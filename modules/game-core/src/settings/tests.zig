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

test "graphics preset reload releases old storage and preserves presets on allocation failure" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);
    try presets.initPresets(allocator);

    const count_before = presets.count();
    const name_before = presets.getPresetName(0);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, presets.initPresets(failing.allocator()));
    try std.testing.expectEqual(count_before, presets.count());
    try std.testing.expectEqual(name_before.ptr, presets.getPresetName(0).ptr);
    try std.testing.expectEqualStrings("LOW", presets.getPresetName(0));
    var settings = Settings{};
    presets.apply(&settings, 0);
    try std.testing.expectEqual(@as(i32, 6), settings.render_distance);
}
