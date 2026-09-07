const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const SettingsUi = @import("../settings_ui.zig");
const Rect = Theme.Rect;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("game-core").settings;
const Settings = settings_pkg.Settings;

const PANEL_WIDTH_MAX = 1280.0;
const StepResult = SettingsUi.StepResult;

pub const GraphicsScreen = struct {
    context: EngineContext,
    scroll_offset: f32,

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
            .scroll_offset = 0.0,
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
        const rs = ctx.render_settings;

        try ctx.screen_manager.drawBackgroundFor(ptr, ui);
        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());

        const ui_scale = Theme.scaleFor(screen_h, settings.ui_scale);
        const label_scale: f32 = 1.02 * ui_scale;
        const value_scale: f32 = 0.98 * ui_scale;
        const button_scale: f32 = 0.98 * ui_scale;
        const row_height: f32 = 58.0 * ui_scale;

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .graphics);

        const margin: f32 = 30.0 * ui_scale;
        const panel_w: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const panel_h: f32 = screen_h - margin * 2.0;
        const panel_x: f32 = (screen_w - panel_w) * 0.5;
        const panel_y: f32 = margin;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "RENDER", "VISUALS", "Lighting, materials, fog, and bloom.");

        const content_top = shell.content.y;
        const content_bottom = shell.content.y + shell.content.height;
        const content_h = shell.content.height;
        const content_left = shell.content.x;
        const content_right = shell.content.x + shell.content.width;
        Theme.drawListRail(ui, shell.content, ui_scale);

        const scroll_dy = ctx.input.getScrollDelta().y;
        self.scroll_offset -= scroll_dy * 36.0 * ui_scale;

        var total_rows: usize = 1;
        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance")) continue;
            total_rows += 1;
        }
        const section_extra = @as(f32, @floatFromInt(countSettingSections())) * 34.0 * ui_scale;
        const total_content_h: f32 = @as(f32, @floatFromInt(total_rows)) * (row_height + 8.0 * ui_scale) + 40.0 * ui_scale + section_extra;
        const max_scroll = @max(0.0, total_content_h - content_h);
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));

        Theme.drawScrollbar(ui, content_right - 12.0 * ui_scale, content_top + 12.0 * ui_scale, content_h - 24.0 * ui_scale, total_content_h, content_h, self.scroll_offset, max_scroll, ui_scale);

        var sy: f32 = content_top + 20.0 * ui_scale - self.scroll_offset;
        const row_x = content_left + 16.0 * ui_scale;
        const row_w = content_right - content_left - 42.0 * ui_scale;

        drawSectionIfVisible(ui, row_x, sy, "BASELINE", content_top, content_bottom, ui_scale);
        sy += 34.0 * ui_scale;

        if (rowFullyVisible(sy, row_height, content_top, content_bottom)) {
            const loaded_preset_count = settings_pkg.json_presets.count();
            const preset_idx = if (loaded_preset_count > 0) settings_pkg.json_presets.getIndex(settings) else 0;
            const preset_count = loaded_preset_count + 1;
            const step = drawStepperRow(ui, .{ .x = row_x, .y = sy, .width = row_w, .height = row_height }, "OVERALL QUALITY", "Preset target for renderer cost and quality.", SettingsUi.getPresetLabel(preset_idx), label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale);
            if (loaded_preset_count > 0) {
                if (step == .previous) {
                    const prev_idx = if (preset_idx == 0) preset_count - 1 else preset_idx - 1;
                    if (prev_idx < loaded_preset_count) {
                        settings_pkg.json_presets.apply(settings, prev_idx);
                        SettingsUi.applyPresetSideEffects(settings, rs);
                    }
                } else if (step == .next) {
                    const next_idx = (preset_idx + 1) % preset_count;
                    if (next_idx < loaded_preset_count) {
                        settings_pkg.json_presets.apply(settings, next_idx);
                        SettingsUi.applyPresetSideEffects(settings, rs);
                    }
                }
            }
        }
        sy += row_height + 8.0 * ui_scale;

        var buf: [64]u8 = undefined;

        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance")) continue;

            sy = drawSectionBoundary(ui, decl.name, row_x, sy, content_top, content_bottom, ui_scale);

            const meta = @field(Settings.metadata, decl.name);
            const val_ptr = &@field(settings, decl.name);
            const val_type = @TypeOf(val_ptr.*);
            const old_val = val_ptr.*;

            if (rowFullyVisible(sy, row_height, content_top, content_bottom)) {
                const row_rect = Rect{ .x = row_x, .y = sy, .width = row_w, .height = row_height };
                const highlighted = SettingsUi.rowHighlight(decl.name, val_ptr.*);
                Theme.drawOptionRow(ui, row_rect, meta.label, rowDescription(decl.name), label_scale, highlighted, ui_scale);

                switch (meta.kind) {
                    .toggle => {
                        if (SettingsUi.drawToggleControl(ui, row_rect, val_ptr.*, value_scale, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
                            val_ptr.* = !val_ptr.*;
                        }
                    },
                    .choice => |choice| {
                        var current_label: []const u8 = "UNKNOWN";
                        if (choice.values) |values| {
                            for (values, 0..) |v, i| {
                                if (v == val_ptr.*) {
                                    if (i < choice.labels.len) current_label = choice.labels[i];
                                    break;
                                }
                            }
                        }
                        if (choice.values) |values| {
                            var current_idx: usize = 0;
                            for (values, 0..) |v, i| {
                                if (v == val_ptr.*) {
                                    current_idx = i;
                                    break;
                                }
                            }
                            const step = SettingsUi.drawStepperControl(ui, row_rect, current_label, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale);
                            if (step == .previous) {
                                const prev_idx = if (current_idx == 0) values.len - 1 else current_idx - 1;
                                val_ptr.* = @as(val_type, @intCast(values[prev_idx]));
                            } else if (step == .next) {
                                const next_idx = (current_idx + 1) % values.len;
                                val_ptr.* = @as(val_type, @intCast(values[next_idx]));
                            }
                        }
                    },
                    .slider => |slider| {
                        const val_str = std.fmt.bufPrint(&buf, "{d:.2}", .{val_ptr.*}) catch "ERR";
                        const step = SettingsUi.drawStepperControl(ui, row_rect, val_str, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale);
                        if (step == .previous) {
                            if (val_ptr.* - slider.step < slider.min - 0.001) {
                                val_ptr.* = slider.max - slider.step;
                            } else {
                                val_ptr.* -= slider.step;
                            }
                        } else if (step == .next) {
                            if (val_ptr.* + slider.step > slider.max + 0.001) {
                                val_ptr.* = slider.max - slider.step;
                            } else {
                                val_ptr.* += slider.step;
                            }
                        }
                    },
                    .int_range => |range| {
                        const val_str = std.fmt.bufPrint(&buf, "{d}", .{val_ptr.*}) catch "ERR";
                        const step = SettingsUi.drawStepperControl(ui, row_rect, val_str, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale);
                        if (step == .previous) {
                            if (val_ptr.* - range.step < range.min) {
                                val_ptr.* = range.max - range.step;
                            } else {
                                val_ptr.* -= range.step;
                            }
                        } else if (step == .next) {
                            if (val_ptr.* + range.step > range.max) {
                                val_ptr.* = range.max - range.step;
                            } else {
                                val_ptr.* += range.step;
                            }
                        }
                    },
                }

                if (comptime std.mem.eql(u8, decl.name, "lpv_quality_preset")) {
                    const legend = SettingsUi.getLPVQualityLegend(settings.lpv_quality_preset);
                    Font.drawText(ui, legend, row_rect.x + row_rect.width - 398.0 * ui_scale, row_rect.y + row_height - 16.0 * ui_scale, 0.72 * ui_scale, Theme.signal);
                }
            }

            if (val_ptr.* != old_val) {
                SettingsUi.applyChangedSetting(decl.name, settings, rs);
            }

            sy += row_height + 8.0 * ui_scale;
        }

        ui.drawRect(.{ .x = shell.rect.x + 12.0 * ui_scale, .y = shell.rect.y + shell.rect.height - 78.0 * ui_scale, .width = shell.rect.width - 24.0 * ui_scale, .height = 76.0 * ui_scale }, Theme.panel);
        if (Theme.drawButton(ui, .{ .x = shell.rect.x + (shell.rect.width - 190.0 * ui_scale) * 0.5, .y = shell.footer_y, .width = 190.0 * ui_scale, .height = 46.0 * ui_scale }, "BACK", button_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
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

fn drawSectionIfVisible(ui: *UISystem, x: f32, y: f32, label: []const u8, content_top: f32, content_bottom: f32, scale: f32) void {
    if (y >= content_top and y <= content_bottom - 24.0 * scale) Theme.drawSectionLabel(ui, x, y, label, scale);
}

fn drawSectionBoundary(ui: *UISystem, comptime name: []const u8, x: f32, y: f32, content_top: f32, content_bottom: f32, scale: f32) f32 {
    const label = sectionBoundaryLabel(name);
    if (label.len == 0) return y;
    drawSectionIfVisible(ui, x, y, label, content_top, content_bottom, scale);
    return y + 34.0 * scale;
}

fn sectionBoundaryLabel(comptime name: []const u8) []const u8 {
    return if (comptime std.mem.eql(u8, name, "shadow_resolution"))
        "SHADOWS"
    else if (comptime std.mem.eql(u8, name, "pbr_enabled"))
        "SURFACES"
    else if (comptime std.mem.eql(u8, name, "taa_enabled"))
        "POST PROCESS"
    else if (comptime std.mem.eql(u8, name, "volumetric_density"))
        "FOG"
    else if (comptime std.mem.eql(u8, name, "lpv_enabled"))
        "GLOBAL LIGHT"
    else
        "";
}

fn countSettingSections() usize {
    comptime var count: usize = 0;
    inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
        if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
        if (comptime std.mem.eql(u8, decl.name, "render_distance")) continue;
        if (comptime sectionBoundaryLabel(decl.name).len > 0) count += 1;
    }
    return count;
}

fn rowFullyVisible(y: f32, h: f32, top: f32, bottom: f32) bool {
    return y >= top + 2.0 and y + h <= bottom - 2.0;
}

fn drawStepperRow(ui: *UISystem, row: Rect, label: []const u8, description: []const u8, value: []const u8, label_scale: f32, value_scale: f32, button_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) StepResult {
    Theme.drawOptionRow(ui, row, label, description, label_scale, false, scale);
    return SettingsUi.drawStepperControl(ui, row, value, value_scale, button_scale, mx, my, clicked, scale);
}

fn rowDescription(comptime name: []const u8) []const u8 {
    return if (comptime std.mem.eql(u8, name, "shadow_resolution"))
        "Depth map budget for directional shadows."
    else if (comptime std.mem.eql(u8, name, "shadow_softness"))
        "PCF sample count and edge softness."
    else if (comptime std.mem.eql(u8, name, "pbr_enabled"))
        "Material response and packed surface channels."
    else if (comptime std.mem.eql(u8, name, "taa_enabled"))
        "Temporal reconstruction path."
    else if (comptime std.mem.eql(u8, name, "max_texture_resolution"))
        "Upper bound for atlas texture detail."
    else if (comptime std.mem.eql(u8, name, "lpv_enabled"))
        "Light propagation volume GI experiment."
    else if (comptime std.mem.eql(u8, name, "volumetric_density"))
        "Fog volume strength."
    else
        "Click arrows to cycle or tune this parameter.";
}
