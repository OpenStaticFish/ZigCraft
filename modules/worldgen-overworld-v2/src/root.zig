//! Overworld V2 terrain generator.
//!
//! Terrain equations, default noise parameters, river channel shaping, mountain
//! density, and noise-intersection caves are ported from Luanti mapgen v7:
//! https://github.com/luanti-org/luanti/blob/master/src/mapgen/mapgen_v7.cpp
//! Luanti source is LGPL-2.1-or-later; its noise helpers are BSD-style licensed.

const std = @import("std");
const worldgen_api = @import("worldgen-api");
const world_core = @import("world-core");
const LightingComputer = @import("worldgen-common").LightingComputer;
const biomes = @import("biomes.zig");
const block_colors = @import("block_colors.zig");
const caves = @import("caves.zig");
const climate = @import("climate.zig");
const noise = @import("noise.zig");
const terrain_shape = @import("terrain_shape.zig");
const trees = @import("trees.zig");
const util = @import("util.zig");
const vegetation = @import("vegetation.zig");

const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const Generator = worldgen_api.Generator;
const GeneratorInfo = worldgen_api.GeneratorInfo;
const ColumnInfo = worldgen_api.ColumnInfo;
const RegionInfo = worldgen_api.RegionInfo;
const fillerBlock = block_colors.fillerBlock;
const surfaceBlock = block_colors.surfaceBlock;

const MGV7_MOUNTAINS: u32 = 0x01;
const MGV7_RIDGES: u32 = 0x02;
const MGV7_CAVERNS: u32 = 0x08;
const DEFAULT_SPFLAGS: u32 = MGV7_MOUNTAINS | MGV7_RIDGES | MGV7_CAVERNS;

const Vec3f = noise.Vec3f;
const LuantiNoiseParams = noise.LuantiNoiseParams;
const ClimateSample = climate.ClimateSample;

const ColumnSample = struct {
    terrain_height: i32,
    base_height: i32,
    biome: BiomeId,
    is_river: bool,
    is_ocean: bool,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
};

const TreeShape = trees.TreeShape;

pub const OverworldV2Generator = struct {
    pub const INFO = GeneratorInfo{
        .name = "Overworld V2",
        .description = "Luanti v7-style terrain with ridges, mountains, rivers, and cave noise.",
        .version = 3,
    };

    pub const Params = struct {
        sea_level: i32 = 64,
        spflags: u32 = DEFAULT_SPFLAGS,
        mount_zero_level: i32 = 0,
        cave_width: f32 = 0.09,
        enable_lighting: bool = true,
    };

    seed: u64,
    seed32: i32,
    allocator: std.mem.Allocator,
    params: Params,

    noise_terrain_base: LuantiNoiseParams,
    noise_terrain_alt: LuantiNoiseParams,
    noise_terrain_persist: LuantiNoiseParams,
    noise_height_select: LuantiNoiseParams,
    noise_filler_depth: LuantiNoiseParams,
    noise_mount_height: LuantiNoiseParams,
    noise_ridge_uwater: LuantiNoiseParams,
    noise_mountain: LuantiNoiseParams,
    noise_ridge: LuantiNoiseParams,
    noise_cave1: LuantiNoiseParams,
    noise_cave2: LuantiNoiseParams,
    noise_temperature: LuantiNoiseParams,
    noise_humidity: LuantiNoiseParams,

    pub fn init(seed: u64, allocator: std.mem.Allocator) OverworldV2Generator {
        return initWithParams(seed, allocator, .{});
    }

    pub fn initWithParams(seed: u64, allocator: std.mem.Allocator, params: Params) OverworldV2Generator {
        const seed32_u: u32 = @truncate(seed);
        const seed32: i32 = @bitCast(seed32_u);
        return .{
            .seed = seed,
            .seed32 = seed32,
            .allocator = allocator,
            .params = params,
            .noise_terrain_base = noise.np(4.0, 70.0, Vec3f.uniform(600), 82341, 5, 0.6, 2.0),
            .noise_terrain_alt = noise.np(4.0, 25.0, Vec3f.uniform(600), 5934, 5, 0.6, 2.0),
            .noise_terrain_persist = noise.np(0.6, 0.1, Vec3f.uniform(2000), 539, 3, 0.6, 2.0),
            .noise_height_select = noise.np(-8.0, 16.0, Vec3f.uniform(500), 4213, 6, 0.7, 2.0),
            .noise_filler_depth = noise.np(0.0, 1.2, Vec3f.uniform(150), 261, 3, 0.7, 2.0),
            .noise_mount_height = noise.np(256.0, 112.0, Vec3f.uniform(1000), 72449, 3, 0.6, 2.0),
            .noise_ridge_uwater = noise.np(0.0, 1.0, Vec3f.uniform(1000), 85039, 5, 0.6, 2.0),
            .noise_mountain = noise.np(-0.6, 1.0, .{ .x = 250, .y = 350, .z = 250 }, 5333, 5, 0.63, 2.0),
            .noise_ridge = noise.np(0.0, 1.0, Vec3f.uniform(100), 6467, 4, 0.75, 2.0),
            .noise_cave1 = noise.np(0.0, 12.0, Vec3f.uniform(61), 52534, 3, 0.5, 2.0),
            .noise_cave2 = noise.np(0.0, 12.0, Vec3f.uniform(67), 10325, 3, 0.5, 2.0),
            .noise_temperature = noise.np(0.0, 1.0, Vec3f.uniform(1400), 9130, 3, 0.55, 2.0),
            .noise_humidity = noise.np(0.0, 1.0, Vec3f.uniform(1200), 9171, 3, 0.55, 2.0),
        };
    }

    pub fn deinit(self: *OverworldV2Generator) void {
        // No owned heap allocations; allocator is stored only for per-call lighting work.
        _ = self;
    }

    pub fn generate(self: *OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) worldgen_api.WorldgenError!void {
        chunk.generated = false;
        @memset(&chunk.blocks, .air);
        @memset(&chunk.biomes, .plains);
        @memset(&chunk.heightmap, 0);

        const world_x0 = chunk.getWorldX();
        const world_z0 = chunk.getWorldZ();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx = util.addWorldOffset(world_x0, local_x);
                const wz = util.addWorldOffset(world_z0, local_z);
                const sample = self.sampleColumn(wx, wz);
                self.fillRawTerrainColumn(chunk, local_x, local_z, wx, wz, sample.base_height);
                self.applyBiomeSurfaceColumn(chunk, local_x, local_z, wx, wz, sample);
                if (self.params.spflags & MGV7_CAVERNS != 0) {
                    self.carveNoiseCavesColumn(chunk, local_x, local_z, wx, wz, sample.terrain_height);
                }
                const actual_height = highestSolidY(chunk, local_x, local_z, sample.terrain_height);
                chunk.setSurfaceHeight(local_x, local_z, @intCast(actual_height));
                chunk.biomes[local_x + local_z * CHUNK_SIZE_X] = sample.biome;
            }
        }

        self.placeTrees(chunk, stop_flag);
        self.placeVegetation(chunk, stop_flag);

        if (self.params.enable_lighting) {
            try LightingComputer.computeSkylight(chunk, self.allocator);
        }

        chunk.generated = true;
        chunk.dirty = true;
        chunk.modified = false;
    }

    fn placeTrees(self: *const OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        trees.placeTrees(self, chunk, stop_flag);
    }

    fn treeForColumn(self: *const OverworldV2Generator, biome: BiomeId, wx: i32, wz: i32) ?TreeShape {
        return trees.treeForColumn(self, biome, wx, wz);
    }

    fn placeVegetation(self: *const OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        vegetation.placeVegetation(self, chunk, stop_flag);
    }

    fn fillRawTerrainColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, base_surface_y: i32) void {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const yi: i32 = @intCast(y);
            const block: BlockType = if (yi == 0)
                .bedrock
            else if (self.isTerrainStone(wx, yi, wz, base_surface_y))
                .stone
            else if (yi <= self.params.sea_level)
                .water
            else
                .air;
            chunk.blocks[Chunk.getIndex(local_x, y, local_z)] = block;
        }
    }

    fn applyBiomeSurfaceColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, sample: ColumnSample) void {
        const filler_depth = self.fillerDepth(wx, wz);
        var layer_depth: i32 = -1;
        var above: BlockType = .air;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 1) : (y -= 1) {
            const uy: u32 = @intCast(y);
            const idx = Chunk.getIndex(local_x, uy, local_z);
            const block = chunk.blocks[idx];

            if (block != .stone) {
                layer_depth = -1;
                above = block;
                continue;
            }

            if (above == .air or above == .water) {
                layer_depth = 0;
            }

            if (layer_depth >= 0) {
                const underwater = above == .water;
                chunk.blocks[idx] = if (layer_depth == 0)
                    surfaceBlock(sample.biome, sample.terrain_height, self.params.sea_level, underwater)
                else if (layer_depth <= filler_depth)
                    fillerBlock(sample.biome, underwater)
                else
                    .stone;
                layer_depth += 1;
            }

            above = chunk.blocks[idx];
        }
    }

    fn carveNoiseCavesColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, terrain_height: i32) void {
        caves.carveNoiseCavesColumn(self, chunk, local_x, local_z, wx, wz, terrain_height);
    }

    fn isTerrainStone(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32, base_surface_y: i32) bool {
        return terrain_shape.isTerrainStone(self, wx, y, wz, base_surface_y);
    }

    fn sampleColumn(self: *const OverworldV2Generator, wx: i32, wz: i32) ColumnSample {
        const base_height = util.floorToI32(self.baseTerrainLevelAtPoint(wx, wz));
        const terrain_height = self.estimateTerrainHeight(wx, wz, base_height);
        const climate_sample = self.sampleClimate(wx, wz);
        const river = self.isRiverColumn(wx, wz) and terrain_height >= self.params.sea_level - 18 and terrain_height <= self.params.sea_level + 1;
        const biome = self.selectBiome(wx, wz, terrain_height, river, climate_sample.temperature, climate_sample.humidity);
        const continentalness = std.math.clamp((@as(f32, @floatFromInt(terrain_height - self.params.sea_level)) + 56.0) / 150.0, 0.0, 1.0);
        return .{
            .terrain_height = terrain_height,
            .base_height = base_height,
            .biome = biome,
            .is_river = river,
            .is_ocean = terrain_height < self.params.sea_level - 2,
            .temperature = climate_sample.temperature,
            .humidity = climate_sample.humidity,
            .continentalness = continentalness,
        };
    }

    fn estimateTerrainHeight(self: *const OverworldV2Generator, wx: i32, wz: i32, base_surface_y: i32) i32 {
        return terrain_shape.estimateTerrainHeight(self, wx, wz, base_surface_y);
    }

    fn baseTerrainLevelAtPoint(self: *const OverworldV2Generator, wx: i32, wz: i32) f32 {
        return terrain_shape.baseTerrainLevelAtPoint(self, wx, wz);
    }

    fn getMountainTerrainAt(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32) bool {
        return terrain_shape.getMountainTerrainAt(self, wx, y, wz);
    }

    fn getRiverChannelAt(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32) bool {
        return terrain_shape.getRiverChannelAt(self, wx, y, wz);
    }

    fn isRiverColumn(self: *const OverworldV2Generator, wx: i32, wz: i32) bool {
        return terrain_shape.isRiverColumn(self, wx, wz);
    }

    fn fillerDepth(self: *const OverworldV2Generator, wx: i32, wz: i32) i32 {
        return terrain_shape.fillerDepth(self, wx, wz);
    }

    fn sampleClimate(self: *const OverworldV2Generator, wx: i32, wz: i32) ClimateSample {
        return climate.sampleClimate(self, wx, wz);
    }

    fn selectBiome(self: *const OverworldV2Generator, wx: i32, wz: i32, height: i32, river: bool, temperature: f32, humidity: f32) BiomeId {
        return biomes.selectBiome(self, wx, wz, height, river, temperature, humidity);
    }

    fn isBeachColumn(self: *const OverworldV2Generator, wx: i32, wz: i32, height: i32) bool {
        return biomes.isBeachColumn(self, wx, wz, height);
    }

    pub fn getSeed(self: *const OverworldV2Generator) u64 {
        return self.seed;
    }

    pub fn getRegionInfo(self: *const OverworldV2Generator, world_x: i32, world_z: i32) RegionInfo {
        const sample = self.sampleColumn(world_x, world_z);
        const focus: worldgen_api.FeatureFocus = if (sample.is_river)
            .lake
        else if (sample.terrain_height > self.params.sea_level + 60)
            .mountain
        else
            .none;
        const mood: worldgen_api.RegionMood = if (sample.is_ocean)
            .sparse
        else if (sample.humidity > 0.7)
            .lush
        else if (sample.terrain_height > self.params.sea_level + 70)
            .wild
        else
            .calm;
        return .{ .mood = mood, .role = .destination, .focus = focus, .center_x = world_x, .center_z = world_z };
    }

    pub fn getColumnInfo(self: *const OverworldV2Generator, wx: f32, wz: f32) ColumnInfo {
        const sample = self.sampleColumn(util.floorToI32(wx), util.floorToI32(wz));
        return .{
            .height = sample.terrain_height,
            .biome = sample.biome,
            .is_ocean = sample.is_ocean,
            .temperature = sample.temperature,
            .humidity = sample.humidity,
            .continentalness = sample.continentalness,
        };
    }

    pub fn generator(self: *OverworldV2Generator) Generator {
        return .{ .ptr = self, .vtable = &VTABLE, .info = INFO };
    }

    fn verticalShift(self: *const OverworldV2Generator) i32 {
        return terrain_shape.verticalShift(self);
    }

    fn toLuantiY(self: *const OverworldV2Generator, y: i32) f32 {
        return terrain_shape.toLuantiY(self, y);
    }

    const VTABLE = Generator.VTable{
        .generate = generateWrapper,
        .getSeed = getSeedWrapper,
        .getRegionInfo = getRegionInfoWrapper,
        .getColumnInfo = getColumnInfoWrapper,
        .column_info_thread_safe = true,
        .deinit = deinitWrapper,
    };

    fn generateWrapper(ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) worldgen_api.WorldgenError!void {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        try self.generate(chunk, stop_flag);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

fn highestSolidY(chunk: *const Chunk, local_x: u32, local_z: u32, max_y: i32) i32 {
    var y: i32 = @min(max_y, CHUNK_SIZE_Y - 1);
    while (y >= 0) : (y -= 1) {
        const block = chunk.getBlock(local_x, @intCast(y), local_z);
        if (block != .air and block != .water) return y;
    }
    return 0;
}

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!Generator {
    const gen = context.allocator.create(OverworldV2Generator) catch return error.OutOfMemory;
    gen.* = OverworldV2Generator.init(context.seed, context.allocator);
    return gen.generator();
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:overworld-v2",
    .aliases = &.{ "overworld-v2", "v2", "v7" },
    .info = OverworldV2Generator.INFO,
    .create = create,
};

test "overworld-v2 deterministic terrain columns" {
    var gen = OverworldV2Generator.init(42, std.testing.allocator);
    const a = gen.getColumnInfo(128.0, -96.0);
    const b = gen.getColumnInfo(128.0, -96.0);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(a.biome, b.biome);
}

test "overworld-v2 generates a chunk" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);
    var chunk = Chunk.init(0, 0);
    try gen.generate(&chunk, null);
    try std.testing.expect(chunk.generated);
    try std.testing.expect(chunk.getBlock(0, 0, 0) == .bedrock);
    try std.testing.expect(chunk.getSurfaceHeight(8, 8) > 0);
}

test "overworld-v2 places trees in forested chunks" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);

    var tree_blocks: u32 = 0;
    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 4, -3 },
        .{ -6, 5 },
        .{ 9, 2 },
    };

    for (positions) |pos| {
        var chunk = Chunk.init(pos[0], pos[1]);
        try gen.generate(&chunk, null);
        for (chunk.blocks) |block| {
            if (trees.isTreeBlock(block)) tree_blocks += 1;
        }
    }

    try std.testing.expect(tree_blocks > 0);
}

test "overworld-v2 places ground vegetation" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);

    var vegetation_blocks: u32 = 0;
    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 4, -3 },
        .{ -6, 5 },
        .{ 9, 2 },
    };

    for (positions) |pos| {
        var chunk = Chunk.init(pos[0], pos[1]);
        try gen.generate(&chunk, null);
        for (chunk.blocks) |block| {
            if (vegetation.isVegetationBlock(block)) vegetation_blocks += 1;
        }
    }

    try std.testing.expect(vegetation_blocks > 0);
}

test "overworld-v2 propagates lighting allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var gen = OverworldV2Generator.init(0, failing.allocator());
    var chunk = Chunk.init(0, 0);

    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}
