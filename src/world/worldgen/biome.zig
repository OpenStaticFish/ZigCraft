//! Data-driven biome system per biomes.md spec
//! Each biome is defined by parameter ranges and evaluated by scoring algorithm

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;

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

/// Tree types that can spawn in biomes
pub const TreeType = enum {
    oak,
    birch,
    spruce,
    swamp_oak, // Swamp trees with vines
    mangrove, // Prop roots
    jungle, // Tall with vines
    acacia, // Diagonal trunk
    huge_red_mushroom,
    huge_brown_mushroom,
    none,
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

    // Selection tuning
    priority: i32 = 0, // Higher priority wins ties
    blend_weight: f32 = 1.0, // For future blending

    // Biome properties
    surface: SurfaceBlocks = .{},
    vegetation: VegetationProfile = .{},
    terrain: TerrainModifier = .{},
    colors: ColorTints = .{},

    /// Score how well this biome matches the given parameters
    /// Returns 0 if outside any range, otherwise returns inverse distance from ideal
    pub fn score(self: BiomeDefinition, params: ClimateParams) f32 {
        // Check if within all ranges
        if (!self.temperature.contains(params.temperature)) return 0;
        if (!self.humidity.contains(params.humidity)) return 0;
        if (!self.elevation.contains(params.elevation)) return 0;
        if (!self.continentalness.contains(params.continentalness)) return 0;
        if (!self.ruggedness.contains(params.ruggedness)) return 0;

        // Compute weighted distance from ideal center
        const t_dist = self.temperature.distanceFromCenter(params.temperature);
        const h_dist = self.humidity.distanceFromCenter(params.humidity);
        const e_dist = self.elevation.distanceFromCenter(params.elevation);
        const c_dist = self.continentalness.distanceFromCenter(params.continentalness);
        const r_dist = self.ruggedness.distanceFromCenter(params.ruggedness);

        // Average distance (lower is better)
        const avg_dist = (t_dist + h_dist + e_dist + c_dist + r_dist) / 5.0;

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
};

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
        .elevation = .{ .min = 0.0, .max = 0.15 },
        .continentalness = .{ .min = 0.0, .max = 0.35 },
        .priority = 10,
        .surface = .{ .top = .gravel, .filler = .gravel, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .colors = .{ .water = .{ 0.1, 0.2, 0.5 } },
    },
    .{
        .id = .ocean,
        .name = "Ocean",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.25 },
        .continentalness = .{ .min = 0.0, .max = 0.46 },
        .priority = 8,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
    },
    .{
        .id = .beach,
        .name = "Beach",
        .temperature = .{ .min = 0.3, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.2, .max = 0.315 }, // Reduced max from 0.35 to 0.315 (~4 blocks above sea)
        .continentalness = .{ .min = 0.40, .max = 0.55 },
        .priority = 7,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .terrain = .{ .height_offset = -2.0 },
    },

    // === Land Biomes ===
    .{
        .id = .plains,
        .name = "Plains",
        .temperature = .{ .min = 0.35, .max = 0.70 },
        .humidity = .{ .min = 0.0, .max = 0.55 },
        .elevation = .{ .min = 0.25, .max = 0.55 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.45 },
        .priority = 1,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.oak}, .tree_density = 0.02, .grass_density = 0.3 },
        .terrain = .{ .height_amplitude = 0.7, .smoothing = 0.2 },
    },
    .{
        .id = .forest,
        .name = "Forest",
        .temperature = .{ .min = 0.35, .max = 0.70 },
        .humidity = .{ .min = 0.45, .max = 1.0 },
        .elevation = .{ .min = 0.25, .max = 0.65 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.55 },
        .priority = 2,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .oak, .birch }, .tree_density = 0.12, .bush_density = 0.05, .grass_density = 0.4 },
        .colors = .{ .grass = .{ 0.25, 0.55, 0.18 }, .foliage = .{ 0.18, 0.45, 0.12 } },
    },
    .{
        .id = .taiga,
        .name = "Taiga",
        .temperature = .{ .min = 0.20, .max = 0.42 },
        .humidity = .{ .min = 0.35, .max = 0.80 },
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .priority = 3,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .tree_density = 0.10, .grass_density = 0.2 },
        .colors = .{ .grass = .{ 0.35, 0.55, 0.25 }, .foliage = .{ 0.28, 0.48, 0.20 } },
    },
    .{
        .id = .desert,
        .name = "Desert",
        .temperature = .{ .min = 0.65, .max = 1.0 },
        .humidity = .{ .min = 0.0, .max = 0.35 },
        .elevation = .{ .min = 0.25, .max = 0.60 },
        .continentalness = .{ .min = 0.50, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.40 },
        .priority = 4,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 6 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0, .cactus_density = 0.015, .dead_bush_density = 0.02 },
        .terrain = .{ .height_amplitude = 0.5, .smoothing = 0.4, .height_offset = -4.0 }, // Flatter, smoother, lowered
        .colors = .{ .grass = .{ 0.75, 0.70, 0.35 } },
    },
    .{
        .id = .swamp,
        .name = "Swamp",
        .temperature = .{ .min = 0.50, .max = 0.80 },
        .humidity = .{ .min = 0.70, .max = 1.0 },
        .elevation = .{ .min = 0.20, .max = 0.40 }, // Near sea level
        .continentalness = .{ .min = 0.50, .max = 0.85 },
        .ruggedness = .{ .min = 0.0, .max = 0.30 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{.swamp_oak}, .tree_density = 0.08 },
        .terrain = .{ .clamp_to_sea_level = true, .height_offset = -2 }, // Waterlogged
        .colors = .{
            .grass = .{ 0.35, 0.45, 0.25 }, // Dark murky green
            .foliage = .{ 0.30, 0.40, 0.20 },
            .water = .{ 0.25, 0.35, 0.30 }, // Murky water
        },
    },
    .{
        .id = .snow_tundra,
        .name = "Snow Tundra",
        .temperature = .{ .min = 0.0, .max = 0.25 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.25, .max = 0.65 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .priority = 4,
        .surface = .{ .top = .snow_block, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .tree_density = 0.01 },
        .colors = .{ .grass = .{ 0.7, 0.75, 0.8 } },
    },

    // === Mountain Biomes ===
    .{
        .id = .mountains,
        .name = "Mountains",
        .temperature = .{ .min = 0.25, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.50, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .stone, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .terrain = .{ .height_amplitude = 1.5 }, // Amplified peaks
    },
    .{
        .id = .snowy_mountains,
        .name = "Snowy Mountains",
        .temperature = .{ .min = 0.0, .max = 0.35 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.45, .max = 1.0 },
        .priority = 7,
        .surface = .{ .top = .snow_block, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
        .terrain = .{ .height_amplitude = 1.4 },
        .colors = .{ .grass = .{ 0.85, 0.90, 0.95 } },
    },

    // === New Biomes ===
    .{
        .id = .mangrove_swamp,
        .name = "Mangrove Swamp",
        .temperature = .{ .min = 0.7, .max = 0.9 },
        .humidity = .{ .min = 0.8, .max = 1.0 },
        .elevation = .{ .min = 0.2, .max = 0.4 },
        .continentalness = .{ .min = 0.5, .max = 0.7 },
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
        .elevation = .{ .min = 0.3, .max = 0.7 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.jungle}, .tree_density = 0.25, .bamboo_density = 0.1, .melon_density = 0.05 },
        .colors = .{ .grass = .{ 0.2, 0.8, 0.1 }, .foliage = .{ 0.1, 0.7, 0.1 } },
    },
    .{
        .id = .savanna,
        .name = "Savanna",
        .temperature = .{ .min = 0.7, .max = 1.0 },
        .humidity = .{ .min = 0.3, .max = 0.5 },
        .priority = 4,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .tree_density = 0.01, .grass_density = 0.5 },
        .colors = .{ .grass = .{ 0.6, 0.6, 0.3 }, .foliage = .{ 0.5, 0.5, 0.3 } },
    },
    .{
        .id = .badlands,
        .name = "Badlands",
        .temperature = .{ .min = 0.7, .max = 1.0 },
        .humidity = .{ .min = 0.0, .max = 0.3 },
        .elevation = .{ .min = 0.4, .max = 0.8 },
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
        .continentalness = .{ .min = 0.0, .max = 0.2 },
        .priority = 20,
        .surface = .{ .top = .mycelium, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .huge_red_mushroom, .huge_brown_mushroom }, .tree_density = 0.05, .red_mushroom_density = 0.1, .brown_mushroom_density = 0.1 },
        .colors = .{ .grass = .{ 0.4, 0.8, 0.4 } },
    },

    // === Special Biomes ===
    .{
        .id = .river,
        .name = "River",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.35 },
        .priority = 15, // High priority when river mask active
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{}, .tree_density = 0 },
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
        const s = biome.score(params);
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
    // Fallback to plains
    return &BIOME_REGISTRY[3]; // plains index
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
    const height_above_sea = @max(0, height - sea_level);
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
};

/// Select top 2 biomes for blending
pub fn selectBiomeBlended(params: ClimateParams) BiomeSelection {
    var best_score: f32 = -1.0;
    var best_biome: BiomeId = .plains;
    var second_score: f32 = -1.0;
    var second_biome: BiomeId = .plains;

    for (BIOME_REGISTRY) |biome| {
        const s = biome.score(params);
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

    var blend: f32 = 0.0;
    const sum = best_score + second_score;
    if (sum > 0.0001) {
        blend = second_score / sum;
    }

    return .{
        .primary = best_biome,
        .secondary = second_biome,
        .blend_factor = blend,
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
            };
        }
    }
    return selection;
}
