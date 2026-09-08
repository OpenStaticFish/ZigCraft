const std = @import("std");
const testing = std.testing;
const fs = @import("fs");

const world_list = @import("world_list.zig");

fn writeFixture(dir: fs.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

fn freeWorldEntries(allocator: std.mem.Allocator, entries: []world_list.WorldEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.dir_path);
    }
    allocator.free(entries);
}

test "writeLevelDat and readLevelDat round-trip metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try world_list.writeLevelDat(testing.allocator, dir, "Alpha", 12345, 0, 99);
    const level = world_list.readLevelDat(testing.allocator, dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(level.name);

    try testing.expectEqualStrings("Alpha", level.name);
    try testing.expectEqual(@as(u64, 12345), level.seed);
    try testing.expectEqual(@as(usize, 0), level.generator_index);
    try testing.expectEqual(@as(i64, 99), level.last_played);
}

test "readLevelDat returns null when file is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, dir));
}

test "readLevelDat returns null for invalid JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "not json");

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, dir));
}

test "readLevelDat returns null for non-object JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "[]");

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, dir));
}

test "readLevelDat returns null when required name is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "{\"seed\":1,\"generator_index\":0}");

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, dir));
}

test "readLevelDat defaults missing last_played to zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "{\"name\":\"Beta\",\"seed\":7,\"generator_index\":0}");
    const level = world_list.readLevelDat(testing.allocator, dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(level.name);

    try testing.expectEqualStrings("Beta", level.name);
    try testing.expectEqual(@as(i64, 0), level.last_played);
}

test "readLevelDat falls back for an out-of-range generator index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "{\"name\":\"Old World\",\"seed\":7,\"generator_index\":999}");
    const level = world_list.readLevelDat(testing.allocator, dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(level.name);

    try testing.expectEqual(@as(usize, 0), level.generator_index);
}

test "readLevelDat rejects a negative seed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };

    try writeFixture(dir, "level.dat", "{\"name\":\"Broken\",\"seed\":-1,\"generator_index\":0}");
    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, dir));
}

test "scanWorldsInHome returns empty for absent home" {
    const entries = try world_list.scanWorldsInHome(testing.allocator, "/definitely/not/a/zigcraft/home");
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "scanWorldsInHome creates missing save directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const home = try dir.realpath(".", &path_buf);

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
    var saves = try dir.openDir(world_list.SAVE_DIR, .{});
    saves.close();
}

test "scanWorldsInHome loads worlds sorted by last_played descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const home = try dir.realpath(".", &path_buf);

    try dir.makePath(world_list.SAVE_DIR ++ "/Older");
    try dir.makePath(world_list.SAVE_DIR ++ "/Newer");
    var older = try dir.openDir(world_list.SAVE_DIR ++ "/Older", .{});
    defer older.close();
    var newer = try dir.openDir(world_list.SAVE_DIR ++ "/Newer", .{});
    defer newer.close();
    try world_list.writeLevelDat(testing.allocator, older, "Older", 1, 0, 10);
    try world_list.writeLevelDat(testing.allocator, newer, "Newer", 2, 0, 20);

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("Newer", entries[0].name);
    try testing.expectEqualStrings("Older", entries[1].name);
}

test "scanWorldsInHome falls back to directory name without level.dat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const home = try dir.realpath(".", &path_buf);

    try dir.makePath(world_list.SAVE_DIR ++ "/BareWorld");

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("BareWorld", entries[0].name);
    try testing.expectEqual(@as(u64, 0), entries[0].seed);
    try testing.expectEqual(@as(i64, 0), entries[0].last_played);
}

test "scanWorldsInHome ignores non-directory save entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const home = try dir.realpath(".", &path_buf);

    try dir.makePath(world_list.SAVE_DIR);
    try writeFixture(dir, world_list.SAVE_DIR ++ "/README.txt", "not a world");

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "deleteWorld removes only the requested directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const home = try dir.realpath(".", &path_buf);

    try dir.makePath(world_list.SAVE_DIR ++ "/DeleteMe/nested");
    try dir.makePath(world_list.SAVE_DIR ++ "/KeepMe");
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/DeleteMe", .{ home, world_list.SAVE_DIR });
    defer testing.allocator.free(target);

    try world_list.deleteWorld(target);

    try testing.expectError(error.FileNotFound, dir.openDir(world_list.SAVE_DIR ++ "/DeleteMe", .{}));
    var kept = try dir.openDir(world_list.SAVE_DIR ++ "/KeepMe", .{});
    kept.close();
}

test "deleteWorld rejects rootless path" {
    try testing.expectError(error.InvalidSavePath, world_list.deleteWorld("lonely"));
}

test "world library rename preserves SaveManager metadata" {
    const persistence = @import("world-persistence");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    try world_list.writeLevelDat(testing.allocator, dir, "Library world", std.math.maxInt(u64), 1, 123);
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(".", &path_buf);
    const sm = try persistence.SaveManager.init(testing.allocator, path, "world", std.math.maxInt(u64), "flat");
    sm.level_data.spawn_x = -37;
    sm.deinit();
    const entry = world_list.readLevelDat(testing.allocator, dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(entry.name);
    try testing.expectEqualStrings("Library world", entry.name);
    try testing.expectEqual(std.math.maxInt(u64), entry.seed);
    try testing.expectEqual(@as(usize, 1), entry.generator_index);
    try world_list.writeLevelDat(testing.allocator, dir, "Renamed world", entry.seed, entry.generator_index, entry.last_played);
    var level = try persistence.LevelData.loadFromFile(testing.allocator, dir);
    defer level.deinit(testing.allocator);
    try testing.expectEqualStrings("Renamed world", level.name);
    try testing.expectEqual(@as(i32, -37), level.spawn_x);
    try testing.expectEqualStrings(@import("world-worldgen").registry.getGeneratorId(1), level.generator_id);
}

test "writeLevelDat rename preserves both shipped legacy generator identities" {
    const LevelData = @import("world-persistence").LevelData;
    const fixtures = [_][]const u8{
        "{\"name\":\"Old library world\",\"seed\":42,\"generator_index\":1,\"last_played\":100}",
        "{\"seed\":42,\"generator_name\":\"Flat World\",\"created_timestamp\":17,\"spawn_x\":-37,\"lighting_algorithm_version\":0}",
    };
    for (fixtures) |fixture| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = fs.Dir{ .inner = tmp.dir };
        try writeFixture(dir, "level.dat", fixture);
        var original = try LevelData.loadFromFile(testing.allocator, dir);
        defer original.deinit(testing.allocator);

        try world_list.writeLevelDat(testing.allocator, dir, "Renamed legacy world", 999, 0, 200);
        var saved = try LevelData.loadFromFile(testing.allocator, dir);
        defer saved.deinit(testing.allocator);
        try testing.expectEqual(original.seed, saved.seed);
        try testing.expectEqual(original.generator_index, saved.generator_index);
        try testing.expectEqualStrings(original.generator_id, saved.generator_id);
        try testing.expectEqualStrings(original.generator_name, saved.generator_name);
        try testing.expectEqual(original.created_timestamp, saved.created_timestamp);
        try testing.expectEqual(original.spawn_x, saved.spawn_x);
        try testing.expectEqual(original.lighting_algorithm_version, saved.lighting_algorithm_version);
        const listed = world_list.readLevelDat(testing.allocator, dir) orelse return error.MissingLevelDat;
        defer testing.allocator.free(listed.name);
        try testing.expectEqualStrings("Renamed legacy world", listed.name);
        try testing.expectEqual(@as(usize, 1), listed.generator_index);
        try testing.expectEqual(@as(i64, 200), listed.last_played);
    }
}

test "writeLevelDat refuses corrupt metadata without replacing it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    const damaged = "{\"seed\":7}";
    try writeFixture(dir, "level.dat", damaged);
    try testing.expectError(error.InvalidLevelData, world_list.writeLevelDat(testing.allocator, dir, "Rename", 999, 0, 200));
    const contents = try dir.readFileAlloc("level.dat", testing.allocator, 4096);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(damaged, contents);
    try testing.expectError(error.FileNotFound, dir.openFile("level.dat.tmp", .{}));
}

test "writeLevelDat refuses new metadata over orphaned region data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    try dir.makePath("regions");
    try writeFixture(dir, "regions/r.0.0.mca", "existing terrain data");
    try testing.expectError(error.MissingLevelData, world_list.writeLevelDat(testing.allocator, dir, "Rename", 999, 0, 200));
    try testing.expectError(error.FileNotFound, dir.openFile("level.dat", .{}));
    const contents = try dir.readFileAlloc("regions/r.0.0.mca", testing.allocator, 4096);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("existing terrain data", contents);
}
