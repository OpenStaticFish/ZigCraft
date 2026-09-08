const std = @import("std");
const fs = @import("fs");
const registry = @import("world-worldgen").registry;
const log = @import("engine-core").log;
const LevelData = @import("world-persistence").LevelData;

pub const SAVE_DIR = ".local/share/zigcraft/saves";

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Creates metadata for a new world, or updates an existing world's display
/// name and last-played time. Seed/generator arguments apply only to creation:
/// changing them during a library rename would invalidate existing terrain.
pub fn writeLevelDat(allocator: std.mem.Allocator, save_dir: fs.Dir, name: []const u8, seed: u64, generator_index: usize, last_played: i64) !void {
    var level = LevelData.loadFromFile(allocator, save_dir) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (save_dir.openDir("regions", .{ .iterate = true })) |regions| {
                defer regions.close();
                var entries = regions.iterate();
                if (try entries.next() != null) return error.MissingLevelData;
            } else |region_err| {
                if (region_err != error.FileNotFound) return region_err;
            }
            const safe_index = if (generator_index < registry.getGeneratorCount()) generator_index else 0;
            const generator_id = registry.getGeneratorId(safe_index);
            var created = LevelData.init(seed, "");
            errdefer created.deinit(allocator);
            created.generator_id = try allocator.dupe(u8, generator_id);
            created.generator_name = try allocator.dupe(u8, generator_id);
            created.generator_index = safe_index;
            break :blk created;
        },
        else => return err,
    };
    defer level.deinit(allocator);
    const name_copy = try allocator.dupe(u8, name);
    if (level.name.len > 0) allocator.free(level.name);
    level.name = name_copy;
    level.last_played_timestamp = last_played;
    try level.saveToFile(allocator, save_dir);
}

/// Returns an owned absolute path for the exact new world, never an existing one.
pub fn saveNewWorld(allocator: std.mem.Allocator, seed: u64, generator_index: usize, world_name: []const u8) ![]u8 {
    const home = getenv("HOME") orelse {
        log.log.warn("Cannot save world: HOME not set", .{});
        return error.NoHome;
    };
    var home_dir = fs.openDirAbsolute(home, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open home dir: {}", .{err});
        return err;
    };
    defer home_dir.close();
    home_dir.makePath(SAVE_DIR) catch |err| {
        log.log.warn("Cannot save world: failed to create saves dir: {}", .{err});
        return err;
    };
    const timestamp = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    var path_buf: [256]u8 = undefined;
    var suffix: u32 = 0;
    const world_dir_path = while (suffix < 1024) : (suffix += 1) {
        const candidate = try std.fmt.bufPrint(&path_buf, "{s}/world_{}_{}", .{ SAVE_DIR, timestamp, suffix });
        home_dir.createDir(candidate, fs.Permissions.default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break candidate;
    } else return error.WorldDirectoryCollision;
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, world_dir_path });
    errdefer allocator.free(full_path);
    var save_dir = home_dir.openDir(world_dir_path, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open world dir: {}", .{err});
        return err;
    };
    defer save_dir.close();
    writeLevelDat(allocator, save_dir, world_name, seed, generator_index, timestamp) catch |err| {
        log.log.warn("Cannot save world: failed to write level.dat: {}", .{err});
        return err;
    };
    return full_path;
}
