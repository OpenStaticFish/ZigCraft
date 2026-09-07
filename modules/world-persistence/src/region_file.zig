//! Region file format for chunk persistence (.mca style).
//!
//! Each region file stores a 32x32 grid of chunks using a location table
//! and zlib-compressed chunk payloads. Matches the Minecraft Anvil format.
//!
//! Layout:
//!   [Header: 4096 bytes] 1024 entries x 4 bytes (3-byte sector offset + 1-byte sector count)
//!   [Chunk Data: variable] 4-byte length + 1-byte compression type + compressed payload
//!
//! Sectors are 4096 bytes. Chunks may span multiple sectors.
//!
//! Thread safety: RegionFile is not thread-safe. Caller must ensure exclusive access.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const fs = @import("fs");

const SECTOR_SIZE: u32 = 4096;
const HEADER_ENTRIES: u32 = 1024;
const HEADER_SIZE: u32 = HEADER_ENTRIES * 4;
// Matches Minecraft Anvil format: 1=GZip, 2=Zlib, 3=Uncompressed
const COMPRESSION_ZLIB: u8 = 2;
const MAX_SECTOR_OFFSET: u32 = (1 << 24) - 1;

const LocationEntry = packed struct(u32) {
    sector_count: u8,
    offset: u24,
};

pub const RegionError = error{
    ChunkNotFound,
    InvalidHeader,
    CompressionError,
    DecompressionError,
    FileTooShort,
    ReadOnly,
};

pub const RegionFile = struct {
    file: fs.File,
    closed: bool = false,
    read_only: bool = false,
    header: [HEADER_ENTRIES]LocationEntry,
    allocator: Allocator,

    pub fn open(allocator: Allocator, path: []const u8) !RegionFile {
        return openExisting(allocator, path, false);
    }

    /// Opens an existing file without creating it or requiring write access.
    pub fn openReadOnly(allocator: Allocator, path: []const u8) !RegionFile {
        return openExisting(allocator, path, true);
    }

    fn openExisting(allocator: Allocator, path: []const u8, read_only: bool) !RegionFile {
        const file = try fs.cwd().openFile(path, .{ .mode = if (read_only) .read_only else .read_write });
        errdefer file.close();

        var region = RegionFile{
            .file = file,
            .read_only = read_only,
            .header = @splat(.{ .offset = 0, .sector_count = 0 }),
            .allocator = allocator,
        };

        try region.readHeader();
        return region;
    }

    pub fn create(allocator: Allocator, path: []const u8) !RegionFile {
        const file = try fs.cwd().createFile(path, .{ .read = true, .truncate = true });
        errdefer file.close();

        const region = RegionFile{
            .file = file,
            .header = @splat(.{ .offset = 0, .sector_count = 0 }),
            .allocator = allocator,
        };

        var header_buf: [HEADER_SIZE]u8 = @splat(0);
        try file.writeAll(&header_buf);

        return region;
    }

    pub fn close(self: *RegionFile) void {
        if (!self.closed) {
            self.file.close();
            self.closed = true;
        }
    }

    pub fn hasChunk(self: *RegionFile, local_x: u5, local_z: u5) bool {
        const idx = @as(u32, local_z) * 32 + @as(u32, local_x);
        return self.header[idx].offset != 0;
    }

    pub fn readChunk(self: *RegionFile, local_x: u5, local_z: u5, allocator: Allocator) ![]u8 {
        const idx = @as(u32, local_z) * 32 + @as(u32, local_x);
        const entry = self.header[idx];

        if (entry.offset == 0) return RegionError.ChunkNotFound;

        const byte_offset: u64 = @as(u64, entry.offset) * SECTOR_SIZE;
        const max_bytes: u64 = @as(u64, entry.sector_count) * SECTOR_SIZE;
        const stat = try self.file.stat();
        if (entry.sector_count == 0 or byte_offset + 5 > stat.size) return RegionError.FileTooShort;

        var len_buf: [4]u8 = undefined;
        if (try self.file.preadAll(&len_buf, byte_offset) != len_buf.len) return RegionError.FileTooShort;
        const chunk_len = std.mem.readInt(u32, &len_buf, .big);

        if (chunk_len < 1 or chunk_len > max_bytes)
            return RegionError.InvalidHeader;
        if (byte_offset + 4 + chunk_len > stat.size) return RegionError.FileTooShort;
        if (@as(u64, chunk_len) + 4 > max_bytes) return RegionError.InvalidHeader;

        var comp_type_buf: [1]u8 = undefined;
        if (try self.file.preadAll(&comp_type_buf, byte_offset + 4) != comp_type_buf.len) return RegionError.FileTooShort;

        if (comp_type_buf[0] != COMPRESSION_ZLIB)
            return RegionError.CompressionError;

        const payload_len = chunk_len - 1;
        const compressed = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(compressed);
        if (try self.file.preadAll(compressed, byte_offset + 5) != compressed.len) return RegionError.FileTooShort;

        const result = try decompressZlib(allocator, compressed);
        allocator.free(compressed);
        return result;
    }

    pub fn writeChunk(self: *RegionFile, local_x: u5, local_z: u5, data: []const u8) !void {
        if (self.read_only) return RegionError.ReadOnly;
        const compressed = try compressZlib(self.allocator, data);
        defer self.allocator.free(compressed);

        const total_len: u32 = @intCast(compressed.len + 1);
        const sectors_needed = (total_len + 4 + SECTOR_SIZE - 1) / SECTOR_SIZE;
        if (sectors_needed > std.math.maxInt(u8)) return RegionError.FileTooShort;

        const idx = @as(u32, local_z) * 32 + @as(u32, local_x);
        const old_entry = self.header[idx];

        const new_offset: u24 = blk: {
            if (old_entry.offset != 0 and @as(u32, old_entry.sector_count) >= sectors_needed) {
                break :blk old_entry.offset;
            }

            const end_sector = self.findEndSector();
            if (end_sector + sectors_needed > MAX_SECTOR_OFFSET)
                return RegionError.FileTooShort;
            break :blk @intCast(end_sector);
        };

        const byte_offset: u64 = @as(u64, new_offset) * SECTOR_SIZE;

        var chunk_header: [5]u8 = undefined;
        std.mem.writeInt(u32, chunk_header[0..4], total_len, .big);
        chunk_header[4] = COMPRESSION_ZLIB;

        const sector_bytes = @as(u64, sectors_needed) * SECTOR_SIZE;

        try self.file.writePositionalAll(&chunk_header, byte_offset);
        try self.file.writePositionalAll(compressed, byte_offset + 5);

        const padding_len = sector_bytes - 4 - total_len;
        if (padding_len > 0) {
            var zeroes: [256]u8 = @splat(0);
            var remaining: u64 = padding_len;
            var pad_offset: u64 = byte_offset + 5 + compressed.len;
            while (remaining > 0) {
                const to_write = @min(remaining, zeroes.len);
                try self.file.writePositionalAll(zeroes[0..@intCast(to_write)], pad_offset);
                remaining -= to_write;
                pad_offset += to_write;
            }
        }

        self.header[idx] = .{
            .offset = new_offset,
            .sector_count = @intCast(sectors_needed),
        };

        try self.writeHeader();
        try self.file.sync();
    }

    pub fn deleteChunk(self: *RegionFile, local_x: u5, local_z: u5) !void {
        if (self.read_only) return RegionError.ReadOnly;
        const idx = @as(u32, local_z) * 32 + @as(u32, local_x);
        self.header[idx] = .{ .offset = 0, .sector_count = 0 };
        try self.writeHeader();
        try self.file.sync();
    }

    fn readHeader(self: *RegionFile) !void {
        const stat = try self.file.stat();
        if (stat.size < HEADER_SIZE) return RegionError.InvalidHeader;

        var buf: [HEADER_SIZE]u8 = undefined;
        if (try self.file.preadAll(&buf, 0) != buf.len) return RegionError.InvalidHeader;

        for (&self.header, 0..HEADER_ENTRIES) |*entry, i| {
            const raw = std.mem.readInt(u32, buf[i * 4 ..][0..4], .big);
            entry.* = @bitCast(raw);
            if ((entry.offset == 0) != (entry.sector_count == 0)) return RegionError.InvalidHeader;
        }
    }

    fn writeHeader(self: *RegionFile) !void {
        var buf: [HEADER_SIZE]u8 = undefined;
        for (&self.header, 0..HEADER_ENTRIES) |entry, i| {
            const raw: u32 = @bitCast(entry);
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], raw, .big);
        }
        try self.file.writePositionalAll(&buf, 0);
    }

    fn findEndSector(self: *RegionFile) u32 {
        var end: u32 = HEADER_SIZE / SECTOR_SIZE;
        for (&self.header) |entry| {
            if (entry.offset != 0) {
                const e: u32 = @as(u32, entry.offset) + @as(u32, entry.sector_count);
                if (e > end) end = e;
            }
        }
        return end;
    }
};

fn compressZlib(allocator: Allocator, data: []const u8) ![]u8 {
    const out_cap = @max(data.len, 256);
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, out_cap);
    defer aw.deinit();

    var comp_buffer: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(
        &aw.writer,
        &comp_buffer,
        .zlib,
        .default,
    ) catch return RegionError.CompressionError;

    comp.writer.writeAll(data) catch return RegionError.CompressionError;
    comp.finish() catch return RegionError.CompressionError;

    return aw.toOwnedSlice() catch return RegionError.CompressionError;
}

fn decompressZlib(allocator: Allocator, compressed: []const u8) ![]u8 {
    var in_reader: std.Io.Reader = .fixed(compressed);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var decomp_buffer: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&in_reader, .zlib, &decomp_buffer);

    _ = decomp.reader.streamRemaining(&aw.writer) catch return RegionError.DecompressionError;

    if (decomp.err) |_| return RegionError.DecompressionError;

    return aw.toOwnedSlice() catch return RegionError.DecompressionError;
}

const testing = std.testing;

fn withTempDir(comptime func: anytype) !void {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try func(dir);
}

test "RegionFile round-trip write and read" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_roundtrip.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            const data = "Hello, region file world! This is test chunk data.";
            try region.writeChunk(0, 0, data);

            region.close();

            var region2 = try RegionFile.openReadOnly(testing.allocator, full_path);
            defer region2.close();

            try testing.expect(region2.read_only);
            try testing.expectError(RegionError.ReadOnly, region2.writeChunk(0, 0, "must not replace data"));
            try testing.expectError(RegionError.ReadOnly, region2.deleteChunk(0, 0));
            try testing.expect(region2.hasChunk(0, 0));

            const read_data = try region2.readChunk(0, 0, testing.allocator);
            defer testing.allocator.free(read_data);

            try testing.expectEqualSlices(u8, data, read_data);
        }
    }.run);
}

test "RegionFile multiple chunks in one region" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_multi.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            const data_a = "Chunk A data at (0,0)";
            const data_b = "Chunk B data at (5,10)";
            const data_c = "Chunk C data at (31,31)";

            try region.writeChunk(0, 0, data_a);
            try region.writeChunk(5, 10, data_b);
            try region.writeChunk(31, 31, data_c);

            const read_a = try region.readChunk(0, 0, testing.allocator);
            defer testing.allocator.free(read_a);
            const read_b = try region.readChunk(5, 10, testing.allocator);
            defer testing.allocator.free(read_b);
            const read_c = try region.readChunk(31, 31, testing.allocator);
            defer testing.allocator.free(read_c);

            try testing.expectEqualSlices(u8, data_a, read_a);
            try testing.expectEqualSlices(u8, data_b, read_b);
            try testing.expectEqualSlices(u8, data_c, read_c);
        }
    }.run);
}

test "RegionFile overwrite replaces data" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_overwrite.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            try region.writeChunk(0, 0, "original data that is long enough to matter");
            try region.writeChunk(0, 0, "new data after overwrite");

            const read_data = try region.readChunk(0, 0, testing.allocator);
            defer testing.allocator.free(read_data);

            try testing.expectEqualSlices(u8, "new data after overwrite", read_data);
        }
    }.run);
}

test "RegionFile empty region creates valid file" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_empty.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            region.close();

            var region2 = try RegionFile.open(testing.allocator, full_path);
            defer region2.close();

            var i: u32 = 0;
            while (i < 32) : (i += 1) {
                var j: u32 = 0;
                while (j < 32) : (j += 1) {
                    try testing.expect(!region2.hasChunk(@intCast(j), @intCast(i)));
                }
            }
        }
    }.run);
}

test "RegionFile hasChunk reports correctly" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_haschunk.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            try testing.expect(!region.hasChunk(0, 0));
            try testing.expect(!region.hasChunk(5, 5));

            try region.writeChunk(0, 0, "some data");
            try testing.expect(region.hasChunk(0, 0));
            try testing.expect(!region.hasChunk(5, 5));

            try region.writeChunk(5, 5, "other data");
            try testing.expect(region.hasChunk(5, 5));
        }
    }.run);
}

test "RegionFile deleteChunk removes chunk" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_delete.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            try region.writeChunk(3, 7, "data to delete");
            try testing.expect(region.hasChunk(3, 7));

            try region.deleteChunk(3, 7);
            try testing.expect(!region.hasChunk(3, 7));

            const result = region.readChunk(3, 7, testing.allocator);
            try testing.expectError(RegionError.ChunkNotFound, result);
        }
    }.run);
}

test "RegionFile readChunk not found returns error" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_notfound.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            const result = region.readChunk(10, 20, testing.allocator);
            try testing.expectError(RegionError.ChunkNotFound, result);
        }
    }.run);
}

test "RegionFile binary chunk data round-trip" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_binary.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            var region = try RegionFile.create(testing.allocator, full_path);
            defer region.close();

            var binary_data: [256]u8 = undefined;
            for (&binary_data, 0..) |*byte, i| {
                byte.* = @intCast(i % 256);
            }

            try region.writeChunk(0, 0, &binary_data);

            const read_data = try region.readChunk(0, 0, testing.allocator);
            defer testing.allocator.free(read_data);

            try testing.expectEqualSlices(u8, &binary_data, read_data);
        }
    }.run);
}

test "RegionFile corrupt header handling" {
    try withTempDir(struct {
        fn run(base: fs.Dir) !void {
            const path = "test_corrupt.mca";
            const file = try base.createFile(path, .{ .read = true, .truncate = true });
            file.close();

            var full_path_buf: [fs.max_path_bytes]u8 = undefined;
            const full_path = try base.realpath(path, &full_path_buf);

            const file2 = try fs.cwd().openFile(full_path, .{ .mode = .read_write });
            try file2.setLength(100);
            file2.close();

            const result = RegionFile.open(testing.allocator, full_path);
            try testing.expectError(RegionError.InvalidHeader, result);
        }
    }.run);
}
