//! Data-driven biome system per biomes.md spec
//! Each biome is defined by parameter ranges and evaluated by scoring algorithm

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const tree_registry = @import("tree_registry.zig");
pub const TreeType = tree_registry.TreeType;

/// Minimum sum threshold for biome blend calculation to avoid division by near-zero values
const BLEND_EPSILON: f32 = 0.0001;

/// Represents a range of values for biome parameter matching
pub const Range = struct {
    min: f32,
    max: f32,

    /// Check if a value falls within this range
    pub fn contains(self: Range, value: f32) bool {
        return value >= self.min and value <= self.max;
    }

    /// Get normalized distance from center (0 = at center, 1 = at edge)
    pub fn distanceFromCenter(self: Range, value: f32) f32 {
        const center = (self.min + self.max) * 0.5;
        const half_width = (self.max - self.min) * 0.5;
        if (half_width <= 0) return if (value == center) 0 else 1;
        return @min(1.0, @abs(value - center) / half_width);
    }

    /// Convenience for "any value"
    pub fn any() Range {
        return .{ .min = 0.0, .max = 1.0 };
    }
};

/// Color tints for visual biome identity (RGB 0-1)
pub const ColorTints = struct {
    grass: [3]f32 = .{ 0.3, 0.65, 0.2 }, // Default green
    foliage: [3]f32 = .{ 0.2, 0.5, 0.15 },
    water: [3]f32 = .{ 0.2, 0.4, 0.8 },
};

/// Vegetation profile for biome-driven placement
pub const VegetationProfile = struct {
    tree_types: []const TreeType = &.{.oak},
    tree_density: f32 = 0.05, // Probability per attempt
    bush_density: f32 = 0.0,
    grass_density: f32 = 0.0,
    cactus_density: f32 = 0.0,
    dead_bush_density: f32 = 0.0,
    bamboo_density: f32 = 0.0,
    melon_density: f32 = 0.0,
    red_mushroom_density: f32 = 0.0,
    brown_mushroom_density: f32 = 0.0,
};

/// Terrain modifiers applied during height computation
pub const TerrainModifier = struct {
    /// Multiplier for hill/mountain amplitude (1.0 = normal)
    height_amplitude: f32 = 1.0,
    /// How much to smooth/flatten terrain (0 = no change, 1 = fully flat)
    smoothing: f32 = 0.0,
    /// Clamp height near sea level (for swamps)
    clamp_to_sea_level: bool = false,
    /// Additional height offset
    height_offset: f32 = 0.0,
};

/// Surface block configuration
pub const SurfaceBlocks = struct {
    top: BlockType = .grass,
    filler: BlockType = .dirt,
    depth_range: i32 = 3,
};

/// Complete biome definition - data-driven and extensible
pub const BiomeDefinition = struct {
    id: BiomeId,
    name: []const u8,

    // Parameter ranges for selection
    temperature: Range,
    humidity: Range,
    elevation: Range = Range.any(),
    continentalness: Range = Range.any(),
    ruggedness: Range = Range.any(),

    // Structural constraints - terrain structure determines biome eligibility
    min_height: i32 = 0, // Minimum absolute height (blocks from y=0)
    max_height: i32 = 256, // Maximum absolute height
    max_slope: i32 = 255, // Maximum allowed slope in blocks (0 = flat)
    min_ridge_mask: f32 = 0.0, // Minimum ridge mask value
    max_ridge_mask: f32 = 1.0, // Maximum ridge mask value

    // Selection tuning
    priority: i32 = 0, // Higher priority wins ties
    blend_weight: f32 = 1.0, // For future blending

    // Biome properties
    surface: SurfaceBlocks = .{},
    vegetation: VegetationProfile = .{},
    terrain: TerrainModifier = .{},
    colors: ColorTints = .{},

    /// Check if biome meets structural constraints (height, slope, continentalness, ridge)
    pub fn meetsStructuralConstraints(self: BiomeDefinition, height: i32, slope: i32, continentalness: f32, ridge_mask: f32) bool {
        if (height < self.min_height) return false;
        if (height > self.max_height) return false;
        if (slope > self.max_slope) return false;
        if (!self.continentalness.contains(continentalness)) return false;
        if (ridge_mask < self.min_ridge_mask or ridge_mask > self.max_ridge_mask) return false;
        return true;
    }

    /// Score how well this biome matches the given climate parameters
    /// Only temperature, humidity, and elevation affect the score (structural already filtered)
    pub fn scoreClimate(self: BiomeDefinition, params: ClimateParams) f32 {
        // Check if within climate ranges
        if (!self.temperature.contains(params.temperature)) return 0;
        if (!self.humidity.contains(params.humidity)) return 0;
        if (!self.elevation.contains(params.elevation)) return 0;

        // Compute weighted distance from ideal center
        const t_dist = self.temperature.distanceFromCenter(params.temperature);
        const h_dist = self.humidity.distanceFromCenter(params.humidity);
        const e_dist = self.elevation.distanceFromCenter(params.elevation);

        // Average distance (lower is better)
        const avg_dist = (t_dist + h_dist + e_dist) / 3.0;

        // Convert to score (higher is better), add priority bonus
        return (1.0 - avg_dist) + @as(f32, @floatFromInt(self.priority)) * 0.01;
    }
};

/// Climate parameters computed per (x,z) column
pub const ClimateParams = struct {
    temperature: f32, // 0=cold, 1=hot (altitude-adjusted)
    humidity: f32, // 0=dry, 1=wet
    elevation: f32, // Normalized: 0=sea level, 1=max height
    continentalness: f32, // 0=deep ocean, 1=deep inland
    ruggedness: f32, // 0=smooth, 1=mountainous (erosion inverted)
};

/// Biome identifiers - matches existing enum in block.zig
/// Per worldgen-revamp.md Section 4.3: Add transition micro-biomes
pub const BiomeId = enum(u8) {
    deep_ocean = 0,
    ocean = 1,
    beach = 2,
    plains = 3,
    forest = 4,
    taiga = 5,
    desert = 6,
    snow_tundra = 7,
    mountains = 8,
    snowy_mountains = 9,
    river = 10,
    swamp = 11, // New biome from spec
    mangrove_swamp = 12,
    jungle = 13,
    savanna = 14,
    badlands = 15,
    mushroom_fields = 16,
    // Per worldgen-revamp.md Section 4.3: Transition micro-biomes
    foothills = 17, // Plains <-> Mountains transition
    marsh = 18, // Forest <-> Swamp transition
    dry_plains = 19, // Desert <-> Forest/Plains transition
    coastal_plains = 20, // Coastal no-tree zone
};

// ============================================================================
// Edge Detection Types and Constants (Issue #102)
// ============================================================================

/// Sampling step for edge detection (every N blocks)
pub const EDGE_STEP: u32 = 4;

/// Radii to check for neighboring biomes (in world blocks)
pub const EDGE_CHECK_RADII = [_]u32{ 4, 8, 12 };

/// Target width of transition bands (blocks)
pub const EDGE_WIDTH: u32 = 8;

/// Represents proximity to a biome boundary
pub const EdgeBand = enum(u2) {
    none = 0, // No edge detected
    outer = 1, // 8-12 blocks from boundary
    middle = 2, // 4-8 blocks from boundary
    inner = 3, // 0-4 blocks from boundary
};

/// Information about biome edge detection result
pub const BiomeEdgeInfo = struct {
    base_biome: BiomeId,
    neighbor_biome: ?BiomeId, // Different biome if edge detected
    edge_band: EdgeBand,
};

/// Rule defining which biome pairs need a transition zone
pub const TransitionRule = struct {
    biome_a: BiomeId,
    biome_b: BiomeId,
    transition: BiomeId,
};

/// Biome adjacency rules - pairs that need buffer biomes between them
pub const TRANSITION_RULES = [_]TransitionRule{
    // Hot/dry <-> Temperate
    .{ .biome_a = .desert, .biome_b = .forest, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .plains, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .taiga, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .jungle, .transition = .savanna },

    // Cold <-> Temperate
    .{ .biome_a = .snow_tundra, .biome_b = .plains, .transition = .taiga },
    .{ .biome_a = .snow_tundra, .biome_b = .forest, .transition = .taiga },

    // Wetland <-> Forest
    .{ .biome_a = .swamp, .biome_b = .forest, .transition = .marsh },
    .{ .biome_a = .swamp, .biome_b = .plains, .transition = .marsh },

    // Mountain <-> Lowland
    .{ .biome_a = .mountains, .biome_b = .plains, .transition = .foothills },
    .{ .biome_a = .mountains, .biome_b = .forest, .transition = .foothills },
    .{ .biome_a = .snowy_mountains, .biome_b = .taiga, .transition = .foothills },
    .{ .biome_a = .snowy_mountains, .biome_b = .snow_tundra, .transition = .foothills },
};

/// Check if two biomes need a transition zone between them
pub fn needsTransition(a: BiomeId, b: BiomeId) bool {
    for (TRANSITION_RULES) |rule| {
        if ((rule.biome_a == a and rule.biome_b == b) or
            (rule.biome_a == b and rule.biome_b == a))
        {
            return true;
        }
    }
    return false;
}

/// Get the transition biome for a pair of biomes, if one is defined
pub fn getTransitionBiome(a: BiomeId, b: BiomeId) ?BiomeId {
    for (TRANSITION_RULES) |rule| {
        if ((rule.biome_a == a and rule.biome_b == b) or
            (rule.biome_a == b and rule.biome_b == a))
        {
            return rule.transition;
        }
    }
    return null;
}

// ============================================================================
// Voronoi Biome Selection System (Issue #106)
// Selects biomes using Voronoi diagram in heat/humidity space
// ============================================================================

/// Voronoi point defining a biome's position in climate space
/// Biomes are selected by finding the closest point to the sampled heat/humidity
pub const BiomePoint = struct {
    id: BiomeId,
    heat: f32, // 0-100 scale (cold to hot)
    humidity: f32, // 0-100 scale (dry to wet)
    weight: f32 = 1.0, // Cell size multiplier (larger = bigger biome regions)
    y_min: i32 = 0, // Minimum Y level
    y_max: i32 = 256, // Maximum Y level
    /// Maximum allowed slope in blocks (0 = flat, 255 = vertical cliff)
    max_slope: i32 = 255,
    /// Minimum continentalness (0-1). Set > 0.35 for land-only biomes
    min_continental: f32 = 0.0,
    /// Maximum continentalness. Set < 0.35 for ocean-only biomes
    max_continental: f32 = 1.0,
};

/// Voronoi biome points - defines where each biome sits in heat/humidity space
/// Heat: 0=frozen, 50=temperate, 100=scorching
/// Humidity: 0=arid, 50=normal, 100=saturated
pub const BIOME_POINTS = [_]BiomePoint{
    // === Ocean Biomes (continental < 0.35) ===
    .{ .id = .deep_ocean, .heat = 50, .humidity = 50, .weight = 1.5, .max_continental = 0.20 },
    .{ .id = .ocean, .heat = 50, .humidity = 50, .weight = 1.5, .min_continental = 0.20, .max_continental = 0.35 },

    // === Coastal Biomes ===
    .{ .id = .beach, .heat = 60, .humidity = 50, .weight = 0.6, .max_slope = 2, .min_continental = 0.35, .max_continental = 0.42, .y_max = 70 },

    // === Cold Biomes ===
    .{ .id = .snow_tundra, .heat = 5, .humidity = 30, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .taiga, .heat = 20, .humidity = 60, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .snowy_mountains, .heat = 10, .humidity = 40, .weight = 0.8, .min_continental = 0.60, .y_min = 100 },

    // === Temperate Biomes ===
    .{ .id = .plains, .heat = 50, .humidity = 45, .weight = 1.5, .min_continental = 0.42 }, // Large weight = common
    .{ .id = .forest, .heat = 45, .humidity = 65, .weight = 1.2, .min_continental = 0.42 },
    .{ .id = .mountains, .heat = 40, .humidity = 50, .weight = 0.8, .min_continental = 0.60, .y_min = 90 },

    // === Warm/Wet Biomes ===
    .{ .id = .swamp, .heat = 65, .humidity = 85, .weight = 0.8, .max_slope = 3, .min_continental = 0.42, .y_max = 72 },
    .{ .id = .mangrove_swamp, .heat = 75, .humidity = 90, .weight = 0.6, .max_slope = 3, .min_continental = 0.35, .max_continental = 0.50, .y_max = 68 },
    .{ .id = .jungle, .heat = 85, .humidity = 85, .weight = 0.9, .min_continental = 0.50 },

    // === Hot/Dry Biomes ===
    .{ .id = .desert, .heat = 90, .humidity = 10, .weight = 1.2, .min_continental = 0.42, .y_max = 90 },
    .{ .id = .savanna, .heat = 80, .humidity = 30, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .badlands, .heat = 85, .humidity = 15, .weight = 0.7, .min_continental = 0.55 },

    // === Special Biomes ===
    .{ .id = .mushroom_fields, .heat = 50, .humidity = 80, .weight = 0.3, .min_continental = 0.35, .max_continental = 0.45 },
    .{ .id = .river, .heat = 50, .humidity = 70, .weight = 0.4, .min_continental = 0.42 }, // Selected by river mask, not Voronoi

    // === Transition Biomes (created by edge detection, but need Voronoi fallback) ===
    // These have extreme positions so they're rarely selected directly
    .{ .id = .foothills, .heat = 45, .humidity = 45, .weight = 0.5, .min_continental = 0.55, .y_min = 75, .y_max = 100 },
    .{ .id = .marsh, .heat = 55, .humidity = 78, .weight = 0.5, .min_continental = 0.42, .y_max = 68 },
    .{ .id = .dry_plains, .heat = 70, .humidity = 25, .weight = 0.6, .min_continental = 0.42 },
    .{ .id = .coastal_plains, .heat = 55, .humidity = 50, .weight = 0.5, .min_continental = 0.35, .max_continental = 0.48 },
};

/// Select biome using Voronoi diagram in heat/humidity space
/// Returns the biome whose point is closest to the given heat/humidity values
pub fn selectBiomeVoronoi(heat: f32, humidity: f32, height: i32, continentalness: f32, slope: i32) BiomeId {
    var min_dist: f32 = std.math.inf(f32);
    var closest: BiomeId = .plains;

    for (BIOME_POINTS) |point| {
        // Check height constraint
        if (height < point.y_min or height > point.y_max) continue;

        // Check slope constraint
        if (slope > point.max_slope) continue;

        // Check continentalness constraint
        if (continentalness < point.min_continental or continentalness > point.max_continental) continue;

        // Calculate weighted Euclidean distance in heat/humidity space
        const d_heat = heat - point.heat;
        const d_humidity = humidity - point.humidity;
        var dist = @sqrt(d_heat * d_heat + d_humidity * d_humidity);

        // Weight adjusts effective cell size (larger weight = closer distance = more likely)
        dist /= point.weight;

        if (dist < min_dist) {
            min_dist = dist;
            closest = point.id;
        }
    }

    return closest;
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
        return .river;
    }
    return selectBiomeVoronoi(heat, humidity, height, continentalness, slope);
}

// ============================================================================
// Biome Registry - All biome definitions
// ============================================================================

pub const BIOME_REGISTRY: []const BiomeDefinition = &.{
    // === Ocean Biomes ===
    .{
        .id = .deep_ocean,
        .name = "Deep Ocean",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.25 },
        .continentalness = .{ .min = 0.0, .max = 0.20 },
        .priority = 2,
        .surface = .{ .top = .gravel, .filler = .gravel, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .colors = .{ .water = .{ 0.1, 0.2, 0.5 } },
    },
    .{
        .id = .ocean,
        .name = "Ocean",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.30 },
        .continentalness = .{ .min = 0.0, .max = 0.35 },
        .priority = 1,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
    },
    .{
        .id = .beach,
        .name = "Beach",
        .temperature = .{ .min = 0.2, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.28, .max = 0.38 },
        .continentalness = .{ .min = 0.35, .max = 0.42 }, // NARROW beach band
        .max_slope = 2,
        .priority = 10,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
    },

    // === Land Biomes (continentalness > 0.45) ===
    .{
        .id = .plains,
        .name = "Plains",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = Range.any(),
        .priority = 0, // Fallback
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.sparse_oak}, .tree_density = 0.02, .grass_density = 0.3 },
        .terrain = .{ .height_amplitude = 0.7, .smoothing = 0.2 },
    },
    .{
        .id = .forest,
        .name = "Forest",
        .temperature = .{ .min = 0.35, .max = 0.75 },
        .humidity = .{ .min = 0.40, .max = 1.0 },
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.60 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .oak, .birch, .dense_oak }, .tree_density = 0.12, .bush_density = 0.05, .grass_density = 0.4 },
        .colors = .{ .grass = .{ 0.25, 0.55, 0.18 }, .foliage = .{ 0.18, 0.45, 0.12 } },
    },
    .{
        .id = .taiga,
        .name = "Taiga",
        .temperature = .{ .min = 0.15, .max = 0.45 },
        .humidity = .{ .min = 0.30, .max = 0.90 },
        .elevation = .{ .min = 0.25, .max = 0.75 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .tree_density = 0.10, .grass_density = 0.2 },
        .colors = .{ .grass = .{ 0.35, 0.55, 0.25 }, .foliage = .{ 0.28, 0.48, 0.20 } },
    },
    .{
        .id = .desert,
        .name = "Desert",
        .temperature = .{ .min = 0.80, .max = 1.0 }, // Very hot
        .humidity = .{ .min = 0.0, .max = 0.20 }, // Very dry
        .elevation = .{ .min = 0.35, .max = 0.60 },
        .continentalness = .{ .min = 0.60, .max = 1.0 }, // Inland
        .ruggedness = .{ .min = 0.0, .max = 0.35 },
        .max_height = 90,
        .max_slope = 4,
        .priority = 6,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 6 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0, .cactus_density = 0.015, .dead_bush_density = 0.02 },
        .terrain = .{ .height_amplitude = 0.5, .smoothing = 0.4 },
        .colors = .{ .grass = .{ 0.75, 0.70, 0.35 } },
    },
    .{
        .id = .swamp,
        .name = "Swamp",
        .temperature = .{ .min = 0.50, .max = 0.80 },
        .humidity = .{ .min = 0.70, .max = 1.0 },
        .elevation = .{ .min = 0.28, .max = 0.40 },
        .continentalness = .{ .min = 0.55, .max = 0.75 }, // Coastal to mid-inland
        .ruggedness = .{ .min = 0.0, .max = 0.30 },
        .max_slope = 3,
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{.swamp_oak}, .tree_density = 0.08 },
        .terrain = .{ .clamp_to_sea_level = true, .height_offset = -2 },
        .colors = .{
            .grass = .{ 0.35, 0.45, 0.25 },
            .foliage = .{ 0.30, 0.40, 0.20 },
            .water = .{ 0.25, 0.35, 0.30 },
        },
    },
    .{
        .id = .snow_tundra,
        .name = "Snow Tundra",
        .temperature = .{ .min = 0.0, .max = 0.25 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.30, .max = 0.70 },
        .continentalness = .{ .min = 0.60, .max = 1.0 }, // Inland
        .min_height = 70,
        .max_slope = 255,
        .priority = 4,
        .surface = .{ .top = .snow_block, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .tree_density = 0.01 },
        .colors = .{ .grass = .{ 0.7, 0.75, 0.8 } },
    },

    // === Mountain Biomes (continentalness > 0.75) ===
    .{
        .id = .mountains,
        .name = "Mountains",
        .temperature = .{ .min = 0.25, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.58, .max = 1.0 },
        .continentalness = .{ .min = 0.75, .max = 1.0 }, // Must be inland high or core
        .ruggedness = .{ .min = 0.60, .max = 1.0 },
        .min_height = 90,
        .min_ridge_mask = 0.1,
        .priority = 2,
        .surface = .{ .top = .stone, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{.sparse_oak}, .tree_density = 0 },
        .terrain = .{ .height_amplitude = 1.5 },
    },
    .{
        .id = .snowy_mountains,
        .name = "Snowy Mountains",
        .temperature = .{ .min = 0.0, .max = 0.35 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.58, .max = 1.0 },
        .continentalness = .{ .min = 0.75, .max = 1.0 },
        .ruggedness = .{ .min = 0.55, .max = 1.0 },
        .min_height = 110,
        .max_slope = 255,
        .priority = 2,
        .surface = .{ .top = .snow_block, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .terrain = .{ .height_amplitude = 1.4 },
        .colors = .{ .grass = .{ 0.85, 0.90, 0.95 } },
    },

    // === Special Biomes ===
    .{
        .id = .mangrove_swamp,
        .name = "Mangrove Swamp",
        .temperature = .{ .min = 0.7, .max = 0.9 },
        .humidity = .{ .min = 0.8, .max = 1.0 },
        .elevation = .{ .min = 0.2, .max = 0.4 },
        .continentalness = .{ .min = 0.45, .max = 0.60 }, // Coastal swamp
        .priority = 6,
        .surface = .{ .top = .mud, .filler = .mud, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{.mangrove}, .tree_density = 0.15 },
        .terrain = .{ .clamp_to_sea_level = true, .height_offset = -1 },
        .colors = .{ .grass = .{ 0.4, 0.5, 0.2 }, .foliage = .{ 0.4, 0.5, 0.2 }, .water = .{ 0.2, 0.4, 0.3 } },
    },
    .{
        .id = .jungle,
        .name = "Jungle",
        .temperature = .{ .min = 0.75, .max = 1.0 },
        .humidity = .{ .min = 0.7, .max = 1.0 },
        .elevation = .{ .min = 0.30, .max = 0.75 },
        .continentalness = .{ .min = 0.60, .max = 1.0 }, // Inland
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.jungle}, .tree_density = 0.20, .bamboo_density = 0.08, .melon_density = 0.04 },
        .colors = .{ .grass = .{ 0.2, 0.8, 0.1 }, .foliage = .{ 0.1, 0.7, 0.1 } },
    },
    .{
        .id = .savanna,
        .name = "Savanna",
        .temperature = .{ .min = 0.65, .max = 1.0 }, // Hot climates
        .humidity = .{ .min = 0.20, .max = 0.50 }, // Wider range - moderately dry
        .elevation = .{ .min = 0.30, .max = 0.65 },
        .continentalness = .{ .min = 0.55, .max = 1.0 }, // Inland (less restrictive)
        .priority = 5, // Higher priority to win over plains in hot zones
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .tree_density = 0.015, .grass_density = 0.5, .dead_bush_density = 0.01 },
        .colors = .{ .grass = .{ 0.55, 0.55, 0.30 }, .foliage = .{ 0.50, 0.50, 0.28 } },
    },
    .{
        .id = .badlands,
        .name = "Badlands",
        .temperature = .{ .min = 0.7, .max = 1.0 },
        .humidity = .{ .min = 0.0, .max = 0.3 },
        .elevation = .{ .min = 0.4, .max = 0.8 },
        .continentalness = .{ .min = 0.70, .max = 1.0 }, // Deep inland
        .ruggedness = .{ .min = 0.4, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .red_sand, .filler = .terracotta, .depth_range = 5 },
        .vegetation = .{ .cactus_density = 0.02 },
        .colors = .{ .grass = .{ 0.5, 0.4, 0.3 } },
    },
    .{
        .id = .mushroom_fields,
        .name = "Mushroom Fields",
        .temperature = .{ .min = 0.4, .max = 0.7 },
        .humidity = .{ .min = 0.7, .max = 1.0 },
        .continentalness = .{ .min = 0.0, .max = 0.15 }, // Deep ocean islands only
        .max_height = 50,
        .priority = 20,
        .surface = .{ .top = .mycelium, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .huge_red_mushroom, .huge_brown_mushroom }, .tree_density = 0.05, .red_mushroom_density = 0.1, .brown_mushroom_density = 0.1 },
        .colors = .{ .grass = .{ 0.4, 0.8, 0.4 } },
    },
    .{
        .id = .river,
        .name = "River",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.35 },
        // River should NEVER win normal biome scoring - impossible range
        .continentalness = .{ .min = -1.0, .max = -0.5 },
        .priority = 15,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
    },

    // === Transition Micro-Biomes ===
    // These should NEVER win natural climate selection.
    // They are ONLY injected by edge detection (Issue #102).
    // Use impossible continental ranges so they can't match naturally.
    .{
        .id = .foothills,
        .name = "Foothills",
        .temperature = .{ .min = 0.20, .max = 0.90 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.25, .max = 0.65 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.30, .max = 0.80 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .sparse_oak, .spruce }, .tree_density = 0.08, .grass_density = 0.4 },
        .terrain = .{ .height_amplitude = 1.1, .smoothing = 0.1 },
        .colors = .{ .grass = .{ 0.35, 0.60, 0.25 } },
    },
    .{
        .id = .marsh,
        .name = "Marsh",
        .temperature = .{ .min = 0.40, .max = 0.75 },
        .humidity = .{ .min = 0.55, .max = 0.80 },
        .elevation = .{ .min = 0.28, .max = 0.42 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.30 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{.swamp_oak}, .tree_density = 0.04, .grass_density = 0.5 },
        .terrain = .{ .height_offset = -1, .smoothing = 0.3 },
        .colors = .{
            .grass = .{ 0.30, 0.50, 0.22 },
            .foliage = .{ 0.25, 0.45, 0.18 },
            .water = .{ 0.22, 0.38, 0.35 },
        },
    },
    .{
        .id = .dry_plains,
        .name = "Dry Plains",
        .temperature = .{ .min = 0.60, .max = 0.85 },
        .humidity = .{ .min = 0.20, .max = 0.40 },
        .elevation = .{ .min = 0.32, .max = 0.58 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.40 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .tree_density = 0.005, .grass_density = 0.3, .dead_bush_density = 0.02 },
        .terrain = .{ .height_amplitude = 0.6, .smoothing = 0.25 },
        .colors = .{ .grass = .{ 0.55, 0.50, 0.28 } }, // Less yellow, more natural
    },
    .{
        .id = .coastal_plains,
        .name = "Coastal Plains",
        .temperature = .{ .min = 0.30, .max = 0.80 },
        .humidity = .{ .min = 0.30, .max = 0.70 },
        .elevation = .{ .min = 0.28, .max = 0.45 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.35 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0, .grass_density = 0.4 }, // No trees
        .terrain = .{ .height_amplitude = 0.5, .smoothing = 0.3 },
        .colors = .{ .grass = .{ 0.35, 0.60, 0.28 } },
    },
};

// ============================================================================
// Biome Selection Functions
// ============================================================================

/// Select the best matching biome for given climate parameters
pub fn selectBiome(params: ClimateParams) BiomeId {
    var best_score: f32 = 0;
    var best_biome: BiomeId = .plains; // Default fallback

    for (BIOME_REGISTRY) |biome| {
        const s = biome.scoreClimate(params);
        if (s > best_score) {
            best_score = s;
            best_biome = biome.id;
        }
    }

    return best_biome;
}

/// Get the BiomeDefinition for a given BiomeId
pub fn getBiomeDefinition(id: BiomeId) *const BiomeDefinition {
    for (BIOME_REGISTRY) |*biome| {
        if (biome.id == id) return biome;
    }
    // All biomes in BiomeId enum must have a corresponding definition in BIOME_REGISTRY
    unreachable;
}

/// Select biome with river override
pub fn selectBiomeWithRiver(params: ClimateParams, river_mask: f32) BiomeId {
    // River biome takes priority when river mask is active
    if (river_mask > 0.5 and params.elevation < 0.35) {
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
    // Normalize elevation: 0 = below sea, 0.3 = sea level, 1.0 = max height
    // Use conditional to avoid integer overflow when height < sea_level
    const height_above_sea: i32 = if (height > sea_level) height - sea_level else 0;
    const elevation_range = max_height - sea_level;
    const elevation = if (elevation_range > 0)
        0.3 + 0.7 * @as(f32, @floatFromInt(height_above_sea)) / @as(f32, @floatFromInt(elevation_range))
    else
        0.3;

    // For underwater: scale 0-0.3
    const final_elevation = if (height < sea_level)
        0.3 * @as(f32, @floatFromInt(@max(0, height))) / @as(f32, @floatFromInt(sea_level))
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

            // Blend towards river:
            // river_factor = 1.0 -> Pure River
            // river_factor = 0.0 -> Pure Land (selection.primary)
            // We set Primary=River, Secondary=Land, Blend=(1-river_factor)
            return .{
                .primary = .river,
                .secondary = selection.primary,
                .blend_factor = 1.0 - river_factor,
                .primary_score = 1.0, // River wins
                .secondary_score = selection.primary_score,
            };
        }
    }
    return selection;
}

/// Structural constraints for biome selection
pub const StructuralParams = struct {
    height: i32,
    slope: i32,
    continentalness: f32,
    ridge_mask: f32,
};

/// Select biome using Voronoi diagram in heat/humidity space (Issue #106)
/// Climate temperature/humidity are converted to heat/humidity scale (0-100)
/// Structural constraints (height, continentalness) filter eligible biomes
pub fn selectBiomeWithConstraints(climate: ClimateParams, structural: StructuralParams) BiomeId {
    // Convert climate params to Voronoi heat/humidity scale (0-100)
    // Temperature 0-1 -> Heat 0-100
    // Humidity 0-1 -> Humidity 0-100
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;

    return selectBiomeVoronoi(heat, humidity, structural.height, structural.continentalness, structural.slope);
}

/// Select biome with structural constraints and river override
pub fn selectBiomeWithConstraintsAndRiver(climate: ClimateParams, structural: StructuralParams, river_mask: f32) BiomeId {
    // Convert climate params to Voronoi heat/humidity scale (0-100)
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;

    return selectBiomeVoronoiWithRiver(heat, humidity, structural.height, structural.continentalness, structural.slope, river_mask);
}

// ============================================================================
// LOD-optimized Biome Functions (Issue #114)
// ============================================================================

/// Simplified biome selection for LOD2+ (no structural constraints)
pub fn selectBiomeSimple(climate: ClimateParams) BiomeId {
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;
    const continental = climate.continentalness;

    // Ocean check
    if (continental < 0.35) {
        if (continental < 0.20) return .deep_ocean;
        return .ocean;
    }

    // Simple land biome selection based on heat/humidity
    if (heat < 20) {
        return if (humidity > 50) .taiga else .snow_tundra;
    } else if (heat < 40) {
        return if (humidity > 60) .taiga else .plains;
    } else if (heat < 60) {
        return if (humidity > 70) .forest else .plains;
    } else if (heat < 80) {
        return if (humidity > 60) .jungle else if (humidity > 30) .savanna else .desert;
    } else {
        return if (humidity > 40) .badlands else .desert;
    }
}

/// Get biome color for LOD rendering (packed RGB)
/// Colors adjusted to match textured output (grass/surface colors)
pub fn getBiomeColor(biome_id: BiomeId) u32 {
    return switch (biome_id) {
        .deep_ocean => 0x1A3380, // Darker blue
        .ocean => 0x3366CC, // Standard ocean blue
        .beach => 0xDDBB88, // Sand color
        .plains => 0x4D8033, // Darker grass green
        .forest => 0x2D591A, // Darker forest green
        .taiga => 0x476647, // Muted taiga green
        .desert => 0xD4B36A, // Warm desert sand
        .snow_tundra => 0xDDEEFF, // Snow
        .mountains => 0x888888, // Stone grey
        .snowy_mountains => 0xCCDDEE, // Snowy stone
        .river => 0x4488CC, // River blue
        .swamp => 0x334D33, // Dark swamp green
        .mangrove_swamp => 0x264026, // Muted mangrove
        .jungle => 0x1A661A, // Vibrant jungle green
        .savanna => 0x8C8C4D, // Dry savanna green
        .badlands => 0xAA6633, // Terracotta orange
        .mushroom_fields => 0x995577, // Mycelium purple
        .foothills => 0x597340, // Transitional green
        .marsh => 0x405933, // Transitional wetland
        .dry_plains => 0x8C8047, // Transitional dry plains
        .coastal_plains => 0x598047, // Transitional coastal
    };
}

// ============================================================================
// BiomeSource - Unified biome selection interface (Issue #147)
// ============================================================================

/// Result of biome selection with blending information
pub const BiomeResult = struct {
    primary: BiomeId,
    secondary: BiomeId, // For blending (may be same as primary)
    blend_factor: f32, // 0.0 = use primary, 1.0 = use secondary
};

/// Parameters for BiomeSource initialization
pub const BiomeSourceParams = struct {
    sea_level: i32 = 64,
    edge_detection_enabled: bool = true,
    ocean_threshold: f32 = 0.35,
};

/// Unified biome selection interface.
///
/// BiomeSource wraps all biome selection logic into a single, configurable
/// interface. This allows swapping biome selection behavior for different
/// dimensions (e.g., Overworld vs Nether) without modifying the generator.
///
/// Part of Issue #147: Modularize Terrain Generation Pipeline
pub const BiomeSource = struct {
    params: BiomeSourceParams,

    /// Initialize with default parameters
    pub fn init() BiomeSource {
        return initWithParams(.{});
    }

    /// Initialize with custom parameters
    pub fn initWithParams(params: BiomeSourceParams) BiomeSource {
        return .{ .params = params };
    }

    /// Primary biome selection interface.
    ///
    /// Selects a biome based on climate and structural parameters,
    /// with optional river override.
    pub fn selectBiome(
        self: *const BiomeSource,
        climate: ClimateParams,
        structural: StructuralParams,
        river_mask: f32,
    ) BiomeId {
        _ = self;
        return selectBiomeWithConstraintsAndRiver(climate, structural, river_mask);
    }

    /// Select biome with edge detection and transition biome injection.
    ///
    /// This is the full biome selection that includes checking for
    /// biome boundaries and inserting appropriate transition biomes.
    pub fn selectBiomeWithEdge(
        self: *const BiomeSource,
        climate: ClimateParams,
        structural: StructuralParams,
        river_mask: f32,
        edge_info: BiomeEdgeInfo,
    ) BiomeResult {
        // First, get the base biome
        const base_biome = self.selectBiome(climate, structural, river_mask);

        // If edge detection is disabled or no edge detected, return base
        if (!self.params.edge_detection_enabled or edge_info.edge_band == .none) {
            return .{
                .primary = base_biome,
                .secondary = base_biome,
                .blend_factor = 0.0,
            };
        }

        // Check if transition is needed
        if (edge_info.neighbor_biome) |neighbor| {
            if (getTransitionBiome(base_biome, neighbor)) |transition| {
                // Set blend factor based on edge band
                const blend: f32 = switch (edge_info.edge_band) {
                    .inner => 0.3, // Closer to boundary: more original showing through
                    .middle => 0.2,
                    .outer => 0.1,
                    .none => 0.0,
                };
                return .{
                    .primary = transition,
                    .secondary = base_biome,
                    .blend_factor = blend,
                };
            }
        }

        // No transition needed
        return .{
            .primary = base_biome,
            .secondary = base_biome,
            .blend_factor = 0.0,
        };
    }

    /// Simplified biome selection for LOD levels
    pub fn selectBiomeSimplified(self: *const BiomeSource, climate: ClimateParams) BiomeId {
        _ = self;
        return selectBiomeSimple(climate);
    }

    /// Check if a position is ocean based on continentalness
    pub fn isOcean(self: *const BiomeSource, continentalness: f32) bool {
        return continentalness < self.params.ocean_threshold;
    }

    /// Get the biome definition for a biome ID
    pub fn getDefinition(_: *const BiomeSource, biome_id: BiomeId) BiomeDefinition {
        return getBiomeDefinition(biome_id);
    }

    /// Get biome color for rendering
    pub fn getColor(_: *const BiomeSource, biome_id: BiomeId) u32 {
        return getBiomeColor(biome_id);
    }

    /// Compute climate parameters from raw values
    pub fn computeClimate(
        self: *const BiomeSource,
        temperature: f32,
        humidity: f32,
        terrain_height: i32,
        continentalness: f32,
        erosion: f32,
        max_height: i32,
    ) ClimateParams {
        return computeClimateParams(
            temperature,
            humidity,
            terrain_height,
            continentalness,
            erosion,
            self.params.sea_level,
            max_height,
        );
    }
};
