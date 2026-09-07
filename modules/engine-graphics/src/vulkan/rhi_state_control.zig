const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const frame_orchestration = @import("rhi_frame_orchestration.zig");
const log = @import("engine-core").log;

pub fn waitIdle(ctx: anytype) void {
    if (!ctx.frames.dry_run and ctx.vulkan_device.vk_device != null) {
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    }
}

pub fn setTextureUniforms(ctx: anytype, texture_enabled: bool, shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle) void {
    ctx.options.textures_enabled = texture_enabled;
    ctx.shadow_runtime.shadow_map_handles = shadow_map_handles;
    for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.draw.descriptors_dirty[i] = true;
    }
    ctx.draw.descriptors_updated = false;
}

pub fn setViewport(ctx: anytype, width: u32, height: u32) void {
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

pub fn requestSwapchainRecreate(ctx: anytype) void {
    ctx.runtime.framebuffer_resized = true;
    ctx.runtime.swapchain_recreate_failed = false;
    ctx.swapchain.framebuffer_resized = true;
}

pub fn getAllocator(ctx: anytype) std.mem.Allocator {
    return ctx.allocator;
}

pub fn getFrameIndex(ctx: anytype) usize {
    return @intCast(ctx.frames.current_frame);
}

pub fn supportsIndirectFirstInstance(ctx: anytype) bool {
    return ctx.vulkan_device.draw_indirect_first_instance;
}

pub fn supportsIndirectCount(ctx: anytype) bool {
    return ctx.vulkan_device.draw_indirect_count;
}

pub fn recover(ctx: anytype) !void {
    if (!ctx.runtime.gpu_fault_detected) return;

    if (ctx.vulkan_device.recovery_count >= ctx.vulkan_device.max_recovery_attempts) {
        log.log.err("RHI: Max recovery attempts ({d}) exceeded. GPU is unstable.", .{ctx.vulkan_device.max_recovery_attempts});
        return error.GpuLost;
    }

    ctx.vulkan_device.recovery_count += 1;
    log.log.info("RHI: Attempting GPU recovery (Attempt {d}/{d})...", .{ ctx.vulkan_device.recovery_count, ctx.vulkan_device.max_recovery_attempts });

    if (ctx.frames.frame_in_progress) {
        ctx.frames.abortFrame();
    }
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.g_pass_active = false;
    ctx.runtime.ssao_pass_active = false;
    ctx.runtime.final_composed.clear();
    ctx.ui.ui_swapchain_pass_active = false;
    ctx.ui.ui_swapchain_clears_output = false;
    ctx.runtime.recovering = true;
    defer ctx.runtime.recovering = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;

    const idle_result = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
    if (idle_result != c.VK_SUCCESS) {
        // VK_ERROR_DEVICE_LOST is terminal for this logical device. Recreating
        // only swapchain resources on it is invalid and previously produced a
        // misleading second "recovery failed" error. Full device/resource
        // reconstruction must happen through a clean application restart.
        log.log.err("RHI: Lost logical device cannot be recovered in place (vkDeviceWaitIdle={d}). Restart required.", .{idle_result});
        ctx.vulkan_device.recovery_fail_count += 1;
        ctx.runtime.gpu_fault_detected = true;
        return error.GpuLost;
    }

    ctx.runtime.gpu_fault_detected = false;
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    frame_orchestration.recreateSwapchainInternal(ctx);

    if (c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device) != c.VK_SUCCESS) {
        log.log.err("RHI: Device unresponsive after recovery. Recovery failed.", .{});
        ctx.vulkan_device.recovery_fail_count += 1;
        ctx.runtime.gpu_fault_detected = true;
        return error.GpuLost;
    }

    ctx.vulkan_device.recovery_success_count += 1;
    log.log.info("RHI: Recovery step complete. If issues persist, please restart.", .{});
}

pub fn setWireframe(ctx: anytype, enabled: bool) void {
    if (ctx.options.wireframe_enabled != enabled) {
        ctx.options.wireframe_enabled = enabled;
        ctx.draw.terrain_pipeline_bound = false;
    }
}

pub fn setTexturesEnabled(ctx: anytype, enabled: bool) void {
    ctx.options.textures_enabled = enabled;
}

pub fn setDebugShadowView(ctx: anytype, enabled: bool) void {
    ctx.options.debug_shadows_active = enabled;
}

pub fn setShadowDebugChannel(ctx: anytype, channel: u32) void {
    ctx.options.shadow_debug_channel = channel;
}

pub fn setVSync(ctx: anytype, enabled: bool) void {
    if (ctx.options.vsync_enabled == enabled) return;

    ctx.options.vsync_enabled = enabled;

    var mode_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.vulkan_device.physical_device, ctx.vulkan_device.surface, &mode_count, null);

    if (mode_count == 0) return;

    var modes: [8]c.VkPresentModeKHR = undefined;
    var actual_count: u32 = @min(mode_count, 8);
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ctx.vulkan_device.physical_device, ctx.vulkan_device.surface, &actual_count, &modes);

    if (enabled) {
        ctx.options.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
    } else {
        ctx.options.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;
        for (modes[0..actual_count]) |mode| {
            if (mode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
                ctx.options.present_mode = c.VK_PRESENT_MODE_IMMEDIATE_KHR;
                break;
            } else if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                ctx.options.present_mode = c.VK_PRESENT_MODE_MAILBOX_KHR;
            }
        }
    }

    ctx.runtime.framebuffer_resized = true;
    ctx.runtime.swapchain_recreate_failed = false;

    // Propagate the chosen mode into the swapchain so the next recreate honors
    // it. Without this, VulkanSwapchain.createSwapchain() would keep using the
    // mode captured at init time (the bug that made setVSync a no-op).
    ctx.swapchain.setPresentMode(ctx.options.present_mode);

    const mode_name: []const u8 = switch (ctx.options.present_mode) {
        c.VK_PRESENT_MODE_IMMEDIATE_KHR => "IMMEDIATE (VSync OFF)",
        c.VK_PRESENT_MODE_MAILBOX_KHR => "MAILBOX (Triple Buffer)",
        c.VK_PRESENT_MODE_FIFO_KHR => "FIFO (VSync ON)",
        c.VK_PRESENT_MODE_FIFO_RELAXED_KHR => "FIFO_RELAXED",
        else => "UNKNOWN",
    };
    log.log.info("Vulkan present mode: {s}", .{mode_name});
}

pub fn setAnisotropicFiltering(ctx: anytype, level: u8) void {
    if (ctx.options.anisotropic_filtering == level) return;
    ctx.options.anisotropic_filtering = level;
}

pub fn setVolumetricDensity(ctx: anytype, density: f32) void {
    _ = ctx;
    _ = density;
}

pub fn setMSAA(ctx: anytype, samples: u8) void {
    const clamped = @min(samples, ctx.vulkan_device.max_msaa_samples);
    if (ctx.options.msaa_samples == clamped) return;

    ctx.options.msaa_samples = clamped;
    ctx.swapchain.msaa_samples = clamped;
    ctx.runtime.framebuffer_resized = true;
    ctx.runtime.swapchain_recreate_failed = false;
    ctx.runtime.pipeline_rebuild_needed = true;
    log.log.info("Vulkan MSAA set to {}x (pending swapchain recreation)", .{clamped});
}

pub fn setShadowResolution(ctx: anytype, requested: u32) void {
    if (requested == 0) return;

    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(ctx.vulkan_device.physical_device, &properties);
    const resolution = @min(requested, properties.limits.maxImageDimension2D);
    if (resolution == ctx.shadow_runtime.shadow_resolution and ctx.shadow_runtime.pending_shadow_resolution == null) return;
    ctx.shadow_runtime.pending_shadow_resolution = resolution;
}

pub fn getMaxAnisotropy(ctx: anytype) u8 {
    return @intFromFloat(@min(ctx.vulkan_device.max_anisotropy, 16.0));
}

pub fn getMaxMSAASamples(ctx: anytype) u8 {
    return ctx.vulkan_device.max_msaa_samples;
}

pub fn getFaultCount(ctx: anytype) u32 {
    return ctx.vulkan_device.fault_count;
}

pub fn getValidationErrorCount(ctx: anytype) u32 {
    return ctx.vulkan_device.validation_error_count.load(.monotonic);
}
