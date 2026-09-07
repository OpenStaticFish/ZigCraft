const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const RenderDevice = @import("engine-rhi").render_device.RenderDevice;
const Mat4 = @import("engine-math").Mat4;
const build_options = @import("engine_graphics_options");
const runtime_env = @import("engine-core").runtime_env;
const resource_manager_pkg = @import("resource_manager.zig");
const VulkanBuffer = resource_manager_pkg.VulkanBuffer;
const TextureResource = resource_manager_pkg.TextureResource;
const ShadowSystem = @import("engine-shadows").ShadowSystem;

const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;

pub fn createRHI(
    comptime VulkanContext: type,
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    render_device: ?*RenderDevice,
    shadow_resolution: u32,
    msaa_samples: u8,
    anisotropic_filtering: u8,
    vtable: *const rhi.RHI.VTable,
) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    errdefer allocator.destroy(ctx);
    @memset(std.mem.asBytes(ctx), 0);

    ctx.allocator = allocator;
    ctx.render_device = render_device;
    ctx.shadow_runtime.shadow_resolution = shadow_resolution;
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
    ctx.runtime.framebuffer_resized = false;

    ctx.runtime.draw_call_count = 0;
    ctx.resources.buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(allocator);
    ctx.resources.next_buffer_handle = 1;
    ctx.resources.textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(allocator);
    ctx.resources.next_texture_handle = 1;
    ctx.draw.current_texture = 0;
    ctx.draw.current_normal_texture = 0;
    ctx.draw.current_roughness_texture = 0;
    ctx.draw.current_displacement_texture = 0;
    ctx.draw.current_env_texture = 0;
    ctx.draw.current_water_reflection_texture = 0;
    ctx.draw.current_scene_depth_texture = 0;
    ctx.draw.current_lpv_texture = 0;
    ctx.draw.current_lpv_texture_g = 0;
    ctx.draw.current_lpv_texture_b = 0;
    ctx.draw.dummy_texture = 0;
    ctx.draw.dummy_texture_3d = 0;
    ctx.draw.dummy_normal_texture = 0;
    ctx.draw.dummy_roughness_texture = 0;
    ctx.mutex = .{};
    ctx.swapchain.swapchain.images = .empty;
    ctx.swapchain.swapchain.image_views = .empty;
    ctx.swapchain.swapchain.framebuffers = .empty;
    ctx.runtime.clear_color = .{ 0.07, 0.08, 0.1, 1.0 };
    ctx.frames.frame_in_progress = false;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.shadow_system.pass_index = 0;
    ctx.ui.ui_in_progress = false;
    ctx.ui.ui_mapped_ptr = null;
    ctx.ui.ui_vertex_offset = 0;
    ctx.runtime.frame_index = 0;
    ctx.timing.timing_enabled = false;
    ctx.timing.timing_results = std.mem.zeroes(rhi.GpuTimingResults);
    ctx.frames.current_frame = 0;
    ctx.frames.current_image_index = 0;

    ctx.draw.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;
    ctx.draw.bound_normal_texture = 0;
    ctx.draw.bound_roughness_texture = 0;
    ctx.draw.bound_displacement_texture = 0;
    ctx.draw.bound_env_texture = 0;
    ctx.draw.bound_water_reflection_texture = 0;
    ctx.draw.bound_scene_depth_texture = 0;
    ctx.draw.bound_lpv_texture = 0;
    ctx.draw.pending_instance_buffer = 0;

    ctx.options.wireframe_enabled = false;
    ctx.options.textures_enabled = true;
    ctx.options.vsync_enabled = true;
    ctx.options.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;

    ctx.options.safe_mode = runtime_env.safeModeEnabled();
    if (ctx.options.safe_mode) {
        log.log.warn("ZIGCRAFT_SAFE_MODE enabled: throttling uploads and forcing GPU idle each frame", .{});
    }

    ctx.frames.command_pool = null;
    ctx.frames.frame_command_pools = [_]c.VkCommandPool{null} ** rhi.MAX_FRAMES_IN_FLIGHT;
    ctx.swapchain.swapchain.main_render_pass = null;
    ctx.swapchain.swapchain.handle = null;
    ctx.swapchain.swapchain.depth_image = null;
    ctx.swapchain.swapchain.depth_image_view = null;
    ctx.swapchain.swapchain.depth_image_memory = null;
    ctx.swapchain.swapchain.msaa_color_image = null;
    ctx.swapchain.swapchain.msaa_color_view = null;
    ctx.swapchain.swapchain.msaa_color_memory = null;
    ctx.pipeline_manager.terrain_pipeline = null;
    ctx.pipeline_manager.pipeline_layout = null;
    ctx.pipeline_manager.wireframe_pipeline = null;
    ctx.pipeline_manager.sky_pipeline = null;
    ctx.pipeline_manager.sky_pipeline_layout = null;
    ctx.pipeline_manager.ui_pipeline = null;
    ctx.pipeline_manager.ui_pipeline_layout = null;
    ctx.pipeline_manager.ui_tex_pipeline = null;
    ctx.pipeline_manager.ui_tex_pipeline_layout = null;
    ctx.pipeline_manager.rml_ui_pipeline = null;
    ctx.pipeline_manager.rml_ui_tex_pipeline = null;
    ctx.pipeline_manager.ui_swapchain_pipeline = null;
    ctx.pipeline_manager.ui_swapchain_tex_pipeline = null;
    ctx.pipeline_manager.rml_ui_swapchain_pipeline = null;
    ctx.pipeline_manager.rml_ui_swapchain_tex_pipeline = null;
    ctx.render_pass_manager.ui_swapchain_framebuffers = .empty;
    if (comptime build_options.debug_shadows) {
        ctx.debug_shadow.pipeline = null;
        ctx.debug_shadow.pipeline_layout = null;
        ctx.debug_shadow.descriptor_set_layout = null;
        ctx.debug_shadow.vbo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.debug_shadow.descriptor_next = .{ 0, 0 };
    }
    ctx.post_process = .{};
    ctx.descriptors.descriptor_pool = null;
    ctx.descriptors.descriptor_set_layout = null;
    ctx.runtime.memory_type_index = 0;
    ctx.options.anisotropic_filtering = anisotropic_filtering;
    ctx.options.msaa_samples = msaa_samples;

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
        ctx.frames.in_flight_fences[i] = null;
        ctx.descriptors.global_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.shadow_ubos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.shadow_ubos_mapped[i] = null;
        ctx.ui.ui_vbos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.ui.rml_vbos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.ui.rml_ibos[i] = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
        ctx.descriptors.descriptor_sets[i] = null;
        ctx.ui.ui_tex_descriptor_sets[i] = null;
        ctx.ui.ui_tex_descriptor_next[i] = 0;
        ctx.draw.bound_instance_buffer[i] = 0;
        for (0..ctx.ui.ui_tex_descriptor_pool[i].len) |j| {
            ctx.ui.ui_tex_descriptor_pool[i][j] = null;
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
        ctx.resources.transfer.transfer_ready[i] = false;
    }

    for (0..rhi.MAX_SWAPCHAIN_IMAGES) |i| {
        ctx.frames.render_finished_semaphores[i] = null;
    }

    ctx.legacy.model_ubo = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.legacy.dummy_instance_buffer = .{ .buffer = null, .memory = null, .size = 0, .is_host_visible = false };
    ctx.ui.ui_screen_width = 0;
    ctx.ui.ui_screen_height = 0;
    ctx.ui.ui_flushed_vertex_count = 0;
    ctx.legacy.dummy_shadow_image = null;
    ctx.legacy.dummy_shadow_memory = null;
    ctx.legacy.dummy_shadow_view = null;
    ctx.draw.current_model = Mat4.identity;
    ctx.draw.current_color = .{ 1.0, 1.0, 1.0, 1.0 };

    return rhi.RHI{
        .ptr = ctx,
        .vtable = vtable,
        .device = render_device,
    };
}
