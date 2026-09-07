const std = @import("std");
const session = @import("game-core").session;
const Settings = @import("game-core").Settings;

test "render distance metadata and far plane support chunk-only streaming" {
    const range = Settings.metadata.render_distance.kind.int_range;
    try std.testing.expectEqual(@as(i32, 2), range.min);
    try std.testing.expectEqual(std.math.maxInt(i32), range.max);
    try std.testing.expectEqual(@as(f32, 10_000), session.cameraFarPlaneForRenderDistance(1));
    try std.testing.expectEqual(@as(f32, 10_000), session.cameraFarPlaneForRenderDistance(256));
    try std.testing.expectEqual(@as(f32, 16_640), session.cameraFarPlaneForRenderDistance(1024));
}

test "chunk debug settings retain non-LOD feature selection" {
    const config = session.BuildConfig{ .chunk_debug_mode = true, .chunk_debug_enable = "water,caves,decorations" };
    try std.testing.expect(config.chunk_debug_mode);
    try std.testing.expectEqualStrings("water,caves,decorations", config.chunk_debug_enable);
}
