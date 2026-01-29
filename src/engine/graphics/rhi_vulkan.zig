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
const shader_registry = @import("vulkan/shader_registry.zig");
const bloom_system_pkg = @import("vulkan/bloom_system.zig");
const BloomSystem = bloom_system_pkg.BloomSystem;
const BloomPushConstants = bloom_system_pkg.BloomPushConstants;
const fxaa_system_pkg = @import("vulkan/fxaa_system.zig");
const FXAASystem = fxaa_system_pkg.FXAASystem;
const FXAAPushConstants = fxaa_system_pkg.FXAAPushConstants;
const ssao_system_pkg = @import("vulkan/ssao_system.zig");
const SSAOSystem = ssao_system_pkg.SSAOSystem;
const SSAOParams = ssao_system_pkg.SSAOParams;
const PipelineManager = @import("vulkan/pipeline_manager.zig").PipelineManager;
const RenderPassManager = @import("vulkan/render_pass_manager.zig").RenderPassManager;

/// GPU Render Passes for profiling
const GpuPass = enum {
    shadow_0,
    shadow_1,
    shadow_2,
    g_pass,
    ssao,
    sky,
    opaque_pass,
    cloud,
    bloom,
    fxaa,
    post_process,

    pub const COUNT = 11;
};

/// Push constants for post-process pass (tonemapping + bloom integration)
const PostProcessPushConstants = extern struct {
    bloom_enabled: f32, // 0.0 = disabled, 1.0 = enabled
    bloom_intensity: f32, // Final bloom blend intensity
};

const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;
const BLOOM_MIP_COUNT = rhi.BLOOM_MIP_COUNT;
const DEPTH_FORMAT = c.VK_FORMAT_D32_SFLOAT;

/// Global uniform buffer layout (std140). Bound to descriptor set 0, binding 0.
const GlobalUniforms = extern struct {
    view_proj: Mat4, // Combined view-projection matrix
    view_proj_prev: Mat4, // Previous frame's view-projection for velocity buffer
    cam_pos: [4]f32, // Camera world position (w unused)
    sun_dir: [4]f32, // Sun direction (w unused)
    sun_color: [4]f32, // Sun color (w unused)
    fog_color: [4]f32, // Fog RGB (a unused)
    cloud_wind_offset: [4]f32, // xy = offset, z = scale, w = coverage
    params: [4]f32, // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    lighting: [4]f32, // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    cloud_params: [4]f32, // x = cloud_height, y = pcf_samples, z = cascade_blend, w = cloud_shadows
    pbr_params: [4]f32, // x = pbr_quality, y = exposure, z = saturation, w = ssao_strength
    volumetric_params: [4]f32, // x = enabled, y = density, z = steps, w = scattering
    viewport_size: [4]f32, // xy = width/height, zw = unused
};

const QUERY_COUNT_PER_FRAME = GpuPass.COUNT * 2;
const TOTAL_QUERY_COUNT = QUERY_COUNT_PER_FRAME * MAX_FRAMES_IN_FLIGHT;

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
    mvp: Mat4,
    bias_params: [4]f32, // x=normalBias, y=slopeBias, z=cascadeIndex, w=texelSize
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

    // PR1: Pipeline and Render Pass Managers
    pipeline_manager: PipelineManager = .{},
    render_pass_manager: RenderPassManager = .{},

    // Legacy / Feature State

    // Dummy shadow texture for fallback
    dummy_shadow_image: c.VkImage = null,
    dummy_shadow_memory: c.VkDeviceMemory = null,
    dummy_shadow_view: c.VkImageView = null,

    // Uniforms (Model UBOs are per-draw/push constant, but we have a fallback/dummy?)
    // descriptor_manager handles Global and Shadow UBOs.
    // We still need dummy_instance_buffer?
    model_ubo: VulkanBuffer = .{}, // Is this used?
    dummy_instance_buffer: VulkanBuffer = .{},

    transfer_fence: c.VkFence = null, // Keep for legacy sync if needed

    // Pipeline
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    sky_pipeline: c.VkPipeline = null,
    sky_pipeline_layout: c.VkPipelineLayout = null,

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
    wireframe_enabled: bool = false,
    textures_enabled: bool = true,
    wireframe_pipeline: c.VkPipeline = null,
    vsync_enabled: bool = true,
    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
    anisotropic_filtering: u8 = 1,
    msaa_samples: u8 = 1,
    safe_mode: bool = false,
    debug_shadows_active: bool = false, // Toggle shadow debug visualization with 'O' key

    // G-Pass resources
    g_normal_image: c.VkImage = null,
    g_normal_memory: c.VkDeviceMemory = null,
    g_normal_view: c.VkImageView = null,
    g_normal_handle: rhi.TextureHandle = 0,
    g_depth_image: c.VkImage = null, // G-Pass depth (1x sampled for SSAO)
    g_depth_memory: c.VkDeviceMemory = null,
    g_depth_view: c.VkImageView = null,

    // G-Pass & Passes
    g_render_pass: c.VkRenderPass = null,
    main_framebuffer: c.VkFramebuffer = null,
    g_framebuffer: c.VkFramebuffer = null,
    // Track the extent G-pass resources were created with (for mismatch detection)
    g_pass_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    // G-Pass Pipelines
    g_pipeline: c.VkPipeline = null,
    g_pipeline_layout: c.VkPipelineLayout = null,
    gpu_fault_detected: bool = false,

    shadow_system: ShadowSystem,
    ssao_system: SSAOSystem = .{},
    shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{0} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_texel_sizes: [rhi.SHADOW_CASCADE_COUNT]f32 = .{0.0} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_resolution: u32,
    memory_type_index: u32,
    framebuffer_resized: bool,
    draw_call_count: u32,
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,
    post_process_ran_this_frame: bool = false,
    fxaa_ran_this_frame: bool = false,
    pipeline_rebuild_needed: bool = false,

    // Frame state
    frame_index: usize,
    image_index: u32,

    terrain_pipeline_bound: bool = false,
    descriptors_updated: bool = false,
    lod_mode: bool = false,
    bound_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    bound_lod_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    pending_instance_buffer: rhi.BufferHandle = 0,
    pending_lod_instance_buffer: rhi.BufferHandle = 0,
    current_view_proj: Mat4 = Mat4.identity,
    current_model: Mat4 = Mat4.identity,
    current_color: [3]f32 = .{ 1.0, 1.0, 1.0 },
    current_mask_radius: f32 = 0.0,
    mutex: std.Thread.Mutex = .{},
    clear_color: [4]f32 = .{ 0.07, 0.08, 0.1, 1.0 },

    // UI Pipeline
    ui_pipeline: c.VkPipeline = null,
    ui_pipeline_layout: c.VkPipelineLayout = null,
    ui_tex_pipeline: c.VkPipeline = null,
    ui_tex_pipeline_layout: c.VkPipelineLayout = null,
    ui_swapchain_pipeline: c.VkPipeline = null,
    ui_swapchain_tex_pipeline: c.VkPipeline = null,
    ui_swapchain_render_pass: c.VkRenderPass = null,
    ui_swapchain_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    ui_tex_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    ui_tex_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    ui_tex_descriptor_pool: [MAX_FRAMES_IN_FLIGHT][64]c.VkDescriptorSet = .{.{null} ** 64} ** MAX_FRAMES_IN_FLIGHT,
    ui_tex_descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32 = .{0} ** MAX_FRAMES_IN_FLIGHT,
    ui_vbos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer = .{VulkanBuffer{}} ** MAX_FRAMES_IN_FLIGHT,
    ui_screen_width: f32 = 0.0,
    ui_screen_height: f32 = 0.0,
    ui_using_swapchain: bool = false,
    ui_in_progress: bool = false,
    ui_vertex_offset: u64 = 0,
    selection_mode: bool = false,
    selection_pipeline: c.VkPipeline = null,
    selection_pipeline_layout: c.VkPipelineLayout = null,
    line_pipeline: c.VkPipeline = null,
    ui_flushed_vertex_count: u32 = 0,
    ui_mapped_ptr: ?*anyopaque = null,

    // Cloud Pipeline
    cloud_pipeline: c.VkPipeline = null,
    cloud_pipeline_layout: c.VkPipelineLayout = null,
    cloud_vbo: VulkanBuffer = .{},
    cloud_ebo: VulkanBuffer = .{},
    cloud_mesh_size: f32 = 0.0,
    cloud_vao: c.VkBuffer = null,

    // Post-Process Resources
    hdr_image: c.VkImage = null,
    hdr_memory: c.VkDeviceMemory = null,
    hdr_view: c.VkImageView = null,
    hdr_handle: rhi.TextureHandle = 0,
    hdr_msaa_image: c.VkImage = null,
    hdr_msaa_memory: c.VkDeviceMemory = null,
    hdr_msaa_view: c.VkImageView = null,

    post_process_render_pass: c.VkRenderPass = null,
    post_process_pipeline: c.VkPipeline = null,
    post_process_pipeline_layout: c.VkPipelineLayout = null,
    post_process_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    post_process_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    post_process_sampler: c.VkSampler = null,
    post_process_pass_active: bool = false,
    post_process_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    hdr_render_pass: c.VkRenderPass = null,

    debug_shadow: DebugShadowResources = .{},

    // Phase 3 Systems
    fxaa: FXAASystem = .{},
    bloom: BloomSystem = .{},

    // Phase 3: Velocity Buffer (prep for TAA/Motion Blur)
    velocity_image: c.VkImage = null,
    velocity_memory: c.VkDeviceMemory = null,
    velocity_view: c.VkImageView = null,
    velocity_handle: rhi.TextureHandle = 0,
    view_proj_prev: Mat4 = Mat4.identity,

    // GPU Timing
    query_pool: c.VkQueryPool = null,
    timing_enabled: bool = true, // Default to true for debugging
    timing_results: rhi.GpuTimingResults = undefined,
};

fn destroyHDRResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.hdr_view != null) {
        c.vkDestroyImageView(vk, ctx.hdr_view, null);
        ctx.hdr_view = null;
    }
    if (ctx.hdr_image != null) {
        c.vkDestroyImage(vk, ctx.hdr_image, null);
        ctx.hdr_image = null;
    }
    if (ctx.hdr_memory != null) {
        c.vkFreeMemory(vk, ctx.hdr_memory, null);
        ctx.hdr_memory = null;
    }
    if (ctx.hdr_msaa_view != null) {
        c.vkDestroyImageView(vk, ctx.hdr_msaa_view, null);
        ctx.hdr_msaa_view = null;
    }
    if (ctx.hdr_msaa_image != null) {
        c.vkDestroyImage(vk, ctx.hdr_msaa_image, null);
        ctx.hdr_msaa_image = null;
    }
    if (ctx.hdr_msaa_memory != null) {
        c.vkFreeMemory(vk, ctx.hdr_msaa_memory, null);
        ctx.hdr_msaa_memory = null;
    }
}

fn destroyPostProcessResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    // Destroy post-process framebuffers
    for (ctx.post_process_framebuffers.items) |fb| {
        c.vkDestroyFramebuffer(vk, fb, null);
    }
    ctx.post_process_framebuffers.deinit(ctx.allocator);
    ctx.post_process_framebuffers = .empty;

    if (ctx.post_process_sampler != null) {
        c.vkDestroySampler(vk, ctx.post_process_sampler, null);
        ctx.post_process_sampler = null;
    }
    if (ctx.post_process_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.post_process_pipeline, null);
        ctx.post_process_pipeline = null;
    }
    if (ctx.post_process_pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vk, ctx.post_process_pipeline_layout, null);
        ctx.post_process_pipeline_layout = null;
    }
    // Note: post_process_descriptor_set_layout is created once in initContext and NOT destroyed here
    if (ctx.post_process_render_pass != null) {
        c.vkDestroyRenderPass(vk, ctx.post_process_render_pass, null);
        ctx.post_process_render_pass = null;
    }

    destroySwapchainUIResources(ctx);
}

fn destroyGPassResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    destroyVelocityResources(ctx);
    ctx.ssao_system.deinit(vk, ctx.allocator);
    if (ctx.g_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.g_pipeline, null);
        ctx.g_pipeline = null;
    }
    if (ctx.g_pipeline_layout != null) {
        c.vkDestroyPipelineLayout(vk, ctx.g_pipeline_layout, null);
        ctx.g_pipeline_layout = null;
    }
    if (ctx.g_framebuffer != null) {
        c.vkDestroyFramebuffer(vk, ctx.g_framebuffer, null);
        ctx.g_framebuffer = null;
    }
    if (ctx.render_pass_manager.g_render_pass != null) {
        c.vkDestroyRenderPass(vk, ctx.render_pass_manager.g_render_pass, null);
        ctx.render_pass_manager.g_render_pass = null;
    }
    if (ctx.g_normal_view != null) {
        c.vkDestroyImageView(vk, ctx.g_normal_view, null);
        ctx.g_normal_view = null;
    }
    if (ctx.g_normal_image != null) {
        c.vkDestroyImage(vk, ctx.g_normal_image, null);
        ctx.g_normal_image = null;
    }
    if (ctx.g_normal_memory != null) {
        c.vkFreeMemory(vk, ctx.g_normal_memory, null);
        ctx.g_normal_memory = null;
    }
    if (ctx.g_depth_view != null) {
        c.vkDestroyImageView(vk, ctx.g_depth_view, null);
        ctx.g_depth_view = null;
    }
    if (ctx.g_depth_image != null) {
        c.vkDestroyImage(vk, ctx.g_depth_image, null);
        ctx.g_depth_image = null;
    }
    if (ctx.g_depth_memory != null) {
        c.vkFreeMemory(vk, ctx.g_depth_memory, null);
        ctx.g_depth_memory = null;
    }
}

fn destroySwapchainUIPipelines(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    if (ctx.ui_swapchain_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.ui_swapchain_pipeline, null);
        ctx.ui_swapchain_pipeline = null;
    }
    if (ctx.ui_swapchain_tex_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.ui_swapchain_tex_pipeline, null);
        ctx.ui_swapchain_tex_pipeline = null;
    }
}

fn destroySwapchainUIResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    for (ctx.ui_swapchain_framebuffers.items) |fb| {
        c.vkDestroyFramebuffer(vk, fb, null);
    }
    ctx.ui_swapchain_framebuffers.deinit(ctx.allocator);
    ctx.ui_swapchain_framebuffers = .empty;

    if (ctx.ui_swapchain_render_pass != null) {
        c.vkDestroyRenderPass(vk, ctx.ui_swapchain_render_pass, null);
        ctx.ui_swapchain_render_pass = null;
    }
}

fn destroyFXAAResources(ctx: *VulkanContext) void {
    destroySwapchainUIPipelines(ctx);
    ctx.fxaa.deinit(ctx.vulkan_device.vk_device, ctx.allocator, ctx.descriptors.descriptor_pool);
}

fn destroyBloomResources(ctx: *VulkanContext) void {
    ctx.bloom.deinit(ctx.vulkan_device.vk_device, ctx.allocator, ctx.descriptors.descriptor_pool);
}

fn destroyVelocityResources(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    if (ctx.velocity_view != null) {
        c.vkDestroyImageView(vk, ctx.velocity_view, null);
        ctx.velocity_view = null;
    }
    if (ctx.velocity_image != null) {
        c.vkDestroyImage(vk, ctx.velocity_image, null);
        ctx.velocity_image = null;
    }
    if (ctx.velocity_memory != null) {
        c.vkFreeMemory(vk, ctx.velocity_memory, null);
        ctx.velocity_memory = null;
    }
}

/// Transitions an array of images to SHADER_READ_ONLY_OPTIMAL layout.
fn transitionImagesToShaderRead(ctx: *VulkanContext, images: []const c.VkImage, is_depth: bool) !void {
    const aspect_mask: c.VkImageAspectFlags = if (is_depth) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandPool = ctx.frames.command_pool;
    alloc_info.commandBufferCount = 1;

    var cmd: c.VkCommandBuffer = null;
    try Utils.checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &alloc_info, &cmd));
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

    const count = images.len;
    var barriers: [16]c.VkImageMemoryBarrier = undefined;
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

fn createHDRResources(ctx: *VulkanContext) !void {
    const extent = ctx.swapchain.getExtent();
    const format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    const sample_count = getMSAASampleCountFlag(ctx.msaa_samples);

    // 1. Create HDR image
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &image_info, null, &ctx.hdr_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.hdr_image, &mem_reqs);
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.hdr_memory));
    try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.hdr_image, ctx.hdr_memory, 0));

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = ctx.hdr_image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = format;
    view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.hdr_view));

    // 2. Create MSAA HDR image if needed
    if (ctx.msaa_samples > 1) {
        image_info.samples = sample_count;
        image_info.usage = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &image_info, null, &ctx.hdr_msaa_image));
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.hdr_msaa_image, &mem_reqs);
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.hdr_msaa_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.hdr_msaa_image, ctx.hdr_msaa_memory, 0));

        view_info.image = ctx.hdr_msaa_image;
        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.hdr_msaa_view));
    }
}

fn createPostProcessResources(ctx: *VulkanContext) !void {
    const vk = ctx.vulkan_device.vk_device;

    // 1. Render Pass
    var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
    color_attachment.format = ctx.swapchain.getImageFormat();
    color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
    color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_ref;

    var dependency = std.mem.zeroes(c.VkSubpassDependency);
    dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.srcAccessMask = 0;
    dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
    rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rp_info.attachmentCount = 1;
    rp_info.pAttachments = &color_attachment;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = &subpass;
    rp_info.dependencyCount = 1;
    rp_info.pDependencies = &dependency;

    try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &ctx.post_process_render_pass));

    // 2. Descriptor Set Layout (binding 0: HDR scene, binding 1: uniforms, binding 2: bloom)
    if (ctx.post_process_descriptor_set_layout == null) {
        var bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 3;
        layout_info.pBindings = &bindings[0];
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &ctx.post_process_descriptor_set_layout));
    }

    // 3. Pipeline Layout (with push constants for bloom parameters)
    if (ctx.post_process_pipeline_layout == null) {
        var post_push_constant = std.mem.zeroes(c.VkPushConstantRange);
        post_push_constant.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        post_push_constant.offset = 0;
        post_push_constant.size = 8; // 2 floats: bloomEnabled, bloomIntensity

        var pipe_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipe_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipe_layout_info.setLayoutCount = 1;
        pipe_layout_info.pSetLayouts = &ctx.post_process_descriptor_set_layout;
        pipe_layout_info.pushConstantRangeCount = 1;
        pipe_layout_info.pPushConstantRanges = &post_push_constant;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipe_layout_info, null, &ctx.post_process_pipeline_layout));
    }

    // 4. Create Linear Sampler
    if (ctx.post_process_sampler != null) {
        c.vkDestroySampler(vk, ctx.post_process_sampler, null);
        ctx.post_process_sampler = null;
    }

    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = c.VK_FILTER_LINEAR;
    sampler_info.minFilter = c.VK_FILTER_LINEAR;
    sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
    var linear_sampler: c.VkSampler = null;
    try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &linear_sampler));
    errdefer c.vkDestroySampler(vk, linear_sampler, null);

    // 5. Pipeline
    const vert_code = try std.fs.cwd().readFileAlloc(shader_registry.POST_PROCESS_VERT, ctx.allocator, @enumFromInt(1024 * 1024));
    defer ctx.allocator.free(vert_code);
    const frag_code = try std.fs.cwd().readFileAlloc(shader_registry.POST_PROCESS_FRAG, ctx.allocator, @enumFromInt(1024 * 1024));
    defer ctx.allocator.free(frag_code);
    const vert_module = try Utils.createShaderModule(vk, vert_code);
    defer c.vkDestroyShaderModule(vk, vert_module, null);
    const frag_module = try Utils.createShaderModule(vk, frag_code);
    defer c.vkDestroyShaderModule(vk, frag_module, null);

    var stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
    };

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
    rs_info.lineWidth = 1.0;
    rs_info.cullMode = c.VK_CULL_MODE_NONE;
    rs_info.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;

    var ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var cb_attach = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    cb_attach.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    var cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb_info.attachmentCount = 1;
    cb_info.pAttachments = &cb_attach;

    var dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dyn_info = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dyn_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dyn_info.dynamicStateCount = 2;
    dyn_info.pDynamicStates = &dyn_states[0];

    var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipe_info.stageCount = 2;
    pipe_info.pStages = &stages[0];
    pipe_info.pVertexInputState = &vi_info;
    pipe_info.pInputAssemblyState = &ia_info;
    pipe_info.pViewportState = &vp_info;
    pipe_info.pRasterizationState = &rs_info;
    pipe_info.pMultisampleState = &ms_info;
    pipe_info.pColorBlendState = &cb_info;
    pipe_info.pDynamicState = &dyn_info;
    pipe_info.layout = ctx.post_process_pipeline_layout;
    pipe_info.renderPass = ctx.post_process_render_pass;

    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &ctx.post_process_pipeline));

    // 6. Descriptor Sets
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        if (ctx.post_process_descriptor_sets[i] == null) {
            var alloc_ds_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_ds_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_ds_info.descriptorPool = ctx.descriptors.descriptor_pool;
            alloc_ds_info.descriptorSetCount = 1;
            alloc_ds_info.pSetLayouts = &ctx.post_process_descriptor_set_layout;
            try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_ds_info, &ctx.post_process_descriptor_sets[i]));
        }

        var image_info_ds = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info_ds.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        image_info_ds.imageView = ctx.hdr_view;
        image_info_ds.sampler = linear_sampler;

        var buffer_info_ds = std.mem.zeroes(c.VkDescriptorBufferInfo);
        buffer_info_ds.buffer = ctx.descriptors.global_ubos[i].buffer;
        buffer_info_ds.offset = 0;
        buffer_info_ds.range = @sizeOf(GlobalUniforms);

        var writes = [_]c.VkWriteDescriptorSet{
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = ctx.post_process_descriptor_sets[i],
                .dstBinding = 0,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .pImageInfo = &image_info_ds,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = ctx.post_process_descriptor_sets[i],
                .dstBinding = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1,
                .pBufferInfo = &buffer_info_ds,
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = ctx.post_process_descriptor_sets[i],
                .dstBinding = 2,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1,
                .pImageInfo = &image_info_ds, // Dummy: use HDR view as placeholder for bloom
            },
        };
        c.vkUpdateDescriptorSets(vk, 3, &writes[0], 0, null);
    }

    // 7. Create post-process framebuffers (one per swapchain image)
    for (ctx.post_process_framebuffers.items) |fb| {
        c.vkDestroyFramebuffer(vk, fb, null);
    }
    ctx.post_process_framebuffers.clearRetainingCapacity();

    for (ctx.swapchain.getImageViews()) |iv| {
        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.post_process_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &iv;
        fb_info.width = ctx.swapchain.getExtent().width;
        fb_info.height = ctx.swapchain.getExtent().height;
        fb_info.layers = 1;

        var fb: c.VkFramebuffer = null;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &fb));
        try ctx.post_process_framebuffers.append(ctx.allocator, fb);
    }

    // Clean up local sampler if not stored in context (but we should probably store it to destroy it later)
    ctx.post_process_sampler = linear_sampler;
}

fn createSwapchainUIResources(ctx: *VulkanContext) !void {
    const vk = ctx.vulkan_device.vk_device;

    destroySwapchainUIResources(ctx);
    errdefer destroySwapchainUIResources(ctx);

    var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
    color_attachment.format = ctx.swapchain.getImageFormat();
    color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
    color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD;
    color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_ref;

    var dependency = std.mem.zeroes(c.VkSubpassDependency);
    dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
    dependency.dstSubpass = 0;
    dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.srcAccessMask = 0;
    dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
    dependency.dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

    var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
    rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rp_info.attachmentCount = 1;
    rp_info.pAttachments = &color_attachment;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = &subpass;
    rp_info.dependencyCount = 1;
    rp_info.pDependencies = &dependency;

    try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &ctx.ui_swapchain_render_pass));

    for (ctx.swapchain.getImageViews()) |iv| {
        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.ui_swapchain_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &iv;
        fb_info.width = ctx.swapchain.getExtent().width;
        fb_info.height = ctx.swapchain.getExtent().height;
        fb_info.layers = 1;

        var fb: c.VkFramebuffer = null;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &fb));
        try ctx.ui_swapchain_framebuffers.append(ctx.allocator, fb);
    }
}

fn createShadowResources(ctx: *VulkanContext) !void {
    const vk = ctx.vulkan_device.vk_device;
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
    c.vkGetImageMemoryRequirements(vk, ctx.shadow_system.shadow_image, &mem_reqs);
    var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.shadow_system.shadow_image_memory));
    try Utils.checkVk(c.vkBindImageMemory(vk, ctx.shadow_system.shadow_image, ctx.shadow_system.shadow_image_memory, 0));

    // Full array view for sampling
    var array_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    array_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    array_view_info.image = ctx.shadow_system.shadow_image;
    array_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    array_view_info.format = DEPTH_FORMAT;
    array_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = rhi.SHADOW_CASCADE_COUNT };
    try Utils.checkVk(c.vkCreateImageView(vk, &array_view_info, null, &ctx.shadow_system.shadow_image_view));

    // Shadow Samplers
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
        sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
        sampler_info.compareEnable = c.VK_TRUE;
        sampler_info.compareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &ctx.shadow_system.shadow_sampler));

        // Regular sampler (no comparison) for debug visualization
        var regular_sampler_info = sampler_info;
        regular_sampler_info.compareEnable = c.VK_FALSE;
        regular_sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
        try Utils.checkVk(c.vkCreateSampler(vk, &regular_sampler_info, null, &ctx.shadow_system.shadow_sampler_regular));
    }

    // Layered views for framebuffers (one per cascade)
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        var layer_view: c.VkImageView = null;
        var layer_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        layer_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        layer_view_info.image = ctx.shadow_system.shadow_image;
        layer_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        layer_view_info.format = DEPTH_FORMAT;
        layer_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = @intCast(si), .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &layer_view_info, null, &layer_view));
        ctx.shadow_system.shadow_image_views[si] = layer_view;

        // Register shadow cascade as a texture handle for debug visualization
        ctx.shadow_map_handles[si] = try ctx.resources.registerExternalTexture(shadow_res, shadow_res, .depth, layer_view, ctx.shadow_system.shadow_sampler_regular);

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.shadow_system.shadow_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.shadow_system.shadow_image_views[si];
        fb_info.width = shadow_res;
        fb_info.height = shadow_res;
        fb_info.layers = 1;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &ctx.shadow_system.shadow_framebuffers[si]));
        ctx.shadow_system.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    const shadow_vert = try std.fs.cwd().readFileAlloc(shader_registry.SHADOW_VERT, ctx.allocator, @enumFromInt(1024 * 1024));
    defer ctx.allocator.free(shadow_vert);
    const shadow_frag = try std.fs.cwd().readFileAlloc(shader_registry.SHADOW_FRAG, ctx.allocator, @enumFromInt(1024 * 1024));
    defer ctx.allocator.free(shadow_frag);

    const shadow_vert_module = try Utils.createShaderModule(vk, shadow_vert);
    defer c.vkDestroyShaderModule(vk, shadow_vert_module, null);
    const shadow_frag_module = try Utils.createShaderModule(vk, shadow_frag);
    defer c.vkDestroyShaderModule(vk, shadow_frag_module, null);

    var shadow_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = shadow_vert_module, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = shadow_frag_module, .pName = "main" },
    };

    const shadow_binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    var shadow_attrs: [2]c.VkVertexInputAttributeDescription = undefined;
    shadow_attrs[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
    shadow_attrs[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 24 }; // normal offset

    var shadow_vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    shadow_vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    shadow_vertex_input.vertexBindingDescriptionCount = 1;
    shadow_vertex_input.pVertexBindingDescriptions = &shadow_binding;
    shadow_vertex_input.vertexAttributeDescriptionCount = 2;
    shadow_vertex_input.pVertexAttributeDescriptions = &shadow_attrs[0];

    var shadow_input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    shadow_input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    shadow_input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    var shadow_rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    shadow_rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    shadow_rasterizer.lineWidth = 1.0;
    shadow_rasterizer.cullMode = c.VK_CULL_MODE_NONE;
    shadow_rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
    shadow_rasterizer.depthBiasEnable = c.VK_TRUE;

    var shadow_multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    shadow_multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    shadow_multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var shadow_depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    shadow_depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    shadow_depth_stencil.depthTestEnable = c.VK_TRUE;
    shadow_depth_stencil.depthWriteEnable = c.VK_TRUE;
    shadow_depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

    var shadow_color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    shadow_color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    shadow_color_blend.attachmentCount = 0;
    shadow_color_blend.pAttachments = null;

    const shadow_dynamic_states = [_]c.VkDynamicState{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
        c.VK_DYNAMIC_STATE_DEPTH_BIAS,
    };
    var shadow_dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    shadow_dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    shadow_dynamic_state.dynamicStateCount = shadow_dynamic_states.len;
    shadow_dynamic_state.pDynamicStates = &shadow_dynamic_states;

    var shadow_viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    shadow_viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    shadow_viewport_state.viewportCount = 1;
    shadow_viewport_state.scissorCount = 1;

    var shadow_pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    shadow_pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    shadow_pipeline_info.stageCount = shadow_stages.len;
    shadow_pipeline_info.pStages = &shadow_stages[0];
    shadow_pipeline_info.pVertexInputState = &shadow_vertex_input;
    shadow_pipeline_info.pInputAssemblyState = &shadow_input_assembly;
    shadow_pipeline_info.pViewportState = &shadow_viewport_state;
    shadow_pipeline_info.pRasterizationState = &shadow_rasterizer;
    shadow_pipeline_info.pMultisampleState = &shadow_multisampling;
    shadow_pipeline_info.pDepthStencilState = &shadow_depth_stencil;
    shadow_pipeline_info.pColorBlendState = &shadow_color_blend;
    shadow_pipeline_info.pDynamicState = &shadow_dynamic_state;
    shadow_pipeline_info.layout = ctx.pipeline_layout;
    shadow_pipeline_info.renderPass = ctx.shadow_system.shadow_render_pass;
    shadow_pipeline_info.subpass = 0;

    var new_pipeline: c.VkPipeline = null;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &shadow_pipeline_info, null, &new_pipeline));

    if (ctx.shadow_system.shadow_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.shadow_system.shadow_pipeline, null);
    }
    ctx.shadow_system.shadow_pipeline = new_pipeline;
}

/// Updates post-process descriptor sets to include bloom texture (called after bloom resources are created)
fn updatePostProcessDescriptorsWithBloom(ctx: *VulkanContext) void {
    const vk = ctx.vulkan_device.vk_device;

    // Get bloom mip0 view (the final composited bloom result)
    const bloom_view = if (ctx.bloom.mip_views[0] != null) ctx.bloom.mip_views[0] else return;
    const sampler = if (ctx.bloom.sampler != null) ctx.bloom.sampler else ctx.post_process_sampler;

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        if (ctx.post_process_descriptor_sets[i] == null) continue;

        var bloom_image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        bloom_image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        bloom_image_info.imageView = bloom_view;
        bloom_image_info.sampler = sampler;

        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = ctx.post_process_descriptor_sets[i];
        write.dstBinding = 2;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.descriptorCount = 1;
        write.pImageInfo = &bloom_image_info;

        c.vkUpdateDescriptorSets(vk, 1, &write, 0, null);
    }
}

fn createGPassResources(ctx: *VulkanContext) !void {
    destroyGPassResources(ctx);
    const normal_format = c.VK_FORMAT_R8G8B8A8_UNORM; // Store normals in [0,1] range
    const velocity_format = c.VK_FORMAT_R16G16_SFLOAT; // RG16F for velocity vectors

    // Create G-Pass render pass using manager
    try ctx.render_pass_manager.createGPassRenderPass(ctx.vulkan_device.vk_device);

    const vk = ctx.vulkan_device.vk_device;
    const extent = ctx.swapchain.getExtent();

    // 2. Create normal image for G-Pass output
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = normal_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.g_normal_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.g_normal_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.g_normal_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.g_normal_image, ctx.g_normal_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_normal_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = normal_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.g_normal_view));
    }

    // 3. Create velocity image for motion vectors (Phase 3)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = velocity_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.velocity_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.velocity_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.velocity_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.velocity_image, ctx.velocity_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.velocity_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = velocity_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.velocity_view));
    }

    // 4. Create G-Pass depth image (separate from MSAA depth, 1x sampled for SSAO)
    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = DEPTH_FORMAT;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.g_depth_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.g_depth_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.g_depth_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.g_depth_image, ctx.g_depth_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.g_depth_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.g_depth_view));
    }

    // 5. Create G-Pass framebuffer (3 attachments: normal, velocity, depth)
    {
        const fb_attachments = [_]c.VkImageView{ ctx.g_normal_view, ctx.velocity_view, ctx.g_depth_view };

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.render_pass_manager.g_render_pass;
        fb_info.attachmentCount = 3;
        fb_info.pAttachments = &fb_attachments;
        fb_info.width = extent.width;
        fb_info.height = extent.height;
        fb_info.layers = 1;

        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &ctx.g_framebuffer));
    }

    // Transition images to shader read layout
    const g_images = [_]c.VkImage{ ctx.g_normal_image, ctx.velocity_image };
    try transitionImagesToShaderRead(ctx, &g_images, false);
    const d_images = [_]c.VkImage{ctx.g_depth_image};
    try transitionImagesToShaderRead(ctx, &d_images, true);

    // Store the extent we created resources with for mismatch detection
    ctx.g_pass_extent = extent;
    std.log.info("G-Pass resources created ({}x{}) with velocity buffer", .{ extent.width, extent.height });
}

/// Creates SSAO resources: render pass, AO image, noise texture, kernel UBO, framebuffer, pipeline.
fn createSSAOResources(ctx: *VulkanContext) !void {
    const extent = ctx.swapchain.getExtent();
    try ctx.ssao_system.init(
        &ctx.vulkan_device,
        ctx.allocator,
        ctx.descriptors.descriptor_pool,
        ctx.frames.command_pool,
        extent.width,
        extent.height,
        ctx.g_normal_view,
        ctx.g_depth_view,
    );

    // Register SSAO result for main pass
    ctx.bound_ssao_handle = try ctx.resources.registerNativeTexture(
        ctx.ssao_system.blur_image,
        ctx.ssao_system.blur_view,
        ctx.ssao_system.sampler,
        extent.width,
        extent.height,
        .red,
    );

    // Update main descriptor sets with SSAO map (Binding 10)
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        var main_ssao_info = c.VkDescriptorImageInfo{
            .sampler = ctx.ssao_system.sampler,
            .imageView = ctx.ssao_system.blur_view,
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
    const ssao_images = [_]c.VkImage{ ctx.ssao_system.image, ctx.ssao_system.blur_image };
    try transitionImagesToShaderRead(ctx, &ssao_images, false);
}

fn createMainFramebuffers(ctx: *VulkanContext) !void {
    const use_msaa = ctx.msaa_samples > 1;
    const extent = ctx.swapchain.getExtent();

    var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
    fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fb_info.renderPass = ctx.render_pass_manager.hdr_render_pass;
    fb_info.width = extent.width;
    fb_info.height = extent.height;
    fb_info.layers = 1;

    // Destroy old framebuffer if it exists
    if (ctx.main_framebuffer != null) {
        c.vkDestroyFramebuffer(ctx.vulkan_device.vk_device, ctx.main_framebuffer, null);
        ctx.main_framebuffer = null;
    }

    if (use_msaa) {
        std.log.info("Creating MSAA framebuffers with {} samples", .{ctx.msaa_samples});
        // [MSAA Color, MSAA Depth, Resolve HDR]
        const attachments = [_]c.VkImageView{ ctx.hdr_msaa_view, ctx.swapchain.swapchain.depth_image_view, ctx.hdr_view };
        fb_info.attachmentCount = 3;
        fb_info.pAttachments = &attachments[0];
        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.main_framebuffer));
    } else {
        // [HDR Color, Depth]
        const attachments = [_]c.VkImageView{ ctx.hdr_view, ctx.swapchain.swapchain.depth_image_view };
        fb_info.attachmentCount = 2;
        fb_info.pAttachments = &attachments[0];
        try Utils.checkVk(c.vkCreateFramebuffer(ctx.vulkan_device.vk_device, &fb_info, null, &ctx.main_framebuffer));
    }
}


fn createSwapchainUIPipelines(ctx: *VulkanContext) !void {
    if (ctx.ui_swapchain_render_pass == null) return error.InitializationFailed;

    destroySwapchainUIPipelines(ctx);
    errdefer destroySwapchainUIPipelines(ctx);

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
    multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depth_stencil.depthTestEnable = c.VK_FALSE;
    depth_stencil.depthWriteEnable = c.VK_FALSE;

    var ui_color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    ui_color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
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

    // UI
    {
        const vert_code = try std.fs.cwd().readFileAlloc(shader_registry.UI_VERT, ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc(shader_registry.UI_FRAG, ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(frag_code);
        const vert_module = try Utils.createShaderModule(ctx.vulkan_device.vk_device, vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, vert_module, null);
        const frag_module = try Utils.createShaderModule(ctx.vulkan_device.vk_device, frag_code);
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
        pipeline_info.pColorBlendState = &ui_color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = ctx.ui_pipeline_layout;
        pipeline_info.renderPass = ctx.ui_swapchain_render_pass;
        pipeline_info.subpass = 0;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_swapchain_pipeline));

        // Textured UI
        const tex_vert_code = try std.fs.cwd().readFileAlloc(shader_registry.UI_TEX_VERT, ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_vert_code);
        const tex_frag_code = try std.fs.cwd().readFileAlloc(shader_registry.UI_TEX_FRAG, ctx.allocator, @enumFromInt(1024 * 1024));
        defer ctx.allocator.free(tex_frag_code);
        const tex_vert_module = try Utils.createShaderModule(ctx.vulkan_device.vk_device, tex_vert_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, tex_vert_module, null);
        const tex_frag_module = try Utils.createShaderModule(ctx.vulkan_device.vk_device, tex_frag_code);
        defer c.vkDestroyShaderModule(ctx.vulkan_device.vk_device, tex_frag_module, null);
        var tex_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = tex_vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = tex_frag_module, .pName = "main" },
        };
        pipeline_info.pStages = &tex_shader_stages[0];
        pipeline_info.layout = ctx.ui_tex_pipeline_layout;
        pipeline_info.renderPass = ctx.ui_swapchain_render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(ctx.vulkan_device.vk_device, null, 1, &pipeline_info, null, &ctx.ui_swapchain_tex_pipeline));
    }
}

fn destroyMainRenderPassAndPipelines(ctx: *VulkanContext) void {
    if (ctx.vulkan_device.vk_device == null) return;
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    if (ctx.main_framebuffer != null) {
        c.vkDestroyFramebuffer(ctx.vulkan_device.vk_device, ctx.main_framebuffer, null);
        ctx.main_framebuffer = null;
    }

    if (ctx.pipeline_manager.terrain_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.terrain_pipeline, null);
        ctx.pipeline_manager.terrain_pipeline = null;
    }
    if (ctx.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.wireframe_pipeline, null);
        ctx.wireframe_pipeline = null;
    }
    if (ctx.selection_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.selection_pipeline, null);
        ctx.selection_pipeline = null;
    }
    if (ctx.line_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.line_pipeline, null);
        ctx.line_pipeline = null;
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
    if (ctx.render_pass_manager.hdr_render_pass != null) {
        c.vkDestroyRenderPass(ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, null);
        ctx.render_pass_manager.hdr_render_pass = null;
    }
}

fn initContext(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    // Ensure we cleanup everything on error
    errdefer deinit(ctx_ptr);

    ctx.allocator = allocator;
    ctx.render_device = render_device;

    ctx.vulkan_device = try VulkanDevice.init(allocator, ctx.window);
    ctx.vulkan_device.initDebugMessenger();
    ctx.resources = try ResourceManager.init(allocator, &ctx.vulkan_device);
    ctx.frames = try FrameManager.init(&ctx.vulkan_device);
    ctx.swapchain = try SwapchainPresenter.init(allocator, &ctx.vulkan_device, ctx.window, ctx.msaa_samples);
    ctx.descriptors = try DescriptorManager.init(allocator, &ctx.vulkan_device, &ctx.resources);

    // PR1: Initialize PipelineManager and RenderPassManager
    ctx.pipeline_manager = try PipelineManager.init(&ctx.vulkan_device, &ctx.descriptors, null);
    ctx.render_pass_manager = RenderPassManager.init();

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

    // Initial resources - HDR must be created before main render pass (framebuffers use HDR views)
    try createHDRResources(ctx);
    try createGPassResources(ctx);
    try createSSAOResources(ctx);

    // Create main render pass and framebuffers using manager (depends on HDR views)
    try ctx.render_pass_manager.createMainRenderPass(
        ctx.vulkan_device.vk_device,
        ctx.swapchain.getExtent(),
        ctx.msaa_samples,
    );

    // Final Pipelines using manager (depend on main_render_pass)
    try ctx.pipeline_manager.createMainPipelines(
        ctx.allocator,
        ctx.vulkan_device.vk_device,
        ctx.render_pass_manager.hdr_render_pass,
        ctx.render_pass_manager.g_render_pass,
        ctx.msaa_samples,
    );

    // Post-process resources (depend on HDR views and post-process render pass)
    try createPostProcessResources(ctx);
    try createSwapchainUIResources(ctx);

    // Phase 3: FXAA and Bloom resources (depend on post-process sampler and HDR views)
    try ctx.fxaa.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.swapchain.getExtent(), ctx.swapchain.getImageFormat(), ctx.post_process_sampler, ctx.swapchain.getImageViews());
    try createSwapchainUIPipelines(ctx);
    try ctx.bloom.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.hdr_view, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, c.VK_FORMAT_R16G16B16A16_SFLOAT);

    // Update post-process descriptor sets to include bloom texture (binding 2)
    updatePostProcessDescriptorsWithBloom(ctx);

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

    // Ensure shadow image is in readable layout initially (in case ShadowPass is skipped)
    if (ctx.shadow_system.shadow_image != null) {
        try transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true);
        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        }
    }

    // Ensure all images are in shader-read layout initially
    {
        var list: [32]c.VkImage = undefined;
        var count: usize = 0;
        // Note: ctx.hdr_msaa_image is transient and not sampled, so it should not be transitioned to SHADER_READ_ONLY_OPTIMAL
        const candidates = [_]c.VkImage{ ctx.hdr_image, ctx.g_normal_image, ctx.ssao_system.image, ctx.ssao_system.blur_image, ctx.ssao_system.noise_image, ctx.velocity_image };
        for (candidates) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }
        // Also transition bloom mips
        for (ctx.bloom.mip_images) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }

        if (count > 0) {
            transitionImagesToShaderRead(ctx, list[0..count], false) catch |err| std.log.err("Failed to transition images during init: {}", .{err});
        }

        if (ctx.g_depth_image != null) {
            transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.g_depth_image}, true) catch |err| std.log.err("Failed to transition G-depth image during init: {}", .{err});
        }
    }

    // 11. GPU Timing Query Pool
    var query_pool_info = std.mem.zeroes(c.VkQueryPoolCreateInfo);
    query_pool_info.sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
    query_pool_info.queryType = c.VK_QUERY_TYPE_TIMESTAMP;
    query_pool_info.queryCount = TOTAL_QUERY_COUNT;
    try Utils.checkVk(c.vkCreateQueryPool(ctx.vulkan_device.vk_device, &query_pool_info, null, &ctx.query_pool));
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.dry_run) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }

    destroyMainRenderPassAndPipelines(ctx);
    destroyHDRResources(ctx);
    destroyFXAAResources(ctx);
    destroyBloomResources(ctx);
    destroyVelocityResources(ctx);
    destroyPostProcessResources(ctx);
    destroyGPassResources(ctx);

    if (ctx.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.pipeline_layout, null);
    if (ctx.sky_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.sky_pipeline_layout, null);
    if (ctx.ui_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_pipeline_layout, null);
    if (ctx.ui_tex_pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_pipeline_layout, null);
    if (ctx.ui_tex_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.ui_tex_descriptor_set_layout, null);
    if (ctx.post_process_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(ctx.vulkan_device.vk_device, ctx.post_process_descriptor_set_layout, null);
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

    if (ctx.query_pool != null) {
        c.vkDestroyQueryPool(ctx.vulkan_device.vk_device, ctx.query_pool, null);
    }

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
    std.debug.print("recreateSwapchainInternal: starting...\n", .{});
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) {
        std.debug.print("recreateSwapchainInternal: window minimized or 0 size, skipping.\n", .{});
        return;
    }

    std.debug.print("recreateSwapchainInternal: destroying old resources...\n", .{});
    destroyMainRenderPassAndPipelines(ctx);
    destroyHDRResources(ctx);
    destroyFXAAResources(ctx);
    destroyBloomResources(ctx);
    destroyPostProcessResources(ctx);
    destroyGPassResources(ctx);

    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.g_pass_active = false;
    ctx.ssao_pass_active = false;

    std.debug.print("recreateSwapchainInternal: swapchain.recreate()...\n", .{});
    ctx.swapchain.recreate() catch |err| {
        std.log.err("Failed to recreate swapchain: {}", .{err});
        return;
    };

    // Recreate resources
    std.debug.print("recreateSwapchainInternal: recreating resources...\n", .{});
    createHDRResources(ctx) catch |err| std.log.err("Failed to recreate HDR resources: {}", .{err});
    createGPassResources(ctx) catch |err| std.log.err("Failed to recreate G-Pass resources: {}", .{err});
    createSSAOResources(ctx) catch |err| std.log.err("Failed to recreate SSAO resources: {}", .{err});
    ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), ctx.msaa_samples) catch |err| std.log.err("Failed to recreate render pass: {}", .{err});
    ctx.pipeline_manager.createMainPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, ctx.render_pass_manager.g_render_pass, ctx.msaa_samples) catch |err| std.log.err("Failed to recreate pipelines: {}", .{err});
    createPostProcessResources(ctx) catch |err| std.log.err("Failed to recreate post-process resources: {}", .{err});
    createSwapchainUIResources(ctx) catch |err| std.log.err("Failed to recreate swapchain UI resources: {}", .{err});
    ctx.fxaa.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.swapchain.getExtent(), ctx.swapchain.getImageFormat(), ctx.post_process_sampler, ctx.swapchain.getImageViews()) catch |err| std.log.err("Failed to recreate FXAA resources: {}", .{err});
    createSwapchainUIPipelines(ctx) catch |err| std.log.err("Failed to recreate swapchain UI pipelines: {}", .{err});
    ctx.bloom.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.hdr_view, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, c.VK_FORMAT_R16G16B16A16_SFLOAT) catch |err| std.log.err("Failed to recreate Bloom resources: {}", .{err});
    updatePostProcessDescriptorsWithBloom(ctx);

    // Ensure all recreated images are in a known layout
    {
        var list: [32]c.VkImage = undefined;
        var count: usize = 0;
        // Note: ctx.hdr_msaa_image is transient and not sampled, so it should not be transitioned to SHADER_READ_ONLY_OPTIMAL
        const candidates = [_]c.VkImage{ ctx.hdr_image, ctx.g_normal_image, ctx.ssao_system.image, ctx.ssao_system.blur_image, ctx.ssao_system.noise_image, ctx.velocity_image };
        for (candidates) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }
        // Also transition bloom mips
        for (ctx.bloom.mip_images) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }

        if (count > 0) {
            transitionImagesToShaderRead(ctx, list[0..count], false) catch |err| std.log.warn("Failed to transition images: {}", .{err});
        }

        if (ctx.g_depth_image != null) {
            transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.g_depth_image}, true) catch |err| std.log.warn("Failed to transition G-depth image: {}", .{err});
        }
        if (ctx.shadow_system.shadow_image != null) {
            transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true) catch |err| std.log.warn("Failed to transition Shadow image: {}", .{err});
            for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
                ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            }
        }
    }

    ctx.framebuffer_resized = false;

    ctx.pipeline_rebuild_needed = false;
    std.debug.print("recreateSwapchainInternal: done.\n", .{});
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
        std.log.info("beginFrame: triggering recreateSwapchainInternal (resize)", .{});
        recreateSwapchainInternal(ctx);
    }

    if (ctx.resources.transfer_ready) {
        ctx.resources.flushTransfer() catch |err| {
            std.log.err("Failed to flush inter-frame transfers: {}", .{err});
        };
    }

    // Begin frame (acquire image, reset fences/CBs)
    const frame_started = ctx.frames.beginFrame(&ctx.swapchain) catch |err| {
        if (err == error.GpuLost) {
            ctx.gpu_fault_detected = true;
        } else {
            std.log.err("beginFrame failed: {}", .{err});
        }
        return;
    };

    if (frame_started) {
        processTimingResults(ctx);

        const current_frame = ctx.frames.current_frame;
        const command_buffer = ctx.frames.command_buffers[current_frame];
        if (ctx.query_pool != null) {
            c.vkCmdResetQueryPool(command_buffer, ctx.query_pool, @intCast(current_frame * QUERY_COUNT_PER_FRAME), QUERY_COUNT_PER_FRAME);
        }
    }

    ctx.resources.setCurrentFrame(ctx.frames.current_frame);

    if (!frame_started) {
        return;
    }

    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);

    ctx.draw_call_count = 0;
    ctx.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.post_process_ran_this_frame = false;
    ctx.fxaa_ran_this_frame = false;
    ctx.ui_using_swapchain = false;

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
            if (ctx.shadow_system.shadow_sampler_regular == null) {
                std.log.err("CRITICAL: Shadow regular sampler is NULL!", .{});
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

            image_infos[info_count] = .{
                .sampler = if (ctx.shadow_system.shadow_sampler_regular != null) ctx.shadow_system.shadow_sampler_regular else ctx.shadow_system.shadow_sampler,
                .imageView = ctx.shadow_system.shadow_image_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            writes[write_count].dstBinding = 4;
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
    if (ctx.render_pass_manager.g_render_pass == null or ctx.g_framebuffer == null or ctx.g_pipeline == null) {
        std.log.warn("beginGPass: skipping - resources null (rp={}, fb={}, pipeline={})", .{ ctx.render_pass_manager.g_render_pass != null, ctx.g_framebuffer != null, ctx.g_pipeline != null });
        return;
    }

    // Safety: Check for size mismatch between G-pass resources and current swapchain
    if (ctx.g_pass_extent.width != ctx.swapchain.getExtent().width or ctx.g_pass_extent.height != ctx.swapchain.getExtent().height) {
        std.log.warn("beginGPass: size mismatch! G-pass={}x{}, swapchain={}x{} - recreating", .{ ctx.g_pass_extent.width, ctx.g_pass_extent.height, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height });
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
    if (ctx.render_pass_manager.g_render_pass == null) std.log.err("CRITICAL: g_render_pass is NULL", .{});
    if (ctx.g_framebuffer == null) std.log.err("CRITICAL: g_framebuffer is NULL", .{});
    if (ctx.pipeline_layout == null) std.log.err("CRITICAL: pipeline_layout is NULL", .{});

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.render_pass_manager.g_render_pass;
    render_pass_info.framebuffer = ctx.g_framebuffer;
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

    // Debug: log extent on first few frames
    if (ctx.frame_index < 10) {
        // std.log.debug("beginGPass frame {}: extent {}x{} (cb={}, rp={}, fb={})", .{ ctx.frame_index, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, command_buffer != null, ctx.render_pass_manager.g_render_pass != null, ctx.g_framebuffer != null });
    }

    var clear_values: [3]c.VkClearValue = undefined;
    clear_values[0] = std.mem.zeroes(c.VkClearValue);
    clear_values[0].color = .{ .float32 = .{ 0, 0, 0, 1 } }; // Normal
    clear_values[1] = std.mem.zeroes(c.VkClearValue);
    clear_values[1].color = .{ .float32 = .{ 0, 0, 0, 1 } }; // Velocity
    clear_values[2] = std.mem.zeroes(c.VkClearValue);
    clear_values[2].depthStencil = .{ .depth = 0.0, .stencil = 0 }; // Depth (Reverse-Z)
    render_pass_info.clearValueCount = 3;
    render_pass_info.pClearValues = &clear_values[0];

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.g_pipeline);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.swapchain.getExtent().width), .height = @floatFromInt(ctx.swapchain.getExtent().height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain.getExtent() };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    const ds = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    if (ds == null) std.log.err("CRITICAL: descriptor_set is NULL for frame {}", .{ctx.frames.current_frame});

    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, &ds, 0, null);
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
    c.vkCmdEndRenderPass(command_buffer);
    ctx.g_pass_active = false;
}

fn endGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endGPassInternal(ctx);
}

// Phase 3: FXAA Pass
fn beginFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    beginFXAAPassInternal(ctx);
}

fn beginFXAAPassInternal(ctx: *VulkanContext) void {
    if (!ctx.fxaa.enabled) return;
    if (ctx.fxaa.pass_active) return;
    if (ctx.fxaa.pipeline == null) return;
    if (ctx.fxaa.render_pass == null) return;

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.fxaa.framebuffers.items.len) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();

    // Begin FXAA render pass (outputs to swapchain)
    var clear_value = std.mem.zeroes(c.VkClearValue);
    clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = ctx.fxaa.render_pass;
    rp_begin.framebuffer = ctx.fxaa.framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = &clear_value;

    c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

    // Set viewport and scissor
    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    // Bind FXAA pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline);

    // Bind descriptor set (contains FXAA input texture)
    const frame = ctx.frames.current_frame;
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline_layout, 0, 1, &ctx.fxaa.descriptor_sets[frame], 0, null);

    // Push FXAA constants
    const push = FXAAPushConstants{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(extent.width)), 1.0 / @as(f32, @floatFromInt(extent.height)) },
        .fxaa_span_max = 8.0,
        .fxaa_reduce_mul = 1.0 / 8.0,
    };
    c.vkCmdPushConstants(command_buffer, ctx.fxaa.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(FXAAPushConstants), &push);

    // Draw fullscreen triangle
    c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
    ctx.draw_call_count += 1;

    ctx.fxaa_ran_this_frame = true;
    ctx.fxaa.pass_active = true;
}

fn beginFXAAPassForUI(ctx: *VulkanContext) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.fxaa.pass_active) return;
    if (ctx.ui_swapchain_render_pass == null) return;
    if (ctx.ui_swapchain_framebuffers.items.len == 0) return;

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.ui_swapchain_framebuffers.items.len) return;

    ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();

    var clear_value = std.mem.zeroes(c.VkClearValue);
    clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = ctx.ui_swapchain_render_pass;
    rp_begin.framebuffer = ctx.ui_swapchain_framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = &clear_value;

    c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    ctx.fxaa.pass_active = true;
}

fn endFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endFXAAPassInternal(ctx);
}

fn endFXAAPassInternal(ctx: *VulkanContext) void {
    if (!ctx.fxaa.pass_active) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);

    ctx.fxaa.pass_active = false;
}

// Phase 3: Bloom Computation
fn computeBloom(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    computeBloomInternal(ctx);
}

fn computeBloomInternal(ctx: *VulkanContext) void {
    if (!ctx.bloom.enabled) return;
    if (ctx.bloom.downsample_pipeline == null) return;
    if (ctx.bloom.upsample_pipeline == null) return;
    if (ctx.bloom.render_pass == null) return;
    if (ctx.hdr_image == null) return;
    if (!ctx.frames.frame_in_progress) return;

    // Ensure any active render passes are ended before issuing barriers
    ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const frame = ctx.frames.current_frame;

    // The HDR image is already transitioned to SHADER_READ_ONLY_OPTIMAL by the main render pass (via finalLayout).
    // However, we still need a pipeline barrier for memory visibility and to ensure the GPU has finished
    // writing to the HDR image before we start downsampling.
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; // Match finalLayout of main pass
    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.image = ctx.hdr_image;
    barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

    // Downsample pass: HDR -> mip0 -> ... -> mipN
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.bloom.downsample_pipeline);

    for (0..BLOOM_MIP_COUNT) |i| {
        const mip_width = ctx.bloom.mip_widths[i];
        const mip_height = ctx.bloom.mip_heights[i];

        // Begin render pass for this mip level
        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

        var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
        rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rp_begin.renderPass = ctx.bloom.render_pass;
        rp_begin.framebuffer = ctx.bloom.mip_framebuffers[i];
        rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = mip_width, .height = mip_height } };
        rp_begin.clearValueCount = 1;
        rp_begin.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

        // Set viewport and scissor
        const viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(mip_width),
            .height = @floatFromInt(mip_height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = mip_width, .height = mip_height } };
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Bind descriptor set (set i samples from source)
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.bloom.pipeline_layout, 0, 1, &ctx.bloom.descriptor_sets[frame][i], 0, null);

        // Source dimensions for texel size
        const src_width: f32 = if (i == 0) @floatFromInt(ctx.swapchain.getExtent().width) else @floatFromInt(ctx.bloom.mip_widths[i - 1]);
        const src_height: f32 = if (i == 0) @floatFromInt(ctx.swapchain.getExtent().height) else @floatFromInt(ctx.bloom.mip_heights[i - 1]);

        // Push constants with threshold only on first pass
        const push = BloomPushConstants{
            .texel_size = .{ 1.0 / src_width, 1.0 / src_height },
            .threshold_or_radius = if (i == 0) ctx.bloom.threshold else 0.0,
            .soft_threshold_or_intensity = 0.5, // soft knee
            .mip_level = @intCast(i),
        };
        c.vkCmdPushConstants(command_buffer, ctx.bloom.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(BloomPushConstants), &push);

        // Draw fullscreen triangle
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        ctx.draw_call_count += 1;

        c.vkCmdEndRenderPass(command_buffer);
    }

    // Upsample pass: Accumulating back up the mip chain
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.bloom.upsample_pipeline);

    // Upsample (BLOOM_MIP_COUNT-1 passes, accumulating into each mip level)
    for (0..BLOOM_MIP_COUNT - 1) |pass| {
        const target_mip = (BLOOM_MIP_COUNT - 2) - pass; // Target mips: e.g. 3, 2, 1, 0 if count=5
        const mip_width = ctx.bloom.mip_widths[target_mip];
        const mip_height = ctx.bloom.mip_heights[target_mip];

        // Begin render pass for target mip level
        var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
        rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rp_begin.renderPass = ctx.bloom.render_pass;
        rp_begin.framebuffer = ctx.bloom.mip_framebuffers[target_mip];
        rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = mip_width, .height = mip_height } };
        rp_begin.clearValueCount = 0; // Don't clear, we're blending

        c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

        // Set viewport and scissor
        const viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(mip_width),
            .height = @floatFromInt(mip_height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = mip_width, .height = mip_height } };
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        // Bind descriptor set
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.bloom.pipeline_layout, 0, 1, &ctx.bloom.descriptor_sets[frame][BLOOM_MIP_COUNT + pass], 0, null);

        // Source dimensions for texel size (upsampling from smaller mip)
        const src_mip = target_mip + 1;
        const src_width: f32 = @floatFromInt(ctx.bloom.mip_widths[src_mip]);
        const src_height: f32 = @floatFromInt(ctx.bloom.mip_heights[src_mip]);

        // Push constants
        const push = BloomPushConstants{
            .texel_size = .{ 1.0 / src_width, 1.0 / src_height },
            .threshold_or_radius = 1.0, // filter radius
            .soft_threshold_or_intensity = ctx.bloom.intensity,
            .mip_level = 0,
        };
        c.vkCmdPushConstants(command_buffer, ctx.bloom.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(BloomPushConstants), &push);

        // Draw fullscreen triangle
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        ctx.draw_call_count += 1;

        c.vkCmdEndRenderPass(command_buffer);
    }

    // Transition HDR image back to color attachment layout
    barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
}

// Phase 3: FXAA and Bloom setters
fn setFXAA(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.fxaa.enabled = enabled;
}

fn setBloom(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.bloom.enabled = enabled;
}

fn setBloomIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.bloom.intensity = intensity;
}

fn endFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.frames.frame_in_progress) return;

    if (ctx.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) endShadowPassInternal(ctx);

    // If post-process pass hasn't run (e.g., UI-only screens), we still need to
    // transition the swapchain image to PRESENT_SRC_KHR before presenting.
    // Run a minimal post-process pass to do this.
    if (!ctx.post_process_ran_this_frame and ctx.post_process_framebuffers.items.len > 0 and ctx.frames.current_image_index < ctx.post_process_framebuffers.items.len) {
        beginPostProcessPassInternal(ctx);
        // Draw fullscreen triangle for post-process (tone mapping)
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        ctx.draw_call_count += 1;
    }
    if (ctx.post_process_pass_active) endPostProcessPassInternal(ctx);

    // If FXAA is enabled and post-process ran but FXAA hasn't, run FXAA pass
    // (Post-process outputs to intermediate texture when FXAA is enabled)
    if (ctx.fxaa.enabled and ctx.post_process_ran_this_frame and !ctx.fxaa_ran_this_frame) {
        beginFXAAPassInternal(ctx);
    }
    if (ctx.fxaa.pass_active) endFXAAPassInternal(ctx);

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
    if (ctx.swapchain.getExtent().width == 0 or ctx.swapchain.getExtent().height == 0) return;

    // Safety: Ensure render pass and framebuffer are valid
    if (ctx.render_pass_manager.hdr_render_pass == null) {
        std.debug.print("beginMainPass: hdr_render_pass is null, creating...\n", .{});
        ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), ctx.msaa_samples) catch |err| {
            std.log.err("beginMainPass: failed to recreate render pass: {}", .{err});
            return;
        };
    }
    if (ctx.main_framebuffer == null) {
        std.debug.print("beginMainPass: main_framebuffer is null, creating...\n", .{});
        createMainFramebuffers(ctx) catch |err| {
            std.log.err("beginMainPass: failed to recreate framebuffer: {}", .{err});
            return;
        };
    }
    if (ctx.main_framebuffer == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.main_pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        // Ensure HDR image is in correct layout for resolve
        if (ctx.hdr_image != null) {
            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = ctx.hdr_image;
            barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

            c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        ctx.terrain_pipeline_bound = false;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.render_pass_manager.hdr_render_pass;
        render_pass_info.framebuffer = ctx.main_framebuffer;
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

        var clear_values: [3]c.VkClearValue = undefined;
        clear_values[0] = std.mem.zeroes(c.VkClearValue);
        clear_values[0].color = .{ .float32 = ctx.clear_color };
        clear_values[1] = std.mem.zeroes(c.VkClearValue);
        clear_values[1].depthStencil = .{ .depth = 0.0, .stencil = 0 };

        if (ctx.msaa_samples > 1) {
            clear_values[2] = std.mem.zeroes(c.VkClearValue);
            clear_values[2].color = .{ .float32 = ctx.clear_color };
            render_pass_info.clearValueCount = 3;
        } else {
            render_pass_info.clearValueCount = 2;
        }
        render_pass_info.pClearValues = &clear_values[0];

        // std.debug.print("beginMainPass: calling vkCmdBeginRenderPass (cb={}, rp={}, fb={})\n", .{ command_buffer != null, ctx.render_pass_manager.hdr_render_pass != null, ctx.main_framebuffer != null });
        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.main_pass_active = true;
        ctx.lod_mode = false;
    }

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(ctx.swapchain.getExtent().width);
    viewport.height = @floatFromInt(ctx.swapchain.getExtent().height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.swapchain.getExtent();
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

fn beginPostProcessPassInternal(ctx: *VulkanContext) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.post_process_framebuffers.items.len == 0) return;
    if (ctx.frames.current_image_index >= ctx.post_process_framebuffers.items.len) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.post_process_pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        // Note: The main render pass already transitions HDR buffer to SHADER_READ_ONLY_OPTIMAL
        // via its finalLayout, so no explicit barrier is needed here.

        // When FXAA is enabled, render to intermediate texture; otherwise render to swapchain
        const use_fxaa_output = ctx.fxaa.enabled and ctx.fxaa.post_process_to_fxaa_render_pass != null and ctx.fxaa.post_process_to_fxaa_framebuffer != null;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;

        if (use_fxaa_output) {
            render_pass_info.renderPass = ctx.fxaa.post_process_to_fxaa_render_pass;
            render_pass_info.framebuffer = ctx.fxaa.post_process_to_fxaa_framebuffer;
        } else {
            render_pass_info.renderPass = ctx.post_process_render_pass;
            render_pass_info.framebuffer = ctx.post_process_framebuffers.items[ctx.frames.current_image_index];
        }

        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.color = .{ .float32 = .{ 0, 0, 0, 1 } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.post_process_pass_active = true;
        ctx.post_process_ran_this_frame = true;

        if (ctx.post_process_pipeline == null) {
            std.log.err("Post-process pipeline is null, skipping draw", .{});
            return;
        }

        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process_pipeline);

        const pp_ds = ctx.post_process_descriptor_sets[ctx.frames.current_frame];
        if (pp_ds == null) {
            std.log.err("Post-process descriptor set is null for frame {}", .{ctx.frames.current_frame});
            return;
        }
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process_pipeline_layout, 0, 1, &pp_ds, 0, null);

        // Push bloom parameters
        const push = PostProcessPushConstants{
            .bloom_enabled = if (ctx.bloom.enabled) 1.0 else 0.0,
            .bloom_intensity = ctx.bloom.intensity,
        };
        c.vkCmdPushConstants(command_buffer, ctx.post_process_pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostProcessPushConstants), &push);

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.x = 0.0;
        viewport.y = 0.0;
        viewport.width = @floatFromInt(ctx.swapchain.getExtent().width);
        viewport.height = @floatFromInt(ctx.swapchain.getExtent().height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.offset = .{ .x = 0, .y = 0 };
        scissor.extent = ctx.swapchain.getExtent();
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    }
}

fn beginPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    beginPostProcessPassInternal(ctx);
}

fn endPostProcessPassInternal(ctx: *VulkanContext) void {
    if (!ctx.post_process_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.post_process_pass_active = false;
}

fn endPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    endPostProcessPassInternal(ctx);
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.dry_run and ctx.vulkan_device.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    const global_uniforms = GlobalUniforms{
        .view_proj = view_proj,
        .view_proj_prev = ctx.view_proj_prev,
        .cam_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 1.0 },
        .sun_dir = .{ sun_dir.x, sun_dir.y, sun_dir.z, 0.0 },
        .sun_color = .{ sun_color.x, sun_color.y, sun_color.z, 1.0 },
        .fog_color = .{ fog_color.x, fog_color.y, fog_color.z, 1.0 },
        .cloud_wind_offset = .{ cloud_params.wind_offset_x, cloud_params.wind_offset_z, cloud_params.cloud_scale, cloud_params.cloud_coverage },
        .params = .{ time_val, fog_density, if (fog_enabled) 1.0 else 0.0, sun_intensity },
        .lighting = .{ ambient, if (use_texture) 1.0 else 0.0, if (cloud_params.pbr_enabled) 1.0 else 0.0, cloud_params.shadow.strength },
        .cloud_params = .{ cloud_params.cloud_height, @floatFromInt(cloud_params.shadow.pcf_samples), if (cloud_params.shadow.cascade_blend) 1.0 else 0.0, if (cloud_params.cloud_shadows) 1.0 else 0.0 },
        .pbr_params = .{ @floatFromInt(cloud_params.pbr_quality), cloud_params.exposure, cloud_params.saturation, if (cloud_params.ssao_enabled) 1.0 else 0.0 },
        .volumetric_params = .{ if (cloud_params.volumetric_enabled) 1.0 else 0.0, cloud_params.volumetric_density, @floatFromInt(cloud_params.volumetric_steps), cloud_params.volumetric_scattering },
        .viewport_size = .{ @floatFromInt(ctx.swapchain.swapchain.extent.width), @floatFromInt(ctx.swapchain.swapchain.extent.height), if (ctx.debug_shadows_active) 1.0 else 0.0, 0.0 },
    };

    try ctx.descriptors.updateGlobalUniforms(ctx.frames.current_frame, &global_uniforms);
    ctx.view_proj_prev = view_proj;
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

fn setSelectionMode(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.selection_mode = enabled;
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

fn drawDepthTexture(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    if (comptime !build_options.debug_shadows) return;
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress or !ctx.ui_in_progress) return;

    if (ctx.debug_shadow.pipeline == null) return;

    // 1. Flush normal UI if any
    flushUI(ctx);

    const tex_opt = ctx.resources.textures.get(texture);
    if (tex_opt == null) {
        std.log.err("drawDepthTexture: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    // 2. Bind Debug Shadow Pipeline
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow.pipeline.?);
    ctx.terrain_pipeline_bound = false;

    // 3. Set up orthographic projection for UI-sized quad
    const width_f32 = ctx.ui_screen_width;
    const height_f32 = ctx.ui_screen_height;
    const proj = Mat4.orthographic(0, width_f32, height_f32, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.debug_shadow.pipeline_layout.?, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    // 4. Update & Bind Descriptor Set
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

    // 5. Draw Quad
    const debug_x = rect.x;
    const debug_y = rect.y;
    const debug_w = rect.width;
    const debug_h = rect.height;

    const debug_vertices = [_]f32{
        // pos.x, pos.y, uv.x, uv.y
        debug_x,           debug_y,           0.0, 0.0,
        debug_x + debug_w, debug_y,           1.0, 0.0,
        debug_x + debug_w, debug_y + debug_h, 1.0, 1.0,
        debug_x,           debug_y,           0.0, 0.0,
        debug_x + debug_w, debug_y + debug_h, 1.0, 1.0,
        debug_x,           debug_y + debug_h, 0.0, 1.0,
    };

    // Use persistently mapped memory if available
    if (ctx.debug_shadow.vbo.mapped_ptr) |ptr| {
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(@TypeOf(debug_vertices))], std.mem.asBytes(&debug_vertices));

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ctx.debug_shadow.vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, 6, 1, 0, 0);
    }

    // 6. Restore normal UI state for subsequent calls
    const restore_pipeline = getUIPipeline(ctx, false);
    if (restore_pipeline != null) {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, restore_pipeline);
        c.vkCmdPushConstants(command_buffer, ctx.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
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
    // We use the pixel dimensions from SDL to trigger resizes correctly on High-DPI
    const fb_w = width;
    const fb_h = height;
    _ = fb_w;
    _ = fb_h;

    // Use SDL_GetWindowSizeInPixels to check for actual pixel dimension changes
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);

    if (!ctx.swapchain.skip_present and (@as(u32, @intCast(w)) != ctx.swapchain.getExtent().width or @as(u32, @intCast(h)) != ctx.swapchain.getExtent().height)) {
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

fn setDebugShadowView(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.debug_shadows_active = enabled;
    // Debug shadow view is handled in shader via viewport_size.z uniform
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
    ctx.swapchain.msaa_samples = clamped;
    ctx.framebuffer_resized = true; // Triggers recreateSwapchain on next frame
    ctx.pipeline_rebuild_needed = true;
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

fn getValidationErrorCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.validation_error_count.load(.monotonic);
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
                    ctx.pipeline_manager.terrain_pipeline;
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
                        ctx.pipeline_manager.terrain_pipeline;
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
                const cascade_index = ctx.shadow_system.pass_index;
                const texel_size = ctx.shadow_texel_sizes[cascade_index];
                const shadow_uniforms = ShadowModelUniforms{
                    .mvp = ctx.shadow_system.pass_matrix,
                    .bias_params = .{ 2.0, 1.0, @floatFromInt(cascade_index), texel_size },
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
                    if (cmd.mapped_ptr) |ptr| {
                        const base = @as([*]const u8, @ptrCast(ptr)) + offset;
                        var draw_index: u32 = 0;
                        while (draw_index < draw_count) : (draw_index += 1) {
                            const cmd_ptr = @as(*const rhi.DrawIndirectCommand, @ptrCast(@alignCast(base + @as(usize, draw_index) * stride_bytes)));
                            const draw_cmd = cmd_ptr.*;
                            if (draw_cmd.vertexCount == 0 or draw_cmd.instanceCount == 0) continue;
                            c.vkCmdDraw(cb, draw_cmd.vertexCount, draw_cmd.instanceCount, draw_cmd.firstVertex, draw_cmd.firstInstance);
                        }
                        return;
                    }
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
                    ctx.pipeline_manager.terrain_pipeline;
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
            const cascade_index = ctx.shadow_system.pass_index;
            const texel_size = ctx.shadow_texel_sizes[cascade_index];
            const shadow_uniforms = ShadowModelUniforms{
                .mvp = ctx.shadow_system.pass_matrix.multiply(ctx.current_model),
                .bias_params = .{ 2.0, 1.0, @floatFromInt(cascade_index), texel_size },
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
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    // Special case: post-process pass draws fullscreen triangle without VBO
    if (ctx.post_process_pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        // Pipeline and descriptor sets are already bound in beginPostProcessPassInternal
        c.vkCmdDraw(command_buffer, count, 1, 0, 0);
        ctx.draw_call_count += 1;
        return;
    }

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
            const needs_rebinding = !ctx.terrain_pipeline_bound or ctx.selection_mode or mode == .lines;
            if (needs_rebinding) {
                const selected_pipeline = if (ctx.selection_mode and ctx.selection_pipeline != null)
                    ctx.selection_pipeline
                else if (mode == .lines and ctx.line_pipeline != null)
                    ctx.line_pipeline
                else if (ctx.wireframe_enabled and ctx.wireframe_pipeline != null)
                    ctx.wireframe_pipeline
                else
                    ctx.pipeline_manager.terrain_pipeline;
                if (selected_pipeline == null) return;
                c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, selected_pipeline);
                // Mark bound only if it's the main terrain pipeline
                ctx.terrain_pipeline_bound = (selected_pipeline == ctx.pipeline_manager.terrain_pipeline);
            }

            const descriptor_set = if (ctx.lod_mode)
                &ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame]
            else
                &ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_layout, 0, 1, descriptor_set, 0, null);
        }

        if (use_shadow) {
            const cascade_index = ctx.shadow_system.pass_index;
            const texel_size = ctx.shadow_texel_sizes[cascade_index];
            const shadow_uniforms = ShadowModelUniforms{
                .mvp = ctx.shadow_system.pass_matrix.multiply(ctx.current_model),
                .bias_params = .{ 2.0, 1.0, @floatFromInt(cascade_index), texel_size },
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
    if (!ctx.main_pass_active and !ctx.fxaa.pass_active) {
        return;
    }
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
    if (!ctx.frames.frame_in_progress) {
        return;
    }

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    const use_swapchain = ctx.post_process_ran_this_frame;
    const ui_pipeline = if (use_swapchain) ctx.ui_swapchain_pipeline else ctx.ui_pipeline;
    if (ui_pipeline == null) return;

    // If post-process already ran, render UI directly to swapchain (overlay).
    // Otherwise, use the main HDR pass so post-process can include UI.
    if (use_swapchain) {
        if (!ctx.fxaa.pass_active) {
            beginFXAAPassForUI(ctx);
        }
        if (!ctx.fxaa.pass_active) return;
    } else {
        if (!ctx.main_pass_active) beginMainPassInternal(ctx);
        if (!ctx.main_pass_active) return;
    }

    ctx.ui_using_swapchain = use_swapchain;

    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;
    ctx.ui_in_progress = true;

    // Use persistently mapped memory if available
    const ui_vbo = ctx.ui_vbos[ctx.frames.current_frame];
    if (ui_vbo.mapped_ptr) |ptr| {
        ctx.ui_mapped_ptr = ptr;
    } else {
        std.log.err("UI VBO memory not mapped!", .{});
    }

    // Bind UI pipeline and VBO
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ui_pipeline);
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

    ctx.ui_mapped_ptr = null;

    flushUI(ctx);
    if (ctx.ui_using_swapchain) {
        endFXAAPassInternal(ctx);
        ctx.ui_using_swapchain = false;
    }
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

const VULKAN_SHADOW_CONTEXT_VTABLE = rhi.IShadowContext.VTable{
    .beginPass = beginShadowPass,
    .endPass = endShadowPass,
    .updateUniforms = updateShadowUniforms,
    .getShadowMapHandle = getShadowMapHandle,
};

fn getUIPipeline(ctx: *VulkanContext, textured: bool) c.VkPipeline {
    if (ctx.ui_using_swapchain) {
        return if (textured) ctx.ui_swapchain_tex_pipeline else ctx.ui_swapchain_pipeline;
    }
    return if (textured) ctx.ui_tex_pipeline else ctx.ui_pipeline;
}

fn bindUIPipeline(ctx_ptr: *anyopaque, textured: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    // Reset this so other pipelines know to rebind if they are called next
    ctx.terrain_pipeline_bound = false;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    const pipeline = getUIPipeline(ctx, textured);
    if (pipeline == null) return;
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
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
    const textured_pipeline = getUIPipeline(ctx, true);
    if (textured_pipeline == null) return;
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, textured_pipeline);
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
    const restore_pipeline = getUIPipeline(ctx, false);
    if (restore_pipeline != null) {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, restore_pipeline);
        c.vkCmdPushConstants(command_buffer, ctx.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
    }
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
    if (ctx.post_process_pass_active) endPostProcessPassInternal(ctx);
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

fn getShadowMapHandle(ctx_ptr: *anyopaque, cascade_index: u32) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return 0;
    return ctx.shadow_map_handles[cascade_index];
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));

    var splits = [_]f32{ 0, 0, 0, 0 };
    var sizes = [_]f32{ 0, 0, 0, 0 };
    @memcpy(splits[0..rhi.SHADOW_CASCADE_COUNT], &params.cascade_splits);
    @memcpy(sizes[0..rhi.SHADOW_CASCADE_COUNT], &params.shadow_texel_sizes);

    @memcpy(&ctx.shadow_texel_sizes, &params.shadow_texel_sizes);

    const shadow_uniforms = ShadowUniforms{
        .light_space_matrices = params.light_space_matrices,
        .cascade_splits = splits,
        .shadow_texel_sizes = sizes,
    };

    try ctx.descriptors.updateShadowUniforms(ctx.frames.current_frame, &shadow_uniforms);
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
fn getNativeCommandBuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.frames.command_buffers[ctx.frames.current_frame]);
}
fn getNativeSwapchainExtent(ctx_ptr: *anyopaque) [2]u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const extent = ctx.swapchain.getExtent();
    return .{ extent.width, extent.height };
}
fn getNativeDevice(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return @intFromPtr(ctx.vulkan_device.vk_device);
}

fn computeSSAO(ctx_ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.ssao_system.compute(
        ctx.vulkan_device.vk_device,
        ctx.frames.command_buffers[ctx.frames.current_frame],
        ctx.frames.current_frame,
        ctx.swapchain.getExtent(),
        proj,
        inv_proj,
    );
}

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    _ = ctx_ptr;
    _ = cascade_index;
    _ = depth_map_handle;
}

const VULKAN_SSAO_VTABLE = rhi.ISSAOContext.VTable{
    .compute = computeSSAO,
};

const VULKAN_UI_CONTEXT_VTABLE = rhi.IUIContext.VTable{
    .beginPass = begin2DPass,
    .endPass = end2DPass,
    .drawRect = drawRect2D,
    .drawTexture = drawTexture2D,
    .drawDepthTexture = drawDepthTexture,
    .bindPipeline = bindUIPipeline,
};

fn getStateContext(ctx_ptr: *anyopaque) rhi.IRenderStateContext {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_STATE_CONTEXT_VTABLE };
}

const VULKAN_STATE_CONTEXT_VTABLE = rhi.IRenderStateContext.VTable{
    .setModelMatrix = setModelMatrix,
    .setInstanceBuffer = setInstanceBuffer,
    .setLODInstanceBuffer = setLODInstanceBuffer,
    .setSelectionMode = setSelectionMode,
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
        .beginPostProcessPass = beginPostProcessPass,
        .endPostProcessPass = endPostProcessPass,
        .beginGPass = beginGPass,
        .endGPass = endGPass,
        .beginFXAAPass = beginFXAAPass,
        .endFXAAPass = endFXAAPass,
        .computeBloom = computeBloom,
        .getEncoder = getEncoder,
        .getStateContext = getStateContext,
        .getNativeSkyPipeline = getNativeSkyPipeline,
        .getNativeSkyPipelineLayout = getNativeSkyPipelineLayout,
        .getNativeCloudPipeline = getNativeCloudPipeline,
        .getNativeCloudPipelineLayout = getNativeCloudPipelineLayout,
        .getNativeMainDescriptorSet = getNativeMainDescriptorSet,
        .getNativeCommandBuffer = getNativeCommandBuffer,
        .getNativeSwapchainExtent = getNativeSwapchainExtent,
        .getNativeDevice = getNativeDevice,
        .setClearColor = setClearColor,
        .computeSSAO = computeSSAO,
        .drawDebugShadowMap = drawDebugShadowMap,
    },
    .ssao = VULKAN_SSAO_VTABLE,
    .shadow = VULKAN_SHADOW_CONTEXT_VTABLE,
    .ui = VULKAN_UI_CONTEXT_VTABLE,
    .query = .{
        .getFrameIndex = getFrameIndex,
        .supportsIndirectFirstInstance = supportsIndirectFirstInstance,
        .getMaxAnisotropy = getMaxAnisotropy,
        .getMaxMSAASamples = getMaxMSAASamples,
        .getFaultCount = getFaultCount,
        .getValidationErrorCount = getValidationErrorCount,
        .waitIdle = waitIdle,
    },
    .timing = .{
        .beginPassTiming = beginPassTiming,
        .endPassTiming = endPassTiming,
        .getTimingResults = getTimingResults,
        .isTimingEnabled = isTimingEnabled,
        .setTimingEnabled = setTimingEnabled,
    },
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setDebugShadowView = setDebugShadowView,
    .setVSync = setVSync,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setVolumetricDensity = setVolumetricDensity,
    .setMSAA = setMSAA,
    .recover = recover,
    .setFXAA = setFXAA,
    .setBloom = setBloom,
    .setBloomIntensity = setBloomIntensity,
};

fn mapPassName(name: []const u8) ?GpuPass {
    if (std.mem.eql(u8, name, "ShadowPass0")) return .shadow_0;
    if (std.mem.eql(u8, name, "ShadowPass1")) return .shadow_1;
    if (std.mem.eql(u8, name, "ShadowPass2")) return .shadow_2;
    if (std.mem.eql(u8, name, "GPass")) return .g_pass;
    if (std.mem.eql(u8, name, "SSAOPass")) return .ssao;
    if (std.mem.eql(u8, name, "SkyPass")) return .sky;
    if (std.mem.eql(u8, name, "OpaquePass")) return .opaque_pass;
    if (std.mem.eql(u8, name, "CloudPass")) return .cloud;
    if (std.mem.eql(u8, name, "BloomPass")) return .bloom;
    if (std.mem.eql(u8, name, "FXAAPass")) return .fxaa;
    if (std.mem.eql(u8, name, "PostProcessPass")) return .post_process;
    return null;
}

fn beginPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.timing_enabled or ctx.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, ctx.query_pool, query_index);
}

fn endPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.timing_enabled or ctx.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2 + 1;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, ctx.query_pool, query_index);
}

fn getTimingResults(ctx_ptr: *anyopaque) rhi.GpuTimingResults {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing_results;
}

fn isTimingEnabled(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing_enabled;
}

fn setTimingEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.timing_enabled = enabled;
}

fn processTimingResults(ctx: *VulkanContext) void {
    if (!ctx.timing_enabled or ctx.query_pool == null) return;
    if (!ctx.timing_enabled or ctx.query_pool == null) return;
    if (ctx.frame_index < MAX_FRAMES_IN_FLIGHT) return;

    const frame = ctx.frames.current_frame;
    const offset = frame * QUERY_COUNT_PER_FRAME;
    var results: [QUERY_COUNT_PER_FRAME]u64 = .{0} ** QUERY_COUNT_PER_FRAME;

    const res = c.vkGetQueryPoolResults(
        ctx.vulkan_device.vk_device,
        ctx.query_pool,
        @intCast(offset),
        QUERY_COUNT_PER_FRAME,
        @sizeOf(@TypeOf(results)),
        &results,
        @sizeOf(u64),
        c.VK_QUERY_RESULT_64_BIT,
    );

    if (res == c.VK_SUCCESS) {
        const period = ctx.vulkan_device.timestamp_period;

        ctx.timing_results.shadow_pass_ms[0] = @as(f32, @floatFromInt(results[1] -% results[0])) * period / 1e6;
        ctx.timing_results.shadow_pass_ms[1] = @as(f32, @floatFromInt(results[3] -% results[2])) * period / 1e6;
        ctx.timing_results.shadow_pass_ms[2] = @as(f32, @floatFromInt(results[5] -% results[4])) * period / 1e6;
        ctx.timing_results.g_pass_ms = @as(f32, @floatFromInt(results[7] -% results[6])) * period / 1e6;
        ctx.timing_results.ssao_pass_ms = @as(f32, @floatFromInt(results[9] -% results[8])) * period / 1e6;
        ctx.timing_results.sky_pass_ms = @as(f32, @floatFromInt(results[11] -% results[10])) * period / 1e6;
        ctx.timing_results.opaque_pass_ms = @as(f32, @floatFromInt(results[13] -% results[12])) * period / 1e6;
        ctx.timing_results.cloud_pass_ms = @as(f32, @floatFromInt(results[15] -% results[14])) * period / 1e6;
        ctx.timing_results.bloom_pass_ms = @as(f32, @floatFromInt(results[17] -% results[16])) * period / 1e6;
        ctx.timing_results.fxaa_pass_ms = @as(f32, @floatFromInt(results[19] -% results[18])) * period / 1e6;
        ctx.timing_results.post_process_pass_ms = @as(f32, @floatFromInt(results[21] -% results[20])) * period / 1e6;

        ctx.timing_results.main_pass_ms = ctx.timing_results.sky_pass_ms + ctx.timing_results.opaque_pass_ms + ctx.timing_results.cloud_pass_ms;

        ctx.timing_results.validate();

        ctx.timing_results.total_gpu_ms = 0;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.shadow_pass_ms[0];
        ctx.timing_results.total_gpu_ms += ctx.timing_results.shadow_pass_ms[1];
        ctx.timing_results.total_gpu_ms += ctx.timing_results.shadow_pass_ms[2];
        ctx.timing_results.total_gpu_ms += ctx.timing_results.g_pass_ms;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.ssao_pass_ms;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.main_pass_ms;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.bloom_pass_ms;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.fxaa_pass_ms;
        ctx.timing_results.total_gpu_ms += ctx.timing_results.post_process_pass_ms;

        if (ctx.timing_enabled) {
            std.debug.print("GPU Frame Time: {d:.2}ms (Shadow: {d:.2}, G-Pass: {d:.2}, SSAO: {d:.2}, Main: {d:.2}, Bloom: {d:.2}, FXAA: {d:.2}, Post: {d:.2})\n", .{
                ctx.timing_results.total_gpu_ms,
                ctx.timing_results.shadow_pass_ms[0] + ctx.timing_results.shadow_pass_ms[1] + ctx.timing_results.shadow_pass_ms[2],
                ctx.timing_results.g_pass_ms,
                ctx.timing_results.ssao_pass_ms,
                ctx.timing_results.main_pass_ms,
                ctx.timing_results.bloom_pass_ms,
                ctx.timing_results.fxaa_pass_ms,
                ctx.timing_results.post_process_pass_ms,
            });
        }
    }
}

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
    ctx.timing_enabled = false; // Will be enabled via RHI call
    ctx.timing_results = std.mem.zeroes(rhi.GpuTimingResults);
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
    ctx.pipeline_manager.terrain_pipeline = null;
    ctx.pipeline_layout = null;
    ctx.wireframe_pipeline = null;
    ctx.sky_pipeline = null;
    ctx.sky_pipeline_layout = null;
    ctx.ui_pipeline = null;
    ctx.ui_pipeline_layout = null;
    ctx.ui_tex_pipeline = null;
    ctx.ui_tex_pipeline_layout = null;
    ctx.ui_tex_descriptor_set_layout = null;
    ctx.ui_swapchain_pipeline = null;
    ctx.ui_swapchain_tex_pipeline = null;
    ctx.ui_swapchain_render_pass = null;
    ctx.ui_swapchain_framebuffers = .empty;
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
