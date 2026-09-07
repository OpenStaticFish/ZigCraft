//! Settings system for persisting user input preferences.
//!
//! Handles loading and saving of input-related game settings.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs");
const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const GameAction = input_mapper_pkg.GameAction;
const ActionBinding = input_mapper_pkg.ActionBinding;
const log = @import("engine-core").log;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub const InputSettings = struct {
    allocator: std.mem.Allocator,
    input_mapper: InputMapper,

    pub const SETTINGS_FILENAME = "settings.json";
    pub const APP_NAME = "zigcraft";
    /// Maximum size of the settings file (1MB).
    pub const MAX_SETTINGS_SIZE = 1024 * 1024;
    /// Current version of the settings schema.
    /// Version 2 introduced GameAction enum-based mapping.
    /// Version 3 introduced human-readable object-based mapping with action names.
    pub const CURRENT_VERSION = 3;
    /// Version 2 arrays included this action. Version 3's named bindings made
    /// action removal safe, but positional migration must continue to reserve
    /// its historical slot so subsequent bindings are not shifted.
    const LEGACY_TOGGLE_LOD_RENDER_INDEX = 40;

    /// Initialize a new InputSettings instance with default bindings.
    pub fn init(allocator: std.mem.Allocator) InputSettings {
        return .{
            .allocator = allocator,
            .input_mapper = InputMapper.init(),
        };
    }

    /// Initialize a new InputSettings instance from an existing InputMapper.
    pub fn initFromMapper(allocator: std.mem.Allocator, mapper: InputMapper) InputSettings {
        return .{
            .allocator = allocator,
            .input_mapper = mapper,
        };
    }

    /// Deinitialize the InputSettings instance.
    pub fn deinit(self: *InputSettings) void {
        // Currently no heap-allocated members in InputSettings,
        // but this provides a consistent API for the caller.
        _ = self;
    }

    /// Load settings from disk.
    /// If the settings file is missing, corrupt, or an error occurs during loading,
    /// it will return an InputSettings instance with default bindings and log a warning.
    pub fn load(allocator: std.mem.Allocator) InputSettings {
        const path = getSettingsPath(allocator) catch |err| {
            log.log.warn("Could not determine settings path: {}. Using default bindings.", .{err});
            return init(allocator);
        };
        defer allocator.free(path);

        const data = fs.cwd().readFileAlloc(path, allocator, MAX_SETTINGS_SIZE) catch |err| {
            if (err != error.FileNotFound) {
                log.log.warn("Failed to read settings file at {s}: {}. Using default bindings.", .{ path, err });
            }
            return init(allocator);
        };
        defer allocator.free(data);

        var settings = init(allocator);
        // Parse and apply settings
        const migrated = settings.parseJson(data) catch |err| blk: {
            log.log.warn("Failed to parse settings file at {s}: {s} ({}). Custom bindings may be lost. Using defaults where necessary.", .{ path, @errorName(err), err });
            // Reset to defaults if parsing fails to ensure clean state
            settings.input_mapper.resetToDefaults();
            break :blk false;
        };

        if (migrated) {
            log.log.info("Persisting migrated settings to {s}", .{path});
            settings.save() catch |err| {
                log.log.err("Failed to save migrated settings: {}", .{err});
            };
        }

        // --- SANITY CHECK FOR BROKEN MIGRATIONS ---
        // If critical debug actions are mapped to Escape (common symptom of shifted indices), reset them.
        const g_bind = settings.input_mapper.getBinding(.toggle_shadow_debug_vis);
        var healed = false;

        if (g_bind.primary == .key and g_bind.primary.key == .escape) {
            log.log.warn("InputSettings: Detected broken G-key mapping (mapped to Escape). Resetting to Default (G).", .{});
            settings.input_mapper.resetActionToDefault(.toggle_shadow_debug_vis);
            healed = true;
        }
        if (healed) {
            settings.save() catch |err| {
                log.log.err("Failed to persist healed input settings: {}", .{err});
            };
        }

        log.log.info("InputSettings: toggle_shadow_debug_vis is bound to {s}", .{settings.input_mapper.getBinding(.toggle_shadow_debug_vis).primary.getName()});

        return settings;
    }

    /// Convenience helper to load bindings directly into an InputMapper.
    pub fn loadAndReturnMapper(allocator: std.mem.Allocator) InputMapper {
        var settings = load(allocator);
        defer settings.deinit();
        return settings.input_mapper;
    }

    /// Save current settings to disk.
    pub fn save(self: *const InputSettings) !void {
        const path = try getSettingsPath(self.allocator);
        defer self.allocator.free(path);

        // Ensure directory exists
        if (fs.path.dirname(path)) |dir_path| {
            fs.createDirAbsolute(dir_path, fs.Permissions.default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Serialize settings
        const json = try self.toJson();
        defer self.allocator.free(json);

        // Write to file
        const file = try fs.createFileAbsolute(path, .{});
        defer file.close();

        try file.writeAll(json);
    }

    /// Helper to save bindings directly from a mapper interface.
    pub fn saveFromMapper(allocator: std.mem.Allocator, mapper: input_mapper_pkg.IInputMapper) !void {
        var settings = InputSettings.init(allocator);
        defer settings.deinit();

        // Populate settings from interface
        inline for (std.meta.fields(GameAction)) |field| {
            const action: GameAction = @enumFromInt(field.value);
            settings.input_mapper.bindings[@intFromEnum(action)] = mapper.getBinding(action);
        }

        try settings.save();
    }

    /// Get the platform-specific settings file path
    fn getSettingsPath(allocator: std.mem.Allocator) ![]u8 {
        if (builtin.os.tag == .linux or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
            const home = getenv("HOME") orelse return error.NoHomeDir;
            const xdg_data = getenv("XDG_DATA_HOME");

            if (xdg_data) |data_dir| {
                return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ data_dir, APP_NAME, SETTINGS_FILENAME });
            } else {
                return std.fmt.allocPrint(allocator, "{s}/.local/share/{s}/{s}", .{ home, APP_NAME, SETTINGS_FILENAME });
            }
        } else if (builtin.os.tag == .macos) {
            const home = getenv("HOME") orelse return error.NoHomeDir;
            return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}/{s}", .{ home, APP_NAME, SETTINGS_FILENAME });
        } else if (builtin.os.tag == .windows) {
            const appdata = getenv("APPDATA") orelse return error.NoAppDataDir;
            return std.fmt.allocPrint(allocator, "{s}\\{s}\\{s}", .{ appdata, APP_NAME, SETTINGS_FILENAME });
        } else {
            // Fallback for other platforms (e.g. Android)
            return std.fmt.allocPrint(allocator, "./{s}", .{SETTINGS_FILENAME});
        }
    }

    fn toJson(self: *const InputSettings) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &buffer);
        defer aw.deinit();

        var s: std.json.Stringify = .{
            .writer = &aw.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        try s.beginObject();
        try s.objectField("version");
        try s.write(CURRENT_VERSION);

        try s.objectField("bindings");
        try s.beginObject();

        inline for (std.meta.fields(GameAction)) |field| {
            try s.objectField(field.name);
            const action: GameAction = @enumFromInt(field.value);
            try s.write(self.input_mapper.bindings[@intFromEnum(action)]);
        }

        try s.endObject(); // end bindings
        try s.endObject(); // end root

        return try aw.toOwnedSlice();
    }

    fn parseJson(self: *InputSettings, data: []const u8) !bool {
        var parsed_value = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed_value.deinit();

        const root = parsed_value.value;
        if (root != .object) return error.InvalidFormat;

        const version_val = root.object.get("version");
        const version: i64 = if (version_val) |v| (if (v == .integer) v.integer else 1) else 1;
        const bindings_val = root.object.get("bindings") orelse return error.MissingBindings;

        log.log.info("InputSettings: Loading settings file (version {})", .{version});

        var migrated = false;
        if (version < CURRENT_VERSION) {
            migrated = true;
        }

        if (version < 3) {
            // Legacy array format
            if (bindings_val != .array) return error.InvalidBindingsFormat;
            const array = bindings_val.array;
            log.log.info("Migrating input settings from version {} (array) to {} (object)", .{ version, CURRENT_VERSION });

            for (array.items, 0..) |item, legacy_index| {
                const action = actionForLegacyBindingIndex(legacy_index) orelse continue;
                const parsed_binding = try std.json.parseFromValue(ActionBinding, self.allocator, item, .{ .ignore_unknown_fields = true });
                defer parsed_binding.deinit();
                self.input_mapper.bindings[@intFromEnum(action)] = parsed_binding.value;
            }
        } else {
            // New object format
            if (bindings_val != .object) return error.InvalidBindingsFormat;

            inline for (std.meta.fields(GameAction)) |field| {
                if (bindings_val.object.get(field.name)) |val| {
                    const action: GameAction = @enumFromInt(field.value);
                    const parsed_binding = try std.json.parseFromValue(ActionBinding, self.allocator, val, .{ .ignore_unknown_fields = true });
                    defer parsed_binding.deinit();
                    self.input_mapper.bindings[@intFromEnum(action)] = parsed_binding.value;
                }
            }
        }
        return migrated;
    }

    fn actionForLegacyBindingIndex(legacy_index: usize) ?GameAction {
        if (legacy_index == LEGACY_TOGGLE_LOD_RENDER_INDEX) return null;

        const current_index = if (legacy_index > LEGACY_TOGGLE_LOD_RENDER_INDEX)
            legacy_index - 1
        else
            legacy_index;
        if (current_index >= GameAction.count) return null;

        return @enumFromInt(current_index);
    }
};

test "InputSettings.load handles corrupt file" {
    const allocator = std.testing.allocator;

    var settings = InputSettings.init(allocator);
    defer settings.deinit();

    // Total garbage should fail with SyntaxError or UnexpectedToken
    const err = settings.parseJson("invalid json");
    try std.testing.expect(err == error.SyntaxError or err == error.UnexpectedToken);
}

test "InputSettings version migration" {
    const allocator = std.testing.allocator;

    // Simulating a version 1 file (if it had fewer bindings or just old version tag)
    const v1_json =
        \\{
        \\  "version": 1,
        \\  "bindings": [
        \\    { "primary": { "key": 119 }, "alternate": { "none": {} } }
        \\  ]
        \\}
    ;

    var settings = InputSettings.init(allocator);
    defer settings.deinit();

    // Reset to defaults first
    settings.input_mapper.resetToDefaults();

    // Parse V1
    _ = try settings.parseJson(v1_json);

    // Verify move_forward (index 0) was updated to W (119)
    try std.testing.expect(settings.input_mapper.getBinding(.move_forward).primary.key == .w);
    // Other bindings should still be default
    try std.testing.expect(settings.input_mapper.getBinding(.jump).primary.key == .space);
}

test "InputSettings V3 object format" {
    const allocator = std.testing.allocator;

    const v3_json =
        \\{
        \\  "version": 3,
        \\  "bindings": {
        \\    "move_forward": { "primary": { "key": 119 }, "alternate": { "none": {} } },
        \\    "jump": { "primary": { "key": 32 }, "alternate": { "none": {} } }
        \\  }
        \\}
    ;

    var settings = InputSettings.init(allocator);
    defer settings.deinit();

    // Reset to defaults first
    settings.input_mapper.resetToDefaults();

    // Parse V3
    _ = try settings.parseJson(v3_json);

    // Verify bindings
    try std.testing.expect(settings.input_mapper.getBinding(.move_forward).primary.key == .w);
    try std.testing.expect(settings.input_mapper.getBinding(.jump).primary.key == .space);
}

test "InputSettings migrates positional bindings without shifting past removed LOD action" {
    const allocator = std.testing.allocator;
    const legacy_action_count = GameAction.count + 1;
    var bindings = [_]ActionBinding{ActionBinding.init(.{ .none = {} })} ** legacy_action_count;
    bindings[39] = ActionBinding.init(.{ .key = .f4 });
    bindings[40] = ActionBinding.init(.{ .key = .f6 });
    bindings[41] = ActionBinding.init(.{ .key = .f7 });

    const LegacySettings = struct {
        version: u8,
        bindings: [legacy_action_count]ActionBinding,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, LegacySettings{
        .version = 2,
        .bindings = bindings,
    }, .{});
    defer allocator.free(json);

    var settings = InputSettings.init(allocator);
    defer settings.deinit();
    _ = try settings.parseJson(json);

    try std.testing.expectEqual(.f4, settings.input_mapper.getBinding(.toggle_timing_overlay).primary.key);
    try std.testing.expectEqual(.f7, settings.input_mapper.getBinding(.toggle_gpass_render).primary.key);
}

test "InputSettings ignores removed actions in named version 3 bindings" {
    const allocator = std.testing.allocator;
    const v3_json =
        \\{
        \\  "version": 3,
        \\  "bindings": {
        \\    "toggle_timing_overlay": { "primary": { "key": 1073741885 }, "alternate": { "none": {} } },
        \\    "toggle_lod_render": { "primary": { "key": 1073741887 }, "alternate": { "none": {} } },
        \\    "toggle_gpass_render": { "primary": { "key": 1073741888 }, "alternate": { "none": {} } }
        \\  }
        \\}
    ;

    var settings = InputSettings.init(allocator);
    defer settings.deinit();
    _ = try settings.parseJson(v3_json);

    try std.testing.expectEqual(.f4, settings.input_mapper.getBinding(.toggle_timing_overlay).primary.key);
    try std.testing.expectEqual(.f7, settings.input_mapper.getBinding(.toggle_gpass_render).primary.key);
}
