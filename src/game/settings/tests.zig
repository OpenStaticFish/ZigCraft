const std = @import("std");
const Settings = @import("data.zig").Settings;
const presets = @import("json_presets.zig");
const persistence = @import("persistence.zig");

test "Persistence Roundtrip" {
    const allocator = std.testing.allocator;
    _ = allocator;
    var settings = Settings{};
    settings.shadow_quality = 3;
    settings.render_distance = 25;
    settings.lod_enabled = true;
}

test "Preset Application" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    // Apply Low
    presets.apply(&settings, 0);
    try std.testing.expectEqual(@as(u32, 0), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 6), settings.render_distance);
    try std.testing.expectEqual(false, settings.lod_enabled);

    // Apply Ultra
    presets.apply(&settings, 3);
    try std.testing.expectEqual(@as(u32, 3), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 28), settings.render_distance);
    try std.testing.expectEqual(true, settings.lod_enabled);
}

test "Preset Matching" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 1); // Medium
    try std.testing.expectEqual(@as(usize, 1), presets.getIndex(&settings));

    // Modify a value to make it Custom
    settings.shadow_quality = 3;
    try std.testing.expectEqual(presets.graphics_presets.items.len, presets.getIndex(&settings));
}
