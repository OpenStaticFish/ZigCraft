const std = @import("std");
const c = @import("c").c;
const post_process_system_pkg = @import("post_process_system.zig");
const log = @import("engine-core").log;
const PostProcessPushConstants = post_process_system_pkg.PostProcessPushConstants;
const fxaa_system_pkg = @import("fxaa_system.zig");
const FXAAPushConstants = fxaa_system_pkg.FXAAPushConstants;
const setup = @import("rhi_resource_setup.zig");
const screenshot = @import("screenshot.zig");
const final_composition = @import("final_composition.zig");
const render_state = @import("rhi_render_state.zig");
const frame_orchestration = @import("rhi_frame_orchestration.zig");

fn recordFinalComposedImage(ctx: anytype) void {
    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.swapchain.swapchain.images.items.len) {
        log.log.err("final composition: image index {} is out of range", .{image_index});
        ctx.runtime.final_composed.clear();
        return;
    }
    ctx.runtime.final_composed.set(
        ctx.swapchain.swapchain.images.items[image_index],
        image_index,
        final_composition.displayLayout(ctx.swapchain.skip_present),
    );
}

fn postProcessTargetsFXAA(ctx: anytype) bool {
    return ctx.fxaa.enabled and ctx.fxaa.post_process_to_fxaa_render_pass != null and ctx.fxaa.post_process_to_fxaa_framebuffer != null;
}

pub fn beginGPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress or ctx.runtime.g_pass_active) return;

    if (ctx.render_pass_manager.g_render_pass == null or ctx.render_pass_manager.g_framebuffer == null or ctx.pipeline_manager.g_pipeline == null) {
        log.log.warn("beginGPass: skipping - resources null (rp={}, fb={}, pipeline={})", .{ ctx.render_pass_manager.g_render_pass != null, ctx.render_pass_manager.g_framebuffer != null, ctx.pipeline_manager.g_pipeline != null });
        return;
    }

    if (ctx.gpass.g_pass_extent.width != ctx.swapchain.getExtent().width or ctx.gpass.g_pass_extent.height != ctx.swapchain.getExtent().height) {
        log.log.warn("beginGPass: size mismatch! G-pass={}x{}, swapchain={}x{} - recreating", .{ ctx.gpass.g_pass_extent.width, ctx.gpass.g_pass_extent.height, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height });
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
        setup.createGPassResources(ctx) catch |err| {
            log.log.errWithTrace("Failed to recreate G-Pass resources: {}", .{err});
            return;
        };
        setup.createSSAOResources(ctx) catch |err| {
            log.log.errWithTrace("Failed to recreate SSAO resources: {}", .{err});
            return;
        };
    }

    ensureNoRenderPassActiveInternal(ctx);

    ctx.runtime.g_pass_active = true;
    const current_frame = ctx.frames.current_frame;
    const command_buffer = ctx.frames.command_buffers[current_frame];

    if (command_buffer == null or ctx.pipeline_manager.pipeline_layout == null) {
        log.log.err("beginGPass: invalid command state (cb={}, layout={})", .{ command_buffer != null, ctx.pipeline_manager.pipeline_layout != null });
        return;
    }

    const g_extent = ctx.dynamic_resolution.getRenderExtent();

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.render_pass_manager.g_render_pass;
    render_pass_info.framebuffer = ctx.render_pass_manager.g_framebuffer;
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = g_extent;

    var clear_values: [3]c.VkClearValue = undefined;
    clear_values[0] = std.mem.zeroes(c.VkClearValue);
    clear_values[0].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[1] = std.mem.zeroes(c.VkClearValue);
    clear_values[1].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[2] = std.mem.zeroes(c.VkClearValue);
    clear_values[2].depthStencil = .{ .depth = 0.0, .stencil = 0 };
    render_pass_info.clearValueCount = 3;
    render_pass_info.pClearValues = &clear_values[0];

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(g_extent.width), .height = @floatFromInt(g_extent.height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = g_extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    if (render_state.prepareDrawDescriptors(ctx)) {
        const ds = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &ds, 0, null);
    }
}

pub fn endGPassInternal(ctx: anytype) void {
    if (!ctx.runtime.g_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.runtime.g_pass_active = false;
}

pub fn beginFXAAPassInternal(ctx: anytype) void {
    if (!ctx.fxaa.enabled) {
        return;
    }
    if (ctx.fxaa.pass_active) return;
    if (ctx.fxaa.pipeline == null) {
        return;
    }
    if (ctx.fxaa.render_pass == null) {
        return;
    }

    ensureNoRenderPassActiveInternal(ctx);

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.fxaa.framebuffers.items.len) {
        return;
    }

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();

    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = ctx.fxaa.render_pass;
    rp_begin.framebuffer = ctx.fxaa.framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    rp_begin.clearValueCount = 0;

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

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline);

    const frame = ctx.frames.current_frame;
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline_layout, 0, 1, &ctx.fxaa.descriptor_sets[frame], 0, null);

    const push = FXAAPushConstants{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(extent.width)), 1.0 / @as(f32, @floatFromInt(extent.height)) },
        .fxaa_span_max = 8.0,
        .fxaa_reduce_mul = 1.0 / 8.0,
    };
    c.vkCmdPushConstants(command_buffer, ctx.fxaa.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(FXAAPushConstants), &push);

    c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
    ctx.runtime.draw_call_count += 1;

    ctx.runtime.fxaa_ran_this_frame = true;
    ctx.fxaa.pass_active = true;
}

/// Begins an overlay pass on the already-composed display image. This state is
/// intentionally not FXAA state: UI may be submitted after the FXAA pass has
/// ended, and several UI begin/end pairs are valid in one frame.
pub fn beginUISwapchainPassInternal(ctx: anytype, clear_output: bool) void {
    if (!ctx.frames.frame_in_progress) {
        return;
    }
    if (ctx.ui.ui_swapchain_pass_active) return;
    if (ctx.render_pass_manager.ui_swapchain_render_pass == null) {
        return;
    }
    if (ctx.render_pass_manager.ui_swapchain_framebuffers.items.len == 0) {
        return;
    }

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.render_pass_manager.ui_swapchain_framebuffers.items.len) {
        return;
    }

    ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();
    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    const first_composition = clear_output or !ctx.runtime.final_composed.isCurrentImage(image_index);
    rp_begin.renderPass = if (first_composition) ctx.render_pass_manager.ui_swapchain_clear_render_pass.? else ctx.render_pass_manager.ui_swapchain_render_pass.?;
    rp_begin.framebuffer = ctx.render_pass_manager.ui_swapchain_framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    const clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    rp_begin.clearValueCount = if (first_composition) 1 else 0;
    rp_begin.pClearValues = if (first_composition) &clear_value else null;

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

    ctx.ui.ui_swapchain_pass_active = true;
    ctx.ui.ui_swapchain_clears_output = first_composition;
}

pub fn endFXAAPassInternal(ctx: anytype) void {
    if (!ctx.fxaa.pass_active) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);

    ctx.fxaa.pass_active = false;
    recordFinalComposedImage(ctx);
}

pub fn endUISwapchainPassInternal(ctx: anytype) void {
    if (!ctx.ui.ui_swapchain_pass_active) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.ui.ui_swapchain_pass_active = false;
    if (ctx.ui.ui_swapchain_clears_output) ctx.runtime.direct_ui_composed_this_frame = true;
    ctx.ui.ui_swapchain_clears_output = false;
    recordFinalComposedImage(ctx);
}

pub fn beginMainPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.swapchain.getExtent().width == 0 or ctx.swapchain.getExtent().height == 0) return;

    if (ctx.render_pass_manager.hdr_render_pass == null) {
        ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), ctx.options.msaa_samples) catch |err| {
            log.log.errWithTrace("beginMainPass: failed to recreate render pass: {}", .{err});
            return;
        };
    }
    if (ctx.render_pass_manager.main_framebuffer == null) {
        setup.createMainFramebuffers(ctx) catch |err| {
            log.log.errWithTrace("beginMainPass: failed to recreate framebuffer: {}", .{err});
            return;
        };
    }
    if (ctx.render_pass_manager.main_framebuffer == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.runtime.main_pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        if (ctx.hdr.hdr_image != null) {
            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = ctx.hdr.hdr_image;
            barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

            // HDR is sampled by fragment-stage bloom/TAA/post-processing today.
            c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        ctx.draw.terrain_pipeline_bound = false;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.render_pass_manager.hdr_render_pass;
        render_pass_info.framebuffer = ctx.render_pass_manager.main_framebuffer;
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.dynamic_resolution.getRenderExtent();

        var clear_values: [2]c.VkClearValue = undefined;
        clear_values[0] = std.mem.zeroes(c.VkClearValue);
        clear_values[0].color = .{ .float32 = ctx.runtime.clear_color };
        clear_values[1] = std.mem.zeroes(c.VkClearValue);
        clear_values[1].depthStencil = .{ .depth = 0.0, .stencil = 0 };
        render_pass_info.clearValueCount = 2;
        render_pass_info.pClearValues = &clear_values[0];

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.runtime.main_pass_active = true;
    }

    const main_extent = ctx.dynamic_resolution.getRenderExtent();

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(main_extent.width);
    viewport.height = @floatFromInt(main_extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = main_extent;
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

pub fn endMainPassInternal(ctx: anytype) void {
    if (!ctx.runtime.main_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.runtime.main_pass_active = false;
}

pub fn beginPostProcessPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) {
        return;
    }
    if (ctx.render_pass_manager.post_process_framebuffers.items.len == 0) {
        return;
    }
    if (ctx.frames.current_image_index >= ctx.render_pass_manager.post_process_framebuffers.items.len) {
        return;
    }

    if (ctx.post_process.pipeline == null) {
        return;
    }

    const pp_ds = ctx.post_process.descriptor_sets[ctx.frames.current_frame];
    if (pp_ds == null) {
        return;
    }

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.post_process.pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        const use_fxaa_output = postProcessTargetsFXAA(ctx);

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;

        if (use_fxaa_output) {
            render_pass_info.renderPass = ctx.fxaa.post_process_to_fxaa_render_pass;
            render_pass_info.framebuffer = ctx.fxaa.post_process_to_fxaa_framebuffer;
        } else {
            render_pass_info.renderPass = ctx.render_pass_manager.post_process_render_pass;
            render_pass_info.framebuffer = ctx.render_pass_manager.post_process_framebuffers.items[ctx.frames.current_image_index];
        }

        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.color = .{ .float32 = .{ 0, 0, 0, 1 } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.post_process.pass_active = true;
        ctx.runtime.post_process_ran_this_frame = true;

        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process.pipeline);

        var source_view = ctx.hdr.hdr_view;
        var source_sampler = ctx.post_process.sampler;
        if (ctx.dynamic_resolution.isActive() and ctx.taa.ran_this_frame and ctx.dynamic_resolution.upscale_view != null) {
            source_view = ctx.dynamic_resolution.upscale_view;
        } else if (ctx.taa.ran_this_frame and ctx.taa.output_texture != 0) {
            if (ctx.resources.textures.get(ctx.taa.output_texture)) |tex| {
                source_view = tex.view;
                source_sampler = tex.sampler;
            }
        }
        ctx.post_process.updateSourceDescriptor(ctx.vulkan_device.vk_device, ctx.frames.current_frame, source_view, source_sampler);

        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process.pipeline_layout, 0, 1, &pp_ds, 0, null);

        const push = PostProcessPushConstants{
            .bloom_enabled = if (ctx.bloom.enabled) 1.0 else 0.0,
            .bloom_intensity = ctx.bloom.intensity,
            .vignette_intensity = if (ctx.post_process_state.vignette_enabled) ctx.post_process_state.vignette_intensity else 0.0,
            .film_grain_intensity = if (ctx.post_process_state.film_grain_enabled) ctx.post_process_state.film_grain_intensity else 0.0,
            .color_grading_enabled = if (ctx.post_process_state.color_grading_enabled) 1.0 else 0.0,
            .color_grading_intensity = ctx.post_process_state.color_grading_intensity,
        };
        c.vkCmdPushConstants(command_buffer, ctx.post_process.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostProcessPushConstants), &push);

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

pub fn endPostProcessPassInternal(ctx: anytype) void {
    if (!ctx.post_process.pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.post_process.pass_active = false;
    if (!postProcessTargetsFXAA(ctx)) recordFinalComposedImage(ctx);
}

pub fn ensureNoRenderPassActiveInternal(ctx: anytype) void {
    if (ctx.runtime.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        ctx.shadow_system.endPass(command_buffer);
    }
    if (ctx.runtime.g_pass_active) endGPassInternal(ctx);
    if (ctx.post_process.pass_active) endPostProcessPassInternal(ctx);
    if (ctx.ui.ui_swapchain_pass_active) endUISwapchainPassInternal(ctx);
}

pub fn endFrame(ctx: anytype) void {
    if (ctx.frames.terminal_failure or !ctx.frames.frame_in_progress) return;

    if (ctx.runtime.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        ctx.shadow_system.endPass(command_buffer);
    }
    // Defensively close a caller-owned overlay before opening a full-screen
    // replacement pass. Normal UI submission closes it in end2DPass.
    if (ctx.ui.ui_swapchain_pass_active) endUISwapchainPassInternal(ctx);

    if (ctx.runtime.draw_call_count > 0 and !ctx.runtime.direct_ui_composed_this_frame and !ctx.runtime.post_process_ran_this_frame and ctx.render_pass_manager.post_process_framebuffers.items.len > 0 and ctx.frames.current_image_index < ctx.render_pass_manager.post_process_framebuffers.items.len) {
        beginPostProcessPassInternal(ctx);
        if (ctx.post_process.pass_active) {
            const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
            c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
            ctx.runtime.draw_call_count += 1;
        }
    }
    if (ctx.post_process.pass_active) endPostProcessPassInternal(ctx);

    if (ctx.fxaa.enabled and ctx.runtime.post_process_ran_this_frame and !ctx.runtime.fxaa_ran_this_frame) {
        beginFXAAPassInternal(ctx);
    }
    if (ctx.fxaa.pass_active) endFXAAPassInternal(ctx);

    // Even a frame with no draws must initialize the acquired image before
    // presentation. Use the same clear-only path as a scene-less UI frame.
    if (!ctx.runtime.final_composed.isCurrentImage(ctx.frames.current_image_index)) {
        beginUISwapchainPassInternal(ctx, true);
        endUISwapchainPassInternal(ctx);
    }

    // The UI path can trigger post-processing at endFrame, so append the
    // readback only after every final-color pass has completed.
    screenshot.recordCapture(ctx);

    const transfer_cb = ctx.resources.getTransferCommandBuffer();

    if (!ctx.resources.transfer.is_dedicated) {
        if (transfer_cb) |cb| {
            ctx.resources.transfer.recordPendingCopies(cb);

            var barrier = std.mem.zeroes(c.VkMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = ctx.resources.transfer.getPendingDstAccessMask();

            c.vkCmdPipelineBarrier(
                cb,
                c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                1,
                &barrier,
                0,
                null,
                0,
                null,
            );
        }
    }

    submitFrame(ctx, transfer_cb) catch |err| {
        log.log.errWithTrace("endFrame failed: {}; frame slot quarantined, restart required", .{err});
        return;
    };

    if (ctx.screenshot_capture.staging != null) {
        if (!screenshot.completeCapture(ctx)) {
            log.log.err("SCREENSHOT: Failed to encode final composed frame", .{});
        }
    }

    if (transfer_cb != null) {
        ctx.resources.resetTransferState();
    }

    if (ctx.render_device) |device| {
        device.setStats(ctx.resources.stats());
    }

    ctx.runtime.frame_index += 1;
}

pub fn submitFrame(ctx: anytype, transfer_cb: ?c.VkCommandBuffer) !void {
    if (ctx.frames.terminal_failure) return error.GpuLost;
    const faults_before = ctx.vulkan_device.fault_count;
    errdefer {
        ctx.frames.failFrame();
        ctx.runtime.gpu_fault_detected = true;
        // endFrame is void at the RHI boundary. Notify the app's existing fault
        // query even for non-device-loss errors, without counting device loss twice.
        if (ctx.vulkan_device.fault_count == faults_before) ctx.vulkan_device.fault_count +|= 1;
        frame_orchestration.invalidateAbortedTemporalState(ctx);
        ctx.runtime.final_composed.clear();
        // Do not discard screenshot staging, reset transfer state, or recycle
        // descriptors/fences here: submission or presentation may be pending.
    }
    if (ctx.resources.transfer.is_dedicated and transfer_cb != null) {
        try ctx.resources.submitTransfer();
    }
    const transfer_sem = ctx.resources.getTransferSemaphore();
    try ctx.frames.endFrame(&ctx.swapchain, transfer_cb, transfer_sem);
}
