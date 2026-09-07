const std = @import("std");
const math = @import("engine-math");
const world = @import("world.zig");
const renderer_mod = @import("world_renderer.zig");

test "full-detail render candidates use the streaming disk" {
    try std.testing.expect(renderer_mod.isWithinChunkRenderRadius(10, 0, 0, 0, 10));
    try std.testing.expect(!renderer_mod.isWithinChunkRenderRadius(10, 10, 0, 0, 10));
}

test "full-detail MDI capacity rejects overflow before visibility truncation" {
    try std.testing.expect(renderer_mod.hasMdiCapacity(16_383, 49_149, 3));
    try std.testing.expect(!renderer_mod.hasMdiCapacity(16_384, 0, 1));
}

test "world orchestration delegates the active chunk distance to the renderer" {
    const Renderer = struct {
        calls: u32 = 0,
        distance: i32 = 0,
        fn render(self: *@This(), _: math.Mat4, _: math.Vec3, distance: i32, _: renderer_mod.RenderLayer) void {
            self.calls += 1;
            self.distance = distance;
        }
    };
    const Streamer = struct {
        fn getActiveRenderDistance(_: *@This()) i32 {
            return 24;
        }
    };
    var renderer = Renderer{};
    var streamer = Streamer{};
    world.WorldOrchestration.render(&renderer, &streamer, math.Mat4.identity(), math.Vec3.zero, .terrain);
    try std.testing.expectEqual(@as(u32, 1), renderer.calls);
    try std.testing.expectEqual(@as(i32, 24), renderer.distance);
}
