const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;
const presets = @import("json_presets.zig");

test "settings default to a full-detail chunk distance" {
    const settings = Settings{};
    try std.testing.expectEqual(@as(i32, 15), settings.render_distance);
}

test "graphics presets apply their configured chunk distance" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 0);
    try std.testing.expectEqual(@as(i32, 6), settings.render_distance);
    try std.testing.expectEqual(@as(u32, 0), settings.shadow_quality);
}

test "preset matching identifies settings changed from a preset" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 1);
    try std.testing.expectEqual(@as(usize, 1), presets.getIndex(&settings));
    settings.shadow_quality = 3;
    try std.testing.expectEqual(presets.count(), presets.getIndex(&settings));
}
