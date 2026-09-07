const std = @import("std");
const sync = @import("sync");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const RenderDevice = @import("engine-rhi").render_device.RenderDevice;
const Mat4 = @import("engine-math").Mat4;
const build_options = @import("engine_graphics_options");

const resource_manager_pkg = @import("resource_manager.zig");
const ResourceManager = resource_manager_pkg.ResourceManager;
const VulkanBuffer = resource_manager_pkg.VulkanBuffer;
const FrameManager = @import("frame_manager.zig").FrameManager;
const SwapchainPresenter = @import("swapchain_presenter.zig").SwapchainPresenter;
const DescriptorManager = @import("descriptor_manager.zig").DescriptorManager;
const PipelineManager = @import("pipeline_manager.zig").PipelineManager;
const RenderPassManager = @import("render_pass_manager.zig").RenderPassManager;
const ShadowSystem = @import("engine-shadows").ShadowSystem;
const SSAOSystem = @import("ssao_system.zig").SSAOSystem;
const PostProcessSystem = @import("post_process_system.zig").PostProcessSystem;
const FXAASystem = @import("fxaa_system.zig").FXAASystem;
const BloomSystem = @import("bloom_system.zig").BloomSystem;
const TAASystem = @import("taa_system.zig").TAASystem;
const DepthPyramidSystem = @import("depth_pyramid.zig").DepthPyramidSystem;
const WaterSystem = @import("water_system.zig").WaterSystem;
const VulkanDevice = @import("device.zig").VulkanDevice;
const DynamicResolutionState = @import("dynamic_resolution.zig").DynamicResolutionState;
const rhi_timing = @import("rhi_timing.zig");
const screenshot = @import("screenshot.zig");
const final_composition = @import("final_composition.zig");

const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;

const DebugShadowResources = if (build_options.debug_shadows) struct {
    pipeline: ?c.VkPipeline = null,
    pipeline_layout: ?c.VkPipelineLayout = null,
    descriptor_set_layout: ?c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]?c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    descriptor_pool: [MAX_FRAMES_IN_FLIGHT][8]?c.VkDescriptorSet = .{.{null} ** 8} ** MAX_FRAMES_IN_FLIGHT,
    descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32 = .{0} ** MAX_FRAMES_IN_FLIGHT,
    vbo: VulkanBuffer = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false },
} else struct {};

const GPassResources = struct {
    g_normal_image: c.VkImage = null,
    g_normal_memory: c.VkDeviceMemory = null,
    g_normal_view: c.VkImageView = null,
    g_normal_handle: rhi.TextureHandle = 0,
    g_depth_image: c.VkImage = null,
    g_depth_memory: c.VkDeviceMemory = null,
    g_depth_view: c.VkImageView = null,
    g_depth_handle: rhi.TextureHandle = 0,
    g_depth_sampler: c.VkSampler = null,
    g_pass_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
};

const HDRResources = struct {
    hdr_image: c.VkImage = null,
    hdr_memory: c.VkDeviceMemory = null,
    hdr_view: c.VkImageView = null,
    hdr_handle: rhi.TextureHandle = 0,
    hdr_msaa_image: c.VkImage = null,
    hdr_msaa_memory: c.VkDeviceMemory = null,
    hdr_msaa_view: c.VkImageView = null,
};

const VelocityResources = struct {
    velocity_image: c.VkImage = null,
    velocity_memory: c.VkDeviceMemory = null,
    velocity_view: c.VkImageView = null,
    velocity_handle: rhi.TextureHandle = 0,
    view_proj_prev: Mat4 = Mat4.identity,
};

const UIState = struct {
    ui_tex_descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
    ui_tex_descriptor_pool: [MAX_FRAMES_IN_FLIGHT][64]c.VkDescriptorSet = .{.{null} ** 64} ** MAX_FRAMES_IN_FLIGHT,
    ui_tex_descriptor_next: [MAX_FRAMES_IN_FLIGHT]u32 = .{0} ** MAX_FRAMES_IN_FLIGHT,
    ui_vbos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer = .{VulkanBuffer{}} ** MAX_FRAMES_IN_FLIGHT,
    rml_vbos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer = .{VulkanBuffer{}} ** MAX_FRAMES_IN_FLIGHT,
    rml_ibos: [MAX_FRAMES_IN_FLIGHT]VulkanBuffer = .{VulkanBuffer{}} ** MAX_FRAMES_IN_FLIGHT,
    ui_screen_width: f32 = 0.0,
    ui_screen_height: f32 = 0.0,
    ui_using_swapchain: bool = false,
    /// This is deliberately independent from FXAA: UI overlays may use the
    /// final display target after FXAA has already ended.
    ui_swapchain_pass_active: bool = false,
    /// The first UI pass of an otherwise empty frame explicitly clears the
    /// display target; subsequent UI passes load and overlay it.
    ui_swapchain_clears_output: bool = false,
    ui_in_progress: bool = false,
    ui_vertex_offset: u64 = 0,
    ui_active_textured: bool = false,
    ui_active_texture: rhi.TextureHandle = 0,
    ui_active_tint: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    selection_mode: bool = false,
    ui_flushed_vertex_count: u32 = 0,
    ui_mapped_ptr: ?*anyopaque = null,
    rml_vertex_offset: u64 = 0,
    rml_index_offset: u64 = 0,
    legacy_pipeline_bound: bool = false,
};

const LegacyResources = struct {
    dummy_shadow_image: c.VkImage = null,
    dummy_shadow_memory: c.VkDeviceMemory = null,
    dummy_shadow_view: c.VkImageView = null,
    model_ubo: VulkanBuffer = .{},
    dummy_instance_buffer: VulkanBuffer = .{},
};

const ShadowRuntime = struct {
    shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{0} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_texel_sizes: [rhi.SHADOW_CASCADE_COUNT]f32 = .{0.0} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_resolution: u32,
    pending_shadow_resolution: ?u32 = null,
};

const PostProcessState = struct {
    vignette_enabled: bool = false,
    vignette_intensity: f32 = 0.3,
    film_grain_enabled: bool = false,
    film_grain_intensity: f32 = 0.15,
    color_grading_enabled: bool = false,
    color_grading_intensity: f32 = 1.0,
};

const RenderOptions = struct {
    wireframe_enabled: bool = false,
    textures_enabled: bool = true,
    vsync_enabled: bool = true,
    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
    anisotropic_filtering: u8 = 1,
    msaa_samples: u8 = 1,
    safe_mode: bool = false,
    debug_shadows_active: bool = false,
    shadow_debug_channel: u32 = 0,
};

const DrawState = struct {
    current_texture: rhi.TextureHandle,
    current_normal_texture: rhi.TextureHandle,
    current_roughness_texture: rhi.TextureHandle,
    current_displacement_texture: rhi.TextureHandle,
    current_env_texture: rhi.TextureHandle,
    current_water_reflection_texture: rhi.TextureHandle,
    current_scene_depth_texture: rhi.TextureHandle,
    current_lpv_texture: rhi.TextureHandle,
    current_lpv_texture_g: rhi.TextureHandle,
    current_lpv_texture_b: rhi.TextureHandle,
    dummy_texture: rhi.TextureHandle,
    dummy_texture_3d: rhi.TextureHandle,
    dummy_normal_texture: rhi.TextureHandle,
    dummy_roughness_texture: rhi.TextureHandle,
    bound_texture: rhi.TextureHandle,
    bound_normal_texture: rhi.TextureHandle,
    bound_roughness_texture: rhi.TextureHandle,
    bound_displacement_texture: rhi.TextureHandle,
    bound_env_texture: rhi.TextureHandle,
    bound_water_reflection_texture: rhi.TextureHandle = 0,
    bound_scene_depth_texture: rhi.TextureHandle = 0,
    bound_lpv_texture: rhi.TextureHandle,
    bound_lpv_texture_g: rhi.TextureHandle = 0,
    bound_lpv_texture_b: rhi.TextureHandle = 0,
    bound_ssao_handle: rhi.TextureHandle = 0,
    bound_shadow_views: [rhi.SHADOW_CASCADE_COUNT]c.VkImageView,
    descriptors_dirty: [MAX_FRAMES_IN_FLIGHT]bool,
    terrain_pipeline_bound: bool = false,
    descriptors_updated: bool = false,
    lod_mode: bool = false,
    lod_descriptor_stream: rhi.LODDescriptorStream = .terrain_standard_direct,
    /// False when the selected immutable snapshot could not acquire the current
    /// material revision. LOD setters and draws remain no-ops until another
    /// stream is selected successfully.
    lod_descriptor_stream_valid: bool = false,
    bound_instance_buffer: [MAX_FRAMES_IN_FLIGHT]rhi.BufferHandle = .{ 0, 0 },
    lod_snapshot_bindings: [MAX_FRAMES_IN_FLIGHT]@import("descriptor_manager.zig").LODDescriptorSnapshotBindings = .{ .{}, .{} },
    /// A snapshot is immutable from its first bind until the corresponding
    /// frame slot fence has completed and prepareFrameState reopens it.
    lod_snapshot_seals: [MAX_FRAMES_IN_FLIGHT]@import("descriptor_manager.zig").LODDescriptorSnapshotSeal = .{ .{}, .{} },
    texture_state_revision: u64 = 0,
    pending_instance_buffer: rhi.BufferHandle = 0,
    pending_lod_instance_buffer: rhi.BufferHandle = 0,
    pending_lod_compact_sample_buffer: rhi.BufferHandle = 0,
    pending_lod_compact_instance_buffer: rhi.BufferHandle = 0,
    current_view_proj: Mat4 = Mat4.identity,
    current_model: Mat4 = Mat4.identity,
    current_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    current_mask_radius: f32 = 0.0,
    current_lod_ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

const RuntimeState = struct {
    gpu_fault_detected: bool = false,
    recovering: bool = false,
    memory_type_index: u32,
    framebuffer_resized: bool,
    draw_call_count: u32,
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,
    post_process_ran_this_frame: bool = false,
    fxaa_ran_this_frame: bool = false,
    direct_ui_composed_this_frame: bool = false,
    transfer_barrier_needed: bool = false,
    pipeline_rebuild_needed: bool = false,
    swapchain_recreate_failed: bool = false,
    frame_index: usize,
    image_index: u32,
    clear_color: [4]f32 = .{ 0.07, 0.08, 0.1, 1.0 },
    first_main_pass_draw_logged: bool = false,
    final_composed: final_composition.FinalComposedImage = .{},
};

const TimingState = struct {
    query_pool: c.VkQueryPool = null,
    timing_enabled: bool = true,
    timing_results: rhi.GpuTimingResults = undefined,
    pass_written: [MAX_FRAMES_IN_FLIGHT][rhi_timing.PASS_COUNT]bool = .{.{false} ** rhi_timing.PASS_COUNT} ** MAX_FRAMES_IN_FLIGHT,
};

pub const ComputeBufferResource = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped_ptr: ?*anyopaque = null,
};

pub const ComputePipelineResource = struct {
    pipeline: c.VkPipeline = null,
    layout: c.VkPipelineLayout = null,
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** MAX_FRAMES_IN_FLIGHT,
};

const ComputeResources = struct {
    next_buffer_handle: u32 = 1,
    next_pipeline_handle: u32 = 1,
    buffers: std.AutoHashMapUnmanaged(u32, ComputeBufferResource) = .empty,
    pipelines: std.AutoHashMapUnmanaged(u32, ComputePipelineResource) = .empty,
};

pub const VulkanContext = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    render_device: ?*RenderDevice,

    vulkan_device: VulkanDevice,
    resources: ResourceManager,
    frames: FrameManager,
    swapchain: SwapchainPresenter,
    descriptors: DescriptorManager,

    pipeline_manager: PipelineManager = .{},
    render_pass_manager: RenderPassManager = .{},

    legacy: LegacyResources = .{},
    draw: DrawState,
    options: RenderOptions = .{},
    gpass: GPassResources = .{},

    shadow_system: ShadowSystem,
    ssao_system: SSAOSystem = .{},
    shadow_runtime: ShadowRuntime,
    runtime: RuntimeState,
    mutex: sync.Mutex = .{},

    ui: UIState = .{},
    hdr: HDRResources = .{},
    post_process: PostProcessSystem = .{},
    debug_shadow: DebugShadowResources = .{},
    fxaa: FXAASystem = .{},
    taa: TAASystem = .{},
    bloom: BloomSystem = .{},
    depth_pyramid: DepthPyramidSystem = .{},
    post_process_state: PostProcessState = .{},
    velocity: VelocityResources = .{},
    water_system: WaterSystem = .{},

    timing: TimingState = .{},
    dynamic_resolution: DynamicResolutionState = .{},
    compute_resources: ComputeResources = .{},
    screenshot_capture: screenshot.PendingCapture = .{},
};
