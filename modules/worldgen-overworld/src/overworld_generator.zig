//! Terrain generator orchestrator for Luanti-style phased worldgen.
//! Phase responsibilities are delegated to dedicated subsystems.

const std = @import("std");
const sync = @import("sync");
const log = @import("engine-core").log;
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const RegionMood = region_pkg.RegionMood;
const world_class = @import("world_class.zig");
const ContinentalZone = world_class.ContinentalZone;
const SurfaceType = world_class.SurfaceType;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
const gen_region = @import("gen_region.zig");
const gen_interface = @import("worldgen-api");
const Generator = gen_interface.Generator;
const GeneratorInfo = gen_interface.GeneratorInfo;
const WorldgenError = gen_interface.WorldgenError;
const ColumnInfo = gen_interface.ColumnInfo;
const MapSample = gen_interface.MapSample;

const terrain_shape_mod = @import("terrain_shape_generator.zig");
const TerrainShapeGenerator = terrain_shape_mod.TerrainShapeGenerator;
const NoiseSampler = terrain_shape_mod.NoiseSampler;
const HeightSampler = terrain_shape_mod.HeightSampler;
const SurfaceBuilder = terrain_shape_mod.SurfaceBuilder;
const CoastalSurfaceType = terrain_shape_mod.CoastalSurfaceType;
const BiomeSource = @import("biome.zig").BiomeSource;
const BiomeDecorator = @import("biome_decorator.zig").BiomeDecorator;
const LightingComputer = @import("worldgen-common").LightingComputer;
const Mutex = sync.Mutex;

pub const OverworldGenerator = struct {
    pub const INFO = GeneratorInfo{
        .name = "Overworld",
        .description = "Standard terrain with diverse biomes and caves.",
        .version = 3,
    };

    allocator: std.mem.Allocator,
    cache_center_x: i32,
    cache_center_z: i32,
    cache_mutex: Mutex,
    terrain_shape: TerrainShapeGenerator,
    biome_decorator: BiomeDecorator,
    basic_chunks_only: bool,

    /// Distance threshold for cache recentering (blocks).
    pub const CACHE_RECENTER_THRESHOLD: i32 = 512;

    pub const InitParams = struct {
        terrain_shape: terrain_shape_mod.Params = .{},
        basic_chunks_only: bool = false,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider) OverworldGenerator {
        return initWithParams(seed, allocator, decoration_provider, .{});
    }

    pub fn initWithParams(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider, params: InitParams) OverworldGenerator {
        return .{
            .allocator = allocator,
            .cache_center_x = 0,
            .cache_center_z = 0,
            .cache_mutex = .{},
            .terrain_shape = TerrainShapeGenerator.initWithParams(seed, params.terrain_shape),
            .biome_decorator = BiomeDecorator.init(seed, decoration_provider),
            .basic_chunks_only = params.basic_chunks_only,
        };
    }

    /// Release owned resources before the struct is destroyed.
    ///
    /// All fields of `OverworldGenerator` are inline value types with no heap
    /// allocations (`cache_mutex` is an inline primitive, and `terrain_shape` /
    /// `biome_decorator` own no heap memory), so there is nothing to free here
    /// today. This hook is still invoked by `deinitWrapper` so that any future
    /// heap-owning field is cleaned up through the erased `Generator` interface
    /// instead of leaking silently.
    pub fn deinit(self: *OverworldGenerator) void {
        _ = self;
    }

    pub fn getNoiseSampler(self: *const OverworldGenerator) *const NoiseSampler {
        return self.terrain_shape.getNoiseSampler();
    }

    pub fn getHeightSampler(self: *const OverworldGenerator) *const HeightSampler {
        return self.terrain_shape.getHeightSampler();
    }

    pub fn getSurfaceBuilder(self: *const OverworldGenerator) *const SurfaceBuilder {
        return self.terrain_shape.getSurfaceBuilder();
    }

    pub fn getBiomeSource(self: *const OverworldGenerator) *const BiomeSource {
        return self.terrain_shape.getBiomeSource();
    }

    pub fn getSeed(self: *const OverworldGenerator) u64 {
        return self.terrain_shape.getSeed();
    }

    pub fn getRegionInfo(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionInfo {
        return self.terrain_shape.getRegionInfo(world_x, world_z);
    }

    pub fn getMood(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionMood {
        return self.getRegionInfo(world_x, world_z).mood;
    }

    pub fn getColumnInfo(self: *const OverworldGenerator, wx: f32, wz: f32) ColumnInfo {
        return self.getColumnInfoReduced(wx, wz, 0);
    }

    pub fn getColumnInfoReduced(self: *const OverworldGenerator, wx: f32, wz: f32, reduction: u8) ColumnInfo {
        const column = self.terrain_shape.sampleColumnData(wx, wz, @min(reduction, 4));
        return .{
            .height = column.terrain_height_i,
            .biome = self.selectColumnBiome(column),
            .is_ocean = column.continentalness < self.terrain_shape.getOceanThreshold(),
            .temperature = column.temperature,
            .humidity = column.humidity,
            .continentalness = column.continentalness,
        };
    }

    /// Samples terrain, biome, climate, and water in one terrain-shape query.
    /// Rivers remain encoded by the biome and river mask.
    pub fn getMapSampleReduced(self: *const OverworldGenerator, wx: f32, wz: f32, reduction: u8) MapSample {
        const column = self.terrain_shape.sampleMapColumnData(wx, wz, @min(reduction, 4));
        return .{
            .terrain_height = column.terrain_height_i,
            .biome = self.selectColumnBiome(column),
            .water = classifyMapWater(column),
            .sea_level = self.terrain_shape.getSeaLevel(),
            .temperature = column.temperature,
            .humidity = column.humidity,
            .continentalness = column.continentalness,
            .river_mask = column.river_mask,
            .ridge_mask = column.ridge_mask,
        };
    }

    fn selectColumnBiome(self: *const OverworldGenerator, column: terrain_shape_mod.ColumnData) BiomeId {
        const climate = self.terrain_shape.biome_source.computeClimate(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            CHUNK_SIZE_Y,
        );

        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = 1,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };
        return self.terrain_shape.biome_source.selectBiome(climate, structural, column.river_mask);
    }

    fn classifyMapWater(column: terrain_shape_mod.ColumnData) gen_interface.MapWaterClassification {
        if (!column.is_underwater) return .none;
        // sampleColumnData already computed warped, coast-jittered
        // continentalness. Re-running the full-resolution warp and continent
        // noise here doubled the expensive work for every underwater inland
        // sample without adding useful map detail.
        return if (column.is_ocean) .ocean else .inland;
    }

    pub fn generate(self: *OverworldGenerator, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void {
        chunk.generated = false;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const cache_center = blk: {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

            const dx = @as(i128, world_x) - @as(i128, self.cache_center_x);
            const dz = @as(i128, world_z) - @as(i128, self.cache_center_z);
            const threshold: i128 = CACHE_RECENTER_THRESHOLD;
            if (dx * dx + dz * dz > threshold * threshold) {
                self.cache_center_x = world_x;
                self.cache_center_z = world_z;
            }

            break :blk .{ .x = self.cache_center_x, .z = self.cache_center_z };
        };

        const phase_data = try self.allocator.create(terrain_shape_mod.ChunkPhaseData);
        defer self.allocator.destroy(phase_data);
        if (!self.terrain_shape.prepareChunkPhaseData(
            phase_data,
            world_x,
            world_z,
            cache_center.x,
            cache_center.z,
            stop_flag,
        )) return;

        var worm_map_opt = if (self.terrain_shape.params.disable_caves)
            null
        else
            self.terrain_shape.generateWormCaves(
                chunk,
                &phase_data.surface_heights,
                self.allocator,
            ) catch null;
        defer if (worm_map_opt) |*map| map.deinit();
        const worm_map_ptr: ?*const terrain_shape_mod.CaveCarveMap = if (worm_map_opt) |*map| map else null;

        if (!self.terrain_shape.fillChunkBlocks(chunk, phase_data, worm_map_ptr, stop_flag)) return;
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            self.biome_decorator.generateOres(chunk);
            if (stop_flag) |sf| if (sf.*) return;
            self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
            if (stop_flag) |sf| if (sf.*) return;
        }
        LightingComputer.computeSkylight(chunk, self.allocator) catch |err| {
            log.log.errWithTrace("Failed to compute skylight for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
            return err;
        };
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            LightingComputer.computeBlockLight(chunk, self.allocator) catch |err| {
                log.log.errWithTrace("Failed to compute block light for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
                return err;
            };
        }

        chunk.generated = true;
        chunk.dirty = true;
    }

    pub fn generateFeatures(self: *const OverworldGenerator, chunk: *Chunk) void {
        if (self.basic_chunks_only) return;
        self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
    }

    pub fn isOceanWater(self: *const OverworldGenerator, wx: f32, wz: f32) bool {
        return self.terrain_shape.isOceanWater(wx, wz);
    }

    pub fn isInlandWater(self: *const OverworldGenerator, wx: f32, wz: f32, height: i32) bool {
        return self.terrain_shape.isInlandWater(wx, wz, height);
    }

    pub fn getContinentalZone(self: *const OverworldGenerator, c: f32) ContinentalZone {
        return self.terrain_shape.getContinentalZone(c);
    }

    fn registrySurfaceBlock(biome_id: BiomeId) BlockType {
        return biome_mod.getBiomeDefinition(biome_id).surface.top;
    }

    fn surfaceTypeForBlock(block: BlockType) SurfaceType {
        return switch (block) {
            .sand, .red_sand => .sand,
            .snow_block, .ice, .packed_ice, .blue_ice => .snow,
            .stone, .cobblestone, .mossy_cobblestone => .stone,
            .gravel => .rock,
            .dirt, .coarse_dirt, .rooted_dirt, .podzol, .mud, .mycelium => .dirt,
            .water => .water_shallow,
            else => .grass,
        };
    }

    fn deriveSurfaceTypeInternal(
        _: *const OverworldGenerator,
        biome_id: BiomeId,
        height: i32,
        sea_level: i32,
        is_ocean: bool,
        coastal_type: CoastalSurfaceType,
    ) SurfaceType {
        if (is_ocean and height < sea_level - 30) return .water_deep;
        if (is_ocean and height < sea_level) return .water_shallow;

        switch (coastal_type) {
            .sand_beach => return .sand,
            .gravel_beach => return .rock,
            .cliff => return .stone,
            .none => {},
        }

        const surface_block = registrySurfaceBlock(biome_id);
        if ((biome_id == .mountains or biome_id == .jagged_peaks or biome_id == .stony_peaks) and height > 120) return .rock;
        return surfaceTypeForBlock(surface_block);
    }

    pub fn generator(self: *OverworldGenerator) Generator {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
            .info = INFO,
        };
    }

    const VTABLE = Generator.VTable{
        .generate = generateWrapper,
        .getSeed = getSeedWrapper,
        .getRegionInfo = getRegionInfoWrapper,
        .getColumnInfo = getColumnInfoWrapper,
        .getColumnInfoReduced = getColumnInfoReducedWrapper,
        .getMapSampleReduced = getMapSampleReducedWrapper,
        .column_info_thread_safe = true,
        .deinit = deinitWrapper,
    };

    fn generateWrapper(ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        try self.generate(chunk, stop_flag);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn getColumnInfoReducedWrapper(ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) ColumnInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfoReduced(wx, wz, reduction);
    }

    fn getMapSampleReducedWrapper(ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) MapSample {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getMapSampleReduced(wx, wz, reduction);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }
};

fn testDecorationProvider() DecorationProvider {
    const NoopProvider = struct {
        fn decorate(_: ?*anyopaque, _: DecorationProvider.DecorationContext) void {}

        const VTABLE = DecorationProvider.VTable{
            .decorate = decorate,
        };
    };

    return .{ .ptr = null, .vtable = &NoopProvider.VTABLE };
}

test "OverworldGenerator propagates phase allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var gen = OverworldGenerator.initWithParams(0, failing.allocator(), testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    var chunk = Chunk.init(0, 0);
    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}

test "OverworldGenerator propagates lighting allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var gen = OverworldGenerator.initWithParams(0, failing.allocator(), testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    var chunk = Chunk.init(0, 0);
    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}
