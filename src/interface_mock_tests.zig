const std = @import("std");
const InputBinding = @import("engine-input").InputBinding;
const MouseButton = @import("engine-core").interfaces.MouseButton;
const Settings = @import("game-core").Settings;

test "input binding interface equality distinguishes binding kinds" {
    const left = InputBinding{ .mouse_button = MouseButton.left };
    try std.testing.expect(left.eql(.{ .mouse_button = .left }));
    try std.testing.expect(!left.eql(.{ .mouse_button = .right }));
    try std.testing.expect(!left.eql(.{ .none = {} }));
}

test "settings interface data remains independently configurable" {
    var settings = Settings{};
    settings.vsync = false;
    settings.wireframe_enabled = true;
    settings.render_distance = 24;
    try std.testing.expect(!settings.vsync);
    try std.testing.expect(settings.wireframe_enabled);
    try std.testing.expectEqual(@as(i32, 24), settings.render_distance);
}
