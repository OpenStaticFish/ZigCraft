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

test "smoke test: launch, generate, render, exit" {
    const test_allocator = testing.allocator;

    var app = App.init(test_allocator) catch |err| {
        if (err == error.WindowCreationFailed or err == error.SDLInitializationFailed) {
            std.debug.print("Skipping integration test: SDL/Vulkan initialization failed (likely no display or Vulkan driver)\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();

    const world_screen = try WorldScreen.init(test_allocator, app.engineContext(), 12345);
    app.screen_manager.setScreen(world_screen.screen());

    try app.runSingleFrame();

    // The screen manager handles the screen transition in the next update/draw cycle
    // In our implementation, setScreen sets next_screen, and update() consumes it.

    try testing.expect(app.screen_manager.stack.items.len > 0);

    const stats = world_screen.session.world.getStats();

    try testing.expect(stats.chunks_loaded > 0);
}
