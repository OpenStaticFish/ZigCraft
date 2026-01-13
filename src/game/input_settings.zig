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

    /// Initialize a new InputSettings instance with default bindings.
    pub fn init(allocator: std.mem.Allocator) InputSettings {
        return .{
            .allocator = allocator,
            .input_mapper = InputMapper.init(),
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
        var settings = InputSettings.init(allocator);

        const path = getSettingsPath(allocator) catch |err| {
            log.log.warn("Could not determine settings path: {}. Using default bindings.", .{err});
            return settings;
        };
        defer allocator.free(path);

        const data = std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(1024 * 1024)) catch |err| {
            if (err != error.FileNotFound) {
                log.log.warn("Failed to read settings file at {s}: {}. Using default bindings.", .{ path, err });
            }
            return settings;
        };
        defer allocator.free(data);

        // Parse and apply settings
        settings.parseJson(data) catch |err| {
            log.log.warn("Failed to parse settings file at {s}: {}. Using default bindings.", .{ path, err });
        };

        return settings;
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
            // Generic fallback for other platforms (e.g. Android, etc)
            // Try to use a local directory or just fail if we can't find a good home
            return std.fmt.allocPrint(allocator, "./{s}", .{SETTINGS_FILENAME});
        }
    }

    fn toJson(self: *const InputSettings) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(self.allocator, &buffer);
        defer aw.deinit();

        try std.json.Stringify.value(.{
            .version = 2,
            .bindings = self.input_mapper.bindings,
        }, .{ .whitespace = .indent_2 }, &aw.writer);

        return aw.toOwnedSlice();
    }

    fn parseJson(self: *InputSettings, data: []const u8) !void {
        const Schema = struct {
            version: u32,
            bindings: [GameAction.count]ActionBinding,
        };

        var parsed = try std.json.parseFromSlice(Schema, self.allocator, data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        self.input_mapper.bindings = parsed.value.bindings;
    }
};
