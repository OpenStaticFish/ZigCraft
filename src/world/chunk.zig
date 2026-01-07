//! Chunk data structure - 16x256x16 block storage with lighting.

const std = @import("std");
const BlockType = @import("block.zig").BlockType;
const BiomeId = @import("worldgen/biome.zig").BiomeId;

pub const CHUNK_SIZE_X = 16;
pub const CHUNK_SIZE_Y = 256;
pub const CHUNK_SIZE_Z = 16;
pub const CHUNK_VOLUME = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z;

/// Maximum light level (0-15)
pub const MAX_LIGHT: u4 = 15;

/// Packed light value: upper 4 bits = skylight, then 4 bits each for R, G, B block light
pub const PackedLight = packed struct {
    block_light_b: u4 = 0, // Bits 0-3
    block_light_g: u4 = 0, // Bits 4-7
    block_light_r: u4 = 0, // Bits 8-11
    sky_light: u4 = 0, // Bits 12-15

    pub fn init(sky: u4, block: u4) PackedLight {
        return .{
            .sky_light = sky,
            .block_light_r = block,
            .block_light_g = block,
            .block_light_b = block,
        };
    }

    pub fn initRGB(sky: u4, r: u4, g: u4, b: u4) PackedLight {
        return .{
            .sky_light = sky,
            .block_light_r = r,
            .block_light_g = g,
            .block_light_b = b,
        };
    }

    pub fn getSkyLight(self: PackedLight) u4 {
        return self.sky_light;
    }

    pub fn getBlockLight(self: PackedLight) u4 {
        // Return average or max for legacy compatibility?
        // Max is probably safest for "intensity" checks.
        return @max(self.block_light_r, @max(self.block_light_g, self.block_light_b));
    }

    pub fn getBlockLightR(self: PackedLight) u4 {
        return self.block_light_r;
    }
    pub fn getBlockLightG(self: PackedLight) u4 {
        return self.block_light_g;
    }
    pub fn getBlockLightB(self: PackedLight) u4 {
        return self.block_light_b;
    }

    pub fn setSkyLight(self: *PackedLight, val: u4) void {
        self.sky_light = val;
    }

    pub fn setBlockLight(self: *PackedLight, val: u4) void {
        self.block_light_r = val;
        self.block_light_g = val;
        self.block_light_b = val;
    }

    pub fn setBlockLightRGB(self: *PackedLight, r: u4, g: u4, b: u4) void {
        self.block_light_r = r;
        self.block_light_g = g;
        self.block_light_b = b;
    }

    /// Get maximum of sky and block light channels
    pub fn getMaxLight(self: PackedLight) u4 {
        return @max(self.sky_light, @max(self.block_light_r, @max(self.block_light_g, self.block_light_b)));
    }

    /// Get normalized brightness (0.0 - 1.0)
    pub fn getBrightness(self: PackedLight) f32 {
        return @as(f32, @floatFromInt(self.getMaxLight())) / 15.0;
    }
};

pub const Chunk = struct {
    /// Chunk state for streaming
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

    /// Chunk position in chunk coordinates (multiply by 16 for world pos)
    chunk_x: i32,
    chunk_z: i32,

    /// Block data stored as flat array (Y-major for cache efficiency during meshing)
    /// Index = x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z
    blocks: [CHUNK_VOLUME]BlockType,

    /// Light data: packed skylight (4 bits) + blocklight (4 bits) per block
    light: [CHUNK_VOLUME]PackedLight,

    /// Biome data for each column (X, Z)
    biomes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,

    /// Surface heightmap (Y coordinate of highest solid block)
    /// Used for generation phases and gameplay logic (rain, spawns)
    /// Values < 0 mean no surface found (e.g. empty column)
    heightmap: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,

    /// Current state in the streaming pipeline
    state: State = .missing,

    /// Job token to validate async results (increments on recycle)
    job_token: u32 = 0,

    /// Is the mesh out of date?
    dirty: bool = true,

    /// Has this chunk been generated?
    generated: bool = false,

    /// Number of active jobs referencing this chunk (prevents unloading)
    pin_count: std.atomic.Value(u32),

    pub fn init(chunk_x: i32, chunk_z: i32) Chunk {
        return .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .blocks = [_]BlockType{.air} ** CHUNK_VOLUME,
            .light = [_]PackedLight{PackedLight.init(0, 0)} ** CHUNK_VOLUME,
            .biomes = [_]BiomeId{.plains} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .heightmap = [_]i16{0} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .state = .missing,
            .pin_count = std.atomic.Value(u32).init(0),
        };
    }

    /// Convert local coordinates to array index
    pub fn getIndex(x: u32, y: u32, z: u32) usize {
        std.debug.assert(x < CHUNK_SIZE_X);
        std.debug.assert(y < CHUNK_SIZE_Y);
        std.debug.assert(z < CHUNK_SIZE_Z);
        return @as(usize, x) + @as(usize, z) * CHUNK_SIZE_X + @as(usize, y) * CHUNK_SIZE_X * CHUNK_SIZE_Z;
    }

    /// Get block at local coordinates
    pub fn getBlock(self: *const Chunk, x: u32, y: u32, z: u32) BlockType {
        return self.blocks[getIndex(x, y, z)];
    }

    /// Set block at local coordinates
    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
        self.blocks[getIndex(x, y, z)] = block;
        self.dirty = true;
    }

    /// Get block with bounds checking (returns air if out of bounds)
    pub fn getBlockSafe(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_SIZE_X or
            y < 0 or y >= CHUNK_SIZE_Y or
            z < 0 or z >= CHUNK_SIZE_Z)
        {
            return .air;
        }
        return self.getBlock(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Get biome at local coordinates (y is ignored as biomes are column-based)
    pub fn getBiome(self: *const Chunk, x: u32, z: u32) BiomeId {
        return self.biomes[x + z * CHUNK_SIZE_X];
    }

    /// Set biome at local coordinates
    pub fn setBiome(self: *Chunk, x: u32, z: u32, biome: BiomeId) void {
        self.biomes[x + z * CHUNK_SIZE_X] = biome;
        self.dirty = true;
    }

    /// Get light at local coordinates
    pub fn getLight(self: *const Chunk, x: u32, y: u32, z: u32) PackedLight {
        return self.light[getIndex(x, y, z)];
    }

    /// Set light at local coordinates
    pub fn setLight(self: *Chunk, x: u32, y: u32, z: u32, light_val: PackedLight) void {
        self.light[getIndex(x, y, z)] = light_val;
    }

    /// Get skylight at local coordinates
    pub fn getSkyLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.light[getIndex(x, y, z)].getSkyLight();
    }

    /// Set skylight at local coordinates
    pub fn setSkyLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setSkyLight(val);
    }

    /// Get blocklight at local coordinates
    pub fn getBlockLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        const idx = x + z * CHUNK_SIZE_X + y * CHUNK_SIZE_X * CHUNK_SIZE_Z;
        return self.light[idx].getBlockLight();
    }

    /// Get surface height at local coordinates
    pub fn getSurfaceHeight(self: *const Chunk, x: u32, z: u32) i16 {
        return self.heightmap[x + z * CHUNK_SIZE_X];
    }

    /// Set surface height at local coordinates
    pub fn setSurfaceHeight(self: *Chunk, x: u32, z: u32, height: i16) void {
        self.heightmap[x + z * CHUNK_SIZE_X] = height;
    }

    /// Set blocklight at local coordinates
    pub fn setBlockLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setBlockLight(val);
    }

    /// Set RGB blocklight at local coordinates
    pub fn setBlockLightRGB(self: *Chunk, x: u32, y: u32, z: u32, r: u4, g: u4, b: u4) void {
        self.light[getIndex(x, y, z)].setBlockLightRGB(r, g, b);
    }

    /// Get light with bounds checking (returns 0 if out of bounds, 15 if above world)
    pub fn getLightSafe(self: *const Chunk, x: i32, y: i32, z: i32) PackedLight {
        if (x < 0 or x >= CHUNK_SIZE_X or z < 0 or z >= CHUNK_SIZE_Z) {
            return PackedLight.init(0, 0);
        }
        if (y >= CHUNK_SIZE_Y) {
            return PackedLight.init(MAX_LIGHT, 0); // Full skylight above world
        }
        if (y < 0) {
            return PackedLight.init(0, 0);
        }
        return self.getLight(@intCast(x), @intCast(y), @intCast(z));
    }

    /// Get world X coordinate of this chunk's origin
    pub fn getWorldX(self: *const Chunk) i32 {
        return self.chunk_x * CHUNK_SIZE_X;
    }

    /// Get world Z coordinate of this chunk's origin
    pub fn getWorldZ(self: *const Chunk) i32 {
        return self.chunk_z * CHUNK_SIZE_Z;
    }

    /// Get the highest solid (non-air) Y coordinate in this column
    /// Returns 0 if the column is entirely air
    pub fn getHighestSolidY(self: *const Chunk, x: u32, z: u32) u32 {
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const block = self.getBlock(x, @intCast(y), z);
            if (block != .air and block != .water) {
                return @intCast(y);
            }
        }
        return 0;
    }

    pub fn pin(self: *Chunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    pub fn unpin(self: *Chunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    pub fn isPinned(self: *const Chunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    /// Fill entire chunk with a block type
    pub fn fill(self: *Chunk, block: BlockType) void {
        @memset(&self.blocks, block);
        self.dirty = true;
    }

    /// Fill a layer (all blocks at a specific Y level)
    pub fn fillLayer(self: *Chunk, y: u32, block: BlockType) void {
        var x: u32 = 0;
        while (x < CHUNK_SIZE_X) : (x += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                self.setBlock(x, y, z, block);
            }
        }
    }

    /// Generate flat terrain (for testing)
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

    /// Update skylight for a specific column (x, z)
    pub fn updateSkylightColumn(self: *Chunk, x: u32, z: u32) void {
        var sky_light: u4 = MAX_LIGHT;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const uy: u32 = @intCast(y);
            const block = self.getBlock(x, uy, z);
            self.setSkyLight(x, uy, z, sky_light);
            if (block.isOpaque()) {
                sky_light = 0;
            } else if (block == .water and sky_light > 0) {
                sky_light -= 1;
            }
        }
    }
};

/// Convert world coordinates to chunk coordinates
pub fn worldToChunk(world_x: i32, world_z: i32) struct { chunk_x: i32, chunk_z: i32 } {
    return .{
        .chunk_x = @divFloor(world_x, CHUNK_SIZE_X),
        .chunk_z = @divFloor(world_z, CHUNK_SIZE_Z),
    };
}

/// Convert world coordinates to local chunk coordinates
pub fn worldToLocal(world_x: i32, world_z: i32) struct { x: u32, z: u32 } {
    return .{
        .x = @intCast(@mod(world_x, CHUNK_SIZE_X)),
        .z = @intCast(@mod(world_z, CHUNK_SIZE_Z)),
    };
}
