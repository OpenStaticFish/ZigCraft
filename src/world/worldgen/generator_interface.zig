const std = @import("std");
const Chunk = @import("../chunk.zig").Chunk;
const LODLevel = @import("../lod_chunk.zig").LODLevel;
const LODSimplifiedData = @import("../lod_chunk.zig").LODSimplifiedData;

const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const BiomeId = @import("biome.zig").BiomeId;

pub const ColumnInfo = struct {
    height: i32,
    biome: BiomeId,
    is_ocean: bool,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
};

/// Options for controlling generation detail level
pub const GenerationOptions = struct {
    /// LOD level - higher = more simplified
    lod_level: LODLevel = .lod0,

    /// Enable cave generation (worm + noise caves)
    enable_caves: bool = true,

    /// Enable worm caves specifically (expensive neighbor checks)
    enable_worm_caves: bool = true,

    /// Enable decorations (trees, flowers, grass)
    enable_decorations: bool = true,

    /// Enable ore generation
    enable_ores: bool = true,

    /// Enable lighting calculation
    enable_lighting: bool = true,

    /// Noise octave reduction (0 = full detail, higher = fewer octaves)
    octave_reduction: u8 = 0,

    /// Skip biome edge blending
    skip_biome_blending: bool = false,

    /// Create options from LOD level with sensible defaults
    pub fn fromLOD(lod: LODLevel) GenerationOptions {
        return switch (lod) {
            .lod0 => .{
                .lod_level = .lod0,
                .enable_caves = true,
                .enable_worm_caves = true,
                .enable_decorations = true,
                .enable_ores = true,
                .enable_lighting = true,
                .octave_reduction = 0,
                .skip_biome_blending = false,
            },
            .lod1 => .{
                .lod_level = .lod1,
                .enable_caves = true,
                .enable_worm_caves = false, // Skip expensive worm caves
                .enable_decorations = true,
                .enable_ores = false,
                .enable_lighting = false,
                .octave_reduction = 1,
                .skip_biome_blending = true,
            },
            .lod2 => .{
                .lod_level = .lod2,
                .enable_caves = false, // Skip all caves
                .enable_worm_caves = false,
                .enable_decorations = false,
                .enable_ores = false,
                .enable_lighting = false,
                .octave_reduction = 2,
                .skip_biome_blending = true,
            },
            .lod3 => .{
                .lod_level = .lod3,
                .enable_caves = false,
                .enable_worm_caves = false,
                .enable_decorations = false,
                .enable_ores = false,
                .enable_lighting = false,
                .octave_reduction = 3, // Maximum simplification
                .skip_biome_blending = true,
            },
        };
    }
};

pub const GeneratorInfo = struct {
    /// Human-readable name of the generator (e.g. "Overworld").
    /// Displayed in the UI. Should be kept relatively short (under 32 chars recommended).
    name: []const u8,
    /// Description of the generator's features and purpose.
    description: []const u8,
};

/// Pluggable generator interface.
/// Uses a VTable for runtime polymorphism.
pub const Generator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    info: GeneratorInfo,

    pub const VTable = struct {
        /// Generate a full chunk of terrain.
        /// Implementations MUST:
        /// 1. Set chunk.generated = false at the very beginning of the function.
        /// 2. Respect the stop_flag (if provided) by returning early without setting chunk.generated = true.
        /// 3. Set chunk.generated = true ONLY after ALL generation steps (terrain, ores, features, lighting) are complete.
        /// Note: If stop_flag is used to return early, the chunk may be left in a partially modified state.
        /// The chunk.generated = false flag ensures that other systems (like rendering) do not process this incomplete data.
        generate: *const fn (ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) void,

        /// Generate heightmap-only data for LOD levels.
        generateHeightmapOnly: *const fn (ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void,

        /// Periodically check if internal caches should be recentered around the player.
        /// Returns true if any cache was recentered.
        maybeRecenterCache: *const fn (ptr: *anyopaque, player_x: i32, player_z: i32) bool,

        /// Get the world seed used by this generator
        getSeed: *const fn (ptr: *anyopaque) u64,

        /// Get region info for a specific world position
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo,

        /// Get detailed column information for a world position (used for mapping)
        getColumnInfo: *const fn (ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo,

        /// Clean up generator resources.
        /// This MUST be called to free any memory or resources allocated by the generator.
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn generate(self: Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        self.vtable.generate(self.ptr, chunk, stop_flag);
    }

    pub fn generateHeightmapOnly(self: Generator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        self.vtable.generateHeightmapOnly(self.ptr, data, region_x, region_z, lod_level);
    }

    pub fn maybeRecenterCache(self: Generator, player_x: i32, player_z: i32) bool {
        return self.vtable.maybeRecenterCache(self.ptr, player_x, player_z);
    }

    pub fn getSeed(self: Generator) u64 {
        return self.vtable.getSeed(self.ptr);
    }

    pub fn getRegionInfo(self: Generator, world_x: i32, world_z: i32) RegionInfo {
        return self.vtable.getRegionInfo(self.ptr, world_x, world_z);
    }

    pub fn getColumnInfo(self: Generator, wx: f32, wz: f32) ColumnInfo {
        return self.vtable.getColumnInfo(self.ptr, wx, wz);
    }

    pub fn deinit(self: Generator, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};
