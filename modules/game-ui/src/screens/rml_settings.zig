//! RmlUi implementation of the settings menu.
//!
//! Rows are generated rather than kept in RML so the renderer metadata remains
//! the single source of truth for its labels, values, and control kinds.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const RmlPage = @import("../rml_page.zig").Page;
const rml_markup = @import("../rml_markup.zig");
const SettingsUi = @import("../settings_ui.zig");
const settings_pkg = @import("game-core").settings;
const apply_logic = settings_pkg.apply_logic;
const Settings = settings_pkg.Settings;

const SettingsTab = enum { display, camera, world, rendering };
const SettingAction = enum { previous, next, toggle };

/// Settings page backed by `assets/ui/rmlui/settings.rml`.
pub const RmlSettingsScreen = struct {
    context: EngineContext,
    page: RmlPage,
    active_tab: SettingsTab = .display,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlSettingsScreen {
        const self = try allocator.create(RmlSettingsScreen);
        errdefer allocator.destroy(self);
        self.* = .{
            .context = context,
            .page = undefined,
        };
        self.page = try RmlPage.init(context, "assets/ui/rmlui/settings.rml", self, onDocumentAction);
        errdefer self.page.deinit();
        try self.refreshRows();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.deinit();
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.close();
            return;
        }

        // Retain the legacy keyboard tab navigation while buttons remain the
        // primary RmlUi interaction.
        const input = self.context.input;
        if (input.isKeyPressed(.right_arrow) or input.isKeyPressed(.down) or input.isKeyPressed(.tab)) {
            self.active_tab = nextTab(self.active_tab);
            try self.refreshRows();
        } else if (input.isKeyPressed(.left_arrow) or input.isKeyPressed(.up)) {
            self.active_tab = previousTab(self.active_tab);
            try self.refreshRows();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        self.page.draw(ui);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onEnter();
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onExit();
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }

    fn close(self: *@This()) void {
        self.context.saveSettings();
        self.context.screen_manager.popScreen();
    }

    fn onDocumentAction(callback_context: *anyopaque, _: []const u8, target_id: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(callback_context));
        self.handleAction(target_id) catch |err| log.log.err("RmlUi settings action failed: {}", .{err});
    }

    fn handleAction(self: *@This(), target_id: []const u8) !void {
        if (std.mem.eql(u8, target_id, "done")) {
            self.close();
            return;
        }

        if (tabFromId(target_id)) |tab| {
            self.active_tab = tab;
            try self.refreshRows();
            return;
        }

        switch (self.active_tab) {
            .display => self.handleDisplayAction(target_id),
            .camera => self.handleCameraAction(target_id),
            .world => self.handleWorldAction(target_id),
            .rendering => self.handleRenderingAction(target_id),
        }
        try self.refreshRows();
    }

    fn handleDisplayAction(self: *@This(), id: []const u8) void {
        const settings = self.context.settings;
        if (std.mem.eql(u8, id, "resolution-prev") or std.mem.eql(u8, id, "resolution-next")) {
            const index = settings.getResolutionIndex();
            const next_index = if (std.mem.eql(u8, id, "resolution-prev"))
                if (index == 0) settings_pkg.RESOLUTIONS.len - 1 else index - 1
            else
                (index + 1) % settings_pkg.RESOLUTIONS.len;
            settings.setResolutionByIndex(next_index);
            self.context.window_manager.setSize(settings.window_width, settings.window_height);
        } else if (std.mem.eql(u8, id, "vsync-toggle")) {
            settings.vsync = !settings.vsync;
            apply_logic.applyToRenderSettings(settings, self.context.render_settings);
        } else if (std.mem.eql(u8, id, "ui-scale-prev")) {
            settings.ui_scale = settings_pkg.ui_helpers.prevUIScale(settings.ui_scale);
        } else if (std.mem.eql(u8, id, "ui-scale-next")) {
            settings.ui_scale = settings_pkg.ui_helpers.cycleUIScale(settings.ui_scale);
        }
    }

    fn handleCameraAction(self: *@This(), id: []const u8) void {
        const settings = self.context.settings;
        if (std.mem.eql(u8, id, "sensitivity-prev") and settings.mouse_sensitivity > 10.0) {
            settings.mouse_sensitivity -= 5.0;
        } else if (std.mem.eql(u8, id, "sensitivity-next") and settings.mouse_sensitivity < 200.0) {
            settings.mouse_sensitivity += 5.0;
        } else if (std.mem.eql(u8, id, "fov-prev") and settings.fov > 30.0) {
            settings.fov -= 5.0;
        } else if (std.mem.eql(u8, id, "fov-next") and settings.fov < 120.0) {
            settings.fov += 5.0;
        }
    }

    fn handleWorldAction(self: *@This(), id: []const u8) void {
        const settings = self.context.settings;
        if (std.mem.eql(u8, id, "render-distance-prev") and settings.render_distance > 2) {
            settings.render_distance -= 1;
        } else if (std.mem.eql(u8, id, "render-distance-next") and settings.render_distance < std.math.maxInt(i32)) {
            settings.render_distance += 1;
        }
    }

    fn handleRenderingAction(self: *@This(), id: []const u8) void {
        if (std.mem.eql(u8, id, "preset-prev")) {
            self.stepOverallPreset(.previous);
        } else if (std.mem.eql(u8, id, "preset-next")) {
            self.stepOverallPreset(.next);
        } else if (std.mem.eql(u8, id, "wireframe-toggle")) {
            self.context.settings.wireframe_enabled = !self.context.settings.wireframe_enabled;
            apply_logic.applyToRenderSettings(self.context.settings, self.context.render_settings);
        } else {
            inline for (RENDER_SETTING_NAMES) |name| {
                if (settingActionFromId(name, id)) |action| self.applyMetadataAction(name, action);
            }
        }
    }

    fn stepOverallPreset(self: *@This(), action: SettingAction) void {
        const settings = self.context.settings;
        const loaded_count = settings_pkg.json_presets.count();
        const preset_index = if (loaded_count > 0) settings_pkg.json_presets.getIndex(settings) else 0;
        const preset_count = loaded_count + 1;
        if (loaded_count == 0) return;
        const index = switch (action) {
            .previous => if (preset_index == 0) preset_count - 1 else preset_index - 1,
            .next => (preset_index + 1) % preset_count,
            .toggle => return,
        };
        if (index < loaded_count) {
            settings_pkg.json_presets.apply(settings, index);
            SettingsUi.applyPresetSideEffects(settings, self.context.render_settings);
        }
    }

    fn applyMetadataAction(self: *@This(), comptime name: []const u8, action: SettingAction) void {
        const settings = self.context.settings;
        const meta = @field(Settings.metadata, name);
        const value = &@field(settings, name);
        const Value = @TypeOf(value.*);
        const old_value = value.*;

        switch (meta.kind) {
            .toggle => {
                if (action == .toggle) value.* = !value.*;
            },
            .choice => |choice| if (choice.values) |values| {
                var current: usize = 0;
                for (values, 0..) |candidate, i| {
                    if (candidate == value.*) current = i;
                }
                if (action == .previous) {
                    const previous = if (current == 0) values.len - 1 else current - 1;
                    value.* = @as(Value, @intCast(values[previous]));
                } else if (action == .next) {
                    value.* = @as(Value, @intCast(values[(current + 1) % values.len]));
                }
            },
            .slider => |slider| {
                if (action == .previous) {
                    if (value.* - slider.step < slider.min - 0.001) value.* = slider.max - slider.step else value.* -= slider.step;
                } else if (action == .next) {
                    if (value.* + slider.step > slider.max + 0.001) value.* = slider.max - slider.step else value.* += slider.step;
                }
            },
            .int_range => |range| {
                if (action == .previous) {
                    if (value.* - range.step < range.min) value.* = range.max - range.step else value.* -= range.step;
                } else if (action == .next) {
                    if (value.* + range.step > range.max) value.* = range.max - range.step else value.* += range.step;
                }
            },
        }

        if (value.* != old_value) {
            SettingsUi.applyChangedSetting(name, settings, self.context.render_settings);
            if (comptime std.mem.eql(u8, name, "msaa_samples")) {
                self.context.render_settings.setMSAA(settings.msaa_samples);
            }
        }
    }

    fn refreshRows(self: *@This()) !void {
        var markup = std.ArrayList(u8).empty;
        defer markup.deinit(self.context.allocator);

        switch (self.active_tab) {
            .display => try self.appendDisplayRows(&markup),
            .camera => try self.appendCameraRows(&markup),
            .world => try self.appendWorldRows(&markup),
            .rendering => try self.appendRenderingRows(&markup),
        }

        const document_markup = try rml_markup.sentinel(&markup, self.context.allocator);
        if (!self.page.backend.setInnerRml(self.page.document, "settings-list", document_markup.ptr)) {
            log.log.warn("RmlUi settings list element was not found", .{});
        }
        self.setTabClasses();
    }

    fn setTabClasses(self: *@This()) void {
        _ = self.page.backend.setClass(self.page.document, "tab-display", "active", self.active_tab == .display);
        _ = self.page.backend.setClass(self.page.document, "tab-camera", "active", self.active_tab == .camera);
        _ = self.page.backend.setClass(self.page.document, "tab-world", "active", self.active_tab == .world);
        _ = self.page.backend.setClass(self.page.document, "tab-rendering", "active", self.active_tab == .rendering);
    }

    fn appendDisplayRows(self: *@This(), out: *std.ArrayList(u8)) !void {
        const settings = self.context.settings;
        try appendSection(out, self.context.allocator, "WINDOW");
        try appendStepperRow(out, self.context.allocator, "RESOLUTION", "Swap the output size instantly.", settings_pkg.RESOLUTIONS[settings.getResolutionIndex()].label, "resolution");
        try appendToggleRow(out, self.context.allocator, "VSYNC", "Lock presentation to display refresh.", settings.vsync, "vsync");
        try appendSection(out, self.context.allocator, "INTERFACE");
        try appendStepperRow(out, self.context.allocator, "UI SCALE", "Resize the menu system.", settings_pkg.ui_helpers.getUIScaleLabel(settings.ui_scale), "ui-scale");
    }

    fn appendCameraRows(self: *@This(), out: *std.ArrayList(u8)) !void {
        var buffer: [32]u8 = undefined;
        const settings = self.context.settings;
        try appendSection(out, self.context.allocator, "MOUSE");
        const sensitivity = try std.fmt.bufPrint(&buffer, "{d}", .{@as(i32, @intFromFloat(settings.mouse_sensitivity))});
        try appendStepperRow(out, self.context.allocator, "SENSITIVITY", "Mouse movement response.", sensitivity, "sensitivity");
        try appendSection(out, self.context.allocator, "VIEW");
        const fov = try std.fmt.bufPrint(&buffer, "{d} FOV", .{@as(i32, @intFromFloat(settings.fov))});
        try appendStepperRow(out, self.context.allocator, "FIELD OF VIEW", "Camera lens angle.", fov, "fov");
    }

    fn appendWorldRows(self: *@This(), out: *std.ArrayList(u8)) !void {
        var buffer: [32]u8 = undefined;
        const settings = self.context.settings;
        try appendSection(out, self.context.allocator, "DISTANCE");
        const render_distance = try std.fmt.bufPrint(&buffer, "{} CHUNKS", .{settings.render_distance});
        try appendStepperRow(out, self.context.allocator, "RENDER DISTANCE", "Full-detail chunk radius.", render_distance, "render-distance");
    }

    fn appendRenderingRows(self: *@This(), out: *std.ArrayList(u8)) !void {
        const settings = self.context.settings;
        try appendSection(out, self.context.allocator, "BASELINE");
        const preset_index = if (settings_pkg.json_presets.count() > 0) settings_pkg.json_presets.getIndex(settings) else 0;
        try appendStepperRow(out, self.context.allocator, "OVERALL QUALITY", "Preset target for renderer cost and quality.", SettingsUi.getPresetLabel(preset_index), "preset");
        try appendToggleRow(out, self.context.allocator, "WIREFRAME", "Debug mesh visibility.", settings.wireframe_enabled, "wireframe");

        try appendMetadataSection(out, self.context.allocator, settings, "MATERIALS", MATERIAL_SETTING_NAMES);
        try appendMetadataSection(out, self.context.allocator, settings, "SHADOWS", SHADOW_SETTING_NAMES);
        try appendMetadataSection(out, self.context.allocator, settings, "IMAGE", IMAGE_SETTING_NAMES);
        try appendMetadataSection(out, self.context.allocator, settings, "ATMOSPHERE AND GI", ATMOSPHERE_SETTING_NAMES);
        try appendMetadataSection(out, self.context.allocator, settings, "DYNAMIC RESOLUTION", DYNAMIC_RESOLUTION_SETTING_NAMES);
    }
};

const MATERIAL_SETTING_NAMES = [_][]const u8{ "textures_enabled", "pbr_enabled", "pbr_quality", "anisotropic_filtering", "max_texture_resolution", "water_quality" };
const SHADOW_SETTING_NAMES = [_][]const u8{ "shadow_quality", "shadow_pcf_samples", "shadow_cascade_blend", "shadow_distance", "shadow_caster_distance" };
const IMAGE_SETTING_NAMES = [_][]const u8{ "msaa_samples", "taa_enabled", "taa_blend_factor", "taa_velocity_rejection", "fxaa_enabled", "ssao_enabled", "bloom_enabled", "bloom_intensity", "vignette_enabled", "vignette_intensity", "film_grain_enabled", "film_grain_intensity" };
const ATMOSPHERE_SETTING_NAMES = [_][]const u8{ "volumetric_density", "volumetric_steps", "volumetric_scattering", "lpv_enabled", "lpv_quality_preset", "lpv_intensity", "lpv_cell_size" };
const DYNAMIC_RESOLUTION_SETTING_NAMES = [_][]const u8{ "dynamic_resolution_enabled", "dynamic_resolution_min_scale", "dynamic_resolution_max_scale", "target_fps" };
const RENDER_SETTING_NAMES = MATERIAL_SETTING_NAMES ++ SHADOW_SETTING_NAMES ++ IMAGE_SETTING_NAMES ++ ATMOSPHERE_SETTING_NAMES ++ DYNAMIC_RESOLUTION_SETTING_NAMES;

fn appendMetadataSection(out: *std.ArrayList(u8), allocator: std.mem.Allocator, settings: *Settings, label: []const u8, comptime names: anytype) !void {
    try appendSection(out, allocator, label);
    inline for (names) |name| try appendMetadataRow(out, allocator, settings, name);
}

fn appendMetadataRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, settings: *Settings, comptime name: []const u8) !void {
    var value_buffer: [64]u8 = undefined;
    const meta = @field(Settings.metadata, name);
    const value = @field(settings, name);
    const value_label = try metadataValueLabel(name, value, &value_buffer);
    switch (meta.kind) {
        .toggle => try appendToggleRow(out, allocator, meta.label, settingDescription(name), value, "setting-" ++ name),
        else => try appendStepperRow(out, allocator, meta.label, settingDescription(name), value_label, "setting-" ++ name),
    }
}

fn metadataValueLabel(comptime name: []const u8, value: anytype, buffer: []u8) ![]const u8 {
    const meta = @field(Settings.metadata, name);
    return switch (meta.kind) {
        .toggle => if (value) "ENABLED" else "DISABLED",
        .choice => |choice| blk: {
            if (choice.values) |values| {
                for (values, 0..) |candidate, index| {
                    if (candidate == value) break :blk if (index < choice.labels.len) choice.labels[index] else "UNKNOWN";
                }
            }
            break :blk "UNKNOWN";
        },
        .slider => try std.fmt.bufPrint(buffer, "{d:.2}", .{value}),
        .int_range => try std.fmt.bufPrint(buffer, "{d}", .{value}),
    };
}

fn appendSection(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8) !void {
    try out.appendSlice(allocator, "<div class=\"section-label\">");
    try rml_markup.appendEscaped(out, allocator, label);
    try out.appendSlice(allocator, "</div>");
}

fn appendStepperRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, description: []const u8, value: []const u8, id_prefix: []const u8) !void {
    try appendRowOpen(out, allocator, label, description);
    try out.appendSlice(allocator, "<div class=\"setting-control\"><button id=\"");
    try out.appendSlice(allocator, id_prefix);
    try out.appendSlice(allocator, "-prev\">-</button><span class=\"setting-value\">");
    try rml_markup.appendEscaped(out, allocator, value);
    try out.appendSlice(allocator, "</span><button id=\"");
    try out.appendSlice(allocator, id_prefix);
    try out.appendSlice(allocator, "-next\">+</button></div></div>");
}

fn appendToggleRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, description: []const u8, enabled: bool, id_prefix: []const u8) !void {
    try appendRowOpen(out, allocator, label, description);
    try out.appendSlice(allocator, "<div class=\"setting-control\"><button id=\"");
    try out.appendSlice(allocator, id_prefix);
    try out.appendSlice(allocator, "-toggle\" class=\"");
    if (enabled) try out.appendSlice(allocator, "primary");
    try out.appendSlice(allocator, "\">");
    try out.appendSlice(allocator, if (enabled) "ENABLED" else "DISABLED");
    try out.appendSlice(allocator, "</button></div></div>");
}

fn appendRowOpen(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, description: []const u8) !void {
    try out.appendSlice(allocator, "<div class=\"setting-row\"><div class=\"setting-copy\"><strong>");
    try rml_markup.appendEscaped(out, allocator, label);
    try out.appendSlice(allocator, "</strong><span>");
    try rml_markup.appendEscaped(out, allocator, description);
    try out.appendSlice(allocator, "</span></div>");
}

fn settingActionFromId(comptime name: []const u8, id: []const u8) ?SettingAction {
    if (std.mem.eql(u8, id, "setting-" ++ name ++ "-prev")) return .previous;
    if (std.mem.eql(u8, id, "setting-" ++ name ++ "-next")) return .next;
    if (std.mem.eql(u8, id, "setting-" ++ name ++ "-toggle")) return .toggle;
    return null;
}

fn tabFromId(id: []const u8) ?SettingsTab {
    if (std.mem.eql(u8, id, "tab-display")) return .display;
    if (std.mem.eql(u8, id, "tab-camera")) return .camera;
    if (std.mem.eql(u8, id, "tab-world")) return .world;
    if (std.mem.eql(u8, id, "tab-rendering")) return .rendering;
    return null;
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

test "metadata settings produce RmlUi rows" {
    var settings = Settings{};
    var markup = std.ArrayList(u8).empty;
    defer markup.deinit(std.testing.allocator);

    inline for (RENDER_SETTING_NAMES) |name| {
        try appendMetadataRow(&markup, std.testing.allocator, &settings, name);
    }
    try std.testing.expect(std.mem.indexOf(u8, markup.items, "setting-shadow_quality-next") != null);
    try std.testing.expect(std.mem.indexOf(u8, markup.items, "setting-dynamic_resolution_enabled-toggle") != null);
}
