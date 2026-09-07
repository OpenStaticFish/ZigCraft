//! Biome selection algorithms: Voronoi, score-based, and blended.
//! All selection functions are pure — they read from the registry but have no side effects.

const std = @import("std");
const registry = @import("biome_registry.zig");

const BiomeId = registry.BiomeId;
const ClimateParams = registry.ClimateParams;
const StructuralParams = registry.StructuralParams;
const BIOME_REGISTRY = registry.BIOME_REGISTRY;
const BIOME_POINTS = registry.BIOME_POINTS;
const BLEND_EPSILON = registry.BLEND_EPSILON;
const NORMALIZED_SEA_LEVEL = registry.NORMALIZED_SEA_LEVEL;

const OCEAN_CONTINENTALNESS_MAX: f32 = 0.37;

// ============================================================================
// Voronoi Biome Selection (Issue #106)
// ============================================================================

/// Select biome using Voronoi diagram in heat/humidity space.
/// Compatibility wrapper for callers that do not have erosion/ridge data.
pub fn selectBiomeVoronoi(heat: f32, humidity: f32, height: i32, continentalness: f32, slope: i32) BiomeId {
    return selectBiomeVoronoiMultiParam(heat, humidity, height, continentalness, 0.35, 0.0, slope);
}

/// Select biome using multi-parameter Voronoi distance.
/// Heat/humidity preserve their historical 0-100 scale; normalized dimensions
/// are scaled to the same range so each axis can materially affect selection.
pub fn selectBiomeVoronoiMultiParam(
    heat: f32,
    humidity: f32,
    height: i32,
    continentalness: f32,
    ruggedness: f32,
    ridge_mask: f32,
    slope: i32,
) BiomeId {
    var min_dist: f32 = std.math.inf(f32);
    var closest: BiomeId = .plains;
    const elevation = normalizedHeight(height);

    for (BIOME_POINTS) |point| {
        // Check height constraint
        if (height < point.y_min or height > point.y_max) continue;

        // Check slope constraint
        if (slope > point.max_slope) continue;

        // Check continentalness constraint
        if (continentalness < point.min_continental or continentalness > point.max_continental) continue;

        // Calculate weighted Euclidean distance in multi-parameter climate space.
        const d_heat = heat - point.heat;
        const d_humidity = humidity - point.humidity;
        const d_elevation = (elevation - point.elevationCenter()) * 100.0;
        const d_continentalness = (continentalness - point.continentalnessCenter()) * 100.0;
        const d_ruggedness = (ruggedness - point.ruggedness) * 100.0;
        const d_ridge_mask = (ridge_mask - point.ridge_mask) * 100.0;
        var dist = @sqrt(
            d_heat * d_heat +
                d_humidity * d_humidity +
                d_elevation * d_elevation +
                d_continentalness * d_continentalness +
                d_ruggedness * d_ruggedness +
                d_ridge_mask * d_ridge_mask,
        );

        // Weight adjusts effective cell size (larger weight = closer distance = more likely)
        dist /= point.weight;

        if (dist < min_dist) {
            min_dist = dist;
            closest = point.id;
        }
    }

    return closest;
}

fn normalizedHeight(height: i32) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(height)) / 256.0, 0.0, 1.0);
}

/// Select biome using Voronoi with river override
pub fn selectBiomeVoronoiWithRiver(
    heat: f32,
    humidity: f32,
    height: i32,
    continentalness: f32,
    slope: i32,
    river_mask: f32,
) BiomeId {
    // River biome takes priority when river mask is active
    // Issue #110: Allow rivers at higher elevations (canyons)
    if (river_mask > 0.5 and height < 120) {
        if (heat <= 20.0) return .frozen_river;
        return .river;
    }
    return selectBiomeVoronoiMultiParam(heat, humidity, height, continentalness, 0.35, 0.0, slope);
}

// ============================================================================
// Multi-parameter Biome Selection
// ============================================================================

/// Select the best matching biome for given climate parameters
pub fn selectBiome(params: ClimateParams) BiomeId {
    var best_score: f32 = 0;
    var best_biome: BiomeId = .plains; // Default fallback

    for (BIOME_REGISTRY) |biome| {
        if (isOceanBiome(biome.id) and !isOceanClimate(params)) continue;
        const s = biome.scoreClimate(params);
        if (s > best_score) {
            best_score = s;
            best_biome = biome.id;
        }
    }

    return best_biome;
}

/// Select the best matching biome using climate and structural parameters.
/// This is the full six-parameter path: temperature, humidity, elevation,
/// continentalness, ruggedness, and ridge mask all influence eligibility or score.
pub fn selectBiomeMultiParam(climate: ClimateParams, structural: StructuralParams) BiomeId {
    var params = climate;
    params.continentalness = structural.continentalness;
    params.ridge_mask = structural.ridge_mask;

    var best_score: f32 = 0;
    var best_biome: BiomeId = .plains;

    for (BIOME_REGISTRY) |biome| {
        if (isOceanBiome(biome.id) and !isOceanStructure(params, structural)) continue;
        if (!biome.meetsStructuralConstraints(structural.height, structural.slope, structural.continentalness, structural.ridge_mask)) continue;

        const s = biome.scoreClimate(params);
        if (s > best_score) {
            best_score = s;
            best_biome = biome.id;
        }
    }

    return best_biome;
}

fn isOceanStructure(climate: ClimateParams, structural: StructuralParams) bool {
    return structural.continentalness < OCEAN_CONTINENTALNESS_MAX and climate.elevation <= NORMALIZED_SEA_LEVEL;
}

fn isOceanClimate(climate: ClimateParams) bool {
    return climate.continentalness < OCEAN_CONTINENTALNESS_MAX and climate.elevation <= NORMALIZED_SEA_LEVEL;
}

fn isOceanBiome(biome: BiomeId) bool {
    return switch (biome) {
        .deep_ocean, .ocean, .frozen_ocean, .cold_ocean, .warm_ocean => true,
        else => false,
    };
}

/// Select biome with river override
pub fn selectBiomeWithRiver(params: ClimateParams, river_mask: f32) BiomeId {
    // River biome takes priority when river mask is active
    if (river_mask > 0.5 and params.elevation < 0.35) {
        if (params.temperature <= 0.20) return .frozen_river;
        return .river;
    }
    return selectBiome(params);
}

/// Compute ClimateParams from raw generator values
pub fn computeClimateParams(
    temperature: f32,
    humidity: f32,
    height: i32,
    continentalness: f32,
    erosion: f32,
    sea_level: i32,
    max_height: i32,
) ClimateParams {
    // Normalize elevation: 0 = below sea, NORMALIZED_SEA_LEVEL = sea level, 1.0 = max height
    // Use conditional to avoid integer overflow when height < sea_level
    const height_above_sea: i32 = if (height > sea_level) height - sea_level else 0;
    const elevation_range = max_height - sea_level;
    const elevation = if (elevation_range > 0)
        NORMALIZED_SEA_LEVEL + 0.7 * @as(f32, @floatFromInt(height_above_sea)) / @as(f32, @floatFromInt(elevation_range))
    else
        NORMALIZED_SEA_LEVEL;

    // For underwater: scale 0-NORMALIZED_SEA_LEVEL
    const final_elevation = if (height < sea_level)
        NORMALIZED_SEA_LEVEL * @as(f32, @floatFromInt(@max(0, height))) / @as(f32, @floatFromInt(sea_level))
    else
        elevation;

    return .{
        .temperature = temperature,
        .humidity = humidity,
        .elevation = @min(1.0, final_elevation),
        .continentalness = continentalness,
        .ruggedness = 1.0 - erosion, // Invert erosion: low erosion = high ruggedness
    };
}

// ============================================================================
// Blended Biome Selection
// ============================================================================

/// Result of blended biome selection
pub const BiomeSelection = struct {
    primary: BiomeId,
    secondary: BiomeId,
    blend_factor: f32, // 0.0 = pure primary, up to 0.5 = mix of secondary
    primary_score: f32,
    secondary_score: f32,
};

/// Select top 2 biomes for blending
pub fn selectBiomeBlended(params: ClimateParams) BiomeSelection {
    var best_score: f32 = 0.0;
    var best_biome: ?BiomeId = null;
    var second_score: f32 = 0.0;
    var second_biome: ?BiomeId = null;

    for (BIOME_REGISTRY) |biome| {
        if (isOceanBiome(biome.id) and !isOceanClimate(params)) continue;
        const s = biome.scoreClimate(params);
        if (s > best_score) {
            second_score = best_score;
            second_biome = best_biome;
            best_score = s;
            best_biome = biome.id;
        } else if (s > second_score) {
            second_score = s;
            second_biome = biome.id;
        }
    }

    const primary = best_biome orelse .plains;
    const secondary = second_biome orelse primary;

    var blend: f32 = 0.0;
    const sum = best_score + second_score;
    if (sum > BLEND_EPSILON) {
        blend = second_score / sum;
    }

    return .{
        .primary = primary,
        .secondary = secondary,
        .blend_factor = blend,
        .primary_score = best_score,
        .secondary_score = second_score,
    };
}

/// Select blended biomes with river override
pub fn selectBiomeWithRiverBlended(params: ClimateParams, river_mask: f32) BiomeSelection {
    const selection = selectBiomeBlended(params);

    // If distinctly river, override primary with blending
    if (params.elevation < 0.35) {
        const river_edge0 = 0.45;
        const river_edge1 = 0.55;

        if (river_mask > river_edge0) {
            const t = std.math.clamp((river_mask - river_edge0) / (river_edge1 - river_edge0), 0.0, 1.0);
            const river_factor = t * t * (3.0 - 2.0 * t);
            const river_biome: BiomeId = if (params.temperature <= 0.20) .frozen_river else .river;

            // Blend towards river:
            // river_factor = 1.0 -> Pure River
            // river_factor = 0.0 -> Pure Land (selection.primary)
            // We set Primary=River, Secondary=Land, Blend=(1-river_factor)
            return .{
                .primary = river_biome,
                .secondary = selection.primary,
                .blend_factor = 1.0 - river_factor,
                .primary_score = 1.0, // River wins
                .secondary_score = selection.primary_score,
            };
        }
    }
    return selection;
}

// ============================================================================
// Constraint-based Selection (multi-parameter + structural filtering)
// ============================================================================

/// Select biome using the full climate and terrain parameter set.
/// Structural constraints filter eligibility before the soft climate score runs.
pub fn selectBiomeWithConstraints(climate: ClimateParams, structural: StructuralParams) BiomeId {
    return selectBiomeMultiParam(climate, structural);
}

/// Select biome with structural constraints and river override
pub fn selectBiomeWithConstraintsAndRiver(climate: ClimateParams, structural: StructuralParams, river_mask: f32) BiomeId {
    if (river_mask > 0.5 and structural.height < 120) {
        if (climate.temperature <= 0.20) return .frozen_river;
        return .river;
    }
    return selectBiomeWithConstraints(climate, structural);
}
