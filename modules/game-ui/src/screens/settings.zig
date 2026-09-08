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

const PANEL_WIDTH_MAX = 1360.0;
const PANEL_HEIGHT_MAX = 820.0;

const StepResult = SettingsUi.StepResult;

const SettingsTab = enum {
    display,
    camera,
    world,
    rendering,
};

pub const SettingsScreen = struct {
    context: EngineContext,
    active_tab: SettingsTab,
    render_scroll_offset: f32,

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
            .active_tab = .display,
            .render_scroll_offset = 0.0,
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
            return;
        }
        const input = self.context.input;
        if (input.isKeyPressed(.right_arrow) or input.isKeyPressed(.down) or input.isKeyPressed(.tab)) self.active_tab = nextTab(self.active_tab);
        if (input.isKeyPressed(.left_arrow) or input.isKeyPressed(.up)) self.active_tab = previousTab(self.active_tab);
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

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .settings);

        const margin: f32 = 34.0 * ui_scale;
        const panel_w: f32 = @min(screen_w - margin * 2.0, 1080.0 * ui_scale);
        const panel_h: f32 = @min(screen_h - margin * 2.0, 760.0 * ui_scale);
        const panel_x = (screen_w - panel_w) * 0.5;
        const panel_y = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "PREFERENCES", "SETTINGS", "Changes apply immediately and save when you leave.");

        const nav_h = 48.0 * ui_scale;
        drawTabs(ui, self, shell.content.x, shell.content.y, shell.content.width, nav_h, false, mouse_x, mouse_y, mouse_clicked, ui_scale);

        const body = Rect{
            .x = shell.content.x,
            .y = shell.content.y + nav_h + 18.0 * ui_scale,
            .width = shell.content.width,
            .height = shell.content.height - nav_h - 18.0 * ui_scale,
        };
        const inner = Rect{
            .x = body.x + 4.0 * ui_scale,
            .y = body.y + 72.0 * ui_scale,
            .width = body.width - 8.0 * ui_scale,
            .height = body.height - 76.0 * ui_scale,
        };

        Font.drawText(ui, tabLabel(self.active_tab), body.x + 4.0 * ui_scale, body.y + 2.0 * ui_scale, 1.52 * ui_scale, Theme.title);
        Font.drawText(ui, tabDescription(self.active_tab), body.x + 4.0 * ui_scale, body.y + 37.0 * ui_scale, 0.88 * ui_scale, Theme.muted);
        ui.drawRect(.{ .x = body.x + 4.0 * ui_scale, .y = body.y + 60.0 * ui_scale, .width = body.width - 8.0 * ui_scale, .height = 1.0 * ui_scale }, Theme.outline);

        const layout = columnLayout(inner, ui_scale);
        const row_h: f32 = 72.0 * ui_scale;
        const label_scale: f32 = 1.08 * ui_scale;
        const value_scale: f32 = 1.00 * ui_scale;
        const button_scale: f32 = 1.00 * ui_scale;

        switch (self.active_tab) {
            .display => drawDisplayTab(ui, ctx, settings, rs, layout, row_h, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale),
            .camera => drawCameraTab(ui, settings, layout, row_h, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale),
            .world => drawWorldTab(ui, settings, rs, layout, row_h, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale),
            .rendering => drawRenderingTab(ui, self, ctx, settings, rs, inner, layout, row_h, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, ui_scale),
        }

        const done_w: f32 = 176.0 * ui_scale;
        if (Theme.drawButton(ui, .{ .x = shell.content.x + shell.content.width - done_w, .y = shell.footer_y, .width = done_w, .height = 46.0 * ui_scale }, "DONE", button_scale, mouse_x, mouse_y, mouse_clicked, .primary, ui_scale)) {
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

const ColumnLayout = struct {
    left_x: f32,
    right_x: f32,
    col_w: f32,
    two_column: bool,
    top_y: f32,
};

fn columnLayout(inner: Rect, scale: f32) ColumnLayout {
    const two_column = false;
    const gap: f32 = 18.0 * scale;
    const col_w: f32 = if (two_column) (inner.width - gap) * 0.5 else inner.width;
    return .{
        .left_x = inner.x,
        .right_x = if (two_column) inner.x + col_w + gap else inner.x,
        .col_w = col_w,
        .two_column = two_column,
        .top_y = inner.y,
    };
}

fn drawTabs(ui: *UISystem, self: *SettingsScreen, x: f32, y: f32, w: f32, h: f32, vertical: bool, mx: f32, my: f32, clicked: bool, scale: f32) void {
    const tabs = [_]SettingsTab{ .display, .camera, .world, .rendering };
    const gap: f32 = 8.0 * scale;
    const tab_w = if (vertical) w else (w - gap * @as(f32, @floatFromInt(tabs.len - 1))) / @as(f32, @floatFromInt(tabs.len));
    const tab_h = if (vertical) 58.0 * scale else h;
    if (vertical) {
        Font.drawText(ui, "SETTINGS", x, y, 0.90 * scale, Theme.muted);
        ui.drawRect(.{ .x = x, .y = y + 24.0 * scale, .width = w, .height = 1.0 * scale }, Theme.outline);
    }
    for (tabs, 0..) |tab, i| {
        const tx = if (vertical) x else x + @as(f32, @floatFromInt(i)) * (tab_w + gap);
        const ty = if (vertical) y + 40.0 * scale + @as(f32, @floatFromInt(i)) * (tab_h + gap) else y;
        const active = self.active_tab == tab;
        if (if (vertical)
            Theme.drawNavItem(ui, .{ .x = tx, .y = ty, .width = tab_w, .height = tab_h }, tabLabel(tab), i, active, mx, my, clicked, scale)
        else
            Theme.drawButtonFocused(ui, .{ .x = tx, .y = ty, .width = tab_w, .height = tab_h }, tabLabel(tab), 0.88 * scale, mx, my, clicked, if (active) .primary else .ghost, active, scale))
        {
            self.active_tab = tab;
        }
    }
    if (vertical) {
        ui.drawRect(.{ .x = x + w + 10.0 * scale, .y = y, .width = 1.0 * scale, .height = h }, Theme.outline);
        Font.drawText(ui, "ARROWS  Switch section", x, y + h - 18.0 * scale, 0.84 * scale, Theme.dim);
    }
}

fn nextTab(tab: SettingsTab) SettingsTab {
    return switch (tab) {
        .display => .camera,
        .camera => .world,
        .world => .rendering,
        .rendering => .display,
    };
}

fn previousTab(tab: SettingsTab) SettingsTab {
    return switch (tab) {
        .display => .rendering,
        .camera => .display,
        .world => .camera,
        .rendering => .world,
    };
}

fn tabLabel(tab: SettingsTab) []const u8 {
    return switch (tab) {
        .display => "DISPLAY",
        .camera => "CAMERA",
        .world => "WORLD",
        .rendering => "RENDERING",
    };
}

fn tabDescription(tab: SettingsTab) []const u8 {
    return switch (tab) {
        .display => "Window, presentation, and interface scale.",
        .camera => "Mouse feel and view framing.",
        .world => "Terrain distance and world streaming.",
        .rendering => "Material toggles and advanced renderer settings.",
    };
}

fn drawDisplayTab(ui: *UISystem, ctx: EngineContext, settings: anytype, rs: anytype, layout: ColumnLayout, row_h: f32, label_scale: f32, value_scale: f32, button_scale: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, scale: f32) void {
    var y_left = layout.top_y;
    Theme.drawSectionLabel(ui, layout.left_x, y_left, "WINDOW", scale);
    y_left += 28.0 * scale;

    const res_idx = settings.getResolutionIndex();
    const res_label = settings_pkg.RESOLUTIONS[res_idx].label;
    if (drawStepperRow(ui, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, "RESOLUTION", "Swap the output size instantly.", res_label, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale)) |step| {
        const new_idx = switch (step) {
            .previous => if (res_idx == 0) settings_pkg.RESOLUTIONS.len - 1 else res_idx - 1,
            .next => (res_idx + 1) % settings_pkg.RESOLUTIONS.len,
            .none => res_idx,
        };
        settings.setResolutionByIndex(new_idx);
        ctx.window_manager.setSize(settings.window_width, settings.window_height);
    }
    y_left += row_h + 8.0 * scale;

    if (drawToggleRow(ui, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, "VSYNC", "Lock presentation to display refresh.", settings.vsync, label_scale, value_scale, mouse_x, mouse_y, mouse_clicked, scale)) {
        settings.vsync = !settings.vsync;
        SettingsUi.applyChangedSetting("vsync", settings, rs);
    }

    var y_right = if (layout.two_column) layout.top_y else y_left + row_h + 22.0 * scale;
    Theme.drawSectionLabel(ui, layout.right_x, y_right, "INTERFACE", scale);
    y_right += 28.0 * scale;

    const ui_scale_label = settings_pkg.ui_helpers.getUIScaleLabel(settings.ui_scale);
    if (drawStepperRow(ui, .{ .x = layout.right_x, .y = y_right, .width = layout.col_w, .height = row_h }, "UI SCALE", "Resize the menu system.", ui_scale_label, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale)) |step| {
        if (step == .previous) settings.ui_scale = settings_pkg.ui_helpers.prevUIScale(settings.ui_scale);
        if (step == .next) settings.ui_scale = settings_pkg.ui_helpers.cycleUIScale(settings.ui_scale);
    }
}

fn drawCameraTab(ui: *UISystem, settings: anytype, layout: ColumnLayout, row_h: f32, label_scale: f32, value_scale: f32, button_scale: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, scale: f32) void {
    var num_buf: [32]u8 = undefined;

    var y_left = layout.top_y;
    Theme.drawSectionLabel(ui, layout.left_x, y_left, "MOUSE", scale);
    y_left += 28.0 * scale;

    const sensitivity_label = std.fmt.bufPrint(&num_buf, "{d}", .{@as(i32, @intFromFloat(settings.mouse_sensitivity))}) catch "?";
    if (drawStepperRow(ui, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, "SENSITIVITY", "Mouse movement response.", sensitivity_label, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale)) |step| {
        if (step == .previous and settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
        if (step == .next and settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
    }

    var y_right = if (layout.two_column) layout.top_y else y_left + row_h + 22.0 * scale;
    Theme.drawSectionLabel(ui, layout.right_x, y_right, "VIEW", scale);
    y_right += 28.0 * scale;

    const fov_label = std.fmt.bufPrint(&num_buf, "{d} FOV", .{@as(i32, @intFromFloat(settings.fov))}) catch "?";
    if (drawStepperRow(ui, .{ .x = layout.right_x, .y = y_right, .width = layout.col_w, .height = row_h }, "FIELD OF VIEW", "Camera lens angle.", fov_label, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale)) |step| {
        if (step == .previous and settings.fov > 30.0) settings.fov -= 5.0;
        if (step == .next and settings.fov < 120.0) settings.fov += 5.0;
    }
}

fn drawWorldTab(ui: *UISystem, settings: anytype, rs: anytype, layout: ColumnLayout, row_h: f32, label_scale: f32, value_scale: f32, button_scale: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, scale: f32) void {
    _ = rs;
    var num_buf: [32]u8 = undefined;

    var y_left = layout.top_y;
    Theme.drawSectionLabel(ui, layout.left_x, y_left, "DISTANCE", scale);
    y_left += 28.0 * scale;

    const render_distance_label = std.fmt.bufPrint(&num_buf, "{} CHUNKS", .{settings.render_distance}) catch "?";
    if (drawStepperRow(ui, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, "RENDER DISTANCE", "Full-detail chunk radius.", render_distance_label, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale)) |step| {
        if (step == .previous and settings.render_distance > 2) settings.render_distance -= 1;
        if (step == .next and settings.render_distance < std.math.maxInt(i32)) {
            settings.render_distance += 1;
        }
    }
}

fn drawRenderingTab(ui: *UISystem, self: *SettingsScreen, ctx: EngineContext, settings: *Settings, rs: anytype, inner: Rect, layout: ColumnLayout, row_h: f32, label_scale: f32, value_scale: f32, button_scale: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, scale: f32) void {
    const row_gap = 8.0 * scale;
    const section_h = 28.0 * scale;
    const material_settings = .{ "textures_enabled", "pbr_enabled", "pbr_quality", "anisotropic_filtering", "max_texture_resolution", "water_quality" };
    const shadow_settings = .{ "shadow_quality", "shadow_pcf_samples", "shadow_cascade_blend", "shadow_distance", "shadow_caster_distance" };
    const image_settings = .{ "taa_enabled", "taa_blend_factor", "taa_velocity_rejection", "fxaa_enabled", "ssao_enabled", "bloom_enabled", "bloom_intensity", "vignette_enabled", "vignette_intensity", "film_grain_enabled", "film_grain_intensity" };
    const atmosphere_settings = .{ "volumetric_density", "volumetric_steps", "volumetric_scattering", "lpv_enabled", "lpv_quality_preset", "lpv_intensity", "lpv_cell_size" };
    const dynamic_resolution_settings = .{ "dynamic_resolution_enabled", "dynamic_resolution_min_scale", "dynamic_resolution_max_scale", "target_fps" };
    const left_sections = .{ "BASELINE", "MATERIALS", "SHADOWS" };
    const right_sections = .{ "IMAGE", "ATMOSPHERE AND GI", "DYNAMIC RESOLUTION" };
    const baseline_rows = .{ "OVERALL QUALITY", "WIREFRAME" };

    const left_content_h = renderingContentHeight(left_sections.len, baseline_rows.len + material_settings.len + shadow_settings.len, row_h, row_gap, section_h, scale);
    const right_content_h = renderingContentHeight(right_sections.len, image_settings.len + atmosphere_settings.len + dynamic_resolution_settings.len, row_h, row_gap, section_h, scale);
    const column_gap: f32 = 28.0 * scale;
    const total_content_h = if (layout.two_column)
        @max(left_content_h, right_content_h)
    else
        left_content_h + column_gap + right_content_h;
    const max_scroll = @max(0.0, total_content_h - inner.height);
    self.render_scroll_offset -= ctx.input.getScrollDelta().y * 36.0 * scale;
    self.render_scroll_offset = @max(0.0, @min(self.render_scroll_offset, max_scroll));
    Theme.drawScrollbar(ui, inner.x + inner.width - 10.0 * scale, inner.y, inner.height, total_content_h, inner.height, self.render_scroll_offset, max_scroll, scale);

    const top = inner.y;
    const bottom = inner.y + inner.height;
    var y_left = layout.top_y - self.render_scroll_offset;
    var y_right = (if (layout.two_column) layout.top_y else layout.top_y + left_content_h + column_gap) - self.render_scroll_offset;

    drawRenderSection(ui, layout.left_x, y_left, left_sections[0], top, bottom, scale);
    y_left += section_h;
    y_left = drawPresetRow(ui, settings, rs, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    if (rowVisible(y_left, row_h, top, bottom)) {
        if (drawToggleRow(ui, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, "WIREFRAME", "Debug mesh visibility.", settings.wireframe_enabled, label_scale, value_scale, mouse_x, mouse_y, mouse_clicked, scale)) {
            settings.wireframe_enabled = !settings.wireframe_enabled;
            SettingsUi.applyChangedSetting("wireframe_enabled", settings, rs);
        }
    }
    y_left += row_h + row_gap;
    drawRenderSection(ui, layout.left_x, y_left, left_sections[1], top, bottom, scale);
    y_left += section_h;
    inline for (material_settings) |name| {
        y_left = drawSettingRow(ui, name, settings, rs, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    }

    drawRenderSection(ui, layout.left_x, y_left, left_sections[2], top, bottom, scale);
    y_left += section_h;
    inline for (shadow_settings) |name| {
        y_left = drawSettingRow(ui, name, settings, rs, .{ .x = layout.left_x, .y = y_left, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    }

    drawRenderSection(ui, layout.right_x, y_right, right_sections[0], top, bottom, scale);
    y_right += section_h;
    inline for (image_settings) |name| {
        y_right = drawSettingRow(ui, name, settings, rs, .{ .x = layout.right_x, .y = y_right, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    }

    drawRenderSection(ui, layout.right_x, y_right, right_sections[1], top, bottom, scale);
    y_right += section_h;
    inline for (atmosphere_settings) |name| {
        y_right = drawSettingRow(ui, name, settings, rs, .{ .x = layout.right_x, .y = y_right, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    }

    drawRenderSection(ui, layout.right_x, y_right, right_sections[2], top, bottom, scale);
    y_right += section_h;
    inline for (dynamic_resolution_settings) |name| {
        y_right = drawSettingRow(ui, name, settings, rs, .{ .x = layout.right_x, .y = y_right, .width = layout.col_w, .height = row_h }, top, bottom, label_scale, value_scale, button_scale, mouse_x, mouse_y, mouse_clicked, scale) + row_gap;
    }
}

fn renderingContentHeight(section_count: usize, row_count: usize, row_h: f32, row_gap: f32, section_h: f32, scale: f32) f32 {
    return @as(f32, @floatFromInt(section_count)) * section_h + @as(f32, @floatFromInt(row_count)) * (row_h + row_gap) + 16.0 * scale;
}

fn rowVisible(y: f32, h: f32, top: f32, bottom: f32) bool {
    return y >= top and y + h <= bottom;
}

fn drawRenderSection(ui: *UISystem, x: f32, y: f32, label: []const u8, top: f32, bottom: f32, scale: f32) void {
    if (rowVisible(y, 24.0 * scale, top, bottom)) Theme.drawSectionLabel(ui, x, y, label, scale);
}

fn drawPresetRow(ui: *UISystem, settings: *Settings, rs: anytype, row: Rect, top: f32, bottom: f32, label_scale: f32, value_scale: f32, button_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) f32 {
    if (!rowVisible(row.y, row.height, top, bottom)) return row.y + row.height;
    const loaded_preset_count = settings_pkg.json_presets.count();
    const preset_idx = if (loaded_preset_count > 0) settings_pkg.json_presets.getIndex(settings) else 0;
    const preset_count = loaded_preset_count + 1;
    if (drawStepperRow(ui, row, "OVERALL QUALITY", "Preset target for renderer cost and quality.", SettingsUi.getPresetLabel(preset_idx), label_scale, value_scale, button_scale, mx, my, clicked, scale)) |step| {
        if (loaded_preset_count > 0 and step == .previous) {
            const prev_idx = if (preset_idx == 0) preset_count - 1 else preset_idx - 1;
            if (prev_idx < loaded_preset_count) {
                settings_pkg.json_presets.apply(settings, prev_idx);
                SettingsUi.applyPresetSideEffects(settings, rs);
            }
        } else if (loaded_preset_count > 0 and step == .next) {
            const next_idx = (preset_idx + 1) % preset_count;
            if (next_idx < loaded_preset_count) {
                settings_pkg.json_presets.apply(settings, next_idx);
                SettingsUi.applyPresetSideEffects(settings, rs);
            }
        }
    }
    return row.y + row.height;
}

fn drawSettingRow(ui: *UISystem, comptime name: []const u8, settings: *Settings, rs: anytype, row: Rect, top: f32, bottom: f32, label_scale: f32, value_scale: f32, button_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) f32 {
    if (!rowVisible(row.y, row.height, top, bottom)) return row.y + row.height;

    var buf: [64]u8 = undefined;
    const meta = @field(Settings.metadata, name);
    const val_ptr = &@field(settings, name);
    const val_type = @TypeOf(val_ptr.*);
    const old_val = val_ptr.*;

    Theme.drawOptionRow(ui, row, meta.label, settingDescription(name), label_scale, SettingsUi.rowHighlight(name, val_ptr.*), scale);

    switch (meta.kind) {
        .toggle => {
            if (SettingsUi.drawToggleControl(ui, row, val_ptr.*, value_scale, mx, my, clicked, scale)) {
                val_ptr.* = !val_ptr.*;
            }
        },
        .choice => |choice| {
            var current_label: []const u8 = "UNKNOWN";
            var current_idx: usize = 0;
            if (choice.values) |values| {
                for (values, 0..) |v, i| {
                    if (v == val_ptr.*) {
                        current_idx = i;
                        if (i < choice.labels.len) current_label = choice.labels[i];
                        break;
                    }
                }
                const step = SettingsUi.drawStepperControl(ui, row, current_label, value_scale, button_scale, mx, my, clicked, scale);
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
            const step = SettingsUi.drawStepperControl(ui, row, val_str, value_scale, button_scale, mx, my, clicked, scale);
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
            const step = SettingsUi.drawStepperControl(ui, row, val_str, value_scale, button_scale, mx, my, clicked, scale);
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

    if (comptime std.mem.eql(u8, name, "lpv_quality_preset")) {
        const legend = SettingsUi.getLPVQualityLegend(settings.lpv_quality_preset);
        Font.drawText(ui, legend, row.x + row.width - 338.0 * scale, row.y + row.height - 16.0 * scale, 0.82 * scale, Theme.signal);
    }

    if (val_ptr.* != old_val) {
        SettingsUi.applyChangedSetting(name, settings, rs);
    }

    return row.y + row.height;
}

fn drawStepperRow(ui: *UISystem, rect: Rect, label: []const u8, description: []const u8, value: []const u8, label_scale: f32, value_scale: f32, button_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) ?StepResult {
    Theme.drawOptionRow(ui, rect, label, description, label_scale, false, scale);
    const result = SettingsUi.drawStepperControl(ui, rect, value, value_scale, button_scale, mx, my, clicked, scale);
    return if (result == .none) null else result;
}

fn drawToggleRow(ui: *UISystem, rect: Rect, label: []const u8, description: []const u8, enabled: bool, label_scale: f32, value_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    Theme.drawOptionRow(ui, rect, label, description, label_scale, enabled, scale);
    return SettingsUi.drawToggleControl(ui, rect, enabled, value_scale, mx, my, clicked, scale);
}

fn settingDescription(comptime name: []const u8) []const u8 {
    return if (comptime std.mem.eql(u8, name, "textures_enabled"))
        "Material atlas sampling."
    else if (comptime std.mem.eql(u8, name, "shadow_quality"))
        "Depth map budget for directional shadows."
    else if (comptime std.mem.eql(u8, name, "shadow_pcf_samples"))
        "PCF sample count and edge softness."
    else if (comptime std.mem.eql(u8, name, "pbr_enabled"))
        "Material response and packed surface channels."
    else if (comptime std.mem.eql(u8, name, "taa_enabled"))
        "Temporal anti-aliasing pipeline."
    else if (comptime std.mem.eql(u8, name, "max_texture_resolution"))
        "Upper bound for atlas texture detail."
    else if (comptime std.mem.eql(u8, name, "lpv_enabled"))
        "Light propagation volume GI experiment."
    else if (comptime std.mem.eql(u8, name, "volumetric_density"))
        "Fog volume strength."
    else if (comptime std.mem.eql(u8, name, "dynamic_resolution_enabled"))
        "Scale rendering resolution to hold target FPS."
    else
        @field(Settings.metadata, name).description;
}
