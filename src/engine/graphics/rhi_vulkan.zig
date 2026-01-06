//! Vulkan Rendering Hardware Interface (RHI) Backend
//!
//! This module implements the RHI interface for Vulkan, providing GPU abstraction.
//! Key features:
//! - Vulkan instance, device, and swapchain management
//! - Multiple pipelines: terrain, shadow (CSM), sky, UI
//! - Resource management (buffers, textures, descriptors)
//! - Synchronization (semaphores, fences for frame pacing)
//!
//! ## Frame Lifecycle
//! 1. `beginFrame()` - Acquires swapchain image, begins command buffer
//! 2. `beginMainPass()` / `beginShadowPass()` - Starts render passes
//! 3. `draw()` / `drawSky()` / `drawUIQuad()` - Records draw commands
//! 4. `endMainPass()` / `endShadowPass()` - Ends render passes
//! 5. `endFrame()` - Submits command buffer, presents to swapchain
//!
//! ## Memory Model
//! Uses host-visible coherent memory for simplicity. Future improvement:
//! staging buffers with device-local memory for better GPU performance.
//!
//! ## Thread Safety
//! A mutex protects buffer/texture maps. Vulkan commands are NOT thread-safe
//! - all rendering must occur on the main thread.

const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const RenderDevice = @import("render_device.zig").RenderDevice;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

const MAX_FRAMES_IN_FLIGHT = 2;

/// Global uniform buffer layout (std140). Bound to descriptor set 0, binding 0.
const GlobalUniforms = extern struct {
    view_proj: Mat4, // Combined view-projection matrix
    cam_pos: [4]f32, // Camera world position (w unused)
    sun_dir: [4]f32, // Sun direction (w unused)
    fog_color: [4]f32, // Fog RGB (a unused)
    time: f32,
    fog_density: f32,
    fog_enabled: f32, // 0.0 or 1.0
    sun_intensity: f32,
    ambient: f32,
    use_texture: f32, // 0.0 = vertex colors, 1.0 = textures
    cloud_wind_offset: [2]f32,
    cloud_scale: f32,
    cloud_coverage: f32,
    cloud_shadow_strength: f32,
    cloud_height: f32,
    padding: [2]f32, // Align to 16 bytes
};

/// Shadow cascade uniforms for CSM. Bound to descriptor set 0, binding 2.
const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32, // vec4 in shader
    shadow_texel_sizes: [4]f32, // vec4 in shader
};

/// Per-draw model matrix, passed via push constants for efficiency.
const ModelUniforms = extern struct {
    view_proj: Mat4,
    model: Mat4,
    mask_radius: f32,
    padding: [3]f32,
};

/// Push constants for procedural sky rendering.
const SkyPushConstants = extern struct {
    cam_forward: [4]f32,
    cam_right: [4]f32,
    cam_up: [4]f32,
    sun_dir: [4]f32,
    sky_color: [4]f32,
    horizon_color: [4]f32,
    params: [4]f32,
    time: [4]f32,
};

/// Vulkan buffer with backing memory.
const VulkanBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: c.VkDeviceSize,
    is_host_visible: bool,
};

/// Vulkan texture with image, view, and sampler.
const TextureResource = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    width: u32,
    height: u32,
    format: rhi.TextureFormat,
    config: rhi.TextureConfig,
};

const ZombieBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
};

/// Per-frame linear staging buffer for async uploads.
const StagingBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,
    current_offset: u64,
    mapped_ptr: ?*anyopaque,

    fn init(ctx: *VulkanContext, size: u64) !StagingBuffer {
        const buf = createVulkanBuffer(ctx, size, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (buf.buffer == null) return error.VulkanError;

        var mapped: ?*anyopaque = null;
        try checkVk(c.vkMapMemory(ctx.vk_device, buf.memory, 0, size, 0, &mapped));

        return StagingBuffer{
            .buffer = buf.buffer,
            .memory = buf.memory,
            .size = size,
            .current_offset = 0,
            .mapped_ptr = mapped,
        };
    }

    fn deinit(self: *StagingBuffer, device: c.VkDevice) void {
        if (self.mapped_ptr != null) {
            c.vkUnmapMemory(device, self.memory);
        }
        c.vkDestroyBuffer(device, self.buffer, null);
        c.vkFreeMemory(device, self.memory, null);
    }

    fn reset(self: *StagingBuffer) void {
        self.current_offset = 0;
    }

    /// Allocates space in the staging buffer. Returns offset if successful, null if full.
    /// Aligns allocation to 256 bytes (common minUniformBufferOffsetAlignment/optimal copy offset).
    fn allocate(self: *StagingBuffer, size: u64) ?u64 {
        const alignment = 256; // Safe alignment for most GPU copy operations
        const aligned_offset = std.mem.alignForward(u64, self.current_offset, alignment);

        if (aligned_offset + size > self.size) return null;

        self.current_offset = aligned_offset + size;
        return aligned_offset;
    }
};

/// Core Vulkan context containing all renderer state.
/// Owns Vulkan objects and manages their lifecycle.
const VulkanContext = struct {
    allocator: std.mem.Allocator,
    render_device: ?*RenderDevice,
    instance: c.VkInstance,
    surface: c.VkSurfaceKHR,
    physical_device: c.VkPhysicalDevice,
    vk_device: c.VkDevice,
    queue: c.VkQueue,
    graphics_family: u32,
    command_pool: c.VkCommandPool,
    command_buffers: [MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,

    // Per-frame transfer command buffers for async uploads
    transfer_command_pool: c.VkCommandPool,
    transfer_command_buffers: [MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
    staging_buffers: [MAX_FRAMES_IN_FLIGHT]StagingBuffer,
    transfer_ready: bool, // True if current frame's transfer buffer is begun and ready for recording

    buffer_deletion_queue: [MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(ZombieBuffer),

    // Sync
    image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    in_flight_fences: [MAX_FRAMES_IN_FLIGHT]c.VkFence,
    current_sync_frame: u32,

    // Swapchain
    swapchain: c.VkSwapchainKHR,
    swapchain_images: std.ArrayListUnmanaged(c.VkImage),
    swapchain_image_views: std.ArrayListUnmanaged(c.VkImageView),
    swapchain_format: c.VkFormat,
    swapchain_extent: c.VkExtent2D,
    swapchain_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer),
    render_pass: c.VkRenderPass,

    // Depth buffer
    depth_image: c.VkImage,
    depth_image_memory: c.VkDeviceMemory,
    depth_image_view: c.VkImageView,

    // Dummy shadow texture for fallback
    dummy_shadow_image: c.VkImage,
    dummy_shadow_memory: c.VkDeviceMemory,
    dummy_shadow_view: c.VkImageView,

    // Uniforms
    global_ubos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    model_ubo: VulkanBuffer,
    shadow_ubos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,

    // Pipeline
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    shadow_pipeline: c.VkPipeline,
    shadow_render_pass: c.VkRenderPass,

    sky_pipeline: c.VkPipeline,
    sky_pipeline_layout: c.VkPipelineLayout,

    image_index: u32,
    frame_index: usize,

    buffers: std.AutoHashMap(rhi.BufferHandle, VulkanBuffer),
    next_buffer_handle: rhi.BufferHandle,

    textures: std.AutoHashMap(rhi.TextureHandle, TextureResource),
    next_texture_handle: rhi.TextureHandle,
    current_texture: rhi.TextureHandle,

    mutex: std.Thread.Mutex,

    memory_type_index: u32, // Host visible coherent

    current_model: Mat4,
    current_mask_radius: f32,

    // For swapchain recreation
    window: *c.SDL_Window,
    framebuffer_resized: bool,
    frame_in_progress: bool,
    main_pass_active: bool,
    shadow_pass_active: bool,
    shadow_pass_index: u32,
    shadow_pass_matrix: Mat4,
    current_view_proj: Mat4,

    clear_color: [4]f32,

    // Debug
    draw_call_count: u32,

    // Frame-level state tracking (for optimization)
    terrain_pipeline_bound: bool,
    shadow_pipeline_bound: bool,
    descriptors_updated: bool,
    bound_texture: rhi.TextureHandle,

    // Rendering options
    wireframe_enabled: bool,
    textures_enabled: bool,
    wireframe_pipeline: c.VkPipeline,
    vsync_enabled: bool,
    present_mode: c.VkPresentModeKHR,
    anisotropic_filtering: u8,
    max_anisotropy: f32,
    msaa_samples: u8,
    max_msaa_samples: u8,

    // MSAA resources (only allocated when msaa_samples > 1)
    msaa_color_image: c.VkImage,
    msaa_color_memory: c.VkDeviceMemory,
    msaa_color_view: c.VkImageView,

    shadow_resolution: u32,

    // Shadow resources
    shadow_images: [rhi.SHADOW_CASCADE_COUNT]c.VkImage,
    shadow_image_memory: [rhi.SHADOW_CASCADE_COUNT]c.VkDeviceMemory,
    shadow_image_views: [rhi.SHADOW_CASCADE_COUNT]c.VkImageView,
    shadow_framebuffers: [rhi.SHADOW_CASCADE_COUNT]c.VkFramebuffer,
    shadow_image_layouts: [rhi.SHADOW_CASCADE_COUNT]c.VkImageLayout,
    shadow_sampler: c.VkSampler,
    shadow_extent: c.VkExtent2D,

    // UI Pipeline
    ui_pipeline: c.VkPipeline,
    ui_pipeline_layout: c.VkPipelineLayout,
    ui_tex_pipeline: c.VkPipeline,
    ui_tex_pipeline_layout: c.VkPipelineLayout,
    ui_tex_descriptor_set_layout: c.VkDescriptorSetLayout,
    ui_tex_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    ui_vbos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    ui_screen_width: f32,
    ui_screen_height: f32,
    ui_in_progress: bool,
    ui_vertex_offset: u64,
    ui_flushed_vertex_count: u32,
    ui_mapped_ptr: ?*anyopaque,

    // Cloud Pipeline
    cloud_pipeline: c.VkPipeline,
    cloud_pipeline_layout: c.VkPipelineLayout,
    cloud_vbo: VulkanBuffer,
    cloud_ebo: VulkanBuffer,
    cloud_mesh_size: f32,
    cloud_vao: c.VkBuffer,

    // Debug Shadow Pipeline
    debug_shadow_pipeline: c.VkPipeline,
    debug_shadow_pipeline_layout: c.VkPipelineLayout,
    debug_shadow_descriptor_set_layout: c.VkDescriptorSetLayout,
    debug_shadow_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    debug_shadow_vbo: VulkanBuffer,
    debug_shadow_vao: c.VkBuffer,
};

/// Converts VkResult to Zig error for consistent error handling.
fn checkVk(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.VulkanError;
}

/// Creates a shader module from SPIR-V bytecode. Caller must destroy after use.
fn createShaderModule(device: c.VkDevice, code: []const u8) !c.VkShaderModule {
    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code.len;
    create_info.pCode = @ptrCast(@alignCast(code.ptr));

    var shader_module: c.VkShaderModule = null;
    try checkVk(c.vkCreateShaderModule(device, &create_info, null, &shader_module));
    return shader_module;
}

/// Finds memory type index matching filter and properties (e.g., HOST_VISIBLE).
fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    var i: u32 = 0;
    while (i < mem_properties.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
        {
            return i;
        }
    }
    return 0;
}

/// Converts MSAA sample count (1, 2, 4, 8) to Vulkan sample count flag.
fn getMSAASampleCountFlag(samples: u8) c.VkSampleCountFlagBits {
    return switch (samples) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}

/// Creates a buffer with specified usage and memory properties.
fn createVulkanBuffer(ctx: *VulkanContext, size: usize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) VulkanBuffer {
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = @intCast(size);
    buffer_info.usage = usage;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var buffer: c.VkBuffer = null;
    _ = c.vkCreateBuffer(ctx.vk_device, &buffer_info, null, &buffer);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(ctx.vk_device, buffer, &mem_reqs);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, properties);

    var memory: c.VkDeviceMemory = null;
    // If allocation fails, we return null memory/buffer (handled by caller hopefully, or we should log/panic?)
    // Existing code ignored errors here mostly. Ideally we check result.
    if (c.vkAllocateMemory(ctx.vk_device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
        c.vkDestroyBuffer(ctx.vk_device, buffer, null);
        return .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    }
    _ = c.vkBindBufferMemory(ctx.vk_device, buffer, memory, 0);

    const is_host_visible = (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
    return .{ .buffer = buffer, .memory = memory, .size = mem_reqs.size, .is_host_visible = is_host_visible };
}

/// Creates MSAA color image resources when msaa_samples > 1.
/// Call after swapchain creation since we need extent and format.
fn createMSAAResources(ctx: *VulkanContext) void {
    // Only create MSAA resources if multisampling is enabled
    if (ctx.msaa_samples <= 1) {
        ctx.msaa_color_image = null;
        ctx.msaa_color_memory = null;
        ctx.msaa_color_view = null;
        return;
    }

    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);

    // Create MSAA color image
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent.width = ctx.swapchain_extent.width;
    image_info.extent.height = ctx.swapchain_extent.height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = ctx.swapchain_format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    // TRANSIENT_ATTACHMENT for lazily-allocated memory (GPU optimization)
    image_info.usage = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    image_info.samples = sample_count;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    if (c.vkCreateImage(ctx.vk_device, &image_info, null, &ctx.msaa_color_image) != c.VK_SUCCESS) {
        std.log.err("Failed to create MSAA color image", .{});
        ctx.msaa_color_image = null;
        return;
    }

    // Allocate memory
    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vk_device, ctx.msaa_color_image, &mem_reqs);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    // Try LAZILY_ALLOCATED first for transient attachments, fall back to DEVICE_LOCAL
    const lazy_mem_type = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT | c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (lazy_mem_type != 0) {
        alloc_info.memoryTypeIndex = lazy_mem_type;
    } else {
        alloc_info.memoryTypeIndex = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    }

    if (c.vkAllocateMemory(ctx.vk_device, &alloc_info, null, &ctx.msaa_color_memory) != c.VK_SUCCESS) {
        std.log.err("Failed to allocate MSAA color memory", .{});
        c.vkDestroyImage(ctx.vk_device, ctx.msaa_color_image, null);
        ctx.msaa_color_image = null;
        return;
    }

    _ = c.vkBindImageMemory(ctx.vk_device, ctx.msaa_color_image, ctx.msaa_color_memory, 0);

    // Create image view
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = ctx.msaa_color_image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = ctx.swapchain_format;
    view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    if (c.vkCreateImageView(ctx.vk_device, &view_info, null, &ctx.msaa_color_view) != c.VK_SUCCESS) {
        std.log.err("Failed to create MSAA color image view", .{});
        c.vkFreeMemory(ctx.vk_device, ctx.msaa_color_memory, null);
        c.vkDestroyImage(ctx.vk_device, ctx.msaa_color_image, null);
        ctx.msaa_color_image = null;
        ctx.msaa_color_memory = null;
        return;
    }

    std.log.info("Created MSAA {}x color image ({}x{})", .{ ctx.msaa_samples, ctx.swapchain_extent.width, ctx.swapchain_extent.height });
}

/// Destroys MSAA resources if they exist.
fn destroyMSAAResources(ctx: *VulkanContext) void {
    if (ctx.msaa_color_view != null) {
        c.vkDestroyImageView(ctx.vk_device, ctx.msaa_color_view, null);
        ctx.msaa_color_view = null;
    }
    if (ctx.msaa_color_image != null) {
        c.vkDestroyImage(ctx.vk_device, ctx.msaa_color_image, null);
        ctx.msaa_color_image = null;
    }
    if (ctx.msaa_color_memory != null) {
        c.vkFreeMemory(ctx.vk_device, ctx.msaa_color_memory, null);
        ctx.msaa_color_memory = null;
    }
}

/// Helper to create a texture sampler based on config and global anisotropy.
fn createSampler(ctx: *VulkanContext, config: rhi.TextureConfig, mip_levels: u32) c.VkSampler {
    const vk_mag_filter: c.VkFilter = if (config.mag_filter == .nearest) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;
    const vk_min_filter: c.VkFilter = if (config.min_filter == .nearest or config.min_filter == .nearest_mipmap_nearest or config.min_filter == .nearest_mipmap_linear)
        c.VK_FILTER_NEAREST
    else
        c.VK_FILTER_LINEAR;

    const vk_mipmap_mode: c.VkSamplerMipmapMode = if (config.min_filter == .nearest_mipmap_nearest or config.min_filter == .linear_mipmap_nearest)
        c.VK_SAMPLER_MIPMAP_MODE_NEAREST
    else
        c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

    const vk_wrap_s: c.VkSamplerAddressMode = switch (config.wrap_s) {
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirrored_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .clamp_to_border => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    };
    const vk_wrap_t: c.VkSamplerAddressMode = switch (config.wrap_t) {
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirrored_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .clamp_to_border => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    };

    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = vk_mag_filter;
    sampler_info.minFilter = vk_min_filter;
    sampler_info.addressModeU = vk_wrap_s;
    sampler_info.addressModeV = vk_wrap_t;
    sampler_info.addressModeW = vk_wrap_s;
    sampler_info.anisotropyEnable = if (ctx.anisotropic_filtering > 1 and mip_levels > 1) c.VK_TRUE else c.VK_FALSE;
    sampler_info.maxAnisotropy = @min(@as(f32, @floatFromInt(ctx.anisotropic_filtering)), ctx.max_anisotropy);
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = vk_mipmap_mode;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = @floatFromInt(mip_levels);

    var sampler: c.VkSampler = null;
    _ = c.vkCreateSampler(ctx.vk_device, &sampler_info, null, &sampler);
    return sampler;
}

fn createMainRenderPass(ctx: *VulkanContext) !void {
    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);
    const use_msaa = ctx.msaa_samples > 1;
    const depth_format = c.VK_FORMAT_D32_SFLOAT;

    if (use_msaa) {
        // MSAA render pass: 3 attachments (MSAA color, MSAA depth, resolve)
        var msaa_color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        msaa_color_attachment.format = ctx.swapchain_format;
        msaa_color_attachment.samples = sample_count;
        msaa_color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        msaa_color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE; // MSAA image not needed after resolve
        msaa_color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        msaa_color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        msaa_color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        msaa_color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        depth_attachment.format = depth_format;
        depth_attachment.samples = sample_count;
        depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE; // Depth not needed after rendering
        depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolve_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        resolve_attachment.format = ctx.swapchain_format;
        resolve_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT; // Resolve target is single-sampled
        resolve_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE; // Will be overwritten by resolve
        resolve_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        resolve_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        resolve_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        resolve_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        resolve_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
        color_attachment_ref.attachment = 0; // MSAA color
        color_attachment_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depth_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
        depth_attachment_ref.attachment = 1; // MSAA depth
        depth_attachment_ref.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolve_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
        resolve_attachment_ref.attachment = 2; // Resolve target (swapchain)
        resolve_attachment_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_attachment_ref;
        subpass.pDepthStencilAttachment = &depth_attachment_ref;
        subpass.pResolveAttachments = &resolve_attachment_ref; // Automatic MSAA resolve

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        var attachment_descs = [_]c.VkAttachmentDescription{ msaa_color_attachment, depth_attachment, resolve_attachment };
        var render_pass_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount = 3;
        render_pass_info.pAttachments = &attachment_descs[0];
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;

        try checkVk(c.vkCreateRenderPass(ctx.vk_device, &render_pass_info, null, &ctx.render_pass));
        std.log.info("Created MSAA {}x render pass", .{ctx.msaa_samples});
    } else {
        // Non-MSAA render pass: 2 attachments (color, depth)
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = ctx.swapchain_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        depth_attachment.format = depth_format;
        depth_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var color_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
        color_attachment_ref.attachment = 0;
        color_attachment_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depth_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
        depth_attachment_ref.attachment = 1;
        depth_attachment_ref.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_attachment_ref;
        subpass.pDepthStencilAttachment = &depth_attachment_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        var attachment_descs = [_]c.VkAttachmentDescription{ color_attachment, depth_attachment };
        var render_pass_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount = 2;
        render_pass_info.pAttachments = &attachment_descs[0];
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;

        try checkVk(c.vkCreateRenderPass(ctx.vk_device, &render_pass_info, null, &ctx.render_pass));
    }
}

fn createMainFramebuffers(ctx: *VulkanContext) !void {
    const use_msaa = ctx.msaa_samples > 1;
    for (ctx.swapchain_image_views.items) |iv| {
        var fb: c.VkFramebuffer = null;
        var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        framebuffer_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer_info.renderPass = ctx.render_pass;
        framebuffer_info.width = ctx.swapchain_extent.width;
        framebuffer_info.height = ctx.swapchain_extent.height;
        framebuffer_info.layers = 1;

        if (use_msaa and ctx.msaa_color_view != null) {
            // MSAA framebuffer: [msaa_color, depth, swapchain_resolve]
            const fb_attachments = [_]c.VkImageView{ ctx.msaa_color_view.?, ctx.depth_image_view, iv };
            framebuffer_info.attachmentCount = 3;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try checkVk(c.vkCreateFramebuffer(ctx.vk_device, &framebuffer_info, null, &fb));
        } else {
            // Non-MSAA framebuffer: [swapchain_color, depth]
            const fb_attachments = [_]c.VkImageView{ iv, ctx.depth_image_view };
            framebuffer_info.attachmentCount = 2;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try checkVk(c.vkCreateFramebuffer(ctx.vk_device, &framebuffer_info, null, &fb));
        }
        try ctx.swapchain_framebuffers.append(ctx.allocator, fb);
    }
}

fn createMainPipelines(ctx: *VulkanContext) !void {
    // Use common multisampling and viewport state
    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);

    var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state.dynamicStateCount = 2;
    dynamic_state.pDynamicStates = &dynamic_states;

    var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.lineWidth = 1.0;
    rasterizer.cullMode = c.VK_CULL_MODE_NONE;
    rasterizer.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

    var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.rasterizationSamples = sample_count;

    var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depth_stencil.depthTestEnable = c.VK_TRUE;
    depth_stencil.depthWriteEnable = c.VK_TRUE;
    depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

    var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;

    var ui_color_blend_attachment = color_blend_attachment;
    ui_color_blend_attachment.blendEnable = c.VK_TRUE;
    ui_color_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
    ui_color_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    ui_color_blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    ui_color_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    ui_color_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
    ui_color_blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;

    var ui_color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    ui_color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    ui_color_blending.attachmentCount = 1;
    ui_color_blending.pAttachments = &ui_color_blend_attachment;

    var terrain_color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    terrain_color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    terrain_color_blending.attachmentCount = 1;
    terrain_color_blending.pAttachments = &color_blend_attachment;

    // Terrain Pipeline
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/terrain.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/terrain.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        var attribute_descriptions: [7]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
        attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 3 * 4 };
        attribute_descriptions[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 6 * 4 };
        attribute_descriptions[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 9 * 4 };
        attribute_descriptions[4] = .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 11 * 4 };
        attribute_descriptions[5] = .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 12 * 4 };
        attribute_descriptions[6] = .{ .binding = 0, .location = 6, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 13 * 4 };
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = 7;
        vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];
        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &depth_stencil;
        pipeline_info.pColorBlendState = &terrain_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.pipeline_layout;
        pipeline_info.renderPass = ctx.render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.pipeline));

        // Wireframe
        var wireframe_rasterizer = rasterizer;
        wireframe_rasterizer.polygonMode = c.VK_POLYGON_MODE_LINE;
        pipeline_info.pRasterizationState = &wireframe_rasterizer;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.wireframe_pipeline));
    }

    // Sky
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/sky.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/sky.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        var sky_depth_stencil = depth_stencil;
        sky_depth_stencil.depthWriteEnable = c.VK_FALSE;
        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &sky_depth_stencil;
        pipeline_info.pColorBlendState = &terrain_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.sky_pipeline_layout;
        pipeline_info.renderPass = ctx.render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.sky_pipeline));
    }

    // UI
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 6 * @sizeOf(f32), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        var attribute_descriptions: [2]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 };
        attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 2 * 4 };
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = 2;
        vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];
        var ui_depth_stencil = depth_stencil;
        ui_depth_stencil.depthTestEnable = c.VK_FALSE;
        ui_depth_stencil.depthWriteEnable = c.VK_FALSE;
        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &ui_depth_stencil;
        pipeline_info.pColorBlendState = &ui_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.ui_pipeline_layout;
        pipeline_info.renderPass = ctx.render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.ui_pipeline));

        // Textured UI
        const tex_vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui_tex.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_vert_code);
        const tex_frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui_tex.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_frag_code);
        const tex_vert_module = try createShaderModule(ctx.vk_device, tex_vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, tex_vert_module, null);
        const tex_frag_module = try createShaderModule(ctx.vk_device, tex_frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, tex_frag_module, null);
        var tex_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = tex_vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = tex_frag_module, .pName = "main" },
        };
        pipeline_info.pStages = &tex_shader_stages[0];
        pipeline_info.layout = ctx.ui_tex_pipeline_layout;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.ui_tex_pipeline));
    }

    // Debug Shadow
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/debug_shadow.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/debug_shadow.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 4 * @sizeOf(f32), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        var attribute_descriptions: [2]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 };
        attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 2 * 4 };
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = 2;
        vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];
        var ui_depth_stencil = depth_stencil;
        ui_depth_stencil.depthTestEnable = c.VK_FALSE;
        ui_depth_stencil.depthWriteEnable = c.VK_FALSE;
        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &ui_depth_stencil;
        pipeline_info.pColorBlendState = &ui_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.debug_shadow_pipeline_layout;
        pipeline_info.renderPass = ctx.render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.debug_shadow_pipeline));
    }

    // Cloud
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/cloud.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/cloud.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 2 * @sizeOf(f32), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        var attribute_descriptions: [1]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 };
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = 1;
        vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];
        var cloud_depth_stencil = depth_stencil;
        cloud_depth_stencil.depthWriteEnable = c.VK_FALSE;
        var cloud_rasterizer = rasterizer;
        cloud_rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &cloud_rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &cloud_depth_stencil;
        pipeline_info.pColorBlendState = &ui_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.cloud_pipeline_layout;
        pipeline_info.renderPass = ctx.render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipeline_info, null, &ctx.cloud_pipeline));
    }
}

fn destroyMainRenderPassAndPipelines(ctx: *VulkanContext) void {
    if (ctx.vk_device == null) return;
    _ = c.vkDeviceWaitIdle(ctx.vk_device);

    if (ctx.pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.pipeline, null);
        ctx.pipeline = null;
    }
    if (ctx.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.wireframe_pipeline, null);
        ctx.wireframe_pipeline = null;
    }
    // Note: shadow_pipeline and shadow_render_pass are NOT destroyed here
    // because they don't depend on the swapchain or MSAA settings.

    if (ctx.sky_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.sky_pipeline, null);
        ctx.sky_pipeline = null;
    }
    if (ctx.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.wireframe_pipeline, null);
        ctx.wireframe_pipeline = null;
    }
    if (ctx.sky_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.sky_pipeline, null);
        ctx.sky_pipeline = null;
    }
    if (ctx.ui_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.ui_pipeline, null);
        ctx.ui_pipeline = null;
    }
    if (ctx.ui_tex_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.ui_tex_pipeline, null);
        ctx.ui_tex_pipeline = null;
    }
    if (ctx.debug_shadow_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.debug_shadow_pipeline, null);
        ctx.debug_shadow_pipeline = null;
    }
    if (ctx.cloud_pipeline != null) {
        c.vkDestroyPipeline(ctx.vk_device, ctx.cloud_pipeline, null);
        ctx.cloud_pipeline = null;
    }
    if (ctx.render_pass != null) {
        c.vkDestroyRenderPass(ctx.vk_device, ctx.render_pass, null);
        ctx.render_pass = null;
    }
}

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.render_device = render_device;

    // 1. Create Instance
    var count: u32 = 0;
    const extensions_ptr = c.SDL_Vulkan_GetInstanceExtensions(&count);
    if (extensions_ptr == null) return error.VulkanExtensionsFailed;

    var app_info = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "ZigCraft";
    app_info.apiVersion = c.VK_API_VERSION_1_0;

    const enable_validation = std.debug.runtime_safety;
    const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};

    var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;
    create_info.enabledExtensionCount = count;
    create_info.ppEnabledExtensionNames = extensions_ptr;

    if (enable_validation) {
        var layer_count: u32 = 0;
        _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);
        if (layer_count > 0) {
            const layer_props = ctx.allocator.alloc(c.VkLayerProperties, layer_count) catch null;
            if (layer_props) |props| {
                defer ctx.allocator.free(props);
                _ = c.vkEnumerateInstanceLayerProperties(&layer_count, props.ptr);
                var found = false;
                for (props) |layer| {
                    const layer_name: [*:0]const u8 = @ptrCast(&layer.layerName);
                    if (std.mem.eql(u8, std.mem.span(layer_name), "VK_LAYER_KHRONOS_validation")) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    create_info.enabledLayerCount = 1;
                    create_info.ppEnabledLayerNames = &validation_layers;
                    std.log.info("Vulkan validation layers enabled", .{});
                }
            }
        }
    }
    try checkVk(c.vkCreateInstance(&create_info, null, &ctx.instance));

    // 2. Create Surface
    if (!c.SDL_Vulkan_CreateSurface(ctx.window, ctx.instance, null, &ctx.surface)) return error.VulkanSurfaceFailed;

    // 3. Pick Physical Device
    var device_count: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(ctx.instance, &device_count, null);
    if (device_count == 0) return error.NoVulkanDevice;
    const devices = try ctx.allocator.alloc(c.VkPhysicalDevice, device_count);
    defer ctx.allocator.free(devices);
    _ = c.vkEnumeratePhysicalDevices(ctx.instance, &device_count, devices.ptr);
    ctx.physical_device = devices[0];

    // 4. Create Logical Device
    var supported_features: c.VkPhysicalDeviceFeatures = undefined;
    c.vkGetPhysicalDeviceFeatures(ctx.physical_device, &supported_features);

    var device_properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(ctx.physical_device, &device_properties);
    ctx.max_anisotropy = device_properties.limits.maxSamplerAnisotropy;
    // Initial anisotropy filtering clamped to max supported
    ctx.anisotropic_filtering = @min(ctx.anisotropic_filtering, @as(u8, @intFromFloat(ctx.max_anisotropy)));

    const color_samples = device_properties.limits.framebufferColorSampleCounts;
    const depth_samples = device_properties.limits.framebufferDepthSampleCounts;
    const sample_counts = color_samples & depth_samples;
    if ((sample_counts & c.VK_SAMPLE_COUNT_8_BIT) != 0) {
        ctx.max_msaa_samples = 8;
    } else if ((sample_counts & c.VK_SAMPLE_COUNT_4_BIT) != 0) {
        ctx.max_msaa_samples = 4;
    } else if ((sample_counts & c.VK_SAMPLE_COUNT_2_BIT) != 0) {
        ctx.max_msaa_samples = 2;
    } else {
        ctx.max_msaa_samples = 1;
    }
    ctx.msaa_samples = @min(ctx.msaa_samples, ctx.max_msaa_samples);

    var device_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    if (supported_features.fillModeNonSolid == c.VK_TRUE) device_features.fillModeNonSolid = c.VK_TRUE;
    if (supported_features.samplerAnisotropy == c.VK_TRUE) device_features.samplerAnisotropy = c.VK_TRUE;

    var queue_family_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &queue_family_count, null);
    const queue_families = try ctx.allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
    defer ctx.allocator.free(queue_families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &queue_family_count, queue_families.ptr);

    var graphics_family: ?u32 = null;
    for (queue_families, 0..) |qf, i| {
        if ((qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
            graphics_family = @intCast(i);
            break;
        }
    }
    if (graphics_family == null) return error.NoGraphicsQueue;
    ctx.graphics_family = graphics_family.?;

    const queue_priority: f32 = 1.0;
    var queue_create_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    queue_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_create_info.queueFamilyIndex = ctx.graphics_family;
    queue_create_info.queueCount = 1;
    queue_create_info.pQueuePriorities = &queue_priority;

    const device_extensions = [_][*c]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    var device_create_info = std.mem.zeroes(c.VkDeviceCreateInfo);
    device_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_create_info.queueCreateInfoCount = 1;
    device_create_info.pQueueCreateInfos = &queue_create_info;
    device_create_info.pEnabledFeatures = &device_features;
    device_create_info.enabledExtensionCount = 1;
    device_create_info.ppEnabledExtensionNames = &device_extensions;

    try checkVk(c.vkCreateDevice(ctx.physical_device, &device_create_info, null, &ctx.vk_device));
    c.vkGetDeviceQueue(ctx.vk_device, ctx.graphics_family, 0, &ctx.queue);

    // 5. Create Swapchain
    var cap: c.VkSurfaceCapabilitiesKHR = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &cap);

    var format_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, null);
    const formats = try ctx.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
    defer ctx.allocator.free(formats);
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, formats.ptr);

    var surface_format = formats[0];
    for (formats) |f| {
        if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            surface_format = f;
            break;
        }
    }
    ctx.swapchain_format = surface_format.format;

    // RESOLUTION FIX: Always query pixel dimensions from SDL
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);

    var lw: c_int = 0;
    var lh: c_int = 0;
    _ = c.SDL_GetWindowSize(ctx.window, &lw, &lh);

    const scale = if (lw > 0) @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(lw)) else 1.0;
    std.log.info("Window size: {}x{} logical, {}x{} pixels (scale: {d:.2})", .{ lw, lh, w, h, scale });

    ctx.swapchain_extent = .{ .width = @intCast(w), .height = @intCast(h) };

    var swapchain_info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
    swapchain_info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swapchain_info.surface = ctx.surface;
    swapchain_info.minImageCount = cap.minImageCount + 1;
    if (cap.maxImageCount > 0 and swapchain_info.minImageCount > cap.maxImageCount) swapchain_info.minImageCount = cap.maxImageCount;
    swapchain_info.imageFormat = ctx.swapchain_format;
    swapchain_info.imageColorSpace = surface_format.colorSpace;
    swapchain_info.imageExtent = ctx.swapchain_extent;
    swapchain_info.imageArrayLayers = 1;
    swapchain_info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    swapchain_info.preTransform = cap.currentTransform;
    swapchain_info.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchain_info.presentMode = ctx.present_mode;
    swapchain_info.clipped = c.VK_TRUE;
    try checkVk(c.vkCreateSwapchainKHR(ctx.vk_device, &swapchain_info, null, &ctx.swapchain));

    var image_count: u32 = 0;
    _ = c.vkGetSwapchainImagesKHR(ctx.vk_device, ctx.swapchain, &image_count, null);
    try ctx.swapchain_images.resize(ctx.allocator, image_count);
    _ = c.vkGetSwapchainImagesKHR(ctx.vk_device, ctx.swapchain, &image_count, ctx.swapchain_images.items.ptr);

    for (ctx.swapchain_images.items) |image| {
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ctx.swapchain_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var view: c.VkImageView = null;
        try checkVk(c.vkCreateImageView(ctx.vk_device, &view_info, null, &view));
        try ctx.swapchain_image_views.append(ctx.allocator, view);
    }

    // 6. Depth Buffer
    const depth_format = c.VK_FORMAT_D32_SFLOAT;
    var depth_image_info = std.mem.zeroes(c.VkImageCreateInfo);
    depth_image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    depth_image_info.imageType = c.VK_IMAGE_TYPE_2D;
    depth_image_info.extent = .{ .width = ctx.swapchain_extent.width, .height = ctx.swapchain_extent.height, .depth = 1 };
    depth_image_info.mipLevels = 1;
    depth_image_info.arrayLayers = 1;
    depth_image_info.format = depth_format;
    depth_image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    depth_image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    depth_image_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    depth_image_info.samples = getMSAASampleCountFlag(ctx.msaa_samples);
    depth_image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    try checkVk(c.vkCreateImage(ctx.vk_device, &depth_image_info, null, &ctx.depth_image));

    var depth_mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vk_device, ctx.depth_image, &depth_mem_reqs);
    var depth_alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    depth_alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    depth_alloc_info.allocationSize = depth_mem_reqs.size;
    depth_alloc_info.memoryTypeIndex = findMemoryType(ctx.physical_device, depth_mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try checkVk(c.vkAllocateMemory(ctx.vk_device, &depth_alloc_info, null, &ctx.depth_image_memory));
    try checkVk(c.vkBindImageMemory(ctx.vk_device, ctx.depth_image, ctx.depth_image_memory, 0));

    var depth_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    depth_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    depth_view_info.image = ctx.depth_image;
    depth_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    depth_view_info.format = depth_format;
    depth_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    try checkVk(c.vkCreateImageView(ctx.vk_device, &depth_view_info, null, &ctx.depth_image_view));

    // 7. Render Stack (Main)
    createMSAAResources(ctx);
    try createMainRenderPass(ctx);
    try createMainFramebuffers(ctx);

    // 8. Command Pools & Buffers
    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = ctx.graphics_family;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    try checkVk(c.vkCreateCommandPool(ctx.vk_device, &pool_info, null, &ctx.command_pool));

    var cb_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    cb_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cb_alloc_info.commandPool = ctx.command_pool;
    cb_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
    try checkVk(c.vkAllocateCommandBuffers(ctx.vk_device, &cb_alloc_info, &ctx.command_buffers[0]));

    try checkVk(c.vkCreateCommandPool(ctx.vk_device, &pool_info, null, &ctx.transfer_command_pool));
    cb_alloc_info.commandPool = ctx.transfer_command_pool;
    try checkVk(c.vkAllocateCommandBuffers(ctx.vk_device, &cb_alloc_info, &ctx.transfer_command_buffers[0]));

    for (0..MAX_FRAMES_IN_FLIGHT) |frame_i| ctx.staging_buffers[frame_i] = try StagingBuffer.init(ctx, 64 * 1024 * 1024);
    ctx.transfer_ready = false;

    // 9. Layouts & Descriptors
    var layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = 6;
    layout_info.pBindings = &layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vk_device, &layout_info, null, &ctx.descriptor_set_layout));

    var ui_tex_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var ui_tex_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    ui_tex_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    ui_tex_layout_info.bindingCount = 1;
    ui_tex_layout_info.pBindings = &ui_tex_layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vk_device, &ui_tex_layout_info, null, &ctx.ui_tex_descriptor_set_layout));

    var debug_shadow_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var debug_shadow_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    debug_shadow_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    debug_shadow_layout_info.bindingCount = 1;
    debug_shadow_layout_info.pBindings = &debug_shadow_layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vk_device, &debug_shadow_layout_info, null, &ctx.debug_shadow_descriptor_set_layout));

    var model_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    model_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    model_push_constant.size = @sizeOf(ModelUniforms);
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &ctx.descriptor_set_layout;
    pipeline_layout_info.pushConstantRangeCount = 1;
    pipeline_layout_info.pPushConstantRanges = &model_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &pipeline_layout_info, null, &ctx.pipeline_layout));

    var sky_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    sky_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    sky_push_constant.size = 128; // Standard SkyPushConstants size
    var sky_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    sky_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    sky_layout_info.pushConstantRangeCount = 1;
    sky_layout_info.pPushConstantRanges = &sky_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &sky_layout_info, null, &ctx.sky_pipeline_layout));

    var ui_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    ui_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
    ui_push_constant.size = @sizeOf(Mat4);
    var ui_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_layout_info.pushConstantRangeCount = 1;
    ui_layout_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &ui_layout_info, null, &ctx.ui_pipeline_layout));

    var ui_tex_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_tex_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_tex_layout_full_info.setLayoutCount = 1;
    ui_tex_layout_full_info.pSetLayouts = &ctx.ui_tex_descriptor_set_layout;
    ui_tex_layout_full_info.pushConstantRangeCount = 1;
    ui_tex_layout_full_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &ui_tex_layout_full_info, null, &ctx.ui_tex_pipeline_layout));

    var debug_shadow_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    debug_shadow_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    debug_shadow_layout_full_info.setLayoutCount = 1;
    debug_shadow_layout_full_info.pSetLayouts = &ctx.debug_shadow_descriptor_set_layout;
    debug_shadow_layout_full_info.pushConstantRangeCount = 1;
    debug_shadow_layout_full_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &debug_shadow_layout_full_info, null, &ctx.debug_shadow_pipeline_layout));

    var cloud_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    cloud_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    cloud_layout_info.pushConstantRangeCount = 1;
    cloud_layout_info.pPushConstantRanges = &sky_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vk_device, &cloud_layout_info, null, &ctx.cloud_pipeline_layout));

    // 10. Shadow Pass (Created ONCE)
    const shadow_res = ctx.shadow_resolution;
    var shadow_depth_desc = std.mem.zeroes(c.VkAttachmentDescription);
    shadow_depth_desc.format = depth_format;
    shadow_depth_desc.samples = c.VK_SAMPLE_COUNT_1_BIT;
    shadow_depth_desc.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    shadow_depth_desc.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    shadow_depth_desc.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    shadow_depth_desc.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    var shadow_depth_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    var shadow_subpass = std.mem.zeroes(c.VkSubpassDescription);
    shadow_subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    shadow_subpass.pDepthStencilAttachment = &shadow_depth_ref;
    var shadow_rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
    shadow_rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    shadow_rp_info.attachmentCount = 1;
    shadow_rp_info.pAttachments = &shadow_depth_desc;
    shadow_rp_info.subpassCount = 1;
    shadow_rp_info.pSubpasses = &shadow_subpass;
    try checkVk(c.vkCreateRenderPass(ctx.vk_device, &shadow_rp_info, null, &ctx.shadow_render_pass));

    ctx.shadow_extent = .{ .width = shadow_res, .height = shadow_res };
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        var shadow_img_info = std.mem.zeroes(c.VkImageCreateInfo);
        shadow_img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        shadow_img_info.imageType = c.VK_IMAGE_TYPE_2D;
        shadow_img_info.extent = .{ .width = shadow_res, .height = shadow_res, .depth = 1 };
        shadow_img_info.mipLevels = 1;
        shadow_img_info.arrayLayers = 1;
        shadow_img_info.format = depth_format;
        shadow_img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        shadow_img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        shadow_img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        try checkVk(c.vkCreateImage(ctx.vk_device, &shadow_img_info, null, &ctx.shadow_images[si]));
        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vk_device, ctx.shadow_images[si], &mem_reqs);
        var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
        try checkVk(c.vkAllocateMemory(ctx.vk_device, &alloc_info, null, &ctx.shadow_image_memory[si]));
        try checkVk(c.vkBindImageMemory(ctx.vk_device, ctx.shadow_images[si], ctx.shadow_image_memory[si], 0));
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.shadow_images[si];
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = depth_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try checkVk(c.vkCreateImageView(ctx.vk_device, &view_info, null, &ctx.shadow_image_views[si]));
        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.shadow_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.shadow_image_views[si];
        fb_info.width = shadow_res;
        fb_info.height = shadow_res;
        fb_info.layers = 1;
        try checkVk(c.vkCreateFramebuffer(ctx.vk_device, &fb_info, null, &ctx.shadow_framebuffers[si]));

        ctx.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    // Shadow Pipeline
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/shadow.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/shadow.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vk_device, frag_module, null);
        var shadow_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const shadow_binding_description = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(rhi.Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        var shadow_attribute = c.VkVertexInputAttributeDescription{
            .binding = 0,
            .location = 0,
            .format = c.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = 0,
        };
        var shadow_vi_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        shadow_vi_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        shadow_vi_info.vertexBindingDescriptionCount = 1;
        shadow_vi_info.pVertexBindingDescriptions = &shadow_binding_description;
        shadow_vi_info.vertexAttributeDescriptionCount = 1;
        shadow_vi_info.pVertexAttributeDescriptions = &shadow_attribute;
        var shadow_ia_info = c.VkPipelineInputAssemblyStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
        var shadow_vp_info = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        shadow_vp_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        shadow_vp_info.viewportCount = 1;
        shadow_vp_info.scissorCount = 1;
        var shadow_rs_info = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        shadow_rs_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        shadow_rs_info.polygonMode = c.VK_POLYGON_MODE_FILL;
        shadow_rs_info.lineWidth = 1.0;
        shadow_rs_info.cullMode = c.VK_CULL_MODE_BACK_BIT;
        shadow_rs_info.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
        shadow_rs_info.depthBiasEnable = c.VK_TRUE;
        var shadow_ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        shadow_ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        shadow_ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var shadow_ds_info = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        shadow_ds_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        shadow_ds_info.depthTestEnable = c.VK_TRUE;
        shadow_ds_info.depthWriteEnable = c.VK_TRUE;
        shadow_ds_info.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;
        var shadow_cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        shadow_cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        var shadow_dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR, c.VK_DYNAMIC_STATE_DEPTH_BIAS };
        var shadow_dyn_info = c.VkPipelineDynamicStateCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 3, .pDynamicStates = &shadow_dyn_states };
        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &shadow_stages[0];
        pipe_info.pVertexInputState = &shadow_vi_info;
        pipe_info.pInputAssemblyState = &shadow_ia_info;
        pipe_info.pViewportState = &shadow_vp_info;
        pipe_info.pRasterizationState = &shadow_rs_info;
        pipe_info.pMultisampleState = &shadow_ms_info;
        pipe_info.pDepthStencilState = &shadow_ds_info;
        pipe_info.pColorBlendState = &shadow_cb_info;
        pipe_info.pDynamicState = &shadow_dyn_info;
        pipe_info.layout = ctx.pipeline_layout;
        pipe_info.renderPass = ctx.shadow_render_pass;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vk_device, null, 1, &pipe_info, null, &ctx.shadow_pipeline));
    }

    // 11. Final Pipelines & Uniforms
    try createMainPipelines(ctx);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.global_ubos[i] = createVulkanBuffer(ctx, @sizeOf(GlobalUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        ctx.shadow_ubos[i] = createVulkanBuffer(ctx, @sizeOf(ShadowUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        ctx.ui_vbos[i] = createVulkanBuffer(ctx, 1024 * 1024, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    }
    ctx.model_ubo = createVulkanBuffer(ctx, @sizeOf(ModelUniforms) * 1000, c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    var pool_sizes = [_]c.VkDescriptorPoolSize{ .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 2 * MAX_FRAMES_IN_FLIGHT }, .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 10 * MAX_FRAMES_IN_FLIGHT } };
    var dp_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    dp_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dp_info.poolSizeCount = 2;
    dp_info.pPoolSizes = &pool_sizes[0];
    dp_info.maxSets = 10 * MAX_FRAMES_IN_FLIGHT;
    try checkVk(c.vkCreateDescriptorPool(ctx.vk_device, &dp_info, null, &ctx.descriptor_pool));

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        var ds_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx.descriptor_set_layout };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vk_device, &ds_alloc, &ctx.descriptor_sets[i]));
        var writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.global_ubos[i].buffer, .offset = 0, .range = @sizeOf(GlobalUniforms) } },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.descriptor_sets[i], .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.shadow_ubos[i].buffer, .offset = 0, .range = @sizeOf(ShadowUniforms) } },
        };
        c.vkUpdateDescriptorSets(ctx.vk_device, 2, &writes[0], 0, null);

        var ui_ds_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx.ui_tex_descriptor_set_layout };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vk_device, &ui_ds_alloc, &ctx.ui_tex_descriptor_sets[i]));

        var ds_ds_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx.debug_shadow_descriptor_set_layout };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vk_device, &ds_ds_alloc, &ctx.debug_shadow_descriptor_sets[i]));
    }

    var shadow_sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    shadow_sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    shadow_sampler_info.magFilter = c.VK_FILTER_LINEAR;
    shadow_sampler_info.minFilter = c.VK_FILTER_LINEAR;
    shadow_sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
    try checkVk(c.vkCreateSampler(ctx.vk_device, &shadow_sampler_info, null, &ctx.shadow_sampler));

    // Create Debug Shadow VBO (6 vertices for fullscreen quad)
    ctx.debug_shadow_vbo = createVulkanBuffer(ctx, 6 * 4 * @sizeOf(f32), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    // Create cloud mesh (large quad centered on camera)
    ctx.cloud_mesh_size = 10000.0;
    const cloud_vertices = [_]f32{
        -ctx.cloud_mesh_size, -ctx.cloud_mesh_size,
        ctx.cloud_mesh_size,  -ctx.cloud_mesh_size,
        ctx.cloud_mesh_size,  ctx.cloud_mesh_size,
        -ctx.cloud_mesh_size, ctx.cloud_mesh_size,
    };
    const cloud_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

    ctx.cloud_vbo = createVulkanBuffer(ctx, @sizeOf(@TypeOf(cloud_vertices)), c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    ctx.cloud_ebo = createVulkanBuffer(ctx, @sizeOf(@TypeOf(cloud_indices)), c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    // Upload cloud vertex data
    var cloud_vbo_ptr: ?*anyopaque = null;
    if (c.vkMapMemory(ctx.vk_device, ctx.cloud_vbo.memory, 0, @sizeOf(@TypeOf(cloud_vertices)), 0, &cloud_vbo_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(cloud_vbo_ptr.?))[0..@sizeOf(@TypeOf(cloud_vertices))], std.mem.asBytes(&cloud_vertices));
        c.vkUnmapMemory(ctx.vk_device, ctx.cloud_vbo.memory);
    }

    // Upload cloud index data
    var cloud_ebo_ptr: ?*anyopaque = null;
    if (c.vkMapMemory(ctx.vk_device, ctx.cloud_ebo.memory, 0, @sizeOf(@TypeOf(cloud_indices)), 0, &cloud_ebo_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(cloud_ebo_ptr.?))[0..@sizeOf(@TypeOf(cloud_indices))], std.mem.asBytes(&cloud_indices));
        c.vkUnmapMemory(ctx.vk_device, ctx.cloud_ebo.memory);
    }

    // Create Sync Objects
    var sem_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    var fen_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fen_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fen_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        try checkVk(c.vkCreateSemaphore(ctx.vk_device, &sem_info, null, &ctx.image_available_semaphores[i]));
        try checkVk(c.vkCreateSemaphore(ctx.vk_device, &sem_info, null, &ctx.render_finished_semaphores[i]));
        try checkVk(c.vkCreateFence(ctx.vk_device, &fen_info, null, &ctx.in_flight_fences[i]));
    }

    // 15. Create Dummy Texture for Descriptor set validity
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    const dummy_handle = createTexture(ctx_ptr, 1, 1, .rgba, .{}, &white_pixel);
    ctx.current_texture = dummy_handle;

    std.log.info("Vulkan initialized successfully!", .{});
}
fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vk_device);

        destroyMainRenderPassAndPipelines(ctx);

        // Clean up UI pipeline
        if (ctx.ui_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.ui_pipeline, null);
        if (ctx.ui_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.ui_pipeline_layout, null);
        if (ctx.ui_tex_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.ui_tex_pipeline, null);
        if (ctx.ui_tex_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.ui_tex_pipeline_layout, null);
        if (ctx.ui_tex_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vk_device, ctx.ui_tex_descriptor_set_layout, null);
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (ctx.ui_vbos[i].buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.ui_vbos[i].buffer, null);
            if (ctx.ui_vbos[i].memory != null) c.vkFreeMemory(ctx.vk_device, ctx.ui_vbos[i].memory, null);
        }

        // Clean up debug shadow pipeline
        if (ctx.debug_shadow_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.debug_shadow_pipeline, null);
        if (ctx.debug_shadow_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.debug_shadow_pipeline_layout, null);
        if (ctx.debug_shadow_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vk_device, ctx.debug_shadow_descriptor_set_layout, null);
        if (ctx.debug_shadow_vbo.buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.debug_shadow_vbo.buffer, null);
        if (ctx.debug_shadow_vbo.memory != null) c.vkFreeMemory(ctx.vk_device, ctx.debug_shadow_vbo.memory, null);

        // Clean up cloud pipeline
        if (ctx.cloud_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.cloud_pipeline, null);
        if (ctx.cloud_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.cloud_pipeline_layout, null);
        if (ctx.cloud_vbo.buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.cloud_vbo.buffer, null);
        if (ctx.cloud_vbo.memory != null) c.vkFreeMemory(ctx.vk_device, ctx.cloud_vbo.memory, null);
        if (ctx.cloud_ebo.buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.cloud_ebo.buffer, null);
        if (ctx.cloud_ebo.memory != null) c.vkFreeMemory(ctx.vk_device, ctx.cloud_ebo.memory, null);

        // Clean up sky pipeline
        if (ctx.sky_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.sky_pipeline, null);
        if (ctx.sky_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.sky_pipeline_layout, null);

        // Clean up shadow pipeline
        if (ctx.shadow_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.shadow_pipeline, null);

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            if (ctx.shadow_framebuffers[i] != null) c.vkDestroyFramebuffer(ctx.vk_device, ctx.shadow_framebuffers[i], null);
            if (ctx.shadow_image_views[i] != null) c.vkDestroyImageView(ctx.vk_device, ctx.shadow_image_views[i], null);
            if (ctx.shadow_images[i] != null) c.vkDestroyImage(ctx.vk_device, ctx.shadow_images[i], null);
            if (ctx.shadow_image_memory[i] != null) c.vkFreeMemory(ctx.vk_device, ctx.shadow_image_memory[i], null);
        }
        if (ctx.shadow_render_pass != null) c.vkDestroyRenderPass(ctx.vk_device, ctx.shadow_render_pass, null);
        if (ctx.shadow_sampler != null) c.vkDestroySampler(ctx.vk_device, ctx.shadow_sampler, null);

        if (ctx.pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.pipeline, null);
        if (ctx.wireframe_pipeline != null) c.vkDestroyPipeline(ctx.vk_device, ctx.wireframe_pipeline, null);
        if (ctx.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vk_device, ctx.pipeline_layout, null);

        for (ctx.swapchain_framebuffers.items) |fb| if (fb != null) c.vkDestroyFramebuffer(ctx.vk_device, fb, null);
        ctx.swapchain_framebuffers.deinit(ctx.allocator);

        for (ctx.swapchain_image_views.items) |iv| if (iv != null) c.vkDestroyImageView(ctx.vk_device, iv, null);
        ctx.swapchain_image_views.deinit(ctx.allocator);
        ctx.swapchain_images.deinit(ctx.allocator);

        if (ctx.depth_image_view != null) c.vkDestroyImageView(ctx.vk_device, ctx.depth_image_view, null);
        if (ctx.depth_image_memory != null) c.vkFreeMemory(ctx.vk_device, ctx.depth_image_memory, null);
        if (ctx.depth_image != null) c.vkDestroyImage(ctx.vk_device, ctx.depth_image, null);

        // Clean up MSAA resources
        destroyMSAAResources(ctx);

        if (ctx.swapchain != null) c.vkDestroySwapchainKHR(ctx.vk_device, ctx.swapchain, null);
        if (ctx.render_pass != null) c.vkDestroyRenderPass(ctx.vk_device, ctx.render_pass, null);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (ctx.image_available_semaphores[i] != null) c.vkDestroySemaphore(ctx.vk_device, ctx.image_available_semaphores[i], null);
            if (ctx.render_finished_semaphores[i] != null) c.vkDestroySemaphore(ctx.vk_device, ctx.render_finished_semaphores[i], null);
            if (ctx.in_flight_fences[i] != null) c.vkDestroyFence(ctx.vk_device, ctx.in_flight_fences[i], null);
        }

        if (ctx.command_pool != null) c.vkDestroyCommandPool(ctx.vk_device, ctx.command_pool, null);
        if (ctx.transfer_command_pool != null) c.vkDestroyCommandPool(ctx.vk_device, ctx.transfer_command_pool, null);

        // Clean up Staging Buffers
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            ctx.staging_buffers[i].deinit(ctx.vk_device);
        }

        // Clean up UBOS
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (ctx.global_ubos[i].buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.global_ubos[i].buffer, null);
            if (ctx.global_ubos[i].memory != null) c.vkFreeMemory(ctx.vk_device, ctx.global_ubos[i].memory, null);
            if (ctx.shadow_ubos[i].buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.shadow_ubos[i].buffer, null);
            if (ctx.shadow_ubos[i].memory != null) c.vkFreeMemory(ctx.vk_device, ctx.shadow_ubos[i].memory, null);
        }
        if (ctx.model_ubo.buffer != null) c.vkDestroyBuffer(ctx.vk_device, ctx.model_ubo.buffer, null);
        if (ctx.model_ubo.memory != null) c.vkFreeMemory(ctx.vk_device, ctx.model_ubo.memory, null);

        if (ctx.descriptor_pool != null) c.vkDestroyDescriptorPool(ctx.vk_device, ctx.descriptor_pool, null);
        if (ctx.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vk_device, ctx.descriptor_set_layout, null);

        if (ctx.dummy_shadow_view != null) c.vkDestroyImageView(ctx.vk_device, ctx.dummy_shadow_view, null);
        if (ctx.dummy_shadow_image != null) c.vkDestroyImage(ctx.vk_device, ctx.dummy_shadow_image, null);
        if (ctx.dummy_shadow_memory != null) c.vkFreeMemory(ctx.vk_device, ctx.dummy_shadow_memory, null);

        var buf_iter = ctx.buffers.iterator();
        while (buf_iter.next()) |entry| {
            c.vkDestroyBuffer(ctx.vk_device, entry.value_ptr.buffer, null);
            c.vkFreeMemory(ctx.vk_device, entry.value_ptr.memory, null);
        }
        ctx.buffers.deinit();

        var tex_iter = ctx.textures.iterator();
        while (tex_iter.next()) |entry| {
            c.vkDestroySampler(ctx.vk_device, entry.value_ptr.sampler, null);
            c.vkDestroyImageView(ctx.vk_device, entry.value_ptr.view, null);
            c.vkFreeMemory(ctx.vk_device, entry.value_ptr.memory, null);
            c.vkDestroyImage(ctx.vk_device, entry.value_ptr.image, null);
        }
        ctx.textures.deinit();

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_i| {
            for (ctx.buffer_deletion_queue[frame_i].items) |zombie| {
                if (zombie.buffer != null) c.vkDestroyBuffer(ctx.vk_device, zombie.buffer, null);
                if (zombie.memory != null) c.vkFreeMemory(ctx.vk_device, zombie.memory, null);
            }
            ctx.buffer_deletion_queue[frame_i].deinit(ctx.allocator);
        }

        c.vkDestroyDevice(ctx.vk_device, null);
    }
    if (ctx.surface != null) c.vkDestroySurfaceKHR(ctx.instance, ctx.surface, null);
    if (ctx.instance != null) c.vkDestroyInstance(ctx.instance, null);

    ctx.allocator.destroy(ctx);
}

fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (size == 0) return 0;

    const vk_usage: c.VkBufferUsageFlags = switch (usage) {
        .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .index => c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    };

    const props: c.VkMemoryPropertyFlags = switch (usage) {
        .vertex, .index => c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .uniform => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    };

    const buf = createVulkanBuffer(ctx, size, vk_usage, props);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const handle = ctx.next_buffer_handle;
    ctx.next_buffer_handle += 1;
    ctx.buffers.put(handle, buf) catch return 0;

    return handle;
}

fn uploadBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) void {
    updateBuffer(ctx_ptr, handle, 0, data);
}

fn updateBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, dst_offset: usize, data: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (data.len == 0 or handle == 0) return;

    ensureFrameReady(ctx);

    ctx.mutex.lock();
    const buf_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (buf_opt) |buf| {
        if (buf.is_host_visible) {
            var map_ptr: ?*anyopaque = null;
            const result = c.vkMapMemory(ctx.vk_device, buf.memory, @intCast(dst_offset), @intCast(data.len), 0, &map_ptr);
            if (result == c.VK_SUCCESS) {
                @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
                c.vkUnmapMemory(ctx.vk_device, buf.memory);
                return;
            }
        }

        const staging = &ctx.staging_buffers[ctx.current_sync_frame];
        if (staging.allocate(data.len)) |src_offset| {
            const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + src_offset;

            @memcpy(dest[0..data.len], data);

            const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];

            var copy_region = std.mem.zeroes(c.VkBufferCopy);
            copy_region.srcOffset = src_offset;
            copy_region.dstOffset = @intCast(dst_offset);
            copy_region.size = @intCast(data.len);
            c.vkCmdCopyBuffer(transfer_cb, staging.buffer, buf.buffer, 1, &copy_region);

            var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.buffer = buf.buffer;
            barrier.offset = @intCast(dst_offset);
            barrier.size = @intCast(data.len);

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT, 0, 0, null, 1, &barrier, 0, null);
        } else {
            std.log.err("Staging buffer full! Skipping upload of {} bytes", .{data.len});
        }
    }
}

fn destroyBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    const entry_opt = ctx.buffers.fetchRemove(handle);
    ctx.mutex.unlock();

    if (entry_opt) |entry| {
        // Queue to the OTHER frame slot so it's deleted after waiting on that frame's fence
        // This ensures at least MAX_FRAMES_IN_FLIGHT frames pass before deletion
        const delete_frame = (ctx.current_sync_frame + 1) % MAX_FRAMES_IN_FLIGHT;
        ctx.buffer_deletion_queue[delete_frame].append(ctx.allocator, .{ .buffer = entry.value.buffer, .memory = entry.value.memory }) catch {
            std.log.err("Failed to queue buffer deletion (OOM). Leaking buffer.", .{});
        };
    }
}

fn cleanupSwapchain(ctx: *VulkanContext) void {
    for (ctx.swapchain_framebuffers.items) |fb| if (fb != null) c.vkDestroyFramebuffer(ctx.vk_device, fb, null);
    ctx.swapchain_framebuffers.clearRetainingCapacity();

    for (ctx.swapchain_image_views.items) |iv| if (iv != null) c.vkDestroyImageView(ctx.vk_device, iv, null);
    ctx.swapchain_image_views.clearRetainingCapacity();
    ctx.swapchain_images.clearRetainingCapacity();

    if (ctx.depth_image_view != null) {
        c.vkDestroyImageView(ctx.vk_device, ctx.depth_image_view, null);
        ctx.depth_image_view = null;
    }
    if (ctx.depth_image_memory != null) {
        c.vkFreeMemory(ctx.vk_device, ctx.depth_image_memory, null);
        ctx.depth_image_memory = null;
    }
    if (ctx.depth_image != null) {
        c.vkDestroyImage(ctx.vk_device, ctx.depth_image, null);
        ctx.depth_image = null;
    }

    // Cleanup MSAA resources
    destroyMSAAResources(ctx);

    if (ctx.swapchain != null) {
        c.vkDestroySwapchainKHR(ctx.vk_device, ctx.swapchain, null);
        ctx.swapchain = null;
    }
}

/// Recreates swapchain after window resize or when it becomes invalid.
/// Returns true on success, false if recreation failed (caller should retry).
fn recreateSwapchain(ctx: *VulkanContext) void {
    _ = c.vkDeviceWaitIdle(ctx.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) return;

    // 1. Destroy existing main rendering stack
    destroyMainRenderPassAndPipelines(ctx);
    cleanupSwapchain(ctx);

    // 2. Recreate Swapchain
    var cap: c.VkSurfaceCapabilitiesKHR = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &cap);
    ctx.swapchain_extent = .{ .width = @intCast(w), .height = @intCast(h) };

    var swapchain_info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
    swapchain_info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    swapchain_info.surface = ctx.surface;
    swapchain_info.minImageCount = cap.minImageCount + 1;
    if (cap.maxImageCount > 0 and swapchain_info.minImageCount > cap.maxImageCount) swapchain_info.minImageCount = cap.maxImageCount;
    swapchain_info.imageFormat = ctx.swapchain_format;
    swapchain_info.imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    swapchain_info.imageExtent = ctx.swapchain_extent;
    swapchain_info.imageArrayLayers = 1;
    swapchain_info.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    swapchain_info.preTransform = cap.currentTransform;
    swapchain_info.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    swapchain_info.presentMode = ctx.present_mode;
    swapchain_info.clipped = c.VK_TRUE;
    _ = c.vkCreateSwapchainKHR(ctx.vk_device, &swapchain_info, null, &ctx.swapchain);

    var image_count: u32 = 0;
    _ = c.vkGetSwapchainImagesKHR(ctx.vk_device, ctx.swapchain, &image_count, null);
    _ = ctx.swapchain_images.resize(ctx.allocator, image_count) catch {};
    _ = c.vkGetSwapchainImagesKHR(ctx.vk_device, ctx.swapchain, &image_count, ctx.swapchain_images.items.ptr);

    for (ctx.swapchain_images.items) |image| {
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ctx.swapchain_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var view: c.VkImageView = null;
        _ = c.vkCreateImageView(ctx.vk_device, &view_info, null, &view);
        _ = ctx.swapchain_image_views.append(ctx.allocator, view) catch {};
    }

    // 3. Recreate Depth Buffer
    const depth_format = c.VK_FORMAT_D32_SFLOAT;
    var depth_img_info = std.mem.zeroes(c.VkImageCreateInfo);
    depth_img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    depth_img_info.imageType = c.VK_IMAGE_TYPE_2D;
    depth_img_info.extent = .{ .width = ctx.swapchain_extent.width, .height = ctx.swapchain_extent.height, .depth = 1 };
    depth_img_info.mipLevels = 1;
    depth_img_info.arrayLayers = 1;
    depth_img_info.format = depth_format;
    depth_img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    depth_img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    depth_img_info.samples = getMSAASampleCountFlag(ctx.msaa_samples);
    _ = c.vkCreateImage(ctx.vk_device, &depth_img_info, null, &ctx.depth_image);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vk_device, ctx.depth_image, &mem_reqs);
    var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    _ = c.vkAllocateMemory(ctx.vk_device, &alloc_info, null, &ctx.depth_image_memory);
    _ = c.vkBindImageMemory(ctx.vk_device, ctx.depth_image, ctx.depth_image_memory, 0);

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = ctx.depth_image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = depth_format;
    view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    _ = c.vkCreateImageView(ctx.vk_device, &view_info, null, &ctx.depth_image_view);

    // 4. Recreate main rendering stack
    createMSAAResources(ctx);
    createMainRenderPass(ctx) catch {};
    createMainFramebuffers(ctx) catch {};
    createMainPipelines(ctx) catch {};

    ctx.framebuffer_resized = false;
    std.log.info("Vulkan swapchain recreated: {}x{} (SDL pixels: {}x{}, MSAA {}x)", .{ ctx.swapchain_extent.width, ctx.swapchain_extent.height, w, h, ctx.msaa_samples });
}
fn ensureFrameReady(ctx: *VulkanContext) void {
    if (ctx.transfer_ready) return;

    const fence = ctx.in_flight_fences[ctx.current_sync_frame];

    // Wait for the frame to be available
    _ = c.vkWaitForFences(ctx.vk_device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));

    // Reset fence
    _ = c.vkResetFences(ctx.vk_device, 1, &fence);

    // Process deletion queue for THIS frame slot (now safe since fence waited)
    // Buffers were queued here during frame N, now it's frame N+MAX_FRAMES_IN_FLIGHT
    // so the GPU is guaranteed to be done with them
    for (ctx.buffer_deletion_queue[ctx.current_sync_frame].items) |zombie| {
        c.vkDestroyBuffer(ctx.vk_device, zombie.buffer, null);
        c.vkFreeMemory(ctx.vk_device, zombie.memory, null);
    }
    ctx.buffer_deletion_queue[ctx.current_sync_frame].clearRetainingCapacity();

    // Reset staging buffer
    ctx.staging_buffers[ctx.current_sync_frame].reset();

    // Begin transfer command buffer
    const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];
    _ = c.vkResetCommandBuffer(transfer_cb, 0);

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    _ = c.vkBeginCommandBuffer(transfer_cb, &begin_info);

    ctx.transfer_ready = true;
}

fn beginFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    ensureFrameReady(ctx);

    ctx.frame_in_progress = true;
    ctx.draw_call_count = 0;
    ctx.main_pass_active = false;
    ctx.shadow_pass_active = false;

    // Reset per-frame optimization state
    ctx.terrain_pipeline_bound = false;
    ctx.shadow_pipeline_bound = false;
    ctx.descriptors_updated = false;
    ctx.bound_texture = 0;

    const acquire_semaphore = ctx.image_available_semaphores[ctx.current_sync_frame];

    var image_index: u32 = 0;
    const result = c.vkAcquireNextImageKHR(ctx.vk_device, ctx.swapchain, 1000000000, acquire_semaphore, null, &image_index);

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
        recreateSwapchain(ctx);
        return;
    } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
        return;
    }

    ctx.image_index = image_index;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    _ = c.vkResetCommandBuffer(command_buffer, 0);

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;

    _ = c.vkBeginCommandBuffer(command_buffer, &begin_info);

    ctx.frame_in_progress = true;

    // Static descriptor updates (Shadow maps) - only update if they changed or on first frame
    // For now, we update them here once per frame but they are safe because we waited for the fence.
    ctx.mutex.lock();
    const tex_opt = ctx.textures.get(ctx.current_texture);
    const dummy_opt = if (tex_opt == null) ctx.textures.get(1) else null; // Use dummy (handle 1) if nothing bound
    ctx.mutex.unlock();

    var writes: [4]c.VkWriteDescriptorSet = undefined;
    var write_count: u32 = 0;

    var image_info: c.VkDescriptorImageInfo = undefined;
    const final_tex = tex_opt orelse dummy_opt;
    if (final_tex) |tex| {
        image_info = .{
            .sampler = tex.sampler,
            .imageView = tex.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[write_count].dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
        writes[write_count].dstBinding = 1;
        writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[write_count].descriptorCount = 1;
        writes[write_count].pImageInfo = &image_info;
        write_count += 1;
    }

    var shadow_infos: [3]c.VkDescriptorImageInfo = undefined;
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (ctx.shadow_image_views[si] != null) {
            shadow_infos[si] = .{
                .sampler = ctx.shadow_sampler,
                .imageView = ctx.shadow_image_views[si],
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };

            writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[write_count].dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
            writes[write_count].dstBinding = @intCast(3 + si);
            writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[write_count].descriptorCount = 1;
            writes[write_count].pImageInfo = &shadow_infos[si];
            write_count += 1;
        }
    }

    if (write_count > 0) {
        c.vkUpdateDescriptorSets(ctx.vk_device, write_count, &writes[0], 0, null);
    }

    ctx.descriptors_updated = true;
    ctx.bound_texture = ctx.current_texture;
}

fn abortFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    if (ctx.main_pass_active) endMainPass(ctx_ptr);
    if (ctx.shadow_pass_active) endShadowPass(ctx_ptr);

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    _ = c.vkEndCommandBuffer(command_buffer);

    // End transfer buffer if it was started
    if (ctx.transfer_ready) {
        _ = c.vkEndCommandBuffer(ctx.transfer_command_buffers[ctx.current_sync_frame]);
        ctx.transfer_ready = false;
    }

    // We didn't submit, so we must manually signal the fence so we don't deadlock
    // on the next time this sync frame comes around.
    // However, it's safer to just reset the fence to a signaled state.
    _ = c.vkResetFences(ctx.vk_device, 1, &ctx.in_flight_fences[ctx.current_sync_frame]);
    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

    // Recreating semaphores is the most robust way to "abort" their pending status from AcquireNextImage
    c.vkDestroySemaphore(ctx.vk_device, ctx.image_available_semaphores[ctx.current_sync_frame], null);
    c.vkDestroySemaphore(ctx.vk_device, ctx.render_finished_semaphores[ctx.current_sync_frame], null);

    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    _ = c.vkCreateSemaphore(ctx.vk_device, &semaphore_info, null, &ctx.image_available_semaphores[ctx.current_sync_frame]);
    _ = c.vkCreateSemaphore(ctx.vk_device, &semaphore_info, null, &ctx.render_finished_semaphores[ctx.current_sync_frame]);

    ctx.frame_in_progress = false;
}

fn endFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    if (ctx.main_pass_active) {
        endMainPass(ctx_ptr);
    }
    if (ctx.shadow_pass_active) {
        endShadowPass(ctx_ptr);
    }

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    _ = c.vkEndCommandBuffer(command_buffer);

    // End transfer command buffer
    const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];
    if (ctx.transfer_ready) {
        _ = c.vkEndCommandBuffer(transfer_cb);
    }

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;

    const wait_semaphores = [_]c.VkSemaphore{ctx.image_available_semaphores[ctx.current_sync_frame]};
    const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    submit_info.waitSemaphoreCount = 1;
    submit_info.pWaitSemaphores = &wait_semaphores;
    submit_info.pWaitDstStageMask = &wait_stages;

    // Submit transfer buffer (if ready) AND graphics buffer
    var command_buffers: [2]c.VkCommandBuffer = undefined;
    var cb_count: u32 = 0;

    if (ctx.transfer_ready) {
        command_buffers[cb_count] = transfer_cb;
        cb_count += 1;
    }
    command_buffers[cb_count] = command_buffer;
    cb_count += 1;

    submit_info.commandBufferCount = cb_count;
    submit_info.pCommandBuffers = &command_buffers[0];

    const signal_semaphores = [_]c.VkSemaphore{ctx.render_finished_semaphores[ctx.current_sync_frame]};
    submit_info.signalSemaphoreCount = 1;
    submit_info.pSignalSemaphores = &signal_semaphores;

    _ = c.vkQueueSubmit(ctx.queue, 1, &submit_info, ctx.in_flight_fences[ctx.current_sync_frame]);

    var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
    present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = &signal_semaphores;

    const swapchains = [_]c.VkSwapchainKHR{ctx.swapchain};
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &swapchains;
    present_info.pImageIndices = &ctx.image_index;

    const result = c.vkQueuePresentKHR(ctx.queue, &present_info);

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or ctx.framebuffer_resized) {
        ctx.framebuffer_resized = false;
        recreateSwapchain(ctx);
    }

    ctx.transfer_ready = false;
    ctx.current_sync_frame = (ctx.current_sync_frame + 1) % MAX_FRAMES_IN_FLIGHT;
    ctx.frame_index += 1;
    ctx.frame_in_progress = false;
}

fn setClearColor(ctx_ptr: *anyopaque, color: Vec3) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const r = if (std.math.isFinite(color.x)) color.x else 0.0;
    const g = if (std.math.isFinite(color.y)) color.y else 0.0;
    const b = if (std.math.isFinite(color.z)) color.z else 0.0;
    ctx.clear_color = .{ r, g, b, 1.0 };
}

fn transitionShadowImage(ctx: *VulkanContext, cascade_index: u32, new_layout: c.VkImageLayout) void {
    if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return;
    if (ctx.shadow_images[cascade_index] == null) return;

    const old_layout = ctx.shadow_image_layouts[cascade_index];
    if (old_layout == new_layout) return;

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    // Always use UNDEFINED as old layout when going to ATTACHMENT_OPTIMAL to avoid layout mismatch errors
    barrier.oldLayout = if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) c.VK_IMAGE_LAYOUT_UNDEFINED else old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = ctx.shadow_images[cascade_index];
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;

    var src_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    var dst_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;

    if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) {
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        dst_stage = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    } else if (old_layout == c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL and new_layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
        barrier.srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        src_stage = c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        dst_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    }

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    ctx.shadow_image_layouts[cascade_index] = new_layout;
}

fn beginMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress or ctx.main_pass_active) return;

    if (ctx.shadow_pass_active) {
        endShadowPass(ctx_ptr);
    }

    ctx.terrain_pipeline_bound = false;

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.render_pass;
    render_pass_info.framebuffer = ctx.swapchain_framebuffers.items[ctx.image_index];
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.swapchain_extent;

    var clear_values: [3]c.VkClearValue = undefined;
    clear_values[0] = .{ .color = .{ .float32 = ctx.clear_color } };
    clear_values[1] = .{ .depthStencil = .{ .depth = 0.0, .stencil = 0 } };

    if (ctx.msaa_samples > 1) {
        // For MSAA, we have 3 attachments, but only the first two (MSAA color/depth) need clearing.
        // The third (resolve) is overwritten. However, some drivers expect a clear value for each attachment.
        clear_values[2] = .{ .color = .{ .float32 = ctx.clear_color } };
        render_pass_info.clearValueCount = 3;
    } else {
        render_pass_info.clearValueCount = 2;
    }
    render_pass_info.pClearValues = &clear_values[0];

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(ctx.swapchain_extent.width);
    viewport.height = @floatFromInt(ctx.swapchain_extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.swapchain_extent;
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    ctx.main_pass_active = true;
}

fn endMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.main_pass_active) return;
    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.main_pass_active = false;
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vk_device);
    }
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    if (ctx.shadow_pass_active) {
        ctx.shadow_pass_matrix = view_proj;
        return;
    }

    ctx.current_view_proj = view_proj;

    const uniforms = GlobalUniforms{
        .view_proj = view_proj,
        .cam_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0 },
        .sun_dir = .{ sun_dir.x, sun_dir.y, sun_dir.z, 0 },
        .fog_color = .{ fog_color.x, fog_color.y, fog_color.z, 1 },
        .time = time_val,
        .fog_density = fog_density,
        .fog_enabled = if (fog_enabled) 1.0 else 0.0,
        .sun_intensity = sun_intensity,
        .ambient = ambient,
        .use_texture = if (use_texture) 1.0 else 0.0,
        .cloud_wind_offset = .{ cloud_params.wind_offset_x, cloud_params.wind_offset_z },
        .cloud_scale = cloud_params.cloud_scale,
        .cloud_coverage = cloud_params.cloud_coverage,
        .cloud_shadow_strength = 0.15,
        .cloud_height = cloud_params.cloud_height,
        .padding = .{ 0, 0 },
    };

    var map_ptr: ?*anyopaque = null;
    const global_ubo = ctx.global_ubos[ctx.current_sync_frame];
    if (c.vkMapMemory(ctx.vk_device, global_ubo.memory, 0, @sizeOf(GlobalUniforms), 0, &map_ptr) == c.VK_SUCCESS) {
        const mapped: *GlobalUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = uniforms;
        c.vkUnmapMemory(ctx.vk_device, global_ubo.memory);
    }
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4, mask_radius: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.current_model = model;
    ctx.current_mask_radius = mask_radius;
}

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.textures_enabled = texture_enabled;
    // Force descriptor update so internal shadow maps are bound even if handles are 0
    ctx.descriptors_updated = false;

    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        if (shadow_map_handles[i] != 0) {
            if (ctx.textures.get(shadow_map_handles[i])) |tex| {
                ctx.shadow_image_views[i] = tex.view;
            }
        }
    }
}

fn drawClouds(ctx_ptr: *anyopaque, params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);

    // Use dedicated cloud pipeline
    if (ctx.cloud_pipeline == null) return;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    // Bind cloud pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.cloud_pipeline);
    ctx.terrain_pipeline_bound = false;

    // CloudPushConstants: mat4 view_proj + 4 vec4s = 128 bytes
    const CloudPushConstants = extern struct {
        view_proj: [4][4]f32,
        camera_pos: [4]f32, // xyz = camera position, w = cloud_height
        cloud_params: [4]f32, // x = coverage, y = scale, z = wind_offset_x, w = wind_offset_z
        sun_params: [4]f32, // xyz = sun_dir, w = sun_intensity
        fog_params: [4]f32, // xyz = fog_color, w = fog_density
    };

    const pc = CloudPushConstants{
        .view_proj = params.view_proj.data,
        .camera_pos = .{ params.cam_pos.x, params.cam_pos.y, params.cam_pos.z, params.cloud_height },
        .cloud_params = .{ params.cloud_coverage, params.cloud_scale, params.wind_offset_x, params.wind_offset_z },
        .sun_params = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, params.sun_intensity },
        .fog_params = .{ params.fog_color.x, params.fog_color.y, params.fog_color.z, params.fog_density },
    };

    c.vkCmdPushConstants(command_buffer, ctx.cloud_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(CloudPushConstants), &pc);

    // Bind cloud mesh
    const offset: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ctx.cloud_vbo.buffer, &offset);
    c.vkCmdBindIndexBuffer(command_buffer, ctx.cloud_ebo.buffer, 0, c.VK_INDEX_TYPE_UINT16);
    c.vkCmdDrawIndexed(command_buffer, 6, 1, 0, 0, 0);
}

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);

    // Use dedicated debug shadow pipeline if available
    if (ctx.debug_shadow_pipeline == null) return;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    // Bind debug shadow pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow_pipeline);
    ctx.terrain_pipeline_bound = false;

    // Set up orthographic projection for UI-sized quad
    const debug_size: f32 = 200.0;
    const debug_spacing: f32 = 10.0;
    const debug_x: f32 = debug_spacing + @as(f32, @floatFromInt(cascade_index)) * (debug_size + debug_spacing);
    const debug_y: f32 = debug_spacing;

    const width_f32 = @as(f32, @floatFromInt(ctx.swapchain_extent.width));
    const height_f32 = @as(f32, @floatFromInt(ctx.swapchain_extent.height));
    const proj = Mat4.orthographic(0, width_f32, height_f32, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.debug_shadow_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    // Update descriptor set with the depth texture
    ctx.mutex.lock();
    const tex_entry = ctx.textures.get(depth_map_handle);
    ctx.mutex.unlock();

    if (tex_entry) |tex| {
        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        image_info.imageView = tex.view;
        image_info.sampler = tex.sampler;

        var write_set = std.mem.zeroes(c.VkWriteDescriptorSet);
        write_set.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write_set.dstSet = ctx.debug_shadow_descriptor_sets[ctx.current_sync_frame];
        write_set.dstBinding = 0;
        write_set.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write_set.descriptorCount = 1;
        write_set.pImageInfo = &image_info;

        c.vkUpdateDescriptorSets(ctx.vk_device, 1, &write_set, 0, null);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow_pipeline_layout, 0, 1, &ctx.debug_shadow_descriptor_sets[ctx.current_sync_frame], 0, null);
    }

    // Create debug quad vertices (position + texCoord) - 4 floats per vertex
    const debug_vertices = [_]f32{
        // pos.x, pos.y, uv.x, uv.y
        debug_x,              debug_y,              0.0, 0.0,
        debug_x + debug_size, debug_y,              1.0, 0.0,
        debug_x + debug_size, debug_y + debug_size, 1.0, 1.0,
        debug_x,              debug_y,              0.0, 0.0,
        debug_x + debug_size, debug_y + debug_size, 1.0, 1.0,
        debug_x,              debug_y + debug_size, 0.0, 1.0,
    };

    // Map and copy vertices to debug shadow VBO
    var map_ptr: ?*anyopaque = null;
    if (c.vkMapMemory(ctx.vk_device, ctx.debug_shadow_vbo.memory, 0, @sizeOf(@TypeOf(debug_vertices)), 0, &map_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(map_ptr.?))[0..@sizeOf(@TypeOf(debug_vertices))], std.mem.asBytes(&debug_vertices));
        c.vkUnmapMemory(ctx.vk_device, ctx.debug_shadow_vbo.memory);

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ctx.debug_shadow_vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, 6, 1, 0, 0);
    }
}

fn createTexture(ctx_ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    // Map TextureFormat to VkFormat
    const vk_format: c.VkFormat = switch (format) {
        .rgba => c.VK_FORMAT_R8G8B8A8_UNORM,
        .rgb => c.VK_FORMAT_R8G8B8_UNORM,
        .red => c.VK_FORMAT_R8_UNORM,
        .depth => c.VK_FORMAT_D32_SFLOAT,
    };

    // Calculate mip levels
    const mip_levels: u32 = if (config.generate_mipmaps and format != .depth)
        @as(u32, @intFromFloat(@floor(std.math.log2(@as(f32, @floatFromInt(@max(width, height))))))) + 1
    else
        1;

    // Determine image aspect mask based on format
    const aspect_mask: c.VkImageAspectFlags = if (format == .depth)
        c.VK_IMAGE_ASPECT_DEPTH_BIT
    else
        c.VK_IMAGE_ASPECT_COLOR_BIT;

    // Determine usage flags based on format
    var usage_flags: c.VkImageUsageFlags = if (format == .depth)
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT
    else
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;

    if (mip_levels > 1) {
        usage_flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    }

    var image: c.VkImage = null;
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = 1;
    image_info.mipLevels = mip_levels;
    image_info.arrayLayers = 1;
    image_info.format = vk_format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = usage_flags;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    if (c.vkCreateImage(ctx.vk_device, &image_info, null, &image) != c.VK_SUCCESS) return 0;

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vk_device, image, &mem_reqs);

    var memory: c.VkDeviceMemory = null;
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = findMemoryType(ctx.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    if (c.vkAllocateMemory(ctx.vk_device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
        c.vkDestroyImage(ctx.vk_device, image, null);
        return 0;
    }
    if (c.vkBindImageMemory(ctx.vk_device, image, memory, 0) != c.VK_SUCCESS) {
        c.vkFreeMemory(ctx.vk_device, memory, null);
        c.vkDestroyImage(ctx.vk_device, image, null);
        return 0;
    }

    if (data_opt) |data| {
        ensureFrameReady(ctx);
        const staging = &ctx.staging_buffers[ctx.current_sync_frame];
        const offset = staging.allocate(data.len);

        if (offset) |off| {
            // Async Path
            const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + off;
            @memcpy(dest[0..data.len], data);

            const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];

            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = image;
            barrier.subresourceRange.aspectMask = aspect_mask;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = mip_levels;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

            var region = std.mem.zeroes(c.VkBufferImageCopy);
            region.bufferOffset = off;
            region.imageSubresource.aspectMask = aspect_mask;
            region.imageSubresource.layerCount = 1;
            region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

            c.vkCmdCopyBufferToImage(transfer_cb, staging.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            if (mip_levels > 1) {
                // Generate mipmaps
                var mip_width: i32 = @intCast(width);
                var mip_height: i32 = @intCast(height);

                for (1..mip_levels) |i| {
                    barrier.subresourceRange.baseMipLevel = @intCast(i - 1);
                    barrier.subresourceRange.levelCount = 1;
                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;

                    c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    var blit = std.mem.zeroes(c.VkImageBlit);
                    blit.srcOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.srcOffsets[1] = .{ .x = mip_width, .y = mip_height, .z = 1 };
                    blit.srcSubresource.aspectMask = aspect_mask;
                    blit.srcSubresource.mipLevel = @intCast(i - 1);
                    blit.srcSubresource.baseArrayLayer = 0;
                    blit.srcSubresource.layerCount = 1;

                    const next_width = if (mip_width > 1) @divFloor(mip_width, 2) else 1;
                    const next_height = if (mip_height > 1) @divFloor(mip_height, 2) else 1;

                    blit.dstOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.dstOffsets[1] = .{ .x = next_width, .y = next_height, .z = 1 };
                    blit.dstSubresource.aspectMask = aspect_mask;
                    blit.dstSubresource.mipLevel = @intCast(i);
                    blit.dstSubresource.baseArrayLayer = 0;
                    blit.dstSubresource.layerCount = 1;

                    c.vkCmdBlitImage(transfer_cb, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, c.VK_FILTER_LINEAR);

                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                    c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    mip_width = next_width;
                    mip_height = next_height;
                }

                // Transition last mip level
                barrier.subresourceRange.baseMipLevel = mip_levels - 1;
                barrier.subresourceRange.levelCount = 1;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            } else {
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            }
        } else {
            // Fallback (Sync)
            const staging_buffer = createVulkanBuffer(ctx, data.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            defer {
                c.vkDestroyBuffer(ctx.vk_device, staging_buffer.buffer, null);
                c.vkFreeMemory(ctx.vk_device, staging_buffer.memory, null);
            }

            var map_ptr: ?*anyopaque = null;
            if (c.vkMapMemory(ctx.vk_device, staging_buffer.memory, 0, data.len, 0, &map_ptr) == c.VK_SUCCESS) {
                @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
                c.vkUnmapMemory(ctx.vk_device, staging_buffer.memory);
            }

            // Alloc temp command buffer
            var temp_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
            temp_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            temp_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            temp_alloc_info.commandPool = ctx.transfer_command_pool;
            temp_alloc_info.commandBufferCount = 1;

            var temp_cb: c.VkCommandBuffer = null;
            _ = c.vkAllocateCommandBuffers(ctx.vk_device, &temp_alloc_info, &temp_cb);

            var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
            begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

            _ = c.vkBeginCommandBuffer(temp_cb, &begin_info);

            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = image;
            barrier.subresourceRange.aspectMask = aspect_mask;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = mip_levels;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

            c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

            var region = std.mem.zeroes(c.VkBufferImageCopy);
            region.imageSubresource.aspectMask = aspect_mask;
            region.imageSubresource.layerCount = 1;
            region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

            c.vkCmdCopyBufferToImage(temp_cb, staging_buffer.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            if (mip_levels > 1) {
                // Generate mipmaps
                var mip_width: i32 = @intCast(width);
                var mip_height: i32 = @intCast(height);

                for (1..mip_levels) |i| {
                    barrier.subresourceRange.baseMipLevel = @intCast(i - 1);
                    barrier.subresourceRange.levelCount = 1;
                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;

                    c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    var blit = std.mem.zeroes(c.VkImageBlit);
                    blit.srcOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.srcOffsets[1] = .{ .x = mip_width, .y = mip_height, .z = 1 };
                    blit.srcSubresource.aspectMask = aspect_mask;
                    blit.srcSubresource.mipLevel = @intCast(i - 1);
                    blit.srcSubresource.baseArrayLayer = 0;
                    blit.srcSubresource.layerCount = 1;

                    const next_width = if (mip_width > 1) @divFloor(mip_width, 2) else 1;
                    const next_height = if (mip_height > 1) @divFloor(mip_height, 2) else 1;

                    blit.dstOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.dstOffsets[1] = .{ .x = next_width, .y = next_height, .z = 1 };
                    blit.dstSubresource.aspectMask = aspect_mask;
                    blit.dstSubresource.mipLevel = @intCast(i);
                    blit.dstSubresource.baseArrayLayer = 0;
                    blit.dstSubresource.layerCount = 1;

                    c.vkCmdBlitImage(temp_cb, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, c.VK_FILTER_LINEAR);

                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                    c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    mip_width = next_width;
                    mip_height = next_height;
                }

                // Transition last mip level
                barrier.subresourceRange.baseMipLevel = mip_levels - 1;
                barrier.subresourceRange.levelCount = 1;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            } else {
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            }

            _ = c.vkEndCommandBuffer(temp_cb);

            var submit_info = std.mem.zeroes(c.VkSubmitInfo);
            submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
            submit_info.commandBufferCount = 1;
            submit_info.pCommandBuffers = &temp_cb;

            _ = c.vkQueueSubmit(ctx.queue, 1, &submit_info, null);
            _ = c.vkQueueWaitIdle(ctx.queue);

            c.vkFreeCommandBuffers(ctx.vk_device, ctx.transfer_command_pool, 1, &temp_cb);
        }
    } else {
        // Transition from UNDEFINED to SHADER_READ_ONLY_OPTIMAL directly
        // This is fast enough to do on the main command buffer usually, but we use transfer CB to be safe with image layout transitions.
        // Actually this block uses a temporary command buffer too in the old code.
        // We should use the async transfer buffer if possible.

        ensureFrameReady(ctx);
        const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = aspect_mask;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = mip_levels;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    var view: c.VkImageView = null;
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = aspect_mask;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    _ = c.vkCreateImageView(ctx.vk_device, &view_info, null, &view);

    const sampler: c.VkSampler = createSampler(ctx, config, mip_levels);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const handle = ctx.next_texture_handle;
    ctx.next_texture_handle += 1;
    ctx.textures.put(handle, .{ .image = image, .memory = memory, .view = view, .sampler = sampler, .width = width, .height = height, .format = format, .config = config }) catch return 0;

    return handle;
}

fn destroyTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    const entry_opt = ctx.textures.fetchRemove(handle);
    ctx.mutex.unlock();

    if (entry_opt) |entry| {
        c.vkDestroySampler(ctx.vk_device, entry.value.sampler, null);
        c.vkDestroyImageView(ctx.vk_device, entry.value.view, null);
        c.vkFreeMemory(ctx.vk_device, entry.value.memory, null);
        c.vkDestroyImage(ctx.vk_device, entry.value.image, null);
    }
}

fn bindTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    _ = slot;
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.current_texture = handle;
}

fn updateTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    ctx.mutex.lock();
    const tex_opt = ctx.textures.get(handle);
    ctx.mutex.unlock();

    const tex = tex_opt orelse return;

    ensureFrameReady(ctx);
    const staging = &ctx.staging_buffers[ctx.current_sync_frame];

    if (staging.allocate(data.len)) |offset| {
        // Async Path
        const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + offset;
        @memcpy(dest[0..data.len], data);

        const transfer_cb = ctx.transfer_command_buffers[ctx.current_sync_frame];

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.image = tex.image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.bufferOffset = offset;
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = tex.width, .height = tex.height, .depth = 1 };

        c.vkCmdCopyBufferToImage(transfer_cb, staging.buffer, tex.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    } else {
        // Fallback (Sync)
        const staging_buffer = createVulkanBuffer(ctx, data.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        defer {
            c.vkDestroyBuffer(ctx.vk_device, staging_buffer.buffer, null);
            c.vkFreeMemory(ctx.vk_device, staging_buffer.memory, null);
        }

        var map_ptr: ?*anyopaque = null;
        if (c.vkMapMemory(ctx.vk_device, staging_buffer.memory, 0, data.len, 0, &map_ptr) == c.VK_SUCCESS) {
            @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
            c.vkUnmapMemory(ctx.vk_device, staging_buffer.memory);
        }

        // Alloc temp command buffer
        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandPool = ctx.transfer_command_pool;
        alloc_info.commandBufferCount = 1;

        var temp_cb: c.VkCommandBuffer = null;
        _ = c.vkAllocateCommandBuffers(ctx.vk_device, &alloc_info, &temp_cb);

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

        _ = c.vkBeginCommandBuffer(temp_cb, &begin_info);

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.image = tex.image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

        c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = tex.width, .height = tex.height, .depth = 1 };

        c.vkCmdCopyBufferToImage(temp_cb, staging_buffer.buffer, tex.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(temp_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

        _ = c.vkEndCommandBuffer(temp_cb);

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &temp_cb;

        _ = c.vkQueueSubmit(ctx.queue, 1, &submit_info, null);
        _ = c.vkQueueWaitIdle(ctx.queue);

        c.vkFreeCommandBuffers(ctx.vk_device, ctx.transfer_command_pool, 1, &temp_cb);
    }
}

fn setViewport(ctx_ptr: *anyopaque, width: u32, height: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(width);
    viewport.height = @floatFromInt(height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = .{ .width = width, .height = height };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

fn getAllocator(ctx_ptr: *anyopaque) std.mem.Allocator {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.allocator;
}

fn setWireframe(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.wireframe_enabled != enabled) {
        ctx.wireframe_enabled = enabled;
        // Force pipeline rebind next draw
        ctx.terrain_pipeline_bound = false;
    }
}

fn setTexturesEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.textures_enabled = enabled;
    // Texture toggle is handled in shader via UBO uniform
}

fn setVSync(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.vsync_enabled == enabled) return;

    ctx.vsync_enabled = enabled;

    // Query available present modes
    var mode_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &mode_count, null);

    if (mode_count == 0) return;

    var modes: [8]c.VkPresentModeKHR = undefined;
    var actual_count: u32 = @min(mode_count, 8);
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &actual_count, &modes);

    // Select present mode based on vsync preference
    if (enabled) {
        // VSync ON: FIFO is always available
        ctx.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
    } else {
        // VSync OFF: Prefer IMMEDIATE, fallback to MAILBOX, then FIFO
        ctx.present_mode = c.VK_PRESENT_MODE_FIFO_KHR; // Default fallback
        for (modes[0..actual_count]) |mode| {
            if (mode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
                ctx.present_mode = c.VK_PRESENT_MODE_IMMEDIATE_KHR;
                break;
            } else if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                ctx.present_mode = c.VK_PRESENT_MODE_MAILBOX_KHR;
                // Don't break, keep looking for IMMEDIATE
            }
        }
    }

    // Trigger swapchain recreation on next frame
    ctx.framebuffer_resized = true;

    const mode_name: []const u8 = switch (ctx.present_mode) {
        c.VK_PRESENT_MODE_IMMEDIATE_KHR => "IMMEDIATE (VSync OFF)",
        c.VK_PRESENT_MODE_MAILBOX_KHR => "MAILBOX (Triple Buffer)",
        c.VK_PRESENT_MODE_FIFO_KHR => "FIFO (VSync ON)",
        c.VK_PRESENT_MODE_FIFO_RELAXED_KHR => "FIFO_RELAXED",
        else => "UNKNOWN",
    };
    std.log.info("Vulkan present mode: {s}", .{mode_name});
}

fn setAnisotropicFiltering(ctx_ptr: *anyopaque, level: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const clamped = @min(level, @as(u8, @intFromFloat(ctx.max_anisotropy)));
    if (ctx.anisotropic_filtering == clamped) return;

    ctx.anisotropic_filtering = clamped;

    // Apply immediately: recreate all texture samplers
    _ = c.vkDeviceWaitIdle(ctx.vk_device);
    var it = ctx.textures.iterator();
    while (it.next()) |entry| {
        const tex = entry.value_ptr;
        c.vkDestroySampler(ctx.vk_device, tex.sampler, null);

        const mip_levels: u32 = if (tex.config.generate_mipmaps)
            @as(u32, @intFromFloat(@floor(std.math.log2(@as(f32, @floatFromInt(@max(tex.width, tex.height))))))) + 1
        else
            1;
        tex.sampler = createSampler(ctx, tex.config, mip_levels);
    }
    std.log.info("Vulkan anisotropic filtering set to {}x (applied to {} textures)", .{ clamped, ctx.textures.count() });
}

fn setMSAA(ctx_ptr: *anyopaque, samples: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const clamped = @min(samples, ctx.max_msaa_samples);
    if (ctx.msaa_samples == clamped) return;

    ctx.msaa_samples = clamped;
    ctx.framebuffer_resized = true; // Triggers recreateSwapchain on next frame
    std.log.info("Vulkan MSAA set to {}x (pending swapchain recreation)", .{clamped});
}

fn getMaxAnisotropy(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromFloat(@min(ctx.max_anisotropy, 16.0));
}

fn getMaxMSAASamples(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.max_msaa_samples;
}

fn drawIndirect(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    // Simple implementation for single draw or MDI if shader supports it
    // For now, this is a placeholder that assumes the pipeline is bound

    ctx.mutex.lock();
    const vbo_opt = ctx.buffers.get(handle);
    const cmd_opt = ctx.buffers.get(command_buffer);
    ctx.mutex.unlock();

    if (vbo_opt) |vbo| {
        if (cmd_opt) |cmd| {
            ctx.draw_call_count += 1;
            const cb = ctx.command_buffers[ctx.current_sync_frame];
            const offset_vals = [_]c.VkDeviceSize{0};
            c.vkCmdBindVertexBuffers(cb, 0, 1, &vbo.buffer, &offset_vals);
            c.vkCmdDrawIndirect(cb, cmd.buffer, @intCast(offset), draw_count, stride);
        }
    }
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    drawOffset(ctx_ptr, handle, count, mode, 0);
}

fn drawOffset(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active and !ctx.shadow_pass_active) beginMainPass(ctx_ptr);

    _ = mode;

    const use_shadow = ctx.shadow_pass_active;

    ctx.mutex.lock();
    const vbo_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (vbo_opt) |vbo| {
        ctx.draw_call_count += 1;

        const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

        // Bind pipeline only if not already bound
        if (use_shadow) {
            if (!ctx.shadow_pipeline_bound) {
                if (ctx.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_pipeline);
                c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.descriptor_sets[ctx.current_sync_frame], 0, null);
                ctx.shadow_pipeline_bound = true;
            }
        } else {
            if (!ctx.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                    ctx.wireframe_pipeline
                else
                    ctx.pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);

                if (!ctx.descriptors_updated or ctx.current_texture != ctx.bound_texture) {
                    ctx.mutex.lock();
                    const tex_opt = ctx.textures.get(ctx.current_texture);
                    ctx.mutex.unlock();

                    if (tex_opt) |tex| {
                        var image_info = c.VkDescriptorImageInfo{
                            .sampler = tex.sampler,
                            .imageView = tex.view,
                            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        };

                        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
                        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                        write.dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
                        write.dstBinding = 1;
                        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                        write.descriptorCount = 1;
                        write.pImageInfo = &image_info;

                        c.vkUpdateDescriptorSets(ctx.vk_device, 1, &write, 0, null);
                    }

                    if (!ctx.descriptors_updated) {
                        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
                            var view = ctx.shadow_image_views[i];
                            if (view == null) {
                                ctx.mutex.lock();
                                const t = ctx.textures.get(ctx.current_texture);
                                ctx.mutex.unlock();
                                if (t) |tex| view = tex.view;
                            }
                            if (view == null) view = ctx.dummy_shadow_view;
                            if (view == null) continue;

                            var image_info = c.VkDescriptorImageInfo{
                                .sampler = ctx.shadow_sampler,
                                .imageView = view,
                                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                            };
                            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
                            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                            write.dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
                            write.dstBinding = @intCast(3 + i);
                            write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                            write.descriptorCount = 1;
                            write.pImageInfo = &image_info;
                            c.vkUpdateDescriptorSets(ctx.vk_device, 1, &write, 0, null);
                        }
                    }

                    ctx.descriptors_updated = true;
                    ctx.bound_texture = ctx.current_texture;
                }

                c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.descriptor_sets[ctx.current_sync_frame], 0, null);
                ctx.terrain_pipeline_bound = true;
            }
        }

        const uniforms = ModelUniforms{
            .view_proj = if (use_shadow) ctx.shadow_pass_matrix else ctx.current_view_proj,
            .model = ctx.current_model,
            .mask_radius = ctx.current_mask_radius,
            .padding = .{ 0, 0, 0 },
        };
        c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);

        const offset_vbo: c.VkDeviceSize = @intCast(offset);
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset_vbo);
        c.vkCmdDraw(command_buffer, count, 1, 0, 0);
    }
}

fn flushUI(ctx: *VulkanContext) void {
    if (ctx.ui_vertex_offset / (6 * @sizeOf(f32)) > ctx.ui_flushed_vertex_count) {
        const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

        const total_vertices: u32 = @intCast(ctx.ui_vertex_offset / (6 * @sizeOf(f32)));
        const count = total_vertices - ctx.ui_flushed_vertex_count;

        c.vkCmdDraw(command_buffer, count, 1, ctx.ui_flushed_vertex_count, 0);
        ctx.ui_flushed_vertex_count = total_vertices;
    }
}

// UI Rendering functions
fn beginUI(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);

    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;
    ctx.ui_in_progress = true;
    ctx.ui_vertex_offset = 0;
    ctx.ui_flushed_vertex_count = 0;

    // Map current frame's UI VBO memory
    const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
    if (c.vkMapMemory(ctx.vk_device, ui_vbo.memory, 0, ui_vbo.size, 0, &ctx.ui_mapped_ptr) != c.VK_SUCCESS) {
        std.log.err("Failed to map UI VBO memory!", .{});
        ctx.ui_mapped_ptr = null;
    }

    // Bind UI pipeline and VBO
    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_pipeline);
    ctx.terrain_pipeline_bound = false;

    const offset: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ui_vbo.buffer, &offset);

    // Set orthographic projection
    const proj = Mat4.orthographic(0, ctx.ui_screen_width, ctx.ui_screen_height, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
}

fn endUI(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.ui_in_progress) return;

    if (ctx.ui_mapped_ptr != null) {
        const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
        c.vkUnmapMemory(ctx.vk_device, ui_vbo.memory);
        ctx.ui_mapped_ptr = null;
    }

    flushUI(ctx);
    ctx.ui_in_progress = false;
}

fn drawUIQuad(ctx_ptr: *anyopaque, rect: rhi.Rect, color: rhi.Color) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    // Two triangles forming a quad - 6 vertices
    const vertices = [_]f32{
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y + h, color.r, color.g, color.b, color.a,
    };

    const size = @sizeOf(@TypeOf(vertices));

    // Check overflow
    const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
    if (ctx.ui_vertex_offset + size > ui_vbo.size) {
        return;
    }

    if (ctx.ui_mapped_ptr) |ptr| {
        const dest = @as([*]u8, @ptrCast(ptr)) + ctx.ui_vertex_offset;
        @memcpy(dest[0..size], std.mem.asBytes(&vertices));
        ctx.ui_vertex_offset += size;
    }
}

fn drawUITexturedQuad(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress or !ctx.ui_in_progress) return;

    // 1. Flush normal UI if any
    flushUI(ctx);

    const tex_opt = ctx.textures.get(texture);
    if (tex_opt == null) {
        std.log.err("drawUITexturedQuad: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    // 2. Bind Textured UI Pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline);
    ctx.terrain_pipeline_bound = false;

    // 3. Update & Bind Descriptor Set
    var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
    image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    image_info.imageView = tex.view;
    image_info.sampler = tex.sampler;

    var write = std.mem.zeroes(c.VkWriteDescriptorSet);
    write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = ctx.ui_tex_descriptor_sets[ctx.current_sync_frame];
    write.dstBinding = 0;
    write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.descriptorCount = 1;
    write.pImageInfo = &image_info;

    c.vkUpdateDescriptorSets(ctx.vk_device, 1, &write, 0, null);
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline_layout, 0, 1, &ctx.ui_tex_descriptor_sets[ctx.current_sync_frame], 0, null);

    // 4. Set Push Constants (Projection)
    const proj = Mat4.orthographic(0, ctx.ui_screen_width, ctx.ui_screen_height, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.ui_tex_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    // 5. Draw
    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    // Use 6 floats per vertex (stride 24) to match untextured UI layout
    // position (2), texcoord (2), padding (2)
    const vertices = [_]f32{
        x,     y,     0.0, 0.0, 0.0, 0.0,
        x + w, y,     1.0, 0.0, 0.0, 0.0,
        x + w, y + h, 1.0, 1.0, 0.0, 0.0,
        x,     y,     0.0, 0.0, 0.0, 0.0,
        x + w, y + h, 1.0, 1.0, 0.0, 0.0,
        x,     y + h, 0.0, 1.0, 0.0, 0.0,
    };

    const size = @sizeOf(@TypeOf(vertices));
    if (ctx.ui_mapped_ptr) |ptr| {
        const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
        if (ctx.ui_vertex_offset + size <= ui_vbo.size) {
            const dest = @as([*]u8, @ptrCast(ptr)) + ctx.ui_vertex_offset;
            @memcpy(dest[0..size], std.mem.asBytes(&vertices));

            const start_vertex = @as(u32, @intCast(ctx.ui_vertex_offset / (6 * @sizeOf(f32))));
            c.vkCmdDraw(command_buffer, 6, 1, start_vertex, 0);

            ctx.ui_vertex_offset += size;
            ctx.ui_flushed_vertex_count = @intCast(ctx.ui_vertex_offset / (6 * @sizeOf(f32)));
        }
    }

    // 6. Restore normal UI state for subsequent calls
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_pipeline);
}

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return;

    if (ctx.main_pass_active) {
        endMainPass(ctx_ptr);
    }
    if (ctx.shadow_pass_active) {
        endShadowPass(ctx_ptr);
    }

    // Reset pipeline state when switching passes
    ctx.shadow_pipeline_bound = false;

    if (ctx.shadow_framebuffers[cascade_index] == null) return;

    // Render pass handles transition from UNDEFINED to DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    ctx.shadow_image_layouts[cascade_index] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.shadow_render_pass;
    render_pass_info.framebuffer = ctx.shadow_framebuffers[cascade_index];
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.shadow_extent;

    var clear_value = std.mem.zeroes(c.VkClearValue);
    clear_value.depthStencil = .{ .depth = 0.0, .stencil = 0 }; // Reverse-Z: clear to 0.0 (far plane)
    render_pass_info.clearValueCount = 1;
    render_pass_info.pClearValues = &clear_value;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

    // Set depth bias for shadow mapping to prevent shadow acne
    c.vkCmdSetDepthBias(command_buffer, 1.25, 0.0, 1.75);

    ctx.shadow_pass_active = true;
    ctx.shadow_pass_index = cascade_index;
    ctx.shadow_pass_matrix = Mat4.identity;

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(ctx.shadow_extent.width);
    viewport.height = @floatFromInt(ctx.shadow_extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.shadow_extent;
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

fn endShadowPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.shadow_pass_active) return;
    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    c.vkCmdEndRenderPass(command_buffer);
    const cascade_index = ctx.shadow_pass_index;
    ctx.shadow_pass_active = false;

    // Render pass handles transition to SHADER_READ_ONLY_OPTIMAL
    ctx.shadow_image_layouts[cascade_index] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    var splits = [_]f32{ 0, 0, 0, 0 };
    var sizes = [_]f32{ 0, 0, 0, 0 };
    @memcpy(splits[0..rhi.SHADOW_CASCADE_COUNT], &params.cascade_splits);
    @memcpy(sizes[0..rhi.SHADOW_CASCADE_COUNT], &params.shadow_texel_sizes);

    const shadow_uniforms = ShadowUniforms{
        .light_space_matrices = params.light_space_matrices,
        .cascade_splits = splits,
        .shadow_texel_sizes = sizes,
    };

    var map_ptr: ?*anyopaque = null;
    const shadow_ubo = ctx.shadow_ubos[ctx.current_sync_frame];
    if (c.vkMapMemory(ctx.vk_device, shadow_ubo.memory, 0, @sizeOf(ShadowUniforms), 0, &map_ptr) == c.VK_SUCCESS) {
        const mapped: *ShadowUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = shadow_uniforms;
        c.vkUnmapMemory(ctx.vk_device, shadow_ubo.memory);
    }
}

fn drawSky(ctx_ptr: *anyopaque, params: rhi.SkyParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);

    if (ctx.sky_pipeline == null) return;

    const pc = SkyPushConstants{
        .cam_forward = .{ params.cam_forward.x, params.cam_forward.y, params.cam_forward.z, 0.0 },
        .cam_right = .{ params.cam_right.x, params.cam_right.y, params.cam_right.z, 0.0 },
        .cam_up = .{ params.cam_up.x, params.cam_up.y, params.cam_up.z, 0.0 },
        .sun_dir = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, 0.0 },
        .sky_color = .{ params.sky_color.x, params.sky_color.y, params.sky_color.z, 1.0 },
        .horizon_color = .{ params.horizon_color.x, params.horizon_color.y, params.horizon_color.z, 1.0 },
        .params = .{ params.aspect, params.tan_half_fov, params.sun_intensity, params.moon_intensity },
        .time = .{ params.time, params.cam_pos.x, params.cam_pos.y, params.cam_pos.z },
    };

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.sky_pipeline);
    ctx.terrain_pipeline_bound = false;
    c.vkCmdPushConstants(command_buffer, ctx.sky_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(SkyPushConstants), &pc);
    c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
}

// Shader stub implementations for Vulkan
// Vulkan uses pre-compiled SPIR-V pipelines, so we don't support runtime shader compilation
fn createShader(ctx_ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
    _ = ctx_ptr;
    _ = vertex_src;
    _ = fragment_src;
    return error.VulkanError;
}

fn destroyShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    _ = ctx_ptr;
    _ = handle;
}

fn bindShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    _ = ctx_ptr;
    _ = handle;
}

fn shaderSetMat4(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, matrix: *const [4][4]f32) void {
    _ = ctx_ptr;
    _ = handle;
    _ = name;
    _ = matrix;
}

fn shaderSetVec3(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    _ = ctx_ptr;
    _ = handle;
    _ = name;
    _ = x;
    _ = y;
    _ = z;
}

fn shaderSetFloat(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, value: f32) void {
    _ = ctx_ptr;
    _ = handle;
    _ = name;
    _ = value;
}

fn shaderSetInt(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, value: i32) void {
    _ = ctx_ptr;
    _ = handle;
    _ = name;
    _ = value;
}

const vtable = rhi.RHI.VTable{
    .init = init,
    .deinit = deinit,
    .createBuffer = createBuffer,
    .uploadBuffer = uploadBuffer,
    .updateBuffer = updateBuffer,
    .destroyBuffer = destroyBuffer,
    .createShader = createShader,
    .destroyShader = destroyShader,
    .bindShader = bindShader,
    .shaderSetMat4 = shaderSetMat4,
    .shaderSetVec3 = shaderSetVec3,
    .shaderSetFloat = shaderSetFloat,
    .shaderSetInt = shaderSetInt,
    .beginFrame = beginFrame,
    .abortFrame = abortFrame,
    .setClearColor = setClearColor,
    .beginMainPass = beginMainPass,
    .endMainPass = endMainPass,
    .endFrame = endFrame,
    .waitIdle = waitIdle,
    .beginShadowPass = beginShadowPass,
    .endShadowPass = endShadowPass,
    .setModelMatrix = setModelMatrix,
    .updateGlobalUniforms = updateGlobalUniforms,
    .updateShadowUniforms = updateShadowUniforms,
    .setTextureUniforms = setTextureUniforms,
    .draw = draw,
    .drawOffset = drawOffset,
    .drawIndirect = drawIndirect,
    .drawSky = drawSky,
    .createTexture = createTexture,
    .destroyTexture = destroyTexture,
    .bindTexture = bindTexture,
    .updateTexture = updateTexture,
    .getAllocator = getAllocator,
    .setViewport = setViewport,
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setVSync = setVSync,
    .beginUI = beginUI,
    .endUI = endUI,
    .drawUIQuad = drawUIQuad,
    .drawUITexturedQuad = drawUITexturedQuad,
    .drawClouds = drawClouds,
    .drawDebugShadowMap = drawDebugShadowMap,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setMSAA = setMSAA,
    .getMaxAnisotropy = getMaxAnisotropy,
    .getMaxMSAASamples = getMaxMSAASamples,
};

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    // Initialize all fields to safe defaults
    ctx.allocator = allocator;
    ctx.render_device = render_device;
    ctx.shadow_resolution = shadow_resolution;
    ctx.window = window;
    ctx.instance = null;
    ctx.surface = null;
    ctx.physical_device = null;
    ctx.vk_device = null;
    ctx.queue = null;
    ctx.graphics_family = 0;
    ctx.framebuffer_resized = false;
    ctx.draw_call_count = 0;
    ctx.buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(allocator);
    ctx.next_buffer_handle = 1;
    ctx.textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(allocator);
    ctx.next_texture_handle = 1;
    ctx.current_texture = 0;
    ctx.mutex = .{};
    ctx.swapchain_images = .empty;
    ctx.swapchain_image_views = .empty;
    ctx.swapchain_framebuffers = .empty;
    ctx.clear_color = .{ 0.07, 0.08, 0.1, 1.0 };
    ctx.frame_in_progress = false;
    ctx.main_pass_active = false;
    ctx.shadow_pass_active = false;
    ctx.shadow_pass_index = 0;
    ctx.ui_in_progress = false;
    ctx.ui_mapped_ptr = null;
    ctx.ui_vertex_offset = 0;
    ctx.frame_index = 0;
    ctx.current_sync_frame = 0;
    ctx.image_index = 0;

    // Optimization state tracking
    ctx.terrain_pipeline_bound = false;
    ctx.shadow_pipeline_bound = false;
    ctx.descriptors_updated = false;
    ctx.bound_texture = 0;
    ctx.current_mask_radius = 0;

    // Rendering options
    ctx.wireframe_enabled = false;
    ctx.textures_enabled = true;
    ctx.vsync_enabled = true;
    ctx.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.command_buffers[i] = null;
        ctx.transfer_command_buffers[i] = null;
        ctx.staging_buffers[i] = .{ .buffer = null, .memory = null, .size = 0, .current_offset = 0, .mapped_ptr = null };
    }
    ctx.command_pool = null;
    ctx.transfer_command_pool = null;
    ctx.transfer_ready = false;
    ctx.render_pass = null;
    ctx.swapchain = null;
    ctx.depth_image = null;
    ctx.depth_image_view = null;
    ctx.depth_image_memory = null;
    ctx.msaa_color_image = null;
    ctx.msaa_color_view = null;
    ctx.msaa_color_memory = null;
    ctx.pipeline = null;
    ctx.pipeline_layout = null;
    ctx.wireframe_pipeline = null;
    ctx.shadow_pipeline = null;
    ctx.shadow_render_pass = null;
    ctx.sky_pipeline = null;
    ctx.sky_pipeline_layout = null;
    ctx.ui_pipeline = null;
    ctx.ui_pipeline_layout = null;
    ctx.ui_tex_pipeline = null;
    ctx.ui_tex_pipeline_layout = null;
    ctx.ui_tex_descriptor_set_layout = null;
    ctx.debug_shadow_pipeline = null;
    ctx.debug_shadow_pipeline_layout = null;
    ctx.debug_shadow_descriptor_set_layout = null;
    ctx.debug_shadow_vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_pipeline = null;
    ctx.cloud_pipeline_layout = null;
    ctx.cloud_vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_ebo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_mesh_size = 10000.0;
    ctx.descriptor_pool = null;
    ctx.descriptor_set_layout = null;
    ctx.memory_type_index = 0;
    ctx.anisotropic_filtering = anisotropic_filtering;
    ctx.max_anisotropy = 1.0;
    ctx.msaa_samples = msaa_samples;
    ctx.max_msaa_samples = 1;
    ctx.shadow_sampler = null;
    ctx.shadow_extent = .{ .width = 0, .height = 0 };
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        ctx.shadow_images[i] = null;
        ctx.shadow_image_memory[i] = null;
        ctx.shadow_image_views[i] = null;
        ctx.shadow_framebuffers[i] = null;
        ctx.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.image_available_semaphores[i] = null;
        ctx.render_finished_semaphores[i] = null;
        ctx.in_flight_fences[i] = null;
        ctx.global_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.shadow_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.ui_vbos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptor_sets[i] = null;
        ctx.ui_tex_descriptor_sets[i] = null;
        ctx.debug_shadow_descriptor_sets[i] = null;
        ctx.buffer_deletion_queue[i] = .empty;
    }
    ctx.model_ubo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.ui_screen_width = 0;
    ctx.ui_screen_height = 0;
    ctx.ui_flushed_vertex_count = 0;
    ctx.cloud_vao = null;
    ctx.debug_shadow_vao = null;
    ctx.dummy_shadow_image = null;
    ctx.dummy_shadow_memory = null;
    ctx.dummy_shadow_view = null;

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &vtable,
        .device = render_device,
    };
}
