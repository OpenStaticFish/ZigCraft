const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const Mat4 = @import("zig-math").Mat4;
const world_core = @import("world-core");
const world_worldgen = @import("world-worldgen");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const block_registry = world_core.block_registry;
const BiomeId = world_core.BiomeId;
const OverworldGenerator = world_worldgen.test_generators.OverworldGenerator;
const deco_registry = world_worldgen.decoration_registry;
const NoiseSampler = world_worldgen.NoiseSampler;
const HeightSampler = world_worldgen.HeightSampler;
const SurfaceBuilder = world_worldgen.SurfaceBuilder;
const CoastalSurfaceType = world_worldgen.surface_builder.CoastalSurfaceType;
const BiomeSource = world_worldgen.biome.BiomeSource;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const OverworldV2Generator = world_worldgen.test_generators.OverworldV2Generator;

pub const std_options: std.Options = .{ .log_level = .err };

fn chunkFingerprint(chunk: *const Chunk) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&chunk.blocks));
    hasher.update(std.mem.asBytes(&chunk.biomes));
    hasher.update(std.mem.asBytes(&chunk.heightmap));
    return hasher.final();
}

test "WorldGen same seed produces identical blocks at origin" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen1.deinit();
    var gen2 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen2.deinit();

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    try gen1.generate(&chunk1, null);
    try gen2.generate(&chunk2, null);

    try testing.expectEqualSlices(BlockType, &chunk1.blocks, &chunk2.blocks);
}

test "WorldGen same seed produces identical biomes at origin" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen1.deinit();
    var gen2 = OverworldGenerator.init(12345, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen2.deinit();

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    try gen1.generate(&chunk1, null);
    try gen2.generate(&chunk2, null);

    try testing.expectEqualSlices(BiomeId, &chunk1.biomes, &chunk2.biomes);
}

test "WorldGen same seed produces identical blocks at different positions" {
    const allocator = testing.allocator;

    const seed: u64 = 54321;

    var gen1 = OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen1.deinit();
    var chunk1a = Chunk.init(0, 0);
    var chunk1b = Chunk.init(1, 0);
    var chunk1c = Chunk.init(0, 1);

    try gen1.generate(&chunk1a, null);
    try gen1.generate(&chunk1b, null);
    try gen1.generate(&chunk1c, null);

    var gen2 = OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen2.deinit();
    var chunk2a = Chunk.init(0, 0);
    var chunk2b = Chunk.init(1, 0);
    var chunk2c = Chunk.init(0, 1);

    try gen2.generate(&chunk2a, null);
    try gen2.generate(&chunk2b, null);
    try gen2.generate(&chunk2c, null);

    try testing.expectEqualSlices(BlockType, &chunk1a.blocks, &chunk2a.blocks);
    try testing.expectEqualSlices(BlockType, &chunk1b.blocks, &chunk2b.blocks);
    try testing.expectEqualSlices(BlockType, &chunk1c.blocks, &chunk2c.blocks);

    try testing.expect(!std.mem.eql(BlockType, &chunk1a.blocks, &chunk1b.blocks));
    try testing.expect(!std.mem.eql(BlockType, &chunk1a.blocks, &chunk1c.blocks));
}

test "WorldGen different seeds produce different blocks" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(11111, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen1.deinit();
    var gen2 = OverworldGenerator.init(99999, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen2.deinit();

    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    try gen1.generate(&chunk1, null);
    try gen2.generate(&chunk2, null);

    const all_same = std.mem.eql(BlockType, &chunk1.blocks, &chunk2.blocks);
    try testing.expect(!all_same);
}

test "WorldGen different seeds produce different biomes" {
    const allocator = testing.allocator;

    var gen1 = OverworldGenerator.init(11111, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen1.deinit();
    var gen2 = OverworldGenerator.init(99999, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen2.deinit();

    const test_locations = [_][2]i32{
        .{ -300, 200 },
        .{ 500, -400 },
        .{ 700, 300 },
        .{ -600, -500 },
        .{ 1000, 1000 },
    };

    var differences_found: u32 = 0;

    for (test_locations) |loc| {
        var chunk1 = Chunk.init(loc[0], loc[1]);
        var chunk2 = Chunk.init(loc[0], loc[1]);

        try gen1.generate(&chunk1, null);
        try gen2.generate(&chunk2, null);

        if (!std.mem.eql(BiomeId, &chunk1.biomes, &chunk2.biomes)) {
            differences_found += 1;
        }
    }

    try testing.expect(differences_found >= 1);
}

test "WorldGen determinism across multiple chunks with same seed" {
    const allocator = testing.allocator;
    const seed: u64 = 987654321;

    var gens = [_]OverworldGenerator{
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider()),
    };
    defer for (&gens) |*gen| gen.deinit();

    var chunks1 = [_]Chunk{
        Chunk.init(0, 0),
        Chunk.init(5, -3),
        Chunk.init(-7, 12),
    };

    var chunks2 = [_]Chunk{
        Chunk.init(0, 0),
        Chunk.init(5, -3),
        Chunk.init(-7, 12),
    };

    for (&gens, 0..) |*gen, i| {
        try gen.generate(&chunks1[i], null);
    }

    for (&gens, 0..) |*gen, i| {
        try gen.generate(&chunks2[i], null);
    }

    for (0..3) |i| {
        try testing.expectEqualSlices(BlockType, &chunks1[i].blocks, &chunks2[i].blocks);
        try testing.expectEqualSlices(BiomeId, &chunks1[i].biomes, &chunks2[i].biomes);
    }
}

test "WorldGen golden output for known seed at origin" {
    const allocator = testing.allocator;

    var gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen.deinit();
    var chunk = Chunk.init(0, 0);

    try gen.generate(&chunk, null);

    try testing.expect(chunk.generated);
    try testing.expect(chunk.dirty);

    const bedrock_present = chunk.getBlock(0, 0, 0) == .bedrock;
    try testing.expect(bedrock_present);

    const surface_height = chunk.getHighestSolidY(8, 8);
    try testing.expect(surface_height > 0);
    try testing.expect(surface_height < CHUNK_SIZE_Y);

    const surface_block = chunk.getBlock(8, surface_height, 8);
    try testing.expect(block_registry.getBlockDefinition(surface_block).is_solid);
}

test "Overworld V2 generator is deterministic" {
    const allocator = testing.allocator;
    var gen1 = OverworldV2Generator.init(4242, allocator);
    var gen2 = OverworldV2Generator.init(4242, allocator);
    var chunk1 = Chunk.init(0, 0);
    var chunk2 = Chunk.init(0, 0);

    try gen1.generate(&chunk1, null);
    try gen2.generate(&chunk2, null);

    try testing.expectEqualSlices(BlockType, &chunk1.blocks, &chunk2.blocks);
    try testing.expectEqualSlices(BiomeId, &chunk1.biomes, &chunk2.biomes);
}

test "Overworld V2 stable chunk fingerprints for known seed" {
    const allocator = testing.allocator;
    const seed: u64 = 424242;
    var gen = OverworldV2Generator.init(seed, allocator);

    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 17, -9 },
        .{ -23, 31 },
    };

    const expected = [_]u64{
        17217192855331184094,
        14865158333412773927,
        9768666648150816461,
    };

    for (positions, 0..) |pos, i| {
        var chunk = Chunk.init(pos[0], pos[1]);
        try gen.generate(&chunk, null);
        const fp = chunkFingerprint(&chunk);
        try testing.expectEqual(expected[i], fp);
    }
}

test "Overworld V2 registry alias resolves" {
    const index = world_worldgen.findGeneratorIndex("overworld-v2") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zigcraft:overworld-v2", world_worldgen.getGeneratorId(index));
}

test "WorldGen stable chunk fingerprints for known seed" {
    const allocator = testing.allocator;
    const seed: u64 = 424242;
    var gen = OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen.deinit();

    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 17, -9 },
        .{ -23, 31 },
    };

    const expected = [_]u64{
        2995571678741719148,
        13866304399676112481,
        7446572877677241388,
    };

    for (positions, 0..) |pos, i| {
        var chunk = Chunk.init(pos[0], pos[1]);
        try gen.generate(&chunk, null);
        const fp = chunkFingerprint(&chunk);
        try testing.expectEqual(expected[i], fp);
    }
}

test "WorldGen populates heightmap and biomes" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen.deinit();
    var chunk = Chunk.init(0, 0);

    try gen.generate(&chunk, null);

    const h = chunk.getSurfaceHeight(8, 8);
    try testing.expect(h > 0);
    try testing.expect(h < CHUNK_SIZE_Y);

    const block_at_surface = chunk.getBlock(8, @intCast(h), 8);
    try testing.expect(block_at_surface != BlockType.air);
    try testing.expect(block_at_surface != BlockType.water);

    const b = chunk.biomes[8 + 8 * 16];
    try testing.expect(@intFromEnum(b) <= 20);
}

test "Decoration placement" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, deco_registry.StandardDecorationProvider.provider());
    defer gen.deinit();
}

test "OverworldGenerator with mock decoration provider" {
    const allocator = std.testing.allocator;
    const DecorationProvider = world_worldgen.DecorationProvider;
    const DecorationContext = world_worldgen.decoration_provider.DecorationProvider.DecorationContext;

    const MockProvider = struct {
        called_count: *usize,

        pub fn provider(called_count: *usize) DecorationProvider {
            return .{
                .ptr = called_count,
                .vtable = &VTABLE,
            };
        }

        const VTABLE = DecorationProvider.VTable{
            .decorate = decorate,
        };

        fn decorate(ptr: ?*anyopaque, ctx: DecorationContext) void {
            _ = ctx;
            const count: *usize = @ptrCast(@alignCast(ptr.?));
            count.* += 1;
        }
    };

    var called_count: usize = 0;
    var gen = OverworldGenerator.init(42, allocator, MockProvider.provider(&called_count));
    defer gen.deinit();

    var chunk = try allocator.create(Chunk);
    defer allocator.destroy(chunk);
    chunk.* = Chunk.init(0, 0);

    var z: u32 = 0;
    while (z < 16) : (z += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) {
            chunk.setSurfaceHeight(x, z, 64);
            chunk.setBlock(x, 64, z, .grass);
            chunk.biomes[x + z * 16] = .plains;
        }
    }

    gen.generateFeatures(chunk);

    try std.testing.expectEqual(@as(usize, 256), called_count);
}

// ============================================================================
// Biome Structural Constraints Tests (Issue #92)
// ============================================================================

test "Biome structural constraints - height filter" {
    const biome_mod = world_worldgen.biome;
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    const snowy_mountains = getBiomeDefinition(.snowy_mountains);
    try testing.expect(snowy_mountains.min_height == 84);

    const climate_low = ClimateParams{
        .temperature = 0.3,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.85,
        .ruggedness = 0.8,
    };
    const structural_low = StructuralParams{
        .height = 50,
        .slope = 5,
        .continentalness = 0.85,
        .ridge_mask = 0.3,
    };
    const biome_at_low_elev = selectBiomeWithConstraints(climate_low, structural_low);
    try testing.expect(biome_at_low_elev != .snowy_mountains);

    const climate_high = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.5,
        .elevation = 0.8,
        .continentalness = 0.85,
        .ruggedness = 0.8,
    };
    const structural_high = StructuralParams{
        .height = 120,
        .slope = 5,
        .continentalness = 0.85,
        .ridge_mask = 0.3,
    };
    const biome_at_high_elev = selectBiomeWithConstraints(climate_high, structural_high);
    try testing.expect(biome_mod.isMountainFamilyTerrainBiome(biome_at_high_elev));
}

test "Biome structural constraints - slope filter" {
    const biome_mod = world_worldgen.biome;
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    const swamp = getBiomeDefinition(.swamp);
    try testing.expect(swamp.max_slope == 3);

    const climate = ClimateParams{
        .temperature = 0.7,
        .humidity = 0.9,
        .elevation = 0.35,
        .continentalness = 0.6,
        .ruggedness = 0.1,
    };
    const structural_steep = StructuralParams{
        .height = 65,
        .slope = 10,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };
    const biome_steep = selectBiomeWithConstraints(climate, structural_steep);
    try testing.expect(biome_steep != .swamp);

    const structural_flat = StructuralParams{
        .height = 65,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };
    const biome_flat = selectBiomeWithConstraints(climate, structural_flat);
    try testing.expect(biome_flat == .swamp);
}

test "Biome structural constraints - desert elevation limit" {
    const biome_mod = world_worldgen.biome;
    const ClimateParams = biome_mod.ClimateParams;
    const StructuralParams = biome_mod.StructuralParams;
    const getBiomeDefinition = biome_mod.getBiomeDefinition;
    const selectBiomeWithConstraints = biome_mod.selectBiomeWithConstraints;

    const desert = getBiomeDefinition(.desert);
    try testing.expect(desert.max_height == 90);

    const climate = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.5,
        .continentalness = 0.8,
        .ruggedness = 0.2,
    };
    const structural_low = StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.8,
        .ridge_mask = 0.1,
    };
    const biome_low = selectBiomeWithConstraints(climate, structural_low);
    try testing.expect(biome_low == .desert);

    const structural_high = StructuralParams{
        .height = 110,
        .slope = 2,
        .continentalness = 0.8,
        .ridge_mask = 0.1,
    };
    const biome_high = selectBiomeWithConstraints(climate, structural_high);
    try testing.expect(biome_high != .desert);
}

// ============================================================================
// Biome Edge Detection Tests (Issue #102)
// ============================================================================

test "needsTransition returns true for important harsh boundary pairs" {
    const biome_mod = world_worldgen.biome;

    try testing.expect(biome_mod.needsTransition(.desert, .forest) == true);
    try testing.expect(biome_mod.needsTransition(.forest, .desert) == true);

    try testing.expect(biome_mod.needsTransition(.desert, .plains) == true);

    try testing.expect(biome_mod.needsTransition(.snow_tundra, .plains) == true);
    try testing.expect(biome_mod.needsTransition(.snow_tundra, .forest) == true);

    try testing.expect(biome_mod.needsTransition(.mountains, .plains) == true);
    try testing.expect(biome_mod.needsTransition(.jagged_peaks, .forest) == true);

    try testing.expect(biome_mod.needsTransition(.swamp, .dark_forest) == true);

    try testing.expect(biome_mod.needsTransition(.badlands, .dark_forest) == true);
    try testing.expect(biome_mod.needsTransition(.wooded_badlands, .plains) == true);
    try testing.expect(biome_mod.needsTransition(.eroded_badlands, .forest) == true);
    try testing.expect(biome_mod.needsTransition(.old_growth_taiga, .dark_forest) == true);
}

test "needsTransition returns false for compatible biomes" {
    const biome_mod = world_worldgen.biome;

    try testing.expect(biome_mod.needsTransition(.plains, .forest) == false);

    try testing.expect(biome_mod.needsTransition(.ocean, .beach) == false);

    try testing.expect(biome_mod.needsTransition(.desert, .desert) == false);
    try testing.expect(biome_mod.needsTransition(.forest, .forest) == false);
}

test "getTransitionBiome returns correct biome for pairs" {
    const biome_mod = world_worldgen.biome;

    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .forest), .dry_plains);
    try testing.expectEqual(biome_mod.getTransitionBiome(.forest, .desert), .dry_plains);

    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .plains), .dry_plains);

    try testing.expectEqual(biome_mod.getTransitionBiome(.snow_tundra, .plains), .taiga);
    try testing.expectEqual(biome_mod.getTransitionBiome(.snow_tundra, .forest), .taiga);

    try testing.expectEqual(biome_mod.getTransitionBiome(.mountains, .plains), .foothills);
    try testing.expectEqual(biome_mod.getTransitionBiome(.jagged_peaks, .forest), .foothills);

    try testing.expectEqual(biome_mod.getTransitionBiome(.swamp, .forest), .marsh);

    try testing.expectEqual(biome_mod.getTransitionBiome(.badlands, .dark_forest), .dry_plains);
    try testing.expectEqual(biome_mod.getTransitionBiome(.wooded_badlands, .plains), .dry_plains);
    try testing.expectEqual(biome_mod.getTransitionBiome(.eroded_badlands, .forest), .dry_plains);
    try testing.expectEqual(biome_mod.getTransitionBiome(.old_growth_taiga, .dark_forest), .taiga);
}

test "getTransitionBiome returns null for compatible pairs" {
    const biome_mod = world_worldgen.biome;

    try testing.expectEqual(biome_mod.getTransitionBiome(.plains, .forest), null);

    try testing.expectEqual(biome_mod.getTransitionBiome(.ocean, .beach), null);

    try testing.expectEqual(biome_mod.getTransitionBiome(.desert, .desert), null);
}

test "EdgeBand enum values are correct" {
    const biome_mod = world_worldgen.biome;

    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.none), 0);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.outer), 1);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.middle), 2);
    try testing.expectEqual(@intFromEnum(biome_mod.EdgeBand.inner), 3);
}

test "Edge detection constants are properly defined" {
    const biome_mod = world_worldgen.biome;

    try testing.expectEqual(biome_mod.EDGE_STEP, 4);

    try testing.expectEqual(biome_mod.EDGE_WIDTH, 12);

    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII.len, 3);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[0], 4);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[1], 8);
    try testing.expectEqual(biome_mod.EDGE_CHECK_RADII[2], 12);
}

test "transition micro biomes are edge injected only" {
    const biome_mod = world_worldgen.biome;
    const transition_biomes = [_]world_worldgen.BiomeId{ .foothills, .marsh, .dry_plains, .coastal_plains };

    for (transition_biomes) |biome_id| {
        const definition = biome_mod.getBiomeDefinition(biome_id);
        try testing.expect(definition.continentalness.min < 0.0);
        try testing.expect(definition.continentalness.max < 0.0);
    }
}

test "BiomeEdgeInfo struct fields" {
    const biome_mod = world_worldgen.biome;

    const edge_info = biome_mod.BiomeEdgeInfo{
        .base_biome = .desert,
        .neighbor_biome = .forest,
        .edge_band = .middle,
    };

    try testing.expectEqual(edge_info.base_biome, .desert);
    try testing.expectEqual(edge_info.neighbor_biome.?, .forest);
    try testing.expectEqual(edge_info.edge_band, .middle);

    const no_edge = biome_mod.BiomeEdgeInfo{
        .base_biome = .plains,
        .neighbor_biome = null,
        .edge_band = .none,
    };

    try testing.expectEqual(no_edge.neighbor_biome, null);
    try testing.expectEqual(no_edge.edge_band, .none);
}

test "Transition rules table has expected entries" {
    const biome_mod = world_worldgen.biome;

    try testing.expect(biome_mod.TRANSITION_RULES.len >= 10);

    var found_desert_forest = false;
    var found_snow_plains = false;
    var found_mountain_plains = false;

    for (biome_mod.TRANSITION_RULES) |rule| {
        if ((rule.biome_a == .desert and rule.biome_b == .forest) or
            (rule.biome_a == .forest and rule.biome_b == .desert))
        {
            found_desert_forest = true;
            try testing.expectEqual(rule.transition, .dry_plains);
        }
        if ((rule.biome_a == .snow_tundra and rule.biome_b == .plains) or
            (rule.biome_a == .plains and rule.biome_b == .snow_tundra))
        {
            found_snow_plains = true;
            try testing.expectEqual(rule.transition, .taiga);
        }
        if ((rule.biome_a == .mountains and rule.biome_b == .plains) or
            (rule.biome_a == .plains and rule.biome_b == .mountains))
        {
            found_mountain_plains = true;
            try testing.expectEqual(rule.transition, .foothills);
        }
    }

    try testing.expect(found_desert_forest);
    try testing.expect(found_snow_plains);
    try testing.expect(found_mountain_plains);
}

// ============================================================================
// Voronoi Biome Selection Tests (Issue #106)
// ============================================================================

test "BiomePoint struct fields" {
    const biome_mod = world_worldgen.biome;

    const point = biome_mod.BiomePoint{
        .id = .desert,
        .heat = 90,
        .humidity = 10,
        .weight = 1.2,
        .min_continental = 0.42,
    };

    try testing.expectEqual(point.id, .desert);
    try testing.expectEqual(@as(f32, 90), point.heat);
    try testing.expectEqual(@as(f32, 10), point.humidity);
    try testing.expectEqual(@as(f32, 1.2), point.weight);
    try testing.expectEqual(@as(f32, 0.42), point.min_continental);
}

test "BIOME_POINTS table has expected biomes" {
    const biome_mod = world_worldgen.biome;

    try testing.expect(biome_mod.BIOME_POINTS.len >= 15);

    var found_desert = false;
    var found_plains = false;
    var found_forest = false;
    var found_snow = false;

    for (biome_mod.BIOME_POINTS) |point| {
        if (point.id == .desert) found_desert = true;
        if (point.id == .plains) found_plains = true;
        if (point.id == .forest) found_forest = true;
        if (point.id == .snow_tundra) found_snow = true;
    }

    try testing.expect(found_desert);
    try testing.expect(found_plains);
    try testing.expect(found_forest);
    try testing.expect(found_snow);
}

test "selectBiomeVoronoi returns desert for hot/dry" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoi(90, 10, 70, 0.5, 0);
    try testing.expectEqual(result, .desert);
}

test "selectBiomeVoronoi returns snow_tundra for cold/dry" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoi(5, 30, 70, 0.5, 0);
    try testing.expectEqual(result, .snow_tundra);
}

test "selectBiomeVoronoi returns ocean for low continentalness" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoi(50, 50, 50, 0.25, 0);
    try testing.expectEqual(result, .ocean);
}

test "selectBiomeVoronoi returns deep_ocean for very low continentalness" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoi(50, 50, 30, 0.10, 0);
    try testing.expectEqual(result, .deep_ocean);
}

test "selectBiomeVoronoi respects height constraints" {
    const biome_mod = world_worldgen.biome;

    const high_result = biome_mod.selectBiomeVoronoi(10, 40, 112, 0.72, 0);
    try testing.expectEqual(high_result, .snowy_mountains);

    const low_result = biome_mod.selectBiomeVoronoi(10, 40, 70, 0.72, 0);
    try testing.expect(low_result != .snowy_mountains);
}

test "selectBiomeVoronoi weight affects selection" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoi(50, 45, 70, 0.5, 0);
    try testing.expectEqual(result, .plains);
}

test "selectBiomeVoronoiWithRiver returns river when mask active" {
    const biome_mod = world_worldgen.biome;

    const result = biome_mod.selectBiomeVoronoiWithRiver(50, 50, 65, 0.5, 0, 0.8);
    try testing.expectEqual(result, .river);

    const no_river = biome_mod.selectBiomeVoronoiWithRiver(50, 50, 65, 0.5, 0, 0.2);
    try testing.expect(no_river != .river);
}

test "selectBiomeWithConstraints uses multi-parameter selection" {
    const biome_mod = world_worldgen.biome;

    const climate = biome_mod.ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = biome_mod.selectBiomeWithConstraints(climate, structural);
    try testing.expectEqual(result, .desert);
}

// ============================================================================
// Issue #147: Modular Terrain Generation Pipeline Tests
// ============================================================================

test "NoiseSampler deterministic output" {
    const sampler = NoiseSampler.init(12345);

    const c1 = sampler.getContinentalness(100.0, 200.0, 0);
    const c2 = sampler.getContinentalness(100.0, 200.0, 0);
    try testing.expectEqual(c1, c2);

    const c3 = sampler.getContinentalness(500.0, 600.0, 0);
    try testing.expect(c1 != c3);
}

test "NoiseSampler values in expected range" {
    const sampler = NoiseSampler.init(42);

    const c = sampler.getContinentalness(0.0, 0.0, 0);
    try testing.expect(c >= 0.0 and c <= 1.0);

    const t = sampler.getTemperature(0.0, 0.0, 0);
    try testing.expect(t >= 0.0 and t <= 1.0);

    const h = sampler.getHumidity(0.0, 0.0, 0);
    try testing.expect(h >= 0.0 and h <= 1.0);
}

test "NoiseSampler batch sampling matches individual" {
    const sampler = NoiseSampler.init(99999);
    const x: f32 = 123.0;
    const z: f32 = 456.0;
    const reduction: u8 = 0;

    const warp = sampler.computeWarp(x, z, reduction);
    const xw = x + warp.x;
    const zw = z + warp.z;
    const c_individual = sampler.getContinentalness(xw, zw, reduction);
    const t_individual = sampler.getTemperature(xw, zw, reduction);

    const column = sampler.sampleColumn(x, z, reduction);

    try testing.expectEqual(c_individual, column.continentalness);
    try testing.expectEqual(t_individual, column.temperature);
}

test "NoiseSampler different seeds produce different results" {
    const sampler1 = NoiseSampler.init(111);
    const sampler2 = NoiseSampler.init(222);

    const c1 = sampler1.getContinentalness(100.0, 100.0, 0);
    const c2 = sampler2.getContinentalness(100.0, 100.0, 0);

    try testing.expect(c1 != c2);
}

test "WorldClassMap.getCell in-bounds returns stored cell" {
    const world_class_mod = world_worldgen.world_class;
    const ClassCell = world_class_mod.ClassCell;
    const WorldClassMap = world_class_mod.WorldClassMap;

    var map = WorldClassMap.init();
    const test_cell = ClassCell{
        .biome_id = .desert,
        .surface_type = .sand,
        .is_water = false,
        .continental_zone = .inland_high,
        .region_role = .destination,
        .path_type = .river,
    };
    map.cells[5 + 3 * 10] = test_cell;

    const result = map.getCell(5, 3);
    try testing.expectEqual(test_cell, result);
}

test "WorldClassMap.getCell out-of-bounds returns default cell" {
    const world_class_mod = world_worldgen.world_class;
    const WorldClassMap = world_class_mod.WorldClassMap;

    var map = WorldClassMap.init();

    const oob_x = map.getCell(10, 0);
    try testing.expectEqual(world_class_mod.DEFAULT_CELL, oob_x);

    const oob_z = map.getCell(0, 10);
    try testing.expectEqual(world_class_mod.DEFAULT_CELL, oob_z);

    const oob_both = map.getCell(99, 99);
    try testing.expectEqual(world_class_mod.DEFAULT_CELL, oob_both);
}

test "WorldClassMap.getCell boundary values" {
    const world_class_mod = world_worldgen.world_class;
    const ClassCell = world_class_mod.ClassCell;
    const WorldClassMap = world_class_mod.WorldClassMap;

    var map = WorldClassMap.init();
    const edge_cell = ClassCell{
        .biome_id = .mountains,
        .surface_type = .rock,
        .is_water = false,
        .continental_zone = .mountain_core,
        .region_role = .destination,
        .path_type = .none,
    };
    map.cells[9 + 9 * 10] = edge_cell;

    const corner = map.getCell(9, 9);
    try testing.expectEqual(edge_cell, corner);

    const just_over = map.getCell(10, 0);
    try testing.expectEqual(world_class_mod.DEFAULT_CELL, just_over);
}

test "WorldClassMap.getCell returns by value (no dangling pointer)" {
    const world_class_mod = world_worldgen.world_class;
    const WorldClassMap = world_class_mod.WorldClassMap;

    var map = WorldClassMap.init();
    map.cells[0] = .{
        .biome_id = .snow_tundra,
        .surface_type = .snow,
        .is_water = false,
        .continental_zone = .inland_high,
        .region_role = .transit,
        .path_type = .none,
    };

    const cell_copy = map.getCell(0, 0);
    map.cells[0] = world_class_mod.DEFAULT_CELL;

    try testing.expectEqual(.snow_tundra, cell_copy.biome_id);
}

test "HeightSampler continental zones" {
    const sampler = HeightSampler.init();
    const world_class_mod = world_worldgen.world_class;

    try testing.expectEqual(world_class_mod.ContinentalZone.deep_ocean, sampler.getContinentalZone(0.1));

    try testing.expectEqual(world_class_mod.ContinentalZone.ocean, sampler.getContinentalZone(0.25));

    try testing.expectEqual(world_class_mod.ContinentalZone.coast, sampler.getContinentalZone(0.38));

    try testing.expectEqual(world_class_mod.ContinentalZone.inland_low, sampler.getContinentalZone(0.50));

    try testing.expectEqual(world_class_mod.ContinentalZone.inland_high, sampler.getContinentalZone(0.70));

    try testing.expectEqual(world_class_mod.ContinentalZone.mountain_core, sampler.getContinentalZone(0.90));
}

test "HeightSampler ocean detection" {
    const sampler = HeightSampler.init();

    try testing.expect(sampler.isOcean(0.0));
    try testing.expect(sampler.isOcean(0.36));
    try testing.expect(!sampler.isOcean(0.37));
    try testing.expect(!sampler.isOcean(0.5));
}

test "HeightSampler mountain mask range" {
    const sampler = HeightSampler.init();

    const m1 = sampler.getMountainMask(0.8, 0.3, 0.8);
    try testing.expect(m1 >= 0.0 and m1 <= 1.0);

    const m2 = sampler.getMountainMask(0.2, 0.8, 0.4);
    try testing.expect(m2 >= 0.0 and m2 <= 1.0);
}

test "SurfaceBuilder coastal type detection" {
    const builder = SurfaceBuilder.init();

    const sand = builder.getCoastalSurfaceType(0.37, 1, 65, 0.3);
    try testing.expectEqual(CoastalSurfaceType.sand_beach, sand);

    const cliff = builder.getCoastalSurfaceType(0.37, 6, 65, 0.3);
    try testing.expectEqual(CoastalSurfaceType.none, cliff);

    const gravel = builder.getCoastalSurfaceType(0.37, 2, 65, 0.8);
    try testing.expectEqual(CoastalSurfaceType.none, gravel);

    const inland = builder.getCoastalSurfaceType(0.50, 1, 70, 0.3);
    try testing.expectEqual(CoastalSurfaceType.none, inland);
}

test "SurfaceBuilder bedrock at y=0" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(0, 50, .plains, 3, false, false);
    try testing.expectEqual(BlockType.bedrock, block);
}

test "SurfaceBuilder water above terrain below sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(60, 55, .plains, 3, false, true);
    try testing.expectEqual(BlockType.water, block);
}

test "SurfaceBuilder air above terrain above sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(80, 70, .plains, 3, false, false);
    try testing.expectEqual(BlockType.air, block);
}

test "BiomeSource initialization" {
    const source = BiomeSource.init();
    try testing.expect(source.params.sea_level == 64);
    try testing.expect(source.params.edge_detection_enabled == true);
}

test "BiomeSource ocean detection" {
    const source = BiomeSource.init();
    try testing.expect(source.isOcean(0.2));
    try testing.expect(!source.isOcean(0.5));
}

test "BiomeSource selectBiome hot dry returns desert" {
    const biome_mod = world_worldgen.biome;
    const source = BiomeSource.init();

    const climate = biome_mod.ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = source.selectBiome(climate, structural, 0.0);
    try testing.expectEqual(result, BiomeId.desert);
}

test "BiomeSource selectBiome cold wet returns snowy taiga" {
    const biome_mod = world_worldgen.biome;
    const source = BiomeSource.init();

    const climate = biome_mod.ClimateParams{
        .temperature = 0.2,
        .humidity = 0.7,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };

    const structural = biome_mod.StructuralParams{
        .height = 72,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = source.selectBiome(climate, structural, 0.0);
    try testing.expectEqual(BiomeId.snowy_taiga, result);
}

test "BiomeSource selectBiome river override" {
    const biome_mod = world_worldgen.biome;
    const source = BiomeSource.init();

    const climate = biome_mod.ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    const structural = biome_mod.StructuralParams{
        .height = 70,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    const result = source.selectBiome(climate, structural, 0.9);
    try testing.expectEqual(result, BiomeId.river);
}

test "BiomeSource getColor returns valid packed RGB" {
    const source = BiomeSource.init();

    const desert_color = source.getColor(BiomeId.desert);
    try testing.expect(desert_color != 0);

    const ocean_color = source.getColor(BiomeId.ocean);
    try testing.expect(ocean_color != desert_color);
}
