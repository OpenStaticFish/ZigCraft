const std = @import("std");
const sync = @import("sync");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const rhi_state_control = @import("rhi_state_control.zig");

// Mock context structures for testing without GPU
// These are minimal mocks that only implement the fields needed for specific tests

const MockOptions = struct {
    textures_enabled: bool = false,
    wireframe_enabled: bool = false,
    debug_shadows_active: bool = false,
    shadow_debug_channel: u32 = 0,
    anisotropic_filtering: u8 = 0,
    vsync_enabled: bool = true,
    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,
    msaa_samples: u8 = 1,
};

const MockDraw = struct {
    descriptors_updated: bool = true,
    descriptors_dirty: [rhi.MAX_FRAMES_IN_FLIGHT]bool = .{false} ** rhi.MAX_FRAMES_IN_FLIGHT,
    terrain_pipeline_bound: bool = true,
    bound_texture: u32 = 0,
};

const MockShadowRuntime = struct {
    shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{0} ** rhi.SHADOW_CASCADE_COUNT,
};

const MockFrames = struct {
    current_frame: u32 = 0,
    frame_in_progress: bool = false,
    terminal_failure: bool = false,
    dry_run: bool = true,
    command_buffers: [3]c.VkCommandBuffer = .{ null, null, null },

    pub fn abortFrame(_: *MockFrames) void {
        // No-op for testing
    }
};

const MockRuntime = struct {
    gpu_fault_detected: bool = false,
    framebuffer_resized: bool = false,
    pipeline_rebuild_needed: bool = false,
    swapchain_recreate_failed: bool = false,
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,
    recovering: bool = false,
};

const MockShadowSystem = struct {
    pass_active: bool = false,
};

const MockSwapchain = struct {
    skip_present: bool = true,
    msaa_samples: u8 = 1,
    framebuffer_resized: bool = false,

    pub fn getExtent(_: MockSwapchain) c.VkExtent2D {
        return .{ .width = 1920, .height = 1080 };
    }

    pub fn setPresentMode(_: *MockSwapchain, _: c.VkPresentModeKHR) void {
        // No-op for testing
    }
};

const MockVulkanDevice = struct {
    draw_indirect_first_instance: bool = false,
    max_anisotropy: f32 = 16.0,
    max_msaa_samples: u8 = 8,
    fault_count: u32 = 0,
    validation_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    recovery_count: u32 = 0,
    max_recovery_attempts: u32 = 5,
    recovery_success_count: u32 = 0,
    recovery_fail_count: u32 = 0,
    vk_device: c.VkDevice = null,
    physical_device: c.VkPhysicalDevice = null,
    surface: c.VkSurfaceKHR = null,
};

// Minimal context for simple getter/setter tests
const MockSimpleContext = struct {
    allocator: std.mem.Allocator,
    options: MockOptions = .{},
    draw: MockDraw = .{},
    frames: MockFrames = .{},
    runtime: MockRuntime = .{},
    swapchain: MockSwapchain = .{},
    vulkan_device: MockVulkanDevice = .{},
    mutex: sync.Mutex = .{},
    shadow_system: MockShadowSystem = .{},
    shadow_runtime: MockShadowRuntime = .{},
    window: ?*c.SDL_Window = null,
};

// ============================================================================
// Simple Getter Tests
// ============================================================================

test "rhi_state_control.getAllocator returns context allocator" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    const allocator = rhi_state_control.getAllocator(&ctx);
    try testing.expectEqual(testing.allocator, allocator);
}

test "rhi_state_control.getFrameIndex returns current frame" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    // Default frame index
    try testing.expectEqual(@as(usize, 0), rhi_state_control.getFrameIndex(&ctx));

    // After changing frame
    ctx.frames.current_frame = 2;
    try testing.expectEqual(@as(usize, 2), rhi_state_control.getFrameIndex(&ctx));
}

test "rhi_state_control.supportsIndirectFirstInstance returns feature flag" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    // Default false
    try testing.expect(!rhi_state_control.supportsIndirectFirstInstance(&ctx));

    // Enable feature
    ctx.vulkan_device.draw_indirect_first_instance = true;
    try testing.expect(rhi_state_control.supportsIndirectFirstInstance(&ctx));
}

test "rhi_state_control.getMaxAnisotropy clamps to 16" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    // Default 16.0 should return 16
    ctx.vulkan_device.max_anisotropy = 16.0;
    try testing.expectEqual(@as(u8, 16), rhi_state_control.getMaxAnisotropy(&ctx));

    // Higher values clamped to 16
    ctx.vulkan_device.max_anisotropy = 32.0;
    try testing.expectEqual(@as(u8, 16), rhi_state_control.getMaxAnisotropy(&ctx));

    // Lower values preserved
    ctx.vulkan_device.max_anisotropy = 8.0;
    try testing.expectEqual(@as(u8, 8), rhi_state_control.getMaxAnisotropy(&ctx));
}

test "rhi_state_control.getMaxMSAASamples returns device limit" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    ctx.vulkan_device.max_msaa_samples = 4;
    try testing.expectEqual(@as(u8, 4), rhi_state_control.getMaxMSAASamples(&ctx));

    ctx.vulkan_device.max_msaa_samples = 8;
    try testing.expectEqual(@as(u8, 8), rhi_state_control.getMaxMSAASamples(&ctx));
}

test "rhi_state_control.getFaultCount returns device fault count" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    // Default 0
    try testing.expectEqual(@as(u32, 0), rhi_state_control.getFaultCount(&ctx));

    // After faults
    ctx.vulkan_device.fault_count = 3;
    try testing.expectEqual(@as(u32, 3), rhi_state_control.getFaultCount(&ctx));
}

test "rhi_state_control.getValidationErrorCount atomic load" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    // Default 0
    try testing.expectEqual(@as(u32, 0), rhi_state_control.getValidationErrorCount(&ctx));

    // After errors
    _ = ctx.vulkan_device.validation_error_count.fetchAdd(5, .monotonic);
    try testing.expectEqual(@as(u32, 5), rhi_state_control.getValidationErrorCount(&ctx));
}

// ============================================================================
// State Setter Tests
// ============================================================================

test "rhi_state_control.setTextureUniforms updates state and marks dirty" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.textures_enabled = false;
    ctx.draw.descriptors_updated = true;
    const handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{ 11, 12, 13, 14 };

    rhi_state_control.setTextureUniforms(&ctx, true, handles);

    try testing.expect(ctx.options.textures_enabled);
    try testing.expect(!ctx.draw.descriptors_updated);
    try testing.expectEqual(handles, ctx.shadow_runtime.shadow_map_handles);
    for (ctx.draw.descriptors_dirty) |dirty| {
        try testing.expect(dirty);
    }
}

test "rhi_state_control.setWireframe updates state and invalidates pipeline" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.wireframe_enabled = false;
    ctx.draw.terrain_pipeline_bound = true;

    rhi_state_control.setWireframe(&ctx, true);

    try testing.expect(ctx.options.wireframe_enabled);
    try testing.expect(!ctx.draw.terrain_pipeline_bound);
}

test "rhi_state_control.setWireframe no-op when unchanged" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.wireframe_enabled = true;
    ctx.draw.terrain_pipeline_bound = true;

    rhi_state_control.setWireframe(&ctx, true);

    // Pipeline should remain bound since no change occurred
    try testing.expect(ctx.draw.terrain_pipeline_bound);
}

test "rhi_state_control.setTexturesEnabled updates flag" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    ctx.options.textures_enabled = false;
    rhi_state_control.setTexturesEnabled(&ctx, true);
    try testing.expect(ctx.options.textures_enabled);

    rhi_state_control.setTexturesEnabled(&ctx, false);
    try testing.expect(!ctx.options.textures_enabled);
}

test "rhi_state_control.setDebugShadowView updates flag" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    ctx.options.debug_shadows_active = false;
    rhi_state_control.setDebugShadowView(&ctx, true);
    try testing.expect(ctx.options.debug_shadows_active);

    rhi_state_control.setDebugShadowView(&ctx, false);
    try testing.expect(!ctx.options.debug_shadows_active);
}

test "rhi_state_control.setShadowDebugChannel updates channel" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    rhi_state_control.setShadowDebugChannel(&ctx, 2);
    try testing.expectEqual(@as(u32, 2), ctx.options.shadow_debug_channel);

    rhi_state_control.setShadowDebugChannel(&ctx, 0);
    try testing.expectEqual(@as(u32, 0), ctx.options.shadow_debug_channel);
}

test "rhi_state_control.setAnisotropicFiltering no-op when unchanged" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.anisotropic_filtering = 8;

    rhi_state_control.setAnisotropicFiltering(&ctx, 8);

    // Should remain 8
    try testing.expectEqual(@as(u8, 8), ctx.options.anisotropic_filtering);
}

test "rhi_state_control.setAnisotropicFiltering updates when changed" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.anisotropic_filtering = 4;

    rhi_state_control.setAnisotropicFiltering(&ctx, 16);

    try testing.expectEqual(@as(u8, 16), ctx.options.anisotropic_filtering);
}

test "rhi_state_control.requestSwapchainRecreate sets both resize flags" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };

    try testing.expect(!ctx.runtime.framebuffer_resized);
    try testing.expect(!ctx.swapchain.framebuffer_resized);

    rhi_state_control.requestSwapchainRecreate(&ctx);

    try testing.expect(ctx.runtime.framebuffer_resized);
    try testing.expect(ctx.swapchain.framebuffer_resized);
}

test "rhi_state_control.requestSwapchainRecreate clears prior recreate failure" {
    // After a failed recreation, a fresh resize request must clear the failed
    // flag so beginFrame is allowed to attempt recreation again (issue #725).
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.runtime.swapchain_recreate_failed = true;

    rhi_state_control.requestSwapchainRecreate(&ctx);

    try testing.expect(!ctx.runtime.swapchain_recreate_failed);
    try testing.expect(ctx.runtime.framebuffer_resized);
    try testing.expect(ctx.swapchain.framebuffer_resized);
}

// ============================================================================
// MSAA State Tests
// ============================================================================

test "rhi_state_control.setMSAA clamps to max samples" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.vulkan_device.max_msaa_samples = 4;
    ctx.options.msaa_samples = 1;
    ctx.swapchain.msaa_samples = 1;
    ctx.runtime.swapchain_recreate_failed = true;

    rhi_state_control.setMSAA(&ctx, 8);

    // Should clamp to max (4)
    try testing.expectEqual(@as(u8, 4), ctx.options.msaa_samples);
    try testing.expectEqual(@as(u8, 4), ctx.swapchain.msaa_samples);
    try testing.expect(ctx.runtime.framebuffer_resized);
    try testing.expect(ctx.runtime.pipeline_rebuild_needed);
    // A settings change is a fresh recreate request, so it must clear a prior failure.
    try testing.expect(!ctx.runtime.swapchain_recreate_failed);
}

test "rhi_state_control.setMSAA no-op when unchanged" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.vulkan_device.max_msaa_samples = 8;
    ctx.options.msaa_samples = 4;

    rhi_state_control.setMSAA(&ctx, 4);

    // Should not set resized/rebuild flags
    try testing.expect(!ctx.runtime.framebuffer_resized);
    try testing.expect(!ctx.runtime.pipeline_rebuild_needed);
}

test "rhi_state_control.setMSAA respects device limits" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.vulkan_device.max_msaa_samples = 2;

    rhi_state_control.setMSAA(&ctx, 8);

    // Should clamp to 2x
    try testing.expectEqual(@as(u8, 2), ctx.options.msaa_samples);
}

// ============================================================================
// Wait Idle Tests
// ============================================================================

test "rhi_state_control.waitIdle early exit in dry run mode" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.frames.dry_run = true;
    ctx.vulkan_device.vk_device = @ptrFromInt(0xDEAD);

    rhi_state_control.waitIdle(&ctx);

    try testing.expect(ctx.frames.dry_run);
    try testing.expectEqual(@as(u32, 0), ctx.vulkan_device.fault_count);
}

test "rhi_state_control.waitIdle early exit with null device" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.frames.dry_run = false;
    ctx.vulkan_device.vk_device = null;

    rhi_state_control.waitIdle(&ctx);

    try testing.expect(!ctx.frames.dry_run);
    try testing.expect(ctx.vulkan_device.vk_device == null);
}

// ============================================================================
// VSync State Machine Tests
// ============================================================================

test "rhi_state_control.setVSync no-op when unchanged" {
    var ctx = MockSimpleContext{ .allocator = testing.allocator };
    ctx.options.vsync_enabled = true;
    ctx.options.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;

    rhi_state_control.setVSync(&ctx, true);

    // Should not query present modes or change anything
    try testing.expect(ctx.options.present_mode == c.VK_PRESENT_MODE_FIFO_KHR);
}

// Note: setVSync when changed cannot be tested without a real GPU
// because it calls vkGetPhysicalDeviceSurfacePresentModesKHR

// ============================================================================
// Recovery State Machine Tests
// ============================================================================
// Note: recover() cannot be tested without a real GPU because it calls
// vkDeviceWaitIdle and frame_orchestration.recreateSwapchainInternal which
// require valid Vulkan device and swapchain objects. The mock structures
// (MockFrames.abortFrame, MockDraw.bound_texture, MockRuntime pass flags,
// MockShadowSystem.pass_active) are in place to support future testing
// when a full mock context is available.
