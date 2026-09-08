//! Unit tests for biome selection algorithms
//!
//! Tests focus on:
//! - Voronoi selection correctness
//! - Climate parameter computation
//! - River override behavior
//! - Blended biome selection

const std = @import("std");
const testing = std.testing;
const selector = @import("biome_selector.zig");
const edge_detector = @import("biome_edge_detector.zig");
const registry = @import("biome_registry.zig");

const BiomeId = registry.BiomeId;
const ClimateParams = registry.ClimateParams;
const StructuralParams = registry.StructuralParams;
const selectBiomeVoronoi = selector.selectBiomeVoronoi;
const selectBiomeVoronoiMultiParam = selector.selectBiomeVoronoiMultiParam;
const selectBiomeVoronoiWithRiver = selector.selectBiomeVoronoiWithRiver;
const selectBiome = selector.selectBiome;
const selectBiomeMultiParam = selector.selectBiomeMultiParam;
const selectBiomeWithRiver = selector.selectBiomeWithRiver;
const selectBiomeBlended = selector.selectBiomeBlended;
const selectBiomeWithRiverBlended = selector.selectBiomeWithRiverBlended;
const selectBiomeWithConstraints = selector.selectBiomeWithConstraints;
const selectBiomeWithConstraintsAndRiver = selector.selectBiomeWithConstraintsAndRiver;
const computeClimateParams = selector.computeClimateParams;
const BiomeSelection = selector.BiomeSelection;
const BIOME_POINTS = registry.BIOME_POINTS;

// ============================================================================
// computeClimateParams Tests
// ============================================================================

test "computeClimateParams normalizes elevation above sea level" {
    const params = computeClimateParams(0.5, 0.5, 96, 0.5, 0.5, 64, 256);
    try testing.expect(params.elevation > 0.3);
    try testing.expect(params.elevation <= 1.0);
}

test "computeClimateParams scales underwater elevation 0-0.3" {
    const params = computeClimateParams(0.5, 0.5, 32, 0.5, 0.5, 64, 256);
    try testing.expect(params.elevation < 0.3);
    try testing.expect(params.elevation >= 0.0);
}

test "computeClimateParams elevation at sea level is ~0.3" {
    const params = computeClimateParams(0.5, 0.5, 64, 0.5, 0.5, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.3), params.elevation, 0.05);
}

test "computeClimateParams inverts erosion to ruggedness" {
    const params = computeClimateParams(0.5, 0.5, 80, 0.5, 0.2, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.8), params.ruggedness, 0.001);
}

test "computeClimateParams preserves temperature and humidity" {
    const params = computeClimateParams(0.7, 0.3, 80, 0.6, 0.5, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.7), params.temperature, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), params.humidity, 0.001);
}

// ============================================================================
// selectBiome (score-based) Tests
// ============================================================================

test "selectBiome returns valid biome id" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiome(params);
    _ = @as(BiomeId, biome);
}

test "selectBiome selects different biomes for different climates" {
    const hot_humid = ClimateParams{
        .temperature = 0.85,
        .humidity = 0.85,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const cold_dry = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.2,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const jungle = selectBiome(hot_humid);
    const tundra = selectBiome(cold_dry);
    try testing.expect(jungle != tundra);
}

test "selectBiomeWithRiver selects river when mask high and elevation low" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expectEqual(BiomeId.river, biome);
}

test "selectBiomeWithRiver selects frozen river in cold climates" {
    const params = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expectEqual(BiomeId.frozen_river, biome);
}

test "selectBiomeWithRiver selects normal biome when elevation high" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expect(biome != .river);
}

test "selectBiomeWithRiver selects non-river biome" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.45,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.0);
    try testing.expect(biome != .river);
}

test "selectBiomeWithRiver at high elevation returns non-river" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expect(biome != .river);
}

// ============================================================================
// selectBiomeVoronoi Tests
// ============================================================================

test "selectBiomeVoronoi respects height constraints" {
    const biome = selectBiomeVoronoi(50, 50, 130, 0.85, 10);
    try testing.expect(biome != .beach);
}

test "selectBiomeVoronoi respects slope constraints" {
    const biome = selectBiomeVoronoi(50, 50, 50, 0.6, 10);
    try testing.expect(biome != .beach);
}

test "selectBiomeVoronoi respects continentalness constraints" {
    const biome = selectBiomeVoronoi(50, 50, 50, 0.2, 2);
    _ = biome;
}

test "selectBiomeVoronoiWithRiver returns river when mask > 0.5 and height < 120" {
    const biome = selectBiomeVoronoiWithRiver(50, 50, 80, 0.6, 2, 0.6);
    try testing.expectEqual(BiomeId.river, biome);
}

test "selectBiomeVoronoiWithRiver returns frozen river for cold river mask" {
    const biome = selectBiomeVoronoiWithRiver(8, 70, 80, 0.6, 2, 0.6);
    try testing.expectEqual(BiomeId.frozen_river, biome);
}

// ============================================================================
// selectBiomeWithConstraints Tests
// ============================================================================

test "selectBiomeWithConstraints converts climate to heat/humidity scale" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const structural = StructuralParams{
        .height = 80,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.2,
    };
    const biome = selectBiomeWithConstraints(climate, structural);
    _ = @as(BiomeId, biome);
}

test "selectBiomeWithConstraintsAndRiver handles river override" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const structural = StructuralParams{
        .height = 70,
        .slope = 1,
        .continentalness = 0.5,
        .ridge_mask = 0.1,
    };
    const biome = selectBiomeWithConstraintsAndRiver(climate, structural, 0.7);
    try testing.expectEqual(BiomeId.river, biome);
}

test "selectBiomeWithConstraints locks baseline climate and structural selections" {
    const Case = struct {
        name: []const u8,
        climate: ClimateParams,
        structural: StructuralParams,
        expected: BiomeId,
    };

    const cases = [_]Case{
        .{
            .name = "ocean",
            .climate = .{ .temperature = 0.5, .humidity = 0.5, .elevation = 0.2, .continentalness = 0.25, .ruggedness = 0.1 },
            .structural = .{ .height = 50, .slope = 1, .continentalness = 0.25, .ridge_mask = 0.0 },
            .expected = .ocean,
        },
        .{
            .name = "coast",
            .climate = .{ .temperature = 0.6, .humidity = 0.5, .elevation = 0.3, .continentalness = 0.38, .ruggedness = 0.1 },
            .structural = .{ .height = 64, .slope = 1, .continentalness = 0.38, .ridge_mask = 0.1 },
            .expected = .beach,
        },
        .{
            .name = "frozen ocean",
            .climate = .{ .temperature = 0.05, .humidity = 0.55, .elevation = 0.2, .continentalness = 0.25, .ruggedness = 0.1 },
            .structural = .{ .height = 50, .slope = 1, .continentalness = 0.25, .ridge_mask = 0.0 },
            .expected = .frozen_ocean,
        },
        .{
            .name = "lowland",
            .climate = .{ .temperature = 0.5, .humidity = 0.45, .elevation = 0.35, .continentalness = 0.6, .ruggedness = 0.1 },
            .structural = .{ .height = 70, .slope = 2, .continentalness = 0.6, .ridge_mask = 0.1 },
            .expected = .plains,
        },
        .{
            .name = "mountain",
            .climate = .{ .temperature = 0.4, .humidity = 0.5, .elevation = 0.7, .continentalness = 0.65, .ruggedness = 0.8 },
            .structural = .{ .height = 100, .slope = 6, .continentalness = 0.65, .ridge_mask = 0.7 },
            .expected = .mountains,
        },
        .{
            .name = "hot dry",
            .climate = .{ .temperature = 0.9, .humidity = 0.1, .elevation = 0.4, .continentalness = 0.6, .ruggedness = 0.2 },
            .structural = .{ .height = 70, .slope = 2, .continentalness = 0.6, .ridge_mask = 0.2 },
            .expected = .desert,
        },
        .{
            .name = "cold",
            .climate = .{ .temperature = 0.05, .humidity = 0.3, .elevation = 0.4, .continentalness = 0.6, .ruggedness = 0.2 },
            .structural = .{ .height = 70, .slope = 2, .continentalness = 0.6, .ridge_mask = 0.2 },
            .expected = .snow_tundra,
        },
        .{
            .name = "wet",
            .climate = .{ .temperature = 0.65, .humidity = 0.85, .elevation = 0.3, .continentalness = 0.6, .ruggedness = 0.1 },
            .structural = .{ .height = 65, .slope = 2, .continentalness = 0.6, .ridge_mask = 0.1 },
            .expected = .swamp,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("failed biome selector baseline case: {s}\n", .{case.name});
        const biome = selectBiomeWithConstraints(case.climate, case.structural);
        try testing.expectEqual(case.expected, biome);
    }
}

test "beach transitions to coastal plains before common inland biomes" {
    try testing.expectEqual(BiomeId.coastal_plains, edge_detector.getTransitionBiome(.beach, .plains).?);
    try testing.expectEqual(BiomeId.coastal_plains, edge_detector.getTransitionBiome(.forest, .beach).?);
    try testing.expectEqual(BiomeId.coastal_plains, edge_detector.getTransitionBiome(.beach, .swamp).?);

    // The former selector baseline is an edge-injection fixture, not a natural biome site.
    const source = @import("biome_source.zig").BiomeSource.init();
    const climate = ClimateParams{ .temperature = 0.55, .humidity = 0.5, .elevation = 0.32, .continentalness = 0.45, .ruggedness = 0.2 };
    const structural = StructuralParams{ .height = 64, .slope = 1, .continentalness = 0.45, .ridge_mask = 0.1 };
    const base = selectBiomeWithConstraints(climate, structural);
    try testing.expect(base != .coastal_plains);
    const transition = source.selectBiomeWithEdge(climate, structural, 0.0, .{
        .base_biome = base,
        .neighbor_biome = .beach,
        .edge_band = .inner,
    });
    try testing.expectEqual(BiomeId.coastal_plains, transition.primary);
    try testing.expectEqual(base, transition.secondary);
    const no_edge = source.selectBiomeWithEdge(climate, structural, 0.0, .{
        .base_biome = base,
        .neighbor_biome = .beach,
        .edge_band = .none,
    });
    try testing.expectEqual(base, no_edge.primary);
}

test "selectBiomeWithConstraintsAndRiver locks river and frozen river priority" {
    const temperate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    const frozen = ClimateParams{
        .temperature = 0.08,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    const structural = StructuralParams{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    try testing.expectEqual(BiomeId.river, selectBiomeWithConstraintsAndRiver(temperate, structural, 0.7));
    try testing.expectEqual(BiomeId.frozen_river, selectBiomeWithConstraintsAndRiver(frozen, structural, 0.7));
}

test "selectBiomeWithConstraints locks structural edge cases" {
    const desert_climate = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };

    try testing.expectEqual(BiomeId.desert, selectBiomeWithConstraints(desert_climate, .{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }));
    try testing.expect(selectBiomeWithConstraints(desert_climate, .{
        .height = 110,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }) != .desert);

    const swamp_climate = ClimateParams{
        .temperature = 0.65,
        .humidity = 0.85,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.1,
    };

    try testing.expectEqual(BiomeId.swamp, selectBiomeWithConstraints(swamp_climate, .{
        .height = 65,
        .slope = registry.getBiomeDefinition(.swamp).max_slope,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }));
    try testing.expect(selectBiomeWithConstraints(swamp_climate, .{
        .height = 65,
        .slope = registry.getBiomeDefinition(.swamp).max_slope + 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }) != .swamp);
    // Wet climate alone cannot override the swamp's inland constraint.
    try testing.expect(selectBiomeWithConstraints(swamp_climate, .{
        .height = 65,
        .slope = 2,
        .continentalness = 0.45,
        .ridge_mask = 0.1,
    }) != .swamp);

    try testing.expectEqual(BiomeId.ocean, selectBiomeWithConstraints(.{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.25,
        .ruggedness = 0.1,
    }, .{
        .height = 50,
        .slope = 1,
        .continentalness = 0.25,
        .ridge_mask = 0.1,
    }));
    try testing.expectEqual(BiomeId.plains, selectBiomeWithConstraints(.{
        .temperature = 0.5,
        .humidity = 0.45,
        .elevation = 0.35,
        .continentalness = 0.6,
        .ruggedness = 0.1,
    }, .{
        .height = 70,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }));
}

test "selectBiomeWithConstraints preserves ocean sea-level boundary" {
    const underwater_ocean = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.30,
        .continentalness = 0.25,
        .ruggedness = 0.1,
    };
    const inland_ocean_candidate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.31,
        .continentalness = 0.25,
        .ruggedness = 0.1,
    };
    const structural = StructuralParams{
        .height = 64,
        .slope = 1,
        .continentalness = 0.25,
        .ridge_mask = 0.1,
    };

    try testing.expectEqual(BiomeId.ocean, selectBiomeWithConstraints(underwater_ocean, structural));
    try testing.expect(selectBiomeWithConstraints(inland_ocean_candidate, structural) != .ocean);
    try testing.expect(selectBiomeWithConstraints(inland_ocean_candidate, structural) != .deep_ocean);
    try testing.expect(selectBiomeWithConstraints(inland_ocean_candidate, structural) != .frozen_ocean);
    try testing.expect(selectBiomeWithConstraints(inland_ocean_candidate, structural) != .cold_ocean);
    try testing.expect(selectBiomeWithConstraints(inland_ocean_candidate, structural) != .warm_ocean);
}

test "selectBiomeWithConstraints preserves coast and inland water boundaries" {
    const beach = registry.getBiomeDefinition(.beach);
    const coast_climate = ClimateParams{
        .temperature = 0.6,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = beach.continentalness.min,
        .ruggedness = 0.1,
    };
    const coast_structural = StructuralParams{
        .height = 64,
        .slope = beach.max_slope,
        .continentalness = beach.continentalness.min,
        .ridge_mask = 0.1,
    };
    const steep_coast = StructuralParams{
        .height = 64,
        .slope = beach.max_slope + 1,
        .continentalness = beach.continentalness.min,
        .ridge_mask = 0.1,
    };
    const high_coast = StructuralParams{
        .height = beach.max_height + 1,
        .slope = 1,
        .continentalness = beach.continentalness.min,
        .ridge_mask = 0.1,
    };
    const inland_water = ClimateParams{
        .temperature = 0.6,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.6,
        .ruggedness = 0.1,
    };

    try testing.expectEqual(BiomeId.beach, selectBiomeWithConstraints(coast_climate, coast_structural));
    var ocean_side = coast_structural;
    ocean_side.continentalness = beach.continentalness.min - 0.0001;
    try testing.expectEqual(BiomeId.ocean, selectBiomeWithConstraints(coast_climate, ocean_side));
    var upper_beach = coast_structural;
    upper_beach.height = beach.max_height;
    upper_beach.continentalness = beach.continentalness.max;
    try testing.expectEqual(BiomeId.beach, selectBiomeWithConstraints(coast_climate, upper_beach));
    upper_beach.continentalness += 0.0001;
    try testing.expect(selectBiomeWithConstraints(coast_climate, upper_beach) != .beach);
    try testing.expect(selectBiomeWithConstraints(coast_climate, steep_coast) != .beach);
    try testing.expect(selectBiomeWithConstraints(coast_climate, high_coast) != .beach);
    try testing.expect(selectBiomeWithConstraints(inland_water, .{
        .height = 50,
        .slope = 1,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }) != .beach);
}

test "selectBiomeWithConstraintsAndRiver preserves river thresholds" {
    const temperate = ClimateParams{
        .temperature = 0.21,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    const frozen = ClimateParams{
        .temperature = 0.20,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    const structural = StructuralParams{
        .height = 119,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    };

    try testing.expect(selectBiomeWithConstraintsAndRiver(temperate, structural, 0.5) != .river);
    try testing.expectEqual(BiomeId.river, selectBiomeWithConstraintsAndRiver(temperate, structural, 0.5001));
    try testing.expectEqual(BiomeId.frozen_river, selectBiomeWithConstraintsAndRiver(frozen, structural, 0.5001));
    try testing.expect(selectBiomeWithConstraintsAndRiver(temperate, .{
        .height = 120,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.1,
    }, 0.5001) != .river);
}

test "selectBiomeWithConstraints documents ridge mask baseline behavior" {
    const climate = ClimateParams{
        .temperature = 0.4,
        .humidity = 0.5,
        .elevation = 0.7,
        .continentalness = 0.65,
        .ruggedness = 0.8,
    };
    const low_ridge = StructuralParams{
        .height = 100,
        .slope = 6,
        .continentalness = 0.65,
        .ridge_mask = 0.0,
    };
    const high_ridge = StructuralParams{
        .height = 100,
        .slope = 6,
        .continentalness = 0.65,
        .ridge_mask = 1.0,
    };

    try testing.expect(selectBiomeWithConstraints(climate, low_ridge) != .jagged_peaks);
    try testing.expect(selectBiomeWithConstraints(climate, high_ridge) != .plains);
}

test "selectBiomeMultiParam uses ruggedness and ridge mask" {
    const climate = ClimateParams{
        .temperature = 0.32,
        .humidity = 0.45,
        .elevation = 0.85,
        .continentalness = 0.85,
        .ruggedness = 0.85,
    };
    const low_ridge = StructuralParams{
        .height = 150,
        .slope = 18,
        .continentalness = 0.85,
        .ridge_mask = 0.1,
    };
    const high_ridge = StructuralParams{
        .height = 150,
        .slope = 18,
        .continentalness = 0.85,
        .ridge_mask = 0.7,
    };

    try testing.expect(selectBiomeMultiParam(climate, low_ridge) != .jagged_peaks);
    try testing.expectEqual(BiomeId.jagged_peaks, selectBiomeMultiParam(climate, high_ridge));
}

test "selectBiomeVoronoi falls back to plains when structural filters exclude all points" {
    try testing.expectEqual(BiomeId.plains, selectBiomeVoronoi(50, 50, 300, 1.1, 255));
}

test "selectBiomeVoronoiMultiParam keeps migrated biome points selectable" {
    for (BIOME_POINTS) |point| {
        // Height bounds filter eligibility; the Voronoi site need not be their midpoint.
        const height: i32 = @intFromFloat(@round(point.elevationCenter() * 256.0));
        try testing.expect(height >= point.y_min and height <= point.y_max);
        const biome = selectBiomeVoronoiMultiParam(
            point.heat,
            point.humidity,
            height,
            point.continentalnessCenter(),
            point.ruggedness,
            point.ridge_mask,
            @min(point.max_slope, 1),
        );

        errdefer std.debug.print(
            "migrated biome point {s} selected {s}\n",
            .{ @tagName(point.id), @tagName(biome) },
        );
        try testing.expectEqual(point.id, biome);
    }
}

test "selectBiomeVoronoiMultiParam separates equal heat humidity by continentalness" {
    const deep = selectBiomeVoronoiMultiParam(50, 50, 50, 0.10, 0.35, 0.0, 1);
    const shallow = selectBiomeVoronoiMultiParam(50, 50, 50, 0.28, 0.35, 0.0, 1);

    try testing.expectEqual(BiomeId.deep_ocean, deep);
    try testing.expectEqual(BiomeId.ocean, shallow);
}

// ============================================================================
// selectBiomeBlended Tests
// ============================================================================

test "selectBiomeBlended returns both primary and secondary" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeBlended(params);
    try testing.expect(selection.primary != .river);
    try testing.expect(selection.primary_score >= 0);
    try testing.expect(selection.secondary_score >= 0);
}

test "selectBiomeBlended blend_factor bounded by BLEND_EPSILON" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeBlended(params);
    try testing.expect(selection.blend_factor >= 0);
    try testing.expect(selection.blend_factor <= 0.5);
}

test "selectBiomeWithRiverBlended returns river-dominant selection when river active" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeWithRiverBlended(params, 0.6);
    try testing.expectEqual(BiomeId.river, selection.primary);
}

test "selectBiomeWithRiverBlended returns normal selection when river not active" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeWithRiverBlended(params, 0.2);
    try testing.expect(selection.primary != .river);
}

// ============================================================================
// BiomeSelection Structure Tests
// ============================================================================

test "BiomeSelection structure fields are valid" {
    const selection = BiomeSelection{
        .primary = .plains,
        .secondary = .forest,
        .blend_factor = 0.3,
        .primary_score = 0.8,
        .secondary_score = 0.6,
    };
    try testing.expect(selection.primary_score > selection.secondary_score);
    try testing.expect(selection.blend_factor >= 0);
}
