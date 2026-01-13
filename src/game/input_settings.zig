//! Settings system for persisting user input preferences.
//!
//! Handles loading and saving of input-related game settings.

const std = @import("std");
const builtin = @import("builtin");
const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const GameAction = input_mapper_pkg.GameAction;
const ActionBinding = input_mapper_pkg.ActionBinding;
const log = @import("../engine/core/log.zig");

pub const InputSettings = struct {
    allocator: std.mem.Allocator,
    input_mapper: InputMapper,

    pub const SETTINGS_FILENAME = "settings.json";
    pub const APP_NAME = "zigcraft";
    /// Maximum size of the settings file (1MB).
    pub const MAX_SETTINGS_SIZE = 1024 * 1024;
    /// Current version of the settings schema.
    /// Version 2 introduced GameAction enum-based mapping.
    pub const CURRENT_VERSION = 2;

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

        const data = std.fs.cwd().readFileAlloc(path, allocator, .limited(MAX_SETTINGS_SIZE)) catch |err| {
            if (err != error.FileNotFound) {
                log.log.warn("Failed to read settings file at {s}: {}. Using default bindings.", .{ path, err });
            }
            return init(allocator);
        };
        defer allocator.free(data);

        var settings = init(allocator);
        // Parse and apply settings
        settings.parseJson(data) catch |err| {
            log.log.warn("Failed to parse settings file at {s}: {s} ({}). Custom bindings may be lost. Using defaults where necessary.", .{ path, @errorName(err), err });
            // Reset to defaults if parsing fails to ensure clean state
            settings.input_mapper.resetToDefaults();
        };

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
        if (std.fs.path.dirname(path)) |dir_path| {
            std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Serialize settings
        const json = try self.toJson();
        defer self.allocator.free(json);

        // Write to file
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        try file.writeAll(json);
    }

    /// Helper to save bindings directly from a mapper.
    pub fn saveFromMapper(allocator: std.mem.Allocator, mapper: InputMapper) !void {
        var settings = InputSettings.initFromMapper(allocator, mapper);
        defer settings.deinit();
        try settings.save();
    }

    /// Get the platform-specific settings file path
    fn getSettingsPath(allocator: std.mem.Allocator) ![]u8 {
        if (builtin.os.tag == .linux or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
            const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
            const xdg_data = std.posix.getenv("XDG_DATA_HOME");

            if (xdg_data) |data_dir| {
                return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ data_dir, APP_NAME, SETTINGS_FILENAME });
            } else {
                return std.fmt.allocPrint(allocator, "{s}/.local/share/{s}/{s}", .{ home, APP_NAME, SETTINGS_FILENAME });
            }
        } else if (builtin.os.tag == .macos) {
            const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
            return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}/{s}", .{ home, APP_NAME, SETTINGS_FILENAME });
        } else if (builtin.os.tag == .windows) {
            const appdata = std.posix.getenv("APPDATA") orelse return error.NoAppDataDir;
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

        try std.json.Stringify.value(.{
            .version = CURRENT_VERSION,
            .bindings = self.input_mapper.bindings,
        }, .{ .whitespace = .indent_2 }, &aw.writer);

        return aw.toOwnedSlice();
    }

    fn parseJson(self: *InputSettings, data: []const u8) !void {
        const Schema = struct {
            version: u32,
            bindings: []ActionBinding,
        };

        var parsed = try std.json.parseFromSlice(Schema, self.allocator, data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Basic version migration/check
        if (parsed.value.version < 2) {
            log.log.info("Migrating input settings from version {} to {}", .{ parsed.value.version, CURRENT_VERSION });
            // Version 1 might have fewer bindings. We'll only copy what we have.
        }

        if (parsed.value.bindings.len != GameAction.count) {
            log.log.warn("Settings file has {} bindings, but engine expected {}. Only matching bindings will be applied.", .{ parsed.value.bindings.len, GameAction.count });
        }

        const count = @min(parsed.value.bindings.len, GameAction.count);
        @memcpy(self.input_mapper.bindings[0..count], parsed.value.bindings[0..count]);
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
    try settings.parseJson(v1_json);

    // Verify move_forward (index 0) was updated to W (119)
    try std.testing.expect(settings.input_mapper.getBinding(.move_forward).primary.key == .w);
    // Other bindings should still be default
    try std.testing.expect(settings.input_mapper.getBinding(.jump).primary.key == .space);
}
