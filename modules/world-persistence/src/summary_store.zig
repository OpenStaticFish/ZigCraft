//! Derived canonical observations, separate from saved block-source regions.
//! Saved blocks remain authoritative: callers must validate saved fingerprints
//! against their source blocks. Generated observations require the current identity.
//!
//! SourceHierarchy must serialize the entire read/check/write operation with saved
//! block commits and other sidecar writes. Revisions are in-process source ordering,
//! not a durable global epoch; this module does not compare revision numbers.
//!
//! Publication syncs an exclusive same-directory temporary file before renaming it.
//! The fs wrapper has no directory sync, so a power loss can lose a directory entry.
//! Repair missing/corrupt saved summaries from saved blocks, never from generation.
//! This does not make the existing in-place region format power-loss atomic.
const std = @import("std");
const fs = @import("fs");
const world_core = @import("world-core");
const scene = world_core.lod_scene;
const ChunkSummary = scene.ChunkSummary;
const Allocator = std.mem.Allocator;

pub const Identity = struct {
    seed: u64,
    generator_hash: u64,
    generator_version: u32,
};

pub const max_bytes = 1024 * 1024;
pub const max_runs = 65536;
const magic = "ZCSUM\x00\x00\x00";
const schema_version: u32 = 1;
const column_bytes = 7; // offset:u32, count:u16, biome:u8
const run_bytes = 9; // min/max:u16, block:u8, top/bottom light:u16

// Wire offsets, not a host struct layout. Every integer is little-endian.
const Header = struct {
    const schema = 8;
    const seed = 12;
    const generator_hash = 20;
    const generator_version = 28;
    const chunk_x = 32;
    const chunk_z = 36;
    const origin = 40;
    const width = 44;
    const depth = 48;
    const height = 52;
    const columns = 56;
    const revision = 60;
    const fingerprint = 68;
    const payload_length = 76;
    const run_count = 80;
    const checksum = 84;
    const size = 92;
};

/// Pure bounded codec. The returned bytes belong to allocator.
pub fn encode(allocator: Allocator, identity: Identity, summary: *const ChunkSummary) ![]u8 {
    if (summary.origin == .live) return error.UncommittedSummary;
    try summary.validate();
    const payload_length = 256 * column_bytes + summary.runs.len * run_bytes;
    if (Header.size + payload_length > max_bytes) return error.SummaryTooLarge;
    const bytes = try allocator.alloc(u8, Header.size + payload_length);
    @memcpy(bytes[0..magic.len], magic);
    put(u32, bytes, Header.schema, schema_version);
    put(u64, bytes, Header.seed, identity.seed);
    put(u64, bytes, Header.generator_hash, identity.generator_hash);
    put(u32, bytes, Header.generator_version, identity.generator_version);
    put(i32, bytes, Header.chunk_x, summary.chunk_x);
    put(i32, bytes, Header.chunk_z, summary.chunk_z);
    put(u32, bytes, Header.origin, @intFromEnum(summary.origin));
    put(u32, bytes, Header.width, 16);
    put(u32, bytes, Header.depth, 16);
    put(u32, bytes, Header.height, 256);
    put(u32, bytes, Header.columns, 256);
    put(u64, bytes, Header.revision, summary.revision);
    put(u64, bytes, Header.fingerprint, summary.fingerprint());
    put(u32, bytes, Header.payload_length, @intCast(payload_length));
    put(u32, bytes, Header.run_count, @intCast(summary.runs.len));
    var offset: usize = Header.size;
    for (summary.columns) |column| {
        put(u32, bytes, offset, column.offset);
        put(u16, bytes, offset + 4, column.count);
        bytes[offset + 6] = @intFromEnum(column.biome);
        offset += column_bytes;
    }
    for (summary.runs) |run| {
        put(u16, bytes, offset, run.min_y);
        put(u16, bytes, offset + 2, run.max_y);
        bytes[offset + 4] = @intFromEnum(run.block);
        put(u16, bytes, offset + 5, packLight(run.light_top));
        put(u16, bytes, offset + 7, packLight(run.light_bottom));
        offset += run_bytes;
    }
    put(u64, bytes, Header.checksum, checksum(bytes));
    return bytes;
}

/// Pure bounded decoder. Identity must match for either persisted origin;
/// identity/coordinate mismatches are errors, not absence.
/// The returned summary owns its runs and must be deinitialized by the caller.
pub fn decode(allocator: Allocator, bytes: []const u8, identity: Identity, cx: i32, cz: i32) !ChunkSummary {
    return decodeRecord(allocator, bytes, identity, cx, cz);
}

fn decodeRecord(allocator: Allocator, bytes: []const u8, identity: ?Identity, cx: i32, cz: i32) !ChunkSummary {
    if (bytes.len > max_bytes) return error.SummaryTooLarge;
    if (bytes.len < Header.size) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidMagic;
    if (get(u64, bytes, Header.checksum) != checksum(bytes)) return error.ChecksumMismatch;
    if (get(u32, bytes, Header.schema) != schema_version) return error.UnsupportedSchema;
    if (get(i32, bytes, Header.chunk_x) != cx or get(i32, bytes, Header.chunk_z) != cz) return error.CoordinateMismatch;
    if (get(u32, bytes, Header.width) != 16 or get(u32, bytes, Header.depth) != 16 or
        get(u32, bytes, Header.height) != 256 or get(u32, bytes, Header.columns) != 256)
        return error.InvalidGeometry;
    const origin = try enumValue(scene.Origin, get(u32, bytes, Header.origin));
    if (origin == .live) return error.UncommittedSummary;
    const count = get(u32, bytes, Header.run_count);
    if (count > max_runs) return error.TooManyRuns;
    const payload_length: usize = 256 * column_bytes + @as(usize, count) * run_bytes;
    if (get(u32, bytes, Header.payload_length) != payload_length or bytes.len != Header.size + payload_length)
        return error.InvalidLength;

    var summary: ChunkSummary = .{
        .allocator = allocator,
        .chunk_x = cx,
        .chunk_z = cz,
        .columns = undefined,
        .runs = try allocator.alloc(scene.Run, count),
        .origin = origin,
        .revision = get(u64, bytes, Header.revision),
    };
    errdefer summary.deinit();
    var offset: usize = Header.size;
    for (&summary.columns) |*column| {
        column.* = .{
            .offset = get(u32, bytes, offset),
            .count = get(u16, bytes, offset + 4),
            .biome = try enumValue(world_core.Biome, bytes[offset + 6]),
        };
        offset += column_bytes;
    }
    for (summary.runs) |*run| {
        run.* = .{
            .min_y = get(u16, bytes, offset),
            .max_y = get(u16, bytes, offset + 2),
            .block = try enumValue(world_core.BlockType, bytes[offset + 4]),
            .light_top = unpackLight(get(u16, bytes, offset + 5)),
            .light_bottom = unpackLight(get(u16, bytes, offset + 7)),
        };
        offset += run_bytes;
    }
    try summary.validate();
    if (summary.fingerprint() != get(u64, bytes, Header.fingerprint)) return error.FingerprintMismatch;
    // Validate the complete record even when it belongs to a stale identity.
    if (identity) |expected| {
        if (get(u64, bytes, Header.seed) != expected.seed or
            get(u64, bytes, Header.generator_hash) != expected.generator_hash or
            get(u32, bytes, Header.generator_version) != expected.generator_version)
            return error.IdentityMismatch;
    }
    return summary;
}

/// Noncreating read. Only FileNotFound maps to null; corruption and I/O errors escape.
pub fn read(allocator: Allocator, save_dir: []const u8, identity: Identity, cx: i32, cz: i32) !?ChunkSummary {
    const path = try recordPath(allocator, save_dir, cx, cz);
    defer allocator.free(path);
    return readRecord(allocator, path, identity, cx, cz);
}

fn readRecord(allocator: Allocator, path: []const u8, identity: ?Identity, cx: i32, cz: i32) !?ChunkSummary {
    const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file) return error.InvalidFileType;
    if (stat.size > max_bytes) return error.SummaryTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(bytes);
    if (try file.preadAll(bytes, 0) != bytes.len) return error.InvalidLength;
    var extra: [1]u8 = undefined;
    if (try file.preadAll(&extra, stat.size) != 0) return error.InvalidLength;
    return try decodeRecord(allocator, bytes, identity, cx, cz);
}

/// Caller must serialize this operation with source commits and other writers.
/// Generated writes refuse any valid saved record, including a stale identity.
/// Explicit saved writes can replace stale/corrupt sidecars after source validation.
pub fn write(allocator: Allocator, save_dir: []const u8, identity: Identity, summary: *const ChunkSummary) !void {
    return writeImpl(allocator, save_dir, identity, summary, false);
}

/// Only a current, confirmed absence of saved BLOCKS authorizes this replacement.
/// Caller must serialize validation and publication with source commit callbacks.
/// Corrupt and orphan saved sidecars are derived observations, not block authority.
pub fn writeAfterConfirmedAbsence(allocator: Allocator, save_dir: []const u8, identity: Identity, summary: *const ChunkSummary) !void {
    if (summary.origin != .generated) return error.ExpectedGeneratedSummary;
    return writeImpl(allocator, save_dir, identity, summary, true);
}

fn writeImpl(allocator: Allocator, save_dir: []const u8, identity: Identity, summary: *const ChunkSummary, confirmed_absent: bool) !void {
    const bytes = try encode(allocator, identity, summary);
    defer allocator.free(bytes);
    const path = try recordPath(allocator, save_dir, summary.chunk_x, summary.chunk_z);
    defer allocator.free(path);
    if (summary.origin == .generated and !confirmed_absent) {
        if (try readRecord(allocator, path, null, summary.chunk_x, summary.chunk_z)) |value| {
            var previous = value;
            defer previous.deinit();
            if (previous.origin == .saved) return error.SavedSummaryExists;
        }
    }
    const dir = try fs.cwd().makeOpenPath(fs.path.dirname(path).?, .{});
    defer dir.close();
    try atomicReplace(dir, fs.path.basename(path), bytes, writeAndSync);
}

fn recordPath(allocator: Allocator, save_dir: []const u8, cx: i32, cz: i32) ![]u8 {
    var relative_buf: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buf, "summaries/v1/r.{d}.{d}/c.{d}.{d}.zsum", .{
        @divFloor(cx, 32), @divFloor(cz, 32), cx, cz,
    });
    return fs.path.join(allocator, &.{ save_dir, relative });
}

fn writeAndSync(file: fs.File, bytes: []const u8) !void {
    try file.writeAll(bytes);
    try file.sync();
}

// The operation parameter permits deterministic partial-write/sync failure tests.
fn atomicReplace(dir: fs.Dir, filename: []const u8, bytes: []const u8, comptime write_sync: anytype) !void {
    var temp_buf: [96]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        var nonce: [16]u8 = undefined;
        std.Options.debug_io.random(&nonce);
        const temp = try std.fmt.bufPrint(&temp_buf, ".zsum-{x}.tmp", .{std.mem.readInt(u128, &nonce, .little)});
        const file = dir.createFile(temp, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        // Registered only after exclusive creation; never remove another writer's file.
        errdefer dir.deleteFile(temp) catch {};
        {
            defer file.close();
            try write_sync(file, bytes);
        }
        try dir.rename(temp, filename);
        return;
    }
    return error.TemporaryNameCollision;
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn enumValue(comptime T: type, value: u32) !T {
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(field.value);
    }
    return error.InvalidEnum;
}

fn packLight(light: world_core.PackedLight) u16 {
    return (@as(u16, light.sky_light) << 12) | (@as(u16, light.block_light_r) << 8) |
        (@as(u16, light.block_light_g) << 4) | @as(u16, light.block_light_b);
}

fn unpackLight(value: u16) world_core.PackedLight {
    return world_core.PackedLight.initRGB(@truncate(value >> 12), @truncate(value >> 8), @truncate(value >> 4), @truncate(value));
}

// FNV-1a covers ALL header bytes except the checksum itself, plus all payload bytes.
fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes[0..Header.checksum]) |byte| hash = (hash ^ byte) *% 1099511628211;
    for (bytes[Header.size..]) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

const testing = std.testing;
const test_identity: Identity = .{ .seed = 42, .generator_hash = 0xfedcba9876543210, .generator_version = 7 };

test "summary codec roundtrips actual strata gaps high Y lighting and empty chunks" {
    var chunk = world_core.Chunk.init(-33, 32);
    chunk.setBiome(2, 3, .windswept_savanna);
    for (0..5) |y| chunk.setBlock(2, @intCast(y), 3, .stone);
    for (5..8) |y| chunk.setBlock(2, @intCast(y), 3, .dirt);
    chunk.setBlock(2, 8, 3, .grass);
    for (10..12) |y| chunk.setBlock(2, @intCast(y), 3, .water);
    chunk.setBlock(2, 16, 3, .birch_leaves);
    chunk.setBlock(2, 19, 3, .flower_red);
    chunk.setBlock(2, 255, 3, .snow_layer);
    chunk.setLight(2, 12, 3, world_core.PackedLight.initRGB(9, 1, 2, 3));
    chunk.setLight(2, 9, 3, world_core.PackedLight.initRGB(4, 5, 6, 7));
    for (0..2) |pass| {
        if (pass == 1) chunk = world_core.Chunk.init(-33, 32);
        var original = try ChunkSummary.capture(testing.allocator, &chunk);
        defer original.deinit();
        original.origin = if (pass == 0) .saved else .generated;
        original.revision = 0x123456789abcdef0;
        const bytes = try encode(testing.allocator, test_identity, &original);
        defer testing.allocator.free(bytes);
        var loaded = try decode(testing.allocator, bytes, test_identity, -33, 32);
        defer loaded.deinit();
        try testing.expectEqualDeep(original.columns, loaded.columns);
        try testing.expectEqualDeep(original.runs, loaded.runs);
        try testing.expectEqual(original.origin, loaded.origin);
        try testing.expectEqual(original.revision, loaded.revision);
        try testing.expectEqual(original.fingerprint(), loaded.fingerprint());
        try testing.expectEqual(@as(usize, 0), loaded.column(0, 0).len);
        if (pass == 0) {
            const runs = loaded.column(2, 3);
            try testing.expectEqual(@as(usize, 7), runs.len);
            try testing.expectEqual(@as(u16, 256), runs[6].max_y);
            try testing.expectEqualDeep(world_core.PackedLight.initRGB(9, 1, 2, 3), runs[3].light_top);
        } else try testing.expectEqual(@as(usize, 0), loaded.runs.len);
        const again = try encode(testing.allocator, test_identity, &loaded);
        defer testing.allocator.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}

test "summary codec checks every header and payload byte and rejects malformed records" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 255, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    summary.origin = .generated;
    const bytes = try encode(testing.allocator, test_identity, &summary);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |_, i| {
        bytes[i] ^= 1;
        try testing.expectError(if (i < magic.len) error.InvalidMagic else error.ChecksumMismatch, decode(testing.allocator, bytes, test_identity, 0, 0));
        bytes[i] ^= 1;
    }
    const mutations = [_]struct { offset: usize, value: u32, err: anyerror }{
        .{ .offset = Header.schema, .value = 2, .err = error.UnsupportedSchema },
        .{ .offset = Header.chunk_x, .value = 1, .err = error.CoordinateMismatch },
        .{ .offset = Header.chunk_z, .value = 1, .err = error.CoordinateMismatch },
        .{ .offset = Header.origin, .value = 256, .err = error.InvalidEnum },
        .{ .offset = Header.origin, .value = @intFromEnum(scene.Origin.live), .err = error.UncommittedSummary },
        .{ .offset = Header.width, .value = 32, .err = error.InvalidGeometry },
        .{ .offset = Header.depth, .value = 32, .err = error.InvalidGeometry },
        .{ .offset = Header.height, .value = 255, .err = error.InvalidGeometry },
        .{ .offset = Header.columns, .value = 255, .err = error.InvalidGeometry },
        .{ .offset = Header.payload_length, .value = std.math.maxInt(u32), .err = error.InvalidLength },
        .{ .offset = Header.run_count, .value = 65537, .err = error.TooManyRuns },
        .{ .offset = Header.run_count, .value = 0, .err = error.InvalidLength },
        .{ .offset = Header.size, .value = 1, .err = error.InvalidColumnRange },
    };
    for (mutations) |mutation| {
        const old = get(u32, bytes, mutation.offset);
        put(u32, bytes, mutation.offset, mutation.value);
        put(u64, bytes, Header.checksum, checksum(bytes));
        try testing.expectError(mutation.err, decode(testing.allocator, bytes, test_identity, 0, 0));
        put(u32, bytes, mutation.offset, old);
    }
    const fp = get(u64, bytes, Header.fingerprint);
    put(u64, bytes, Header.fingerprint, fp ^ 1);
    put(u64, bytes, Header.checksum, checksum(bytes));
    try testing.expectError(error.FingerprintMismatch, decode(testing.allocator, bytes, test_identity, 0, 0));
    put(u64, bytes, Header.fingerprint, fp);
    for ([_]usize{ Header.size + 6, Header.size + 256 * column_bytes + 4 }) |offset| {
        const old = bytes[offset];
        bytes[offset] = 255;
        put(u64, bytes, Header.checksum, checksum(bytes));
        try testing.expectError(error.InvalidEnum, decode(testing.allocator, bytes, test_identity, 0, 0));
        bytes[offset] = old;
    }
    put(u64, bytes, Header.checksum, checksum(bytes));
    for ([_]Identity{
        .{ .seed = 43, .generator_hash = test_identity.generator_hash, .generator_version = 7 },
        .{ .seed = 42, .generator_hash = 0, .generator_version = 7 },
        .{ .seed = 42, .generator_hash = test_identity.generator_hash, .generator_version = 8 },
    }) |identity| try testing.expectError(error.IdentityMismatch, decode(testing.allocator, bytes, identity, 0, 0));
    try testing.expectError(error.InvalidLength, decode(testing.allocator, bytes[0 .. Header.size - 1], test_identity, 0, 0));
    const truncated = try testing.allocator.dupe(u8, bytes[0 .. bytes.len - 1]);
    defer testing.allocator.free(truncated);
    put(u64, truncated, Header.checksum, checksum(truncated));
    try testing.expectError(error.InvalidLength, decode(testing.allocator, truncated, test_identity, 0, 0));
    const extended = try testing.allocator.alloc(u8, bytes.len + 1);
    defer testing.allocator.free(extended);
    @memcpy(extended[0..bytes.len], bytes);
    extended[bytes.len] = 0;
    put(u64, extended, Header.checksum, checksum(extended));
    try testing.expectError(error.InvalidLength, decode(testing.allocator, extended, test_identity, 0, 0));
}

test "summary codec bounds worst case runs and allocations" {
    var chunk = world_core.Chunk.init(std.math.minInt(i32), std.math.maxInt(i32));
    for (0..256) |y| chunk.fillLayer(@intCast(y), if (y % 2 == 0) .stone else .water);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    summary.origin = .saved;
    const bytes = try encode(testing.allocator, test_identity, &summary);
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len < max_bytes);
    var loaded = try decode(testing.allocator, bytes, test_identity, chunk.chunk_x, chunk.chunk_z);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, max_runs), loaded.runs.len);
    try testing.expectEqualDeep(summary.runs, loaded.runs);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, encode(failing.allocator(), test_identity, &summary));
    try testing.expectError(error.OutOfMemory, decode(failing.allocator(), bytes, test_identity, chunk.chunk_x, chunk.chunk_z));
    put(u32, bytes, Header.run_count, max_runs + 1);
    put(u64, bytes, Header.checksum, checksum(bytes));
    try testing.expectError(error.TooManyRuns, decode(failing.allocator(), bytes, test_identity, chunk.chunk_x, chunk.chunk_z));
    const oversized = try testing.allocator.alloc(u8, max_bytes + 1);
    defer testing.allocator.free(oversized);
    try testing.expectError(error.SummaryTooLarge, decode(failing.allocator(), oversized, test_identity, 0, 0));
}

test "summary store missing reads are noncreating and corrupt files are errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    try testing.expect((try read(testing.allocator, save_dir, test_identity, -33, 32)) == null);
    try testing.expectError(error.FileNotFound, dir.access("summaries", .{}));
    const missing_save = try fs.path.join(testing.allocator, &.{ save_dir, "missing" });
    defer testing.allocator.free(missing_save);
    try testing.expect((try read(testing.allocator, missing_save, test_identity, 0, 0)) == null);
    try testing.expectError(error.FileNotFound, dir.access("missing", .{}));
    var chunk = world_core.Chunk.init(-33, 32);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    summary.origin = .saved;
    try write(testing.allocator, save_dir, test_identity, &summary);
    const relative = "summaries/v1/r.-2.1/c.-33.32.zsum";
    try dir.access(relative, .{});
    try testing.expectError(error.FileNotFound, dir.access("regions", .{}));
    try testing.expectError(error.FileNotFound, dir.access("lod", .{}));
    var loaded = (try read(testing.allocator, save_dir, test_identity, -33, 32)).?;
    defer loaded.deinit();
    try testing.expectEqual(summary.fingerprint(), loaded.fingerprint());
    {
        const file = try dir.createFile(relative, .{});
        defer file.close();
        try file.writeAll("corrupt");
    }
    try testing.expectError(error.InvalidLength, read(testing.allocator, save_dir, test_identity, -33, 32));
    summary.origin = .generated;
    try testing.expectError(error.InvalidLength, write(testing.allocator, save_dir, test_identity, &summary));
    summary.origin = .saved;
    try write(testing.allocator, save_dir, test_identity, &summary);
    var repaired = (try read(testing.allocator, save_dir, test_identity, -33, 32)).?;
    defer repaired.deinit();
    try testing.expectEqual(summary.fingerprint(), repaired.fingerprint());
    {
        const file = try dir.openFile(relative, .{ .mode = .read_write });
        defer file.close();
        try file.setLength(max_bytes + 1);
    }
    try testing.expectError(error.SummaryTooLarge, read(testing.allocator, save_dir, test_identity, -33, 32));
    try dir.makePath("summaries/v1/r.0.0/c.0.0.zsum");
    try testing.expectError(error.InvalidFileType, read(testing.allocator, save_dir, test_identity, 0, 0));
}

test "summary store saved origin wins over generation without imposing durable revision order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    try testing.expectError(error.UncommittedSummary, write(testing.allocator, save_dir, test_identity, &summary));
    try testing.expectError(error.FileNotFound, dir.access("summaries", .{}));
    summary.origin = .generated;
    try write(testing.allocator, save_dir, test_identity, &summary);
    var changed_identity = test_identity;
    changed_identity.generator_version += 1;
    try testing.expectError(error.IdentityMismatch, read(testing.allocator, save_dir, changed_identity, 0, 0));
    try write(testing.allocator, save_dir, changed_identity, &summary);
    summary.origin = .saved;
    summary.revision = 100;
    try write(testing.allocator, save_dir, changed_identity, &summary);
    summary.origin = .generated;
    summary.revision = 999;
    summary.runs[0].block = .water;
    try testing.expectError(error.SavedSummaryExists, write(testing.allocator, save_dir, test_identity, &summary));
    try testing.expectError(error.SavedSummaryExists, write(testing.allocator, save_dir, changed_identity, &summary));
    var saved = (try read(testing.allocator, save_dir, changed_identity, 0, 0)).?;
    defer saved.deinit();
    try testing.expectEqual(scene.Origin.saved, saved.origin);
    try testing.expectEqual(@as(u64, 100), saved.revision);
    try testing.expectEqual(world_core.BlockType.stone, saved.runs[0].block);
    summary.origin = .saved;
    summary.revision = 1; // A new process may restart its source revision counter.
    try write(testing.allocator, save_dir, test_identity, &summary);
    var replaced = (try read(testing.allocator, save_dir, test_identity, 0, 0)).?;
    defer replaced.deinit();
    try testing.expectEqual(@as(u64, 1), replaced.revision);
    try testing.expectEqual(world_core.BlockType.water, replaced.runs[0].block);
}

test "summary store confirmed block absence repairs orphan and corrupt sidecars only with generated summaries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    try dir.makePath("regions");
    {
        const region = try dir.createFile("regions/r.0.0.mca", .{});
        defer region.close();
        try region.writeAll("block source must remain untouched");
    }
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    for ([_]scene.Origin{ .live, .saved }) |origin| {
        summary.origin = origin;
        try testing.expectError(error.ExpectedGeneratedSummary, writeAfterConfirmedAbsence(testing.allocator, save_dir, test_identity, &summary));
    }
    try testing.expectError(error.FileNotFound, dir.access("summaries", .{}));
    summary.origin = .saved;
    try write(testing.allocator, save_dir, test_identity, &summary);
    summary.origin = .generated;
    summary.runs[0].block = .water;
    var new_identity = test_identity;
    new_identity.generator_version += 1;
    try testing.expectError(error.SavedSummaryExists, write(testing.allocator, save_dir, new_identity, &summary));
    try writeAfterConfirmedAbsence(testing.allocator, save_dir, new_identity, &summary);
    var orphan_repaired = (try read(testing.allocator, save_dir, new_identity, 0, 0)).?;
    defer orphan_repaired.deinit();
    try testing.expectEqual(scene.Origin.generated, orphan_repaired.origin);
    try testing.expectEqual(world_core.BlockType.water, orphan_repaired.runs[0].block);

    {
        const corrupt = try dir.createFile("summaries/v1/r.0.0/c.0.0.zsum", .{});
        defer corrupt.close();
        try corrupt.writeAll("corrupt");
    }
    try testing.expectError(error.InvalidLength, write(testing.allocator, save_dir, new_identity, &summary));
    try writeAfterConfirmedAbsence(testing.allocator, save_dir, new_identity, &summary);
    summary.runs[0].max_y = 257;
    try testing.expectError(error.InvalidRunBounds, writeAfterConfirmedAbsence(testing.allocator, save_dir, new_identity, &summary));
    var corrupt_repaired = (try read(testing.allocator, save_dir, new_identity, 0, 0)).?;
    defer corrupt_repaired.deinit();
    try testing.expectEqual(orphan_repaired.fingerprint(), corrupt_repaired.fingerprint());
    try testing.expectEqual(scene.Origin.generated, corrupt_repaired.origin);
    const region_bytes = try dir.readFileAlloc("regions/r.0.0.mca", testing.allocator, 128);
    defer testing.allocator.free(region_bytes);
    try testing.expectEqualStrings("block source must remain untouched", region_bytes);
}

test "summary store encode partial write sync and rename failures preserve old record and clean own temp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.Dir{ .inner = tmp.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    summary.origin = .saved;
    try write(testing.allocator, save_dir, test_identity, &summary);
    const old_fingerprint = summary.fingerprint();
    summary.origin = .live;
    try testing.expectError(error.UncommittedSummary, write(testing.allocator, save_dir, test_identity, &summary));
    summary.origin = .saved;
    summary.runs[0].max_y = 257;
    try testing.expectError(error.InvalidRunBounds, write(testing.allocator, save_dir, test_identity, &summary));
    summary.runs[0].max_y = 1;
    summary.runs[0].block = .water;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, write(failing.allocator(), save_dir, test_identity, &summary));
    const bytes = try encode(testing.allocator, test_identity, &summary);
    defer testing.allocator.free(bytes);
    const region = try dir.openDir("summaries/v1/r.0.0", .{ .iterate = true });
    defer region.close();
    const foreign = try region.createFile(".zsum-foreign.tmp", .{ .exclusive = true });
    foreign.close();
    const Faults = struct {
        fn partial(file: fs.File, data: []const u8) !void {
            try file.writeAll(data[0..8]);
            return error.InjectedWriteFailure;
        }
        fn syncFailure(file: fs.File, data: []const u8) !void {
            try file.writeAll(data);
            return error.InjectedSyncFailure;
        }
    };
    try testing.expectError(error.InjectedWriteFailure, atomicReplace(region, "c.0.0.zsum", bytes, Faults.partial));
    try testing.expectError(error.InjectedSyncFailure, atomicReplace(region, "c.0.0.zsum", bytes, Faults.syncFailure));
    // A missing destination parent forces rename failure after a complete synced write.
    try testing.expectError(error.FileNotFound, atomicReplace(region, "missing/c.0.0.zsum", bytes, writeAndSync));
    var loaded = (try read(testing.allocator, save_dir, test_identity, 0, 0)).?;
    defer loaded.deinit();
    try testing.expectEqual(old_fingerprint, loaded.fingerprint());
    var iterator = region.iterate();
    var count: usize = 0;
    while (try iterator.next()) |entry| {
        try testing.expect(std.mem.eql(u8, entry.name, "c.0.0.zsum") or std.mem.eql(u8, entry.name, ".zsum-foreign.tmp"));
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}
