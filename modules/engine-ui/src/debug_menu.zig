//! Centralized debug menu overlay.
//! Lists all debug features with toggle state and hotkey labels.
//! Opened via F3 (toggle_debug_menu action).

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const Font = @import("font.zig");

pub const DebugFeature = enum(u8) {
    wireframe,
    textures,
    vsync,
    fps_counter,
    block_info,
    shadow_sandbox,
    shadow_beauty,
    shadow_probe,
    shadow_debug,
    shadow_cascade_index,
    shadow_caster_coverage,
    shadow_seam_diag,
    direct_key_debug,
    sky_fill_debug,
    block_light_debug,
    outdoor_factor_debug,
    timing_overlay,
    gpass_render,
    ssao,
    fog,
    clouds,
    lpv_overlay,
    frustum_debug,
    occlusion_debug,
    creative_mode,
    time_pause,
    chunk_inspector,

    pub const count = @typeInfo(DebugFeature).@"enum".fields.len;
};

pub const FeatureInfo = struct {
    label: []const u8,
    hotkey: []const u8,
};

/// Hotkey labels reflect the default bindings in `input_mapper.zig`.
/// Shown for reference — features are toggled by clicking menu rows.
pub const FEATURE_INFOS = [DebugFeature.count]FeatureInfo{
    .{ .label = "WIREFRAME", .hotkey = "F" },
    .{ .label = "TEXTURES", .hotkey = "T" },
    .{ .label = "VSYNC", .hotkey = "V" },
    .{ .label = "FPS COUNTER", .hotkey = "F2" },
    .{ .label = "BLOCK INFO", .hotkey = "F5" },
    .{ .label = "SHADOW SANDBOX", .hotkey = "MENU" },
    .{ .label = "SHADOW BEAUTY", .hotkey = "MENU" },
    .{ .label = "SHADOW PROBE", .hotkey = "MENU" },
    .{ .label = "SHADOW DEBUG", .hotkey = "G" },
    .{ .label = "CASCADE INDEX", .hotkey = "F3" },
    .{ .label = "CASTER COVERAGE", .hotkey = "F3" },
    .{ .label = "SEAM DIAG", .hotkey = "F3" },
    .{ .label = "DIRECT KEY", .hotkey = "MENU" },
    .{ .label = "SKY FILL", .hotkey = "MENU" },
    .{ .label = "BLOCK LIGHT", .hotkey = "MENU" },
    .{ .label = "OUTDOOR FACTOR", .hotkey = "MENU" },
    .{ .label = "TIMING OVERLAY", .hotkey = "F4" },
    .{ .label = "G-PASS RENDER", .hotkey = "F7" },
    .{ .label = "SSAO", .hotkey = "F8" },
    .{ .label = "FOG", .hotkey = "F10" },
    .{ .label = "CLOUDS", .hotkey = "MENU" },
    .{ .label = "LPV OVERLAY", .hotkey = "F11" },
    .{ .label = "FRUSTUM DEBUG", .hotkey = "J" },
    .{ .label = "OCCLUSION DEBUG", .hotkey = "K" },
    .{ .label = "CREATIVE MODE", .hotkey = "F12" },
    .{ .label = "TIME PAUSE", .hotkey = "N" },
    .{ .label = "CHUNK INSPECTOR", .hotkey = "J" },
};

pub const DebugMenuOverlay = struct {
    enabled: bool = false,
    scroll_offset: usize = 0,

    const BASE_PANEL_X: f32 = 10.0;
    const BASE_PANEL_Y: f32 = 10.0;
    const BASE_PANEL_WIDTH: f32 = 300.0;
    const BASE_LINE_HEIGHT: f32 = 18.0;
    const BASE_HEADER_HEIGHT: f32 = 28.0;
    const BASE_PADDING: f32 = 8.0;
    const BASE_TITLE_SCALE: f32 = 1.5;
    const BASE_TEXT_SCALE: f32 = 1.2;
    const SCROLL_ARROW_HEIGHT: f32 = 16.0;
    const SCROLL_THUMB_MIN_HEIGHT: f32 = 20.0;

    pub fn toggle(self: *DebugMenuOverlay) void {
        self.enabled = !self.enabled;
        self.scroll_offset = 0;
    }

    pub const ClickResult = struct {
        feature: DebugFeature,
    };

    pub fn draw(self: *DebugMenuOverlay, ui: *UISystem, feature_states: [DebugFeature.count]bool, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, ui_scale: f32, scroll_delta_y: f32) ?ClickResult {
        if (!self.enabled) return null;

        const panel_width = BASE_PANEL_WIDTH * ui_scale;
        const screen_w: f32 = ui.screen_width;
        const panel_x = screen_w - (BASE_PANEL_X * ui_scale) - panel_width;
        const panel_y = BASE_PANEL_Y * ui_scale;
        const line_height = BASE_LINE_HEIGHT * ui_scale;
        const header_height = BASE_HEADER_HEIGHT * ui_scale;
        const padding = BASE_PADDING * ui_scale;
        const title_scale = BASE_TITLE_SCALE * ui_scale;
        const text_scale = BASE_TEXT_SCALE * ui_scale;

        const panel_top_margin = panel_y + padding + header_height;
        const screen_h: f32 = ui.screen_height;
        const max_possible_rows: usize = @intFromFloat(@divTrunc(screen_h * 0.85 - panel_top_margin, line_height));
        const max_visible_rows = @max(3, @min(max_possible_rows, DebugFeature.count));

        if (scroll_delta_y != 0) {
            const rows_to_scroll: usize = if (@abs(scroll_delta_y) >= 1.0) @as(usize, @intFromFloat(@round(@abs(scroll_delta_y)))) else 0;
            if (scroll_delta_y > 0) {
                if (self.scroll_offset > 0) self.scroll_offset -= @min(rows_to_scroll, self.scroll_offset);
            } else {
                const max_offset = DebugFeature.count - max_visible_rows;
                self.scroll_offset += @min(rows_to_scroll, max_offset - self.scroll_offset);
            }
        }

        const panel_height = header_height + padding * 2 + @as(f32, @floatFromInt(max_visible_rows)) * line_height;
        const panel_rect = Rect{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height };
        const header_rect = Rect{ .x = panel_x, .y = panel_y, .width = panel_width, .height = header_height + padding };

        ui.drawRect(panel_rect, Color.rgba(0.03, 0.05, 0.08, 0.88));
        ui.drawRect(header_rect, Color.rgba(0.10, 0.16, 0.24, 0.94));
        ui.drawRectOutline(panel_rect, Color.rgba(0.45, 0.66, 0.90, 0.95), 2.0 * ui_scale);

        var y = panel_y + padding;
        Font.drawText(ui, "DEBUG MENU", panel_x + padding, y, title_scale, Color.rgba(0.98, 0.99, 1.0, 1.0));
        y += header_height;

        var result: ?ClickResult = null;

        for (0..max_visible_rows) |i| {
            const feature_idx = self.scroll_offset + i;
            if (feature_idx >= DebugFeature.count) break;

            const feature: DebugFeature = @enumFromInt(feature_idx);
            const info = FEATURE_INFOS[feature_idx];
            const state = feature_states[feature_idx];
            const row_rect = Rect{ .x = panel_x + 2 * ui_scale, .y = y - 2 * ui_scale, .width = panel_width - 4 * ui_scale, .height = line_height };
            const hovered = row_rect.contains(mouse_x, mouse_y);

            const stripe_alpha: f32 = if ((feature_idx % 2) == 0) 0.34 else 0.24;
            ui.drawRect(row_rect, Color.rgba(0.05, 0.07, 0.11, stripe_alpha));

            if (hovered) {
                ui.drawRect(row_rect, Color.rgba(0.23, 0.34, 0.50, 0.72));
                if (mouse_clicked) {
                    result = .{ .feature = feature };
                }
            }

            Font.drawText(ui, info.label, panel_x + padding + 4 * ui_scale, y, text_scale, Color.rgba(0.92, 0.95, 0.98, 1.0));

            const state_text = if (state) "ON" else "OFF";
            const state_color = if (state) Color.rgba(0.42, 1.0, 0.48, 1.0) else Color.rgba(0.92, 0.42, 0.42, 1.0);
            const state_x = panel_x + panel_width - padding - 4 * ui_scale - Font.measureTextWidth(state_text, text_scale) - 50.0 * ui_scale;
            Font.drawText(ui, state_text, state_x, y, text_scale, state_color);

            const hotkey_x = panel_x + panel_width - padding - 4 * ui_scale - Font.measureTextWidth(info.hotkey, text_scale);
            Font.drawText(ui, info.hotkey, hotkey_x, y, text_scale, Color.rgba(0.72, 0.76, 0.84, 1.0));

            y += line_height;
        }

        if (DebugFeature.count > max_visible_rows) {
            const scroll_bar_x = panel_x + panel_width - 8.0 * ui_scale;
            const scroll_bar_top = panel_y + header_height + padding;
            const scroll_bar_height = panel_height - header_height - padding * 2;
            const thumb_height = @max(SCROLL_THUMB_MIN_HEIGHT * ui_scale, @as(f32, @floatFromInt(max_visible_rows)) / @as(f32, @floatFromInt(DebugFeature.count)) * scroll_bar_height);
            const thumb_ratio = @as(f32, @floatFromInt(self.scroll_offset)) / @as(f32, @floatFromInt(DebugFeature.count - max_visible_rows));
            const thumb_y = scroll_bar_top + thumb_ratio * (scroll_bar_height - thumb_height);

            ui.drawRect(.{ .x = scroll_bar_x, .y = scroll_bar_top, .width = 4.0 * ui_scale, .height = scroll_bar_height }, Color.rgba(0.25, 0.3, 0.4, 0.6));
            ui.drawRect(.{ .x = scroll_bar_x, .y = thumb_y, .width = 4.0 * ui_scale, .height = thumb_height }, Color.rgba(0.5, 0.65, 0.85, 0.9));
        }

        return result;
    }
};
