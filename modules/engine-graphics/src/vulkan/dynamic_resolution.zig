const std = @import("std");
const c = @import("c").c;

const ROLLING_WINDOW_SIZE = 8;
const ACTIVE_THRESHOLD = 0.999;

pub const DynamicResolutionState = struct {
    enabled: bool = false,
    min_scale: f32 = 0.5,
    max_scale: f32 = 1.0,
    target_fps: u32 = 60,
    current_scale: f32 = 1.0,
    render_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    frame_times: [ROLLING_WINDOW_SIZE]f32 = .{0.0} ** ROLLING_WINDOW_SIZE,
    frame_time_index: usize = 0,
    frame_time_count: usize = 0,
    rolling_avg_ms: f32 = 0.0,

    upscale_image: c.VkImage = null,
    upscale_memory: c.VkDeviceMemory = null,
    upscale_view: c.VkImageView = null,
    upscale_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    pub fn update(self: *DynamicResolutionState, gpu_time_ms: f32) void {
        if (!self.enabled) {
            self.current_scale = 1.0;
            self.render_extent = self.swapchain_extent;
            return;
        }

        if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
            self.render_extent = .{ .width = 0, .height = 0 };
            return;
        }
        if (!std.math.isFinite(gpu_time_ms) or gpu_time_ms <= 0.0) {
            self.computeRenderExtent();
            return;
        }

        const min_scale = @min(self.min_scale, self.max_scale);
        const max_scale = @max(self.min_scale, self.max_scale);

        self.frame_times[self.frame_time_index] = gpu_time_ms;
        self.frame_time_index = (self.frame_time_index + 1) % ROLLING_WINDOW_SIZE;
        if (self.frame_time_count < ROLLING_WINDOW_SIZE) {
            self.frame_time_count += 1;
        }

        var sum: f32 = 0.0;
        var count: usize = 0;
        for (self.frame_times) |t| {
            if (t > 0.0) {
                sum += t;
                count += 1;
            }
        }
        self.rolling_avg_ms = if (count > 0) sum / @as(f32, @floatFromInt(count)) else 0.0;

        if (self.frame_time_count < 4) {
            self.computeRenderExtent();
            return;
        }

        const target_ms = 1000.0 / @as(f32, @floatFromInt(@max(self.target_fps, 1)));

        if (self.rolling_avg_ms > target_ms * 1.1) {
            self.current_scale = @max(self.current_scale - 0.02, min_scale);
        } else if (self.rolling_avg_ms < target_ms * 0.8) {
            self.current_scale = @min(self.current_scale + 0.01, max_scale);
        }

        self.current_scale = std.math.clamp(self.current_scale, min_scale, max_scale);

        self.computeRenderExtent();
    }

    fn computeRenderExtent(self: *DynamicResolutionState) void {
        if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) {
            self.render_extent = .{ .width = 0, .height = 0 };
            return;
        }
        const w = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(self.swapchain_extent.width)) * self.current_scale)));
        const h = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(self.swapchain_extent.height)) * self.current_scale)));
        self.render_extent = .{
            .width = @max(w, 1),
            .height = @max(h, 1),
        };
    }

    pub fn setSwapchainExtent(self: *DynamicResolutionState, extent: c.VkExtent2D) void {
        self.swapchain_extent = extent;
        if (!self.enabled) {
            self.render_extent = extent;
            self.current_scale = 1.0;
        } else {
            self.computeRenderExtent();
        }
    }

    pub fn isActive(self: *const DynamicResolutionState) bool {
        return self.enabled and self.current_scale < ACTIVE_THRESHOLD and self.render_extent.width > 0 and self.render_extent.height > 0;
    }

    pub fn getRenderExtent(self: *const DynamicResolutionState) c.VkExtent2D {
        if (self.enabled) {
            return self.render_extent;
        }
        return self.swapchain_extent;
    }
};

test "DynamicResolutionState scales smoothly and clamps bounds" {
    var state = DynamicResolutionState{};
    state.enabled = true;
    state.min_scale = 0.5;
    state.max_scale = 1.0;
    state.target_fps = 60;
    state.setSwapchainExtent(.{ .width = 1920, .height = 1080 });

    state.update(25.0);
    try std.testing.expectEqual(@as(f32, 1.0), state.current_scale);
    try std.testing.expectEqual(@as(u32, 1920), state.getRenderExtent().width);

    for (0..4) |_| state.update(40.0);
    try std.testing.expect(state.current_scale < 1.0);
    try std.testing.expect(state.isActive());

    state.min_scale = 0.9;
    state.max_scale = 0.6;
    state.update(100.0);
    try std.testing.expect(state.current_scale >= 0.6);
    try std.testing.expect(state.current_scale <= 0.9);
}

test "DynamicResolutionState disables cleanly" {
    var state = DynamicResolutionState{};
    state.enabled = false;
    state.setSwapchainExtent(.{ .width = 1280, .height = 720 });
    state.update(50.0);

    try std.testing.expectEqual(@as(f32, 1.0), state.current_scale);
    try std.testing.expect(!state.isActive());
    try std.testing.expectEqual(@as(u32, 1280), state.getRenderExtent().width);
    try std.testing.expectEqual(@as(u32, 720), state.getRenderExtent().height);
}
