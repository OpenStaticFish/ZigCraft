//! Chunk serialization/deserialization for persistence.
//!
//! Converts between in-memory `Chunk` structs and a compact binary format
//! suitable for storage in region files (`region_file.zig`).
//!
//! Wire format (version 3, little-endian):
//!   [Header: 18 bytes]
//!     magic:       u32  = 0x5A434B00 ("ZCK\0")
//!     version:     u8   = 3
//!     flags:       u8   (has_light | has_biome_data | has_heightmap)
//!     crc32:       u32  (over all data after header)
//!     chunk_x:     i32
//!     chunk_z:     i32
//!
//!   [BlockData: 65536 bytes] (always present)
//!     BlockType as u8, flat array matching Chunk.blocks layout
//!
//!   [LightData: 131072 bytes] (if has_light flag set)
//!     PackedLight raw bytes, flat array
//!
//!   [BiomeData: 256 bytes] (if has_biome_data flag set)
//!     BiomeId as u8, flat array (16x16 columns)
//!
//!   [HeightMap: 512 bytes] (if has_heightmap flag set)
//!     i16 LE values, flat array (16x16 columns)
//!
//! Thread safety: All functions are pure and thread-safe given immutable input.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("fs");

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const PackedLight = world_core.PackedLight;
const CHUNK_VOLUME = world_core.CHUNK_VOLUME;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

pub const CHUNK_MAGIC: u32 = 0x5A434B00;
pub const CHUNK_DATA_VERSION: u8 = 3;
pub const BIOME_COUNT: usize = @typeInfo(BiomeId).@"enum".fields.len;

pub const HeaderFlags = packed struct(u8) {
    has_light: bool = false,
    has_biome_data: bool = false,
    has_heightmap: bool = false,
    lighting_current: bool = false,
    _reserved: u4 = 0,
};

pub const HEADER_SIZE: usize = 18;

pub const SerializeError = error{
    InvalidMagic,
    UnsupportedVersion,
    DataTooShort,
    InvalidBiomeData,
    ChecksumMismatch,
    CoordinateMismatch,
};

const BlockDataSize = CHUNK_VOLUME;
const LightDataSize = CHUNK_VOLUME * @sizeOf(PackedLight);
const BiomeDataSize = CHUNK_SIZE_X * CHUNK_SIZE_Z;
const HeightmapDataSize = (CHUNK_SIZE_X * CHUNK_SIZE_Z) * @sizeOf(i16);

pub fn computeFlags(chunk: *const Chunk) HeaderFlags {
    var flags = HeaderFlags{ .has_biome_data = true, .has_heightmap = true, .lighting_current = chunk.lighting_valid };

    const light_bytes = std.mem.sliceAsBytes(&chunk.light);
    for (light_bytes) |b| {
        if (b != 0) {
            flags.has_light = true;
            break;
        }
    }

    return flags;
}

pub fn serializedSize(chunk: *const Chunk) usize {
    return dataPayloadSize(computeFlags(chunk)) + HEADER_SIZE;
}

fn dataPayloadSize(flags: HeaderFlags) usize {
    var size: usize = BlockDataSize;
    if (flags.has_light) size += LightDataSize;
    if (flags.has_biome_data) size += BiomeDataSize;
    if (flags.has_heightmap) size += HeightmapDataSize;
    return size;
}

fn isValidBiome(byte: u8) bool {
    return byte < BIOME_COUNT;
}

pub fn serializeChunk(chunk: *const Chunk, allocator: Allocator) ![]u8 {
    const flags = computeFlags(chunk);
    const payload_size = dataPayloadSize(flags);
    const total_size = HEADER_SIZE + payload_size;

    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var off: usize = 0;

    std.mem.writeInt(u32, buf[off..][0..4], CHUNK_MAGIC, .little);
    off += 4;
    buf[off] = CHUNK_DATA_VERSION;
    off += 1;
    buf[off] = @bitCast(flags);
    off += 1;
    std.mem.writeInt(u32, buf[off..][0..4], 0, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], chunk.chunk_x, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], chunk.chunk_z, .little);
    off += 4;

    @memcpy(buf[off..][0..BlockDataSize], std.mem.sliceAsBytes(&chunk.blocks));
    off += BlockDataSize;

    if (flags.has_light) {
        @memcpy(buf[off..][0..LightDataSize], std.mem.sliceAsBytes(&chunk.light));
        off += LightDataSize;
    }

    if (flags.has_biome_data) {
        @memcpy(buf[off..][0..BiomeDataSize], std.mem.sliceAsBytes(&chunk.biomes));
        off += BiomeDataSize;
    }

    if (flags.has_heightmap) {
        @memcpy(buf[off..][0..HeightmapDataSize], std.mem.sliceAsBytes(&chunk.heightmap));
        off += HeightmapDataSize;
    }

    std.debug.assert(off == total_size);

    const crc = std.hash.Crc32.hash(buf[HEADER_SIZE..]);
    std.mem.writeInt(u32, buf[6..][0..4], crc, .little);

    return buf;
}

/// Transactional saved-source decode. Only persisted fields are published, so
/// caller-owned pins, revisions, and residency state are not overwritten.
pub fn deserializeChunkAt(data: []const u8, cx: i32, cz: i32, chunk: *Chunk) !void {
    var scratch = Chunk.init(cx, cz);
    try deserializeChunk(data, &scratch);
    if (scratch.chunk_x != cx or scratch.chunk_z != cz) return SerializeError.CoordinateMismatch;

    chunk.chunk_x = scratch.chunk_x;
    chunk.chunk_z = scratch.chunk_z;
    chunk.blocks = scratch.blocks;
    chunk.light = scratch.light;
    chunk.biomes = scratch.biomes;
    chunk.heightmap = scratch.heightmap;
    chunk.lighting_valid = scratch.lighting_valid;
    chunk.dirty = scratch.dirty;
}

pub fn deserializeChunk(data: []const u8, chunk: *Chunk) !void {
    if (data.len < HEADER_SIZE) return SerializeError.DataTooShort;

    var off: usize = 0;

    const magic = std.mem.readInt(u32, data[off..][0..4], .little);
    off += 4;
    if (magic != CHUNK_MAGIC) return SerializeError.InvalidMagic;

    const version = data[off];
    off += 1;
    if (version != 2 and version != CHUNK_DATA_VERSION) return SerializeError.UnsupportedVersion;

    const flags_byte = data[off];
    off += 1;
    const flags: HeaderFlags = @bitCast(flags_byte);

    const stored_crc = std.mem.readInt(u32, data[off..][0..4], .little);
    off += 4;

    chunk.chunk_x = std.mem.readInt(i32, data[off..][0..4], .little);
    off += 4;
    chunk.chunk_z = std.mem.readInt(i32, data[off..][0..4], .little);
    off += 4;

    const expected: usize = HEADER_SIZE + dataPayloadSize(flags);
    if (data.len < expected) return SerializeError.DataTooShort;

    const computed_crc = std.hash.Crc32.hash(data[HEADER_SIZE..]);
    if (stored_crc != computed_crc) return SerializeError.ChecksumMismatch;

    @memcpy(std.mem.sliceAsBytes(&chunk.blocks), data[off..][0..BlockDataSize]);
    off += BlockDataSize;

    if (flags.has_light) {
        @memcpy(std.mem.sliceAsBytes(&chunk.light), data[off..][0..LightDataSize]);
        off += LightDataSize;
    } else {
        @memset(std.mem.sliceAsBytes(&chunk.light), 0);
    }

    if (flags.has_biome_data) {
        const biome_slice = data[off..][0..BiomeDataSize];
        for (biome_slice, 0..) |byte, i| {
            if (!isValidBiome(byte)) return SerializeError.InvalidBiomeData;
            chunk.biomes[i] = std.enums.fromInt(BiomeId, byte) orelse
                return SerializeError.InvalidBiomeData;
        }
        off += BiomeDataSize;
    } else {
        @memset(&chunk.biomes, .plains);
    }

    if (flags.has_heightmap) {
        @memcpy(std.mem.sliceAsBytes(&chunk.heightmap), data[off..][0..HeightmapDataSize]);
        off += HeightmapDataSize;
    } else {
        @memset(&chunk.heightmap, 0);
    }

    chunk.lighting_valid = version >= 3 and flags.lighting_current;
    chunk.dirty = true;
}

const testing = std.testing;

test "serialize/deserialize round-trip preserves blocks" {
    var chunk = Chunk.init(5, -3);
    chunk.setBlock(0, 0, 0, .bedrock);
    chunk.setBlock(5, 64, 10, .stone);
    chunk.setBlock(8, 128, 8, .glowstone);
    chunk.setBlock(15, 255, 15, .gold_ore);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqual(@as(i32, 5), result.chunk_x);
    try testing.expectEqual(@as(i32, -3), result.chunk_z);
    try testing.expectEqualSlices(BlockType, &chunk.blocks, &result.blocks);
}

test "serialize/deserialize round-trip preserves light data" {
    var chunk = Chunk.init(0, 0);
    chunk.setSkyLight(5, 64, 10, 15);
    chunk.setBlockLight(5, 64, 10, 8);
    chunk.setBlock(5, 64, 10, .glowstone);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqual(@as(u4, 15), result.getSkyLight(5, 64, 10));
    try testing.expectEqual(@as(u4, 8), result.getBlockLight(5, 64, 10));
}

test "serialize/deserialize round-trip preserves RGB light" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlockLightRGB(3, 50, 7, 4, 8, 12);
    chunk.setBlock(3, 50, 7, .glowstone);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    const light = result.getLight(3, 50, 7);
    try testing.expectEqual(@as(u4, 4), light.getBlockLightR());
    try testing.expectEqual(@as(u4, 8), light.getBlockLightG());
    try testing.expectEqual(@as(u4, 12), light.getBlockLightB());
}

test "serialize/deserialize round-trip preserves biome data" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(0, 0, .desert);
    chunk.setBiome(8, 8, .mountains);
    chunk.setBiome(15, 15, .ocean);
    chunk.setBiome(3, 12, .jungle);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqual(BiomeId.desert, result.getBiome(0, 0));
    try testing.expectEqual(BiomeId.mountains, result.getBiome(8, 8));
    try testing.expectEqual(BiomeId.ocean, result.getBiome(15, 15));
    try testing.expectEqual(BiomeId.jungle, result.getBiome(3, 12));
    try testing.expectEqualSlices(BiomeId, &chunk.biomes, &result.biomes);
}

test "serialize/deserialize round-trip preserves heightmap" {
    var chunk = Chunk.init(0, 0);
    chunk.setSurfaceHeight(0, 0, 64);
    chunk.setSurfaceHeight(8, 8, 128);
    chunk.setSurfaceHeight(15, 15, -1);
    chunk.setSurfaceHeight(7, 3, 255);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqual(@as(i16, 64), result.getSurfaceHeight(0, 0));
    try testing.expectEqual(@as(i16, 128), result.getSurfaceHeight(8, 8));
    try testing.expectEqual(@as(i16, -1), result.getSurfaceHeight(15, 15));
    try testing.expectEqual(@as(i16, 255), result.getSurfaceHeight(7, 3));
}

test "empty chunk serializes without light data" {
    var chunk = Chunk.init(0, 0);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    const min_size = HEADER_SIZE + BlockDataSize + BiomeDataSize + HeightmapDataSize;
    try testing.expectEqual(min_size, data.len);

    const flags_byte = data[5];
    const flags: HeaderFlags = @bitCast(flags_byte);
    try testing.expect(!flags.has_light);
    try testing.expect(flags.has_biome_data);
    try testing.expect(flags.has_heightmap);
}

test "chunk with light includes light section" {
    var chunk = Chunk.init(0, 0);
    chunk.setSkyLight(0, 0, 0, 15);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    const expected = HEADER_SIZE + BlockDataSize + LightDataSize + BiomeDataSize + HeightmapDataSize;
    try testing.expectEqual(expected, data.len);

    const flags_byte = data[5];
    const flags: HeaderFlags = @bitCast(flags_byte);
    try testing.expect(flags.has_light);
}

test "full chunk (all stone) round-trip" {
    var chunk = Chunk.init(10, -20);
    chunk.fill(.stone);
    chunk.setSkyLight(0, 200, 0, 15);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqual(@as(i32, 10), result.chunk_x);
    try testing.expectEqual(@as(i32, -20), result.chunk_z);
    for (&result.blocks) |block| {
        try testing.expectEqual(BlockType.stone, block);
    }
}

test "flat terrain round-trip" {
    var chunk = Chunk.init(7, 3);
    chunk.generateFlat(64);
    chunk.updateSkylightColumn(0, 0);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(data, &result);

    try testing.expectEqualSlices(BlockType, &chunk.blocks, &result.blocks);
    try testing.expectEqualSlices(BiomeId, &chunk.biomes, &result.biomes);
}

test "corrupt magic returns error" {
    var buf: [HEADER_SIZE]u8 = @splat(0xFF);
    var chunk = Chunk.init(0, 0);
    const result = deserializeChunk(&buf, &chunk);
    try testing.expectError(SerializeError.InvalidMagic, result);
}

test "unknown version returns error" {
    var buf: [HEADER_SIZE]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], CHUNK_MAGIC, .little);
    buf[4] = 99;

    var chunk = Chunk.init(0, 0);
    const result = deserializeChunk(&buf, &chunk);
    try testing.expectError(SerializeError.UnsupportedVersion, result);
}

test "truncated data returns DataTooShort" {
    var chunk_src = Chunk.init(0, 0);
    chunk_src.setBlock(5, 64, 10, .stone);

    const data = try serializeChunk(&chunk_src, testing.allocator);
    defer testing.allocator.free(data);

    var chunk = Chunk.init(0, 0);
    const result = deserializeChunk(data[0 .. HEADER_SIZE + 10], &chunk);
    try testing.expectError(SerializeError.DataTooShort, result);
}

test "data shorter than header returns DataTooShort" {
    var buf: [8]u8 = @splat(0);
    var chunk = Chunk.init(0, 0);
    const result = deserializeChunk(&buf, &chunk);
    try testing.expectError(SerializeError.DataTooShort, result);
}

test "invalid biome byte returns InvalidBiomeData" {
    var chunk = Chunk.init(0, 0);
    chunk.setSkyLight(0, 0, 0, 1);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    const flags_byte = data[5];
    const flags: HeaderFlags = @bitCast(flags_byte);
    var biome_off: usize = HEADER_SIZE + BlockDataSize;
    if (flags.has_light) biome_off += LightDataSize;
    data[biome_off] = 255;

    std.mem.writeInt(u32, data[6..][0..4], std.hash.Crc32.hash(data[HEADER_SIZE..]), .little);

    var result = Chunk.init(0, 0);
    const res = deserializeChunk(data, &result);
    try testing.expectError(SerializeError.InvalidBiomeData, res);
}

test "serializedSize matches actual output" {
    var chunk = Chunk.init(0, 0);
    const expected = serializedSize(&chunk);
    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqual(expected, data.len);
}

test "serializedSize matches with light data" {
    var chunk = Chunk.init(0, 0);
    chunk.setSkyLight(0, 0, 0, 15);
    const expected = serializedSize(&chunk);
    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqual(expected, data.len);
}

test "magic bytes spell ZCK\\0" {
    try testing.expectEqual(@as(u32, 0x5A434B00), CHUNK_MAGIC);
    const bytes: [4]u8 = .{ 0x00, 0x4B, 0x43, 0x5A };
    try testing.expectEqual(CHUNK_MAGIC, std.mem.readInt(u32, &bytes, .little));
}

test "deserialize without light defaults to zero light" {
    var chunk = Chunk.init(0, 0);
    chunk.setSkyLight(5, 5, 5, 15);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    var flags: HeaderFlags = @bitCast(data[5]);
    flags.has_light = false;
    data[5] = @bitCast(flags);

    var trunc = try testing.allocator.alloc(u8, data.len - LightDataSize);
    defer testing.allocator.free(trunc);

    const header_copy = HEADER_SIZE + BlockDataSize;
    @memcpy(trunc[0..header_copy], data[0..header_copy]);
    const src_off = header_copy + LightDataSize;

    const remaining = data.len - src_off;
    @memcpy(trunc[header_copy..][0..remaining], data[src_off..][0..remaining]);

    std.mem.writeInt(u32, trunc[6..][0..4], std.hash.Crc32.hash(trunc[HEADER_SIZE..]), .little);

    var result = Chunk.init(0, 0);
    try deserializeChunk(trunc, &result);

    try testing.expectEqual(@as(u4, 0), result.getSkyLight(5, 5, 5));
}

test "integration: serialize to region file and back" {
    const RegionFile = @import("region_file.zig").RegionFile;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    const path = "test_chunk_serdes.mca";
    const file = try dir.createFile(path, .{ .read = true, .truncate = true });
    file.close();

    var full_path_buf: [fs.max_path_bytes]u8 = undefined;
    const full_path = try dir.realpath(path, &full_path_buf);

    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBiome(4, 4, .forest);
    chunk.setSkyLight(8, 100, 8, 15);
    chunk.setSurfaceHeight(4, 4, 64);

    const serialized = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(serialized);

    var region = try RegionFile.create(testing.allocator, full_path);
    defer region.close();

    try region.writeChunk(0, 0, serialized);

    const read_data = try region.readChunk(0, 0, testing.allocator);
    defer testing.allocator.free(read_data);

    var result = Chunk.init(0, 0);
    try deserializeChunk(read_data, &result);

    try testing.expectEqualSlices(BlockType, &chunk.blocks, &result.blocks);
    try testing.expectEqual(BiomeId.forest, result.getBiome(4, 4));
    try testing.expectEqual(@as(u4, 15), result.getSkyLight(8, 100, 8));
    try testing.expectEqual(@as(i16, 64), result.getSurfaceHeight(4, 4));
}

test "corrupt payload returns ChecksumMismatch" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(5, 64, 10, .stone);

    const data = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data);

    data[HEADER_SIZE + 100] +%= 1;

    var result = Chunk.init(0, 0);
    const res = deserializeChunk(data, &result);
    try testing.expectError(SerializeError.ChecksumMismatch, res);
}

test "CRC32 is deterministic for same chunk" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(3, 50, 7, .dirt);

    const data1 = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data1);
    const data2 = try serializeChunk(&chunk, testing.allocator);
    defer testing.allocator.free(data2);

    const crc1 = std.mem.readInt(u32, data1[6..][0..4], .little);
    const crc2 = std.mem.readInt(u32, data2[6..][0..4], .little);
    try testing.expectEqual(crc1, crc2);
}
