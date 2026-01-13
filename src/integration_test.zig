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

    app.app_state = .world;
    app.pending_new_world_seed = 12345;

    try app.runSingleFrame();

    try testing.expect(app.game_session != null);
    const session = app.game_session.?;
    const stats = session.world.getStats();
    try testing.expect(stats.chunks_loaded > 0);
}
