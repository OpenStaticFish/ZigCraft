//! UI Widgets like buttons and text inputs.

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const Font = @import("font.zig");

pub fn drawButton(u: *UISystem, rect: Rect, label: []const u8, scale: f32, mx: f32, my: f32, clicked: bool) bool {
    const hov = rect.contains(mx, my);
    u.drawRect(rect, if (hov) Color.rgba(0.2, 0.26, 0.36, 0.95) else Color.rgba(0.13, 0.17, 0.24, 0.92));
    u.drawRectOutline(rect, if (hov) Color.rgba(0.55, 0.7, 0.9, 1.0) else Color.rgba(0.29, 0.35, 0.45, 1.0), 2.0);
    Font.drawTextCentered(u, label, rect.x + rect.width * 0.5, rect.y + (rect.height - 7.0 * scale) * 0.5, scale, Color.rgba(0.95, 0.96, 0.98, 1.0));
    return hov and clicked;
}

pub fn drawTextInput(u: *UISystem, rect: Rect, text: []const u8, ph: []const u8, scale: f32, foc: bool, caret: bool) void {
    u.drawRect(rect, Color.rgba(0.07, 0.09, 0.13, 0.95));
    u.drawRectOutline(rect, if (foc) Color.rgba(0.5, 0.75, 0.95, 1.0) else Color.rgba(0.25, 0.3, 0.38, 1.0), 2.0);
    const ty = rect.y + (rect.height - 7.0 * scale) * 0.5;
    if (text.len > 0) Font.drawText(u, text, rect.x + 8, ty, scale, Color.rgba(0.92, 0.95, 0.98, 1.0)) else Font.drawText(u, ph, rect.x + 8, ty, scale, Color.rgba(0.5, 0.56, 0.65, 1.0));
    if (foc and caret) u.drawRect(.{ .x = rect.x + 8 + Font.measureTextWidth(text, scale), .y = rect.y + 8, .width = 2, .height = rect.height - 16 }, Color.rgba(0.9, 0.95, 1.0, 1.0));
}
