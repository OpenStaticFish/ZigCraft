//! Vulkan Rendering Hardware Interface (RHI) Backend
//!
//! This module implements the RHI interface for Vulkan, providing GPU abstraction.
//!
//! ## Robustness & Safety
//! The backend implements a Guarded Submission model to handle GPU hangs gracefully.
//! Every queue submission is wrapped in `submitGuarded()`, which detects `VK_ERROR_DEVICE_LOST`
//! and initiates a safe teardown or recovery path.
//!
//! Out-of-bounds GPU memory accesses are handled via `VK_EXT_robustness2`, which
//! ensures that such operations return safe values (zeros) rather than crashing
//! the system. Detailed fault information is logged using `VK_EXT_device_fault`.
//!
//! ## Recovery
//! When a GPU fault is detected, the `gpu_fault_detected` flag is set. The engine
//! attempts to stop further submissions and should ideally trigger a device recreation.
//! Currently, the engine logs the fault and requires an application restart for full recovery.
//!
//! ## Thread Safety
//! A mutex protects buffer/texture maps. Vulkan commands are NOT thread-safe
//! - all rendering must occur on the main thread. Queue submissions are synchronized
//! via an internal mutex in `VulkanDevice`.
//!
const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const VulkanDevice = @import("vulkan_device.zig").VulkanDevice;
const VulkanSwapchain = @import("vulkan_swapchain.zig").VulkanSwapchain;
const RenderDevice = @import("render_device.zig").RenderDevice;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const build_options = @import("build_options");

const resource_manager_pkg = @import("vulkan/resource_manager.zig");
const ResourceManager = resource_manager_pkg.ResourceManager;
const FrameManager = @import("vulkan/frame_manager.zig").FrameManager;
const SwapchainPresenter = @import("vulkan/swapchain_presenter.zig").SwapchainPresenter;
const DescriptorManager = @import("vulkan/descriptor_manager.zig").DescriptorManager;
const Utils = @import("vulkan/utils.zig");

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
    cloud_params: [4]f32, // x = cloud_height, y = pcf_samples, z = cascade_blend, w = cloud_shadows
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
    color: [3]f32,
    mask_radius: f32,
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

const VulkanBuffer = resource_manager_pkg.VulkanBuffer;
const TextureResource = resource_manager_pkg.TextureResource;

const ShadowSystem = @import("shadow_system.zig").ShadowSystem;

const DebugShadowResources = if (build_options.debug_shadows) struct {
    pipeline: ?c.VkPipeline = null,
    pipeline_layout: ?c.VkPipelineLayout = null,
    descriptor_set_layout: ?c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]?c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    descriptor_pool: [MAX_FRAMES_IN_FLIGHT][8]?c.VkDescriptorSet = .{.{null} ** 8} ** MAX_FRAMES_IN_FLIGHT,
    descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32 = .{0} ** MAX_FRAMES_IN_FLIGHT,
    vbo: VulkanBuffer = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false },
} else struct {};

/// Core Vulkan context containing all renderer state.
/// Owns Vulkan objects and manages their lifecycle.
const VulkanContext = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    render_device: ?*RenderDevice,

    // Subsystems
    vulkan_device: VulkanDevice,
    resources: ResourceManager,
    frames: FrameManager,
    swapchain: SwapchainPresenter,
    descriptors: DescriptorManager,

    // Legacy / Feature State

    // Dummy shadow texture for fallback
    dummy_shadow_image: c.VkImage,
    dummy_shadow_memory: c.VkDeviceMemory,
    dummy_shadow_view: c.VkImageView,

    // Uniforms (Model UBOs are per-draw/push constant, but we have a fallback/dummy?)
    // descriptor_manager handles Global and Shadow UBOs.
    // We still need dummy_instance_buffer?
    model_ubo: VulkanBuffer, // Is this used?
    dummy_instance_buffer: VulkanBuffer,

    transfer_fence: c.VkFence = null, // Keep for legacy sync if needed

    // Pipeline
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,

    sky_pipeline: c.VkPipeline,
    sky_pipeline_layout: c.VkPipelineLayout,

    // Binding State
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
    safe_mode: bool,

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
    // Track the extent G-pass resources were created with (for mismatch detection)
    g_pass_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    // SSAO Pipelines
    g_pipeline: c.VkPipeline = null,
    g_pipeline_layout: c.VkPipelineLayout = null,
    ssao_pipeline: c.VkPipeline = null,
    gpu_fault_detected: bool = false,
    ssao_pipeline_layout: c.VkPipelineLayout = null,
    ssao_blur_pipeline: c.VkPipeline = null,
    ssao_blur_pipeline_layout: c.VkPipelineLayout = null,
    ssao_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    ssao_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    ssao_blur_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    ssao_blur_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,

    shadow_system: ShadowSystem,
    shadow_resolution: u32,
    memory_type_index: u32,
    framebuffer_resized: bool,
    draw_call_count: u32,
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,

    // Frame state
    frame_index: usize,
    image_index: u32,

    terrain_pipeline_bound: bool,
    descriptors_updated: bool,
    lod_mode: bool = false,
    bound_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    bound_lod_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    pending_instance_buffer: rhi.BufferHandle = 0,
    pending_lod_instance_buffer: rhi.BufferHandle = 0,
    current_view_proj: Mat4,
    current_model: Mat4,
    current_color: [3]f32,
    current_mask_radius: f32,
    mutex: std.Thread.Mutex,
    clear_color: [4]f32,

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

    debug_shadow: DebugShadowResources = .{},
};

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
    if (vk == null) return;

    if (ctx.ssao_pipeline != null) c.vkDestroyPipeline(vk, ctx.ssao_pipeline, null);
    if (ctx.ssao_blur_pipeline != null) c.vkDestroyPipeline(vk, ctx.ssao_blur_pipeline, null);
    if (ctx.ssao_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, ctx.ssao_pipeline_layout, null);
    if (ctx.ssao_blur_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, ctx.ssao_blur_pipeline_layout, null);

    // Free descriptor sets before destroying layout
    if (ctx.descriptors.descriptor_pool != null) {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            if (ctx.ssao_descriptor_sets[i] != null) {
                _ = c.vkFreeDescriptorSets(vk, ctx.descriptors.descriptor_pool, 1, &ctx.ssao_descriptor_sets[i]);
                ctx.ssao_descriptor_sets[i] = null;
            }
            if (ctx.ssao_blur_descriptor_sets[i] != null) {
                _ = c.vkFreeDescriptorSets(vk, ctx.descriptors.descriptor_pool, 1, &ctx.ssao_blur_descriptor_sets[i]);
                ctx.ssao_blur_descriptor_sets[i] = null;
            }
        }
    }

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

fn createShaderModule(device: c.VkDevice, code: []const u8) !c.VkShaderModule {
    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code.len;
    create_info.pCode = @ptrCast(@alignCast(code.ptr));

    var shader_module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(device, &create_info, null, &shader_module));
    return shader_module;
}

/// Finds memory type index matching filter and properties (e.g., HOST_VISIBLE).
fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
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
    return error.NoMatchingMemoryType;
}

/// Transitions an array of images to SHADER_READ_ONLY_OPTIMAL layout.
fn transitionImagesToShaderRead(ctx: *VulkanContext, images: []const c.VkImage, is_depth: bool) !void {
    if (images.len == 0) return;

    var cmd_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cmd_info.commandPool = ctx.frames.command_pool;
    cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_info.commandBufferCount = 1;

    var cmd: c.VkCommandBuffer = null;
    try Utils.checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cmd_info, &cmd));

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

    const count = @min(images.len, 4);
    const aspect_mask: c.VkImageAspectFlags = if (is_depth) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;

    var barriers: [4]c.VkImageMemoryBarrier = undefined;
    for (0..count) |i| {
        barriers[i] = std.mem.zeroes(c.VkImageMemoryBarrier);
        barriers[i].sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barriers[i].oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[i].newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barriers[i].srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].image = images[i];
        barriers[i].subresourceRange = .{ .aspectMask = aspect_mask, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        barriers[i].srcAccessMask = 0;
        barriers[i].dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    }

    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, @intCast(count), &barriers[0]);

    try Utils.checkVk(c.vkEndCommandBuffer(cmd));

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;
    try ctx.vulkan_device.submitGuarded(submit_info, null);
    try Utils.checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));
    c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.frames.command_pool, 1, &cmd);
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
fn createVulkanBuffer(ctx: *VulkanContext, size: usize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) !VulkanBuffer {
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = @intCast(size);
    buffer_info.usage = usage;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var buffer: c.VkBuffer = null;
    try Utils.checkVk(c.vkCreateBuffer(ctx.vulkan_device.vk_device, &buffer_info, null, &buffer));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(ctx.vulkan_device.vk_device, buffer, &mem_reqs);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, properties);

    var memory: c.VkDeviceMemory = null;
    try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &memory));
    try Utils.checkVk(c.vkBindBufferMemory(ctx.vulkan_device.vk_device, buffer, memory, 0));

    return .{
        .buffer = buffer,
        .memory = memory,
        .size = mem_reqs.size,
        .is_host_visible = (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0,
    };
}

/// Helper to create a texture sampler based on config and global anisotropy.
fn createMainRenderPass(ctx: *VulkanContext) !void {
    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);
    const use_msaa = ctx.msaa_samples > 1;
    const depth_format = DEPTH_FORMAT;

    if (use_msaa) {
        // MSAA render pass: 3 attachments (MSAA color, MSAA depth, resolve)
        var msaa_color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        msaa_color_attachment.format = ctx.swapchain.swapchain.image_format;
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
        depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var resolve_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        resolve_attachment.format = ctx.swapchain.swapchain.image_format;
        resolve_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        resolve_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        resolve_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        resolve_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        resolve_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        resolve_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        resolve_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        var resolve_ref = c.VkAttachmentReference{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;
        subpass.pDepthStencilAttachment = &depth_ref;
        subpass.pResolveAttachments = &resolve_ref;

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

        try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &render_pass_info, null, &ctx.swapchain.swapchain.main_render_pass));
        std.log.info("Created MSAA {}x render pass", .{ctx.msaa_samples});
    } else {
        // Non-MSAA render pass: 2 attachments (color, depth)
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = ctx.swapchain.swapchain.image_format;
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

        try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &render_pass_info, null, &ctx.swapchain.swapchain.main_render_pass));
    }
}

/// Creates G-Pass resources: render pass, normal image, framebuffer, and pipeline.
/// G-Pass outputs world-space normals to a RGB texture for SSAO sampling.
fn createShadowResources(ctx: *VulkanContext) !void {
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

    try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &shadow_rp_info, null, &ctx.shadow_system.shadow_render_pass));

    ctx.shadow_system.shadow_extent = .{ .width = shadow_res, .height = shadow_res };

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
    try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &shadow_img_info, null, &ctx.shadow_system.shadow_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.shadow_system.shadow_image, &mem_reqs);
    var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.shadow_system.shadow_image_memory));
    try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.shadow_system.shadow_image, ctx.shadow_system.shadow_image_memory, 0));

    // Full array view for sampling
    var array_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    array_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    array_view_info.image = ctx.shadow_system.shadow_image;
    array_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    array_view_info.format = DEPTH_FORMAT;
    array_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = rhi.SHADOW_CASCADE_COUNT };
    try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &array_view_info, null, &ctx.shadow_system.shadow_image_view));

    // Layered views for framebuffers (one per cascade)
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        var layer_view: c.VkImageView = null;
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.shadow_system.shadow_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = @intCast(si), .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &layer_view));
        ctx.shadow_system.shadow_image_views[si] = layer_view;

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.shadow_system.shadow_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.shadow_system.shadow_image_views[si];
        fb_info.width = shadow_res;
        fb_info.height = shadow_res;
        fb_info.layers = 1;
        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.shadow_system.shadow_framebuffers[si]));
        ctx.shadow_system.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    // Shadow Sampler
    {
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.anisotropyEnable = c.VK_FALSE;
        sampler_info.maxAnisotropy = 1.0;
        sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
        sampler_info.compareEnable = c.VK_TRUE;
        sampler_info.compareOp = c.VK_COMPARE_OP_LESS;

        try Utils.checkVk(c.vkCreateSampler(ctx.vulkan_device.vk_device, &sampler_info, null, &ctx.shadow_system.shadow_sampler));
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
        pipe_info.renderPass = ctx.shadow_system.shadow_render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.shadow_system.shadow_pipeline));
    }
}

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

        try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.g_render_pass));
    }

    // 2. Create normal image for G-Pass output
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.swapchain.swapchain.extent.width, .height = ctx.swapchain.swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = normal_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.g_normal_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.g_normal_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.g_normal_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.g_normal_image, ctx.g_normal_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_normal_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = normal_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.g_normal_view));
    }

    // 3. Create G-Pass depth image (separate from MSAA depth, 1x sampled for SSAO)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.swapchain.swapchain.extent.width, .height = ctx.swapchain.swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = DEPTH_FORMAT;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.g_depth_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.g_depth_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.g_depth_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.g_depth_image, ctx.g_depth_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_depth_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.g_depth_view));
    }

    // 4. Create G-Pass framebuffer
    {
        const fb_attachments = [_]c.VkImageView{ ctx.g_normal_view, ctx.g_depth_view };

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.g_render_pass;
        fb_info.attachmentCount = 2;
        fb_info.pAttachments = &fb_attachments;
        fb_info.width = ctx.swapchain.swapchain.extent.width;
        fb_info.height = ctx.swapchain.swapchain.extent.height;
        fb_info.layers = 1;

        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.g_framebuffer));
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

        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.g_pipeline));
    }

    // Transition G-buffer images to SHADER_READ_ONLY_OPTIMAL (needed if SSAO is disabled)
    const g_images = [_]c.VkImage{ctx.g_normal_image};
    try transitionImagesToShaderRead(ctx, &g_images, false);
    const d_images = [_]c.VkImage{ctx.g_depth_image};
    try transitionImagesToShaderRead(ctx, &d_images, true);

    // Store the extent we created resources with for mismatch detection
    ctx.g_pass_extent = ctx.swapchain.swapchain.extent;
    std.log.info("G-Pass resources created ({}x{})", .{ ctx.swapchain.swapchain.extent.width, ctx.swapchain.swapchain.extent.height });
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

        try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.ssao_render_pass));
        // Blur uses same format
        try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &rp_info, null, &ctx.ssao_blur_render_pass));
    }

    // 2. Create SSAO output image (store directly in context)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.swapchain.swapchain.extent.width, .height = ctx.swapchain.swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = ao_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_image, ctx.ssao_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ao_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_view));
    }

    // 3. Create SSAO blur output image
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = ctx.swapchain.swapchain.extent.width, .height = ctx.swapchain.swapchain.extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = ao_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_blur_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_blur_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_blur_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_blur_image, ctx.ssao_blur_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_blur_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ao_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_blur_view));
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

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &img_info, null, &ctx.ssao_noise_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.ssao_noise_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.ssao_noise_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.ssao_noise_image, ctx.ssao_noise_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.ssao_noise_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.ssao_noise_view));

        // Upload noise data via staging buffer
        const staging = try Utils.createVulkanBuffer(&ctx.vulkan_device, 16 * 4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
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
        cmd_info.commandPool = ctx.frames.command_pool;
        cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_info.commandBufferCount = 1;

        var cmd: c.VkCommandBuffer = null;
        try Utils.checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &cmd_info, &cmd));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

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

        try Utils.checkVk(c.vkEndCommandBuffer(cmd));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cmd;
        try ctx.vulkan_device.submitGuarded(submit_info, null);
        try Utils.checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));
        c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.frames.command_pool, 1, &cmd);
    }

    // 5. Create SSAO kernel UBO with hemisphere samples
    {
        ctx.ssao_kernel_ubo = try Utils.createVulkanBuffer(&ctx.vulkan_device, @sizeOf(SSAOParams), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

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
        fb_info.width = ctx.swapchain.swapchain.extent.width;
        fb_info.height = ctx.swapchain.swapchain.extent.height;
        fb_info.layers = 1;

        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.ssao_framebuffer));

        fb_info.renderPass = ctx.ssao_blur_render_pass;
        fb_info.pAttachments = &ctx.ssao_blur_view;
        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.ssao_blur_framebuffer));
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

        try Utils.checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_descriptor_set_layout));

        // Blur only needs: ssao texture (0)
        var blur_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        layout_info.bindingCount = 1;
        layout_info.pBindings = &blur_bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_blur_descriptor_set_layout));

        // Allocate descriptor sets from existing pool
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            var ds_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            ds_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            ds_alloc.descriptorPool = ctx.descriptors.descriptor_pool;
            ds_alloc.descriptorSetCount = 1;
            ds_alloc.pSetLayouts = &ctx.ssao_descriptor_set_layout;
            try Utils.checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_alloc, &ctx.ssao_descriptor_sets[i]));

            ds_alloc.pSetLayouts = &ctx.ssao_blur_descriptor_set_layout;
            try Utils.checkVk(c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &ds_alloc, &ctx.ssao_blur_descriptor_sets[i]));
        }
    }

    // 8. Create SSAO pipeline layout and pipeline
    {
        var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = &ctx.ssao_descriptor_set_layout;

        try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_pipeline_layout));

        layout_info.pSetLayouts = &ctx.ssao_blur_descriptor_set_layout;
        try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &layout_info, null, &ctx.ssao_blur_pipeline_layout));

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

        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.ssao_pipeline));

        // Blur pipeline
        stages[1].module = blur_frag_module;
        pipe_info.layout = ctx.ssao_blur_pipeline_layout;
        pipe_info.renderPass = ctx.ssao_blur_render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipe_info, null, &ctx.ssao_blur_pipeline));
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

        try Utils.checkVk(c.vkCreateSampler(ctx.vulkan_device.vk_device, &sampler_info, null, &ctx.ssao_sampler));
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

        // Binding 10: SSAO Map (blur output) in the MAIN descriptor sets
        var main_ssao_info = c.VkDescriptorImageInfo{
            .sampler = ctx.ssao_sampler,
            .imageView = ctx.ssao_blur_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var main_ssao_write = std.mem.zeroes(c.VkWriteDescriptorSet);
        main_ssao_write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        main_ssao_write.dstSet = ctx.descriptors.descriptor_sets[i];
        main_ssao_write.dstBinding = 10;
        main_ssao_write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        main_ssao_write.descriptorCount = 1;
        main_ssao_write.pImageInfo = &main_ssao_info;
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &main_ssao_write, 0, null);

        // Also update LOD descriptor sets
        main_ssao_write.dstSet = ctx.descriptors.lod_descriptor_sets[i];
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &main_ssao_write, 0, null);
    }

    // 11. Transition SSAO images to SHADER_READ_ONLY_OPTIMAL
    // This is needed because if SSAO is disabled, the pass is skipped,
    // but the terrain shader still samples the (undefined) texture.
    const ssao_images = [_]c.VkImage{ ctx.ssao_image, ctx.ssao_blur_image };
    try transitionImagesToShaderRead(ctx, &ssao_images, false);

    std.log.info("SSAO resources created ({}x{})", .{ ctx.swapchain.swapchain.extent.width, ctx.swapchain.swapchain.extent.height });
}

fn createMainFramebuffers(ctx: *VulkanContext) !void {
    const use_msaa = ctx.msaa_samples > 1;
    for (ctx.swapchain.swapchain.image_views.items) |iv| {
        var fb: c.VkFramebuffer = null;
        var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        framebuffer_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        framebuffer_info.width = ctx.swapchain.swapchain.extent.width;
        framebuffer_info.height = ctx.swapchain.swapchain.extent.height;
        framebuffer_info.layers = 1;

        if (use_msaa and ctx.swapchain.swapchain.msaa_color_view != null) {
            // MSAA framebuffer: [msaa_color, depth, swapchain_resolve]
            const fb_attachments = [_]c.VkImageView{ ctx.swapchain.swapchain.msaa_color_view.?, ctx.swapchain.swapchain.depth_image_view, iv };
            framebuffer_info.attachmentCount = 3;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &framebuffer_info, null, &fb));
        } else {
            // Non-MSAA framebuffer: [swapchain_color, depth]
            const fb_attachments = [_]c.VkImageView{ iv, ctx.swapchain.swapchain.depth_image_view };
            framebuffer_info.attachmentCount = 2;
            framebuffer_info.pAttachments = &fb_attachments[0];
            try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &framebuffer_info, null, &fb));
        }
        try ctx.swapchain.swapchain.framebuffers.append(ctx.allocator, fb);
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
        pipeline_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.pipeline));

        // Wireframe (No culling)
        var wireframe_rasterizer = rasterizer;
        wireframe_rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        wireframe_rasterizer.polygonMode = c.VK_POLYGON_MODE_LINE;
        pipeline_info.pRasterizationState = &wireframe_rasterizer;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.wireframe_pipeline));
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
        pipeline_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.sky_pipeline));
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
        pipeline_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_pipeline));

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
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_tex_pipeline));
    }

    // Debug Shadow
    if (comptime build_options.debug_shadows) {
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
        pipeline_info.layout = ctx.debug_shadow.pipeline_layout orelse return error.InitializationFailed;
        pipeline_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.debug_shadow.pipeline));
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
        pipeline_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.cloud_pipeline));
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
    if (ctx.ui_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.ui_pipeline, null);
        ctx.ui_pipeline = null;
    }
    if (ctx.ui_tex_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.ui_tex_pipeline, null);
        ctx.ui_tex_pipeline = null;
    }
    if (comptime build_options.debug_shadows) {
        if (ctx.debug_shadow.pipeline) |pipeline| c.vkDestroyPipeline(ctx.vulkan_device.vk_device, pipeline, null);
        ctx.debug_shadow.pipeline = null;
    }

    if (ctx.cloud_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.cloud_pipeline, null);
        ctx.cloud_pipeline = null;
    }
    if (ctx.swapchain.swapchain.main_render_pass != null) {
        c.vkDestroyRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.swapchain.main_render_pass, null);
        ctx.swapchain.swapchain.main_render_pass = null;
    }
}

fn initContext(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.render_device = render_device;

    ctx.vulkan_device = try VulkanDevice.init(allocator, ctx.window);
    ctx.resources = try ResourceManager.init(allocator, &ctx.vulkan_device);
    ctx.frames = try FrameManager.init(&ctx.vulkan_device);
    ctx.swapchain = try SwapchainPresenter.init(allocator, &ctx.vulkan_device, ctx.window, ctx.msaa_samples);
    ctx.descriptors = try DescriptorManager.init(allocator, &ctx.vulkan_device, &ctx.resources);

    ctx.shadow_system = try ShadowSystem.init(allocator, ctx.shadow_resolution);

    // Initialize defaults
    ctx.dummy_shadow_image = null;
    ctx.dummy_shadow_memory = null;
    ctx.dummy_shadow_view = null;
    ctx.clear_color = .{ 0.07, 0.08, 0.1, 1.0 };
    ctx.frames.frame_in_progress = false;
    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.shadow_system.pass_index = 0;
    ctx.ui_in_progress = false;
    ctx.ui_mapped_ptr = null;
    ctx.ui_vertex_offset = 0;

    // Optimization state tracking
    ctx.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
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

    const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
    ctx.safe_mode = if (safe_mode_env) |val|
        !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
    else
        false;
    if (ctx.safe_mode) {
        std.log.warn("ZIGCRAFT_SAFE_MODE enabled: throttling uploads and forcing GPU idle each frame", .{});
    }

    // Pipeline Layouts (using DescriptorManager's layout)
    var model_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    model_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    model_push_constant.size = 256;
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &ctx.descriptors.descriptor_set_layout;
    pipeline_layout_info.pushConstantRangeCount = 1;
    pipeline_layout_info.pPushConstantRanges = &model_push_constant;
    try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &pipeline_layout_info, null, &ctx.pipeline_layout));

    var sky_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    sky_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
    sky_push_constant.size = 128;
    var sky_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    sky_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    sky_layout_info.setLayoutCount = 1;
    sky_layout_info.pSetLayouts = &ctx.descriptors.descriptor_set_layout;
    sky_layout_info.pushConstantRangeCount = 1;
    sky_layout_info.pPushConstantRanges = &sky_push_constant;
    try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &sky_layout_info, null, &ctx.sky_pipeline_layout));

    var ui_push_constant = std.mem.zeroes(c.VkPushConstantRange);
    ui_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT;
    ui_push_constant.size = @sizeOf(Mat4);
    var ui_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_layout_info.pushConstantRangeCount = 1;
    ui_layout_info.pPushConstantRanges = &ui_push_constant;
    try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &ui_layout_info, null, &ctx.ui_pipeline_layout));

    // UI Tex Pipeline Layout - needs a separate descriptor layout for texture only?
    // rhi_vulkan.zig created `ui_tex_descriptor_set_layout` locally.
    // I should move that to DescriptorManager too? Or keep it local?
    // It's local to UI. DescriptorManager handles the *Main* descriptor set.
    // I'll recreate it here locally as it was.
    var ui_tex_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    var ui_tex_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    ui_tex_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    ui_tex_layout_info.bindingCount = 1;
    ui_tex_layout_info.pBindings = &ui_tex_layout_bindings[0];
    try Utils.checkVk(c.vkCreateDescriptorSetLayout(ctx.vulkan_device.vk_device, &ui_tex_layout_info, null, &ctx.ui_tex_descriptor_set_layout));

    // Also need to create the pool for UI tex descriptors?
    // Original code created `ui_tex_descriptor_pool` logic... wait, where is it?
    // It seems original code initialized `ui_tex_descriptor_pool` in the loop at the end of initContext.
    // I need to allocate that pool.
    var ui_pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = MAX_FRAMES_IN_FLIGHT * 64 },
    };
    var ui_pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    ui_pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    ui_pool_info.poolSizeCount = 1;
    ui_pool_info.pPoolSizes = &ui_pool_sizes[0];
    ui_pool_info.maxSets = MAX_FRAMES_IN_FLIGHT * 64;
    // We don't have a field for this pool in VulkanContext?
    // Ah, `ui_tex_descriptor_pool` is an array of sets `[MAX_FRAMES][64]VkDescriptorSet`.
    // The pool must be `descriptor_pool` or similar?
    // Original code used `ctx.descriptors.descriptor_pool`? No, that was for main sets.
    // Actually, original code didn't show creation of a separate pool for UI.
    // Let me check `initContext` again.
    // Line 1997: `ctx.descriptors.descriptor_pool` created.
    // Line 2027: `ctx.ui_tex_descriptor_set_layout` created.
    // UI descriptors are allocated in `drawTexture2D`.
    // They are allocated from `ctx.descriptors.descriptor_pool`?
    // `drawTexture2D` line 5081 calls `c.vkUpdateDescriptorSets`. It assumes sets are allocated.
    // Where are they allocated?
    // They are pre-allocated in `initContext`?
    // Looking at the end of `initContext` (original):
    // It initializes the array `ctx.ui_tex_descriptor_pool` to nulls.
    // It doesn't allocate them.
    // Wait, `drawTexture2D` allocates them?
    // `drawTexture2D` at line 5081 uses `ds`.
    // `ds` comes from `ctx.ui_tex_descriptor_pool[frame][idx]`.
    // If it's null, it must be allocated.
    // But `drawTexture2D` doesn't show allocation logic in the snippet I have (lines 5051+).
    // Ah, I missed where they are allocated.
    // Maybe they are allocated on demand?
    // Let's assume I need to keep `descriptor_pool` large enough for UI too.
    // `DescriptorManager` created a pool with 100 sets. That might be too small for UI if UI uses many.
    // I should increase `DescriptorManager` pool size.

    var ui_tex_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    ui_tex_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    ui_tex_layout_full_info.setLayoutCount = 1;
    ui_tex_layout_full_info.pSetLayouts = &ctx.ui_tex_descriptor_set_layout;
    ui_tex_layout_full_info.pushConstantRangeCount = 1;
    ui_tex_layout_full_info.pPushConstantRanges = &ui_push_constant;
    try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &ui_tex_layout_full_info, null, &ctx.ui_tex_pipeline_layout));

    if (comptime build_options.debug_shadows) {
        var debug_shadow_layout_full_info: c.VkPipelineLayoutCreateInfo = undefined;
        @memset(std.mem.asBytes(&debug_shadow_layout_full_info), 0);
        debug_shadow_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        debug_shadow_layout_full_info.setLayoutCount = 1;
        const debug_layout = ctx.debug_shadow.descriptor_set_layout orelse return error.InitializationFailed;
        debug_shadow_layout_full_info.pSetLayouts = &debug_layout;
        debug_shadow_layout_full_info.pushConstantRangeCount = 1;
        debug_shadow_layout_full_info.pPushConstantRanges = &ui_push_constant;
        try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &debug_shadow_layout_full_info, null, &ctx.debug_shadow.pipeline_layout));
    }

    var cloud_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    cloud_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    cloud_layout_info.pushConstantRangeCount = 1;
    cloud_layout_info.pPushConstantRanges = &sky_push_constant;
    try Utils.checkVk(c.vkCreatePipelineLayout(ctx.vulkan_device.vk_device, &cloud_layout_info, null, &ctx.cloud_pipeline_layout));

    // Shadow Pass (Legacy)
    // ... [Copy Shadow Pass creation logic from lines 2114-2285] ...
    // NOTE: This logic creates shadow_render_pass, shadow_pipeline, etc.
    // I will call a helper function `createShadowResources` which essentially contains that logic.
    // Wait, `createShadowResources` was not existing in original file, it was inline.
    // I should create it to keep initContext clean.
    try createShadowResources(ctx);

    // Final Pipelines
    try createMainPipelines(ctx);

    // Initial resources
    try createGPassResources(ctx);
    try createSSAOResources(ctx);

    // Setup Dummy Textures from DescriptorManager
    ctx.dummy_texture = ctx.descriptors.dummy_texture;
    ctx.dummy_normal_texture = ctx.descriptors.dummy_normal_texture;
    ctx.dummy_roughness_texture = ctx.descriptors.dummy_roughness_texture;
    ctx.current_texture = ctx.dummy_texture;
    ctx.current_normal_texture = ctx.dummy_normal_texture;
    ctx.current_roughness_texture = ctx.dummy_roughness_texture;
    ctx.current_displacement_texture = ctx.dummy_roughness_texture;
    ctx.current_env_texture = ctx.dummy_texture;

    // Create cloud resources
    const cloud_vbo_handle = try ctx.resources.createBuffer(8 * @sizeOf(f32), .vertex);
    std.log.info("Cloud VBO handle: {}, map count: {}", .{ cloud_vbo_handle, ctx.resources.buffers.count() });
    if (cloud_vbo_handle == 0) {
        std.log.err("Failed to create cloud VBO", .{});
        return error.InitializationFailed;
    }
    const cloud_buf = ctx.resources.buffers.get(cloud_vbo_handle);
    if (cloud_buf == null) {
        std.log.err("Cloud VBO created but not found in map!", .{});
        return error.InitializationFailed;
    }
    ctx.cloud_vbo = cloud_buf.?;

    // Create UI VBOs
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.ui_vbos[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, 1024 * 1024, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    }

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.descriptors_dirty[i] = true;
        // Init UI pools
        for (0..64) |j| ctx.ui_tex_descriptor_pool[i][j] = null;
        ctx.ui_tex_descriptor_next[i] = 0;
    }

    try ctx.resources.flushTransfer();
    // Reset to frame 0 after initialization. Dummy textures created at index 1 are safe.
    ctx.resources.setCurrentFrame(0);
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.dry_run) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }

    destroyMainRenderPassAndPipelines(ctx);
    destroyGPassResources(ctx);
    destroySSAOResources(ctx);

    if (ctx.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.pipeline_layout, null);
    if (ctx.sky_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.sky_pipeline_layout, null);
    if (ctx.ui_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_pipeline_layout, null);
    if (ctx.ui_tex_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_pipeline_layout, null);
    if (ctx.ui_tex_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_descriptor_set_layout, null);
    if (comptime build_options.debug_shadows) {
        if (ctx.debug_shadow.pipeline_layout) |layout| c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, layout, null);
        if (ctx.debug_shadow.descriptor_set_layout) |layout| c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, layout, null);
    }
    if (ctx.cloud_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.cloud_pipeline_layout, null);

    // Destroy internal buffers and resources
    // Helper to destroy raw VulkanBuffers
    const device = ctx.vulkan_device.vk_device;
    {
        if (ctx.model_ubo.buffer != null) c.vkDestroyBuffer(device, ctx.model_ubo.buffer, null);
        if (ctx.model_ubo.memory != null) c.vkFreeMemory(device, ctx.model_ubo.memory, null);

        if (ctx.dummy_instance_buffer.buffer != null) c.vkDestroyBuffer(device, ctx.dummy_instance_buffer.buffer, null);
        if (ctx.dummy_instance_buffer.memory != null) c.vkFreeMemory(device, ctx.dummy_instance_buffer.memory, null);

        if (ctx.ssao_kernel_ubo.buffer != null) c.vkDestroyBuffer(device, ctx.ssao_kernel_ubo.buffer, null);
        if (ctx.ssao_kernel_ubo.memory != null) c.vkFreeMemory(device, ctx.ssao_kernel_ubo.memory, null);

        for (ctx.ui_vbos) |buf| {
            if (buf.buffer != null) c.vkDestroyBuffer(device, buf.buffer, null);
            if (buf.memory != null) c.vkFreeMemory(device, buf.memory, null);
        }
    }

    if (comptime build_options.debug_shadows) {
        if (ctx.debug_shadow.vbo.buffer != null) c.vkDestroyBuffer(device, ctx.debug_shadow.vbo.buffer, null);
        if (ctx.debug_shadow.vbo.memory != null) c.vkFreeMemory(device, ctx.debug_shadow.vbo.memory, null);
    }
    // Note: cloud_vbo is managed by resource manager and destroyed there

    // Destroy dummy textures
    ctx.resources.destroyTexture(ctx.dummy_texture);
    ctx.resources.destroyTexture(ctx.dummy_normal_texture);
    ctx.resources.destroyTexture(ctx.dummy_roughness_texture);
    if (ctx.dummy_shadow_view != null) c.vkDestroyImageView(ctx.vulkan_device.vk_device, ctx.dummy_shadow_view, null);
    if (ctx.dummy_shadow_image != null) c.vkDestroyImage(ctx.vulkan_device.vk_device, ctx.dummy_shadow_image, null);
    if (ctx.dummy_shadow_memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.dummy_shadow_memory, null);

    ctx.shadow_system.deinit(ctx.vulkan_device.vk_device);

    ctx.descriptors.deinit();
    ctx.swapchain.deinit();
    ctx.frames.deinit();
    ctx.resources.deinit();
    ctx.vulkan_device.deinit();

    ctx.allocator.destroy(ctx);
}
fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createBuffer(size, usage);
}

fn uploadBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.uploadBuffer(handle, data);
}

fn updateBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, dst_offset: usize, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.updateBuffer(handle, dst_offset, data);
}

fn destroyBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.resources.destroyBuffer(handle);
}

fn recreateSwapchainInternal(ctx: *VulkanContext) void {
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) return;

    destroyMainRenderPassAndPipelines(ctx);
    destroyGPassResources(ctx);
    destroySSAOResources(ctx);

    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.g_pass_active = false;
    ctx.ssao_pass_active = false;

    ctx.swapchain.recreate() catch |err| {
        std.log.err("Failed to recreate swapchain: {}", .{err});
        return;
    };

    createMainPipelines(ctx) catch |err| std.log.err("Failed to recreate main pipelines: {}", .{err});
    createGPassResources(ctx) catch |err| std.log.err("Failed to recreate G-pass resources: {}", .{err});
    createSSAOResources(ctx) catch |err| std.log.err("Failed to recreate SSAO resources: {}", .{err});

    ctx.framebuffer_resized = false;
}

fn recreateSwapchain(ctx: *VulkanContext) void {
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    recreateSwapchainInternal(ctx);
}

fn beginFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (ctx.gpu_fault_detected) return;
    if (ctx.frames.frame_in_progress) return;

    if (ctx.framebuffer_resized) {
        recreateSwapchainInternal(ctx);
    }

    if (ctx.resources.transfer_ready) {
        ctx.resources.flushTransfer() catch |err| {
            std.log.err("Failed to flush inter-frame transfers: {}", .{err});
        };
    }

    // Begin frame (acquire image, reset fences/CBs)
    if (ctx.frames.beginFrame(&ctx.swapchain) catch |err| {
        if (err == error.OutOfDate) {
            recreateSwapchainInternal(ctx);
        } else {
            std.log.err("beginFrame failed: {}", .{err});
        }
        return;
    }) {
        // Frame started successfully
    } else {
        return;
    }

    ctx.resources.setCurrentFrame(ctx.frames.current_frame);

    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);

    ctx.draw_call_count = 0;
    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;

    ctx.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
    ctx.descriptors_updated = false;
    ctx.bound_texture = 0;

    const command_buffer = ctx.frames.getCurrentCommandBuffer();

    // Memory barrier for host writes
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

    ctx.ui_vertex_offset = 0;
    ctx.ui_flushed_vertex_count = 0;
    ctx.ui_tex_descriptor_next[ctx.frames.current_frame] = 0;
    if (comptime build_options.debug_shadows) {
        ctx.debug_shadow.descriptor_next[ctx.frames.current_frame] = 0;
    }

    // Static descriptor updates (Atlases & Shadow maps)
    const cur_tex = ctx.current_texture;
    const cur_nor = ctx.current_normal_texture;
    const cur_rou = ctx.current_roughness_texture;
    const cur_dis = ctx.current_displacement_texture;
    const cur_env = ctx.current_env_texture;

    // Check if any texture bindings or shadow views changed since last frame
    var needs_update = false;
    if (ctx.bound_texture != cur_tex) needs_update = true;
    if (ctx.bound_normal_texture != cur_nor) needs_update = true;
    if (ctx.bound_roughness_texture != cur_rou) needs_update = true;
    if (ctx.bound_displacement_texture != cur_dis) needs_update = true;
    if (ctx.bound_env_texture != cur_env) needs_update = true;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (ctx.bound_shadow_views[si] != ctx.shadow_system.shadow_image_views[si]) needs_update = true;
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
        for (0..rhi.SHADOW_CASCADE_COUNT) |si| ctx.bound_shadow_views[si] = ctx.shadow_system.shadow_image_views[si];
    }

    if (ctx.descriptors_dirty[ctx.frames.current_frame]) {
        if (ctx.descriptors.descriptor_sets[ctx.frames.current_frame] == null) {
            std.log.err("CRITICAL: Descriptor set for frame {} is NULL!", .{ctx.frames.current_frame});
            return;
        }
        var writes: [10]c.VkWriteDescriptorSet = undefined;
        var write_count: u32 = 0;
        var image_infos: [10]c.VkDescriptorImageInfo = undefined;
        var info_count: u32 = 0;

        const dummy_tex_entry = ctx.resources.textures.get(ctx.dummy_texture);

        const atlas_slots = [_]struct { handle: rhi.TextureHandle, binding: u32 }{
            .{ .handle = cur_tex, .binding = 1 },
            .{ .handle = cur_nor, .binding = 6 },
            .{ .handle = cur_rou, .binding = 7 },
            .{ .handle = cur_dis, .binding = 8 },
            .{ .handle = cur_env, .binding = 9 },
        };

        for (atlas_slots) |slot| {
            const entry = ctx.resources.textures.get(slot.handle) orelse dummy_tex_entry;
            if (entry) |tex| {
                image_infos[info_count] = .{
                    .sampler = tex.sampler,
                    .imageView = tex.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
            if (ctx.shadow_system.shadow_sampler == null) {
                std.log.err("CRITICAL: Shadow sampler is NULL!", .{});
            }
            if (ctx.shadow_system.shadow_image_view == null) {
                std.log.err("CRITICAL: Shadow image view is NULL!", .{});
            }
            image_infos[info_count] = .{
                .sampler = ctx.shadow_system.shadow_sampler,
                .imageView = ctx.shadow_system.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
                writes[i].dstSet = ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame];
            }
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, write_count, &writes[0], 0, null);
        }

        ctx.descriptors_dirty[ctx.frames.current_frame] = false;
    }

    ctx.descriptors_updated = true;
}

fn abortFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    if (ctx.main_pass_active) endMainPass(ctx_ptr);
    if (ctx.shadow_system.pass_active) endShadowPass(ctx_ptr);
    if (ctx.g_pass_active) endGPass(ctx_ptr);

    ctx.frames.abortFrame();

    // Recreate semaphores
    const device = ctx.vulkan_device.vk_device;
    const frame = ctx.frames.current_frame;

    c.vkDestroySemaphore(device, ctx.frames.image_available_semaphores[frame], null);
    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.image_available_semaphores[frame]);

    c.vkDestroySemaphore(device, ctx.frames.render_finished_semaphores[frame], null);
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.render_finished_semaphores[frame]);

    ctx.draw_call_count = 0;
    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.g_pass_active = false;
    ctx.ssao_pass_active = false;
    ctx.descriptors_updated = false;
    ctx.bound_texture = 0;
}

fn beginGPassInternal(ctx: *VulkanContext) void {
    if (!ctx.frames.frame_in_progress or ctx.g_pass_active) return;

    // Safety: Skip G-pass if resources are not available
    if (ctx.g_render_pass == null or ctx.g_framebuffer == null or ctx.g_pipeline == null) {
        std.log.warn("beginGPass: skipping - resources null (rp={}, fb={}, pipeline={})", .{ ctx.g_render_pass != null, ctx.g_framebuffer != null, ctx.g_pipeline != null });
        return;
    }

    // Safety: Check for size mismatch between G-pass resources and current swapchain
    if (ctx.g_pass_extent.width != ctx.swapchain.swapchain.extent.width or ctx.g_pass_extent.height != ctx.swapchain.swapchain.extent.height) {
        std.log.warn("beginGPass: size mismatch! G-pass={}x{}, swapchain={}x{} - recreating", .{ ctx.g_pass_extent.width, ctx.g_pass_extent.height, ctx.swapchain.swapchain.extent.width, ctx.swapchain.swapchain.extent.height });
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
        createGPassResources(ctx) catch |err| {
            std.log.err("Failed to recreate G-pass resources: {}", .{err});
            return;
        };
        createSSAOResources(ctx) catch |err| {
            std.log.err("Failed to recreate SSAO resources: {}", .{err});
        };
    }

    ensureNoRenderPassActiveInternal(ctx);

    ctx.g_pass_active = true;
    const current_frame = ctx.frames.current_frame;
    const command_buffer = ctx.frames.command_buffers[current_frame];

    // Debug: check for NULL handles
    if (command_buffer == null) std.log.err("CRITICAL: command_buffer is NULL for frame {}", .{current_frame});
    if (ctx.g_render_pass == null) std.log.err("CRITICAL: g_render_pass is NULL", .{});
    if (ctx.g_framebuffer == null) std.log.err("CRITICAL: g_framebuffer is NULL", .{});
    if (ctx.pipeline_layout == null) std.log.err("CRITICAL: pipeline_layout is NULL", .{});

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.g_render_pass;
    render_pass_info.framebuffer = ctx.g_framebuffer;
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.swapchain.swapchain.extent;

    // Debug: log extent on first few frames
    if (ctx.frame_index < 10) {
        std.log.debug("beginGPass frame {}: extent {}x{} (cb={}, rp={}, fb={})", .{ ctx.frame_index, ctx.swapchain.swapchain.extent.width, ctx.swapchain.swapchain.extent.height, command_buffer != null, ctx.g_render_pass != null, ctx.g_framebuffer != null });
    }

    var clear_values: [2]c.VkClearValue = undefined;
    clear_values[0] = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    clear_values[1] = .{ .depthStencil = .{ .depth = 0.0, .stencil = 0 } };
    render_pass_info.clearValueCount = 2;
    render_pass_info.pClearValues = &clear_values[0];

    std.log.debug("beginGPass: calling vkCmdBeginRenderPass", .{});
    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    std.log.debug("beginGPass: calling vkCmdBindPipeline", .{});
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.swapchain.swapchain.extent.width), .height = @floatFromInt(ctx.swapchain.swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain.swapchain.extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    const ds = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    if (ds == null) std.log.err("CRITICAL: descriptor_set is NULL for frame {}", .{ctx.frames.current_frame});

    std.log.debug("beginGPass: calling vkCmdBindDescriptorSets", .{});
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ds, 0, null);
    std.log.debug("beginGPass: done", .{});
}

fn beginGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    beginGPassInternal(ctx);
}

fn endGPassInternal(ctx: *VulkanContext) void {
    if (!ctx.g_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    std.log.debug("endGPass: calling vkCmdEndRenderPass (cb={})", .{command_buffer != null});
    c.vkCmdEndRenderPass(command_buffer);
    ctx.g_pass_active = false;
}

fn endGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endGPassInternal(ctx);
}

fn computeSSAOInternal(ctx: *VulkanContext) void {
    if (!ctx.frames.frame_in_progress) return;

    // Safety: Skip SSAO if resources are not available
    if (ctx.ssao_render_pass == null or ctx.ssao_framebuffer == null or ctx.ssao_pipeline == null) {
        return;
    }
    if (ctx.ssao_blur_render_pass == null or ctx.ssao_blur_framebuffer == null or ctx.ssao_blur_pipeline == null) {
        return;
    }

    ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

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
        render_pass_info.renderArea.extent = ctx.swapchain.swapchain.extent;
        var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_pipeline);

        // Set viewport and scissor for SSAO pass
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.swapchain.swapchain.extent.width), .height = @floatFromInt(ctx.swapchain.swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain.swapchain.extent };
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_pipeline_layout, 0, 1, &ctx.ssao_descriptor_sets[ctx.frames.current_frame], 0, null);
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
        render_pass_info.renderArea.extent = ctx.swapchain.swapchain.extent;
        var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_blur_pipeline);

        // Set viewport and scissor for blur pass
        const blur_viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.swapchain.swapchain.extent.width), .height = @floatFromInt(ctx.swapchain.swapchain.extent.height), .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(command_buffer, 0, 1, &blur_viewport);
        const blur_scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain.swapchain.extent };
        c.vkCmdSetScissor(command_buffer, 0, 1, &blur_scissor);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ssao_blur_pipeline_layout, 0, 1, &ctx.ssao_blur_descriptor_sets[ctx.frames.current_frame], 0, null);
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(command_buffer);
    }
}

fn computeSSAO(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    computeSSAOInternal(ctx);
}

fn endFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.frames.frame_in_progress) return;

    if (ctx.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) endShadowPassInternal(ctx);

    const transfer_cb = ctx.resources.getTransferCommandBuffer();

    ctx.frames.endFrame(&ctx.swapchain, transfer_cb) catch |err| {
        std.log.err("endFrame failed: {}", .{err});
    };

    if (transfer_cb != null) {
        ctx.resources.resetTransferState();
    }

    ctx.frame_index += 1;
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
    if (ctx.shadow_system.shadow_image == null) return;

    const old_layout = ctx.shadow_system.shadow_image_layouts[cascade_index];
    if (old_layout == new_layout) return;

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) c.VK_IMAGE_LAYOUT_UNDEFINED else old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = ctx.shadow_system.shadow_image;
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

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdPipelineBarrier(command_buffer, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    ctx.shadow_system.shadow_image_layouts[cascade_index] = new_layout;
}

fn beginMainPassInternal(ctx: *VulkanContext) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.swapchain.swapchain.extent.width == 0 or ctx.swapchain.swapchain.extent.height == 0) return;

    // Safety: Ensure framebuffer is valid
    if (ctx.swapchain.swapchain.main_render_pass == null) return;
    if (ctx.swapchain.swapchain.framebuffers.items.len == 0) return;
    if (ctx.frames.current_image_index >= ctx.swapchain.swapchain.framebuffers.items.len) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.main_pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        ctx.terrain_pipeline_bound = false;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.swapchain.swapchain.main_render_pass;
        render_pass_info.framebuffer = ctx.swapchain.swapchain.framebuffers.items[ctx.frames.current_image_index];
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.swapchain.extent;

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
    viewport.width = @floatFromInt(ctx.swapchain.swapchain.extent.width);
    viewport.height = @floatFromInt(ctx.swapchain.swapchain.extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.swapchain.swapchain.extent;
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

fn beginMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    beginMainPassInternal(ctx);
}

fn endMainPassInternal(ctx: *VulkanContext) void {
    if (!ctx.main_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.main_pass_active = false;
}

fn endMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endMainPassInternal(ctx);
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.dry_run and ctx.vulkan_device.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

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
        .cloud_params = .{ cloud_params.cloud_height, @floatFromInt(cloud_params.shadow.pcf_samples), if (cloud_params.shadow.cascade_blend) 1.0 else 0.0, if (cloud_params.cloud_shadows) 1.0 else 0.0 },
        .pbr_params = .{ @floatFromInt(cloud_params.pbr_quality), cloud_params.exposure, cloud_params.saturation, if (cloud_params.ssao_enabled) 1.0 else 0.0 },
        .volumetric_params = .{ if (cloud_params.volumetric_enabled) 1.0 else 0.0, cloud_params.volumetric_density, @floatFromInt(cloud_params.volumetric_steps), cloud_params.volumetric_scattering },
        .viewport_size = .{ @floatFromInt(ctx.swapchain.swapchain.extent.width), @floatFromInt(ctx.swapchain.swapchain.extent.height), 0, 0 },
    };

    if (ctx.descriptors.global_ubos_mapped[ctx.frames.current_frame]) |map_ptr| {
        const mapped: *GlobalUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = uniforms;
    }
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.current_model = model;
    ctx.current_color = .{ color.x, color.y, color.z };
    ctx.current_mask_radius = mask_radius;
}

fn setInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;
    ctx.pending_instance_buffer = handle;
    ctx.lod_mode = false;
    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
}

fn setLODInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;
    ctx.pending_lod_instance_buffer = handle;
    ctx.lod_mode = true;
    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
}

fn applyPendingDescriptorUpdates(ctx: *VulkanContext, frame_index: usize) void {
    if (ctx.pending_instance_buffer != 0 and ctx.bound_instance_buffer[frame_index] != ctx.pending_instance_buffer) {
        const buf_opt = ctx.resources.buffers.get(ctx.pending_instance_buffer);

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptors.descriptor_sets[frame_index];
            write.dstBinding = 5; // Instance SSBO
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.bound_instance_buffer[frame_index] = ctx.pending_instance_buffer;
        }
    }

    if (ctx.pending_lod_instance_buffer != 0 and ctx.bound_lod_instance_buffer[frame_index] != ctx.pending_lod_instance_buffer) {
        const buf_opt = ctx.resources.buffers.get(ctx.pending_lod_instance_buffer);

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptors.lod_descriptor_sets[frame_index];
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
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active) beginMainPassInternal(ctx);
    if (!ctx.main_pass_active) return;

    // Use dedicated cloud pipeline
    if (ctx.cloud_pipeline == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

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
    if (comptime !build_options.debug_shadows) return;
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active) beginMainPassInternal(ctx);
    if (!ctx.main_pass_active) return;

    if (ctx.debug_shadow.pipeline == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    // ...

    // Bind debug shadow pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow.pipeline.?);

    ctx.terrain_pipeline_bound = false;

    // Set up orthographic projection for UI-sized quad
    const debug_size: f32 = 200.0;
    const debug_spacing: f32 = 10.0;
    const debug_x: f32 = debug_spacing + @as(f32, @floatFromInt(cascade_index)) * (debug_size + debug_spacing);
    const debug_y: f32 = debug_spacing;

    const width_f32 = @as(f32, @floatFromInt(ctx.swapchain.swapchain.extent.width));
    const height_f32 = @as(f32, @floatFromInt(ctx.swapchain.swapchain.extent.height));
    const proj = Mat4.orthographic(0, width_f32, height_f32, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.debug_shadow.pipeline_layout.?, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    // Update descriptor set with the depth texture
    const tex_entry = ctx.resources.textures.get(depth_map_handle);

    if (tex_entry) |tex| {
        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        image_info.imageView = tex.view;
        image_info.sampler = tex.sampler;

        const frame = ctx.frames.current_frame;
        const idx = ctx.debug_shadow.descriptor_next[frame];
        const pool_len = ctx.debug_shadow.descriptor_pool[frame].len;
        ctx.debug_shadow.descriptor_next[frame] = @intCast((idx + 1) % pool_len);
        const ds = ctx.debug_shadow.descriptor_pool[frame][idx] orelse return;

        var write_set = std.mem.zeroes(c.VkWriteDescriptorSet);
        write_set.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write_set.dstSet = ds;
        write_set.dstBinding = 0;
        write_set.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write_set.descriptorCount = 1;
        write_set.pImageInfo = &image_info;

        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write_set, 0, null);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow.pipeline_layout.?, 0, 1, &ds, 0, null);
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
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ctx.debug_shadow.vbo.memory, 0, @sizeOf(@TypeOf(debug_vertices)), 0, &map_ptr) == c.VK_SUCCESS) {
        @memcpy(@as([*]u8, @ptrCast(map_ptr.?))[0..@sizeOf(@TypeOf(debug_vertices))], std.mem.asBytes(&debug_vertices));
        c.vkUnmapMemory(ctx.vulkan_device.vk_device, ctx.debug_shadow.vbo.memory);

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ctx.debug_shadow.vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, 6, 1, 0, 0);
    }
}

fn createTexture(ctx_ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createTexture(width, height, format, config, data_opt);
}

fn destroyTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.destroyTexture(handle);
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

fn updateTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.updateTexture(handle, data);
}

fn setViewport(ctx_ptr: *anyopaque, width: u32, height: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    // Check if the requested viewport size matches the current swapchain extent.
    // If not, flag a resize so the swapchain is recreated at the beginning of the next frame.
    if (width != ctx.swapchain.swapchain.extent.width or height != ctx.swapchain.swapchain.extent.height) {
        ctx.framebuffer_resized = true;
    }

    if (!ctx.frames.frame_in_progress) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

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
    return @intCast(ctx.frames.current_frame);
}

fn supportsIndirectFirstInstance(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.draw_indirect_first_instance;
}

fn recover(ctx_ptr: *anyopaque) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.gpu_fault_detected) return;

    if (ctx.vulkan_device.recovery_count >= ctx.vulkan_device.max_recovery_attempts) {
        std.log.err("RHI: Max recovery attempts ({d}) exceeded. GPU is unstable.", .{ctx.vulkan_device.max_recovery_attempts});
        return error.GpuLost;
    }

    ctx.vulkan_device.recovery_count += 1;
    std.log.info("RHI: Attempting GPU recovery (Attempt {d}/{d})...", .{ ctx.vulkan_device.recovery_count, ctx.vulkan_device.max_recovery_attempts });

    // Best effort: wait for idle
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    // If robustness2 is working, the device might not be "lost" in the Vulkan sense,
    // but we might have hit a corner case.
    // Full recovery requires recreating the logical device and all resources.
    // For now, we reset the flag and recreate the swapchain.
    // Limitation: If the device is truly lost (VK_ERROR_DEVICE_LOST returned everywhere),
    // this soft recovery will likely fail or loop. Full engine restart is recommended for true TDRs.
    // TODO: Implement hard recovery (recreateDevice) which would:
    // 1. Destroy logical device and all resources
    // 2. Re-initialize device via VulkanDevice.init
    // 3. Re-create all RHI resources (buffers, textures, pipelines)
    // 4. Restore application state
    ctx.gpu_fault_detected = false;
    recreateSwapchain(ctx);

    // Basic verification: Check if device is responsive
    if (c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device) != c.VK_SUCCESS) {
        std.log.err("RHI: Device unresponsive after recovery. Recovery failed.", .{});
        ctx.vulkan_device.recovery_fail_count += 1;
        ctx.gpu_fault_detected = true; // Re-flag to prevent further submissions
        return error.GpuLost;
    }

    ctx.vulkan_device.recovery_success_count += 1;
    std.log.info("RHI: Recovery step complete. If issues persist, please restart.", .{});
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
    if (ctx.anisotropic_filtering == level) return;
    ctx.anisotropic_filtering = level;
    // Recreate sampler logic is complex as it requires recreating all texture samplers
    // For now, we rely on application restart or next resource load for full effect,
    // or implement dynamic sampler updates if critical.
    // Given the architecture, recreating swapchain/resources often happens on setting change anyway.
}

fn setVolumetricDensity(ctx_ptr: *anyopaque, density: f32) void {
    // This is just a parameter update for the next frame's uniform update
    // No immediate Vulkan action required other than ensuring the value is used.
    // Since uniforms are updated every frame from App settings in main loop,
    // this specific setter might just be a placeholder or hook for future optimization.
    _ = ctx_ptr;
    _ = density;
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

fn getFaultCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.fault_count;
}

fn drawIndexed(ctx_ptr: *anyopaque, vbo_handle: rhi.BufferHandle, ebo_handle: rhi.BufferHandle, count: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) beginMainPassInternal(ctx);

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) return;

    const vbo_opt = ctx.resources.buffers.get(vbo_handle);
    const ebo_opt = ctx.resources.buffers.get(ebo_handle);

    if (vbo_opt) |vbo| {
        if (ebo_opt) |ebo| {
            ctx.draw_call_count += 1;
            const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

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
                &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
            else
                &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) beginMainPassInternal(ctx);

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) return;

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);
    const cmd_opt = ctx.resources.buffers.get(command_buffer);

    if (vbo_opt) |vbo| {
        if (cmd_opt) |cmd| {
            ctx.draw_call_count += 1;
            const cb = ctx.frames.command_buffers[ctx.frames.current_frame];

            if (use_shadow) {
                if (!ctx.shadow_system.pipeline_bound) {
                    if (ctx.shadow_system.shadow_pipeline == null) return;
                    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                    ctx.shadow_system.pipeline_bound = true;
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
                &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
            else
                &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);

            if (use_shadow) {
                const shadow_uniforms = ShadowModelUniforms{
                    .light_space_matrix = ctx.shadow_system.pass_matrix,
                    .model = Mat4.identity,
                };
                c.vkCmdPushConstants(cb, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
            } else {
                const uniforms = ModelUniforms{
                    .model = Mat4.identity,
                    .color = .{ 1.0, 1.0, 1.0 },
                    .mask_radius = 0,
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
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) beginMainPassInternal(ctx);

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);

    if (vbo_opt) |vbo| {
        ctx.draw_call_count += 1;
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        if (use_shadow) {
            if (!ctx.shadow_system.pipeline_bound) {
                if (ctx.shadow_system.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                ctx.shadow_system.pipeline_bound = true;
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
            &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
        else
            &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);

        if (use_shadow) {
            const shadow_uniforms = ShadowModelUniforms{
                .light_space_matrix = ctx.shadow_system.pass_matrix,
                .model = Mat4.identity,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = Mat4.identity,
                .color = .{ 1.0, 1.0, 1.0 },
                .mask_radius = 0,
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
    _ = mode;
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) beginMainPassInternal(ctx);

    if (!ctx.main_pass_active and !ctx.shadow_system.pass_active and !ctx.g_pass_active) return;

    const use_shadow = ctx.shadow_system.pass_active;
    const use_g_pass = ctx.g_pass_active;

    const vbo_opt = ctx.resources.buffers.get(handle);

    if (vbo_opt) |vbo| {
        const vertex_stride: u64 = @sizeOf(rhi.Vertex);
        const required_bytes: u64 = @as(u64, offset) + @as(u64, count) * vertex_stride;
        if (required_bytes > vbo.size) {
            std.log.err("drawOffset: vertex buffer overrun (handle={}, offset={}, count={}, size={})", .{ handle, offset, count, vbo.size });
            return;
        }

        ctx.draw_call_count += 1;

        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        // Bind pipeline only if not already bound
        if (use_shadow) {
            if (!ctx.shadow_system.pipeline_bound) {
                if (ctx.shadow_system.shadow_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.shadow_system.shadow_pipeline);
                ctx.shadow_system.pipeline_bound = true;
            }
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.descriptors.descriptor_sets[ctx.frames.current_frame], 0, null);
        } else if (use_g_pass) {
            if (ctx.g_pipeline == null) return;
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);

            const descriptor_set = if (ctx.lod_mode)
                &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
            else
                &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
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
                &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
            else
                &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);
        }

        if (use_shadow) {
            const shadow_uniforms = ShadowModelUniforms{
                .light_space_matrix = ctx.shadow_system.pass_matrix,
                .model = ctx.current_model,
            };
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(ShadowModelUniforms), &shadow_uniforms);
        } else {
            const uniforms = ModelUniforms{
                .model = ctx.current_model,
                .color = ctx.current_color,
                .mask_radius = ctx.current_mask_radius,
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
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        const total_vertices: u32 = @intCast(ctx.ui_vertex_offset / (6 * @sizeOf(f32)));
        const count = total_vertices - ctx.ui_flushed_vertex_count;

        c.vkCmdDraw(command_buffer, count, 1, ctx.ui_flushed_vertex_count, 0);
        ctx.ui_flushed_vertex_count = total_vertices;
    }
}

fn bindBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const buf_opt = ctx.resources.buffers.get(handle);

    if (buf_opt) |buf| {
        const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
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
    if (!ctx.frames.frame_in_progress) return;

    var vk_stages: c.VkShaderStageFlags = 0;
    if (stages.vertex) vk_stages |= c.VK_SHADER_STAGE_VERTEX_BIT;
    if (stages.fragment) vk_stages |= c.VK_SHADER_STAGE_FRAGMENT_BIT;
    if (stages.compute) vk_stages |= c.VK_SHADER_STAGE_COMPUTE_BIT;

    const cb = ctx.frames.command_buffers[ctx.frames.current_frame];
    // Currently we only have one main pipeline layout used for everything.
    // In a more SOLID system, we'd bind the layout associated with the current shader.
    c.vkCmdPushConstants(cb, ctx.pipeline_layout, vk_stages, offset, size, data);
}

// 2D Rendering functions
fn begin2DPass(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.main_pass_active) beginMainPassInternal(ctx);
    if (!ctx.main_pass_active) return;

    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;
    ctx.ui_in_progress = true;

    // Map current frame's UI VBO memory
    const ui_vbo = ctx.ui_vbos[ctx.frames.current_frame];
    if (c.vkMapMemory(ctx.vulkan_device.vk_device, ui_vbo.memory, 0, ui_vbo.size, 0, &ctx.ui_mapped_ptr) != c.VK_SUCCESS) {
        std.log.err("Failed to map UI VBO memory!", .{});
    }

    // Bind UI pipeline and VBO
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_pipeline);
    ctx.terrain_pipeline_bound = false;

    const offset_val: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ui_vbo.buffer, &offset_val);

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
        const ui_vbo = ctx.ui_vbos[ctx.frames.current_frame];
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
    const ui_vbo = ctx.ui_vbos[ctx.frames.current_frame];
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
    if (!ctx.frames.frame_in_progress) return;

    // Reset this so other pipelines know to rebind if they are called next
    ctx.terrain_pipeline_bound = false;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    if (textured) {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline);
    } else {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_pipeline);
    }
}

fn drawTexture2D(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress or !ctx.ui_in_progress) return;

    // 1. Flush normal UI if any
    flushUI(ctx);

    const tex_opt = ctx.resources.textures.get(texture);
    if (tex_opt == null) {
        std.log.err("drawTexture2D: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    // 2. Bind Textured UI Pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.ui_tex_pipeline);
    ctx.terrain_pipeline_bound = false;

    // 3. Update & Bind Descriptor Set
    var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
    image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    image_info.imageView = tex.view;
    image_info.sampler = tex.sampler;

    const frame = ctx.frames.current_frame;
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
        const ui_vbo = ctx.ui_vbos[ctx.frames.current_frame];
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

fn createShader(ctx_ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.resources.createShader(vertex_src, fragment_src);
}

fn destroyShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.destroyShader(handle);
}

fn mapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.mapBuffer(handle);
}

fn unmapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.unmapBuffer(handle);
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

fn ensureNoRenderPassActiveInternal(ctx: *VulkanContext) void {
    if (ctx.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) endShadowPassInternal(ctx);
    if (ctx.g_pass_active) endGPassInternal(ctx);
}

fn ensureNoRenderPassActive(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ensureNoRenderPassActiveInternal(ctx);
}

fn beginShadowPassInternal(ctx: *VulkanContext, cascade_index: u32, light_space_matrix: Mat4) void {
    if (!ctx.frames.frame_in_progress) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.shadow_system.beginPass(command_buffer, cascade_index, light_space_matrix);
}

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    beginShadowPassInternal(ctx, cascade_index, light_space_matrix);
}

fn endShadowPassInternal(ctx: *VulkanContext) void {
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.shadow_system.endPass(command_buffer);
}

fn endShadowPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endShadowPassInternal(ctx);
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

    if (ctx.descriptors.shadow_ubos_mapped[ctx.frames.current_frame]) |map_ptr| {
        const mapped: *ShadowUniforms = @ptrCast(@alignCast(map_ptr));
        mapped.* = shadow_uniforms;
    }
}

fn getNativeSkyPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.sky_pipeline);
}
fn getNativeSkyPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.sky_pipeline_layout);
}
fn getNativeCloudPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.cloud_pipeline);
}
fn getNativeCloudPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.cloud_pipeline_layout);
}
fn getNativeMainDescriptorSet(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.descriptors.descriptor_sets[ctx.frames.current_frame]);
}
fn getNativeSSAOPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_pipeline);
}
fn getNativeSSAOPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_pipeline_layout);
}
fn getNativeSSAOBlurPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_blur_pipeline);
}
fn getNativeSSAOBlurPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_blur_pipeline_layout);
}
fn getNativeSSAODescriptorSet(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_descriptor_sets[ctx.frames.current_frame]);
}
fn getNativeSSAOBlurDescriptorSet(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_blur_descriptor_sets[ctx.frames.current_frame]);
}
fn getNativeCommandBuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.frames.command_buffers[ctx.frames.current_frame]);
}
fn getNativeSwapchainExtent(ctx_ptr: *anyopaque) [2]u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return .{ ctx.swapchain.swapchain.extent.width, ctx.swapchain.swapchain.extent.height };
}
fn getNativeSSAOFramebuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_framebuffer);
}
fn getNativeSSAOBlurFramebuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_blur_framebuffer);
}
fn getNativeSSAORenderPass(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_render_pass);
}
fn getNativeSSAOBlurRenderPass(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_blur_render_pass);
}
fn getNativeSSAOParamsBuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_kernel_ubo.buffer);
}
fn getNativeSSAOParamsMemory(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.ssao_kernel_ubo.memory);
}
fn getNativeDevice(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.vulkan_device.vk_device);
}

fn getStateContext(ctx_ptr: *anyopaque) rhi.IRenderStateContext {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_STATE_CONTEXT_VTABLE };
}

const VULKAN_STATE_CONTEXT_VTABLE = rhi.IRenderStateContext.VTable{
    .setModelMatrix = setModelMatrix,
    .setInstanceBuffer = setInstanceBuffer,
    .setLODInstanceBuffer = setLODInstanceBuffer,
    .updateGlobalUniforms = updateGlobalUniforms,
    .setTextureUniforms = setTextureUniforms,
};

fn getEncoder(ctx_ptr: *anyopaque) rhi.IGraphicsCommandEncoder {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_COMMAND_ENCODER_VTABLE };
}

const VULKAN_COMMAND_ENCODER_VTABLE = rhi.IGraphicsCommandEncoder.VTable{
    .bindShader = bindShader,
    .bindTexture = bindTexture,
    .bindBuffer = bindBuffer,
    .pushConstants = pushConstants,
    .draw = draw,
    .drawOffset = drawOffset,
    .drawIndexed = drawIndexed,
    .drawIndirect = drawIndirect,
    .drawInstance = drawInstance,
    .setViewport = setViewport,
};

const VULKAN_RHI_VTABLE = rhi.RHI.VTable{
    .init = initContext,
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
        .beginGPass = beginGPass,
        .endGPass = endGPass,
        .getEncoder = getEncoder,
        .getStateContext = getStateContext,
        .getNativeSkyPipeline = getNativeSkyPipeline,
        .getNativeSkyPipelineLayout = getNativeSkyPipelineLayout,
        .getNativeCloudPipeline = getNativeCloudPipeline,
        .getNativeCloudPipelineLayout = getNativeCloudPipelineLayout,
        .getNativeMainDescriptorSet = getNativeMainDescriptorSet,
        .getNativeSSAOPipeline = getNativeSSAOPipeline,
        .getNativeSSAOPipelineLayout = getNativeSSAOPipelineLayout,
        .getNativeSSAOBlurPipeline = getNativeSSAOBlurPipeline,
        .getNativeSSAOBlurPipelineLayout = getNativeSSAOBlurPipelineLayout,
        .getNativeSSAODescriptorSet = getNativeSSAODescriptorSet,
        .getNativeSSAOBlurDescriptorSet = getNativeSSAOBlurDescriptorSet,
        .getNativeCommandBuffer = getNativeCommandBuffer,
        .getNativeSwapchainExtent = getNativeSwapchainExtent,
        .getNativeSSAOFramebuffer = getNativeSSAOFramebuffer,
        .getNativeSSAOBlurFramebuffer = getNativeSSAOBlurFramebuffer,
        .getNativeSSAORenderPass = getNativeSSAORenderPass,
        .getNativeSSAOBlurRenderPass = getNativeSSAOBlurRenderPass,
        .getNativeSSAOParamsBuffer = getNativeSSAOParamsBuffer,
        .getNativeSSAOParamsMemory = getNativeSSAOParamsMemory,
        .getNativeDevice = getNativeDevice,
        .computeSSAO = computeSSAO,
        .setClearColor = setClearColor,
        .drawDebugShadowMap = drawDebugShadowMap,
    },
    .shadow = .{
        .beginPass = beginShadowPass,
        .endPass = endShadowPass,
        .updateUniforms = updateShadowUniforms,
    },
    .ui = .{
        .beginPass = begin2DPass,
        .endPass = end2DPass,
        .drawRect = drawRect2D,
        .drawTexture = drawTexture2D,
        .bindPipeline = bindUIPipeline,
    },
    .query = .{
        .getFrameIndex = getFrameIndex,
        .supportsIndirectFirstInstance = supportsIndirectFirstInstance,
        .getMaxAnisotropy = getMaxAnisotropy,
        .getMaxMSAASamples = getMaxMSAASamples,
        .getFaultCount = getFaultCount,
        .waitIdle = waitIdle,
    },
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setVSync = setVSync,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setVolumetricDensity = setVolumetricDensity,
    .setMSAA = setMSAA,
    .recover = recover,
};

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    @memset(std.mem.asBytes(ctx), 0);

    // Initialize all fields to safe defaults
    ctx.allocator = allocator;
    ctx.render_device = render_device;
    ctx.shadow_resolution = shadow_resolution;
    ctx.window = window;
    ctx.shadow_system = try ShadowSystem.init(allocator, shadow_resolution);
    ctx.vulkan_device = .{
        .allocator = allocator,
    };
    ctx.swapchain.swapchain = .{
        .device = &ctx.vulkan_device,
        .window = window,
        .allocator = allocator,
    };
    ctx.framebuffer_resized = false;

    ctx.draw_call_count = 0;
    ctx.resources.buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(allocator);
    ctx.resources.next_buffer_handle = 1;
    ctx.resources.textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(allocator);
    ctx.resources.next_texture_handle = 1;
    ctx.current_texture = 0;
    ctx.current_normal_texture = 0;
    ctx.current_roughness_texture = 0;
    ctx.current_displacement_texture = 0;
    ctx.current_env_texture = 0;
    ctx.dummy_texture = 0;
    ctx.dummy_normal_texture = 0;
    ctx.dummy_roughness_texture = 0;
    ctx.mutex = .{};
    ctx.swapchain.swapchain.images = .empty;
    ctx.swapchain.swapchain.image_views = .empty;
    ctx.swapchain.swapchain.framebuffers = .empty;
    ctx.clear_color = .{ 0.07, 0.08, 0.1, 1.0 };
    ctx.frames.frame_in_progress = false;
    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.shadow_system.pass_index = 0;
    ctx.ui_in_progress = false;
    ctx.ui_mapped_ptr = null;
    ctx.ui_vertex_offset = 0;
    ctx.frame_index = 0;
    ctx.frames.current_frame = 0;
    ctx.frames.current_image_index = 0;

    // Optimization state tracking
    ctx.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
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

    const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
    ctx.safe_mode = if (safe_mode_env) |val|
        !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
    else
        false;
    if (ctx.safe_mode) {
        std.log.warn("ZIGCRAFT_SAFE_MODE enabled: throttling uploads and forcing GPU idle each frame", .{});
    }

    ctx.frames.command_pool = null;
    ctx.resources.transfer_command_pool = null;
    ctx.resources.transfer_ready = false;
    ctx.swapchain.swapchain.main_render_pass = null;
    ctx.swapchain.swapchain.handle = null;
    ctx.swapchain.swapchain.depth_image = null;
    ctx.swapchain.swapchain.depth_image_view = null;
    ctx.swapchain.swapchain.depth_image_memory = null;
    ctx.swapchain.swapchain.msaa_color_image = null;
    ctx.swapchain.swapchain.msaa_color_view = null;
    ctx.swapchain.swapchain.msaa_color_memory = null;
    ctx.pipeline = null;
    ctx.pipeline_layout = null;
    ctx.wireframe_pipeline = null;
    ctx.sky_pipeline = null;
    ctx.sky_pipeline_layout = null;
    ctx.ui_pipeline = null;
    ctx.ui_pipeline_layout = null;
    ctx.ui_tex_pipeline = null;
    ctx.ui_tex_pipeline_layout = null;
    ctx.ui_tex_descriptor_set_layout = null;
    if (comptime build_options.debug_shadows) {
        ctx.debug_shadow.pipeline = null;
        ctx.debug_shadow.pipeline_layout = null;
        ctx.debug_shadow.descriptor_set_layout = null;
        ctx.debug_shadow.vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.debug_shadow.descriptor_next = .{ 0, 0 };
    }
    ctx.cloud_pipeline = null;
    ctx.cloud_pipeline_layout = null;
    ctx.cloud_vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_ebo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.cloud_mesh_size = 10000.0;
    ctx.descriptors.descriptor_pool = null;
    ctx.descriptors.descriptor_set_layout = null;
    ctx.memory_type_index = 0;
    ctx.anisotropic_filtering = anisotropic_filtering;
    ctx.msaa_samples = msaa_samples;

    ctx.shadow_system.shadow_image = null;
    ctx.shadow_system.shadow_image_view = null;
    ctx.shadow_system.shadow_image_memory = null;
    ctx.shadow_system.shadow_sampler = null;
    ctx.shadow_system.shadow_render_pass = null;
    ctx.shadow_system.shadow_pipeline = null;
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        ctx.shadow_system.shadow_image_views[i] = null;
        ctx.shadow_system.shadow_framebuffers[i] = null;
        ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.frames.image_available_semaphores[i] = null;
        ctx.frames.render_finished_semaphores[i] = null;
        ctx.frames.in_flight_fences[i] = null;
        ctx.descriptors.global_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.shadow_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.shadow_ubos_mapped[i] = null;
        ctx.ui_vbos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.descriptor_sets[i] = null;
        ctx.descriptors.lod_descriptor_sets[i] = null;
        ctx.ui_tex_descriptor_sets[i] = null;
        ctx.ui_tex_descriptor_next[i] = 0;
        ctx.bound_instance_buffer[i] = 0;
        ctx.bound_lod_instance_buffer[i] = 0;
        for (0..ctx.ui_tex_descriptor_pool[i].len) |j| {
            ctx.ui_tex_descriptor_pool[i][j] = null;
        }
        if (comptime build_options.debug_shadows) {
            ctx.debug_shadow.descriptor_sets[i] = null;
            ctx.debug_shadow.descriptor_next[i] = 0;
            for (0..ctx.debug_shadow.descriptor_pool[i].len) |j| {
                ctx.debug_shadow.descriptor_pool[i][j] = null;
            }
        }
        ctx.resources.buffer_deletion_queue[i] = .empty;
        ctx.resources.image_deletion_queue[i] = .empty;
    }
    ctx.model_ubo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.dummy_instance_buffer = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.ui_screen_width = 0;
    ctx.ui_screen_height = 0;
    ctx.ui_flushed_vertex_count = 0;
    ctx.cloud_vao = null;
    ctx.dummy_shadow_image = null;
    ctx.dummy_shadow_memory = null;
    ctx.dummy_shadow_view = null;
    ctx.current_model = Mat4.identity;
    ctx.current_color = .{ 1.0, 1.0, 1.0 };
    ctx.current_mask_radius = 0;

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &VULKAN_RHI_VTABLE,
        .device = render_device,
    };
}
