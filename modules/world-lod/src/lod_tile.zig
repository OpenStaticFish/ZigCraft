//! CPU-owned compact source data for far-terrain tiles.
//!
//! `CompactLODSample` is a fixed 16-byte, little-endian ABI.  It deliberately
//! contains semantic `world_core.BlockType` IDs, not atlas or GPU resource IDs,
//! so it can be built, cached, and tested without a renderer.  The two 64-bit
//! words have this bit layout (least-significant bit first):
//!
//! ```text
//! bits  0..15  terrain height: signed i16, 1/8 block, [-4096, 4095.875]
//! bits 16..31  water height: signed i16, 1/8 block, [-4095.875, 4095.875];
//!              -4096 is the no-water sentinel
//! bits 32..39  water depth: unsigned u8, 1/4 block, [0, 63.75]
//! bits 40..47  water coverage: unsigned u8, [0, 1]
//! bits 48..54  surface material semantic ID
//! bits 55..61  subsurface material semantic ID
//! bits 62..68  foundation material semantic ID
//! bits 69..92  RGB color (low 24 bits of source color)
//! bits 93..96  sky light, [0, 15]
//! bits 97..100 block light, [0, 15]
//! bits 101..106 ambient occlusion, unsigned u6, [0, 1]
//! bits 107..112 vegetation coverage, unsigned u6, [0, 1]
//! bits 113..120 vegetation height, unsigned u8, 1/2 block, [0, 127.5]
//! bits 121..122 provenance (worldgen/chunk-derived/edited)
//! bits 123..127 reserved, zero
//! ```
//!
//! All float quantizers first map non-finite input to zero, clamp to their
//! documented range, then use `@round` (nearest integer). Version 1 recognizes
//! block IDs through `stone_stairs`; later or out-of-range IDs are reduced to
//! the semantic `stone` fallback rather than becoming renderer-specific data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const world_core = @import("world-core");

const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const BlockType = world_core.BlockType;
const LODMaterialLayers = world_core.LODMaterialLayers;
const LODWaterState = world_core.LODWaterState;
const LODLightingHint = world_core.LODLightingHint;
const LODVegetationHint = world_core.LODVegetationHint;
const LODColumnProvenance = world_core.LODColumnProvenance;

pub const COMPACT_LOD_TILE_MAGIC: u32 = 0x5444_4C43; // "CLDT" in little-endian bytes.
pub const COMPACT_LOD_TILE_VERSION: u16 = 1;
pub const COMPACT_LOD_SAMPLE_BYTES: usize = 16;
pub const COMPACT_LOD_TILE_HEADER_BYTES: usize = 20;
const WATER_HEIGHT_NONE: i16 = std.math.minInt(i16);
const HEIGHT_SCALE: f32 = 8.0;
const DEPTH_SCALE: f32 = 4.0;
const VEGETATION_HEIGHT_SCALE: f32 = 2.0;
const MAX_ENCODED_BLOCK_ID: u8 = 0x7f;
const MAX_KNOWN_BLOCK_ID: u8 = @intFromEnum(BlockType.stone_stairs);
const MAX_VALID_WIRE_BLOCK_ID: u7 = @intCast(@min(MAX_ENCODED_BLOCK_ID, MAX_KNOWN_BLOCK_ID));

pub const TileEdge = enum(u2) {
    north = 0,
    east = 1,
    south = 2,
    west = 3,
};

/// All currently defined `TileEdge` bits. This is kept separate from the
/// serialized version so a future edge/encoding extension cannot silently turn
/// an unknown bit into a seamless edge.
pub const TILE_EDGE_MASK: u8 = 0x0f;

pub fn edgeMask(edge: TileEdge) u8 {
    return @as(u8, 1) << @intFromEnum(edge);
}

pub const TileError = error{
    InvalidLod,
    InvalidSourceData,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    DataTooShort,
    InvalidLength,
    ChecksumMismatch,
    InvalidSample,
    UnsupportedSourceFeatures,
};

/// A renderer-independent compact sample. `bytes` is the stable wire/upload ABI.
pub const CompactLODSample = struct {
    bytes: [COMPACT_LOD_SAMPLE_BYTES]u8,

    pub fn decode(self: CompactLODSample) DecodedSample {
        const low = std.mem.readInt(u64, self.bytes[0..8], .little);
        const high = std.mem.readInt(u64, self.bytes[8..16], .little);
        const bits = @as(u128, low) | (@as(u128, high) << 64);

        const water_raw = signedField(bits, 16);
        const water_present = water_raw != WATER_HEIGHT_NONE;
        return .{
            .terrain_height = dequantizeHeight(signedField(bits, 0)),
            .water = .{
                .is_surface = water_present,
                .surface_height = if (water_present) dequantizeHeight(water_raw) else 0.0,
                .depth = @as(f32, @floatFromInt(unsignedField(bits, 32, u8))) / DEPTH_SCALE,
                .coverage = @as(f32, @floatFromInt(unsignedField(bits, 40, u8))) / 255.0,
            },
            .material_layers = .{
                .surface = semanticMaterialFromId(unsignedField(bits, 48, u7)),
                .subsurface = semanticMaterialFromId(unsignedField(bits, 55, u7)),
                .foundation = semanticMaterialFromId(unsignedField(bits, 62, u7)),
            },
            .color = unsignedField(bits, 69, u32) & 0x00ff_ffff,
            .lighting = .{
                .sky_light = unsignedField(bits, 93, u8) & 0x0f,
                .block_light = unsignedField(bits, 97, u8) & 0x0f,
                .ambient_occlusion = @as(f32, @floatFromInt(unsignedField(bits, 101, u8) & 0x3f)) / 63.0,
            },
            .vegetation = .{
                .tree_coverage = @as(f32, @floatFromInt(unsignedField(bits, 107, u8) & 0x3f)) / 63.0,
                .avg_tree_height = @as(f32, @floatFromInt(unsignedField(bits, 113, u8) & 0xff)) / VEGETATION_HEIGHT_SCALE,
                .offset_x = 0.0,
                .offset_z = 0.0,
                .trunk = .air,
                .leaves = .air,
            },
            .provenance = provenanceFromBits(unsignedField(bits, 121, u8)),
        };
    }

    fn isValid(self: CompactLODSample) bool {
        const low = std.mem.readInt(u64, self.bytes[0..8], .little);
        const high = std.mem.readInt(u64, self.bytes[8..16], .little);
        const bits = @as(u128, low) | (@as(u128, high) << 64);
        if ((high >> 59) != 0) return false;
        if (((high >> 57) & 0x3) > @intFromEnum(LODColumnProvenance.edited)) return false;
        return unsignedField(bits, 48, u7) <= MAX_VALID_WIRE_BLOCK_ID and
            unsignedField(bits, 55, u7) <= MAX_VALID_WIRE_BLOCK_ID and
            unsignedField(bits, 62, u7) <= MAX_VALID_WIRE_BLOCK_ID;
    }
};

comptime {
    std.debug.assert(@sizeOf(CompactLODSample) == COMPACT_LOD_SAMPLE_BYTES);
    std.debug.assert(@alignOf(CompactLODSample) == 1);
}

/// The lossily reconstructed source-column attributes represented by a sample.
pub const DecodedSample = struct {
    terrain_height: f32,
    water: LODWaterState,
    material_layers: LODMaterialLayers,
    color: u32,
    lighting: LODLightingHint,
    vegetation: LODVegetationHint,
    provenance: LODColumnProvenance,
};

pub const ByteMetrics = struct {
    /// Bytes that would be uploaded for the compact padded sample grid.
    compact_upload_bytes: usize,
    /// Bytes emitted by the current CPU heightfield path for top faces alone.
    conservative_expanded_top_grid_bytes: usize,

    pub fn savedBytes(self: ByteMetrics) usize {
        return if (self.conservative_expanded_top_grid_bytes > self.compact_upload_bytes)
            self.conservative_expanded_top_grid_bytes - self.compact_upload_bytes
        else
            0;
    }
};

/// An allocator-owned top-grid plus one duplicated source edge on every side.
/// `sampleClamped` accepts `-1..width` neighbor coordinates and is stable at a
/// tile boundary, making it suitable for CPU normal derivation before neighbors
/// are available.
pub const CompactLODTile = struct {
    allocator: Allocator,
    lod_level: LODLevel,
    width: u32,
    /// Bit per `TileEdge` whose apron was populated from a same-level neighbor.
    neighbor_apron_mask: u8 = 0,
    samples: []CompactLODSample,

    pub const Support = enum { supported, invalid_lod, invalid_source, canonical_scene, vertical_spans, vegetation_topology, water_topology };

    pub fn support(source: *const LODSimplifiedData, lod_level: LODLevel) Support {
        // V1's heightfield cannot reproduce canonical occupancy, strata,
        // per-span RGB light, or partial footprints. Preserve the source and
        // select expanded topology, regardless of descriptor qualification.
        if (source.scene_grid != null) return .canonical_scene;
        if (lod_level != .lod3 and lod_level != .lod4) return .invalid_lod;
        if (!LODSimplifiedData.isSupportedGridSize(lod_level, source.width)) return .invalid_source;
        if (hasUnsupportedVerticalSpans(source)) return .vertical_spans;
        // Encoding a vegetation hint does not render it: V1 emits only the
        // terrain/water grid. Forests need expanded geometry even without spans.
        for (source.vegetation) |vegetation| {
            if (vegetation.tree_coverage > 0) return .vegetation_topology;
        }
        if (hasUnsupportedWaterTopology(source)) return .water_topology;
        return .supported;
    }

    pub fn initFromSimplified(allocator: Allocator, lod_level: LODLevel, source: *const LODSimplifiedData) !CompactLODTile {
        switch (support(source, lod_level)) {
            .supported => {},
            .invalid_lod => return TileError.InvalidLod,
            .invalid_source => return TileError.InvalidSourceData,
            .canonical_scene, .vertical_spans, .vegetation_topology, .water_topology => return TileError.UnsupportedSourceFeatures,
        }
        const source_count = squareCount(source.width) orelse return TileError.InvalidSourceData;
        if (source.heightmap.len != source_count or
            source.biomes.len != source_count or
            source.top_blocks.len != source_count or
            source.colors.len != source_count or
            source.material_layers.len != source_count or
            source.water.len != source_count or
            source.lighting.len != source_count or
            source.vegetation.len != source_count or
            source.provenance.len != source_count)
        {
            return TileError.InvalidSourceData;
        }

        const padded_stride = apronStride(source.width) orelse return TileError.InvalidSourceData;
        const sample_count = squareCount(padded_stride) orelse return TileError.InvalidSourceData;
        const samples = try allocator.alloc(CompactLODSample, sample_count);
        errdefer allocator.free(samples);

        var apron_z: u32 = 0;
        while (apron_z < padded_stride) : (apron_z += 1) {
            const source_z = apronToSourceCoordinate(apron_z, source.width);
            var apron_x: u32 = 0;
            while (apron_x < padded_stride) : (apron_x += 1) {
                const source_x = apronToSourceCoordinate(apron_x, source.width);
                const index = @as(usize, source_z) * @as(usize, source.width) + @as(usize, source_x);
                samples[@as(usize, apron_z) * @as(usize, padded_stride) + @as(usize, apron_x)] = packSourceColumn(source, index);
            }
        }

        return .{
            .allocator = allocator,
            .lod_level = lod_level,
            .width = source.width,
            .neighbor_apron_mask = 0,
            .samples = samples,
        };
    }

    pub fn deinit(self: *CompactLODTile) void {
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn stride(self: *const CompactLODTile) u32 {
        return self.width + 2;
    }

    /// Returns an interior top-grid sample, excluding the duplicated-edge apron.
    pub fn sample(self: *const CompactLODTile, x: u32, z: u32) ?CompactLODSample {
        if (x >= self.width or z >= self.width) return null;
        const stride_value = self.stride();
        return self.samples[@as(usize, z + 1) * @as(usize, stride_value) + @as(usize, x + 1)];
    }

    /// Returns the padded sample at a raw apron coordinate (`0..width + 1`).
    pub fn sampleApron(self: *const CompactLODTile, x: u32, z: u32) ?CompactLODSample {
        const stride_value = self.stride();
        if (x >= stride_value or z >= stride_value) return null;
        return self.samples[@as(usize, z) * @as(usize, stride_value) + @as(usize, x)];
    }

    /// Returns an interior or immediate neighbor sample from the apron. Inputs
    /// outside `-1..width` are clamped to that supported normal-sampling range.
    pub fn sampleClamped(self: *const CompactLODTile, x: i32, z: i32) CompactLODSample {
        const max_coordinate: i32 = @intCast(self.width);
        const apron_x: u32 = @intCast(std.math.clamp(x, @as(i32, -1), max_coordinate) + 1);
        const apron_z: u32 = @intCast(std.math.clamp(z, @as(i32, -1), max_coordinate) + 1);
        return self.sampleApron(apron_x, apron_z).?;
    }

    /// Replaces one duplicated fallback apron with authoritative samples from
    /// the adjacent same-level tile. Region grids include both endpoints, so
    /// the shared boundary is neighbor coordinate 0/width-1 and the apron must
    /// copy the first sample beyond it (1/width-2).
    pub fn applyNeighborApron(self: *CompactLODTile, edge: TileEdge, neighbor: *const CompactLODTile) !void {
        if (self.lod_level != neighbor.lod_level or self.width != neighbor.width) return TileError.InvalidSourceData;
        const stride_value = self.stride();
        const stride_usize: usize = stride_value;
        var coordinate: u32 = 0;
        while (coordinate < self.width) : (coordinate += 1) {
            const destination = switch (edge) {
                .north => @as(usize, coordinate + 1),
                .east => @as(usize, coordinate + 1) * stride_usize + @as(usize, stride_value - 1),
                .south => @as(usize, stride_value - 1) * stride_usize + @as(usize, coordinate + 1),
                .west => @as(usize, coordinate + 1) * stride_usize,
            };
            const source_sample = switch (edge) {
                .north => neighbor.sample(coordinate, neighbor.width - 2).?,
                .east => neighbor.sample(1, coordinate).?,
                .south => neighbor.sample(coordinate, 1).?,
                .west => neighbor.sample(neighbor.width - 2, coordinate).?,
            };
            self.samples[destination] = source_sample;
        }
        self.neighbor_apron_mask |= @as(u8, 1) << @intFromEnum(edge);
    }

    pub fn hasNeighborApron(self: *const CompactLODTile, edge: TileEdge) bool {
        return (self.neighbor_apron_mask & edgeMask(edge)) != 0;
    }

    /// Only an edge copied from a same-level neighbor is seamless. A duplicated
    /// local edge is valid compact data, but it is deliberately *not* a seam
    /// claim: the renderer must retain that edge's skirt and use its normal
    /// fallback until an authoritative apron was available before upload.
    pub fn skirtMask(self: *const CompactLODTile) u8 {
        return (~self.neighbor_apron_mask) & TILE_EDGE_MASK;
    }

    /// Compares compact bytes with the current CPU top-face expansion using an
    /// explicit vertex size supplied by the renderer-facing caller.
    pub fn byteMetrics(self: *const CompactLODTile, expanded_vertex_bytes: usize) ByteMetrics {
        const cells = @as(usize, self.width - 1) * @as(usize, self.width - 1);
        return .{
            .compact_upload_bytes = self.samples.len * COMPACT_LOD_SAMPLE_BYTES,
            // The current path emits two triangles (six Vertex values)
            // per cell before side faces, water, or vegetation are considered.
            .conservative_expanded_top_grid_bytes = cells * 6 * expanded_vertex_bytes,
        };
    }

    pub fn serializedSize(self: *const CompactLODTile) usize {
        return COMPACT_LOD_TILE_HEADER_BYTES + self.samples.len * COMPACT_LOD_SAMPLE_BYTES;
    }

    /// Serializes the versioned little-endian tile format. The returned buffer is caller-owned.
    pub fn serialize(self: *const CompactLODTile, allocator: Allocator) ![]u8 {
        const bytes = try allocator.alloc(u8, self.serializedSize());
        errdefer allocator.free(bytes);

        std.mem.writeInt(u32, bytes[0..4], COMPACT_LOD_TILE_MAGIC, .little);
        std.mem.writeInt(u16, bytes[4..6], COMPACT_LOD_TILE_VERSION, .little);
        bytes[6] = @intFromEnum(self.lod_level);
        bytes[7] = self.neighbor_apron_mask;
        std.mem.writeInt(u32, bytes[8..12], self.width, .little);
        std.mem.writeInt(u32, bytes[12..16], @intCast(self.samples.len), .little);
        std.mem.writeInt(u32, bytes[16..20], 0, .little);
        @memcpy(bytes[COMPACT_LOD_TILE_HEADER_BYTES..], std.mem.sliceAsBytes(self.samples));
        std.mem.writeInt(u32, bytes[16..20], computeTileCrc(bytes), .little);
        return bytes;
    }

    /// Deserializes only a complete, validated current-version tile. The result owns its samples.
    pub fn deserialize(allocator: Allocator, bytes: []const u8) !CompactLODTile {
        if (bytes.len < COMPACT_LOD_TILE_HEADER_BYTES) return TileError.DataTooShort;
        if (std.mem.readInt(u32, bytes[0..4], .little) != COMPACT_LOD_TILE_MAGIC) return TileError.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != COMPACT_LOD_TILE_VERSION) return TileError.UnsupportedVersion;
        if ((bytes[7] & 0xf0) != 0) return TileError.InvalidHeader;

        const lod_level = std.enums.fromInt(LODLevel, bytes[6]) orelse return TileError.InvalidLod;
        if (lod_level != .lod3 and lod_level != .lod4) return TileError.InvalidLod;
        const width = std.mem.readInt(u32, bytes[8..12], .little);
        if (!LODSimplifiedData.isSupportedGridSize(lod_level, width)) return TileError.InvalidHeader;
        const stride_value = apronStride(width) orelse return TileError.InvalidHeader;
        const sample_count = squareCount(stride_value) orelse return TileError.InvalidHeader;
        if (std.mem.readInt(u32, bytes[12..16], .little) != sample_count) return TileError.InvalidHeader;

        const payload_len = std.math.mul(usize, sample_count, COMPACT_LOD_SAMPLE_BYTES) catch return TileError.InvalidHeader;
        if (bytes.len != COMPACT_LOD_TILE_HEADER_BYTES + payload_len) return TileError.InvalidLength;
        const payload = bytes[COMPACT_LOD_TILE_HEADER_BYTES..];
        if (std.mem.readInt(u32, bytes[16..20], .little) != computeTileCrc(bytes)) return TileError.ChecksumMismatch;

        const samples = try allocator.alloc(CompactLODSample, sample_count);
        errdefer allocator.free(samples);
        @memcpy(std.mem.sliceAsBytes(samples), payload);
        for (samples) |sample_value| {
            if (!sample_value.isValid()) return TileError.InvalidSample;
        }
        return .{ .allocator = allocator, .lod_level = lod_level, .width = width, .neighbor_apron_mask = bytes[7], .samples = samples };
    }
};

/// Reduces a block to the renderer-independent seven-bit semantic material ID.
/// Values not known by this build use stone until an ABI version adds them.
pub fn reduceMaterial(block: BlockType) u7 {
    const id: u8 = @intFromEnum(block);
    return @intCast(if (id <= @min(MAX_ENCODED_BLOCK_ID, MAX_KNOWN_BLOCK_ID)) id else @intFromEnum(BlockType.stone));
}

fn packSourceColumn(source: *const LODSimplifiedData, index: usize) CompactLODSample {
    const water = source.water[index];
    const water_height: i16 = if (water.is_surface) quantizeWaterHeight(water.surface_height) else WATER_HEIGHT_NONE;
    const layers = source.material_layers[index];

    var bits: u128 = 0;
    bits |= @as(u128, @as(u16, @bitCast(quantizeTerrainHeight(terrainHeightForColumn(source, index)))));
    bits |= @as(u128, @as(u16, @bitCast(water_height))) << 16;
    bits |= @as(u128, if (water.is_surface) quantizeRange(water.depth, DEPTH_SCALE, 255) else 0) << 32;
    bits |= @as(u128, if (water.is_surface) quantizeUnit(water.coverage, 255) else 0) << 40;
    bits |= @as(u128, reduceMaterial(layers.surface)) << 48;
    bits |= @as(u128, reduceMaterial(layers.subsurface)) << 55;
    bits |= @as(u128, reduceMaterial(layers.foundation)) << 62;
    bits |= @as(u128, source.colors[index] & 0x00ff_ffff) << 69;
    bits |= @as(u128, @min(source.lighting[index].sky_light, 15)) << 93;
    bits |= @as(u128, @min(source.lighting[index].block_light, 15)) << 97;
    bits |= @as(u128, quantizeUnit(source.lighting[index].ambient_occlusion, 63)) << 101;
    bits |= @as(u128, quantizeUnit(source.vegetation[index].tree_coverage, 63)) << 107;
    bits |= @as(u128, quantizeRange(source.vegetation[index].avg_tree_height, VEGETATION_HEIGHT_SCALE, 255)) << 113;
    bits |= @as(u128, @intFromEnum(source.provenance[index])) << 121;

    var bytes: [COMPACT_LOD_SAMPLE_BYTES]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], @truncate(bits), .little);
    std.mem.writeInt(u64, bytes[8..16], @truncate(bits >> 64), .little);
    return .{ .bytes = bytes };
}

fn quantizeTerrainHeight(value: f32) i16 {
    return quantizeSigned(value, std.math.minInt(i16), std.math.maxInt(i16));
}

fn terrainHeightForColumn(source: *const LODSimplifiedData, index: usize) f32 {
    const terrain = source.heightmap[index];
    const water = source.water[index];
    if (!water.is_surface or water.coverage <= 0.0 or terrain < water.surface_height) return terrain;
    // Some coarse source columns encode the water surface as their height. Keep
    // the independently summarized floor in that ambiguous case.
    return if (water.depth > 0.0) @max(0.0, water.surface_height - water.depth) else water.surface_height;
}

fn hasUnsupportedVerticalSpans(source: *const LODSimplifiedData) bool {
    if (!source.hasVerticalSpans()) return false;
    var z: u32 = 0;
    while (z < source.width) : (z += 1) {
        var x: u32 = 0;
        while (x < source.width) : (x += 1) {
            const count = source.verticalSpanCount(x, z);
            // Version 1 represents one heightfield surface plus summary water
            // and vegetation fields. Any additional explicit topology must use
            // the maintained CPU mesh path until a versioned encoding exists.
            if (count > 1) return true;
            var span_index: u8 = 0;
            while (span_index < count) : (span_index += 1) {
                const span = source.getVerticalSpan(x, z, span_index) orelse return true;
                if (span.min_height > 0.01) return true;
            }
        }
    }
    return false;
}

fn hasUnsupportedWaterTopology(source: *const LODSimplifiedData) bool {
    var has_water = false;
    var has_dry = false;
    for (source.water) |water| {
        if (water.is_surface and water.coverage > 0.001 and water.coverage < 0.999) return true;
        if (water.is_surface and water.coverage >= 0.999) {
            has_water = true;
        } else {
            has_dry = true;
        }
        // The reusable full-grid index buffer cannot reject a shoreline cell
        // at primitive granularity. A triangle with one collapsed dry vertex
        // still stretches toward the clip point, so mixed tiles stay expanded.
        if (has_water and has_dry) return true;
    }
    return false;
}

fn quantizeWaterHeight(value: f32) i16 {
    return quantizeSigned(value, std.math.minInt(i16) + 1, std.math.maxInt(i16));
}

fn quantizeSigned(value: f32, min: i16, max: i16) i16 {
    const finite = if (std.math.isFinite(value)) value else 0.0;
    const min_value = @as(f32, @floatFromInt(min)) / HEIGHT_SCALE;
    const max_value = @as(f32, @floatFromInt(max)) / HEIGHT_SCALE;
    return @intFromFloat(@round(std.math.clamp(finite, min_value, max_value) * HEIGHT_SCALE));
}

fn quantizeRange(value: f32, scale: f32, max: u8) u8 {
    const finite = if (std.math.isFinite(value)) value else 0.0;
    const max_value = @as(f32, @floatFromInt(max)) / scale;
    return @intFromFloat(@round(std.math.clamp(finite, 0.0, max_value) * scale));
}

fn quantizeUnit(value: f32, max: u8) u8 {
    const finite = if (std.math.isFinite(value)) value else 0.0;
    return @intFromFloat(@round(std.math.clamp(finite, 0.0, 1.0) * @as(f32, @floatFromInt(max))));
}

fn dequantizeHeight(value: i16) f32 {
    return @as(f32, @floatFromInt(value)) / HEIGHT_SCALE;
}

fn signedField(bits: u128, shift: u7) i16 {
    const raw: u16 = @truncate(bits >> shift);
    return @bitCast(raw);
}

fn unsignedField(bits: u128, shift: u7, comptime T: type) T {
    return @truncate(bits >> shift);
}

fn semanticMaterialFromId(id: u7) BlockType {
    return @enumFromInt(id);
}

fn provenanceFromBits(bits: u8) LODColumnProvenance {
    return std.enums.fromInt(LODColumnProvenance, bits) orelse .worldgen;
}

fn computeTileCrc(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes[0..16]);
    crc.update(&.{ 0, 0, 0, 0 });
    crc.update(bytes[COMPACT_LOD_TILE_HEADER_BYTES..]);
    return crc.final();
}

fn apronStride(width: u32) ?u32 {
    return std.math.add(u32, width, 2) catch null;
}

fn squareCount(width: u32) ?usize {
    const count = std.math.mul(u32, width, width) catch return null;
    return @intCast(count);
}

fn apronToSourceCoordinate(apron_coordinate: u32, width: u32) u32 {
    if (apron_coordinate == 0) return 0;
    return @min(apron_coordinate - 1, width - 1);
}

test "CompactLODSample golden vector decodes signed 128-bit height fields" {
    // terrain=-12.5, water=7.25. The upper word also proves that decode does
    // not accidentally truncate the packed u128 before reading later fields.
    var bits: u128 = 0;
    bits |= @as(u128, @as(u16, @bitCast(@as(i16, -100))));
    bits |= @as(u128, @as(u16, @bitCast(@as(i16, 58)))) << 16;
    bits |= @as(u128, 9) << 32;
    bits |= @as(u128, 255) << 40;
    bits |= @as(u128, 15) << 93;
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], @truncate(bits), .little);
    std.mem.writeInt(u64, bytes[8..16], @truncate(bits >> 64), .little);
    const decoded = (CompactLODSample{ .bytes = bytes }).decode();
    try std.testing.expectEqual(@as(f32, -12.5), decoded.terrain_height);
    try std.testing.expectEqual(@as(f32, 7.25), decoded.water.surface_height);
    try std.testing.expectEqual(@as(u8, 15), decoded.lighting.sky_light);
}

test "CompactLODTile round trips its versioned little-endian payload" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod3);
    defer source.deinit();
    for (source.water) |*water| water.* = .{ .is_surface = true, .surface_height = 124.25, .depth = 3.5, .coverage = 1.0 };
    source.setColumn(2, 3, 123.125, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0xaabb_ccdd, .{ .is_surface = true, .surface_height = 124.25, .depth = 3.5, .coverage = 1.0 }, .{ .sky_light = 15, .block_light = 7, .ambient_occlusion = 0.5 }, .{ .tree_coverage = 0.5, .avg_tree_height = 12.5, .offset_x = 0.25, .offset_z = 0.75, .trunk = .wood, .leaves = .leaves });
    source.setColumnProvenance(2, 3, .edited);

    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(allocator, .lod3, &source));
    try std.testing.expectEqual(@as(f32, 0.5), source.vegetation[2 + 3 * source.width].tree_coverage);
    source.vegetation[2 + 3 * source.width] = .empty;

    var tile = try CompactLODTile.initFromSimplified(allocator, .lod3, &source);
    defer tile.deinit();
    const wire = try tile.serialize(allocator);
    defer allocator.free(wire);
    var restored = try CompactLODTile.deserialize(allocator, wire);
    defer restored.deinit();

    try std.testing.expectEqual(COMPACT_LOD_TILE_HEADER_BYTES + tile.samples.len * COMPACT_LOD_SAMPLE_BYTES, wire.len);
    try std.testing.expectEqualDeep(tile.sample(2, 3).?, restored.sample(2, 3).?);
    const decoded = restored.sample(2, 3).?.decode();
    try std.testing.expectEqual(@as(f32, 123.125), decoded.terrain_height);
    try std.testing.expectEqual(@as(u32, 0x00bb_ccdd), decoded.color);
    try std.testing.expectEqual(LODColumnProvenance.edited, decoded.provenance);
}

test "CompactLODTile clamps and rounds quantized source values deterministically" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    for (source.water) |*water| water.* = .{ .is_surface = true, .surface_height = 9999.0, .depth = 9999.0, .coverage = 1.0 };
    source.setColumn(0, 0, 1.07, .plains, LODMaterialLayers.default(.stone), 0, .{ .is_surface = true, .surface_height = 9999.0, .depth = 9999.0, .coverage = 2.0 }, .{ .sky_light = 255, .block_light = 99, .ambient_occlusion = -1.0 }, .{ .tree_coverage = 2.0, .avg_tree_height = 999.0, .offset_x = 0.0, .offset_z = 0.0, .trunk = .air, .leaves = .air });
    source.setHeight(1, 0, -9999.0);

    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(allocator, .lod4, &source));
    // Wire quantizers remain testable independently of render eligibility.
    const first = packSourceColumn(&source, 0).decode();
    const second = packSourceColumn(&source, 1).decode();
    try std.testing.expectEqual(@as(f32, 1.125), first.terrain_height);
    try std.testing.expectEqual(@as(f32, 4095.875), first.water.surface_height);
    try std.testing.expectEqual(@as(f32, 63.75), first.water.depth);
    try std.testing.expectEqual(@as(f32, 1.0), first.water.coverage);
    try std.testing.expectEqual(@as(u8, 15), first.lighting.sky_light);
    try std.testing.expectEqual(@as(f32, 0.0), first.lighting.ambient_occlusion);
    try std.testing.expectEqual(@as(f32, 127.5), first.vegetation.avg_tree_height);
    try std.testing.expectEqual(@as(f32, -4096.0), second.terrain_height);
}

test "CompactLODTile accepts reduced LOD3 and LOD4 density grids" {
    const allocator = std.testing.allocator;
    inline for ([_]struct { lod: LODLevel, density: f32, width: u32 }{
        .{ .lod = .lod3, .density = 0.5, .width = 65 },
        .{ .lod = .lod4, .density = 0.25, .width = 17 },
    }) |case| {
        var source = try LODSimplifiedData.initWithSampleDensity(allocator, case.lod, case.density);
        defer source.deinit();
        var tile = try CompactLODTile.initFromSimplified(allocator, case.lod, &source);
        defer tile.deinit();
        try std.testing.expectEqual(case.width, tile.width);
        try std.testing.expectEqual((case.width - 1) * (case.width - 1) * 6, (tile.width - 1) * (tile.width - 1) * 6);
    }
}

test "CompactLODTile rejects partial water so CPU shore geometry is retained" {
    var source = try LODSimplifiedData.init(std.testing.allocator, .lod4);
    defer source.deinit();
    source.setColumn(1, 1, 64.0, .plains, LODMaterialLayers.default(.sand), 0, .{
        .is_surface = true,
        .surface_height = 65.0,
        .depth = 1.0,
        .coverage = 0.5,
    }, .daylight, .empty);
    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(std.testing.allocator, .lod4, &source));
}

test "CompactLODTile uses the water-height sentinel for dry columns" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    source.setColumn(0, 0, 10.0, .plains, LODMaterialLayers.default(.sand), 0, .{ .is_surface = false, .surface_height = 42.0, .depth = 8.0, .coverage = 1.0 }, LODLightingHint.daylight, LODVegetationHint.empty);
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();

    const decoded = tile.sample(0, 0).?.decode();
    try std.testing.expect(!decoded.water.is_surface);
    try std.testing.expectEqual(@as(f32, 0.0), decoded.water.surface_height);
    try std.testing.expectEqual(@as(f32, 0.0), decoded.water.depth);
    try std.testing.expectEqual(@as(f32, 0.0), decoded.water.coverage);
}

test "CompactLODTile retains column provenance" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    source.setColumnProvenance(4, 5, .chunk_derived);
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();

    try std.testing.expectEqual(LODColumnProvenance.chunk_derived, tile.sample(4, 5).?.decode().provenance);
}

test "CompactLODTile duplicates boundary samples for stable neighbor normals" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    source.setHeight(0, 0, 11.0);
    source.setHeight(source.width - 1, source.width - 1, 22.0);
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();

    try std.testing.expectEqual(@as(f32, 11.0), tile.sampleClamped(-1, -1).decode().terrain_height);
    try std.testing.expectEqual(@as(f32, 22.0), tile.sampleClamped(@as(i32, @intCast(source.width)), @as(i32, @intCast(source.width))).decode().terrain_height);
    try std.testing.expectEqualDeep(tile.sampleApron(0, 0).?, tile.sample(0, 0).?);
}

test "CompactLODTile patches aprons from same-level neighbors" {
    const allocator = std.testing.allocator;
    var left_source = try LODSimplifiedData.init(allocator, .lod4);
    defer left_source.deinit();
    var right_source = try LODSimplifiedData.init(allocator, .lod4);
    defer right_source.deinit();
    var mismatched_source = try LODSimplifiedData.init(allocator, .lod3);
    defer mismatched_source.deinit();
    right_source.setHeight(0, 7, 44.0);
    right_source.setHeight(1, 7, 88.0);

    var left = try CompactLODTile.initFromSimplified(allocator, .lod4, &left_source);
    defer left.deinit();
    var right = try CompactLODTile.initFromSimplified(allocator, .lod4, &right_source);
    defer right.deinit();
    var mismatched = try CompactLODTile.initFromSimplified(allocator, .lod3, &mismatched_source);
    defer mismatched.deinit();
    try left.applyNeighborApron(.east, &right);

    try std.testing.expect(left.hasNeighborApron(.east));
    try std.testing.expectEqual(@as(f32, 88.0), left.sampleApron(left.stride() - 1, 8).?.decode().terrain_height);
    try std.testing.expectEqual(@as(f32, 88.0), left.sampleClamped(@intCast(left.width), 7).decode().terrain_height);
    try std.testing.expectError(TileError.InvalidSourceData, left.applyNeighborApron(.east, &mismatched));
}

test "CompactLODTile neighbor aprons use samples beyond shared endpoints" {
    const allocator = std.testing.allocator;
    var center_source = try LODSimplifiedData.init(allocator, .lod4);
    defer center_source.deinit();
    var neighbor_source = try LODSimplifiedData.init(allocator, .lod4);
    defer neighbor_source.deinit();
    const last = neighbor_source.width - 1;
    neighbor_source.setHeight(3, last - 1, 11.0);
    neighbor_source.setHeight(1, 3, 22.0);
    neighbor_source.setHeight(3, 1, 33.0);
    neighbor_source.setHeight(last - 1, 3, 44.0);

    inline for (.{
        .{ TileEdge.north, @as(f32, 11.0) },
        .{ TileEdge.east, @as(f32, 22.0) },
        .{ TileEdge.south, @as(f32, 33.0) },
        .{ TileEdge.west, @as(f32, 44.0) },
    }) |case| {
        var center = try CompactLODTile.initFromSimplified(allocator, .lod4, &center_source);
        defer center.deinit();
        var neighbor = try CompactLODTile.initFromSimplified(allocator, .lod4, &neighbor_source);
        defer neighbor.deinit();
        try center.applyNeighborApron(case[0], &neighbor);
        const sample = switch (case[0]) {
            .north => center.sampleApron(4, 0).?,
            .east => center.sampleApron(center.stride() - 1, 4).?,
            .south => center.sampleApron(4, center.stride() - 1).?,
            .west => center.sampleApron(0, 4).?,
        };
        try std.testing.expectEqual(case[1], sample.decode().terrain_height);
    }
}

test "CompactLODTile stores terrain floor separately from water surface" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    for (source.water) |*water| water.* = .{ .is_surface = true, .surface_height = 64.0, .depth = 10.0, .coverage = 1.0 };
    source.setColumn(1, 1, 64.0, .ocean, .{ .surface = .water, .subsurface = .sand, .foundation = .stone }, 0, .{ .is_surface = true, .surface_height = 64.0, .depth = 10.0, .coverage = 1.0 }, .daylight, .empty);
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();

    const decoded = tile.sample(1, 1).?.decode();
    try std.testing.expectEqual(@as(f32, 54.0), decoded.terrain_height);
    try std.testing.expectEqual(@as(f32, 64.0), decoded.water.surface_height);
}

test "CompactLODTile rejects mixed wet and dry samples without per-cell water indices" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    source.setColumn(1, 1, 64.0, .ocean, .{ .surface = .water, .subsurface = .sand, .foundation = .stone }, 0, .{ .is_surface = true, .surface_height = 64.0, .depth = 4.0, .coverage = 1.0 }, .daylight, .empty);
    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(allocator, .lod4, &source));
}

test "CompactLODTile rejects unsupported overhang spans" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod4);
    defer source.deinit();
    try std.testing.expect(source.setVerticalSpan(1, 1, 0, .{
        .min_height = 12.0,
        .max_height = 20.0,
        .biome = .plains,
        .material_layers = .{ .surface = .stone, .subsurface = .stone, .foundation = .stone },
        .color = 0,
        .water = .empty,
        .lighting = .daylight,
        .vegetation = .empty,
    }));

    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(allocator, .lod4, &source));
}

test "CompactLODTile rejects additional water spans until topology is versioned" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod4);
    defer source.deinit();
    try std.testing.expect(source.setVerticalSpan(1, 1, 0, .{
        .min_height = 0.0,
        .max_height = 54.0,
        .biome = .ocean,
        .material_layers = .{ .surface = .sand, .subsurface = .sand, .foundation = .stone },
        .color = 0,
        .water = .empty,
        .lighting = .daylight,
        .vegetation = .empty,
    }));
    try std.testing.expect(source.setVerticalSpan(1, 1, 1, .{
        .min_height = 54.0,
        .max_height = 64.0,
        .biome = .ocean,
        .material_layers = .{ .surface = .water, .subsurface = .water, .foundation = .stone },
        .color = 0,
        .water = .{ .is_surface = true, .surface_height = 64.0, .depth = 10.0, .coverage = 1.0 },
        .lighting = .daylight,
        .vegetation = .empty,
    }));

    try std.testing.expectError(TileError.UnsupportedSourceFeatures, CompactLODTile.initFromSimplified(allocator, .lod4, &source));
}

test "CompactLODTile rejects a corrupted serialized payload" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();
    const wire = try tile.serialize(allocator);
    defer allocator.free(wire);
    wire[COMPACT_LOD_TILE_HEADER_BYTES] ^= 0x80;

    try std.testing.expectError(TileError.ChecksumMismatch, CompactLODTile.deserialize(allocator, wire));
}

test "CompactLODTile rejects unknown semantic materials with a valid checksum" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();
    const wire = try tile.serialize(allocator);
    defer allocator.free(wire);

    const sample = wire[COMPACT_LOD_TILE_HEADER_BYTES..][0..COMPACT_LOD_SAMPLE_BYTES];
    var low = std.mem.readInt(u64, sample[0..8], .little);
    low &= ~(@as(u64, 0x7f) << 48);
    low |= @as(u64, MAX_KNOWN_BLOCK_ID + 1) << 48;
    std.mem.writeInt(u64, sample[0..8], low, .little);
    std.mem.writeInt(u32, wire[16..20], computeTileCrc(wire), .little);

    try std.testing.expectError(TileError.InvalidSample, CompactLODTile.deserialize(allocator, wire));
}

test "CompactLODTile reduces future material IDs and reports compact byte metrics" {
    const future_block: BlockType = @enumFromInt(200);
    try std.testing.expectEqual(@as(u7, @intFromEnum(BlockType.stone)), reduceMaterial(future_block));
    try std.testing.expectEqual(@as(u7, @intFromEnum(BlockType.blue_ice)), reduceMaterial(.blue_ice));

    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();
    const metrics = tile.byteMetrics(32);
    try std.testing.expectEqual(tile.samples.len * COMPACT_LOD_SAMPLE_BYTES, metrics.compact_upload_bytes);
    try std.testing.expect(metrics.compact_upload_bytes < metrics.conservative_expanded_top_grid_bytes);
    try std.testing.expectEqual(metrics.conservative_expanded_top_grid_bytes - metrics.compact_upload_bytes, metrics.savedBytes());
    try std.testing.expectEqual(@as(usize, 0), (ByteMetrics{ .compact_upload_bytes = 16, .conservative_expanded_top_grid_bytes = 0 }).savedBytes());
}

test "CompactLODTile checksum covers header metadata" {
    const allocator = std.testing.allocator;
    var source = try LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    var tile = try CompactLODTile.initFromSimplified(allocator, .lod4, &source);
    defer tile.deinit();
    const wire = try tile.serialize(allocator);
    defer allocator.free(wire);
    wire[7] ^= 0x01;

    try std.testing.expectError(TileError.ChecksumMismatch, CompactLODTile.deserialize(allocator, wire));
}
