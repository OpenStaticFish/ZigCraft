const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const RenderDevice = @import("engine-rhi").render_device.RenderDevice;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const frame_orchestration = @import("vulkan/rhi_frame_orchestration.zig");
const pass_orchestration = @import("vulkan/rhi_pass_orchestration.zig");
const draw_submission = @import("vulkan/rhi_draw_submission.zig");
const ui_submission = @import("vulkan/rhi_ui_submission.zig");
const timing = @import("vulkan/rhi_timing.zig");
const context_factory = @import("vulkan/rhi_context_factory.zig");
const state_control = @import("vulkan/rhi_state_control.zig");
const shadow_bridge = @import("vulkan/rhi_shadow_bridge.zig");
const water_bridge = @import("vulkan/rhi_water_bridge.zig");
const native_access = @import("vulkan/rhi_native_access.zig");
const render_state = @import("vulkan/rhi_render_state.zig");
const init_deinit = @import("vulkan/rhi_init_deinit.zig");
const rhi_timing = @import("vulkan/rhi_timing.zig");
const screenshot = @import("vulkan/screenshot.zig");
const Utils = @import("vulkan/utils.zig");
const CullingSystem = @import("vulkan/culling_system.zig").CullingSystem;
const build_options = @import("engine_graphics_options");

const imgui_c = if (build_options.imgui) @cImport({
    @cInclude("cimgui_backend.h");
}) else struct {};

const QUERY_COUNT_PER_FRAME = rhi_timing.QUERY_COUNT_PER_FRAME;

const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;

fn initContext(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try init_deinit.initContext(ctx, allocator, render_device);
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    init_deinit.deinit(ctx);
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

fn beginFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (ctx.runtime.gpu_fault_detected) return;
    if (ctx.frames.frame_in_progress) return;

    frame_orchestration.recreatePendingShadowResources(ctx);

    if ((ctx.runtime.framebuffer_resized or ctx.swapchain.framebuffer_resized) and !ctx.runtime.swapchain_recreate_failed) {
        log.log.info("beginFrame: triggering recreateSwapchainInternal (resize)", .{});
        frame_orchestration.recreateSwapchainInternal(ctx);
    }

    var flushed_inter_frame_transfer = false;
    if (ctx.resources.transfer.transfer_ready[ctx.resources.transfer.current_frame]) {
        ctx.resources.flushTransfer() catch |err| {
            log.log.errWithTrace("Failed to flush inter-frame transfers: {}", .{err});
            if (err == error.BackendError) {
                ctx.runtime.gpu_fault_detected = true;
                return;
            }
        };
        flushed_inter_frame_transfer = true;
    }

    // Begin frame (acquire image, reset fences/CBs)
    const frame_started = ctx.frames.beginFrame(&ctx.swapchain) catch |err| {
        if (err == error.GpuLost) {
            ctx.runtime.gpu_fault_detected = true;
        } else {
            log.log.errWithTrace("beginFrame failed: {}", .{err});
        }
        return;
    };

    if (frame_started) {
        processTimingResults(ctx);

        if (ctx.dynamic_resolution.enabled) {
            ctx.dynamic_resolution.update(ctx.timing.timing_results.total_gpu_ms);
        }

        const current_frame = ctx.frames.current_frame;
        const command_buffer = ctx.frames.command_buffers[current_frame];
        if (ctx.timing.query_pool != null) {
            rhi_timing.resetFrameTiming(ctx, current_frame);
            c.vkCmdResetQueryPool(command_buffer, ctx.timing.query_pool, @intCast(current_frame * QUERY_COUNT_PER_FRAME), QUERY_COUNT_PER_FRAME);
        }
    }

    ctx.resources.setCurrentFrame(ctx.frames.current_frame);

    if (!frame_started) {
        return;
    }

    ctx.runtime.transfer_barrier_needed = flushed_inter_frame_transfer;
    render_state.applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
    frame_orchestration.prepareFrameState(ctx);
}

fn abortFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    // Reset both recording command buffers before any screen/world teardown.
    // vkDeviceWaitIdle only covers submitted work and cannot make references in
    // an unsubmitted recording command buffer safe to destroy.
    ctx.resources.abortCurrentFrame();
    ctx.frames.abortFrame();
    if (ctx.screenshot_capture.staging != null) screenshot.discardCapture(ctx);

    // Recreate semaphores
    const device = ctx.vulkan_device.vk_device;
    const frame = ctx.frames.current_frame;

    c.vkDestroySemaphore(device, ctx.frames.image_available_semaphores[frame], null);
    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.image_available_semaphores[frame]);

    const image_idx = ctx.frames.current_image_index;
    c.vkDestroySemaphore(device, ctx.frames.render_finished_semaphores[image_idx], null);
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.render_finished_semaphores[image_idx]);

    ctx.runtime.draw_call_count = 0;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.g_pass_active = false;
    ctx.runtime.ssao_pass_active = false;
    ctx.water_system.pass_active = false;
    ctx.post_process.pass_active = false;
    ctx.fxaa.pass_active = false;
    ctx.ui.ui_swapchain_pass_active = false;
    ctx.ui.ui_using_swapchain = false;
    ctx.ui.ui_swapchain_clears_output = false;
    ctx.runtime.final_composed.clear();
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;
}

fn beginGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginGPassInternal(ctx);
}

fn endGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endGPassInternal(ctx);
}

fn beginFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginFXAAPassInternal(ctx);
}

fn endFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endFXAAPassInternal(ctx);
}

fn computeBloom(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (!ctx.frames.frame_in_progress) return;
    pass_orchestration.ensureNoRenderPassActiveInternal(ctx);

    var bloom_source_image = ctx.hdr.hdr_image;
    // Bloom samples the raw blitted image, while post-process consumes its image view.
    if (ctx.dynamic_resolution.isActive() and ctx.taa.ran_this_frame and ctx.dynamic_resolution.upscale_image != null) {
        bloom_source_image = ctx.dynamic_resolution.upscale_image;
    } else if (ctx.taa.ran_this_frame and ctx.taa.output_texture != 0) {
        if (ctx.resources.textures.get(ctx.taa.output_texture)) |tex| {
            if (tex.image) |img| {
                bloom_source_image = img;
            }
        }
    }

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.bloom.compute(
        command_buffer,
        ctx.frames.current_frame,
        bloom_source_image,
        ctx.swapchain.getExtent(),
        &ctx.runtime.draw_call_count,
    );
}

fn computeTAA(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (!ctx.frames.frame_in_progress) return;
    if (!ctx.taa.enabled) return;
    pass_orchestration.ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const render_extent = ctx.dynamic_resolution.getRenderExtent();

    ctx.taa.compute(
        ctx.vulkan_device.vk_device,
        command_buffer,
        ctx.frames.current_frame,
        &ctx.resources,
        ctx.hdr.hdr_view,
        ctx.velocity.velocity_view,
        render_extent,
        &ctx.runtime.draw_call_count,
    );

    if (ctx.dynamic_resolution.isActive() and ctx.taa.ran_this_frame and ctx.dynamic_resolution.upscale_image != null) {
        upscaleDynamicResolution(ctx, command_buffer, render_extent);
    }
}

fn upscaleDynamicResolution(ctx: *VulkanContext, command_buffer: c.VkCommandBuffer, render_extent: c.VkExtent2D) void {
    const taa_output_tex = ctx.resources.textures.get(ctx.taa.output_texture) orelse return;
    const taa_output_image = taa_output_tex.image orelse return;

    var src_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    src_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    src_barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    src_barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    src_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    src_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    src_barrier.image = taa_output_image;
    src_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    src_barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    src_barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;

    var dst_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    dst_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    dst_barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    dst_barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    dst_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    dst_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    dst_barrier.image = ctx.dynamic_resolution.upscale_image;
    dst_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    dst_barrier.srcAccessMask = 0;
    dst_barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

    const barriers = [_]c.VkImageMemoryBarrier{ src_barrier, dst_barrier };
    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, barriers.len, &barriers[0]);

    const native_extent = ctx.swapchain.getExtent();

    var blit_info = std.mem.zeroes(c.VkImageBlit);
    blit_info.srcSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    blit_info.srcOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
    blit_info.srcOffsets[1] = .{ .x = @intCast(render_extent.width), .y = @intCast(render_extent.height), .z = 1 };
    blit_info.dstSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
    blit_info.dstOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
    blit_info.dstOffsets[1] = .{ .x = @intCast(native_extent.width), .y = @intCast(native_extent.height), .z = 1 };

    c.vkCmdBlitImage(command_buffer, taa_output_image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, ctx.dynamic_resolution.upscale_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit_info, c.VK_FILTER_LINEAR);

    var restore_src = src_barrier;
    restore_src.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    restore_src.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    restore_src.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    restore_src.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

    var restore_dst = dst_barrier;
    restore_dst.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    restore_dst.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    restore_dst.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    restore_dst.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

    const restore_barriers = [_]c.VkImageMemoryBarrier{ restore_src, restore_dst };
    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, restore_barriers.len, &restore_barriers[0]);
}

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

fn computeDepthPyramid(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.depth_pyramid.pipeline == null) return;
    pass_orchestration.ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.depth_pyramid.compute(
        command_buffer,
        ctx.frames.current_frame,
        ctx.gpass.g_depth_image,
        ctx.gpass.g_pass_extent.width,
        ctx.gpass.g_pass_extent.height,
    );
}

fn setVignetteEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.vignette_enabled = enabled;
}

fn setVignetteIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.vignette_intensity = intensity;
}

fn setFilmGrainEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.film_grain_enabled = enabled;
}

fn setFilmGrainIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.film_grain_intensity = intensity;
}

fn setColorGradingEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.color_grading_enabled = enabled;
}

fn setColorGradingIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.color_grading_intensity = intensity;
}

fn setTAABlendFactor(ctx_ptr: *anyopaque, value: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.taa.blend_factor = std.math.clamp(value, 0.0, 0.98);
}

fn setTAAVelocityRejection(ctx_ptr: *anyopaque, value: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.taa.velocity_rejection = std.math.clamp(value, 0.0, 0.25);
}

fn setDynamicResolution(ctx_ptr: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.dynamic_resolution.enabled = enabled;
    ctx.dynamic_resolution.min_scale = std.math.clamp(min_scale, 0.25, 1.0);
    ctx.dynamic_resolution.max_scale = std.math.clamp(max_scale, 0.25, 1.0);
    if (ctx.dynamic_resolution.min_scale > ctx.dynamic_resolution.max_scale) {
        ctx.dynamic_resolution.max_scale = ctx.dynamic_resolution.min_scale;
    }
    ctx.dynamic_resolution.target_fps = if (target_fps == 0) 60 else target_fps;
    if (!enabled) {
        ctx.dynamic_resolution.current_scale = 1.0;
        ctx.dynamic_resolution.render_extent = ctx.swapchain.getExtent();
    } else {
        ctx.dynamic_resolution.update(ctx.timing.timing_results.total_gpu_ms);
    }
}

fn getResolutionScale(ctx_ptr: *anyopaque) f32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.dynamic_resolution.current_scale;
}

fn createCullingSystem(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, max_chunks: usize) anyerror!?rhi.ICullingSystem {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const system = try CullingSystem.init(allocator, ctx, max_chunks);
    return system.interface();
}

fn captureFrame(ctx_ptr: *anyopaque, path: []const u8) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return screenshot.requestCapture(ctx, path);
}

fn endFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (ctx.runtime.gpu_fault_detected) return;
    pass_orchestration.endFrame(ctx);
}

fn setClearColor(ctx_ptr: *anyopaque, color: Vec3) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const r = if (std.math.isFinite(color.x)) color.x else 0.0;
    const g = if (std.math.isFinite(color.y)) color.y else 0.0;
    const b = if (std.math.isFinite(color.z)) color.z else 0.0;
    ctx.runtime.clear_color = .{ r, g, b, 1.0 };
}

fn beginMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginMainPassInternal(ctx);
}

fn endMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endMainPassInternal(ctx);
}

fn beginPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginPostProcessPassInternal(ctx);
}

fn endPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endPostProcessPassInternal(ctx);
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.waitIdle(ctx);
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, uniforms: rhi.GlobalUniforms, frame_params: rhi.FrameRenderParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try render_state.updateGlobalUniforms(ctx, uniforms, frame_params);
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4, color: Vec3) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setModelMatrix(ctx, model, color);
}

fn setInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setInstanceBuffer(ctx, handle);
}

fn setTerrainPipelineBound(ctx_ptr: *anyopaque, bound: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setTerrainPipelineBound(ctx, bound);
}

fn setSelectionMode(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setSelectionMode(ctx, enabled);
}

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setTextureUniforms(ctx, texture_enabled, shadow_map_handles);
}

fn drawDepthTexture(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawDepthTexture(ctx, texture, rect);
}

fn createTexture(ctx_ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createTexture(width, height, format, config, data_opt);
}

fn createTexture3D(ctx_ptr: *anyopaque, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createTexture3D(width, height, depth, format, config, data_opt);
}

fn destroyTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.resources.destroyTexture(handle);
}

fn bindTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const resolved = if (handle == 0) switch (slot) {
        6 => ctx.draw.dummy_normal_texture,
        7, 8 => ctx.draw.dummy_roughness_texture,
        9 => ctx.draw.dummy_texture,
        // LPV shader bindings are sampler3D. A 2D fallback is invalid even
        // when LPV lighting is disabled, and snapshotting it made indirect
        // terrain undefined on RADV.
        11, 12, 13 => ctx.draw.dummy_texture_3d,
        0, 1 => ctx.draw.dummy_texture,
        else => ctx.draw.dummy_texture,
    } else handle;

    switch (slot) {
        0, 1 => ctx.draw.current_texture = resolved,
        6 => ctx.draw.current_normal_texture = resolved,
        7 => ctx.draw.current_roughness_texture = resolved,
        8 => ctx.draw.current_displacement_texture = resolved,
        9 => ctx.draw.current_env_texture = resolved,
        14 => ctx.draw.current_water_reflection_texture = resolved,
        15 => ctx.draw.current_scene_depth_texture = resolved,
        11 => ctx.draw.current_lpv_texture = resolved,
        12 => ctx.draw.current_lpv_texture_g = resolved,
        13 => ctx.draw.current_lpv_texture_b = resolved,
        else => {},
    }

    if (ctx.frames.frame_in_progress) {
        frame_orchestration.refreshTextureDescriptors(ctx);
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
    state_control.setViewport(ctx, width, height);
}

fn requestSwapchainRecreate(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.requestSwapchainRecreate(ctx);
}

fn getAllocator(ctx_ptr: *anyopaque) std.mem.Allocator {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getAllocator(ctx);
}

fn getFrameIndex(ctx_ptr: *anyopaque) usize {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getFrameIndex(ctx);
}

fn supportsIndirectFirstInstance(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.supportsIndirectFirstInstance(ctx);
}

fn supportsIndirectCount(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.supportsIndirectCount(ctx);
}

fn recover(ctx_ptr: *anyopaque) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try state_control.recover(ctx);
}

fn setWireframe(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setWireframe(ctx, enabled);
}

fn setTexturesEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setTexturesEnabled(ctx, enabled);
}

fn setDebugShadowView(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setDebugShadowView(ctx, enabled);
}

fn setShadowDebugChannel(ctx_ptr: *anyopaque, channel: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setShadowDebugChannel(ctx, channel);
}

fn setVSync(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setVSync(ctx, enabled);
}

fn setAnisotropicFiltering(ctx_ptr: *anyopaque, level: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setAnisotropicFiltering(ctx, level);
}

fn setVolumetricDensity(ctx_ptr: *anyopaque, density: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setVolumetricDensity(ctx, density);
}

fn setShadowResolution(ctx_ptr: *anyopaque, resolution: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setShadowResolution(ctx, resolution);
}

fn setMSAA(ctx_ptr: *anyopaque, samples: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setMSAA(ctx, samples);
}

fn getMaxAnisotropy(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getMaxAnisotropy(ctx);
}

fn getMaxMSAASamples(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getMaxMSAASamples(ctx);
}

fn getFaultCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getFaultCount(ctx);
}

fn getValidationErrorCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getValidationErrorCount(ctx);
}

fn getDeviceLocalVramBytes(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.vulkan_device.getDeviceLocalVramBytes();
}

fn getRenderResolution(ctx_ptr: *anyopaque) rhi.RenderResolution {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return .{
        .width = ctx.gpass.g_pass_extent.width,
        .height = ctx.gpass.g_pass_extent.height,
    };
}

fn getDrawCallCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.runtime.draw_call_count;
}

fn drawIndexed(ctx_ptr: *anyopaque, vbo_handle: rhi.BufferHandle, ebo_handle: rhi.BufferHandle, count: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawIndexed(ctx, vbo_handle, ebo_handle, count);
}

fn drawIndirect(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawIndirect(ctx, handle, command_buffer, offset, draw_count, stride);
}

fn drawIndirectCount(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, count_buffer: rhi.BufferHandle, count_offset: usize, max_draw_count: u32, stride: u32) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return draw_submission.drawIndirectCount(ctx, handle, command_buffer, offset, count_buffer, count_offset, max_draw_count, stride);
}

fn drawInstance(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawInstance(ctx, handle, count, instance_index);
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    drawOffset(ctx_ptr, handle, count, mode, 0);
}

fn drawOffset(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawOffset(ctx, handle, count, mode, offset);
}

fn bindBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.bindBuffer(ctx, handle, usage);
}

fn pushConstants(ctx_ptr: *anyopaque, stages: rhi.ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    draw_submission.pushConstants(ctx, stages, offset, size, data);
}

// 2D Rendering functions
fn begin2DPass(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ui_submission.begin2DPass(ctx, screen_width, screen_height);
}

fn end2DPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.end2DPass(ctx);
}

fn drawRect2D(ctx_ptr: *anyopaque, rect: rhi.Rect, color: rhi.Color) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawRect2D(ctx, rect, color);
}

fn drawIndexedUIGeometry(ctx_ptr: *anyopaque, vertices: []const rhi.UiVertex, indices: []const u32, texture: rhi.TextureHandle, translation: [2]f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawIndexedGeometry(ctx, vertices, indices, texture, translation);
}

fn setUIScissorRegion(ctx_ptr: *anyopaque, region: rhi.UiScissor) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.setScissorRegion(ctx, region);
}

const VULKAN_SHADOW_CONTEXT_VTABLE = rhi.IShadowContext.VTable{
    .beginPass = beginShadowPass,
    .endPass = endShadowPass,
    .updateUniforms = updateShadowUniforms,
    .getShadowMapHandle = getShadowMapHandle,
    .getResolution = getShadowResolution,
};

fn bindUIPipeline(ctx_ptr: *anyopaque, textured: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.bindUIPipeline(ctx, textured);
}

fn drawTexture2D(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawTexture2D(ctx, texture, rect);
}

fn drawTextureRegion2D(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect, uv: rhi.UVRect, color: rhi.Color) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawTextureRegion2D(ctx, texture, rect, uv, color);
}

fn createShader(ctx_ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
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

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    shadow_bridge.beginShadowPassInternal(ctx, cascade_index, light_space_matrix);
}

fn endShadowPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    shadow_bridge.endShadowPassInternal(ctx);
}

fn getShadowMapHandle(ctx_ptr: *anyopaque, cascade_index: u32) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return shadow_bridge.getShadowMapHandle(ctx, cascade_index);
}

fn getShadowResolution(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return shadow_bridge.getShadowResolution(ctx);
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try shadow_bridge.updateShadowUniforms(ctx, params);
}

const VULKAN_WATER_CONTEXT_VTABLE = rhi.IWaterContext.VTable{
    .beginReflectionPass = beginWaterReflectionPass,
    .endReflectionPass = endWaterReflectionPass,
    .getReflectionTextureHandle = getWaterReflectionTextureHandle,
    .getSceneDepthTextureHandle = getWaterSceneDepthTextureHandle,
    .computeReflectedViewProj = computeWaterReflectedViewProj,
};

fn beginWaterReflectionPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    water_bridge.beginWaterReflectionPassInternal(ctx);
}

fn endWaterReflectionPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    water_bridge.endWaterReflectionPassInternal(ctx);
}

fn getWaterReflectionTextureHandle(ctx_ptr: *anyopaque) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return water_bridge.getWaterReflectionTextureHandle(ctx);
}

fn getWaterSceneDepthTextureHandle(ctx_ptr: *anyopaque) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return water_bridge.getWaterSceneDepthTextureHandle(ctx);
}

fn computeWaterReflectedViewProj(ctx_ptr: *anyopaque, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return water_bridge.computeWaterReflectedViewProj(ctx, view, proj, camera_pos);
}

fn getNativeCommandBuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeCommandBuffer(ctx);
}
fn getNativeSwapchainExtent(ctx_ptr: *anyopaque) [2]u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeSwapchainExtent(ctx);
}
fn getNativeDevice(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeDevice(ctx);
}
fn getNativeInstance(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeInstance(ctx);
}
fn getNativePhysicalDevice(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativePhysicalDevice(ctx);
}
fn getNativeQueue(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeQueue(ctx);
}
fn getNativeQueueFamily(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeQueueFamily(ctx);
}
fn getNativeDescriptorPool(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeDescriptorPool(ctx);
}
fn getNativeUiRenderPass(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeUiRenderPass(ctx);
}
fn getNativeSwapchainImageCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeSwapchainImageCount(ctx);
}
fn computeSsao(ctx_ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.ssao_system.compute(
        ctx.vulkan_device.vk_device,
        ctx.frames.command_buffers[ctx.frames.current_frame],
        ctx.frames.current_frame,
        ctx.dynamic_resolution.getRenderExtent(),
        proj,
        inv_proj,
    );
}

fn drawSkyEffect(ctx_ptr: *anyopaque, params: rhi.SkyParams) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const pipeline = ctx.pipeline_manager.sky_pipeline;
    const layout = ctx.pipeline_manager.sky_pipeline_layout;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];

    if (pipeline == null or layout == null or cmd == null) {
        log.log.warn("Vulkan RHI: Sky rendering skipped, handles missing (pipeline={}, layout={}, cmd={})", .{ pipeline != null, layout != null, cmd != null });
        if (pipeline == null) return error.SkyPipelineNotReady;
        if (layout == null) return error.SkyPipelineLayoutNotReady;
        if (cmd == null) return error.CommandBufferNotReady;
        return error.ResourceNotReady;
    }

    const pc = rhi.SkyPushConstants{
        .cam_forward = .{ params.cam_forward.x, params.cam_forward.y, params.cam_forward.z, 0.0 },
        .cam_right = .{ params.cam_right.x, params.cam_right.y, params.cam_right.z, 0.0 },
        .cam_up = .{ params.cam_up.x, params.cam_up.y, params.cam_up.z, 0.0 },
        .sun_dir = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, 0.0 },
        .sky_color = .{ params.sky_color.x, params.sky_color.y, params.sky_color.z, 1.0 },
        .horizon_color = .{ params.horizon_color.x, params.horizon_color.y, params.horizon_color.z, 1.0 },
        .params = .{ params.aspect, params.tan_half_fov, params.sun_intensity, params.moon_intensity },
        .time = .{ params.time, params.cam_pos.x, params.cam_pos.y, params.cam_pos.z },
    };

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    if (descriptor_set != null) {
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
    }
    c.vkCmdPushConstants(cmd, layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(rhi.SkyPushConstants), &pc);
    c.vkCmdDraw(cmd, 3, 1, 0, 0);
}

fn beginWaterDrawEffect(ctx_ptr: *anyopaque, reflection: rhi.TextureHandle, scene_depth: rhi.TextureHandle) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const pipeline = ctx.water_system.water_pipeline;
    const layout = ctx.water_system.water_pipeline_layout;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];

    if (pipeline == null or layout == null or cmd == null or reflection == 0 or scene_depth == 0) return false;

    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const descriptor_set = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    if (descriptor_set != null) {
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
    }
    ctx.draw.terrain_pipeline_bound = true;
    return true;
}

fn endWaterDrawEffect(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.draw.terrain_pipeline_bound = false;
}

const VULKAN_RENDER_EFFECTS_VTABLE = rhi.IRenderEffectsContext.VTable{
    .drawSky = drawSkyEffect,
    .beginWaterDraw = beginWaterDrawEffect,
    .endWaterDraw = endWaterDrawEffect,
};

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    shadow_bridge.drawDebugShadowMap(ctx, cascade_index, depth_map_handle);
}

const VULKAN_SSAO_VTABLE = rhi.ISSAOContext.VTable{
    .compute = computeSsao,
};

const VULKAN_DEBUG_OVERLAY_VTABLE = rhi.IDebugOverlayContext.VTable{
    .drawDebugShadowMap = drawDebugShadowMap,
};

const VULKAN_UI_CONTEXT_VTABLE = rhi.IUIContext.VTable{
    .beginPass = begin2DPass,
    .endPass = end2DPass,
    .drawRect = drawRect2D,
    .drawTexture = drawTexture2D,
    .drawTextureRegion = drawTextureRegion2D,
    .drawDepthTexture = drawDepthTexture,
    .bindPipeline = bindUIPipeline,
    .drawIndexedGeometry = drawIndexedUIGeometry,
    .setScissorRegion = setUIScissorRegion,
};

fn initImGuiBackend(ctx_ptr: *anyopaque, window: *anyopaque) bool {
    if (!build_options.imgui) return false;
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!imgui_c.ZigCraft_ImGui_ImplSDL3_InitForVulkan(@ptrCast(window))) return false;
    const image_count = getNativeSwapchainImageCount(ctx_ptr);
    const min_image_count: u32 = if (image_count > 1) image_count else 2;
    var init_info = imgui_c.ZigCraftImGuiVulkanInitInfo{
        .instance = @ptrFromInt(getNativeInstance(ctx_ptr)),
        .physical_device = @ptrFromInt(getNativePhysicalDevice(ctx_ptr)),
        .device = @ptrFromInt(getNativeDevice(ctx_ptr)),
        .queue = @ptrFromInt(getNativeQueue(ctx_ptr)),
        .queue_family = getNativeQueueFamily(ctx_ptr),
        .descriptor_pool = @ptrFromInt(getNativeDescriptorPool(ctx_ptr)),
        .render_pass = @ptrFromInt(getNativeUiRenderPass(ctx_ptr)),
        .min_image_count = min_image_count,
        .image_count = @max(image_count, min_image_count),
        .msaa_samples = 1,
    };
    _ = ctx;
    if (!imgui_c.ZigCraft_ImGui_ImplVulkan_Init(&init_info)) {
        imgui_c.ZigCraft_ImGui_ImplSDL3_Shutdown();
        return false;
    }
    return true;
}

fn shutdownImGuiBackend(_: *anyopaque) void {
    if (!build_options.imgui) return;
    imgui_c.ZigCraft_ImGui_ImplVulkan_Shutdown();
    imgui_c.ZigCraft_ImGui_ImplSDL3_Shutdown();
}

fn newImGuiFrame(_: *anyopaque) void {
    if (!build_options.imgui) return;
    imgui_c.ZigCraft_ImGui_ImplVulkan_NewFrame();
    imgui_c.ZigCraft_ImGui_ImplSDL3_NewFrame();
}

fn renderImGuiDrawData(ctx_ptr: *anyopaque, draw_data: *anyopaque) void {
    if (!build_options.imgui) return;
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const command_buffer = currentCommandBuffer(ctx) orelse return;
    imgui_c.ZigCraft_ImGui_ImplVulkan_RenderDrawData(
        @ptrCast(draw_data),
        @ptrFromInt(@intFromPtr(command_buffer)),
    );
}

const VULKAN_IMGUI_CONTEXT_VTABLE = rhi.IImGuiContext.VTable{
    .initBackend = initImGuiBackend,
    .shutdownBackend = shutdownImGuiBackend,
    .newFrame = newImGuiFrame,
    .renderDrawData = renderImGuiDrawData,
};

fn getStateContext(ctx_ptr: *anyopaque) rhi.IRenderStateContext {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_STATE_CONTEXT_VTABLE };
}

const VULKAN_STATE_CONTEXT_VTABLE = rhi.IRenderStateContext.VTable{
    .setModelMatrix = setModelMatrix,
    .setInstanceBuffer = setInstanceBuffer,
    .setTerrainPipelineBound = setTerrainPipelineBound,
    .setSelectionMode = setSelectionMode,
    .updateGlobalUniforms = updateGlobalUniforms,
    .setTextureUniforms = setTextureUniforms,
};

fn getEncoder(ctx_ptr: *anyopaque) rhi.IGraphicsCommandEncoder {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_COMMAND_ENCODER_VTABLE };
}

const VULKAN_COMMAND_ENCODER_VTABLE = rhi.IGraphicsCommandEncoder.VTable{
    .bindTexture = bindTexture,
    .bindBuffer = bindBuffer,
    .pushConstants = pushConstants,
    .draw = draw,
    .drawOffset = drawOffset,
    .drawIndexed = drawIndexed,
    .drawIndirect = drawIndirect,
    .drawIndirectCount = drawIndirectCount,
    .drawInstance = drawInstance,
    .setViewport = setViewport,
};

fn currentCommandBuffer(ctx: *VulkanContext) ?c.VkCommandBuffer {
    return ctx.frames.command_buffers[ctx.frames.current_frame];
}

fn computeBufferResource(ctx: *VulkanContext, buffer: rhi.ComputeBuffer) ?*@import("vulkan/rhi_context_types.zig").ComputeBufferResource {
    if (buffer.handle == 0) return null;
    return ctx.compute_resources.buffers.getPtr(buffer.handle);
}

fn computePipelineResource(ctx: *VulkanContext, pipeline: rhi.ComputePipeline) ?*@import("vulkan/rhi_context_types.zig").ComputePipelineResource {
    if (pipeline.handle == 0) return null;
    return ctx.compute_resources.pipelines.getPtr(pipeline.handle);
}

fn bindingBuffer(ctx: *VulkanContext, binding: rhi.ComputeBufferBinding) c.VkBuffer {
    return switch (binding) {
        .compute => |buffer| if (computeBufferResource(ctx, buffer)) |resource| resource.buffer else null,
        .buffer => |handle| blk: {
            const buffer = ctx.resources.buffers.get(handle) orelse break :blk null;
            break :blk buffer.buffer;
        },
    };
}

fn bindComputePipeline(ctx_ptr: *anyopaque, pipeline: rhi.ComputePipeline) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    const resource = computePipelineResource(ctx, pipeline) orelse return;
    c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, resource.pipeline);
}

fn bindComputeDescriptorSet(ctx_ptr: *anyopaque, pipeline: rhi.ComputePipeline, frame_index: usize) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    if (frame_index >= rhi.MAX_FRAMES_IN_FLIGHT) return;
    const resource = computePipelineResource(ctx, pipeline) orelse return;
    const set = resource.descriptor_sets[frame_index];
    c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, resource.layout, 0, 1, &set, 0, null);
}

fn createComputeBuffer(ctx_ptr: *anyopaque, size: usize, host_visible: bool) rhi.RhiError!rhi.ComputeBuffer {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const properties: c.VkMemoryPropertyFlags = if (host_visible)
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
    else
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    const buffer = try Utils.createVulkanBuffer(&ctx.vulkan_device, size, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, properties);
    const handle = ctx.compute_resources.next_buffer_handle;
    ctx.compute_resources.next_buffer_handle +%= 1;
    try ctx.compute_resources.buffers.put(ctx.allocator, handle, .{ .buffer = buffer.buffer, .memory = buffer.memory, .mapped_ptr = buffer.mapped_ptr });
    return .{ .handle = handle, .mapped_ptr = buffer.mapped_ptr };
}

fn destroyComputeBuffer(ctx_ptr: *anyopaque, buffer: *rhi.ComputeBuffer) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const vk = ctx.vulkan_device.vk_device;
    const resource = ctx.compute_resources.buffers.fetchRemove(buffer.handle) orelse {
        buffer.* = .{};
        return;
    };
    if (resource.value.mapped_ptr != null) c.vkUnmapMemory(vk, resource.value.memory);
    if (resource.value.buffer != null) c.vkDestroyBuffer(vk, resource.value.buffer, null);
    if (resource.value.memory != null) c.vkFreeMemory(vk, resource.value.memory, null);
    buffer.* = .{};
}

fn createComputePipeline(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!rhi.ComputePipeline {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const vk = ctx.vulkan_device.vk_device;
    var resource = @import("vulkan/rhi_context_types.zig").ComputePipelineResource{};
    var result = rhi.ComputePipeline{};
    errdefer destroyComputePipeline(ctx_ptr, &result);

    var pool_size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = storage_binding_count * rhi.MAX_FRAMES_IN_FLIGHT };
    var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.maxSets = rhi.MAX_FRAMES_IN_FLIGHT;
    pool_info.poolSizeCount = 1;
    pool_info.pPoolSizes = &pool_size;
    var descriptor_pool: c.VkDescriptorPool = null;
    try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &descriptor_pool));
    resource.descriptor_pool = descriptor_pool;

    const bindings = try allocator.alloc(c.VkDescriptorSetLayoutBinding, storage_binding_count);
    defer allocator.free(bindings);
    for (bindings, 0..) |*binding, i| {
        binding.* = .{ .binding = @intCast(i), .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null };
    }

    var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
    layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = storage_binding_count;
    layout_info.pBindings = bindings.ptr;
    var descriptor_set_layout: c.VkDescriptorSetLayout = null;
    try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &descriptor_set_layout));
    resource.descriptor_set_layout = descriptor_set_layout;

    var layouts = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout);
    for (&layouts) |*layout| layout.* = descriptor_set_layout;
    var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    alloc_info.descriptorPool = descriptor_pool;
    alloc_info.descriptorSetCount = rhi.MAX_FRAMES_IN_FLIGHT;
    alloc_info.pSetLayouts = &layouts;
    var descriptor_sets = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet);
    try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &descriptor_sets));
    for (descriptor_sets, 0..) |set, i| resource.descriptor_sets[i] = set;

    var pc_range = std.mem.zeroes(c.VkPushConstantRange);
    pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
    pc_range.size = push_constant_size;
    var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
    pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pipeline_layout_info.setLayoutCount = 1;
    pipeline_layout_info.pSetLayouts = &descriptor_set_layout;
    pipeline_layout_info.pushConstantRangeCount = if (push_constant_size == 0) 0 else 1;
    pipeline_layout_info.pPushConstantRanges = if (push_constant_size == 0) null else &pc_range;
    var pipeline_layout: c.VkPipelineLayout = null;
    try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &pipeline_layout));
    resource.layout = pipeline_layout;

    const bytes = try fs.cwd().readFileAlloc(shader_path, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;
    const shader_module = try Utils.createShaderModule(vk, bytes);
    defer c.vkDestroyShaderModule(vk, shader_module, null);

    var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
    stage.module = shader_module;
    stage.pName = "main";
    var pipeline_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
    pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeline_info.stage = stage;
    pipeline_info.layout = pipeline_layout;
    var pipeline: c.VkPipeline = null;
    try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &pipeline_info, null, &pipeline));
    resource.pipeline = pipeline;
    const handle = ctx.compute_resources.next_pipeline_handle;
    ctx.compute_resources.next_pipeline_handle +%= 1;
    try ctx.compute_resources.pipelines.put(ctx.allocator, handle, resource);
    result.handle = handle;
    return result;
}

fn updateComputeDescriptors(ctx_ptr: *anyopaque, pipeline: rhi.ComputePipeline, frame_index: usize, buffers: []const rhi.ComputeBufferBinding) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (frame_index >= rhi.MAX_FRAMES_IN_FLIGHT or buffers.len == 0) return;
    const pipeline_resource = computePipelineResource(ctx, pipeline) orelse return;

    const infos = ctx.allocator.alloc(c.VkDescriptorBufferInfo, buffers.len) catch |err| {
        log.log.err("Failed to allocate compute descriptor buffer infos: {}", .{err});
        return;
    };
    defer ctx.allocator.free(infos);

    const writes = ctx.allocator.alloc(c.VkWriteDescriptorSet, buffers.len) catch |err| {
        log.log.err("Failed to allocate compute descriptor writes: {}", .{err});
        return;
    };
    defer ctx.allocator.free(writes);

    for (buffers, 0..) |buffer, i| {
        const vk_buffer = bindingBuffer(ctx, buffer);
        if (vk_buffer == null) return;
        infos[i] = .{ .buffer = vk_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[i] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[i].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet = pipeline_resource.descriptor_sets[frame_index];
        writes[i].dstBinding = @intCast(i);
        writes[i].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[i].descriptorCount = 1;
        writes[i].pBufferInfo = &infos[i];
    }
    c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, @intCast(writes.len), writes.ptr, 0, null);
}

fn destroyComputePipeline(ctx_ptr: *anyopaque, pipeline: *rhi.ComputePipeline) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const vk = ctx.vulkan_device.vk_device;
    const resource = ctx.compute_resources.pipelines.fetchRemove(pipeline.handle) orelse {
        pipeline.* = .{};
        return;
    };
    if (resource.value.pipeline != null) c.vkDestroyPipeline(vk, resource.value.pipeline, null);
    if (resource.value.layout != null) c.vkDestroyPipelineLayout(vk, resource.value.layout, null);
    if (resource.value.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, resource.value.descriptor_set_layout, null);
    if (resource.value.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, resource.value.descriptor_pool, null);
    pipeline.* = .{};
}

fn dispatchCompute(ctx_ptr: *anyopaque, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    c.vkCmdDispatch(cmd, group_count_x, group_count_y, group_count_z);
}

fn pushComputeConstants(ctx_ptr: *anyopaque, pipeline: rhi.ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    const resource = computePipelineResource(ctx, pipeline) orelse return;
    c.vkCmdPushConstants(cmd, resource.layout, c.VK_SHADER_STAGE_COMPUTE_BIT, offset, size, data);
}

fn fillComputeBuffer(ctx_ptr: *anyopaque, buffer: rhi.ComputeBuffer, offset: u64, size: u64, data: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    const resource = computeBufferResource(ctx, buffer) orelse return;
    c.vkCmdFillBuffer(cmd, resource.buffer, offset, size, data);
}

fn copyComputeBuffer(ctx_ptr: *anyopaque, src_buffer: rhi.ComputeBufferBinding, dst_buffer: rhi.ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    const src = bindingBuffer(ctx, src_buffer);
    const dst = bindingBuffer(ctx, dst_buffer);
    if (src == null or dst == null) return;
    var region = std.mem.zeroes(c.VkBufferCopy);
    region.srcOffset = src_offset;
    region.dstOffset = dst_offset;
    region.size = size;
    c.vkCmdCopyBuffer(cmd, src, dst, 1, &region);
}

fn computePipelineBarrier(ctx_ptr: *anyopaque, src_stage: rhi.PipelineStageFlags, dst_stage: rhi.PipelineStageFlags, src_access: rhi.AccessFlags, dst_access: rhi.AccessFlags) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    var barrier = std.mem.zeroes(c.VkMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 1, &barrier, 0, null, 0, null);
}

fn computeBufferBarrier(ctx_ptr: *anyopaque, buffer: rhi.ComputeBufferBinding, src_stage: rhi.PipelineStageFlags, dst_stage: rhi.PipelineStageFlags, src_access: rhi.AccessFlags, dst_access: rhi.AccessFlags, offset: u64, size: u64) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const cmd = currentCommandBuffer(ctx) orelse return;
    const vk_buffer = bindingBuffer(ctx, buffer);
    if (vk_buffer == null or size == 0) return;

    var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = vk_buffer;
    barrier.offset = offset;
    barrier.size = size;

    c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 1, &barrier, 0, null);
}

fn waitForFrameFence(ctx_ptr: *anyopaque, frame_index: usize) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (frame_index >= rhi.MAX_FRAMES_IN_FLIGHT) return false;
    const fence = ctx.frames.in_flight_fences[frame_index] orelse return false;
    return c.vkWaitForFences(ctx.vulkan_device.vk_device, 1, &fence, c.VK_TRUE, 5_000_000_000) == c.VK_SUCCESS;
}

fn hasComputeCommandBuffer(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return currentCommandBuffer(ctx) != null;
}

const VULKAN_COMPUTE_CONTEXT_VTABLE = rhi.IComputeContext.VTable{
    .bindComputePipeline = bindComputePipeline,
    .bindDescriptorSet = bindComputeDescriptorSet,
    .createComputeBuffer = createComputeBuffer,
    .destroyComputeBuffer = destroyComputeBuffer,
    .createComputePipeline = createComputePipeline,
    .updateComputeDescriptors = updateComputeDescriptors,
    .destroyComputePipeline = destroyComputePipeline,
    .dispatch = dispatchCompute,
    .pushConstants = pushComputeConstants,
    .fillBuffer = fillComputeBuffer,
    .copyBuffer = copyComputeBuffer,
    .pipelineBarrier = computePipelineBarrier,
    .bufferBarrier = computeBufferBarrier,
    .waitForFrameFence = waitForFrameFence,
    .hasCommandBuffer = hasComputeCommandBuffer,
};

const VULKAN_RESOURCE_FACTORY_VTABLE = rhi.IResourceFactory.VTable{
    .createBuffer = createBuffer,
    .uploadBuffer = uploadBuffer,
    .updateBuffer = updateBuffer,
    .destroyBuffer = destroyBuffer,
    .createTexture = createTexture,
    .createTexture3D = createTexture3D,
    .destroyTexture = destroyTexture,
    .updateTexture = updateTexture,
    .createShader = createShader,
    .destroyShader = destroyShader,
    .mapBuffer = mapBuffer,
    .unmapBuffer = unmapBuffer,
};

const VULKAN_RENDER_CONTEXT_VTABLE = rhi.IRenderContext.VTable{
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .abortFrame = abortFrame,
    .requestSwapchainRecreate = requestSwapchainRecreate,
    .getEncoder = getEncoder,
    .getStateContext = getStateContext,
    .setClearColor = setClearColor,
};

const VULKAN_PASS_ORCHESTRATION_VTABLE = rhi.IPassOrchestrationContext.VTable{
    .beginMainPass = beginMainPass,
    .endMainPass = endMainPass,
    .beginPostProcessPass = beginPostProcessPass,
    .endPostProcessPass = endPostProcessPass,
    .beginGPass = beginGPass,
    .endGPass = endGPass,
    .beginFXAAPass = beginFXAAPass,
    .endFXAAPass = endFXAAPass,
};

const VULKAN_POST_PROCESS_VTABLE = rhi.IPostProcessContext.VTable{
    .computeBloom = computeBloom,
    .computeTAA = computeTAA,
    .computeDepthPyramid = computeDepthPyramid,
};

const VULKAN_NATIVE_HANDLES_VTABLE = rhi.VulkanNativeHandles.VTable{
    .getCommandBuffer = getNativeCommandBuffer,
    .getSwapchainExtent = getNativeSwapchainExtent,
    .getDevice = getNativeDevice,
    .getInstance = getNativeInstance,
    .getPhysicalDevice = getNativePhysicalDevice,
    .getQueue = getNativeQueue,
    .getQueueFamily = getNativeQueueFamily,
    .getDescriptorPool = getNativeDescriptorPool,
    .getUiRenderPass = getNativeUiRenderPass,
    .getSwapchainImageCount = getNativeSwapchainImageCount,
};

const VULKAN_DEVICE_QUERY_VTABLE = rhi.IDeviceQuery.VTable{
    .getFrameIndex = getFrameIndex,
    .supportsIndirectFirstInstance = supportsIndirectFirstInstance,
    .supportsIndirectCount = supportsIndirectCount,
    .getMaxAnisotropy = getMaxAnisotropy,
    .getMaxMSAASamples = getMaxMSAASamples,
    .getFaultCount = getFaultCount,
    .getValidationErrorCount = getValidationErrorCount,
    .getDrawCallCount = getDrawCallCount,
    .getDeviceLocalVramBytes = getDeviceLocalVramBytes,
    .getRenderResolution = getRenderResolution,
    .waitIdle = waitIdle,
};

const VULKAN_DEVICE_TIMING_VTABLE = rhi.IDeviceTiming.VTable{
    .beginPassTiming = beginPassTiming,
    .endPassTiming = endPassTiming,
    .getTimingResults = getTimingResults,
    .isTimingEnabled = isTimingEnabled,
    .setTimingEnabled = setTimingEnabled,
};

const VULKAN_RENDER_QUALITY_OPTIONS_VTABLE = rhi.IRenderQualityOptions.VTable{
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setDebugShadowView = setDebugShadowView,
    .setShadowDebugChannel = setShadowDebugChannel,
    .setVSync = setVSync,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setVolumetricDensity = setVolumetricDensity,
    .setShadowResolution = setShadowResolution,
    .setMSAA = setMSAA,
    .setFXAA = setFXAA,
    .setBloom = setBloom,
    .setBloomIntensity = setBloomIntensity,
    .setVignetteEnabled = setVignetteEnabled,
    .setVignetteIntensity = setVignetteIntensity,
    .setFilmGrainEnabled = setFilmGrainEnabled,
    .setFilmGrainIntensity = setFilmGrainIntensity,
    .setColorGradingEnabled = setColorGradingEnabled,
    .setColorGradingIntensity = setColorGradingIntensity,
    .setTAABlendFactor = setTAABlendFactor,
    .setTAAVelocityRejection = setTAAVelocityRejection,
    .setDynamicResolution = setDynamicResolution,
    .getResolutionScale = getResolutionScale,
};

const VULKAN_DEVICE_RECOVERY_VTABLE = rhi.IDeviceRecovery.VTable{
    .recover = recover,
};

const VULKAN_CULLING_FACTORY_VTABLE = rhi.ICullingSystemFactory.VTable{
    .createCullingSystem = createCullingSystem,
};

const VULKAN_SCREENSHOT_CONTEXT_VTABLE = rhi.IScreenshotContext.VTable{
    .captureFrame = captureFrame,
};

const VULKAN_RHI_INTERFACES = rhi.RHI.Interfaces{
    .resources = &VULKAN_RESOURCE_FACTORY_VTABLE,
    .render = &VULKAN_RENDER_CONTEXT_VTABLE,
    .passes = &VULKAN_PASS_ORCHESTRATION_VTABLE,
    .post_process = &VULKAN_POST_PROCESS_VTABLE,
    .effects = &VULKAN_RENDER_EFFECTS_VTABLE,
    .vulkan = &VULKAN_NATIVE_HANDLES_VTABLE,
    .ssao = &VULKAN_SSAO_VTABLE,
    .debug_overlay = &VULKAN_DEBUG_OVERLAY_VTABLE,
    .shadow = &VULKAN_SHADOW_CONTEXT_VTABLE,
    .water = &VULKAN_WATER_CONTEXT_VTABLE,
    .compute = &VULKAN_COMPUTE_CONTEXT_VTABLE,
    .ui = &VULKAN_UI_CONTEXT_VTABLE,
    .imgui = &VULKAN_IMGUI_CONTEXT_VTABLE,
    .query = &VULKAN_DEVICE_QUERY_VTABLE,
    .timing = &VULKAN_DEVICE_TIMING_VTABLE,
    .quality = &VULKAN_RENDER_QUALITY_OPTIONS_VTABLE,
    .recovery = &VULKAN_DEVICE_RECOVERY_VTABLE,
    .culling_factory = &VULKAN_CULLING_FACTORY_VTABLE,
    .screenshot = &VULKAN_SCREENSHOT_CONTEXT_VTABLE,
};

const VULKAN_RHI_VTABLE = rhi.RHI.composeVTable(.{
    .init = initContext,
    .deinit = deinit,
}, VULKAN_RHI_INTERFACES);

fn beginPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    timing.beginPassTiming(ctx, pass_name);
}

fn endPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    timing.endPassTiming(ctx, pass_name);
}

fn getTimingResults(ctx_ptr: *anyopaque) rhi.GpuTimingResults {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing.timing_results;
}

fn isTimingEnabled(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing.timing_enabled;
}

fn setTimingEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.timing.timing_enabled = enabled;
}

fn processTimingResults(ctx: *VulkanContext) void {
    timing.processTimingResults(ctx);
}

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !rhi.RHI {
    return context_factory.createRHI(
        VulkanContext,
        allocator,
        window,
        render_device,
        shadow_resolution,
        msaa_samples,
        anisotropic_filtering,
        &VULKAN_RHI_VTABLE,
    );
}
