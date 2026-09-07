const std = @import("std");
const world_core = @import("world-core");

const Chunk = world_core.Chunk;
const BiomeId = world_core.BiomeId;

pub const RegionMood = enum {
    calm,
    sparse,
    lush,
    wild,
};

pub const RegionRole = enum {
    transit,
    destination,
    boundary,
};

pub const FeatureFocus = enum {
    none,
    lake,
    forest,
    mountain,
};

pub const RegionInfo = struct {
    mood: RegionMood,
    role: RegionRole,
    focus: FeatureFocus,
    center_x: i32,
    center_z: i32,
};

pub const ColumnInfo = struct {
    height: i32,
    biome: BiomeId,
    is_ocean: bool,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
};

/// The water covering a map sample's terrain surface.
///
/// Rivers are intentionally not a separate water class: generators may expose
/// them through `MapSample.biome` and `MapSample.river_mask` instead.
pub const MapWaterClassification = enum {
    /// No ocean or inland water covers the sampled terrain.
    none,
    /// Terrain below sea level that belongs to the ocean.
    ocean,
    /// Terrain below sea level that is not ocean water.
    inland,
};

/// Stable, map-oriented data for one world column.
///
/// `terrain_height` is the solid terrain surface, rather than a water-surface
/// height. `sea_level` is the block Y coordinate used for water classification.
/// Climate values and masks are normalized to the 0..1 range. A terrain height
/// equal to `sea_level` is not classified as water.
pub const MapSample = struct {
    terrain_height: i32,
    biome: BiomeId,
    water: MapWaterClassification,
    sea_level: i32,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
    river_mask: f32,
    ridge_mask: f32,
};

pub const GeneratorInfo = struct {
    name: []const u8,
    description: []const u8,
    version: u32,
};

pub const Generator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    info: GeneratorInfo,

    pub const VTable = struct {
        generate: *const fn (ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void,
        getSeed: *const fn (ptr: *anyopaque) u64,
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo,
        getColumnInfo: *const fn (ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo,
        getColumnInfoReduced: ?*const fn (ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) ColumnInfo = null,
        getMapSampleReduced: ?*const fn (ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) MapSample = null,
        /// Allows concurrent calls to column-info and map-sampling methods on
        /// the same generator pointer.
        column_info_thread_safe: bool = false,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn generate(self: Generator, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void {
        try self.vtable.generate(self.ptr, chunk, stop_flag);
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

    /// Returns map-oriented column data when the generator supports it.
    /// Generators without a reduced sampler retain their existing behavior.
    pub fn getColumnInfoReduced(self: Generator, wx: f32, wz: f32, reduction: u8) ColumnInfo {
        const reduced = self.vtable.getColumnInfoReduced orelse return self.getColumnInfo(wx, wz);
        return reduced(self.ptr, wx, wz, reduction);
    }

    /// Returns map-oriented data at the requested sampling reduction.
    ///
    /// Generators without a dedicated sampler use column information with the
    /// legacy sea level of 64. The fallback only classifies terrain below that
    /// level, and treats non-ocean water as inland.
    pub fn getMapSampleReduced(self: Generator, wx: f32, wz: f32, reduction: u8) MapSample {
        const sample_fn = self.vtable.getMapSampleReduced orelse {
            const column = self.getColumnInfoReduced(wx, wz, reduction);
            return .{
                .terrain_height = column.height,
                .biome = column.biome,
                .water = if (column.height < 64)
                    if (column.is_ocean) .ocean else .inland
                else
                    .none,
                .sea_level = 64,
                .temperature = column.temperature,
                .humidity = column.humidity,
                .continentalness = column.continentalness,
                .river_mask = 0.0,
                .ridge_mask = 0.0,
            };
        };
        return sample_fn(self.ptr, wx, wz, reduction);
    }

    pub fn deinit(self: Generator, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const CreateContext = struct {
    seed: u64,
    allocator: std.mem.Allocator,
};

pub const RegistryError = error{
    InvalidGeneratorIndex,
    InvalidGeneratorId,
    OutOfMemory,
};

pub const WorldgenError = error{
    OutOfMemory,
};

pub const GeneratorDescriptor = struct {
    id: []const u8,
    aliases: []const []const u8 = &.{},
    info: GeneratorInfo,
    create: *const fn (context: CreateContext) RegistryError!Generator,
};
