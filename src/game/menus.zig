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
const WindowManager = @import("../engine/core/window.zig").WindowManager;
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
    window_manager: ?*WindowManager = null,
};

pub fn drawHome(ctx: MenuContext, app_state: *AppState, last_state: *AppState, seed_focused: *bool) MenuAction {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    // Scale UI based on screen height for better readability at high resolutions
    const ui_scale: f32 = @max(1.0, ctx.screen_h / 720.0);
    const title_scale: f32 = 5.0 * ui_scale;
    const btn_scale: f32 = 2.8 * ui_scale;
    const btn_height: f32 = 60.0 * ui_scale;
    const btn_spacing: f32 = 18.0 * ui_scale;

    Font.drawTextCentered(ctx.ui, "ZIG VOXEL ENGINE", ctx.screen_w * 0.5, ctx.screen_h * 0.16, title_scale, Color.rgba(0.95, 0.96, 0.98, 1.0));
    const bw: f32 = @min(ctx.screen_w * 0.5, 450.0 * ui_scale);
    const bx: f32 = (ctx.screen_w - bw) * 0.5;
    var by: f32 = ctx.screen_h * 0.4;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SINGLEPLAYER", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        app_state.* = .singleplayer;
        seed_focused.* = true;
    }
    by += btn_height + btn_spacing;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        last_state.* = .home;
        app_state.* = .settings;
    }
    by += btn_height + btn_spacing;
    if (Widgets.drawButton(ctx.ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "QUIT", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        return .quit;
    }
    return .none;
}

pub fn drawSettings(ctx: MenuContext, app_state: *AppState, settings: *Settings, last_state: AppState, rhi: RHI) void {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    // Scale UI based on screen height for better readability at high resolutions
    const ui_scale: f32 = @max(1.0, ctx.screen_h / 720.0);
    const label_scale: f32 = 2.5 * ui_scale;
    const btn_scale: f32 = 2.0 * ui_scale;
    const title_scale: f32 = 3.5 * ui_scale;
    const row_height: f32 = 55.0 * ui_scale;
    const btn_height: f32 = 38.0 * ui_scale;
    const btn_width: f32 = 40.0 * ui_scale;
    const toggle_width: f32 = 160.0 * ui_scale;

    const pw: f32 = @min(ctx.screen_w * 0.75, 750.0 * ui_scale);
    const ph: f32 = 680.0 * ui_scale;
    const px: f32 = (ctx.screen_w - pw) * 0.5;
    const py: f32 = (ctx.screen_h - ph) * 0.5;
    ctx.ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.95));
    ctx.ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0 * ui_scale);
    Font.drawTextCentered(ctx.ui, "SETTINGS", ctx.screen_w * 0.5, py + 25.0 * ui_scale, title_scale, Color.white);
    var sy: f32 = py + 85.0 * ui_scale;
    const lx: f32 = px + 50.0 * ui_scale;
    const vx: f32 = px + pw - 250.0 * ui_scale;

    // Resolution
    Font.drawText(ctx.ui, "RESOLUTION", lx, sy, label_scale, Color.white);
    const res_idx = settings.getResolutionIndex();
    const res_label = Settings.RESOLUTIONS[res_idx].label;
    if (Widgets.drawButton(ctx.ui, .{ .x = vx - 20.0, .y = sy - 5.0, .width = 180.0 * ui_scale, .height = btn_height }, res_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        const new_idx = (res_idx + 1) % Settings.RESOLUTIONS.len;
        settings.setResolutionByIndex(new_idx);
        // Apply resolution change immediately
        if (ctx.window_manager) |wm| {
            wm.setSize(settings.window_width, settings.window_height);
        }
    }
    sy += row_height;

    // Render Distance
    Font.drawText(ctx.ui, "RENDER DISTANCE", lx, sy, label_scale, Color.white);
    Font.drawNumber(ctx.ui, @intCast(settings.render_distance), vx + 70.0 * ui_scale, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.render_distance > 1) settings.render_distance -= 1;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.render_distance += 1;
    }
    sy += row_height;

    // Sensitivity
    Font.drawText(ctx.ui, "SENSITIVITY", lx, sy, label_scale, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.mouse_sensitivity), vx + 70.0 * ui_scale, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
    }
    sy += row_height;

    // FOV
    Font.drawText(ctx.ui, "FOV", lx, sy, label_scale, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.fov), vx + 70.0 * ui_scale, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.fov > 30.0) settings.fov -= 5.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.fov < 120.0) settings.fov += 5.0;
    }
    sy += row_height;

    // VSync
    Font.drawText(ctx.ui, "VSYNC", lx, sy, label_scale, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.vsync) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.vsync = !settings.vsync;
        rhi.setVSync(settings.vsync);
    }
    sy += row_height;

    // Shadow Distance
    Font.drawText(ctx.ui, "SHADOW DISTANCE", lx, sy, label_scale, Color.white);
    Font.drawNumber(ctx.ui, @intFromFloat(settings.shadow_distance), vx + 70.0 * ui_scale, sy, Color.white);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.shadow_distance > 50.0) settings.shadow_distance -= 50.0;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        if (settings.shadow_distance < 1000.0) settings.shadow_distance += 50.0;
    }
    sy += row_height;

    // Anisotropic Filtering
    Font.drawText(ctx.ui, "ANISOTROPIC FILTER", lx, sy, label_scale, Color.white);
    const af_label = getAnisotropyLabel(settings.anisotropic_filtering);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, af_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.anisotropic_filtering = cycleAnisotropy(settings.anisotropic_filtering);
        rhi.setAnisotropicFiltering(settings.anisotropic_filtering);
    }
    sy += row_height;

    // MSAA (Vulkan only)
    Font.drawText(ctx.ui, "ANTI-ALIASING", lx, sy, label_scale, Color.rgba(0.7, 0.7, 0.8, 1.0));
    const msaa_label = getMSAALabel(settings.msaa_samples);
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, msaa_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.msaa_samples = cycleMSAA(settings.msaa_samples);
        rhi.setMSAA(settings.msaa_samples);
    }
    Font.drawText(ctx.ui, "(VULKAN)", vx + toggle_width + 10.0, sy, 1.5 * ui_scale, Color.rgba(0.5, 0.5, 0.6, 1.0));
    sy += row_height;

    // LOD System (experimental)
    Font.drawText(ctx.ui, "LOD SYSTEM", lx, sy, label_scale, Color.rgba(0.7, 0.7, 0.8, 1.0));
    if (Widgets.drawButton(ctx.ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.lod_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.lod_enabled = !settings.lod_enabled;
    }
    Font.drawText(ctx.ui, "(RESTART)", vx + toggle_width + 10.0, sy, 1.5 * ui_scale, Color.rgba(0.5, 0.5, 0.6, 1.0));

    // Back button
    if (Widgets.drawButton(ctx.ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 70.0 * ui_scale, .width = 150.0 * ui_scale, .height = 50.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        settings.save(ctx.allocator);
        app_state.* = last_state;
    }
}

fn getAnisotropyLabel(level: u8) []const u8 {
    return switch (level) {
        0, 1 => "OFF",
        2 => "2X",
        4 => "4X",
        8 => "8X",
        16 => "16X",
        else => "ON",
    };
}

fn cycleAnisotropy(current: u8) u8 {
    return switch (current) {
        0, 1 => 2,
        2 => 4,
        4 => 8,
        8 => 16,
        else => 1,
    };
}

fn getMSAALabel(samples: u8) []const u8 {
    return switch (samples) {
        0, 1 => "OFF",
        2 => "2X",
        4 => "4X",
        8 => "8X",
        else => "ON",
    };
}

fn cycleMSAA(current: u8) u8 {
    return switch (current) {
        0, 1 => 2,
        2 => 4,
        4 => 8,
        else => 1,
    };
}

pub fn drawSingleplayer(ctx: MenuContext, app_state: *AppState, seed_input: *std.ArrayListUnmanaged(u8), seed_focused: *bool, pending_new_world_seed: *?u64) !void {
    const mouse_pos = ctx.input.getMousePosition();
    const mouse_x: f32 = @floatFromInt(mouse_pos.x);
    const mouse_y: f32 = @floatFromInt(mouse_pos.y);
    const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

    // Scale UI based on screen height for better readability at high resolutions
    const ui_scale: f32 = @max(1.0, ctx.screen_h / 720.0);
    const title_scale: f32 = 3.5 * ui_scale;
    const label_scale: f32 = 2.5 * ui_scale;
    const btn_scale: f32 = 2.2 * ui_scale;
    const input_scale: f32 = 2.5 * ui_scale;

    const pw: f32 = @min(ctx.screen_w * 0.7, 650.0 * ui_scale);
    const ph: f32 = 320.0 * ui_scale;
    const px: f32 = (ctx.screen_w - pw) * 0.5;
    const py: f32 = ctx.screen_h * 0.24;
    ctx.ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.92));
    ctx.ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0 * ui_scale);
    Font.drawTextCentered(ctx.ui, "CREATE WORLD", ctx.screen_w * 0.5, py + 22.0 * ui_scale, title_scale, Color.rgba(0.92, 0.94, 0.97, 1.0));
    const ly: f32 = py + 90.0 * ui_scale;
    Font.drawText(ctx.ui, "SEED", px + 30.0 * ui_scale, ly, label_scale, Color.rgba(0.72, 0.78, 0.86, 1.0));
    const ih: f32 = 52.0 * ui_scale;
    const iy: f32 = ly + 28.0 * ui_scale;
    const rw: f32 = 150.0 * ui_scale;
    const iw: f32 = pw - 30.0 * ui_scale - rw - 15.0 * ui_scale - 30.0 * ui_scale;
    const ix: f32 = px + 30.0 * ui_scale;
    const rx: f32 = ix + iw + 15.0 * ui_scale;
    const seed_rect = Rect{ .x = ix, .y = iy, .width = iw, .height = ih };
    const random_rect = Rect{ .x = rx, .y = iy, .width = rw, .height = ih };
    if (mouse_clicked) seed_focused.* = seed_rect.contains(mouse_x, mouse_y);
    Widgets.drawTextInput(ctx.ui, seed_rect, seed_input.items, "LEAVE BLANK FOR RANDOM", input_scale, seed_focused.*, @as(u32, @intFromFloat(ctx.time.elapsed * 2.0)) % 2 == 0);
    if (Widgets.drawButton(ctx.ui, random_rect, "RANDOM", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        const gen = seed_gen.randomSeedValue();
        try seed_gen.setSeedInput(seed_input, ctx.allocator, gen);
        seed_focused.* = true;
    }
    if (seed_focused.*) try handleSeedTyping(seed_input, ctx.allocator, ctx.input, 32);
    const byy: f32 = py + ph - 80.0 * ui_scale;
    const hw: f32 = (pw - 30.0 * ui_scale - 15.0 * ui_scale - 30.0 * ui_scale) / 2.0;
    const btn_h: f32 = 50.0 * ui_scale;
    if (Widgets.drawButton(ctx.ui, .{ .x = px + 30.0 * ui_scale, .y = byy, .width = hw, .height = btn_h }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
        app_state.* = .home;
        seed_focused.* = false;
    }
    if (Widgets.drawButton(ctx.ui, .{ .x = px + 30.0 * ui_scale + hw + 15.0 * ui_scale, .y = byy, .width = hw, .height = btn_h }, "CREATE", btn_scale, mouse_x, mouse_y, mouse_clicked) or ctx.input.isKeyPressed(.enter)) {
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
