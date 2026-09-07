//! Disk serialization for generated LOD source data.

const std = @import("std");

const world_core = @import("world-core");
const LODLevel = @import("lod_types.zig").LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const LODMaterialLayers = world_core.LODMaterialLayers;
const LODWaterState = world_core.LODWaterState;
const LODLightingHint = world_core.LODLightingHint;
const LODVegetationHint = world_core.LODVegetationHint;
const LODVerticalSpan = world_core.LODVerticalSpan;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;

pub const MAGIC: u32 = 0x5A4C4F44; // "ZLOD"
pub const CACHE_VERSION: u8 = 11;
const CACHE_VERSION_V10: u8 = 10;
pub const CACHE_VERSION_V1: u8 = 1;
pub const HEADER_SIZE: usize = 42;

pub const Key = struct {
    seed: u64,
    generator_identity_hash: u64,
    generator_version: u32,
    rx: i32,
    rz: i32,
    lod: LODLevel,
};

pub const CacheError = error{
    InvalidMagic,
    UnsupportedVersion,
    DataTooShort,
    InvalidKey,
    InvalidWidth,
    InvalidBiome,
    InvalidBlock,
    InvalidSpanCount,
    InvalidProvenance,
    MissingProvenance,
    ChecksumMismatch,
    CanonicalSourceUnsupported,
};

pub const ColumnProvenance = world_core.LODColumnProvenance;

const BIOME_COUNT: usize = @typeInfo(BiomeId).@"enum".fields.len;
const BLOCK_COUNT: usize = @typeInfo(BlockType).@"enum".fields.len;
const HEIGHT_WIRE_SIZE: usize = @sizeOf(f32);
const BIOME_WIRE_SIZE: usize = @sizeOf(BiomeId);
const BLOCK_WIRE_SIZE: usize = @sizeOf(BlockType);
const COLOR_WIRE_SIZE: usize = @sizeOf(u32);
const MATERIAL_LAYERS_WIRE_SIZE: usize = 3 * BLOCK_WIRE_SIZE;
const WATER_WIRE_SIZE: usize = @sizeOf(u8) + 3 * @sizeOf(f32);
const LIGHTING_WIRE_SIZE: usize = 2 * @sizeOf(u8) + @sizeOf(f32);
const VEGETATION_WIRE_SIZE: usize = 4 * @sizeOf(f32) + 2 * BLOCK_WIRE_SIZE;
const CELL_WIRE_SIZE: usize = HEIGHT_WIRE_SIZE + BIOME_WIRE_SIZE + BLOCK_WIRE_SIZE + COLOR_WIRE_SIZE + MATERIAL_LAYERS_WIRE_SIZE + WATER_WIRE_SIZE + LIGHTING_WIRE_SIZE + VEGETATION_WIRE_SIZE;
const SPAN_FLAGS_WIRE_SIZE: usize = @sizeOf(u8);
const SPAN_WIRE_SIZE: usize = 2 * HEIGHT_WIRE_SIZE + BIOME_WIRE_SIZE + MATERIAL_LAYERS_WIRE_SIZE + COLOR_WIRE_SIZE + WATER_WIRE_SIZE + LIGHTING_WIRE_SIZE + VEGETATION_WIRE_SIZE;

comptime {
    std.debug.assert(MATERIAL_LAYERS_WIRE_SIZE == 3);
    std.debug.assert(WATER_WIRE_SIZE == 13);
    std.debug.assert(LIGHTING_WIRE_SIZE == 6);
    std.debug.assert(VEGETATION_WIRE_SIZE == 18);
    std.debug.assert(CELL_WIRE_SIZE == 50);
    std.debug.assert(SPAN_WIRE_SIZE == 53);
}

fn payloadSize(count: usize) usize {
    return count * CELL_WIRE_SIZE;
}

pub fn serializedSize(data: *const LODSimplifiedData) usize {
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    var total = HEADER_SIZE + payloadSize(count) + SPAN_FLAGS_WIRE_SIZE + count;
    if (data.hasVerticalSpans()) {
        total += count; // vertical span counts
        total += count * world_core.MAX_LOD_VERTICAL_SPANS * SPAN_WIRE_SIZE;
    }
    return total;
}

/// Creates an allocator-owned snapshot suitable for handing to an asynchronous
/// serializer. Source data remains owned by the LOD region and may be edited
/// as soon as this returns.
pub fn cloneSourceData(data: *const LODSimplifiedData, lod: LODLevel, allocator: std.mem.Allocator) !LODSimplifiedData {
    var copy = if (data.hasVerticalSpans())
        try LODSimplifiedData.initWithVerticalSpansGridSize(allocator, lod, data.width)
    else
        try LODSimplifiedData.initWithGridSize(allocator, lod, data.width);
    errdefer copy.deinit();

    copy.version = data.version;
    @memcpy(copy.heightmap, data.heightmap);
    @memcpy(copy.biomes, data.biomes);
    @memcpy(copy.top_blocks, data.top_blocks);
    @memcpy(copy.colors, data.colors);
    @memcpy(copy.material_layers, data.material_layers);
    @memcpy(copy.water, data.water);
    @memcpy(copy.lighting, data.lighting);
    @memcpy(copy.vegetation, data.vegetation);
    @memcpy(copy.provenance, data.provenance);
    if (data.vertical_span_counts) |counts| @memcpy(copy.vertical_span_counts.?, counts);
    if (data.vertical_spans) |spans| @memcpy(copy.vertical_spans.?, spans);
    if (data.scene_grid) |grid| {
        const owned = try allocator.create(world_core.lod_scene.SceneGrid);
        owned.* = grid.clone(allocator) catch |err| {
            allocator.destroy(owned);
            return err;
        };
        copy.scene_grid = owned;
    }
    return copy;
}

fn writeF32(buf: []u8, value: f32) void {
    std.mem.writeInt(u32, buf[0..4], @as(u32, @bitCast(value)), .little);
}

fn readF32(buf: []const u8) f32 {
    return @as(f32, @bitCast(std.mem.readInt(u32, buf[0..4], .little)));
}

fn writeBlock(buf: []u8, block: BlockType) void {
    buf[0] = @intFromEnum(block);
}

fn readBlock(byte: u8) !BlockType {
    if (byte >= BLOCK_COUNT) return CacheError.InvalidBlock;
    return std.enums.fromInt(BlockType, byte) orelse CacheError.InvalidBlock;
}

fn readBiome(byte: u8) !BiomeId {
    if (byte >= BIOME_COUNT) return CacheError.InvalidBiome;
    return std.enums.fromInt(BiomeId, byte) orelse CacheError.InvalidBiome;
}

fn writeMaterialLayers(buf: []u8, layers: LODMaterialLayers) void {
    writeBlock(buf[0..1], layers.surface);
    writeBlock(buf[1..2], layers.subsurface);
    writeBlock(buf[2..3], layers.foundation);
}

fn readMaterialLayers(buf: []const u8) !LODMaterialLayers {
    return .{
        .surface = try readBlock(buf[0]),
        .subsurface = try readBlock(buf[1]),
        .foundation = try readBlock(buf[2]),
    };
}

fn writeWater(buf: []u8, water: LODWaterState) void {
    buf[0] = if (water.is_surface) 1 else 0;
    writeF32(buf[1..][0..4], water.surface_height);
    writeF32(buf[5..][0..4], water.depth);
    writeF32(buf[9..][0..4], water.coverage);
}

fn readWater(buf: []const u8) LODWaterState {
    return .{
        .is_surface = buf[0] != 0,
        .surface_height = readF32(buf[1..][0..4]),
        .depth = readF32(buf[5..][0..4]),
        .coverage = readF32(buf[9..][0..4]),
    };
}

fn writeLighting(buf: []u8, lighting: LODLightingHint) void {
    buf[0] = lighting.sky_light;
    buf[1] = lighting.block_light;
    writeF32(buf[2..][0..4], lighting.ambient_occlusion);
}

fn readLighting(buf: []const u8) LODLightingHint {
    return .{
        .sky_light = buf[0],
        .block_light = buf[1],
        .ambient_occlusion = readF32(buf[2..][0..4]),
    };
}

fn writeVegetation(buf: []u8, vegetation: LODVegetationHint) void {
    writeF32(buf[0..][0..4], vegetation.tree_coverage);
    writeF32(buf[4..][0..4], vegetation.avg_tree_height);
    writeF32(buf[8..][0..4], vegetation.offset_x);
    writeF32(buf[12..][0..4], vegetation.offset_z);
    writeBlock(buf[16..17], vegetation.trunk);
    writeBlock(buf[17..18], vegetation.leaves);
}

fn readVegetation(buf: []const u8) !LODVegetationHint {
    return .{
        .tree_coverage = readF32(buf[0..][0..4]),
        .avg_tree_height = readF32(buf[4..][0..4]),
        .offset_x = readF32(buf[8..][0..4]),
        .offset_z = readF32(buf[12..][0..4]),
        .trunk = try readBlock(buf[16]),
        .leaves = try readBlock(buf[17]),
    };
}

fn writeSpan(buf: []u8, span: LODVerticalSpan) void {
    var off: usize = 0;
    writeF32(buf[off..][0..4], span.min_height);
    off += 4;
    writeF32(buf[off..][0..4], span.max_height);
    off += 4;
    buf[off] = @intFromEnum(span.biome);
    off += 1;
    writeMaterialLayers(buf[off..][0..3], span.material_layers);
    off += 3;
    std.mem.writeInt(u32, buf[off..][0..4], span.color, .little);
    off += 4;
    writeWater(buf[off..][0..WATER_WIRE_SIZE], span.water);
    off += WATER_WIRE_SIZE;
    writeLighting(buf[off..][0..LIGHTING_WIRE_SIZE], span.lighting);
    off += LIGHTING_WIRE_SIZE;
    writeVegetation(buf[off..][0..VEGETATION_WIRE_SIZE], span.vegetation);
}

fn readSpan(buf: []const u8) !LODVerticalSpan {
    var off: usize = 0;
    const min_height = readF32(buf[off..][0..4]);
    off += 4;
    const max_height = readF32(buf[off..][0..4]);
    off += 4;
    const biome = try readBiome(buf[off]);
    off += 1;
    const material_layers = try readMaterialLayers(buf[off..][0..3]);
    off += 3;
    const color = std.mem.readInt(u32, buf[off..][0..4], .little);
    off += 4;
    const water = readWater(buf[off..][0..WATER_WIRE_SIZE]);
    off += WATER_WIRE_SIZE;
    const lighting = readLighting(buf[off..][0..LIGHTING_WIRE_SIZE]);
    off += LIGHTING_WIRE_SIZE;
    const vegetation = try readVegetation(buf[off..][0..VEGETATION_WIRE_SIZE]);
    return .{ .min_height = min_height, .max_height = max_height, .biome = biome, .material_layers = material_layers, .color = color, .water = water, .lighting = lighting, .vegetation = vegetation };
}

fn computeCrc(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[0..6]);
    crc.update(&.{ 0, 0, 0, 0 });
    crc.update(bytes[10..]);
    return crc.final();
}

pub fn serialize(data: *const LODSimplifiedData, key: Key, allocator: std.mem.Allocator) ![]u8 {
    // Canonical summaries have their own store; the legacy wire format cannot
    // silently discard cell occupancy, material runs, or halo ownership.
    if (data.scene_grid != null) return CacheError.CanonicalSourceUnsupported;
    const width_usize = @as(usize, @intCast(data.width));
    const count = width_usize * width_usize;
    const total_size = serializedSize(data);
    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var off: usize = 0;
    std.mem.writeInt(u32, buf[off..][0..4], MAGIC, .little);
    off += 4;
    buf[off] = CACHE_VERSION;
    off += 1;
    buf[off] = @intFromEnum(key.lod);
    off += 1;
    std.mem.writeInt(u32, buf[off..][0..4], 0, .little);
    off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], key.seed, .little);
    off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], key.generator_identity_hash, .little);
    off += 8;
    std.mem.writeInt(u32, buf[off..][0..4], key.generator_version, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], key.rx, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], key.rz, .little);
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], data.width, .little);
    off += 4;

    for (data.heightmap) |height| {
        writeF32(buf[off..][0..4], height);
        off += 4;
    }
    for (data.biomes) |biome| {
        buf[off] = @intFromEnum(biome);
        off += 1;
    }
    for (data.top_blocks) |block| {
        writeBlock(buf[off..][0..1], block);
        off += 1;
    }
    for (data.colors) |color| {
        std.mem.writeInt(u32, buf[off..][0..4], color, .little);
        off += 4;
    }
    for (data.material_layers) |layers| {
        writeMaterialLayers(buf[off..][0..3], layers);
        off += 3;
    }
    for (data.water) |water| {
        writeWater(buf[off..][0..WATER_WIRE_SIZE], water);
        off += WATER_WIRE_SIZE;
    }
    for (data.lighting) |lighting| {
        writeLighting(buf[off..][0..LIGHTING_WIRE_SIZE], lighting);
        off += LIGHTING_WIRE_SIZE;
    }
    for (data.vegetation) |vegetation| {
        writeVegetation(buf[off..][0..VEGETATION_WIRE_SIZE], vegetation);
        off += VEGETATION_WIRE_SIZE;
    }

    const has_spans = data.hasVerticalSpans();
    buf[off] = if (has_spans) 1 else 0;
    off += 1;
    for (data.provenance) |provenance| {
        buf[off] = @intFromEnum(provenance);
        off += 1;
    }
    if (has_spans) {
        const counts = data.vertical_span_counts.?;
        const spans = data.vertical_spans.?;
        @memcpy(buf[off..][0..count], counts);
        off += count;
        for (spans) |span| {
            writeSpan(buf[off..][0..SPAN_WIRE_SIZE], span);
            off += SPAN_WIRE_SIZE;
        }
    }

    std.debug.assert(off == total_size);
    const crc = computeCrc(buf);
    std.mem.writeInt(u32, buf[6..][0..4], crc, .little);
    return buf;
}

pub fn deserialize(bytes: []const u8, key: Key, allocator: std.mem.Allocator) !LODSimplifiedData {
    if (bytes.len < HEADER_SIZE) return CacheError.DataTooShort;

    var off: usize = 0;
    if (std.mem.readInt(u32, bytes[off..][0..4], .little) != MAGIC) return CacheError.InvalidMagic;
    off += 4;

    const version = bytes[off];
    if (version != CACHE_VERSION and version != CACHE_VERSION_V10 and version != CACHE_VERSION_V1) return CacheError.UnsupportedVersion;
    off += 1;
    const lod_byte = bytes[off];
    off += 1;
    if (lod_byte != @intFromEnum(key.lod)) return CacheError.InvalidKey;

    const stored_crc = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;
    if (computeCrc(bytes) != stored_crc) return CacheError.ChecksumMismatch;

    const seed = std.mem.readInt(u64, bytes[off..][0..8], .little);
    off += 8;
    const generator_identity_hash = std.mem.readInt(u64, bytes[off..][0..8], .little);
    off += 8;
    const generator_version = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;
    const rx = std.mem.readInt(i32, bytes[off..][0..4], .little);
    off += 4;
    const rz = std.mem.readInt(i32, bytes[off..][0..4], .little);
    off += 4;
    const width = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;

    if (seed != key.seed or generator_identity_hash != key.generator_identity_hash or generator_version != key.generator_version or rx != key.rx or rz != key.rz) return CacheError.InvalidKey;
    if (!LODSimplifiedData.isSupportedGridSize(key.lod, width)) return CacheError.InvalidWidth;

    const count = @as(usize, @intCast(width)) * @as(usize, @intCast(width));
    const v1_expected = HEADER_SIZE + payloadSize(count);
    if (bytes.len < v1_expected) return CacheError.DataTooShort;

    var has_spans = false;
    var expected = v1_expected;
    if (version == CACHE_VERSION or version == CACHE_VERSION_V10) {
        if (bytes.len < v1_expected + SPAN_FLAGS_WIRE_SIZE) return CacheError.DataTooShort;
        has_spans = bytes[v1_expected] != 0;
        expected = v1_expected + SPAN_FLAGS_WIRE_SIZE;
        if (version == CACHE_VERSION) expected += count;
        if (has_spans) {
            if (version == CACHE_VERSION_V10) expected += count;
            expected += count + count * world_core.MAX_LOD_VERTICAL_SPANS * SPAN_WIRE_SIZE;
        }
    }
    if (bytes.len < expected) return CacheError.DataTooShort;

    // Older span-less payloads never recorded source authority. Treat them as
    // stale instead of silently converting edited/chunk-derived columns back
    // to worldgen data; the cache pipeline will regenerate them safely.
    if ((version == CACHE_VERSION_V1) or (version == CACHE_VERSION_V10 and !has_spans)) return CacheError.MissingProvenance;

    var data = if (has_spans)
        try LODSimplifiedData.initWithVerticalSpansGridSize(allocator, key.lod, width)
    else
        try LODSimplifiedData.initWithGridSize(allocator, key.lod, width);
    errdefer data.deinit();

    for (data.heightmap) |*height| {
        height.* = readF32(bytes[off..][0..4]);
        off += 4;
    }
    for (data.biomes) |*biome| {
        biome.* = try readBiome(bytes[off]);
        off += 1;
    }
    for (data.top_blocks) |*block| {
        block.* = try readBlock(bytes[off]);
        off += 1;
    }
    for (data.colors) |*color| {
        color.* = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
    }
    for (data.material_layers) |*layers| {
        layers.* = try readMaterialLayers(bytes[off..][0..3]);
        off += 3;
    }
    for (data.water) |*water| {
        water.* = readWater(bytes[off..][0..WATER_WIRE_SIZE]);
        off += 13;
    }
    for (data.lighting) |*lighting| {
        lighting.* = readLighting(bytes[off..][0..LIGHTING_WIRE_SIZE]);
        off += 6;
    }
    for (data.vegetation) |*vegetation| {
        vegetation.* = try readVegetation(bytes[off..][0..VEGETATION_WIRE_SIZE]);
        off += 18;
    }

    if (version == CACHE_VERSION or version == CACHE_VERSION_V10) {
        const flags = bytes[off];
        off += 1;
        if ((flags & ~@as(u8, 1)) != 0) return CacheError.InvalidSpanCount;
        if (version == CACHE_VERSION or has_spans) {
            for (data.provenance) |*provenance| {
                const byte = bytes[off];
                provenance.* = switch (byte) {
                    0 => .worldgen,
                    1 => .chunk_derived,
                    2 => .edited,
                    else => return CacheError.InvalidProvenance,
                };
                off += 1;
            }
        }
        if (has_spans) {
            const counts = data.vertical_span_counts.?;
            @memcpy(counts, bytes[off..][0..count]);
            off += count;
            for (counts) |span_count| {
                if (span_count > world_core.MAX_LOD_VERTICAL_SPANS) return CacheError.InvalidSpanCount;
            }
            const spans = data.vertical_spans.?;
            for (spans) |*span| {
                span.* = try readSpan(bytes[off..][0..SPAN_WIRE_SIZE]);
                off += SPAN_WIRE_SIZE;
            }
        }
    }

    std.debug.assert(off == expected);
    return data;
}

const testing = std.testing;

test "LOD cache round-trip preserves source data" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer data.deinit();

    data.setColumn(1, 2, 77.5, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF336699, .{
        .is_surface = true,
        .surface_height = 63.0,
        .depth = 3.5,
        .coverage = 0.75,
    }, .{
        .sky_light = 12,
        .block_light = 2,
        .ambient_occlusion = 0.8,
    }, .{
        .tree_coverage = 0.4,
        .avg_tree_height = 8.0,
        .offset_x = 0.2,
        .offset_z = -0.3,
        .trunk = .wood,
        .leaves = .leaves,
    });

    const key = Key{ .seed = 1234, .generator_identity_hash = 99, .generator_version = 7, .rx = -2, .rz = 3, .lod = .lod2 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try deserialize(bytes, key, testing.allocator);
    defer decoded.deinit();

    const idx = 1 + 2 * data.width;
    try testing.expectEqual(data.heightmap[idx], decoded.heightmap[idx]);
    try testing.expectEqual(data.biomes[idx], decoded.biomes[idx]);
    try testing.expectEqual(data.top_blocks[idx], decoded.top_blocks[idx]);
    try testing.expectEqual(data.colors[idx], decoded.colors[idx]);
    try testing.expectEqual(data.material_layers[idx].subsurface, decoded.material_layers[idx].subsurface);
    try testing.expectEqual(data.water[idx].depth, decoded.water[idx].depth);
    try testing.expectEqual(data.lighting[idx].sky_light, decoded.lighting[idx].sky_light);
    try testing.expectEqual(data.vegetation[idx].leaves, decoded.vegetation[idx].leaves);
}

test "LOD cache round-trips reduced far density widths" {
    inline for ([_]struct { lod: LODLevel, density: f32, width: u32 }{
        .{ .lod = .lod3, .density = 0.5, .width = 65 },
        .{ .lod = .lod4, .density = 0.25, .width = 17 },
    }) |case| {
        var data = try LODSimplifiedData.initWithSampleDensity(testing.allocator, case.lod, case.density);
        defer data.deinit();
        data.setHeight(0, 0, 83.0);
        const key = Key{ .seed = 73, .generator_identity_hash = 9, .generator_version = 2, .rx = 1, .rz = -1, .lod = case.lod };
        const bytes = try serialize(&data, key, testing.allocator);
        defer testing.allocator.free(bytes);
        var decoded = try deserialize(bytes, key, testing.allocator);
        defer decoded.deinit();
        try testing.expectEqual(case.width, decoded.width);
        try testing.expectEqual(@as(f32, 83.0), decoded.getHeight(0, 0));
    }
}

test "LOD cache round-trip preserves vertical spans" {
    var data = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod1);
    defer data.deinit();

    const lower = LODVerticalSpan{
        .min_height = 12.0,
        .max_height = 48.0,
        .biome = .forest,
        .material_layers = .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone },
        .color = 0xFF112233,
        .water = .empty,
        .lighting = .{ .sky_light = 9, .block_light = 1, .ambient_occlusion = 0.7 },
        .vegetation = .{ .tree_coverage = 0.5, .avg_tree_height = 7.0, .offset_x = 0.25, .offset_z = -0.25, .trunk = .wood, .leaves = .leaves },
    };
    const upper = LODVerticalSpan{
        .min_height = 49.0,
        .max_height = 92.0,
        .biome = .mountains,
        .material_layers = .{ .surface = .stone, .subsurface = .stone, .foundation = .stone },
        .color = 0xFF8899AA,
        .water = .{ .is_surface = true, .surface_height = 64.0, .depth = 2.0, .coverage = 0.25 },
        .lighting = .daylight,
        .vegetation = .empty,
    };
    try testing.expect(data.setVerticalSpan(2, 3, 0, lower));
    try testing.expect(data.setVerticalSpan(2, 3, 1, upper));

    const key = Key{ .seed = 1234, .generator_identity_hash = 99, .generator_version = 7, .rx = -2, .rz = 3, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try deserialize(bytes, key, testing.allocator);
    defer decoded.deinit();

    try testing.expect(decoded.hasVerticalSpans());
    try testing.expectEqual(data.vertical_span_counts.?.len, decoded.vertical_span_counts.?.len);
    try testing.expectEqualSlices(u8, data.vertical_span_counts.?, decoded.vertical_span_counts.?);
    try testing.expectEqual(lower, decoded.getVerticalSpan(2, 3, 0).?);
    try testing.expectEqual(upper, decoded.getVerticalSpan(2, 3, 1).?);
}

test "LOD cache round-trip preserves span-less column provenance" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod3);
    defer data.deinit();

    data.setColumnProvenance(2, 3, .chunk_derived);
    data.setColumnProvenance(4, 5, .edited);

    const key = Key{ .seed = 1234, .generator_identity_hash = 99, .generator_version = 7, .rx = -2, .rz = 3, .lod = .lod3 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try deserialize(bytes, key, testing.allocator);
    defer decoded.deinit();

    try testing.expectEqual(ColumnProvenance.chunk_derived, decoded.getColumnProvenance(2, 3));
    try testing.expectEqual(ColumnProvenance.edited, decoded.getColumnProvenance(4, 5));
    try testing.expectEqual(ColumnProvenance.worldgen, decoded.getColumnProvenance(0, 0));
}

test "LOD cache rejects legacy span-less payload without provenance" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer data.deinit();
    data.setColumn(1, 1, 91.0, .mountains, .{ .surface = .stone, .subsurface = .dirt, .foundation = .stone }, 0xFF445566, .empty, .daylight, .empty);

    const key = Key{ .seed = 4, .generator_identity_hash = 5, .generator_version = 6, .rx = -1, .rz = -2, .lod = .lod2 };
    const v2_bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(v2_bytes);
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    const v1_size = HEADER_SIZE + payloadSize(count);
    const v1_bytes = try testing.allocator.dupe(u8, v2_bytes[0..v1_size]);
    defer testing.allocator.free(v1_bytes);
    v1_bytes[4] = CACHE_VERSION_V1;
    std.mem.writeInt(u32, v1_bytes[6..][0..4], 0, .little);
    std.mem.writeInt(u32, v1_bytes[6..][0..4], computeCrc(v1_bytes), .little);

    try testing.expectError(CacheError.MissingProvenance, deserialize(v1_bytes, key, testing.allocator));
}

test "LOD cache rejects v10 span-less payload without provenance" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod3);
    defer data.deinit();

    const key = Key{ .seed = 4, .generator_identity_hash = 5, .generator_version = 6, .rx = 1, .rz = -2, .lod = .lod3 };
    const current_bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(current_bytes);
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    const legacy_size = current_bytes.len - count;
    const legacy_bytes = try testing.allocator.alloc(u8, legacy_size);
    defer testing.allocator.free(legacy_bytes);
    const provenance_offset = HEADER_SIZE + payloadSize(count) + SPAN_FLAGS_WIRE_SIZE;
    @memcpy(legacy_bytes[0..provenance_offset], current_bytes[0..provenance_offset]);
    legacy_bytes[4] = CACHE_VERSION_V10;
    std.mem.writeInt(u32, legacy_bytes[6..][0..4], 0, .little);
    std.mem.writeInt(u32, legacy_bytes[6..][0..4], computeCrc(legacy_bytes), .little);

    try testing.expectError(CacheError.MissingProvenance, deserialize(legacy_bytes, key, testing.allocator));
}

test "LOD cache rejects checksum mismatch" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0x01;

    try testing.expectError(CacheError.ChecksumMismatch, deserialize(bytes, key, testing.allocator));
}

test "LOD cache reports invalid provenance" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod2 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    const provenance_offset = HEADER_SIZE + payloadSize(count) + SPAN_FLAGS_WIRE_SIZE;
    bytes[provenance_offset] = 3;
    std.mem.writeInt(u32, bytes[6..][0..4], 0, .little);
    std.mem.writeInt(u32, bytes[6..][0..4], computeCrc(bytes), .little);

    try testing.expectError(CacheError.InvalidProvenance, deserialize(bytes, key, testing.allocator));
}

test "LOD cache rejects mismatched cache key" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    const wrong_key = Key{ .seed = 1, .generator_identity_hash = 3, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    try testing.expectError(CacheError.InvalidKey, deserialize(bytes, wrong_key, testing.allocator));
}

test "LOD cache checksum covers key header fields" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    bytes[10] ^= 0x01;
    try testing.expectError(CacheError.ChecksumMismatch, deserialize(bytes, key, testing.allocator));
}

test "LOD cache payload size follows named wire fields" {
    try testing.expectEqual(@as(usize, 50), payloadSize(1));
    try testing.expectEqual(@as(usize, HEADER_SIZE + 50 * 4), HEADER_SIZE + payloadSize(4));

    var data = try LODSimplifiedData.init(testing.allocator, .lod0);
    defer data.deinit();
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    try testing.expectEqual(HEADER_SIZE + payloadSize(count) + SPAN_FLAGS_WIRE_SIZE + count, serializedSize(&data));
}
