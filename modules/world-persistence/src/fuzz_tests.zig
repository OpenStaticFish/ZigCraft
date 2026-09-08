const std = @import("std");
const fs = @import("fs");

const world_core = @import("world-core");

const chunk_serializer = @import("chunk_serializer.zig");
const level_data = @import("level_data.zig");
const region_file = @import("region_file.zig");

test "fuzz corpus: chunk deserializer rejects short and corrupted payloads" {
    var source = world_core.Chunk.init(12, -34);
    source.setBlock(1, 2, 3, .stone);
    source.setSkyLight(1, 2, 3, 15);

    const serialized = try chunk_serializer.serializeChunk(&source, std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const lengths = [_]usize{ 0, 1, 4, chunk_serializer.HEADER_SIZE - 1, chunk_serializer.HEADER_SIZE, chunk_serializer.HEADER_SIZE + 1, serialized.len - 1 };
    for (lengths) |len| {
        var target = world_core.Chunk.init(0, 0);
        const result = chunk_serializer.deserializeChunk(serialized[0..len], &target);
        try std.testing.expectError(chunk_serializer.SerializeError.DataTooShort, result);
    }

    const offsets = [_]usize{ 0, 4, chunk_serializer.HEADER_SIZE, serialized.len / 2, serialized.len - 1 };
    for (offsets) |offset| {
        const mutated = try std.testing.allocator.dupe(u8, serialized);
        defer std.testing.allocator.free(mutated);
        mutated[offset] +%= 1;

        var target = world_core.Chunk.init(0, 0);
        const result = chunk_serializer.deserializeChunk(mutated, &target);
        if (offset == 0) {
            try std.testing.expectError(chunk_serializer.SerializeError.InvalidMagic, result);
        } else if (offset == 4) {
            try std.testing.expectError(chunk_serializer.SerializeError.UnsupportedVersion, result);
        } else {
            try std.testing.expectError(chunk_serializer.SerializeError.ChecksumMismatch, result);
        }
    }
}

test "fuzz corpus: region file parser rejects malformed files without short reads" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };

    const cases = [_]struct {
        name: []const u8,
        bytes: []const u8,
        open_error: ?anyerror = null,
        read_error: ?anyerror = null,
    }{
        .{ .name = "empty.mca", .bytes = "", .open_error = region_file.RegionError.InvalidHeader },
        .{ .name = "short.mca", .bytes = "not a full header", .open_error = region_file.RegionError.InvalidHeader },
        .{ .name = "dangling.mca", .bytes = &danglingRegionHeader(), .open_error = region_file.RegionError.InvalidHeader },
        .{ .name = "bad-length.mca", .bytes = &badLengthRegion(), .open_error = region_file.RegionError.InvalidHeader },
    };

    for (cases) |case| {
        const file = try dir.createFile(case.name, .{ .truncate = true });
        try file.writeAll(case.bytes);
        file.close();

        var full_path_buf: [fs.max_path_bytes]u8 = undefined;
        const full_path = try dir.realpath(case.name, &full_path_buf);

        if (case.open_error) |expected| {
            try std.testing.expectError(expected, region_file.RegionFile.open(std.testing.allocator, full_path));
            continue;
        }

        var region = try region_file.RegionFile.open(std.testing.allocator, full_path);
        defer region.close();
        try std.testing.expectError(case.read_error.?, region.readChunk(0, 0, std.testing.allocator));
    }
}

test "golden fixture: v0.1 level data loads into current model" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };

    const file = try dir.createFile("level.dat", .{ .truncate = true });
    defer file.close();
    try file.writeAll(@embedFile("level_fixture_v0_1"));

    var loaded = try level_data.LevelData.loadFromFile(std.testing.allocator, dir);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 881882), loaded.seed);
    try std.testing.expectEqualStrings("overworld", loaded.generator_name);
    try std.testing.expectEqual(@as(i64, 1700000000000), loaded.created_timestamp);
    try std.testing.expectEqual(@as(i64, 1700000000000), loaded.last_played_timestamp);
    try std.testing.expectEqual(@as(i32, 8), loaded.spawn_x);
    try std.testing.expectEqual(@as(i32, 8), loaded.spawn_z);
}

fn danglingRegionHeader() [4096]u8 {
    var bytes: [4096]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0x00000201, .big);
    return bytes;
}

fn badLengthRegion() [4096 + 5]u8 {
    var bytes: [4096 + 5]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0x00000101, .big);
    std.mem.writeInt(u32, bytes[4096..4100], 4096, .big);
    bytes[4100] = 2;
    return bytes;
}
