const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("../settings.zig");
const Settings = settings_pkg.Settings;

const PANEL_WIDTH_MAX = 850.0;
const PANEL_HEIGHT_BASE = 850.0;
const BG_COLOR = Color.rgba(0.12, 0.14, 0.18, 0.95);
const BORDER_COLOR = Color.rgba(0.28, 0.33, 0.42, 1.0);

pub const GraphicsScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*GraphicsScreen {
        const self = try allocator.create(GraphicsScreen);
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
        const helpers = settings_pkg.ui_helpers;
        const presets = settings_pkg.presets;
        const apply_logic = settings_pkg.apply_logic;

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
        const label_scale: f32 = 2.2 * ui_scale;
        const btn_scale: f32 = 1.8 * ui_scale;
        const title_scale: f32 = 3.5 * ui_scale;
        const row_height: f32 = 48.0 * ui_scale;
        const btn_height: f32 = 34.0 * ui_scale;
        const toggle_width: f32 = 180.0 * ui_scale;

        const pw: f32 = @min(screen_w * 0.8, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 40.0, PANEL_HEIGHT_BASE * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawTextCentered(ui, "GRAPHICS SETTINGS", screen_w * 0.5, py + 25.0 * ui_scale, title_scale, Color.white);

        var sy: f32 = py + 80.0 * ui_scale;
        const lx: f32 = px + 40.0 * ui_scale;
        const vx: f32 = px + pw - 220.0 * ui_scale;

        // Quality Preset
        Font.drawText(ui, "OVERALL QUALITY", lx, sy, label_scale, Color.rgba(0.4, 0.8, 1.0, 1.0));
        const preset_idx = presets.getIndex(settings);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getPresetLabel(preset_idx), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const next_idx = (preset_idx + 1) % (settings_pkg.GRAPHICS_PRESETS.len + 1);
            if (next_idx < settings_pkg.GRAPHICS_PRESETS.len) {
                presets.apply(settings, next_idx);
            }
            // Apply settings to RHI regardless of whether it's a preset or custom
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height + 10.0 * ui_scale;

        var buf: [32]u8 = undefined;

        // Shadows
        Font.drawText(ui, "SHADOW RESOLUTION", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getShadowQualityLabel(settings.shadow_quality), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.shadow_quality = (settings.shadow_quality + 1) % @as(u32, @intCast(settings_pkg.SHADOW_QUALITIES.len));
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        Font.drawText(ui, "SHADOW SOFTNESS", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getShadowSamplesLabel(settings.shadow_pcf_samples, &buf), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.shadow_pcf_samples = switch (settings.shadow_pcf_samples) {
                4 => 8,
                8 => 12,
                12 => 16,
                else => 4,
            };
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        Font.drawText(ui, "CASCADE BLENDING", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.shadow_cascade_blend) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.shadow_cascade_blend = !settings.shadow_cascade_blend;
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height + 10.0 * ui_scale;

        // PBR
        Font.drawText(ui, "PBR RENDERING", lx, sy, label_scale, Color.rgba(1.0, 0.8, 0.4, 1.0));
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.pbr_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.pbr_enabled = !settings.pbr_enabled;
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        Font.drawText(ui, "PBR QUALITY", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getPBRQualityLabel(settings.pbr_quality), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.pbr_quality = (settings.pbr_quality + 1) % 3;
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height + 10.0 * ui_scale;

        // Textures
        Font.drawText(ui, "MAX TEXTURE RES", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getTextureResLabel(settings.max_texture_resolution, &buf), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.max_texture_resolution = switch (settings.max_texture_resolution) {
                16 => 32,
                32 => 64,
                64 => 128,
                128 => 256,
                256 => 512,
                else => 16,
            };
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        Font.drawText(ui, "ANISOTROPIC FILTER", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getAnisotropyLabel(settings.anisotropic_filtering), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.anisotropic_filtering = helpers.cycleAnisotropy(settings.anisotropic_filtering);
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        // Misc
        Font.drawText(ui, "ANTI-ALIASING (MSAA)", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, helpers.getMSAALabel(settings.msaa_samples), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.msaa_samples = helpers.cycleMSAA(settings.msaa_samples);
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        Font.drawText(ui, "CLOUD SHADOWS", lx, sy, label_scale, Color.white);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.cloud_shadows_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.cloud_shadows_enabled = !settings.cloud_shadows_enabled;
            apply_logic.applyToRHI(settings, ctx.rhi);
        }
        sy += row_height;

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 60.0 * ui_scale, .width = 150.0 * ui_scale, .height = 45.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
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
