//! Chunk data structure - 16x256x16 block storage with lighting.

const std = @import("std");
const BlockType = @import("block.zig").BlockType;
const block_registry = @import("block_registry.zig");
const BiomeId = @import("block.zig").Biome;

pub const CHUNK_SIZE_X = @import("chunk_constants.zig").CHUNK_SIZE_X;
pub const CHUNK_SIZE_Y = @import("chunk_constants.zig").CHUNK_SIZE_Y;
pub const CHUNK_SIZE_Z = @import("chunk_constants.zig").CHUNK_SIZE_Z;
pub const MAX_BLOCK_TYPES = @import("chunk_constants.zig").MAX_BLOCK_TYPES;
pub const CHUNK_VOLUME = @import("chunk_constants.zig").CHUNK_VOLUME;
pub const CHUNK_UNLOAD_BUFFER = @import("chunk_constants.zig").CHUNK_UNLOAD_BUFFER;
pub const MAX_LIGHT = @import("chunk_constants.zig").MAX_LIGHT;

pub const PackedLight = @import("light.zig").PackedLight;

pub const Chunk = struct {
    /// Runtime geometry lineage, independent of derived lighting and save admission.
    pub const SourceKind = enum { generated, saved, edited };

    pub const State = enum {
        missing,
        queued_for_generation,
        generating,
        generated,
        queued_for_mesh,
        meshing,
        mesh_ready,
        uploading,
        renderable,
        unloading,
    };

    chunk_x: i32,
    chunk_z: i32,
    blocks: [CHUNK_VOLUME]BlockType,
    light: [CHUNK_VOLUME]PackedLight,
    biomes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    heightmap: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
    /// Highest live non-air block per column for maps and other surface views.
    /// Unlike `heightmap`, this includes water, leaves, logs, and foliage.
    map_surface_blocks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BlockType,
    map_surface_heights: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
    map_surface_revision: u64 = 0,
    state: State = .missing,
    job_token: u32 = 0,
    /// Monotonic mesh-input revisions. They are updated while storage owns the chunk.
    content_revision: std.atomic.Value(u64) = .init(0),
    light_revision: std.atomic.Value(u64) = .init(0),
    dirty: bool = true,
    mesh_attempts: u8 = 0,
    force_cpu_mesh: bool = false,
    generated: bool = false,
    modified: bool = false,
    source_kind: SourceKind = .generated,
    /// In-process canonical snapshot order; never serialized as world authority.
    canonical_save_order: u64 = 0,
    /// Persisted with chunk format v3; v2 chunks are treated as stale lighting.
    lighting_valid: bool = false,
    pin_count: std.atomic.Value(u32),

    /// Creates a new chunk at chunk coordinates `(chunk_x, chunk_z)` with default air, plains biome, and zero light.
    /// The returned value owns no heap memory; chunk storage containers own its lifetime and synchronization.
    pub fn init(chunk_x: i32, chunk_z: i32) Chunk {
        return .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .blocks = [_]BlockType{.air} ** CHUNK_VOLUME,
            .light = [_]PackedLight{PackedLight.init(0, 0)} ** CHUNK_VOLUME,
            .biomes = [_]BiomeId{.plains} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .heightmap = [_]i16{0} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .map_surface_blocks = [_]BlockType{.air} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .map_surface_heights = [_]i16{-1} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .state = .missing,
            .pin_count = std.atomic.Value(u32).init(0),
        };
    }

    /// Converts chunk-local `(x, y, z)` coordinates into the flat storage index.
    /// Coordinates must be in bounds; debug builds assert on invalid local positions.
    pub fn getIndex(x: u32, y: u32, z: u32) usize {
        std.debug.assert(x < CHUNK_SIZE_X);
        std.debug.assert(y < CHUNK_SIZE_Y);
        std.debug.assert(z < CHUNK_SIZE_Z);
        return @as(usize, x) + @as(usize, z) * CHUNK_SIZE_X + @as(usize, y) * CHUNK_SIZE_X * CHUNK_SIZE_Z;
    }

    /// Reads the block at chunk-local coordinates.
    /// Coordinates must be in bounds; use `getBlockSafe` for unchecked neighbor sampling.
    pub fn getBlock(self: *const Chunk, x: u32, y: u32, z: u32) BlockType {
        return self.blocks[getIndex(x, y, z)];
    }

    /// Writes a block at chunk-local coordinates and marks the chunk dirty and modified.
    /// Coordinates must be in bounds; callers are responsible for scheduling mesh/light updates.
    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
        const index = getIndex(x, y, z);
        if (self.blocks[index] == block) return;
        self.blocks[index] = block;
        self.dirty = true;
        self.modified = true;
        self.markContentChanged();
    }

    /// Safely reads a block for possibly out-of-bounds local coordinates.
    /// Out-of-range samples return `.air`, matching neighbor-missing meshing behavior.
    pub fn getBlockSafe(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_SIZE_X or y < 0 or y >= CHUNK_SIZE_Y or z < 0 or z >= CHUNK_SIZE_Z) return .air;
        return self.getBlock(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Reads the biome id for a horizontal chunk-local column.
    /// `x` and `z` must be in range `[0, CHUNK_SIZE_X/Z)`.
    pub fn getBiome(self: *const Chunk, x: u32, z: u32) BiomeId {
        return self.biomes[x + z * CHUNK_SIZE_X];
    }

    /// Writes the biome id for a horizontal chunk-local column and marks the chunk dirty.
    /// This affects tinting and terrain metadata but does not mark the chunk player-modified.
    pub fn setBiome(self: *Chunk, x: u32, z: u32, biome: BiomeId) void {
        const index = x + z * CHUNK_SIZE_X;
        if (self.biomes[index] == biome) return;
        self.biomes[index] = biome;
        self.dirty = true;
        self.markContentChanged();
    }

    /// Marks direct bulk writes to blocks, biomes, or heightmap as mesh-relevant.
    pub fn markContentChanged(self: *Chunk) void {
        _ = self.content_revision.fetchAdd(1, .release);
    }

    /// Marks a completed lighting batch as mesh-relevant.
    pub fn markLightChanged(self: *Chunk) void {
        _ = self.light_revision.fetchAdd(1, .release);
    }

    /// Reads packed sky/block light at chunk-local coordinates.
    /// Coordinates must be in bounds and are not checked outside debug assertions in `getIndex`.
    pub fn getLight(self: *const Chunk, x: u32, y: u32, z: u32) PackedLight {
        return self.light[getIndex(x, y, z)];
    }

    /// Writes packed sky/block light at chunk-local coordinates.
    /// Lighting callers are responsible for marking dependent meshes dirty when needed.
    pub fn setLight(self: *Chunk, x: u32, y: u32, z: u32, light_val: PackedLight) void {
        self.light[getIndex(x, y, z)] = light_val;
    }

    /// Reads only the sky-light channel at chunk-local coordinates.
    /// Coordinates must be in bounds.
    pub fn getSkyLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.light[getIndex(x, y, z)].getSkyLight();
    }

    /// Writes only the sky-light channel at chunk-local coordinates.
    /// Coordinates must be in bounds and `val` is a packed 4-bit light value.
    pub fn setSkyLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setSkyLight(val);
    }

    /// Reads only the block-light channel at chunk-local coordinates.
    /// Coordinates must be in bounds.
    pub fn getBlockLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.light[getIndex(x, y, z)].getBlockLight();
    }

    /// Reads the cached surface height for a horizontal chunk-local column.
    /// The value is maintained by generation/lighting paths and used by worldgen and meshing.
    pub fn getSurfaceHeight(self: *const Chunk, x: u32, z: u32) i16 {
        return self.heightmap[x + z * CHUNK_SIZE_X];
    }

    /// Writes the cached surface height for a horizontal chunk-local column.
    /// Does not recompute lighting or mesh data by itself.
    pub fn setSurfaceHeight(self: *Chunk, x: u32, z: u32, height: i16) void {
        self.heightmap[x + z * CHUNK_SIZE_X] = height;
    }

    /// Writes the scalar block-light channel at chunk-local coordinates.
    /// Coordinates must be in bounds and `val` is a packed 4-bit light value.
    pub fn setBlockLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setBlockLight(val);
    }

    /// Writes RGB block-light channels at chunk-local coordinates.
    /// Coordinates must be in bounds and each channel is a packed 4-bit value.
    pub fn setBlockLightRGB(self: *Chunk, x: u32, y: u32, z: u32, r: u4, g: u4, b: u4) void {
        self.light[getIndex(x, y, z)].setBlockLightRGB(r, g, b);
    }

    /// Safely reads packed light for possibly out-of-bounds local coordinates.
    /// Horizontal out-of-range samples return dark; samples above the world return full sky light for top-face meshing.
    pub fn getLightSafe(self: *const Chunk, x: i32, y: i32, z: i32) PackedLight {
        // Out-of-bounds X/Z returns zero light. Out-of-bounds Y returns:
        //   - MAX_LIGHT sky light for y >= CHUNK_SIZE_Y: the meshing system samples this
        //     position to light the TOP FACE of the highest block in each column (e.g. a
        //     mountain peak at y=255 queries y=256). The space above the world is open
        //     sky, so the face should be full daylight. Returning 0 here makes mountain
        //     tops render incorrectly dark.
        //   - 0 light for y < 0: nothing emits light from below the world.
        if (x < 0 or x >= CHUNK_SIZE_X or z < 0 or z >= CHUNK_SIZE_Z) return PackedLight.init(0, 0);
        if (y >= CHUNK_SIZE_Y) return PackedLight.init(MAX_LIGHT, 0);
        if (y < 0) return PackedLight.init(0, 0);
        return self.getLight(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Returns the world-space block X coordinate of this chunk's minimum X edge.
    /// Extreme chunk coordinates saturate to the nearest representable i32 edge.
    pub fn getWorldX(self: *const Chunk) i32 {
        return chunkCoordToWorldEdge(self.chunk_x, CHUNK_SIZE_X);
    }

    /// Returns the world-space block Z coordinate of this chunk's minimum Z edge.
    /// Extreme chunk coordinates saturate to the nearest representable i32 edge.
    pub fn getWorldZ(self: *const Chunk) i32 {
        return chunkCoordToWorldEdge(self.chunk_z, CHUNK_SIZE_Z);
    }

    /// Scans a local column from top to bottom and returns the highest non-air, non-water block Y.
    /// Returns zero when the column has no solid block; `x` and `z` must be in bounds.
    pub fn getHighestSolidY(self: *const Chunk, x: u32, z: u32) u32 {
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const block = self.getBlock(x, @intCast(y), z);
            if (block != .air and block != .water) return @intCast(y);
        }
        return 0;
    }

    /// Rebuilds the live top-surface cache in one pass over block storage.
    /// Returns the total number of non-air blocks, allowing generation
    /// publication to reuse this scan for empty-chunk validation.
    pub fn rebuildMapSurface(self: *Chunk) u32 {
        @memset(&self.map_surface_blocks, .air);
        @memset(&self.map_surface_heights, -1);

        var non_air_count: u32 = 0;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                var x: u32 = 0;
                while (x < CHUNK_SIZE_X) : (x += 1) {
                    const block = self.getBlock(x, @intCast(y), z);
                    if (block == .air) continue;
                    non_air_count += 1;
                    const column = x + z * CHUNK_SIZE_X;
                    if (self.map_surface_heights[column] < 0) {
                        self.map_surface_blocks[column] = block;
                        self.map_surface_heights[column] = @intCast(y);
                    }
                }
            }
        }
        self.map_surface_revision = self.content_revision.load(.acquire);
        return non_air_count;
    }

    pub fn mapSurfaceIsCurrent(self: *const Chunk) bool {
        return self.map_surface_revision == self.content_revision.load(.acquire);
    }

    /// Increments the async-work pin count for this chunk.
    /// Streamers must not unload pinned chunks while worker jobs may still read them.
    pub fn pin(self: *Chunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    /// Decrements the async-work pin count for this chunk.
    /// Must be paired with a previous `pin`; callers are responsible for avoiding underflow.
    pub fn unpin(self: *Chunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    /// Reports whether any async job currently pins this chunk.
    /// This is an atomic read suitable for streamer unload checks.
    pub fn isPinned(self: *const Chunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    /// Fills every block in the chunk with one block type and marks block data dirty.
    /// Does not update biome, light, or heightmap arrays.
    pub fn fill(self: *Chunk, block: BlockType) void {
        @memset(&self.blocks, block);
        self.dirty = true;
    }

    /// Fills one horizontal Y layer with a block type using normal `setBlock` mutation semantics.
    /// `y` must be in bounds; the chunk becomes dirty and modified.
    pub fn fillLayer(self: *Chunk, y: u32, block: BlockType) void {
        var x: u32 = 0;
        while (x < CHUNK_SIZE_X) : (x += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                self.setBlock(x, y, z, block);
            }
        }
    }

    /// Generates a simple flat terrain stack of bedrock, stone, dirt, grass, and air.
    /// Marks the chunk generated and dirty; intended for tests and flat-world generation.
    pub fn generateFlat(self: *Chunk, ground_level: u32) void {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const block: BlockType = if (y == 0)
                .bedrock
            else if (y < ground_level - 3)
                .stone
            else if (y < ground_level)
                .dirt
            else if (y == ground_level)
                .grass
            else
                .air;

            self.fillLayer(y, block);
        }
        self.generated = true;
        self.dirty = true;
    }

    /// Recomputes top-down sky light for one local `(x, z)` column.
    /// Opaque blocks stop sky light and water attenuates it by one level per block.
    pub fn updateSkylightColumn(self: *Chunk, x: u32, z: u32) void {
        var sky_light: u4 = MAX_LIGHT;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const uy: u32 = @intCast(y);
            const block = self.getBlock(x, uy, z);
            self.setSkyLight(x, uy, z, sky_light);
            if (block_registry.getBlockDefinition(block).isOpaque()) {
                sky_light = 0;
            } else {
                sky_light = block_registry.attenuateVerticalSkylight(sky_light, block);
            }
        }
    }
};

fn chunkCoordToWorldEdge(coord: i32, comptime chunk_size: comptime_int) i32 {
    const max_edge = std.math.maxInt(i32) - chunk_size + 1;
    const product = @as(i64, coord) * @as(i64, chunk_size);
    const clamped = std.math.clamp(product, std.math.minInt(i32), max_edge);
    return @intCast(clamped);
}

/// Converts floating world X/Z coordinates to chunk coordinates.
/// Coordinates are floored to block coordinates first, then converted with negative-safe floor division.
pub fn worldToChunkFromFloat(world_x: f32, world_z: f32) struct { chunk_x: i32, chunk_z: i32 } {
    const chunk = worldToChunk(@as(i32, @intFromFloat(@floor(world_x))), @as(i32, @intFromFloat(@floor(world_z))));
    return .{ .chunk_x = chunk.chunk_x, .chunk_z = chunk.chunk_z };
}

/// Converts integer world X/Z block coordinates to chunk coordinates.
/// Uses floor division so negative world coordinates map to the containing negative chunk.
pub fn worldToChunk(world_x: i32, world_z: i32) struct { chunk_x: i32, chunk_z: i32 } {
    return .{
        .chunk_x = @divFloor(world_x, CHUNK_SIZE_X),
        .chunk_z = @divFloor(world_z, CHUNK_SIZE_Z),
    };
}

/// Converts integer world X/Z block coordinates to local coordinates inside their containing chunk.
/// Uses modulo semantics that produce values in `[0, CHUNK_SIZE_X/Z)` even for negative world coordinates.
pub fn worldToLocal(world_x: i32, world_z: i32) struct { x: u32, z: u32 } {
    return .{
        .x = @intCast(@mod(world_x, CHUNK_SIZE_X)),
        .z = @intCast(@mod(world_z, CHUNK_SIZE_Z)),
    };
}
