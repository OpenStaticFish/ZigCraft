//! Canonical chunk geometry and renderer-independent scene projection storage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Chunk = @import("chunk.zig").Chunk;
const BlockType = @import("block.zig").BlockType;
const BiomeId = @import("block.zig").Biome;
const PackedLight = @import("light.zig").PackedLight;

pub const Run = struct {
    min_y: u16,
    max_y: u16,
    block: BlockType,
    light_top: PackedLight,
    light_bottom: PackedLight,
};

pub const Column = struct {
    offset: u32,
    count: u16,
    biome: BiomeId,
};

pub const Origin = enum(u8) { generated, saved, live };

pub const ChunkSummary = struct {
    allocator: Allocator,
    chunk_x: i32,
    chunk_z: i32,
    columns: [256]Column,
    runs: []Run,
    origin: Origin = .generated,
    revision: u64 = 0,

    /// Caller must keep the chunk alive and synchronize mutation for both passes.
    pub fn capture(allocator: Allocator, chunk: *const Chunk) !ChunkSummary {
        var columns: [256]Column = undefined;
        var count: u32 = 0;
        for (&columns, 0..) |*info, index| {
            const x: u32 = @intCast(index % 16);
            const z: u32 = @intCast(index / 16);
            info.* = .{ .offset = count, .count = 0, .biome = chunk.getBiome(x, z) };
            var previous: BlockType = .air;
            for (0..256) |y| {
                const block = chunk.getBlock(x, @intCast(y), z);
                if (block != .air and block != previous) {
                    info.count += 1;
                    count += 1;
                }
                previous = block;
            }
        }
        const runs = try allocator.alloc(Run, count);
        for (columns, 0..) |info, index| {
            const x: u32 = @intCast(index % 16);
            const z: u32 = @intCast(index / 16);
            var next: usize = info.offset;
            var y: u32 = 0;
            while (y < 256) {
                const block = chunk.getBlock(x, y, z);
                const min_y = y;
                y += 1;
                if (block == .air) continue;
                while (y < 256 and chunk.getBlock(x, y, z) == block) : (y += 1) {}
                runs[next] = .{
                    .min_y = @intCast(min_y),
                    .max_y = @intCast(y),
                    .block = block,
                    .light_top = chunk.getLightSafe(@intCast(x), @intCast(y), @intCast(z)),
                    .light_bottom = chunk.getLightSafe(@intCast(x), @as(i32, @intCast(min_y)) - 1, @intCast(z)),
                };
                next += 1;
            }
        }
        return .{
            .allocator = allocator,
            .chunk_x = chunk.chunk_x,
            .chunk_z = chunk.chunk_z,
            .columns = columns,
            .runs = runs,
            .origin = .live,
            .revision = chunk.content_revision.load(.acquire),
        };
    }

    pub fn clone(self: *const ChunkSummary, allocator: Allocator) !ChunkSummary {
        var result = self.*;
        result.runs = try allocator.dupe(Run, self.runs);
        result.allocator = allocator;
        return result;
    }

    pub fn deinit(self: *ChunkSummary) void {
        self.allocator.free(self.runs);
        self.* = undefined;
    }

    /// Includes the value itself and all owned allocations.
    pub fn memoryBytes(self: *const ChunkSummary) usize {
        return @sizeOf(ChunkSummary) + self.runs.len * @sizeOf(Run);
    }

    pub fn column(self: *const ChunkSummary, lx: u32, lz: u32) []const Run {
        std.debug.assert(lx < 16 and lz < 16);
        const info = self.columns[lz * 16 + lx];
        const start: usize = info.offset;
        return self.runs[start .. start + info.count];
    }

    /// Codec callers must check lengths before allocation, then validate before use.
    /// Headers form a packed, exhaustive partition in z-major column order.
    pub fn validate(self: *const ChunkSummary) !void {
        if (self.runs.len > 65536) return error.TooManyRuns;
        if (!validEnum(self.origin)) return error.InvalidOrigin;
        var next: usize = 0;
        for (self.columns) |info| {
            if (!validEnum(info.biome)) return error.InvalidBiome;
            if (info.count > 256) return error.TooManyRuns;
            if (info.offset != next or info.count > self.runs.len - next) return error.InvalidColumnRange;
            var previous: ?Run = null;
            for (self.runs[next .. next + info.count]) |run| {
                if (!validEnum(run.block) or run.block == .air) return error.InvalidBlock;
                if (run.min_y >= run.max_y or run.max_y > 256) return error.InvalidRunBounds;
                if (previous) |prev| {
                    if (run.min_y < prev.max_y) return error.InvalidRunOrder;
                    if (run.min_y == prev.max_y and run.block == prev.block) return error.UncoalescedRun;
                }
                previous = run;
            }
            next += info.count;
        }
        if (next != self.runs.len) return error.InvalidColumnRange;
    }

    /// FNV-1a over explicit little-endian geometry fields, never struct padding.
    /// Lighting, provenance, revisions, allocation layout, and offsets are excluded.
    pub fn fingerprint(self: *const ChunkSummary) u64 {
        var hash: u64 = 14695981039346656037;
        hashInteger(&hash, @as(u32, @bitCast(self.chunk_x)));
        hashInteger(&hash, @as(u32, @bitCast(self.chunk_z)));
        for (self.columns) |info| {
            hashInteger(&hash, @intFromEnum(info.biome));
            hashInteger(&hash, info.count);
            const start: usize = info.offset;
            for (self.runs[start .. start + info.count]) |run| {
                hashInteger(&hash, run.min_y);
                hashInteger(&hash, run.max_y);
                hashInteger(&hash, @intFromEnum(run.block));
            }
        }
        return hash;
    }
};

fn validEnum(value: anytype) bool {
    inline for (@typeInfo(@TypeOf(value)).@"enum".fields) |field| {
        if (@intFromEnum(value) == field.value) return true;
    }
    return false;
}

fn hashInteger(hash: *u64, value: anytype) void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .little);
    for (bytes) |byte| hash.* = (hash.* ^ byte) *% 1099511628211;
}

pub const SceneSpan = struct {
    min_y: f32,
    max_y: f32,
    block: BlockType,
    biome: BiomeId,
    coverage: f32 = 1,
    center_x: f32 = 0.5,
    center_z: f32 = 0.5,
    light: PackedLight,
    light_bottom: ?PackedLight = null,
};

pub const SceneColumn = struct {
    offset: u32 = 0,
    count: u16 = 0,
    known_area: u32 = 0,
    total_area: u32 = 0,
    approximate: bool = false,
};

pub const KnownChunk = struct {
    cx: i32,
    cz: i32,
};

pub const SceneGrid = struct {
    allocator: Allocator,
    origin_x: i32,
    origin_z: i32,
    cell_size: u32,
    /// Interior cell count per axis; storage also includes a one-cell halo.
    width: u32,
    columns: []SceneColumn,
    spans: std.ArrayListUnmanaged(SceneSpan) = .empty,
    /// Actual leased inputs, including known air and halo chunks. Unique and
    /// sorted by (cz, cx); an empty list also supports older manual test grids.
    known_chunks: std.ArrayListUnmanaged(KnownChunk) = .empty,
    source_epoch: u64 = 0,

    pub fn init(allocator: Allocator, origin_x: i32, origin_z: i32, cell_size: u32, width: u32) !SceneGrid {
        if (width == 0 or width > 256) return error.InvalidGridSize;
        if (cell_size == 0 or !std.math.isPowerOfTwo(cell_size)) return error.InvalidCellSize;
        // Area metadata and all halo edges must remain representable.
        if (@as(u64, cell_size) * cell_size > std.math.maxInt(u32)) return error.InvalidCellSize;
        for ([_]i32{ origin_x, origin_z }) |origin| {
            const min = @as(i64, origin) - cell_size;
            const max = @as(i64, origin) + @as(i64, width + 1) * cell_size;
            if (min < std.math.minInt(i32) or max > std.math.maxInt(i32)) return error.InvalidGridCoordinates;
        }
        const columns = try allocator.alloc(SceneColumn, @as(usize, width + 2) * (width + 2));
        @memset(columns, .{});
        return .{
            .allocator = allocator,
            .origin_x = origin_x,
            .origin_z = origin_z,
            .cell_size = cell_size,
            .width = width,
            .columns = columns,
        };
    }

    fn index(self: *const SceneGrid, gx: i32, gz: i32) usize {
        const width: i32 = @intCast(self.width);
        std.debug.assert(gx >= -1 and gz >= -1 and gx <= width and gz <= width);
        return @as(usize, @intCast(gz + 1)) * (self.width + 2) + @as(usize, @intCast(gx + 1));
    }

    pub fn column(self: *const SceneGrid, gx: i32, gz: i32) []const SceneSpan {
        const info = self.columns[self.index(gx, gz)];
        const start: usize = info.offset;
        return self.spans.items[start .. start + info.count];
    }

    pub fn columnInfo(self: *SceneGrid, gx: i32, gz: i32) *SceneColumn {
        return &self.columns[self.index(gx, gz)];
    }

    /// A positive total_area marks a cell as written, even when wholly unknown.
    /// Empty spans with known_area == total_area explicitly describe known air.
    /// Projection spans may overlap vertically when their horizontal coverage differs.
    pub fn appendColumn(self: *SceneGrid, gx: i32, gz: i32, spans: []const SceneSpan, known_area: u32, total_area: u32, approximate: bool) !void {
        const width: i32 = @intCast(self.width);
        if (gx < -1 or gz < -1 or gx > width or gz > width) return error.InvalidGridCoordinates;
        const info = self.columnInfo(gx, gz);
        if (info.total_area != 0) return error.ColumnAlreadyWritten;
        if (total_area == 0 or total_area > self.cell_size * self.cell_size or known_area > total_area) return error.InvalidArea;
        if (spans.len > std.math.maxInt(u16) or spans.len > std.math.maxInt(u32) - self.spans.items.len) return error.TooManySpans;
        if (known_area < total_area and spans.len != 0 and !approximate) return error.InvalidArea;
        for (spans) |span| {
            if (!std.math.isFinite(span.min_y) or !std.math.isFinite(span.max_y) or span.min_y < 0 or span.min_y >= span.max_y or span.max_y > 256) return error.InvalidSpanBounds;
            if (!std.math.isFinite(span.coverage) or span.coverage <= 0 or span.coverage > 1 or
                !std.math.isFinite(span.center_x) or span.center_x < 0 or span.center_x > 1 or
                !std.math.isFinite(span.center_z) or span.center_z < 0 or span.center_z > 1) return error.InvalidSpanCoverage;
            if (!validEnum(span.block) or span.block == .air) return error.InvalidBlock;
            if (!validEnum(span.biome)) return error.InvalidBiome;
        }
        const offset: u32 = @intCast(self.spans.items.len);
        try self.spans.appendSlice(self.allocator, spans);
        info.* = .{
            .offset = offset,
            .count = @intCast(spans.len),
            .known_area = known_area,
            .total_area = total_area,
            .approximate = approximate,
        };
    }

    pub fn clone(self: *const SceneGrid, allocator: Allocator) !SceneGrid {
        var result = self.*;
        result.allocator = allocator;
        result.columns = try allocator.dupe(SceneColumn, self.columns);
        errdefer allocator.free(result.columns);
        result.spans = .empty;
        errdefer result.spans.deinit(allocator);
        try result.spans.appendSlice(allocator, self.spans.items);
        result.known_chunks = .empty;
        try result.known_chunks.appendSlice(allocator, self.known_chunks.items);
        return result;
    }

    pub fn deinit(self: *SceneGrid) void {
        self.allocator.free(self.columns);
        self.spans.deinit(self.allocator);
        self.known_chunks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Includes the value itself and allocated capacity, not just live spans.
    pub fn memoryBytes(self: *const SceneGrid) usize {
        return @sizeOf(SceneGrid) + self.columns.len * @sizeOf(SceneColumn) + self.spans.capacity * @sizeOf(SceneSpan) + self.known_chunks.capacity * @sizeOf(KnownChunk);
    }

    /// Includes halo geometry; a grid with no geometry has no height bounds.
    pub fn heightBounds(self: *const SceneGrid) ?struct { min: f32, max: f32 } {
        if (self.spans.items.len == 0) return null;
        var min = self.spans.items[0].min_y;
        var max = self.spans.items[0].max_y;
        for (self.spans.items[1..]) |span| {
            min = @min(min, span.min_y);
            max = @max(max, span.max_y);
        }
        return .{ .min = min, .max = max };
    }
};

test "ChunkSummary capture preserves layer depths gaps foliage water and boundary light" {
    const testing = std.testing;
    var chunk = Chunk.init(-3, 7);
    chunk.setBiome(2, 3, .forest);
    for (0..5) |y| chunk.setBlock(2, @intCast(y), 3, .stone);
    for (5..8) |y| chunk.setBlock(2, @intCast(y), 3, .dirt);
    chunk.setBlock(2, 8, 3, .grass);
    for (10..12) |y| chunk.setBlock(2, @intCast(y), 3, .water);
    for (14..17) |y| chunk.setBlock(2, @intCast(y), 3, .birch_leaves);
    chunk.setBlock(2, 18, 3, .birch_leaves);
    chunk.setBlock(2, 19, 3, .flower_red);
    chunk.setBlock(2, 255, 3, .snow_layer);
    chunk.setLight(2, 12, 3, PackedLight.initRGB(9, 1, 2, 3));
    chunk.setLight(2, 9, 3, PackedLight.initRGB(4, 5, 6, 7));

    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    try summary.validate();
    try testing.expectEqual(@as(i32, -3), summary.chunk_x);
    try testing.expectEqual(@as(i32, 7), summary.chunk_z);
    try testing.expectEqual(Origin.live, summary.origin);
    try testing.expectEqual(chunk.content_revision.load(.acquire), summary.revision);
    try testing.expectEqual(BiomeId.forest, summary.columns[3 * 16 + 2].biome);
    const runs = summary.column(2, 3);
    try testing.expectEqual(@as(usize, 8), runs.len);
    const expected_min = [_]u16{ 0, 5, 8, 10, 14, 18, 19, 255 };
    const expected_max = [_]u16{ 5, 8, 9, 12, 17, 19, 20, 256 };
    const expected_blocks = [_]BlockType{ .stone, .dirt, .grass, .water, .birch_leaves, .birch_leaves, .flower_red, .snow_layer };
    for (runs, expected_min, expected_max, expected_blocks) |run, min, max, block| {
        try testing.expectEqual(min, run.min_y);
        try testing.expectEqual(max, run.max_y);
        try testing.expectEqual(block, run.block);
    }
    try testing.expectEqualDeep(PackedLight.initRGB(9, 1, 2, 3), runs[3].light_top);
    try testing.expectEqualDeep(PackedLight.initRGB(4, 5, 6, 7), runs[3].light_bottom);
    try testing.expectEqualDeep(PackedLight.init(0, 0), runs[0].light_bottom);
    try testing.expectEqualDeep(PackedLight.init(15, 0), runs[7].light_top);
    try testing.expectEqual(@as(usize, 0), summary.column(3, 2).len);
    try testing.expectEqual(@sizeOf(ChunkSummary) + runs.len * @sizeOf(Run), summary.memoryBytes());

    // Verify every voxel, including air gaps and all other columns, against source.
    for (0..16) |z| {
        for (0..16) |x| {
            var reconstructed = [_]BlockType{.air} ** 256;
            for (summary.column(@intCast(x), @intCast(z))) |run| {
                @memset(reconstructed[run.min_y..run.max_y], run.block);
            }
            for (reconstructed, 0..) |block, y| {
                try testing.expectEqual(chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)), block);
            }
        }
    }
}

test "ChunkSummary capture retains the finite worst case of 65536 runs" {
    const testing = std.testing;
    var chunk = Chunk.init(0, 0);
    for (0..256) |y| chunk.fillLayer(@intCast(y), if (y % 2 == 0) .stone else .water);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    try summary.validate();
    try testing.expectEqual(@as(usize, 65536), summary.runs.len);
    for (summary.columns) |info| try testing.expectEqual(@as(u16, 256), info.count);
    const last = summary.column(15, 15);
    try testing.expectEqual(@as(u16, 255), last[255].min_y);
    try testing.expectEqual(@as(u16, 256), last[255].max_y);
}

test "ChunkSummary fingerprint is deterministic geometry only and clone is independent" {
    const testing = std.testing;
    var chunk = Chunk.init(-8, 5);
    chunk.setBlock(1, 2, 3, .stone);
    chunk.setBlock(1, 3, 3, .water);
    var original = try ChunkSummary.capture(testing.allocator, &chunk);
    defer original.deinit();
    const hash = original.fingerprint();
    chunk.setLight(1, 4, 3, PackedLight.init(15, 6));
    var relit = try ChunkSummary.capture(testing.allocator, &chunk);
    defer relit.deinit();
    relit.origin = .saved;
    relit.revision += 123;
    try testing.expectEqual(hash, relit.fingerprint());
    try testing.expect(!std.meta.eql(original.runs[1].light_top, relit.runs[1].light_top));

    var copy = try original.clone(testing.allocator);
    defer copy.deinit();
    try testing.expectEqual(hash, copy.fingerprint());
    try testing.expectEqualDeep(original.columns, copy.columns);
    try testing.expectEqual(original.origin, copy.origin);
    try testing.expectEqual(original.revision, copy.revision);
    copy.runs[0].light_bottom = PackedLight.init(3, 7);
    try testing.expectEqual(hash, copy.fingerprint());
    copy.runs[0].block = .water;
    copy.runs[1].block = .stone;
    try testing.expect(hash != copy.fingerprint());
    try testing.expectEqual(BlockType.stone, original.runs[0].block);
    @memcpy(copy.runs, original.runs);
    copy.runs[0].min_y -= 1;
    try testing.expect(hash != copy.fingerprint());
    @memcpy(copy.runs, original.runs);
    copy.columns[0].biome = .ocean;
    try testing.expect(hash != copy.fingerprint());
    copy.columns = original.columns;
    copy.chunk_x += 1;
    try testing.expect(hash != copy.fingerprint());
    copy.chunk_x = original.chunk_x;
    copy.chunk_z += 1;
    try testing.expect(hash != copy.fingerprint());
}

test "ChunkSummary validate rejects malformed codec headers runs and block tags" {
    const testing = std.testing;
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 2, 0, .stone);
    chunk.setBlock(0, 4, 0, .stone);
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    const info = summary.columns[0];
    summary.columns[0].offset = std.math.maxInt(u32);
    try testing.expectError(error.InvalidColumnRange, summary.validate());
    summary.columns[0] = info;
    summary.columns[0].count = 257;
    try testing.expectError(error.TooManyRuns, summary.validate());
    summary.columns[0].count = 3;
    try testing.expectError(error.InvalidColumnRange, summary.validate());
    summary.columns[0] = info;
    summary.columns[1].offset = 0;
    try testing.expectError(error.InvalidColumnRange, summary.validate());
    summary.columns[1].offset = 2;
    const run = summary.runs[1];
    summary.runs[1].min_y = 1;
    try testing.expectError(error.InvalidRunOrder, summary.validate());
    summary.runs[1].min_y = 3;
    try testing.expectError(error.UncoalescedRun, summary.validate());
    summary.runs[1] = run;
    summary.runs[1].max_y = 257;
    try testing.expectError(error.InvalidRunBounds, summary.validate());
    summary.runs[1].max_y = run.min_y;
    try testing.expectError(error.InvalidRunBounds, summary.validate());
    summary.runs[1] = run;
    summary.runs[1].block = .air;
    try testing.expectError(error.InvalidBlock, summary.validate());
    summary.runs[1].block = @enumFromInt(255);
    try testing.expectError(error.InvalidBlock, summary.validate());
    summary.runs[1] = run;
    try summary.validate();
    const owned_runs = summary.runs;
    const oversized = try testing.allocator.alloc(Run, 65537);
    defer testing.allocator.free(oversized);
    summary.runs = oversized;
    defer summary.runs = owned_runs;
    try testing.expectError(error.TooManyRuns, summary.validate());
}

test "SceneGrid halo distinguishes known air unknown cells and partial geometry" {
    const testing = std.testing;
    var grid = try SceneGrid.init(testing.allocator, -32, 64, 4, 2);
    defer grid.deinit();
    try testing.expectEqual(@as(usize, 16), grid.columns.len);
    try testing.expect(grid.heightBounds() == null);
    try grid.appendColumn(0, 0, &.{}, 16, 16, false);
    try grid.appendColumn(1, 0, &.{}, 0, 16, false);
    try testing.expectEqual(@as(usize, 0), grid.column(0, 0).len);
    try testing.expectEqual(@as(u32, 16), grid.columnInfo(0, 0).known_area);
    try testing.expectEqual(@as(u32, 0), grid.columnInfo(1, 0).known_area);
    try testing.expectEqual(@as(u32, 0), grid.columnInfo(0, 1).total_area);
    try testing.expectError(error.ColumnAlreadyWritten, grid.appendColumn(0, 0, &.{}, 16, 16, false));
    try testing.expectError(error.ColumnAlreadyWritten, grid.appendColumn(1, 0, &.{}, 0, 16, false));
    const corners = [_][2]i32{ .{ -1, -1 }, .{ 2, -1 }, .{ -1, 2 }, .{ 2, 2 } };
    for (corners, 0..) |corner, i| {
        const span: SceneSpan = .{
            .min_y = @floatFromInt(i + 1),
            .max_y = @floatFromInt(i + 2),
            .block = .water,
            .biome = .river,
            .coverage = 0.5,
            .light = PackedLight.init(11, 0),
        };
        try grid.appendColumn(corner[0], corner[1], &.{span}, 8, 16, true);
        try testing.expectEqualDeep(span, grid.column(corner[0], corner[1])[0]);
        try testing.expect(grid.columnInfo(corner[0], corner[1]).approximate);
    }
    const bounds = grid.heightBounds().?;
    try testing.expectEqual(@as(f32, 1), bounds.min);
    try testing.expectEqual(@as(f32, 5), bounds.max);
    try grid.known_chunks.appendSlice(testing.allocator, &.{ .{ .cx = -3, .cz = 3 }, .{ .cx = -2, .cz = 4 } });
    try testing.expectEqual(@sizeOf(SceneGrid) + grid.columns.len * @sizeOf(SceneColumn) + grid.spans.capacity * @sizeOf(SceneSpan) + grid.known_chunks.capacity * @sizeOf(KnownChunk), grid.memoryBytes());
    grid.source_epoch = 42;
    var copy = try grid.clone(testing.allocator);
    defer copy.deinit();
    try testing.expectEqualDeep(grid.columns, copy.columns);
    try testing.expectEqualDeep(grid.spans.items, copy.spans.items);
    try testing.expectEqualDeep(grid.known_chunks.items, copy.known_chunks.items);
    try testing.expectEqual(grid.source_epoch, copy.source_epoch);
    try testing.expectEqual(grid.origin_x, copy.origin_x);
    try testing.expectEqual(grid.origin_z, copy.origin_z);
    try testing.expectEqual(grid.cell_size, copy.cell_size);
    try testing.expectEqual(grid.width, copy.width);
    copy.spans.items[0].block = .stone;
    copy.columnInfo(0, 0).known_area = 0;
    copy.known_chunks.items[0].cx = -4;
    try copy.known_chunks.append(testing.allocator, .{ .cx = -2, .cz = 5 });
    try testing.expectEqual(@as(usize, 2), grid.known_chunks.items.len);
    try testing.expectEqual(KnownChunk{ .cx = -3, .cz = 3 }, grid.known_chunks.items[0]);
    try testing.expectEqual(BlockType.water, grid.column(-1, -1)[0].block);
    try testing.expectEqual(@as(u32, 16), grid.columnInfo(0, 0).known_area);
}

test "SceneGrid rejects invalid dimensions coordinates areas and nonfinite spans" {
    const testing = std.testing;
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidGridSize, SceneGrid.init(allocator, 0, 0, 1, 0));
    try testing.expectError(error.InvalidGridSize, SceneGrid.init(allocator, 0, 0, 1, 257));
    try testing.expectError(error.InvalidCellSize, SceneGrid.init(allocator, 0, 0, 0, 1));
    try testing.expectError(error.InvalidCellSize, SceneGrid.init(allocator, 0, 0, 3, 1));
    try testing.expectError(error.InvalidCellSize, SceneGrid.init(allocator, 0, 0, 65536, 1));
    try testing.expectError(error.InvalidGridCoordinates, SceneGrid.init(allocator, std.math.minInt(i32), 0, 1, 1));
    try testing.expectError(error.InvalidGridCoordinates, SceneGrid.init(allocator, 0, std.math.maxInt(i32), 1, 1));
    var grid = try SceneGrid.init(allocator, -256, -256, 1, 256);
    defer grid.deinit();
    try testing.expectError(error.InvalidGridCoordinates, grid.appendColumn(-2, 0, &.{}, 1, 1, false));
    try testing.expectError(error.InvalidGridCoordinates, grid.appendColumn(0, 257, &.{}, 1, 1, false));
    try testing.expectError(error.InvalidArea, grid.appendColumn(0, 0, &.{}, 2, 1, false));
    try testing.expectError(error.InvalidArea, grid.appendColumn(0, 0, &.{}, 0, 0, false));
    var span: SceneSpan = .{ .min_y = 0, .max_y = 256, .block = .leaves, .biome = .forest, .light = PackedLight.init(15, 0) };
    span.max_y = std.math.inf(f32);
    try testing.expectError(error.InvalidSpanBounds, grid.appendColumn(0, 0, &.{span}, 1, 1, false));
    span.max_y = 256;
    span.coverage = std.math.nan(f32);
    try testing.expectError(error.InvalidSpanCoverage, grid.appendColumn(0, 0, &.{span}, 1, 1, false));
    span.coverage = 1;
    span.center_z = -0.5;
    try testing.expectError(error.InvalidSpanCoverage, grid.appendColumn(0, 0, &.{span}, 1, 1, false));
    span.center_z = 0.5;
    try testing.expectEqual(@as(usize, 0), grid.spans.items.len);
    try testing.expectEqual(@as(u32, 0), grid.columnInfo(0, 0).total_area);
    try grid.appendColumn(0, 0, &.{span}, 1, 1, false);
    try testing.expectEqual(@as(f32, 256), grid.heightBounds().?.max);
}

test "Scene storage allocation failures leave sources and append state intact" {
    const testing = std.testing;
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 0, 0, .stone);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, ChunkSummary.capture(failing.allocator(), &chunk));
    var summary = try ChunkSummary.capture(testing.allocator, &chunk);
    defer summary.deinit();
    failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, summary.clone(failing.allocator()));
    try summary.validate();

    failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, SceneGrid.init(failing.allocator(), 0, 0, 1, 1));
    var grid = try SceneGrid.init(testing.allocator, 0, 0, 1, 1);
    defer grid.deinit();
    const span: SceneSpan = .{ .min_y = 1, .max_y = 2, .block = .stone, .biome = .plains, .light = PackedLight.init(15, 0) };
    failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    grid.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, grid.appendColumn(-1, -1, &.{span}, 1, 1, false));
    grid.allocator = testing.allocator;
    try testing.expectEqual(@as(usize, 0), grid.spans.items.len);
    try testing.expectEqual(@as(u32, 0), grid.columnInfo(-1, -1).total_area);
    try grid.appendColumn(-1, -1, &.{span}, 1, 1, false);
    try grid.known_chunks.append(testing.allocator, .{ .cx = -1, .cz = -1 });
    for (0..3) |fail_index| {
        var clone_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, grid.clone(clone_allocator.allocator()));
        try testing.expectEqualDeep(span, grid.column(-1, -1)[0]);
        try testing.expectEqualSlices(KnownChunk, &.{.{ .cx = -1, .cz = -1 }}, grid.known_chunks.items);
    }
}
