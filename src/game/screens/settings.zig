const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Settings = @import("../state.zig").Settings;
const GraphicsScreen = @import("graphics.zig").GraphicsScreen;

const PANEL_WIDTH_MAX = 750.0;
const PANEL_HEIGHT_BASE = 845.0;
const BG_COLOR = Color.rgba(0.12, 0.14, 0.18, 0.95);
const BORDER_COLOR = Color.rgba(0.28, 0.33, 0.42, 1.0);

pub const SettingsScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*SettingsScreen {
        const self = try allocator.create(SettingsScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.saveSettings();
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const settings = ctx.settings;

        // Draw background screen if it exists
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);

        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * settings.ui_scale;
        const label_scale: f32 = 2.5 * ui_scale;
        const btn_scale: f32 = 2.0 * ui_scale;
        const title_scale: f32 = 3.5 * ui_scale;
        const row_height: f32 = 55.0 * ui_scale;
        const btn_height: f32 = 38.0 * ui_scale;
        const btn_width: f32 = 40.0 * ui_scale;
        const toggle_width: f32 = 160.0 * ui_scale;

        const pw: f32 = @min(screen_w * 0.75, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = PANEL_HEIGHT_BASE * ui_scale;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawTextCentered(ui, "SETTINGS", screen_w * 0.5, py + 25.0 * ui_scale, title_scale, Color.white);
        var sy: f32 = py + 85.0 * ui_scale;
        const lx: f32 = px + 50.0 * ui_scale;
        const vx: f32 = px + pw - 250.0 * ui_scale;

        // Resolution
        Font.drawText(ui, "RESOLUTION", lx, sy, label_scale, Color.white);
        const res_idx = settings.getResolutionIndex();
        const res_label = Settings.RESOLUTIONS[res_idx].label;
        if (Widgets.drawButton(ui, .{ .x = vx - 20.0, .y = sy - 5.0, .width = 180.0 * ui_scale, .height = btn_height }, res_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const new_idx = (res_idx + 1) % Settings.RESOLUTIONS.len;
            settings.setResolutionByIndex(new_idx);
            ctx.window_manager.setSize(settings.window_width, settings.window_height);
        }
        sy += row_height;

        // Render Distance
        Font.drawText(ui, "RENDER DISTANCE", lx, sy, label_scale, Color.white);
        Font.drawNumber(ui, @intCast(settings.render_distance), vx + 70.0 * ui_scale, sy, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.render_distance > 1) settings.render_distance -= 1;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.render_distance += 1;
        }
        sy += row_height;

        // Sensitivity
        Font.drawText(ui, "SENSITIVITY", lx, sy, label_scale, Color.white);
        Font.drawNumber(ui, @intFromFloat(settings.mouse_sensitivity), vx + 70.0 * ui_scale, sy, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
        }
        sy += row_height;

        // FOV
        Font.drawText(ui, "FOV", lx, sy, label_scale, Color.white);
        Font.drawNumber(ui, @intFromFloat(settings.fov), vx + 70.0 * ui_scale, sy, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov > 30.0) settings.fov -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov < 120.0) settings.fov += 5.0;
        }
        sy += row_height;

        // VSync
        Font.drawText(ui, "VSYNC", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.vsync) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.vsync = !settings.vsync;
            ctx.rhi.setVSync(settings.vsync);
        }
        sy += row_height + 15.0 * ui_scale;

        // Advanced Graphics Button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 250.0 * ui_scale) * 0.5, .y = sy, .width = 250.0 * ui_scale, .height = btn_height + 10.0 * ui_scale }, "ADVANCED GRAPHICS...", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const graphics_screen = try GraphicsScreen.init(ctx.allocator, ctx);
            errdefer graphics_screen.deinit(graphics_screen);
            ctx.screen_manager.pushScreen(graphics_screen.screen());
        }
        sy += row_height + 15.0 * ui_scale;

        // UI Scale
        Font.drawText(ui, "UI SCALE", lx, sy, label_scale, Color.white);
        const ui_scale_label = getUIScaleLabel(settings.ui_scale);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, ui_scale_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.ui_scale = cycleUIScale(settings.ui_scale);
        }
        sy += row_height;

        // LOD System (experimental)
        Font.drawText(ui, "LOD SYSTEM", lx, sy, label_scale, Color.rgba(0.7, 0.7, 0.8, 1.0));
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.lod_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.lod_enabled = !settings.lod_enabled;
        }
        sy += row_height;

        // Textures
        Font.drawText(ui, "TEXTURES", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.textures_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.textures_enabled = !settings.textures_enabled;
            ctx.rhi.setTexturesEnabled(settings.textures_enabled);
        }
        sy += row_height;

        // Wireframe (debug)
        Font.drawText(ui, "WIREFRAME", lx, sy, label_scale, Color.rgba(0.7, 0.7, 0.8, 1.0));
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.wireframe_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.wireframe_enabled = !settings.wireframe_enabled;
            ctx.rhi.setWireframe(settings.wireframe_enabled);
        }
        Font.drawText(ui, "(DEBUG)", vx + toggle_width + 10.0, sy, 1.5 * ui_scale, Color.rgba(0.5, 0.5, 0.6, 1.0));

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 70.0 * ui_scale, .width = 150.0 * ui_scale, .height = 50.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn getUIScaleLabel(scale: f32) []const u8 {
    if (scale <= 0.55) return "0.5X";
    if (scale <= 0.8) return "0.75X";
    if (scale <= 1.1) return "1.0X";
    if (scale <= 1.3) return "1.25X";
    if (scale <= 1.6) return "1.5X";
    return "2.0X";
}

fn cycleUIScale(current: f32) f32 {
    if (current <= 0.55) return 0.75;
    if (current <= 0.8) return 1.0;
    if (current <= 1.1) return 1.25;
    if (current <= 1.3) return 1.5;
    if (current <= 1.6) return 2.0;
    return 0.5;
}
