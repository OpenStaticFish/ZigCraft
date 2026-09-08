const std = @import("std");
const testing = std.testing;
const fs = @import("fs");
const world_list = @import("game-ui").world_list;

test "writeLevelDat creates valid JSON" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try world_list.writeLevelDat(allocator, dir, "TestWorld", 12345, 0, 100000);
    const content = try dir.readFileAlloc("level.dat", allocator, 4096);
    defer allocator.free(content);
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "TestWorld") != null);
    try testing.expect(std.mem.indexOf(u8, content, "12345") != null);
}

test "readLevelDat returns correct values" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try world_list.writeLevelDat(allocator, dir, "MyWorld", 99887766, 1, 200000);
    const result = world_list.readLevelDat(allocator, dir);
    try testing.expect(result != null);
    defer allocator.free(result.?.name);
    try testing.expectEqualStrings("MyWorld", result.?.name);
    try testing.expectEqual(@as(u64, 99887766), result.?.seed);
    try testing.expectEqual(@as(usize, 1), result.?.generator_index);
    try testing.expect(result.?.last_played > 0);
}

test "readLevelDat returns null for missing file" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    const result = world_list.readLevelDat(allocator, dir);
    try testing.expect(result == null);
}

test "readLevelDat returns null for invalid JSON" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    const file = try dir.createFile("level.dat", .{});
    defer file.close();
    try file.writeAll("not valid json!!!");
    const result = world_list.readLevelDat(allocator, dir);
    try testing.expect(result == null);
}

test "writeLevelDat renames existing worlds without changing generation identity" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try world_list.writeLevelDat(allocator, dir, "First", 100, 0, 100000);
    // The production overwrite caller is library rename, not world reseeding.
    // Stale caller values must not change the identity of persisted terrain.
    try world_list.writeLevelDat(allocator, dir, "Second", 200, 1, 200000);
    const result = world_list.readLevelDat(allocator, dir);
    try testing.expect(result != null);
    defer allocator.free(result.?.name);
    try testing.expectEqualStrings("Second", result.?.name);
    try testing.expectEqual(@as(u64, 100), result.?.seed);
    try testing.expectEqual(@as(usize, 0), result.?.generator_index);
    try testing.expectEqual(@as(i64, 200000), result.?.last_played);
    var saved = try @import("world-persistence").LevelData.loadFromFile(allocator, dir);
    defer saved.deinit(allocator);
    const generator_id = @import("world-worldgen").registry.getGeneratorId(0);
    try testing.expectEqual(@as(?usize, 0), saved.generator_index);
    try testing.expectEqualStrings(generator_id, saved.generator_id);
    try testing.expectEqualStrings(generator_id, saved.generator_name);
}

test "scanWorlds reads level.dat from each world directory" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var home_path_buf: [fs.max_path_bytes]u8 = undefined;
    const home_path = try dir.realpath(".", &home_path_buf);

    try dir.makePath(world_list.SAVE_DIR ++ "/world_a");
    try dir.makePath(world_list.SAVE_DIR ++ "/world_b");

    var world_a = try dir.openDir(world_list.SAVE_DIR ++ "/world_a", .{});
    defer world_a.close();
    var world_b = try dir.openDir(world_list.SAVE_DIR ++ "/world_b", .{});
    defer world_b.close();

    try world_list.writeLevelDat(allocator, world_a, "Alpha", 111, 1, 1000);
    try world_list.writeLevelDat(allocator, world_b, "Beta", 222, 2, 2000);

    const worlds = try world_list.scanWorldsInHome(allocator, home_path);
    defer {
        for (worlds) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.dir_path);
        }
        allocator.free(worlds);
    }

    try testing.expectEqual(@as(usize, 2), worlds.len);
    try testing.expectEqualStrings("Beta", worlds[0].name);
    try testing.expectEqual(@as(u64, 222), worlds[0].seed);
    try testing.expectEqual(@as(usize, 2), worlds[0].generator_index);
    try testing.expectEqualStrings("Alpha", worlds[1].name);
    try testing.expectEqual(@as(u64, 111), worlds[1].seed);
    try testing.expectEqual(@as(usize, 1), worlds[1].generator_index);
}

test "scanWorlds keeps directory fallback when level.dat is missing" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var home_path_buf: [fs.max_path_bytes]u8 = undefined;
    const home_path = try dir.realpath(".", &home_path_buf);

    try dir.makePath(world_list.SAVE_DIR ++ "/missing_level");

    const worlds = try world_list.scanWorldsInHome(allocator, home_path);
    defer {
        for (worlds) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.dir_path);
        }
        allocator.free(worlds);
    }

    try testing.expectEqual(@as(usize, 1), worlds.len);
    try testing.expectEqualStrings("missing_level", worlds[0].name);
    try testing.expectEqual(@as(u64, 0), worlds[0].seed);
    try testing.expectEqual(@as(usize, 0), worlds[0].generator_index);
}

test "deleteWorld removes directory and reports invalid paths" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };

    try dir.makePath("victim");

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var victim_path_buf: [fs.max_path_bytes]u8 = undefined;
    const victim_path = try std.fmt.bufPrint(&victim_path_buf, "{s}/victim", .{base_path});

    try world_list.deleteWorld(victim_path);
    try testing.expectError(error.FileNotFound, dir.openDir("victim", .{}));
    try testing.expectError(error.InvalidSavePath, world_list.deleteWorld("victim"));
}
