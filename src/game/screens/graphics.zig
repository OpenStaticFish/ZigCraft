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

        // Draw background screen if it exists
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const mouse_clicked_right = ctx.input.isMouseButtonPressed(.right);

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

        if (settings_pkg.json_presets.graphics_presets.items.len > 0) {
            const preset_idx = settings_pkg.json_presets.getIndex(settings);
            if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, getPresetLabel(preset_idx), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                const next_idx = (preset_idx + 1) % (settings_pkg.json_presets.graphics_presets.items.len + 1);
                if (next_idx < settings_pkg.json_presets.graphics_presets.items.len) {
                    settings_pkg.json_presets.apply(settings, next_idx);
                    ctx.rhi.*.setAnisotropicFiltering(settings.anisotropic_filtering);
                    ctx.rhi.*.setMSAA(settings.msaa_samples);
                    ctx.rhi.*.setTexturesEnabled(settings.textures_enabled);
                } else {
                    // Custom selected, nothing changes in values but UI label updates to CUSTOM (via getPresetIndex next frame)
                }
            }
        } else {
            _ = Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, "ERROR", btn_scale, mouse_x, mouse_y, false);
        }
        sy += row_height + 10.0 * ui_scale;

        var buf: [64]u8 = undefined;

        // Auto-generated UI from metadata
        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            const meta = @field(Settings.metadata, decl.name);
            const val_ptr = &@field(settings, decl.name);
            const val_type = @TypeOf(val_ptr.*);
            const old_val = val_ptr.*;

            Font.drawText(ui, meta.label, lx, sy, label_scale, Color.white);

            switch (meta.kind) {
                .toggle => {
                    const label = if (val_ptr.*) "ENABLED" else "DISABLED";
                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
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
                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, current_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        if (choice.values) |values| {
                            var current_idx: usize = 0;
                            for (values, 0..) |v, i| {
                                if (v == val_ptr.*) {
                                    current_idx = i;
                                    break;
                                }
                            }
                            // Cycle: Left click forward, Right click backward (if we had right click)
                            // For now, standard cycle
                            const next_idx = (current_idx + 1) % values.len;
                            val_ptr.* = @as(val_type, @intCast(values[next_idx]));
                        }
                    }
                },
                .slider => |slider| {
                    const val_str = std.fmt.bufPrint(&buf, "{d:.1}", .{val_ptr.*}) catch "ERR";
                    const rect = .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height };
                    const is_hovered = (mouse_x >= rect.x and mouse_x <= rect.x + rect.width and mouse_y >= rect.y and mouse_y <= rect.y + rect.height);

                    if (Widgets.drawButton(ui, rect, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        // Left-click: increment with wrap to min
                        if (val_ptr.* + slider.step > slider.max + 0.001) {
                            val_ptr.* = slider.min;
                        } else {
                            val_ptr.* += slider.step;
                        }
                    } else if (is_hovered and mouse_clicked_right) {
                        // Right-click: decrement with wrap to max
                        if (val_ptr.* - slider.step < slider.min - 0.001) {
                            val_ptr.* = slider.max;
                        } else {
                            val_ptr.* -= slider.step;
                        }
                    }
                },
                .int_range => |range| {
                    const val_str = std.fmt.bufPrint(&buf, "{d}", .{val_ptr.*}) catch "ERR";
                    const rect = .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height };
                    const is_hovered = (mouse_x >= rect.x and mouse_x <= rect.x + rect.width and mouse_y >= rect.y and mouse_y <= rect.y + rect.height);

                    if (Widgets.drawButton(ui, rect, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        // Left-click: increment with wrap to min
                        if (val_ptr.* + range.step > range.max) {
                            val_ptr.* = range.min;
                        } else {
                            val_ptr.* += range.step;
                        }
                    } else if (is_hovered and mouse_clicked_right) {
                        // Right-click: decrement with wrap to max
                        if (val_ptr.* - range.step < range.min) {
                            val_ptr.* = range.max;
                        } else {
                            val_ptr.* -= range.step;
                        }
                    }
                },
            }

            // Handle side effects
            if (val_ptr.* != old_val) {
                if (std.mem.eql(u8, decl.name, "anisotropic_filtering")) {
                    ctx.rhi.*.setAnisotropicFiltering(settings.anisotropic_filtering);
                } else if (std.mem.eql(u8, decl.name, "msaa_samples")) {
                    ctx.rhi.*.setMSAA(settings.msaa_samples);
                } else if (std.mem.eql(u8, decl.name, "textures_enabled")) {
                    ctx.rhi.*.setTexturesEnabled(settings.textures_enabled);
                } else if (std.mem.eql(u8, decl.name, "vsync")) {
                    ctx.rhi.*.setVSync(settings.vsync);
                } else if (std.mem.eql(u8, decl.name, "volumetric_density")) {
                    ctx.rhi.*.setVolumetricDensity(settings.volumetric_density);
                }
            }

            sy += row_height;
        }

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

fn getPresetLabel(idx: usize) []const u8 {
    if (idx >= settings_pkg.json_presets.graphics_presets.items.len) return "CUSTOM";
    return settings_pkg.json_presets.graphics_presets.items[idx].name;
}
