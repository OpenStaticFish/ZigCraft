//! Level metadata for world saves.
//!
//! Manages the `level.dat` JSON file that stores world metadata such as
//! seed, generator type, timestamps, and spawn position.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("fs");

fn timestampMs() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

pub const LevelData = struct {
    pub const CURRENT_LIGHTING_ALGORITHM_VERSION: u32 = 1;

    seed: u64,
    generator_name: []const u8,
    created_timestamp: i64,
    last_played_timestamp: i64,
    spawn_x: i32,
    spawn_z: i32,
    /// Zero is the legacy value used when an existing level.dat has no field.
    lighting_algorithm_version: u32,
    name: []const u8 = "",
    generator_id: []const u8 = "",
    generator_index: ?usize = null,

    pub fn init(seed: u64, generator_name: []const u8) LevelData {
        const now = timestampMs();
        return .{
            .seed = seed,
            .generator_name = generator_name,
            .created_timestamp = now,
            .last_played_timestamp = now,
            .spawn_x = 8,
            .spawn_z = 8,
            .lighting_algorithm_version = CURRENT_LIGHTING_ALGORITHM_VERSION,
        };
    }

    pub fn deinit(self: *LevelData, allocator: Allocator) void {
        if (self.generator_name.len > 0) {
            allocator.free(self.generator_name);
        }
        if (self.name.len > 0) allocator.free(self.name);
        if (self.generator_id.len > 0) allocator.free(self.generator_id);
    }

    pub fn saveToFile(self: *const LevelData, allocator: Allocator, dir: fs.Dir) !void {
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .seed = self.seed,
            .name = self.name,
            .generator_name = self.generator_name,
            .generator_id = self.generator_id,
            .generator_index = self.generator_index,
            .created_timestamp = self.created_timestamp,
            .last_played_timestamp = self.last_played_timestamp,
            .last_played = self.last_played_timestamp,
            .spawn_x = self.spawn_x,
            .spawn_z = self.spawn_z,
            .lighting_algorithm_version = self.lighting_algorithm_version,
        }, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        const file = try dir.createFile("level.dat.tmp", .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
        try file.sync();
        try dir.rename("level.dat.tmp", "level.dat");
    }

    pub fn loadFromFile(allocator: Allocator, dir: fs.Dir) !LevelData {
        const file = try dir.openFile("level.dat", .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 4096) return error.LevelDataTooLarge;

        const contents = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(contents);
        if (try file.preadAll(contents, 0) != contents.len) return error.InvalidLevelData;
        // Both the library and runtime metadata shapes have shipped. Parse real
        // JSON, retaining their identity fields instead of silently defaulting a
        // corrupt document to a new seed/generator.
        const Saved = struct {
            seed: u64,
            generator_name: []const u8 = "",
            generator_id: []const u8 = "",
            generator_index: ?usize = null,
            name: []const u8 = "",
            created_timestamp: i64 = 0,
            last_played_timestamp: ?i64 = null,
            last_played: i64 = 0,
            spawn_x: i32 = 8,
            spawn_z: i32 = 8,
            lighting_algorithm_version: u32 = 0,
        };
        const parsed = try std.json.parseFromSlice(Saved, allocator, contents, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const saved = parsed.value;
        if (saved.generator_name.len == 0 and saved.generator_id.len == 0 and saved.generator_index == null) return error.InvalidLevelData;
        var result = LevelData.init(saved.seed, "");
        errdefer result.deinit(allocator);
        result.generator_name = try allocator.dupe(u8, saved.generator_name);
        result.generator_id = try allocator.dupe(u8, saved.generator_id);
        result.name = try allocator.dupe(u8, saved.name);
        result.generator_index = saved.generator_index;
        result.created_timestamp = saved.created_timestamp;
        result.last_played_timestamp = saved.last_played_timestamp orelse saved.last_played;
        result.spawn_x = saved.spawn_x;
        result.spawn_z = saved.spawn_z;
        result.lighting_algorithm_version = saved.lighting_algorithm_version;
        return result;
    }

    pub fn touchLastPlayed(self: *LevelData) void {
        self.last_played_timestamp = timestampMs();
    }
};

const testing = std.testing;

test "LevelData save and load round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original = LevelData.init(12345, "overworld");
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try original.saveToFile(testing.allocator, dir);

    var loaded = try LevelData.loadFromFile(testing.allocator, dir);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 12345), loaded.seed);
    try testing.expectEqualStrings("overworld", loaded.generator_name);
    try testing.expectEqual(@as(i32, 8), loaded.spawn_x);
    try testing.expectEqual(@as(i32, 8), loaded.spawn_z);
    try testing.expectEqual(LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION, loaded.lighting_algorithm_version);
}

test "LevelData treats metadata without a lighting version as legacy" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    const file = try dir.createFile("level.dat", .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\n  \"seed\": 7,\n  \"generator_name\": \"flat\"\n}");

    var loaded = try LevelData.loadFromFile(testing.allocator, dir);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), loaded.lighting_algorithm_version);
}

test "LevelData touchLastPlayed updates timestamp" {
    var data = LevelData.init(99999, "flat");
    const old_ts = data.last_played_timestamp;
    std.Options.debug_io.sleep(.fromNanoseconds(1_000_000), .boot) catch {};
    data.touchLastPlayed();
    try testing.expect(data.last_played_timestamp >= old_ts);
}

test "LevelData preserves shipped library identity and rejects incomplete metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    const file = try dir.createFile("level.dat", .{});
    try file.writeAll("{\"name\":\"My \\\"world\\\"\",\"seed\":18446744073709551615,\"generator_id\":\"overworld-v2\",\"generator_index\":3,\"last_played\":123}");
    file.close();
    var level = try LevelData.loadFromFile(testing.allocator, dir);
    defer level.deinit(testing.allocator);
    level.spawn_x = -37;
    try level.saveToFile(testing.allocator, dir);
    var reloaded = try LevelData.loadFromFile(testing.allocator, dir);
    defer reloaded.deinit(testing.allocator);
    try testing.expectEqualStrings("My \"world\"", reloaded.name);
    try testing.expectEqualStrings("overworld-v2", reloaded.generator_id);
    try testing.expectEqual(std.math.maxInt(u64), reloaded.seed);
    try testing.expectEqual(@as(?usize, 3), reloaded.generator_index);
    try testing.expectEqual(@as(i64, 123), reloaded.last_played_timestamp);
    try testing.expectEqual(@as(i32, -37), reloaded.spawn_x);
    const invalid = try dir.createFile("level.dat", .{});
    try invalid.writeAll("{\"seed\":9}");
    invalid.close();
    try testing.expectError(error.InvalidLevelData, LevelData.loadFromFile(testing.allocator, dir));
}
