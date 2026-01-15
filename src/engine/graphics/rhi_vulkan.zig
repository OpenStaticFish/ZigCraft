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
//!
const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const VulkanDevice = @import("vulkan_device.zig").VulkanDevice;
const VulkanSwapchain = @import("vulkan_swapchain.zig").VulkanSwapchain;
const RenderDevice = @import("render_device.zig").RenderDevice;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;
const DEPTH_FORMAT = c.VK_FORMAT_D32_SFLOAT;

/// Global uniform buffer layout (std140). Bound to descriptor set 0, binding 0.
const GlobalUniforms = extern struct {
    view_proj: Mat4, // Combined view-projection matrix
    cam_pos: [4]f32, // Camera world position (w unused)
    sun_dir: [4]f32, // Sun direction (w unused)
    sun_color: [4]f32, // Sun color (w unused)
    fog_color: [4]f32, // Fog RGB (a unused)
    cloud_wind_offset: [4]f32, // xy = offset, z = scale, w = coverage
    params: [4]f32, // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    lighting: [4]f32, // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    cloud_params: [4]f32, // x = cloud_height, y = shadow_samples, z = shadow_blend, w = cloud_shadows
    pbr_params: [4]f32, // x = pbr_quality, y = exposure, z = saturation, w = unused
    volumetric_params: [4]f32, // x = enabled, y = density, z = steps, w = scattering
    viewport_size: [4]f32, // xy = width/height, zw = unused
};

const SSAOParams = extern struct {
    projection: Mat4,
    invProjection: Mat4,
    samples: [64][4]f32,
    radius: f32 = 0.5,
    bias: f32 = 0.025,
    _padding: [2]f32 = undefined,
};

/// Shadow cascade uniforms for CSM. Bound to descriptor set 0, binding 2.
const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32, // vec4 in shader
    shadow_texel_sizes: [4]f32, // vec4 in shader
};

/// Per-draw model matrix, passed via push constants for efficiency.
const ModelUniforms = extern struct {
    model: Mat4,
    mask_radius: f32,
    padding: [3]f32,
};

/// Per-draw shadow matrix and model, passed via push constants.
const ShadowModelUniforms = extern struct {
    light_space_matrix: Mat4,
    model: Mat4,
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
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    size: c.VkDeviceSize = 0,
    is_host_visible: bool = false,
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
        try checkVk(c.vkMapMemory(ctx.vulkan_device.vk_device, buf.memory, 0, size, 0, &mapped));

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
    window: *c.SDL_Window,
    render_device: ?*anyopaque,
    vulkan_device: VulkanDevice,
    vulkan_swapchain: VulkanSwapchain,

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

    // Dummy shadow texture for fallback
    dummy_shadow_image: c.VkImage,
    dummy_shadow_memory: c.VkDeviceMemory,
    dummy_shadow_view: c.VkImageView,

    // Uniforms
    global_ubos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    global_ubos_mapped: [MAX_FRAMES_IN_FLIGHT]?*anyopaque,
    model_ubo: VulkanBuffer,
    dummy_instance_buffer: VulkanBuffer,
    shadow_ubos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    shadow_ubos_mapped: [MAX_FRAMES_IN_FLIGHT]?*anyopaque,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    lod_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,

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
    current_normal_texture: rhi.TextureHandle,
    current_roughness_texture: rhi.TextureHandle,
    current_displacement_texture: rhi.TextureHandle,
    current_env_texture: rhi.TextureHandle,
    dummy_texture: rhi.TextureHandle,
    dummy_normal_texture: rhi.TextureHandle,
    dummy_roughness_texture: rhi.TextureHandle,
    bound_texture: rhi.TextureHandle,
    bound_normal_texture: rhi.TextureHandle,
    bound_roughness_texture: rhi.TextureHandle,
    bound_displacement_texture: rhi.TextureHandle,
    bound_env_texture: rhi.TextureHandle,
    bound_ssao_handle: rhi.TextureHandle = 0,
    bound_shadow_views: [rhi.SHADOW_CASCADE_COUNT]c.VkImageView,
    descriptors_dirty: [MAX_FRAMES_IN_FLIGHT]bool,

    // Rendering options
    wireframe_enabled: bool,
    textures_enabled: bool,
    wireframe_pipeline: c.VkPipeline,
    vsync_enabled: bool,
    present_mode: c.VkPresentModeKHR,
    anisotropic_filtering: u8,
    msaa_samples: u8,

    // SSAO resources
    g_normal_image: c.VkImage = null,
    g_normal_memory: c.VkDeviceMemory = null,
    g_normal_view: c.VkImageView = null,
    g_normal_handle: rhi.TextureHandle = 0,
    g_depth_image: c.VkImage = null, // G-Pass depth (1x sampled for SSAO)
    g_depth_memory: c.VkDeviceMemory = null,
    g_depth_view: c.VkImageView = null,
    ssao_image: c.VkImage = null, // SSAO AO output
    ssao_memory: c.VkDeviceMemory = null,
    ssao_view: c.VkImageView = null,
    ssao_handle: rhi.TextureHandle = 0,
    ssao_blur_image: c.VkImage = null,
    ssao_blur_memory: c.VkDeviceMemory = null,
    ssao_blur_view: c.VkImageView = null,
    ssao_blur_handle: rhi.TextureHandle = 0,
    ssao_noise_image: c.VkImage = null,
    ssao_noise_memory: c.VkDeviceMemory = null,
    ssao_noise_view: c.VkImageView = null,
    ssao_noise_handle: rhi.TextureHandle = 0,
    ssao_kernel_ubo: VulkanBuffer = .{},
    ssao_params: SSAOParams = undefined,
    ssao_sampler: c.VkSampler = null, // Linear sampler for SSAO textures

    // G-Pass & SSAO Passes
    g_render_pass: c.VkRenderPass = null,
    ssao_render_pass: c.VkRenderPass = null,
    ssao_blur_render_pass: c.VkRenderPass = null,
    g_framebuffer: c.VkFramebuffer = null,
    ssao_framebuffer: c.VkFramebuffer = null,
    ssao_blur_framebuffer: c.VkFramebuffer = null,

    // SSAO Pipelines
    g_pipeline: c.VkPipeline = null,
    g_pipeline_layout: c.VkPipelineLayout = null,
    ssao_pipeline: c.VkPipeline = null,
    ssao_pipeline_layout: c.VkPipelineLayout = null,
    ssao_blur_pipeline: c.VkPipeline = null,
    ssao_blur_pipeline_layout: c.VkPipelineLayout = null,
    ssao_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    ssao_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined,
    ssao_blur_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    ssao_blur_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined,

    shadow_resolution: u32,
    memory_type_index: u32,
    framebuffer_resized: bool,
    draw_call_count: u32,
    main_pass_active: bool = false,
    shadow_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,
    shadow_pass_index: u32 = 0,
    frame_in_progress: bool,
    terrain_pipeline_bound: bool,
    shadow_pipeline_bound: bool,
    descriptors_updated: bool,
    lod_mode: bool = false,
    bound_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    bound_lod_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    pending_instance_buffer: rhi.BufferHandle = 0,
    pending_lod_instance_buffer: rhi.BufferHandle = 0,
    shadow_pass_matrix: Mat4,
    current_view_proj: Mat4,
    current_model: Mat4,
    current_mask_radius: f32,
    mutex: std.Thread.Mutex,
    clear_color: [4]f32,

    // Shadow resources
    shadow_image: c.VkImage,
    shadow_image_memory: c.VkDeviceMemory,
    shadow_image_view: c.VkImageView,
    shadow_image_views: [rhi.SHADOW_CASCADE_COUNT]c.VkImageView,
    shadow_image_layouts: [rhi.SHADOW_CASCADE_COUNT]c.VkImageLayout,
    shadow_framebuffers: [rhi.SHADOW_CASCADE_COUNT]c.VkFramebuffer,
    shadow_sampler: c.VkSampler,
    shadow_extent: c.VkExtent2D,

    // UI Pipeline
    ui_pipeline: c.VkPipeline,
    ui_pipeline_layout: c.VkPipelineLayout,
    ui_tex_pipeline: c.VkPipeline,
    ui_tex_pipeline_layout: c.VkPipelineLayout,
    ui_tex_descriptor_set_layout: c.VkDescriptorSetLayout,
    ui_tex_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    ui_tex_descriptor_pool: [MAX_FRAMES_IN_FLIGHT][64]c.VkDescriptorSet,
    ui_tex_descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32,
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
    debug_shadow_descriptor_pool: [MAX_FRAMES_IN_FLIGHT][8]c.VkDescriptorSet,
    debug_shadow_descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32,
    debug_shadow_vbo: VulkanBuffer,
    debug_shadow_vao: c.VkBuffer,
};

fn destroyShadowResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.shadow_pipeline != null) c.vkDestroyPipeline(vk, ctx.shadow_pipeline, null);
    if (ctx.shadow_render_pass != null) c.vkDestroyRenderPass(vk, ctx.shadow_render_pass, null);
    if (ctx.shadow_sampler != null) c.vkDestroySampler(vk, ctx.shadow_sampler, null);
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        if (ctx.shadow_framebuffers[i] != null) c.vkDestroyFramebuffer(vk, ctx.shadow_framebuffers[i], null);
        if (ctx.shadow_image_views[i] != null) c.vkDestroyImageView(vk, ctx.shadow_image_views[i], null);
        ctx.shadow_framebuffers[i] = null;
        ctx.shadow_image_views[i] = null;
    }
    if (ctx.shadow_image_view != null) c.vkDestroyImageView(vk, ctx.shadow_image_view, null);
    if (ctx.shadow_image != null) c.vkDestroyImage(vk, ctx.shadow_image, null);
    if (ctx.shadow_image_memory != null) c.vkFreeMemory(vk, ctx.shadow_image_memory, null);
    ctx.shadow_pipeline = null;
    ctx.shadow_render_pass = null;
    ctx.shadow_sampler = null;
    ctx.shadow_image_view = null;
    ctx.shadow_image = null;
    ctx.shadow_image_memory = null;
}

fn destroyGPassResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.g_pipeline != null) c.vkDestroyPipeline(vk, ctx.g_pipeline, null);
    if (ctx.g_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, ctx.g_pipeline_layout, null);
    if (ctx.g_framebuffer != null) c.vkDestroyFramebuffer(vk, ctx.g_framebuffer, null);
    if (ctx.g_render_pass != null) c.vkDestroyRenderPass(vk, ctx.g_render_pass, null);
    if (ctx.g_normal_view != null) c.vkDestroyImageView(vk, ctx.g_normal_view, null);
    if (ctx.g_normal_image != null) c.vkDestroyImage(vk, ctx.g_normal_image, null);
    if (ctx.g_normal_memory != null) c.vkFreeMemory(vk, ctx.g_normal_memory, null);
    if (ctx.g_depth_view != null) c.vkDestroyImageView(vk, ctx.g_depth_view, null);
    if (ctx.g_depth_image != null) c.vkDestroyImage(vk, ctx.g_depth_image, null);
    if (ctx.g_depth_memory != null) c.vkFreeMemory(vk, ctx.g_depth_memory, null);
    ctx.g_pipeline = null;
    ctx.g_pipeline_layout = null;
    ctx.g_framebuffer = null;
    ctx.g_render_pass = null;
    ctx.g_normal_view = null;
    ctx.g_normal_image = null;
    ctx.g_normal_memory = null;
    ctx.g_depth_view = null;
    ctx.g_depth_image = null;
    ctx.g_depth_memory = null;
}

fn destroySSAOResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.ssao_pipeline != null) c.vkDestroyPipeline(vk, ctx.ssao_pipeline, null);
    if (ctx.ssao_blur_pipeline != null) c.vkDestroyPipeline(vk, ctx.ssao_blur_pipeline, null);
    if (ctx.ssao_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, ctx.ssao_pipeline_layout, null);
    if (ctx.ssao_blur_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, ctx.ssao_blur_pipeline_layout, null);
    if (ctx.ssao_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, ctx.ssao_descriptor_set_layout, null);
    if (ctx.ssao_blur_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, ctx.ssao_blur_descriptor_set_layout, null);
    if (ctx.ssao_framebuffer != null) c.vkDestroyFramebuffer(vk, ctx.ssao_framebuffer, null);
    if (ctx.ssao_blur_framebuffer != null) c.vkDestroyFramebuffer(vk, ctx.ssao_blur_framebuffer, null);
    if (ctx.ssao_render_pass != null) c.vkDestroyRenderPass(vk, ctx.ssao_render_pass, null);
    if (ctx.ssao_blur_render_pass != null) c.vkDestroyRenderPass(vk, ctx.ssao_blur_render_pass, null);
    if (ctx.ssao_view != null) c.vkDestroyImageView(vk, ctx.ssao_view, null);
    if (ctx.ssao_image != null) c.vkDestroyImage(vk, ctx.ssao_image, null);
    if (ctx.ssao_memory != null) c.vkFreeMemory(vk, ctx.ssao_memory, null);
    if (ctx.ssao_blur_view != null) c.vkDestroyImageView(vk, ctx.ssao_blur_view, null);
    if (ctx.ssao_blur_image != null) c.vkDestroyImage(vk, ctx.ssao_blur_image, null);
    if (ctx.ssao_blur_memory != null) c.vkFreeMemory(vk, ctx.ssao_blur_memory, null);
    if (ctx.ssao_noise_view != null) c.vkDestroyImageView(vk, ctx.ssao_noise_view, null);
    if (ctx.ssao_noise_image != null) c.vkDestroyImage(vk, ctx.ssao_noise_image, null);
    if (ctx.ssao_noise_memory != null) c.vkFreeMemory(vk, ctx.ssao_noise_memory, null);
    if (ctx.ssao_kernel_ubo.buffer != null) c.vkDestroyBuffer(vk, ctx.ssao_kernel_ubo.buffer, null);
    if (ctx.ssao_kernel_ubo.memory != null) c.vkFreeMemory(vk, ctx.ssao_kernel_ubo.memory, null);
    if (ctx.ssao_sampler != null) c.vkDestroySampler(vk, ctx.ssao_sampler, null);
    ctx.ssao_pipeline = null;
    ctx.ssao_blur_pipeline = null;
    ctx.ssao_pipeline_layout = null;
    ctx.ssao_blur_pipeline_layout = null;
    ctx.ssao_descriptor_set_layout = null;
    ctx.ssao_blur_descriptor_set_layout = null;
    ctx.ssao_framebuffer = null;
    ctx.ssao_blur_framebuffer = null;
    ctx.ssao_render_pass = null;
    ctx.ssao_blur_render_pass = null;
    ctx.ssao_view = null;
    ctx.ssao_image = null;
    ctx.ssao_memory = null;
    ctx.ssao_blur_view = null;
    ctx.ssao_blur_image = null;
    ctx.ssao_blur_memory = null;
    ctx.ssao_noise_view = null;
    ctx.ssao_noise_image = null;
    ctx.ssao_noise_memory = null;
    ctx.ssao_kernel_ubo = .{};
    ctx.ssao_sampler = null;
}

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
    _ = c.vkCreateBuffer(ctx.vulkan_device.vk_device, &buffer_info, null, &buffer);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(ctx.vulkan_device.vk_device, buffer, &mem_reqs);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, properties);

    var memory: c.VkDeviceMemory = null;
    // If allocation fails, we return null memory/buffer (handled by caller hopefully, or we should log/panic?)
    // Existing code ignored errors here mostly. Ideally we check result.
    if (c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
        c.vkDestroyBuffer(ctx.vulkan_device.vk_device, buffer, null);
        return .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    }
    _ = c.vkBindBufferMemory(ctx.vulkan_device.vk_device, buffer, memory, 0);

    const is_host_visible = (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
    return .{ .buffer = buffer, .memory = memory, .size = mem_reqs.size, .is_host_visible = is_host_visible };
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
    sampler_info.maxAnisotropy = @min(@as(f32, @floatFromInt(ctx.anisotropic_filtering)), ctx.vulkan_device.max_anisotropy);
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = vk_mipmap_mode;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = @floatFromInt(mip_levels);

    var sampler: c.VkSampler = null;
    _ = c.vkCreateSampler(ctx.vulkan_device.vk_device, &sampler_info, null, &sampler);
    return sampler;
}

fn createMainRenderPass(ctx: *VulkanContext) !void {
    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);
    const use_msaa = ctx.msaa_samples > 1;

    if (use_msaa) {
        // MSAA render pass: 3 attachments (MSAA color, MSAA depth, resolve)
        var msaa_color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        msaa_color_attachment.format = ctx.vulkan_swapchain.image_format;
        msaa_color_attachment.samples = sample_count;
        msaa_color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        msaa_color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE; // MSAA image not needed after resolve
        msaa_color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        msaa_color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        msaa_color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        msaa_color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        depth_attachment.format = DEPTH_FORMAT;
        depth_attachment.samples = sample_count;
        depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE; // Depth not needed after rendering
        depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolve_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        resolve_attachment.format = ctx.vulkan_swapchain.image_format;
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

        try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &render_pass_info, null, &ctx.vulkan_swapchain.main_render_pass));
        std.log.info("Created MSAA {}x render pass", .{ctx.msaa_samples});
    } else {
        // Non-MSAA render pass: 2 attachments (color, depth)
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = ctx.vulkan_swapchain.image_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        depth_attachment.format = DEPTH_FORMAT;
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

        try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &render_pass_info, null, &ctx.vulkan_swapchain.main_render_pass));
    }
}

/// Creates G-Pass resources: render pass, normal image, framebuffer, and pipeline.
/// G-Pass outputs world-space normals to a RGB texture for SSAO sampling.
fn createGPassResources(ctx: *VulkanContext) !void {
    destroyGPassResources(ctx);
    const normal_format = c.VK_FORMAT_R8G8B8A8_UNORM; // Store normals in [0,1] range

    // 1. Create G-Pass render pass (outputs: normal color + depth)
    {
        var attachments: [2]c.VkAttachmentDescription = undefined;

        // Attachment 0: Normal buffer (color output)
        attachments[0] = std.mem.zeroes(c.VkAttachmentDescription);
        attachments[0].format = normal_format;
        attachments[0].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[0].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[0].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[0].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        // Attachment 1: Depth buffer (shared with main pass for SSAO depth sampling)
        attachments[1] = std.mem.zeroes(c.VkAttachmentDescription);
        attachments[1].format = DEPTH_FORMAT;
        attachments[1].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[1].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[1].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[1].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[1].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[1].finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;
        subpass.pDepthStencilAttachment = &depth_ref;

        var dependencies: [2]c.VkSubpassDependency = undefined;
        // Dependency 0: External -> G-Pass
        dependencies[0] = std.mem.zeroes(c.VkSubpassDependency);
        dependencies[0].srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependencies[0].dstSubpass = 0;
        dependencies[0].srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        dependencies[0].dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependencies[0].srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT;
        dependencies[0].dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        dependencies[0].dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        // Dependency 1: G-Pass -> Fragment shader read (for SSAO)
        dependencies[1] = std.mem.zeroes(c.VkSubpassDependency);
        dependencies[1].srcSubpass = 0;
        dependencies[1].dstSubpass = c.VK_SUBPASS_EXTERNAL;
        dependencies[1].srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        dependencies[1].dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dependencies[1].srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        dependencies[1].dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        dependencies[1].dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 2;
        rp_info.pAttachments = &attachments;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 2;
        rp_info.pDependencies = &dependencies;

        try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.g_render_pass));
    }

    // 2. Create normal image for G-Pass output
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.vulkan_swapchain.extent.width, .height = ctx.vulkan_swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = normal_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.g_normal_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.g_normal_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.g_normal_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.g_normal_image, ctx.g_normal_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_normal_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = normal_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.g_normal_view));
    }

    // 3. Create G-Pass depth image (separate from MSAA depth, 1x sampled for SSAO)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.vulkan_swapchain.extent.width, .height = ctx.vulkan_swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = DEPTH_FORMAT;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.g_depth_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.g_depth_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.g_depth_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.g_depth_image, ctx.g_depth_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_depth_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.g_depth_view));
    }

    // 4. Create G-Pass framebuffer
    {
        const fb_attachments = [_]c.VkImageView{ ctx.g_normal_view, ctx.g_depth_view };

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.g_render_pass;
        fb_info.attachmentCount = 2;
        fb_info.pAttachments = &fb_attachments;
        fb_info.width = ctx.vulkan_swapchain.extent.width;
        fb_info.height = ctx.vulkan_swapchain.extent.height;
        fb_info.layers = 1;

        try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.g_framebuffer));
    }

    // 5. Create G-Pass pipeline (uses terrain.vert + g_pass.frag)
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/terrain.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/g_pass.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);

        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };

        // Vertex input matches terrain vertex format
        const binding_desc = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(rhi.Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        var attr_descs: [8]c.VkVertexInputAttributeDescription = undefined;
        // location 0: aPos (vec3)
        attr_descs[0] = .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "pos") };
        // location 1: aColor (vec3)
        attr_descs[1] = .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "color") };
        // location 2: aNormal (vec3)
        attr_descs[2] = .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "normal") };
        // location 3: aTexCoord (vec2)
        attr_descs[3] = .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "uv") };
        // location 4: aTileID (float)
        attr_descs[4] = .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "tile_id") };
        // location 5: aSkyLight (float)
        attr_descs[5] = .{ .location = 5, .binding = 0, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "skylight") };
        // location 6: aBlockLight (vec3)
        attr_descs[6] = .{ .location = 6, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "blocklight") };
        // location 7: aAO (float)
        attr_descs[7] = .{ .location = 7, .binding = 0, .format = c.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "ao") };

        var vi_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vi_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi_info.vertexBindingDescriptionCount = 1;
        vi_info.pVertexBindingDescriptions = &binding_desc;
        vi_info.vertexAttributeDescriptionCount = 8;
        vi_info.pVertexAttributeDescriptions = &attr_descs;

        var ia_info = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ia_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia_info.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var vp_info = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        vp_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp_info.viewportCount = 1;
        vp_info.scissorCount = 1;

        var rs_info = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rs_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs_info.polygonMode = c.VK_POLYGON_MODE_FILL;
        rs_info.lineWidth = 1.0;
        rs_info.cullMode = c.VK_CULL_MODE_NONE;
        rs_info.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

        var ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var ds_info = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        ds_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds_info.depthTestEnable = c.VK_TRUE;
        ds_info.depthWriteEnable = c.VK_TRUE;
        ds_info.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL; // Reverse-Z

        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        blend_attachment.blendEnable = c.VK_FALSE;

        var cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb_info.attachmentCount = 1;
        cb_info.pAttachments = &blend_attachment;

        const dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dyn_info = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dyn_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn_info.dynamicStateCount = 2;
        dyn_info.pDynamicStates = &dyn_states;

        // Use existing pipeline layout (has GlobalUniforms, textures, push constants)
        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &stages;
        pipe_info.pVertexInputState = &vi_info;
        pipe_info.pInputAssemblyState = &ia_info;
        pipe_info.pViewportState = &vp_info;
        pipe_info.pRasterizationState = &rs_info;
        pipe_info.pMultisampleState = &ms_info;
        pipe_info.pDepthStencilState = &ds_info;
        pipe_info.pColorBlendState = &cb_info;
        pipe_info.pDynamicState = &dyn_info;
        pipe_info.layout = ctx.pipeline_layout;
        pipe_info.renderPass = ctx.g_render_pass;

        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.g_pipeline));
    }

    std.log.info("G-Pass resources created ({}x{})", .{ ctx.vulkan_swapchain.extent.width, ctx.vulkan_swapchain.extent.height });
}

/// Creates SSAO resources: render pass, AO image, noise texture, kernel UBO, framebuffer, pipeline.
fn createSSAOResources(ctx: *VulkanContext) !void {
    destroySSAOResources(ctx);
    const ao_format = c.VK_FORMAT_R8_UNORM; // Single channel AO output

    // 1. Create SSAO render pass (outputs: single-channel AO)
    {
        var ao_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        ao_attachment.format = ao_format;
        ao_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ao_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        ao_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        ao_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        ao_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        ao_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        ao_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dependency.dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = &ao_attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 1;
        rp_info.pDependencies = &dependency;

        try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.ssao_render_pass));
        // Blur uses same format
        try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.ssao_blur_render_pass));
    }

    // 2. Create SSAO output image (store directly in context)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.vulkan_swapchain.extent.width, .height = ctx.vulkan_swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = ao_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_image, ctx.ssao_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ao_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_view));
    }

    // 3. Create SSAO blur output image
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.vulkan_swapchain.extent.width, .height = ctx.vulkan_swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = ao_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_blur_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_blur_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_blur_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_blur_image, ctx.ssao_blur_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_blur_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ao_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_blur_view));
    }

    // 4. Create SSAO noise texture (4x4 random rotation vectors)
    {
        var rng = std.Random.DefaultPrng.init(12345);
        var noise_data: [16 * 4]u8 = undefined;
        for (0..16) |i| {
            // Random rotation vector in tangent space (xy random, z=0)
            const x = rng.random().float(f32) * 2.0 - 1.0;
            const y = rng.random().float(f32) * 2.0 - 1.0;
            noise_data[i * 4 + 0] = @intFromFloat((x * 0.5 + 0.5) * 255.0);
            noise_data[i * 4 + 1] = @intFromFloat((y * 0.5 + 0.5) * 255.0);
            noise_data[i * 4 + 2] = 0; // z = 0
            noise_data[i * 4 + 3] = 255;
        }

        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = 4, .height = 4, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_noise_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_noise_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_noise_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_noise_image, ctx.ssao_noise_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_noise_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_noise_view));

        // Upload noise data via staging buffer
        const staging = createVulkanBuffer(ctx, 16 * 4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        defer {
            c.vkDestroyBuffer(ctx.vulkan_device.vk_device, staging.buffer, null);
            c.vkFreeMemory(ctx.vulkan_device.vk_device, staging.memory, null);
        }

        var data: ?*anyopaque = null;
        _ = c.vkMapMemory(ctx.vulkan_device.vk_device, staging.memory, 0, 16 * 4, 0, &data);
        if (data) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..64], &noise_data);
            c.vkUnmapMemory(ctx.vulkan_device.vk_device, staging.memory);
        }

        // Copy to image
        var cmd_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cmd_info.commandPool = ctx.command_pool;
        cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_info.commandBufferCount = 1;

        var cmd: c.VkCommandBuffer = null;
        try checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cmd_info, &cmd));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

        // Transition to TRANSFER_DST
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = ctx.ssao_noise_image;
        barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = 4, .height = 4, .depth = 1 };
        c.vkCmdCopyBufferToImage(cmd, staging.buffer, ctx.ssao_noise_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        // Transition to SHADER_READ_ONLY
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

        try checkVk(c.vkEndCommandBuffer(cmd));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cmd;
        try checkVk(c.vkQueueSubmit(ctx.vulkan_device.queue, 1, &submit_info, null));
        try checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));
        c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.command_pool, 1, &cmd);
    }

    // 5. Create SSAO kernel UBO with hemisphere samples
    {
        ctx.ssao_kernel_ubo = createVulkanBuffer(ctx, @sizeOf(SSAOParams), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        // Generate hemisphere samples
        var rng = std.Random.DefaultPrng.init(67890);
        for (0..64) |i| {
            var sample: [3]f32 = .{
                rng.random().float(f32) * 2.0 - 1.0,
                rng.random().float(f32) * 2.0 - 1.0,
                rng.random().float(f32), // hemisphere (z >= 0)
            };
            // Normalize
            const len = @sqrt(sample[0] * sample[0] + sample[1] * sample[1] + sample[2] * sample[2]);
            sample[0] /= len;
            sample[1] /= len;
            sample[2] /= len;

            // Scale to be more densely distributed near origin
            var scale: f32 = @as(f32, @floatFromInt(i)) / 64.0;
            scale = 0.1 + scale * scale * 0.9; // lerp(0.1, 1.0, scale*scale)
            sample[0] *= scale;
            sample[1] *= scale;
            sample[2] *= scale;

            ctx.ssao_params.samples[i] = .{ sample[0], sample[1], sample[2], 0.0 };
        }
        ctx.ssao_params.radius = 0.5;
        ctx.ssao_params.bias = 0.025;
    }

    // 6. Create SSAO framebuffers
    {
        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.ssao_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.ssao_view;
        fb_info.width = ctx.vulkan_swapchain.extent.width;
        fb_info.height = ctx.vulkan_swapchain.extent.height;
        fb_info.layers = 1;

        try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.ssao_framebuffer));

        fb_info.renderPass = ctx.ssao_blur_render_pass;
        fb_info.pAttachments = &ctx.ssao_blur_view;
        try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.ssao_blur_framebuffer));
    }

    // 7. Create SSAO descriptor set layout and allocate sets
    {
        // SSAO shader needs: depth (0), normal (1), noise (2), params UBO (3)
        var bindings: [4]c.VkDescriptorSetLayoutBinding = undefined;
        bindings[0] = .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
        bindings[1] = .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
        bindings[2] = .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };
        bindings[3] = .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 4;
        layout_info.pBindings = &bindings;

        try checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_descriptor_set_layout));

        // Blur only needs: ssao texture (0)
        var blur_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        layout_info.bindingCount = 1;
        layout_info.pBindings = &blur_bindings;
        try checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_blur_descriptor_set_layout));

        // Allocate descriptor sets from existing pool
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var ds_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            ds_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            ds_alloc.descriptorPool = ctx.descriptor_pool;
            ds_alloc.descriptorSetCount = 1;
            ds_alloc.pSetLayouts = &ctx.ssao_descriptor_set_layout;
            try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_alloc, &ctx.ssao_descriptor_sets[i]));

            ds_alloc.pSetLayouts = &ctx.ssao_blur_descriptor_set_layout;
            try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_alloc, &ctx.ssao_blur_descriptor_sets[i]));
        }
    }

    // 8. Create SSAO pipeline layout and pipeline
    {
        var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = &ctx.ssao_descriptor_set_layout;

        try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_pipeline_layout));

        layout_info.pSetLayouts = &ctx.ssao_blur_descriptor_set_layout;
        try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_blur_pipeline_layout));

        // Load shaders
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ssao.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ssao.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const blur_frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ssao_blur.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(blur_frag_code);

        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
        const blur_frag_module = try createShaderModule(ctx.vulkan_device.vk_device, blur_frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, blur_frag_module, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };

        // Fullscreen triangle - no vertex input
        var vi_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vi_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var ia_info = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ia_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia_info.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var vp_info = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        vp_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp_info.viewportCount = 1;
        vp_info.scissorCount = 1;

        var rs_info = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rs_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs_info.polygonMode = c.VK_POLYGON_MODE_FILL;
        rs_info.lineWidth = 1.0;
        rs_info.cullMode = c.VK_CULL_MODE_NONE;

        var ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var ds_info = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        ds_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds_info.depthTestEnable = c.VK_FALSE;
        ds_info.depthWriteEnable = c.VK_FALSE;

        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT;
        blend_attachment.blendEnable = c.VK_FALSE;

        var cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb_info.attachmentCount = 1;
        cb_info.pAttachments = &blend_attachment;

        const dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dyn_info = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dyn_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn_info.dynamicStateCount = 2;
        dyn_info.pDynamicStates = &dyn_states;

        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &stages;
        pipe_info.pVertexInputState = &vi_info;
        pipe_info.pInputAssemblyState = &ia_info;
        pipe_info.pViewportState = &vp_info;
        pipe_info.pRasterizationState = &rs_info;
        pipe_info.pMultisampleState = &ms_info;
        pipe_info.pDepthStencilState = &ds_info;
        pipe_info.pColorBlendState = &cb_info;
        pipe_info.pDynamicState = &dyn_info;
        pipe_info.layout = ctx.ssao_pipeline_layout;
        pipe_info.renderPass = ctx.ssao_render_pass;

        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.ssao_pipeline));

        // Blur pipeline
        stages[1].module = blur_frag_module;
        pipe_info.layout = ctx.ssao_blur_pipeline_layout;
        pipe_info.renderPass = ctx.ssao_blur_render_pass;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.ssao_blur_pipeline));
    }

    // 9. Create sampler for SSAO textures
    {
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_NEAREST;
        sampler_info.minFilter = c.VK_FILTER_NEAREST;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;

        try checkVk(c.vkCreateSampler(ctx.vulkan_device.vk_device, &sampler_info, null, &ctx.ssao_sampler));
    }

    // 10. Write SSAO descriptor sets
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        // SSAO descriptor set: depth(0), normal(1), noise(2), params(3)
        var image_infos: [3]c.VkDescriptorImageInfo = undefined;
        var buffer_info: c.VkDescriptorBufferInfo = undefined;
        var writes: [4]c.VkWriteDescriptorSet = undefined;

        // Binding 0: Depth sampler (g_depth_view)
        image_infos[0] = .{
            .sampler = ctx.ssao_sampler,
            .imageView = ctx.g_depth_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[0] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[0].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = ctx.ssao_descriptor_sets[i];
        writes[0].dstBinding = 0;
        writes[0].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[0].descriptorCount = 1;
        writes[0].pImageInfo = &image_infos[0];

        // Binding 1: Normal sampler (g_normal_view)
        image_infos[1] = .{
            .sampler = ctx.ssao_sampler,
            .imageView = ctx.g_normal_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[1] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = ctx.ssao_descriptor_sets[i];
        writes[1].dstBinding = 1;
        writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[1].descriptorCount = 1;
        writes[1].pImageInfo = &image_infos[1];

        // Binding 2: Noise sampler
        image_infos[2] = .{
            .sampler = ctx.ssao_sampler,
            .imageView = ctx.ssao_noise_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[2] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[2].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[2].dstSet = ctx.ssao_descriptor_sets[i];
        writes[2].dstBinding = 2;
        writes[2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[2].descriptorCount = 1;
        writes[2].pImageInfo = &image_infos[2];

        // Binding 3: SSAO Params UBO
        buffer_info = .{
            .buffer = ctx.ssao_kernel_ubo.buffer,
            .offset = 0,
            .range = @sizeOf(SSAOParams),
        };
        writes[3] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[3].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[3].dstSet = ctx.ssao_descriptor_sets[i];
        writes[3].dstBinding = 3;
        writes[3].descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        writes[3].descriptorCount = 1;
        writes[3].pBufferInfo = &buffer_info;

        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 4, &writes, 0, null);

        // SSAO Blur descriptor set: ssao_view(0)
        var blur_image_info = c.VkDescriptorImageInfo{
            .sampler = ctx.ssao_sampler,
            .imageView = ctx.ssao_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var blur_write = std.mem.zeroes(c.VkWriteDescriptorSet);
        blur_write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        blur_write.dstSet = ctx.ssao_blur_descriptor_sets[i];
        blur_write.dstBinding = 0;
        blur_write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        blur_write.descriptorCount = 1;
        blur_write.pImageInfo = &blur_image_info;

        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &blur_write, 0, null);
    }

    std.log.info("SSAO resources created ({}x{})", .{ ctx.vulkan_swapchain.extent.width, ctx.vulkan_swapchain.extent.height });
}

fn createMainFramebuffers(ctx: *VulkanContext) !void {
    const use_msaa = ctx.msaa_samples > 1;
    for (ctx.vulkan_swapchain.image_views.items) |iv| {
        var fb: c.VkFramebuffer = null;
        var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        framebuffer_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        framebuffer_info.width = ctx.vulkan_swapchain.extent.width;
        framebuffer_info.height = ctx.vulkan_swapchain.extent.height;
        framebuffer_info.layers = 1;

        if (use_msaa and ctx.vulkan_swapchain.msaa_color_view != null) {
            // MSAA framebuffer: [msaa_color, depth, swapchain_resolve]
            const fb_attachments = [_]c.VkImageView{ ctx.vulkan_swapchain.msaa_color_view.?, ctx.vulkan_swapchain.depth_image_view, iv };
            framebuffer_info.attachmentCount = 3;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &framebuffer_info, null, &fb));
        } else {
            // Non-MSAA framebuffer: [swapchain_color, depth]
            const fb_attachments = [_]c.VkImageView{ iv, ctx.vulkan_swapchain.depth_image_view };
            framebuffer_info.attachmentCount = 2;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &framebuffer_info, null, &fb));
        }
        try ctx.vulkan_swapchain.framebuffers.append(ctx.allocator, fb);
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
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        var attribute_descriptions: [8]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
        attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 3 * 4 };
        attribute_descriptions[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 6 * 4 };
        attribute_descriptions[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 9 * 4 };
        attribute_descriptions[4] = .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 11 * 4 };
        attribute_descriptions[5] = .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 12 * 4 };
        attribute_descriptions[6] = .{ .binding = 0, .location = 6, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 13 * 4 };
        attribute_descriptions[7] = .{ .binding = 0, .location = 7, .format = c.VK_FORMAT_R32_SFLOAT, .offset = 16 * 4 }; // AO
        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = 8;
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
        pipeline_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.pipeline));

        // Wireframe (No culling)
        var wireframe_rasterizer = rasterizer;
        wireframe_rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        wireframe_rasterizer.polygonMode = c.VK_POLYGON_MODE_LINE;
        pipeline_info.pRasterizationState = &wireframe_rasterizer;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.wireframe_pipeline));
    }

    // Sky
    {
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/sky.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/sky.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
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
        pipeline_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.sky_pipeline));
    }

    // UI
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
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
        pipeline_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_pipeline));

        // Textured UI
        const tex_vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui_tex.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_vert_code);
        const tex_frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/ui_tex.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_frag_code);
        const tex_vert_module = try createShaderModule(ctx.vulkan_device.vk_device, tex_vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, tex_vert_module, null);
        const tex_frag_module = try createShaderModule(ctx.vulkan_device.vk_device, tex_frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, tex_frag_module, null);
        var tex_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = tex_vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = tex_frag_module, .pName = "main" },
        };
        pipeline_info.pStages = &tex_shader_stages[0];
        pipeline_info.layout = ctx.ui_tex_pipeline_layout;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_tex_pipeline));
    }

    // Debug Shadow
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/debug_shadow.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/debug_shadow.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
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
        pipeline_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.debug_shadow_pipeline));
    }

    // Cloud
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/cloud.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/cloud.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
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
        pipeline_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.cloud_pipeline));
    }
}

fn destroyMainRenderPassAndPipelines(ctx: *VulkanContext) void {
    if (ctx.vulkan_device.vk_device == null) return;
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    if (ctx.pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline, null);
        ctx.pipeline = null;
    }
    if (ctx.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.wireframe_pipeline, null);
        ctx.wireframe_pipeline = null;
    }
    // Note: shadow_pipeline and shadow_render_pass are NOT destroyed here
    // because they don't depend on the swapchain or MSAA settings.

    if (ctx.sky_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.sky_pipeline, null);
        ctx.sky_pipeline = null;
    }
    if (ctx.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.wireframe_pipeline, null);
        ctx.wireframe_pipeline = null;
    }
    if (ctx.sky_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.sky_pipeline, null);
        ctx.sky_pipeline = null;
    }
    if (ctx.ui_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.ui_pipeline, null);
        ctx.ui_pipeline = null;
    }
    if (ctx.ui_tex_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.ui_tex_pipeline, null);
        ctx.ui_tex_pipeline = null;
    }
    if (ctx.debug_shadow_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.debug_shadow_pipeline, null);
        ctx.debug_shadow_pipeline = null;
    }
    if (ctx.cloud_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.cloud_pipeline, null);
        ctx.cloud_pipeline = null;
    }
    if (ctx.vulkan_swapchain.main_render_pass != null) {
        c.vkDestroyRenderPass(ctx.vulkan_device.vk_device, ctx.vulkan_swapchain.main_render_pass, null);
        ctx.vulkan_swapchain.main_render_pass = null;
    }
}

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.render_device = render_device;

    ctx.vulkan_device = try VulkanDevice.init(allocator, ctx.window);
    ctx.vulkan_swapchain = try VulkanSwapchain.init(allocator, &ctx.vulkan_device, ctx.window, ctx.msaa_samples);

    // 8. Command Pools & Buffers

    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = ctx.vulkan_device.graphics_family;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    try checkVk(c.vkCreateCommandPool(ctx.vulkan_device.vk_device, &pool_info, null, &ctx.command_pool));

    var cb_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    cb_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cb_alloc_info.commandPool = ctx.command_pool;
    cb_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cb_alloc_info.commandBufferCount = MAX_FRAMES_IN_FLIGHT;
    try checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cb_alloc_info, &ctx.command_buffers[0]));

    try checkVk(c.vkCreateCommandPool(ctx.vulkan_device.vk_device, &pool_info, null, &ctx.transfer_command_pool));
    cb_alloc_info.commandPool = ctx.transfer_command_pool;
    try checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cb_alloc_info, &ctx.transfer_command_buffers[0]));

    for (0..MAX_FRAMES_IN_FLIGHT) |frame_i| ctx.staging_buffers[frame_i] = try StagingBuffer.init(ctx, 64 * 1024 * 1024);
    ctx.transfer_ready = false;

    // 9. Layouts & Descriptors
    var layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Shadow Array (comparison)
        .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Shadow Array (regular for PCSS)
        .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT }, // Instance Data (SSBO)
        .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Normal
        .{ .binding = 7, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Roughness
        .{ .binding = 8, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Disp
        .{ .binding = 9, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // Env Map
        .{ .binding = 10, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT }, // SSAO Map
    };
    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = @intCast(layout_bindings.len);
    layout_info.pBindings = &layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.descriptor_set_layout));

    var ui_tex_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var ui_tex_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    ui_tex_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    ui_tex_layout_info.bindingCount = 1;
    ui_tex_layout_info.pBindings = &ui_tex_layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &ui_tex_layout_info, null, &ctx.ui_tex_descriptor_set_layout));

    var debug_shadow_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var debug_shadow_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    debug_shadow_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    debug_shadow_layout_info.bindingCount = 1;
    debug_shadow_layout_info.pBindings = &debug_shadow_layout_bindings[0];
    try checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &debug_shadow_layout_info, null, &ctx.debug_shadow_descriptor_set_layout));

    var model_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    model_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    // Increase size to 256 to account for potential alignment/padding discrepancies in shaders (e.g. 144 bytes)
    model_push_constant.size = 256;
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &ctx.descriptor_set_layout;
    pipeline_layout_info.pushConstantRangeCount = 1;
    pipeline_layout_info.pPushConstantRanges = &model_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &pipeline_layout_info, null, &ctx.pipeline_layout));

    var sky_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    sky_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    sky_push_constant.size = 128; // Standard SkyPushConstants size
    var sky_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    sky_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    sky_layout_info.setLayoutCount = 1;
    sky_layout_info.pSetLayouts = &ctx.descriptor_set_layout;
    sky_layout_info.pushConstantRangeCount = 1;
    sky_layout_info.pPushConstantRanges = &sky_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &sky_layout_info, null, &ctx.sky_pipeline_layout));

    var ui_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    ui_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
    ui_push_constant.size = @sizeOf(Mat4);
    var ui_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_layout_info.pushConstantRangeCount = 1;
    ui_layout_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &ui_layout_info, null, &ctx.ui_pipeline_layout));

    var ui_tex_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_tex_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_tex_layout_full_info.setLayoutCount = 1;
    ui_tex_layout_full_info.pSetLayouts = &ctx.ui_tex_descriptor_set_layout;
    ui_tex_layout_full_info.pushConstantRangeCount = 1;
    ui_tex_layout_full_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &ui_tex_layout_full_info, null, &ctx.ui_tex_pipeline_layout));

    var debug_shadow_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    debug_shadow_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    debug_shadow_layout_full_info.setLayoutCount = 1;
    debug_shadow_layout_full_info.pSetLayouts = &ctx.debug_shadow_descriptor_set_layout;
    debug_shadow_layout_full_info.pushConstantRangeCount = 1;
    debug_shadow_layout_full_info.pPushConstantRanges = &ui_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &debug_shadow_layout_full_info, null, &ctx.debug_shadow_pipeline_layout));

    var cloud_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    cloud_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    cloud_layout_info.pushConstantRangeCount = 1;
    cloud_layout_info.pPushConstantRanges = &sky_push_constant;
    try checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &cloud_layout_info, null, &ctx.cloud_pipeline_layout));

    // 10. Shadow Pass (Created ONCE)
    const shadow_res = ctx.shadow_resolution;
    var shadow_depth_desc = std.mem.zeroes(c.VkAttachmentDescription);
    shadow_depth_desc.format = DEPTH_FORMAT;
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

    // Add subpass dependencies for proper synchronization
    var shadow_dependencies = [_]c.VkSubpassDependency{
        // 1. External -> Subpass 0: Wait for previous reads to finish before writing
        .{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
            .dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        },
        // 2. Subpass 0 -> External: Wait for writes to finish before subsequent reads (sampling)
        .{
            .srcSubpass = 0,
            .dstSubpass = c.VK_SUBPASS_EXTERNAL,
            .srcStageMask = c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        },
    };
    shadow_rp_info.dependencyCount = 2;
    shadow_rp_info.pDependencies = &shadow_dependencies;

    try checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &shadow_rp_info, null, &ctx.shadow_render_pass));

    ctx.shadow_extent = .{ .width = shadow_res, .height = shadow_res };

    var shadow_img_info = std.mem.zeroes(c.VkImageCreateInfo);
    shadow_img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    shadow_img_info.imageType = c.VK_IMAGE_TYPE_2D;
    shadow_img_info.extent = .{ .width = shadow_res, .height = shadow_res, .depth = 1 };
    shadow_img_info.mipLevels = 1;
    shadow_img_info.arrayLayers = rhi.SHADOW_CASCADE_COUNT;
    shadow_img_info.format = DEPTH_FORMAT;
    shadow_img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    shadow_img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    shadow_img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &shadow_img_info, null, &ctx.shadow_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.shadow_image, &mem_reqs);
    var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.shadow_image_memory));
    try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.shadow_image, ctx.shadow_image_memory, 0));

    // Full array view for sampling
    var array_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    array_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    array_view_info.image = ctx.shadow_image;
    array_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    array_view_info.format = DEPTH_FORMAT;
    array_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = rhi.SHADOW_CASCADE_COUNT };
    try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &array_view_info, null, &ctx.shadow_image_view));

    // Layered views for framebuffers (one per cascade)
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        var layer_view: c.VkImageView = null;
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.shadow_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = @intCast(si), .layerCount = 1 };
        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &layer_view));
        ctx.shadow_image_views[si] = layer_view;

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.shadow_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.shadow_image_views[si];
        fb_info.width = shadow_res;
        fb_info.height = shadow_res;
        fb_info.layers = 1;
        try checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.shadow_framebuffers[si]));
        ctx.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    // Shadow Pipeline
    {
        const vert_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/shadow.vert.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc("assets/shaders/vulkan/shadow.frag.spv", ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try createShaderModule(ctx.vulkan_device.vk_device, frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, frag_module, null);
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
        shadow_rs_info.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
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
        try checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.shadow_pipeline));
    }

    // 11. Final Pipelines & Uniforms
    try createMainPipelines(ctx);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.global_ubos[i] = createVulkanBuffer(ctx, @sizeOf(GlobalUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        ctx.shadow_ubos[i] = createVulkanBuffer(ctx, @sizeOf(ShadowUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        ctx.ui_vbos[i] = createVulkanBuffer(ctx, 1024 * 1024, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        // Persistent mapping for UBOs
        _ = c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.global_ubos[i].memory, 0, @sizeOf(GlobalUniforms), 0, &ctx.global_ubos_mapped[i]);
        _ = c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.shadow_ubos[i].memory, 0, @sizeOf(ShadowUniforms), 0, &ctx.shadow_ubos_mapped[i]);
        ctx.descriptors_dirty[i] = true;
    }
    ctx.model_ubo = createVulkanBuffer(ctx, @sizeOf(ModelUniforms) * 1000, c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    ctx.dummy_instance_buffer = createVulkanBuffer(
        ctx,
        @sizeOf(rhi.InstanceData),
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    if (ctx.dummy_instance_buffer.memory != null) {
        var dummy_ptr: ?*anyopaque = null;
        if (c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.dummy_instance_buffer.memory, 0, ctx.dummy_instance_buffer.size, 0, &dummy_ptr) == c.VK_SUCCESS) {
            if (dummy_ptr) |ptr| {
                @memset(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(rhi.InstanceData)], 0);
            }
            c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.dummy_instance_buffer.memory);
        }
    }

    var pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 32 * MAX_FRAMES_IN_FLIGHT },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 256 * MAX_FRAMES_IN_FLIGHT },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 16 * MAX_FRAMES_IN_FLIGHT },
    };
    var dp_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    dp_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dp_info.poolSizeCount = 3;
    dp_info.pPoolSizes = &pool_sizes[0];
    dp_info.maxSets = 256 * MAX_FRAMES_IN_FLIGHT;
    try checkVk(c.vkCreateDescriptorPool(ctx.vulkan_device.vk_device, &dp_info, null, &ctx.descriptor_pool));

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        var ds_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx.descriptor_set_layout };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_alloc, &ctx.descriptor_sets[i]));
        var writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.global_ubos[i].buffer, .offset = 0, .range = @sizeOf(GlobalUniforms) } },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.descriptor_sets[i], .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.shadow_ubos[i].buffer, .offset = 0, .range = @sizeOf(ShadowUniforms) } },
        };
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 2, &writes[0], 0, null);

        var lod_ds_alloc = c.VkDescriptorSetAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = ctx.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &ctx.descriptor_set_layout };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &lod_ds_alloc, &ctx.lod_descriptor_sets[i]));
        var lod_writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.lod_descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.global_ubos[i].buffer, .offset = 0, .range = @sizeOf(GlobalUniforms) } },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.lod_descriptor_sets[i], .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.shadow_ubos[i].buffer, .offset = 0, .range = @sizeOf(ShadowUniforms) } },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ctx.lod_descriptor_sets[i], .dstBinding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .pBufferInfo = &c.VkDescriptorBufferInfo{ .buffer = ctx.dummy_instance_buffer.buffer, .offset = 0, .range = @sizeOf(rhi.InstanceData) } },
        };
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 3, &lod_writes[0], 0, null);

        var ui_layouts: [64]c.VkDescriptorSetLayout = undefined;
        for (&ui_layouts) |*layout| {
            layout.* = ctx.ui_tex_descriptor_set_layout;
        }
        var ui_ds_alloc = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = ctx.descriptor_pool,
            .descriptorSetCount = ui_layouts.len,
            .pSetLayouts = &ui_layouts[0],
        };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ui_ds_alloc, &ctx.ui_tex_descriptor_pool[i][0]));
        ctx.ui_tex_descriptor_sets[i] = ctx.ui_tex_descriptor_pool[i][0];

        var debug_layouts: [8]c.VkDescriptorSetLayout = undefined;
        for (&debug_layouts) |*layout| {
            layout.* = ctx.debug_shadow_descriptor_set_layout;
        }
        var ds_ds_alloc = c.VkDescriptorSetAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = ctx.descriptor_pool,
            .descriptorSetCount = debug_layouts.len,
            .pSetLayouts = &debug_layouts[0],
        };
        try checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_ds_alloc, &ctx.debug_shadow_descriptor_pool[i][0]));
        ctx.debug_shadow_descriptor_sets[i] = ctx.debug_shadow_descriptor_pool[i][0];
        ctx.debug_shadow_descriptor_next[i] = 0;
    }

    // 11b. G-Pass and SSAO resources (after descriptor pool is created)
    try createGPassResources(ctx);
    try createSSAOResources(ctx);

    var shadow_sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    shadow_sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    shadow_sampler_info.magFilter = c.VK_FILTER_LINEAR;
    shadow_sampler_info.minFilter = c.VK_FILTER_LINEAR;
    shadow_sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    shadow_sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
    shadow_sampler_info.compareEnable = c.VK_TRUE;
    // Reverse-Z: Lit if Ref >= Tex (Closer/Larger Z >= Stored Depth)
    shadow_sampler_info.compareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;
    try checkVk(c.vkCreateSampler(ctx.vulkan_device.vk_device, &shadow_sampler_info, null, &ctx.shadow_sampler));

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
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.cloud_vbo.memory, 0, @sizeOf(@TypeOf(cloud_vertices)), 0, &cloud_vbo_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(cloud_vbo_ptr.?))[0..@sizeOf(@TypeOf(cloud_vertices))], std.mem.asBytes(&cloud_vertices));
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.cloud_vbo.memory);
    }

    // Upload cloud index data
    var cloud_ebo_ptr: ?*anyopaque = null;
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.cloud_ebo.memory, 0, @sizeOf(@TypeOf(cloud_indices)), 0, &cloud_ebo_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(cloud_ebo_ptr.?))[0..@sizeOf(@TypeOf(cloud_indices))], std.mem.asBytes(&cloud_indices));
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.cloud_ebo.memory);
    }

    // Create Sync Objects
    var sem_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    var fen_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fen_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fen_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        try checkVk(c.vkCreateSemaphore(ctx.vulkan_device.vk_device, &sem_info, null, &ctx.image_available_semaphores[i]));
        try checkVk(c.vkCreateSemaphore(ctx.vulkan_device.vk_device, &sem_info, null, &ctx.render_finished_semaphores[i]));
        try checkVk(c.vkCreateFence(ctx.vulkan_device.vk_device, &fen_info, null, &ctx.in_flight_fences[i]));
    }

    // 15. Create Dummy Shadow resources for Descriptor set validity
    {
        var dummy_img_info = std.mem.zeroes(c.VkImageCreateInfo);
        dummy_img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        dummy_img_info.imageType = c.VK_IMAGE_TYPE_2D;
        dummy_img_info.extent = .{ .width = 1, .height = 1, .depth = 1 };
        dummy_img_info.mipLevels = 1;
        dummy_img_info.arrayLayers = rhi.SHADOW_CASCADE_COUNT;
        dummy_img_info.format = DEPTH_FORMAT;
        dummy_img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        dummy_img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        dummy_img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        try checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &dummy_img_info, null, &ctx.dummy_shadow_image));

        var dummy_mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.dummy_shadow_image, &dummy_mem_reqs);
        var dummy_alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = dummy_mem_reqs.size, .memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, dummy_mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
        try checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &dummy_alloc_info, null, &ctx.dummy_shadow_memory));
        try checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.dummy_shadow_image, ctx.dummy_shadow_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.dummy_shadow_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = rhi.SHADOW_CASCADE_COUNT };
        try checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.dummy_shadow_view));
    }

    // 15b. Transition shadow images to SHADER_READ_ONLY_OPTIMAL so they're valid for sampling
    // before any shadow passes have rendered. This prevents GPU hangs from sampling UNDEFINED layout.
    {
        var cmd_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        cmd_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cmd_alloc_info.commandPool = ctx.command_pool;
        cmd_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_alloc_info.commandBufferCount = 1;

        var init_cmd: c.VkCommandBuffer = null;
        try checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cmd_alloc_info, &init_cmd));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try checkVk(c.vkBeginCommandBuffer(init_cmd, &begin_info));

        // Transition main shadow image (all cascade layers)
        var shadow_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        shadow_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        shadow_barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        shadow_barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        shadow_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        shadow_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        shadow_barrier.image = ctx.shadow_image;
        shadow_barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        shadow_barrier.subresourceRange.baseMipLevel = 0;
        shadow_barrier.subresourceRange.levelCount = 1;
        shadow_barrier.subresourceRange.baseArrayLayer = 0;
        shadow_barrier.subresourceRange.layerCount = rhi.SHADOW_CASCADE_COUNT;
        shadow_barrier.srcAccessMask = 0;
        shadow_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(init_cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &shadow_barrier);

        // Transition dummy shadow image (all cascade layers)
        var dummy_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        dummy_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        dummy_barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        dummy_barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        dummy_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        dummy_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        dummy_barrier.image = ctx.dummy_shadow_image;
        dummy_barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        dummy_barrier.subresourceRange.baseMipLevel = 0;
        dummy_barrier.subresourceRange.levelCount = 1;
        dummy_barrier.subresourceRange.baseArrayLayer = 0;
        dummy_barrier.subresourceRange.layerCount = rhi.SHADOW_CASCADE_COUNT;
        dummy_barrier.srcAccessMask = 0;
        dummy_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(init_cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &dummy_barrier);

        // Transition SSAO blur image to SHADER_READ_ONLY_OPTIMAL (needed even when SSAO passes are disabled)
        if (ctx.ssao_blur_image != null) {
            var ssao_blur_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            ssao_blur_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            ssao_blur_barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            ssao_blur_barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            ssao_blur_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            ssao_blur_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            ssao_blur_barrier.image = ctx.ssao_blur_image;
            ssao_blur_barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            ssao_blur_barrier.subresourceRange.baseMipLevel = 0;
            ssao_blur_barrier.subresourceRange.levelCount = 1;
            ssao_blur_barrier.subresourceRange.baseArrayLayer = 0;
            ssao_blur_barrier.subresourceRange.layerCount = 1;
            ssao_blur_barrier.srcAccessMask = 0;
            ssao_blur_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

            c.vkCmdPipelineBarrier(init_cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &ssao_blur_barrier);
        }

        try checkVk(c.vkEndCommandBuffer(init_cmd));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &init_cmd;

        try checkVk(c.vkQueueSubmit(ctx.vulkan_device.queue, 1, &submit_info, null));
        try checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));

        c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.command_pool, 1, &init_cmd);

        // Update layout tracking
        for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
            ctx.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }

        std.log.info("Shadow images transitioned to SHADER_READ_ONLY_OPTIMAL", .{});
    }

    // 16. Create Dummy Textures for Descriptor set validity
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    const dummy_handle = createTexture(ctx_ptr, 1, 1, .rgba, .{}, &white_pixel);

    // Truly neutral normal map dummy: (128, 128, 255, 0)
    // Alpha 0 = PBR Off flag for our shader
    const normal_neutral = [_]u8{ 128, 128, 255, 0 };
    const dummy_normal_handle = createTexture(ctx_ptr, 1, 1, .rgba, .{}, &normal_neutral);

    // Roughness dummy: 1.0 roughness (Max), 0.0 displacement
    const roughness_neutral = [_]u8{ 255, 0, 0, 255 };
    const dummy_roughness_handle = createTexture(ctx_ptr, 1, 1, .rgba, .{}, &roughness_neutral);

    ctx.dummy_texture = dummy_handle;
    ctx.dummy_normal_texture = dummy_normal_handle;
    ctx.dummy_roughness_texture = dummy_roughness_handle;

    ctx.current_texture = dummy_handle;
    ctx.current_normal_texture = dummy_normal_handle;
    ctx.current_roughness_texture = dummy_roughness_handle;
    ctx.current_displacement_texture = dummy_roughness_handle;
    ctx.current_env_texture = dummy_handle;

    // 17. Initialize ALL descriptor bindings with valid resources to prevent undefined behavior
    // Descriptor sets were only partially written during allocation (bindings 0, 2 for UBOs)
    // We MUST write bindings 1, 3, 4, 5, 6, 7, 8, 9, 10 before any draw calls
    {
        ctx.mutex.lock();
        const dummy_tex = ctx.textures.get(dummy_handle).?;
        const dummy_normal = ctx.textures.get(dummy_normal_handle).?;
        const dummy_rough = ctx.textures.get(dummy_roughness_handle).?;
        ctx.mutex.unlock();

        for (0..MAX_FRAMES_IN_FLIGHT) |frame_idx| {
            var image_infos: [8]c.VkDescriptorImageInfo = undefined;
            var writes: [9]c.VkWriteDescriptorSet = undefined;

            // Binding 1: Main texture atlas (dummy)
            image_infos[0] = .{
                .sampler = dummy_tex.sampler,
                .imageView = dummy_tex.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[0] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[0].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[0].dstSet = ctx.descriptor_sets[frame_idx];
            writes[0].dstBinding = 1;
            writes[0].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[0].descriptorCount = 1;
            writes[0].pImageInfo = &image_infos[0];

            // Binding 3: Shadow array (comparison sampler for PCF)
            image_infos[1] = .{
                .sampler = ctx.shadow_sampler,
                .imageView = ctx.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[1] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[1].dstSet = ctx.descriptor_sets[frame_idx];
            writes[1].dstBinding = 3;
            writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[1].descriptorCount = 1;
            writes[1].pImageInfo = &image_infos[1];

            // Binding 4: Shadow array (regular sampler for PCSS blocker search)
            image_infos[2] = .{
                .sampler = ctx.ssao_sampler, // Use nearest sampler (no comparison)
                .imageView = ctx.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[2] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[2].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[2].dstSet = ctx.descriptor_sets[frame_idx];
            writes[2].dstBinding = 4;
            writes[2].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[2].descriptorCount = 1;
            writes[2].pImageInfo = &image_infos[2];

            // Binding 6: Normal map (dummy neutral)
            image_infos[3] = .{
                .sampler = dummy_normal.sampler,
                .imageView = dummy_normal.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[3] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[3].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[3].dstSet = ctx.descriptor_sets[frame_idx];
            writes[3].dstBinding = 6;
            writes[3].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[3].descriptorCount = 1;
            writes[3].pImageInfo = &image_infos[3];

            // Binding 7: Roughness map (dummy neutral)
            image_infos[4] = .{
                .sampler = dummy_rough.sampler,
                .imageView = dummy_rough.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[4] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[4].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[4].dstSet = ctx.descriptor_sets[frame_idx];
            writes[4].dstBinding = 7;
            writes[4].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[4].descriptorCount = 1;
            writes[4].pImageInfo = &image_infos[4];

            // Binding 8: Displacement map (dummy neutral)
            image_infos[5] = .{
                .sampler = dummy_rough.sampler,
                .imageView = dummy_rough.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[5] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[5].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[5].dstSet = ctx.descriptor_sets[frame_idx];
            writes[5].dstBinding = 8;
            writes[5].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[5].descriptorCount = 1;
            writes[5].pImageInfo = &image_infos[5];

            // Binding 9: Environment Map (dummy)
            image_infos[6] = .{
                .sampler = dummy_tex.sampler,
                .imageView = dummy_tex.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[6] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[6].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[6].dstSet = ctx.descriptor_sets[frame_idx];
            writes[6].dstBinding = 9;
            writes[6].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[6].descriptorCount = 1;
            writes[6].pImageInfo = &image_infos[6];

            // Binding 10: SSAO Map (blur output)
            image_infos[7] = .{
                .sampler = ctx.ssao_sampler,
                .imageView = ctx.ssao_blur_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[7] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[7].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[7].dstSet = ctx.descriptor_sets[frame_idx];
            writes[7].dstBinding = 10;
            writes[7].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[7].descriptorCount = 1;
            writes[7].pImageInfo = &image_infos[7];

            // Binding 5: Instance data (dummy SSBO)
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = ctx.dummy_instance_buffer.buffer,
                .offset = 0,
                .range = ctx.dummy_instance_buffer.size,
            };
            writes[8] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[8].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[8].dstSet = ctx.descriptor_sets[frame_idx];
            writes[8].dstBinding = 5;
            writes[8].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[8].descriptorCount = 1;
            writes[8].pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 9, &writes[0], 0, null);

            for (0..9) |write_idx| {
                writes[write_idx].dstSet = ctx.lod_descriptor_sets[frame_idx];
            }
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 9, &writes[0], 0, null);
        }
        std.log.info("All descriptor bindings initialized with valid resources", .{});
    }

    std.log.info("Vulkan initialized successfully!", .{});
}
fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.vulkan_device.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

        destroyMainRenderPassAndPipelines(ctx);
        destroyShadowResources(ctx);
        destroyGPassResources(ctx);
        destroySSAOResources(ctx);

        // Clean up remaining resources
        if (ctx.descriptor_pool != null) c.vkDestroyDescriptorPool(ctx.vulkan_device.vk_device, ctx.descriptor_pool, null);

        if (ctx.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.pipeline_layout, null);
        if (ctx.sky_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.sky_pipeline_layout, null);
        if (ctx.ui_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_pipeline_layout, null);
        if (ctx.ui_tex_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_pipeline_layout, null);
        if (ctx.debug_shadow_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.debug_shadow_pipeline_layout, null);
        if (ctx.cloud_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.cloud_pipeline_layout, null);

        if (ctx.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.descriptor_set_layout, null);
        if (ctx.ui_tex_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_descriptor_set_layout, null);
        if (ctx.debug_shadow_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.debug_shadow_descriptor_set_layout, null);

        if (ctx.dummy_shadow_view != null) c.vkDestroyImageView(ctx.vulkan_device.vk_device, ctx.dummy_shadow_view, null);
        if (ctx.dummy_shadow_image != null) c.vkDestroyImage(ctx.vulkan_device.vk_device, ctx.dummy_shadow_image, null);
        if (ctx.dummy_shadow_memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.dummy_shadow_memory, null);

        if (ctx.model_ubo.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.model_ubo.buffer, null);
        if (ctx.model_ubo.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.model_ubo.memory, null);
        if (ctx.dummy_instance_buffer.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.dummy_instance_buffer.buffer, null);
        if (ctx.dummy_instance_buffer.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.dummy_instance_buffer.memory, null);
        if (ctx.debug_shadow_vbo.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.debug_shadow_vbo.buffer, null);
        if (ctx.debug_shadow_vbo.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.debug_shadow_vbo.memory, null);
        if (ctx.cloud_vbo.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.cloud_vbo.buffer, null);
        if (ctx.cloud_vbo.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.cloud_vbo.memory, null);
        if (ctx.cloud_ebo.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.cloud_ebo.buffer, null);
        if (ctx.cloud_ebo.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.cloud_ebo.memory, null);

        ctx.vulkan_swapchain.deinit();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (ctx.ui_vbos[i].buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.ui_vbos[i].buffer, null);
            if (ctx.ui_vbos[i].memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.ui_vbos[i].memory, null);
            if (ctx.global_ubos[i].buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.global_ubos[i].buffer, null);
            if (ctx.global_ubos[i].memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.global_ubos[i].memory, null);
            if (ctx.shadow_ubos[i].buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, ctx.shadow_ubos[i].buffer, null);
            if (ctx.shadow_ubos[i].memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.shadow_ubos[i].memory, null);

            if (ctx.image_available_semaphores[i] != null) c.vkDestroySemaphore(ctx.vulkan_device.vk_device, ctx.image_available_semaphores[i], null);
            if (ctx.render_finished_semaphores[i] != null) c.vkDestroySemaphore(ctx.vulkan_device.vk_device, ctx.render_finished_semaphores[i], null);
            if (ctx.in_flight_fences[i] != null) c.vkDestroyFence(ctx.vulkan_device.vk_device, ctx.in_flight_fences[i], null);

            ctx.staging_buffers[i].deinit(ctx.vulkan_device.vk_device);

            for (ctx.buffer_deletion_queue[i].items) |zombie| {
                if (zombie.buffer != null) c.vkDestroyBuffer(ctx.vulkan_device.vk_device, zombie.buffer, null);
                if (zombie.memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, zombie.memory, null);
            }
            ctx.buffer_deletion_queue[i].deinit(ctx.allocator);
        }

        var buf_iter = ctx.buffers.iterator();
        while (buf_iter.next()) |entry| {
            c.vkDestroyBuffer(ctx.vulkan_device.vk_device, entry.value_ptr.buffer, null);
            c.vkFreeMemory(ctx.vulkan_device.vk_device, entry.value_ptr.memory, null);
        }
        ctx.buffers.deinit();

        var tex_iter = ctx.textures.iterator();
        while (tex_iter.next()) |entry| {
            c.vkDestroySampler(ctx.vulkan_device.vk_device, entry.value_ptr.sampler, null);
            c.vkDestroyImageView(ctx.vulkan_device.vk_device, entry.value_ptr.view, null);
            c.vkFreeMemory(ctx.vulkan_device.vk_device, entry.value_ptr.memory, null);
            c.vkDestroyImage(ctx.vulkan_device.vk_device, entry.value_ptr.image, null);
        }
        ctx.textures.deinit();

        if (ctx.command_pool != null) c.vkDestroyCommandPool(ctx.vulkan_device.vk_device, ctx.command_pool, null);
        if (ctx.transfer_command_pool != null) c.vkDestroyCommandPool(ctx.vulkan_device.vk_device, ctx.transfer_command_pool, null);

        ctx.vulkan_device.deinit();
    }
    ctx.allocator.destroy(ctx);
}

fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (size == 0) return 0;

    const vk_usage: c.VkBufferUsageFlags = switch (usage) {
        .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .index => c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        .storage => c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .indirect => c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    };

    const props: c.VkMemoryPropertyFlags = switch (usage) {
        .vertex, .index => c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .uniform, .storage, .indirect => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
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
            const result = c.vkMapMemory(ctx.vulkan_device.vk_device, buf.memory, @intCast(dst_offset), @intCast(data.len), 0, &map_ptr);
            if (result == c.VK_SUCCESS) {
                @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
                c.vkUnmapMemory(ctx.vulkan_device.vk_device, buf.memory);
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

fn recreateSwapchain(ctx: *VulkanContext) void {
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) return;

    // 1. Destroy existing stacks
    destroyMainRenderPassAndPipelines(ctx);
    destroyGPassResources(ctx);
    destroySSAOResources(ctx);

    // Reset pass state flags to prevent state confusion
    ctx.main_pass_active = false;
    ctx.shadow_pass_active = false;
    ctx.g_pass_active = false;
    ctx.ssao_pass_active = false;

    // 2. Recreate Swapchain (includes main RP and framebuffers)

    ctx.vulkan_swapchain.recreate(ctx.msaa_samples) catch |err| {
        std.log.err("Failed to recreate swapchain: {}", .{err});
        return;
    };

    // 3. Recreate dependent resources
    createMainPipelines(ctx) catch {};
    createGPassResources(ctx) catch {};
    createSSAOResources(ctx) catch {};

    ctx.framebuffer_resized = false;
    std.log.info("Vulkan swapchain recreated: {}x{} (SDL pixels: {}x{}, MSAA {}x)", .{ ctx.vulkan_swapchain.extent.width, ctx.vulkan_swapchain.extent.height, w, h, ctx.msaa_samples });
}

fn ensureFrameReady(ctx: *VulkanContext) void {
    if (ctx.transfer_ready) return;

    const fence = ctx.in_flight_fences[ctx.current_sync_frame];

    // Wait for the frame to be available (timeout after 2 seconds to avoid system lockup)
    const timeout_ns = 2_000_000_000;
    const wait_res = c.vkWaitForFences(ctx.vulkan_device.vk_device, 1, &fence, c.VK_TRUE, timeout_ns);
    if (wait_res == c.VK_TIMEOUT) {
        std.log.err("Vulkan GPU timeout! Possible GPU hang detected. System lockup prevented.", .{});
        // CRITICAL: Do NOT proceed to reset fences or command buffers.
        // The GPU is stuck. We cannot recover safely without device loss.
        // Crashing the application is safer than crashing the OS/Driver by race conditions.
        @panic("GPU Timeout / Hang Detected");
    }

    // Reset fence
    _ = c.vkResetFences(ctx.vulkan_device.vk_device, 1, &fence);

    // Process deletion queue for THIS frame slot (now safe since fence waited)
    // Buffers were queued here during frame N, now it's frame N+MAX_FRAMES_IN_FLIGHT
    // so the GPU is guaranteed to be done with them
    for (ctx.buffer_deletion_queue[ctx.current_sync_frame].items) |zombie| {
        c.vkDestroyBuffer(ctx.vulkan_device.vk_device, zombie.buffer, null);
        c.vkFreeMemory(ctx.vulkan_device.vk_device, zombie.memory, null);
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

    // Check if an explicit resize was requested (e.g. by setViewport detecting a mismatch)
    if (ctx.framebuffer_resized) {
        recreateSwapchain(ctx);
        // Note: recreateSwapchain resets framebuffer_resized to false.
        // We continue execution to acquire the image from the NEW swapchain.
    }

    ensureFrameReady(ctx);

    applyPendingDescriptorUpdates(ctx, ctx.current_sync_frame);

    ctx.frame_in_progress = false; // Reset initially
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
    const result = c.vkAcquireNextImageKHR(ctx.vulkan_device.vk_device, ctx.vulkan_swapchain.handle, 1000000000, acquire_semaphore, null, &image_index);

    if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
        recreateSwapchain(ctx);
        // Frame execution must stop here. subsequent passes check ctx.frame_in_progress.
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

    // Make host writes and uploads visible to the GPU this frame.
    var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
    mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    mem_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT;
    mem_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
        0,
        1,
        &mem_barrier,
        0,
        null,
        0,
        null,
    );

    ctx.frame_in_progress = true;
    ctx.ui_vertex_offset = 0;
    ctx.ui_flushed_vertex_count = 0;
    ctx.ui_tex_descriptor_next[ctx.current_sync_frame] = 0;
    ctx.debug_shadow_descriptor_next[ctx.current_sync_frame] = 0;

    // Static descriptor updates (Atlases & Shadow maps)

    ctx.mutex.lock();
    const cur_tex = ctx.current_texture;
    const cur_nor = ctx.current_normal_texture;
    const cur_rou = ctx.current_roughness_texture;
    const cur_dis = ctx.current_displacement_texture;
    const cur_env = ctx.current_env_texture;
    ctx.mutex.unlock();

    // Check if any texture bindings or shadow views changed since last frame
    var needs_update = false;
    if (ctx.bound_texture != cur_tex) needs_update = true;
    if (ctx.bound_normal_texture != cur_nor) needs_update = true;
    if (ctx.bound_roughness_texture != cur_rou) needs_update = true;
    if (ctx.bound_displacement_texture != cur_dis) needs_update = true;
    if (ctx.bound_env_texture != cur_env) needs_update = true;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (ctx.bound_shadow_views[si] != ctx.shadow_image_views[si]) needs_update = true;
    }

    // Also update if we've cycled back to this frame in flight and haven't updated this set yet
    if (needs_update) {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| ctx.descriptors_dirty[i] = true;
        // Update tracking immediately so next frame doesn't re-trigger a dirty state for all frames
        ctx.bound_texture = cur_tex;
        ctx.bound_normal_texture = cur_nor;
        ctx.bound_roughness_texture = cur_rou;
        ctx.bound_displacement_texture = cur_dis;
        ctx.bound_env_texture = cur_env;
        for (0..rhi.SHADOW_CASCADE_COUNT) |si| ctx.bound_shadow_views[si] = ctx.shadow_image_views[si];
    }

    if (ctx.descriptors_dirty[ctx.current_sync_frame]) {
        var writes: [10]c.VkWriteDescriptorSet = undefined;
        var write_count: u32 = 0;
        var image_infos: [10]c.VkDescriptorImageInfo = undefined;
        var info_count: u32 = 0;

        const dummy_tex_entry = ctx.textures.get(ctx.dummy_texture);

        const atlas_slots = [_]struct { handle: rhi.TextureHandle, binding: u32 }{
            .{ .handle = cur_tex, .binding = 1 },
            .{ .handle = cur_nor, .binding = 6 },
            .{ .handle = cur_rou, .binding = 7 },
            .{ .handle = cur_dis, .binding = 8 },
            .{ .handle = cur_env, .binding = 9 },
        };

        for (atlas_slots) |slot| {
            const entry = ctx.textures.get(slot.handle) orelse dummy_tex_entry;
            if (entry) |tex| {
                image_infos[info_count] = .{
                    .sampler = tex.sampler,
                    .imageView = tex.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[write_count].dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
                writes[write_count].dstBinding = slot.binding;
                writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes[write_count].descriptorCount = 1;
                writes[write_count].pImageInfo = &image_infos[info_count];
                write_count += 1;
                info_count += 1;
            }
        }

        // Shadows
        {
            image_infos[info_count] = .{
                .sampler = ctx.shadow_sampler,
                .imageView = ctx.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[write_count].dstSet = ctx.descriptor_sets[ctx.current_sync_frame];
            writes[write_count].dstBinding = 3;
            writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[write_count].descriptorCount = 1;
            writes[write_count].pImageInfo = &image_infos[info_count];
            write_count += 1;
            info_count += 1;
        }

        if (write_count > 0) {
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, write_count, &writes[0], 0, null);

            // Also update LOD descriptor sets with the same texture bindings
            for (0..write_count) |i| {
                writes[i].dstSet = ctx.lod_descriptor_sets[ctx.current_sync_frame];
            }
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, write_count, &writes[0], 0, null);
        }

        ctx.descriptors_dirty[ctx.current_sync_frame] = false;
    }

    ctx.descriptors_updated = true;
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
    _ = c.vkResetFences(ctx.vulkan_device.vk_device, 1, &ctx.in_flight_fences[ctx.current_sync_frame]);
    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

    // Recreating semaphores is the most robust way to "abort" their pending status from AcquireNextImage
    c.vkDestroySemaphore(ctx.vulkan_device.vk_device, ctx.image_available_semaphores[ctx.current_sync_frame], null);
    c.vkDestroySemaphore(ctx.vulkan_device.vk_device, ctx.render_finished_semaphores[ctx.current_sync_frame], null);

    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    _ = c.vkCreateSemaphore(ctx.vulkan_device.vk_device, &semaphore_info, null, &ctx.image_available_semaphores[ctx.current_sync_frame]);
    _ = c.vkCreateSemaphore(ctx.vulkan_device.vk_device, &semaphore_info, null, &ctx.render_finished_semaphores[ctx.current_sync_frame]);

    ctx.frame_in_progress = false;
}

fn beginGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress or ctx.g_pass_active) return;

    ensureNoRenderPassActive(ctx_ptr);

    ctx.g_pass_active = true;
    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.g_render_pass;
    render_pass_info.framebuffer = ctx.g_framebuffer;
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.vulkan_swapchain.extent;

    var clear_values: [2]c.VkClearValue = undefined;
    clear_values[0] = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    clear_values[1] = .{ .depthStencil = .{ .depth = 0.0, .stencil = 0 } };
    render_pass_info.clearValueCount = 2;
    render_pass_info.pClearValues = &clear_values[0];

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.vulkan_swapchain.extent.width), .height = @floatFromInt(ctx.vulkan_swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.vulkan_swapchain.extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.descriptor_sets[ctx.current_sync_frame], 0, null);
}

fn endGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.g_pass_active) return;
    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.g_pass_active = false;
}

fn computeSSAO(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    ensureNoRenderPassActive(ctx_ptr);

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    // Update SSAO Params UBO
    if (ctx.ssao_kernel_ubo.memory != null) {
        var data: ?*anyopaque = null;
        _ = c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.ssao_kernel_ubo.memory, 0, @sizeOf(SSAOParams), 0, &data);
        if (data) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(SSAOParams)], std.mem.asBytes(&ctx.ssao_params));
            c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.ssao_kernel_ubo.memory);
        }
    }

    // 1. SSAO Pass
    {
        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.ssao_render_pass;
        render_pass_info.framebuffer = ctx.ssao_framebuffer;
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.vulkan_swapchain.extent;
        var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_pipeline);

        // Set viewport and scissor for SSAO pass
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.vulkan_swapchain.extent.width), .height = @floatFromInt(ctx.vulkan_swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.vulkan_swapchain.extent };
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_pipeline_layout, 0, 1, &ctx.ssao_descriptor_sets[ctx.current_sync_frame], 0, null);
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(command_buffer);
    }

    // 2. Blur Pass
    {
        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.ssao_blur_render_pass;
        render_pass_info.framebuffer = ctx.ssao_blur_framebuffer;
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.vulkan_swapchain.extent;
        var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_blur_pipeline);

        // Set viewport and scissor for blur pass
        const blur_viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.vulkan_swapchain.extent.width), .height = @floatFromInt(ctx.vulkan_swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(command_buffer, 0, 1, &blur_viewport);
        const blur_scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.vulkan_swapchain.extent };
        c.vkCmdSetScissor(command_buffer, 0, 1, &blur_scissor);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_blur_pipeline_layout, 0, 1, &ctx.ssao_blur_descriptor_sets[ctx.current_sync_frame], 0, null);
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(command_buffer);
    }
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

    _ = c.vkQueueSubmit(ctx.vulkan_device.queue, 1, &submit_info, ctx.in_flight_fences[ctx.current_sync_frame]);

    var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
    present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present_info.waitSemaphoreCount = 1;
    present_info.pWaitSemaphores = &signal_semaphores;

    const swapchains = [_]c.VkSwapchainKHR{ctx.vulkan_swapchain.handle};
    present_info.swapchainCount = 1;
    present_info.pSwapchains = &swapchains;
    present_info.pImageIndices = &ctx.image_index;

    const result = c.vkQueuePresentKHR(ctx.vulkan_device.queue, &present_info);

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
    if (ctx.shadow_image == null) return;

    const old_layout = ctx.shadow_image_layouts[cascade_index];
    if (old_layout == new_layout) return;

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) c.VK_IMAGE_LAYOUT_UNDEFINED else old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = ctx.shadow_image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = @intCast(cascade_index);
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
    if (!ctx.frame_in_progress) return;
    if (ctx.vulkan_swapchain.extent.width == 0 or ctx.vulkan_swapchain.extent.height == 0) return;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];
    if (!ctx.main_pass_active) {
        ensureNoRenderPassActive(ctx_ptr);

        ctx.terrain_pipeline_bound = false;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.vulkan_swapchain.main_render_pass;
        render_pass_info.framebuffer = ctx.vulkan_swapchain.framebuffers.items[ctx.image_index];
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.vulkan_swapchain.extent;

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

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.main_pass_active = true;
    }

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(ctx.vulkan_swapchain.extent.width);
    viewport.height = @floatFromInt(ctx.vulkan_swapchain.extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.vulkan_swapchain.extent;
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
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
    if (ctx.vulkan_device.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    ctx.current_view_proj = view_proj;

    const uniforms = GlobalUniforms{
        .view_proj = view_proj,
        .cam_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0 },
        .sun_dir = .{ sun_dir.x, sun_dir.y, sun_dir.z, 0 },
        .sun_color = .{ sun_color.x, sun_color.y, sun_color.z, 0 },
        .fog_color = .{ fog_color.x, fog_color.y, fog_color.z, 1 },
        .cloud_wind_offset = .{ cloud_params.wind_offset_x, cloud_params.wind_offset_z, cloud_params.cloud_scale, cloud_params.cloud_coverage },
        .params = .{ time_val, fog_density, if (fog_enabled) 1.0 else 0.0, sun_intensity },
        .lighting = .{ ambient, if (use_texture) 1.0 else 0.0, if (cloud_params.pbr_enabled) 1.0 else 0.0, 0.15 },
        .cloud_params = .{ cloud_params.cloud_height, @floatFromInt(cloud_params.shadow_samples), if (cloud_params.shadow_blend) 1.0 else 0.0, if (cloud_params.cloud_shadows) 1.0 else 0.0 },
        .pbr_params = .{ @floatFromInt(cloud_params.pbr_quality), cloud_params.exposure, cloud_params.saturation, if (cloud_params.ssao_enabled) 1.0 else 0.0 },
        .volumetric_params = .{ if (cloud_params.volumetric_enabled) 1.0 else 0.0, cloud_params.volumetric_density, @floatFromInt(cloud_params.volumetric_steps), cloud_params.volumetric_scattering },
        .viewport_size = .{ @floatFromInt(ctx.vulkan_swapchain.extent.width), @floatFromInt(ctx.vulkan_swapchain.extent.height), 0, 0 },
    };

    if (ctx.global_ubos_mapped[ctx.current_sync_frame]) |map_ptr| {
        const mapped: *GlobalUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = uniforms;
    }
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4, mask_radius: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.current_model = model;
    ctx.current_mask_radius = mask_radius;
}

fn setInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    ctx.pending_instance_buffer = handle;
    ctx.lod_mode = false;
    applyPendingDescriptorUpdates(ctx, ctx.current_sync_frame);
}

fn setLODInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    ctx.pending_lod_instance_buffer = handle;
    ctx.lod_mode = true;
    applyPendingDescriptorUpdates(ctx, ctx.current_sync_frame);
}

fn applyPendingDescriptorUpdates(ctx: *VulkanContext, frame_index: usize) void {
    if (ctx.pending_instance_buffer != 0 and ctx.bound_instance_buffer[frame_index] != ctx.pending_instance_buffer) {
        ctx.mutex.lock();
        const buf_opt = ctx.buffers.get(ctx.pending_instance_buffer);
        ctx.mutex.unlock();

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptor_sets[frame_index];
            write.dstBinding = 5; // Instance SSBO
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.bound_instance_buffer[frame_index] = ctx.pending_instance_buffer;
        }
    }

    if (ctx.pending_lod_instance_buffer != 0 and ctx.bound_lod_instance_buffer[frame_index] != ctx.pending_lod_instance_buffer) {
        ctx.mutex.lock();
        const buf_opt = ctx.buffers.get(ctx.pending_lod_instance_buffer);
        ctx.mutex.unlock();

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.lod_descriptor_sets[frame_index];
            write.dstBinding = 5; // Instance SSBO
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.bound_lod_instance_buffer[frame_index] = ctx.pending_lod_instance_buffer;
        }
    }
}

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.textures_enabled = texture_enabled;
    _ = shadow_map_handles;
    // Force descriptor update so internal shadow maps are bound
    ctx.descriptors_updated = false;
}

fn beginCloudPass(ctx_ptr: *anyopaque, params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);
    if (!ctx.main_pass_active) return;

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

    const width_f32 = @as(f32, @floatFromInt(ctx.vulkan_swapchain.extent.width));
    const height_f32 = @as(f32, @floatFromInt(ctx.vulkan_swapchain.extent.height));
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

        const frame = ctx.current_sync_frame;
        const idx = ctx.debug_shadow_descriptor_next[frame];
        const pool_len = ctx.debug_shadow_descriptor_pool[frame].len;
        ctx.debug_shadow_descriptor_next[frame] = @intCast((idx + 1) % pool_len);
        const ds = ctx.debug_shadow_descriptor_pool[frame][idx];

        var write_set = std.mem.zeroes(c.VkWriteDescriptorSet);
        write_set.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write_set.dstSet = ds;
        write_set.dstBinding = 0;
        write_set.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write_set.descriptorCount = 1;
        write_set.pImageInfo = &image_info;

        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write_set, 0, null);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow_pipeline_layout, 0, 1, &ds, 0, null);
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
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.debug_shadow_vbo.memory, 0, @sizeOf(@TypeOf(debug_vertices)), 0, &map_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(map_ptr.?))[0..@sizeOf(@TypeOf(debug_vertices))], std.mem.asBytes(&debug_vertices));
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.debug_shadow_vbo.memory);

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
        .rgba_srgb => c.VK_FORMAT_R8G8B8A8_SRGB, // Hardware sRGB->Linear decode
        .rgb => c.VK_FORMAT_R8G8B8_UNORM,
        .red => c.VK_FORMAT_R8_UNORM,
        .depth => c.VK_FORMAT_D32_SFLOAT,
        .rgba32f => c.VK_FORMAT_R32G32B32A32_SFLOAT,
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

    if (c.vkCreateImage(ctx.vulkan_device.vk_device, &image_info, null, &image) != c.VK_SUCCESS) return 0;

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, image, &mem_reqs);

    var memory: c.VkDeviceMemory = null;
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    if (c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
        c.vkDestroyImage(ctx.vulkan_device.vk_device, image, null);
        return 0;
    }
    if (c.vkBindImageMemory(ctx.vulkan_device.vk_device, image, memory, 0) != c.VK_SUCCESS) {
        c.vkFreeMemory(ctx.vulkan_device.vk_device, memory, null);
        c.vkDestroyImage(ctx.vulkan_device.vk_device, image, null);
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
                c.vkDestroyBuffer(ctx.vulkan_device.vk_device, staging_buffer.buffer, null);
                c.vkFreeMemory(ctx.vulkan_device.vk_device, staging_buffer.memory, null);
            }

            var map_ptr: ?*anyopaque = null;
            if (c.vkMapMemory(ctx.vulkan_device.vk_device, staging_buffer.memory, 0, data.len, 0, &map_ptr) == c.VK_SUCCESS) {
                @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
                c.vkUnmapMemory(ctx.vulkan_device.vk_device, staging_buffer.memory);
            }

            // Alloc temp command buffer
            var temp_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
            temp_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            temp_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            temp_alloc_info.commandPool = ctx.transfer_command_pool;
            temp_alloc_info.commandBufferCount = 1;

            var temp_cb: c.VkCommandBuffer = null;
            _ = c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &temp_alloc_info, &temp_cb);

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

            _ = c.vkQueueSubmit(ctx.vulkan_device.queue, 1, &submit_info, null);
            _ = c.vkQueueWaitIdle(ctx.vulkan_device.queue);

            c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.transfer_command_pool, 1, &temp_cb);
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

    _ = c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &view);

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
        c.vkDestroySampler(ctx.vulkan_device.vk_device, entry.value.sampler, null);
        c.vkDestroyImageView(ctx.vulkan_device.vk_device, entry.value.view, null);
        c.vkFreeMemory(ctx.vulkan_device.vk_device, entry.value.memory, null);
        c.vkDestroyImage(ctx.vulkan_device.vk_device, entry.value.image, null);
    }
}

fn bindTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const resolved = if (handle == 0) switch (slot) {
        6 => ctx.dummy_normal_texture,
        7, 8 => ctx.dummy_roughness_texture,
        9 => ctx.dummy_texture,
        0, 1 => ctx.dummy_texture,
        else => ctx.dummy_texture,
    } else handle;

    switch (slot) {
        0, 1 => ctx.current_texture = resolved,
        6 => ctx.current_normal_texture = resolved,
        7 => ctx.current_roughness_texture = resolved,
        8 => ctx.current_displacement_texture = resolved,
        9 => ctx.current_env_texture = resolved,
        else => ctx.current_texture = resolved,
    }
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
            c.vkDestroyBuffer(ctx.vulkan_device.vk_device, staging_buffer.buffer, null);
            c.vkFreeMemory(ctx.vulkan_device.vk_device, staging_buffer.memory, null);
        }

        var map_ptr: ?*anyopaque = null;
        if (c.vkMapMemory(ctx.vulkan_device.vk_device, staging_buffer.memory, 0, data.len, 0, &map_ptr) == c.VK_SUCCESS) {
            @memcpy(@as([*]u8, @ptrCast(map_ptr))[0..data.len], data);
            c.vkUnmapMemory(ctx.vulkan_device.vk_device, staging_buffer.memory);
        }

        // Alloc temp command buffer
        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandPool = ctx.transfer_command_pool;
        alloc_info.commandBufferCount = 1;

        var temp_cb: c.VkCommandBuffer = null;
        _ = c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &alloc_info, &temp_cb);

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

        _ = c.vkQueueSubmit(ctx.vulkan_device.queue, 1, &submit_info, null);
        _ = c.vkQueueWaitIdle(ctx.vulkan_device.queue);

        c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.transfer_command_pool, 1, &temp_cb);
    }
}

fn setViewport(ctx_ptr: *anyopaque, width: u32, height: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    // Check if the requested viewport size matches the current swapchain extent.
    // If not, flag a resize so the swapchain is recreated at the beginning of the next frame.
    if (width != ctx.vulkan_swapchain.extent.width or height != ctx.vulkan_swapchain.extent.height) {
        ctx.framebuffer_resized = true;
    }

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

fn getFrameIndex(ctx_ptr: *anyopaque) usize {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intCast(ctx.current_sync_frame);
}

fn supportsIndirectFirstInstance(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.draw_indirect_first_instance;
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
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.vulkan_device.physical_device, ctx.vulkan_device.surface, &mode_count, null);

    if (mode_count == 0) return;

    var modes: [8]c.VkPresentModeKHR = undefined;
    var actual_count: u32 = @min(mode_count, 8);
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.vulkan_device.physical_device, ctx.vulkan_device.surface, &actual_count, &modes);

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
    const clamped = @min(level, @as(u8, @intFromFloat(ctx.vulkan_device.max_anisotropy)));
    if (ctx.anisotropic_filtering == clamped) return;

    ctx.anisotropic_filtering = clamped;

    // Apply immediately: recreate all texture samplers
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    var it = ctx.textures.iterator();
    while (it.next()) |entry| {
        const tex = entry.value_ptr;
        c.vkDestroySampler(ctx.vulkan_device.vk_device, tex.sampler, null);

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
    const clamped = @min(samples, ctx.vulkan_device.max_msaa_samples);
    if (ctx.msaa_samples == clamped) return;

    ctx.msaa_samples = clamped;
    ctx.framebuffer_resized = true; // Triggers recreateSwapchain on next frame
    std.log.info("Vulkan MSAA set to {}x (pending swapchain recreation)", .{clamped});
}

fn getMaxAnisotropy(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromFloat(@min(ctx.vulkan_device.max_anisotropy, 16.0));
}

fn getMaxMSAASamples(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.max_msaa_samples;
}

fn drawIndexed(ctx_ptr: *anyopaque, vbo_handle: rhi.BufferHandle, ebo_handle: rhi.BufferHandle, count: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) beginMainPass(ctx_ptr);

    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) return;

    ctx.mutex.lock();
    const vbo_opt = ctx.buffers.get(vbo_handle);
    const ebo_opt = ctx.buffers.get(ebo_handle);
    ctx.mutex.unlock();

    if (vbo_opt) |vbo| {
        if (ebo_opt) |ebo| {
            ctx.draw_call_count += 1;
            const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

            // Use simple pipeline binding logic
            if (!ctx.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                    ctx.wireframe_pipeline
                else
                    ctx.pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.terrain_pipeline_bound = true;
            }

            const descriptor_set = if (ctx.lod_mode)
                &ctx.lod_descriptor_sets[ctx.current_sync_frame]
            else
                &ctx.descriptor_sets[ctx.current_sync_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);

            const offset: c.VkDeviceSize = 0;
            c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset);
            c.vkCmdBindIndexBuffer(command_buffer, ebo.buffer, 0, c.VK_INDEX_TYPE_UINT16);
            c.vkCmdDrawIndexed(command_buffer, count, 1, 0, 0, 0);
        }
    }
}

fn drawIndirect(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) beginMainPass(ctx_ptr);

    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) return;

    const use_shadow = ctx.shadow_pass_active;
    const use_g_pass = ctx.g_pass_active;

    ctx.mutex.lock();
    const vbo_opt = ctx.buffers.get(handle);
    const cmd_opt = ctx.buffers.get(command_buffer);
    ctx.mutex.unlock();

    if (vbo_opt) |vbo| {
        if (cmd_opt) |cmd| {
            ctx.draw_call_count += 1;
            const cb = ctx.command_buffers[ctx.current_sync_frame];

            if (use_shadow) {
                if (!ctx.shadow_pipeline_bound) {
                    if (ctx.shadow_pipeline == null) return;
                    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_pipeline);
                    ctx.shadow_pipeline_bound = true;
                }
            } else if (use_g_pass) {
                if (ctx.g_pipeline == null) return;
                c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);
            } else {
                if (!ctx.terrain_pipeline_bound) {
                    const selected_pipeline = if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                        ctx.wireframe_pipeline
                    else
                        ctx.pipeline;
                    if (selected_pipeline == null) {
                        std.log.warn("drawIndirect: main pipeline (selected_pipeline) is null - cannot draw terrain", .{});
                        return;
                    }
                    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                    ctx.terrain_pipeline_bound = true;
                }
            }

            const descriptor_set = if (!use_shadow and ctx.lod_mode)
                &ctx.lod_descriptor_sets[ctx.current_sync_frame]
            else
                &ctx.descriptor_sets[ctx.current_sync_frame];
            c.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);

            if (use_shadow) {
                const shadow_uniforms = ShadowModelUniforms{
                    .light_space_matrix = ctx.shadow_pass_matrix,
                    .model = Mat4.identity,
                };
                c.vkCmdPushConstants(cb, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
            } else {
                const uniforms = ModelUniforms{
                    .model = Mat4.identity,
                    .mask_radius = 0,
                    .padding = .{ 0, 0, 0 },
                };
                c.vkCmdPushConstants(cb, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
            }

            const offset_vals = [_]c.VkDeviceSize{0};
            c.vkCmdBindVertexBuffers(cb, 0, 1, &vbo.buffer, &offset_vals);

            if (cmd.is_host_visible and draw_count > 0 and stride > 0) {
                const stride_bytes: usize = @intCast(stride);
                const map_size: usize = @as(usize, @intCast(draw_count)) * stride_bytes;
                const cmd_size: usize = @intCast(cmd.size);
                if (offset <= cmd_size and map_size <= cmd_size - offset) {
                    var map_ptr: ?*anyopaque = null;
                    if (c.vkMapMemory(ctx.vulkan_device.vk_device, cmd.memory, 0, cmd.size, 0, &map_ptr) == c.VK_SUCCESS and map_ptr != null) {
                        const base = @as([*]const u8, @ptrCast(map_ptr.?)) + offset;
                        var draw_index: u32 = 0;
                        while (draw_index < draw_count) : (draw_index += 1) {
                            const cmd_ptr = @as(*const rhi.DrawIndirectCommand, @ptrCast(@alignCast(base + @as(usize, draw_index) * stride_bytes)));
                            const draw_cmd = cmd_ptr.*;
                            if (draw_cmd.vertexCount == 0 or draw_cmd.instanceCount == 0) continue;
                            c.vkCmdDraw(cb, draw_cmd.vertexCount, draw_cmd.instanceCount, draw_cmd.firstVertex, draw_cmd.firstInstance);
                        }
                        c.vkUnmapMemory(ctx.vulkan_device.vk_device, cmd.memory);
                        return;
                    }
                    if (map_ptr != null) c.vkUnmapMemory(ctx.vulkan_device.vk_device, cmd.memory);
                } else {
                    std.log.warn("drawIndirect: command buffer range out of bounds (offset={}, size={}, buffer={})", .{ offset, map_size, cmd_size });
                }
            }

            if (ctx.vulkan_device.multi_draw_indirect) {
                c.vkCmdDrawIndirect(cb, cmd.buffer, @intCast(offset), draw_count, stride);
            } else {
                const stride_bytes: usize = @intCast(stride);
                var draw_index: u32 = 0;
                while (draw_index < draw_count) : (draw_index += 1) {
                    const draw_offset = offset + @as(usize, draw_index) * stride_bytes;
                    c.vkCmdDrawIndirect(cb, cmd.buffer, @intCast(draw_offset), 1, stride);
                }
                std.log.info("drawIndirect: MDI unsupported - drew {} draws via single-draw fallback", .{draw_count});
            }
        }
    }
}

fn drawInstance(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) beginMainPass(ctx_ptr);

    const use_shadow = ctx.shadow_pass_active;
    const use_g_pass = ctx.g_pass_active;

    ctx.mutex.lock();
    const vbo_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (vbo_opt) |vbo| {
        ctx.draw_call_count += 1;
        const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

        if (use_shadow) {
            if (!ctx.shadow_pipeline_bound) {
                if (ctx.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_pipeline);
                ctx.shadow_pipeline_bound = true;
            }
        } else if (use_g_pass) {
            if (ctx.g_pipeline == null) return;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);
        } else {
            if (!ctx.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                    ctx.wireframe_pipeline
                else
                    ctx.pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.terrain_pipeline_bound = true;
            }
        }

        const descriptor_set = if (!use_shadow and ctx.lod_mode)
            &ctx.lod_descriptor_sets[ctx.current_sync_frame]
        else
            &ctx.descriptor_sets[ctx.current_sync_frame];
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);

        if (use_shadow) {
            const shadow_uniforms = ShadowModelUniforms{
                .light_space_matrix = ctx.shadow_pass_matrix,
                .model = Mat4.identity,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = Mat4.identity,
                .mask_radius = 0,
                .padding = .{ 0, 0, 0 },
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
        }

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, count, 1, 0, instance_index);
    }
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    drawOffset(ctx_ptr, handle, count, mode, 0);
}

fn drawOffset(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) beginMainPass(ctx_ptr);

    // If we failed to start a pass (e.g. minimized window), abort draw
    if (!ctx.main_pass_active and !ctx.shadow_pass_active and !ctx.g_pass_active) return;

    _ = mode;

    const use_shadow = ctx.shadow_pass_active;
    const use_g_pass = ctx.g_pass_active;

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
                ctx.shadow_pipeline_bound = true;
            }
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.descriptor_sets[ctx.current_sync_frame], 0, null);
        } else if (use_g_pass) {
            if (ctx.g_pipeline == null) return;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);

            const descriptor_set = if (ctx.lod_mode)
                &ctx.lod_descriptor_sets[ctx.current_sync_frame]
            else
                &ctx.descriptor_sets[ctx.current_sync_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);
        } else {
            if (!ctx.terrain_pipeline_bound) {
                const selected_pipeline = if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                    ctx.wireframe_pipeline
                else
                    ctx.pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                ctx.terrain_pipeline_bound = true;
            }

            const descriptor_set = if (ctx.lod_mode)
                &ctx.lod_descriptor_sets[ctx.current_sync_frame]
            else
                &ctx.descriptor_sets[ctx.current_sync_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);
        }

        if (use_shadow) {
            const shadow_uniforms = ShadowModelUniforms{
                .light_space_matrix = ctx.shadow_pass_matrix,
                .model = ctx.current_model,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = ctx.current_model,
                .mask_radius = ctx.current_mask_radius,
                .padding = .{ 0, 0, 0 },
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ModelUniforms), &uniforms);
        }

        const offset_vbo: c.VkDeviceSize = @intCast(offset);
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &offset_vbo);
        c.vkCmdDraw(command_buffer, count, 1, 0, 0);
    }
}

fn flushUI(ctx: *VulkanContext) void {
    if (!ctx.main_pass_active) return;
    if (ctx.ui_vertex_offset / (6 * @sizeOf(f32)) > ctx.ui_flushed_vertex_count) {
        const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

        const total_vertices: u32 = @intCast(ctx.ui_vertex_offset / (6 * @sizeOf(f32)));
        const count = total_vertices - ctx.ui_flushed_vertex_count;

        c.vkCmdDraw(command_buffer, count, 1, ctx.ui_flushed_vertex_count, 0);
        ctx.ui_flushed_vertex_count = total_vertices;
    }
}

fn bindBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    ctx.mutex.lock();
    const buf_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (buf_opt) |buf| {
        const cb = ctx.command_buffers[ctx.current_sync_frame];
        const offset: c.VkDeviceSize = 0;
        switch (usage) {
            .vertex => c.vkCmdBindVertexBuffers(cb, 0, 1, &buf.buffer, &offset),
            .index => c.vkCmdBindIndexBuffer(cb, buf.buffer, 0, c.VK_INDEX_TYPE_UINT16),
            else => {},
        }
    }
}

fn pushConstants(ctx_ptr: *anyopaque, stages: rhi.ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    var vk_stages: c.VkShaderStageFlags = 0;
    if (stages.vertex) vk_stages |= c.VK_SHADER_STAGE_VERTEX_BIT;
    if (stages.fragment) vk_stages |= c.VK_SHADER_STAGE_FRAGMENT_BIT;
    if (stages.compute) vk_stages |= c.VK_SHADER_STAGE_COMPUTE_BIT;

    const cb = ctx.command_buffers[ctx.current_sync_frame];
    // Currently we only have one main pipeline layout used for everything.
    // In a more SOLID system, we'd bind the layout associated with the current shader.
    c.vkCmdPushConstants(cb, ctx.pipeline_layout, vk_stages, offset, size, data);
}

// 2D Rendering functions
fn begin2DPass(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);
    if (!ctx.main_pass_active) return;

    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;
    ctx.ui_in_progress = true;

    // Map current frame's UI VBO memory
    const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ui_vbo.memory, 0, ui_vbo.size, 0, &ctx.ui_mapped_ptr) != c.VK_SUCCESS) {
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

    // Force Viewport/Scissor to match UI screen size
    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = ctx.ui_screen_width, .height = ctx.ui_screen_height, .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = @intFromFloat(ctx.ui_screen_width), .height = @intFromFloat(ctx.ui_screen_height) } };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

fn end2DPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.ui_in_progress) return;

    if (ctx.ui_mapped_ptr != null) {
        const ui_vbo = ctx.ui_vbos[ctx.current_sync_frame];
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, ui_vbo.memory);
        ctx.ui_mapped_ptr = null;
    }

    flushUI(ctx);
    ctx.ui_in_progress = false;
}

fn drawRect2D(ctx_ptr: *anyopaque, rect: rhi.Rect, color: rhi.Color) void {
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

fn bindUIPipeline(ctx_ptr: *anyopaque, textured: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    // Reset this so other pipelines know to rebind if they are called next
    ctx.terrain_pipeline_bound = false;

    const command_buffer = ctx.command_buffers[ctx.current_sync_frame];

    if (textured) {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline);
    } else {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_pipeline);
    }
}

fn drawTexture2D(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress or !ctx.ui_in_progress) return;

    // 1. Flush normal UI if any
    flushUI(ctx);

    const tex_opt = ctx.textures.get(texture);
    if (tex_opt == null) {
        std.log.err("drawTexture2D: Texture handle {} not found in textures map!", .{texture});
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

    const frame = ctx.current_sync_frame;
    const idx = ctx.ui_tex_descriptor_next[frame];
    const pool_len = ctx.ui_tex_descriptor_pool[frame].len;
    ctx.ui_tex_descriptor_next[frame] = @intCast((idx + 1) % pool_len);
    const ds = ctx.ui_tex_descriptor_pool[frame][idx];

    var write = std.mem.zeroes(c.VkWriteDescriptorSet);
    write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = ds;
    write.dstBinding = 0;
    write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.descriptorCount = 1;
    write.pImageInfo = &image_info;

    c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline_layout, 0, 1, &ds, 0, null);

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
    c.vkCmdPushConstants(command_buffer, ctx.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
}

fn ensureNoRenderPassActive(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.main_pass_active) endMainPass(ctx_ptr);
    if (ctx.shadow_pass_active) endShadowPass(ctx_ptr);
    if (ctx.g_pass_active) endGPass(ctx_ptr);
}

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;

    if (ctx.shadow_framebuffers[cascade_index] == null) return;

    ctx.shadow_pass_active = true;
    ctx.shadow_pass_index = cascade_index;
    ctx.shadow_pass_matrix = light_space_matrix;
    ctx.shadow_pipeline_bound = false;

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
    ctx.shadow_pass_matrix = light_space_matrix;

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

    if (ctx.shadow_ubos_mapped[ctx.current_sync_frame]) |map_ptr| {
        const mapped: *ShadowUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = shadow_uniforms;
    }
}

fn drawSky(ctx_ptr: *anyopaque, params: rhi.SkyParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frame_in_progress) return;
    if (!ctx.main_pass_active) beginMainPass(ctx_ptr);
    if (!ctx.main_pass_active) return;

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
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.sky_pipeline_layout, 0, 1, &ctx.descriptor_sets[ctx.current_sync_frame], 0, null);
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

fn mapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) ?*anyopaque {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    const buf_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (buf_opt) |buf| {
        var map_ptr: ?*anyopaque = null;
        if (c.vkMapMemory(ctx.vulkan_device.vk_device, buf.memory, 0, buf.size, 0, &map_ptr) == c.VK_SUCCESS) {
            return map_ptr;
        }
    }
    return null;
}

fn unmapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    const buf_opt = ctx.buffers.get(handle);
    ctx.mutex.unlock();

    if (buf_opt) |buf| {
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, buf.memory);
    }
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
    .resources = .{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .createTexture = createTexture,
        .destroyTexture = destroyTexture,
        .updateTexture = updateTexture,
        .createShader = createShader,
        .destroyShader = destroyShader,
        .mapBuffer = mapBuffer,
        .unmapBuffer = unmapBuffer,
    },
    .render = .{
        .beginFrame = beginFrame,
        .endFrame = endFrame,
        .abortFrame = abortFrame,
        .beginMainPass = beginMainPass,
        .endMainPass = endMainPass,
        .beginShadowPass = beginShadowPass,
        .endShadowPass = endShadowPass,
        .beginGPass = beginGPass,
        .endGPass = endGPass,
        .computeSSAO = computeSSAO,
        .bindShader = bindShader,
        .bindTexture = bindTexture,
        .setModelMatrix = setModelMatrix,
        .setInstanceBuffer = setInstanceBuffer,
        .setLODInstanceBuffer = setLODInstanceBuffer,
        .updateGlobalUniforms = updateGlobalUniforms,
        .updateShadowUniforms = updateShadowUniforms,
        .setTextureUniforms = setTextureUniforms,
        .draw = draw,
        .drawOffset = drawOffset,
        .drawIndexed = drawIndexed,
        .drawIndirect = drawIndirect,
        .drawInstance = drawInstance,
        .setViewport = setViewport,
        .bindBuffer = bindBuffer,
        .pushConstants = pushConstants,
        .setClearColor = setClearColor,
        .begin2DPass = begin2DPass,
        .end2DPass = end2DPass,
        .drawRect2D = drawRect2D,
        .drawTexture2D = drawTexture2D,
        .drawSky = drawSky,
        .beginCloudPass = beginCloudPass,
        .drawDebugShadowMap = drawDebugShadowMap,
        .bindUIPipeline = bindUIPipeline,
    },
    .query = .{
        .getFrameIndex = getFrameIndex,
        .supportsIndirectFirstInstance = supportsIndirectFirstInstance,
        .getMaxAnisotropy = getMaxAnisotropy,
        .getMaxMSAASamples = getMaxMSAASamples,
        .waitIdle = waitIdle,
    },
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setVSync = setVSync,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setMSAA = setMSAA,
};

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    @memset(std.mem.asBytes(ctx), 0);

    // Initialize all fields to safe defaults
    ctx.allocator = allocator;
    ctx.render_device = render_device;
    ctx.shadow_resolution = shadow_resolution;
    ctx.window = window;
    ctx.vulkan_device = .{
        .allocator = allocator,
    };
    ctx.vulkan_swapchain = .{
        .device = &ctx.vulkan_device,
        .window = window,
        .allocator = allocator,
    };
    ctx.framebuffer_resized = false;

    ctx.draw_call_count = 0;
    ctx.buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(allocator);
    ctx.next_buffer_handle = 1;
    ctx.textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(allocator);
    ctx.next_texture_handle = 1;
    ctx.current_texture = 0;
    ctx.current_normal_texture = 0;
    ctx.current_roughness_texture = 0;
    ctx.current_displacement_texture = 0;
    ctx.current_env_texture = 0;
    ctx.dummy_texture = 0;
    ctx.dummy_normal_texture = 0;
    ctx.dummy_roughness_texture = 0;
    ctx.mutex = .{};
    ctx.vulkan_swapchain.images = .empty;
    ctx.vulkan_swapchain.image_views = .empty;
    ctx.vulkan_swapchain.framebuffers = .empty;
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
    ctx.bound_normal_texture = 0;
    ctx.bound_roughness_texture = 0;
    ctx.bound_displacement_texture = 0;
    ctx.bound_env_texture = 0;
    ctx.current_mask_radius = 0;
    ctx.lod_mode = false;
    ctx.pending_instance_buffer = 0;
    ctx.pending_lod_instance_buffer = 0;

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
    ctx.vulkan_swapchain.main_render_pass = null;
    ctx.vulkan_swapchain.handle = null;
    ctx.vulkan_swapchain.depth_image = null;
    ctx.vulkan_swapchain.depth_image_view = null;
    ctx.vulkan_swapchain.depth_image_memory = null;
    ctx.vulkan_swapchain.msaa_color_image = null;
    ctx.vulkan_swapchain.msaa_color_view = null;
    ctx.vulkan_swapchain.msaa_color_memory = null;
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
    ctx.debug_shadow_descriptor_next = .{ 0, 0 };
    ctx.cloud_pipeline = null;
    ctx.cloud_pipeline_layout = null;
    ctx.cloud_vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_ebo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_mesh_size = 10000.0;
    ctx.descriptor_pool = null;
    ctx.descriptor_set_layout = null;
    ctx.memory_type_index = 0;
    ctx.anisotropic_filtering = anisotropic_filtering;
    ctx.msaa_samples = msaa_samples;
    ctx.shadow_sampler = null;

    ctx.shadow_extent = .{ .width = 0, .height = 0 };
    ctx.shadow_image = null;
    ctx.shadow_image_view = null;
    ctx.shadow_image_memory = null;
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
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
        ctx.lod_descriptor_sets[i] = null;
        ctx.ui_tex_descriptor_sets[i] = null;
        ctx.ui_tex_descriptor_next[i] = 0;
        ctx.bound_instance_buffer[i] = 0;
        ctx.bound_lod_instance_buffer[i] = 0;
        for (0..ctx.ui_tex_descriptor_pool[i].len) |j| {
            ctx.ui_tex_descriptor_pool[i][j] = null;
        }
        ctx.debug_shadow_descriptor_sets[i] = null;
        ctx.debug_shadow_descriptor_next[i] = 0;
        for (0..ctx.debug_shadow_descriptor_pool[i].len) |j| {
            ctx.debug_shadow_descriptor_pool[i][j] = null;
        }
        ctx.buffer_deletion_queue[i] = .empty;
    }
    ctx.model_ubo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.dummy_instance_buffer = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
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
