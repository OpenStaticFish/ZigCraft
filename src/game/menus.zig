const std = @import("std");
const AppState = @import("state.zig").AppState;
const Settings = @import("state.zig").Settings;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Color = @import("../engine/ui/ui_system.zig").Color;
const Rect = @import("../engine/ui/ui_system.zig").Rect;
const Font = @import("../engine/ui/font.zig");
const Widgets = @import("../engine/ui/widgets.zig");
const Input = @import("../engine/input/input.zig").Input;
const Key = @import("../engine/core/interfaces.zig").Key;
const Time = @import("../engine/core/time.zig").Time;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const log = @import("../engine/core/log.zig");
const seed_gen = @import("seed.zig");

pub const MenuAction = enum {
    none,
    quit,
};

pub const MenuContext = struct {
    ui: *UISystem,
    input: *const Input,
    screen_w: f32,
    screen_h: f32,
    time: *const Time,
    allocator: std.mem.Allocator,
};

pub fn drawHome(ctx: MenuContext, app_state: *AppState, last_state: *AppState, seed_focused: *bool) MenuAction {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    Font.drawTextCentered(ctx.ui, "ZIG VOXEL ENGINE", ctx.screen_w * 0.5, ctx.screen_h * 0.16, 4.0, Color.rgba(0.95, 0.96, 0.98, 1.0));
    const bw: f32 = @min(ctx.screen_w * 0.5, 360.0);
    const bh: f32 = 48.0;
    const bx: f32 = (ctx.screen_w - bw) * 0.5;
    var by: f32 = ctx.screen_h * 0.4;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SINGLEPLAYER", 2.2, mouse_x, mouse_y, mouse_clicked)) {
        app_state.* = .singleplayer;
        seed_focused.* = true;
    }
    by += bh + 14.0;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SETTINGS", 2.2, mouse_x, mouse_y, mouse_clicked)) {
        last_state.* = .home;
        app_state.* = .settings;
    }
    by += bh + 14.0;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "QUIT", 2.2, mouse_x, mouse_y, mouse_clicked)) {
        return .quit;
    }
    return .none;
}

pub fn drawSettings(ctx: MenuContext, app_state: *AppState, settings: *Settings, last_state: AppState, rhi: RHI) void {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    const pw: f32 = @min(ctx.screen_w * 0.7, 600.0);
    const ph: f32 = 400.0;
    const px: f32 = (ctx.screen_w - pw) * 0.5;
    const py: f32 = (ctx.screen_h - ph) * 0.5;
    ctx.ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.95));
    ctx.ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);
    Font.drawTextCentered(ctx.ui, "SETTINGS", ctx.screen_w * 0.5, py + 20.0, 2.8, Color.white);
    var sy: f32 = py + 80.0;
    const lx: f32 = px + 40.0;
    const vx: f32 = px + pw - 200.0;
    Font.drawText(ctx.ui, "RENDER DISTANCE", lx, sy, 2.0, Color.white);
    Font.drawNumber(ctx.ui, @intCast(settings.render_distance), vx + 60.0, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.render_distance > 1) settings.render_distance -= 1;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        settings.render_distance += 1;
    }
    sy += 50.0;
    Font.drawText(ctx.ui, "SENSITIVITY", lx, sy, 2.0, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.mouse_sensitivity), vx + 60.0, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
    }
    sy += 50.0;
    Font.drawText(ctx.ui, "FOV", lx, sy, 2.0, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.fov), vx + 60.0, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.fov > 30.0) settings.fov -= 5.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.fov < 120.0) settings.fov += 5.0;
    }
    sy += 50.0;
    Font.drawText(ctx.ui, "VSYNC", lx, sy, 2.0, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = 130.0, .height = 30.0 }, if (settings.vsync) "ENABLED" else "DISABLED", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        settings.vsync = !settings.vsync;
        rhi.setVSync(settings.vsync);
    }
    sy += 50.0;
    Font.drawText(ctx.ui, "SHADOW DISTANCE", lx, sy, 2.0, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.shadow_distance), vx + 60.0, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.shadow_distance > 50.0) settings.shadow_distance -= 50.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.shadow_distance < 1000.0) settings.shadow_distance += 50.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = px + (pw - 120.0) * 0.5, .y = py + ph - 60.0, .width = 120.0, .height = 40.0 }, "BACK", 2.0, mouse_x, mouse_y, mouse_clicked)) app_state.* = last_state;
}

pub fn drawSingleplayer(ctx: MenuContext, app_state: *AppState, seed_input: *std.ArrayListUnmanaged(u8), seed_focused: *bool, pending_new_world_seed: *?u64) !void {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    const pw: f32 = @min(ctx.screen_w * 0.7, 520.0);
    const ph: f32 = 260.0;
    const px: f32 = (ctx.screen_w - pw) * 0.5;
    const py: f32 = ctx.screen_h * 0.24;
    ctx.ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.92));
    ctx.ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);
    Font.drawTextCentered(ctx.ui, "CREATE WORLD", ctx.screen_w * 0.5, py + 18.0, 2.8, Color.rgba(0.92, 0.94, 0.97, 1.0));
    const ly: f32 = py + 78.0;
    Font.drawText(ctx.ui, "SEED", px + 24.0, ly, 2.0, Color.rgba(0.72, 0.78, 0.86, 1.0));
    const ih: f32 = 42.0;
    const iy: f32 = ly + 22.0;
    const rw: f32 = 120.0;
    const iw: f32 = pw - 24.0 - rw - 12.0 - 24.0;
    const ix: f32 = px + 24.0;
    const rx: f32 = ix + iw + 12.0;
    const seed_rect = Rect{ .x = ix, .y = iy, .width = iw, .height = ih };
    const random_rect = Rect{ .x = rx, .y = iy, .width = rw, .height = ih };
    if (mouse_clicked) seed_focused.* = seed_rect.contains(mouse_x, mouse_y);
    Widgets.drawTextInput(ctx.ui, seed_rect, seed_input.items, "LEAVE BLANK FOR RANDOM", 2.0, seed_focused.*, @as(u32, @intFromFloat(ctx.time.elapsed * 2.0)) % 2 == 0);
    if (Widgets.drawButton(ctx.ui, random_rect, "RANDOM", 1.8, mouse_x, mouse_y, mouse_clicked)) {
        const gen = seed_gen.randomSeedValue();
        try seed_gen.setSeedInput(seed_input, ctx.allocator, gen);
        seed_focused.* = true;
    }
    if (seed_focused.*) try handleSeedTyping(seed_input, ctx.allocator, ctx.input, 32);
    const byy: f32 = py + ph - 64.0;
    const hw: f32 = (pw - 24.0 - 12.0 - 24.0) / 2.0;
    if (Widgets.drawButton(ctx.ui, .{ .x = px + 24.0, .y = byy, .width = hw, .height = 40.0 }, "BACK", 1.9, mouse_x, mouse_y, mouse_clicked)) {
        app_state.* = .home;
        seed_focused.* = false;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = px + 24.0 + hw + 12.0, .y = byy, .width = hw, .height = 40.0 }, "CREATE", 1.9, mouse_x, mouse_y, mouse_clicked) or ctx.input.isKeyPressed(.enter)) {
        const seed = try seed_gen.resolveSeed(seed_input, ctx.allocator);
        pending_new_world_seed.* = seed;
        app_state.* = .world;
        seed_focused.* = false;
        log.log.info("World seed: {}", .{seed});
    }
}

pub fn handleSeedTyping(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: *const Input, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (seed_input.items.len > 0) _ = seed_input.pop();
    }
    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);
    const letters = [_]Key{ .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z };
    inline for (letters) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) {
        var ch: u8 = @intCast(@intFromEnum(key));
        if (shift) ch = std.ascii.toUpper(ch);
        try seed_input.append(allocator, ch);
    };
    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) try seed_input.append(allocator, @intCast(@intFromEnum(key)));
    if (input.isKeyPressed(.space) and seed_input.items.len < max_len) try seed_input.append(allocator, ' ');
}
