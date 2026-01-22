//! Integration smoke test for ZigCraft.
//!
//! Tests the full application lifecycle: launch, generate terrain, render a frame, and exit.
//! Requires a display server (use xvfb-run in CI).
//!
//! Run with: zig build test-integration
//! CI: xvfb-run -a zig build test-integration

const std = @import("std");
const testing = std.testing;

const App = @import("game/app.zig").App;

const WorldScreen = @import("game/screens/world.zig").WorldScreen;
const Screen = @import("game/screen.zig");
const rhi = @import("engine/graphics/rhi.zig");
const UISystem = @import("engine/ui/ui_system.zig").UISystem;
const c = @import("c.zig").c;

const EngineContext = Screen.EngineContext;
const IScreen = Screen.IScreen;

const UploadScreen = struct {
    context: EngineContext,
    buffer: rhi.BufferHandle,
    payload: [64]u8 = [_]u8{0} ** 64,
    tick: u8 = 0,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*UploadScreen {
        const upload_screen = try allocator.create(UploadScreen);
        const buffer = try context.rhi.createBuffer(upload_screen.payload.len, .vertex);
        upload_screen.* = .{ .context = context, .buffer = buffer };
        return upload_screen;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.context.rhi.destroyBuffer(self.buffer);
        self.context.allocator.destroy(self);
    }

    fn update(ptr: *anyopaque, _: f32) !void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.payload[0] = self.tick;
        self.tick +%= 1;
        try self.context.rhi.updateBuffer(self.buffer, 0, self.payload[0..]);
    }

    fn draw(_: *anyopaque, ui: *UISystem) !void {
        ui.begin();
        ui.end();
    }

    pub fn screen(self: *UploadScreen) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

test "smoke test: launch, generate, render, exit" {
    const test_allocator = testing.allocator;

    @import("engine/core/log.zig").log.min_level = .err;

    var app = App.init(test_allocator) catch |err| {
        if (err == error.WindowCreationFailed or err == error.SDLInitializationFailed) {
            std.debug.print("Skipping integration test: SDL/Vulkan initialization failed (likely no display or Vulkan driver)\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();

    const world_screen = try WorldScreen.init(test_allocator, app.engineContext(), 12345, 0);
    app.screen_manager.setScreen(world_screen.screen());

    try app.runSingleFrame();

    // The screen manager handles the screen transition in the next update/draw cycle
    // In our implementation, setScreen sets next_screen, and update() consumes it.

    try testing.expect(app.screen_manager.stack.items.len > 0);

    const stats = world_screen.session.world.getStats();

    try testing.expect(stats.chunks_loaded > 0);

    const upload_screen = try UploadScreen.init(test_allocator, app.engineContext());
    app.screen_manager.setScreen(upload_screen.screen());

    const frame_count = rhi.MAX_FRAMES_IN_FLIGHT + 2;
    for (0..frame_count) |_| {
        try app.runSingleFrame();
    }

    const resize_width: u32 = 1024;
    const resize_height: u32 = 720;
    app.window_manager.setSize(resize_width, resize_height);
    app.input.initWindowSize(app.window_manager.window);
    try app.runSingleFrame();

    var actual_w: c_int = 0;
    var actual_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(app.window_manager.window, &actual_w, &actual_h);
    const extent = app.rhi.context().getNativeSwapchainExtent();
    try testing.expectEqual(@as(u32, @intCast(actual_w)), extent[0]);
    try testing.expectEqual(@as(u32, @intCast(actual_h)), extent[1]);

    try testing.expectEqual(@as(u32, 0), app.rhi.getValidationErrorCount());
}
