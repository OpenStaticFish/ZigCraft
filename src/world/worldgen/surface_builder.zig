//! SurfaceBuilder - Surface block placement rules component
//!
//! This module defines rules for placing surface blocks based on biome,
//! structural conditions (slope, height, coastal proximity), and depth.
//! It separates surface placement logic from terrain shape generation.
//!
//! Part of Issue #147: Modularize Terrain Generation Pipeline

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const Biome = @import("../block.zig").Biome;
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const BiomeDefinition = biome_mod.BiomeDefinition;
const Chunk = @import("../chunk.zig").Chunk;

// ============================================================================
// Types
// ============================================================================

/// Coastal surface type determined by structural signals
pub const CoastalSurfaceType = enum {
    none, // Not in coastal zone OR near inland water (use biome default)
    sand_beach, // Gentle slope near sea level, adjacent to OCEAN -> sand
    gravel_beach, // High erosion coastal area adjacent to OCEAN -> gravel
    cliff, // Steep slope in coastal zone -> stone
};

// ============================================================================
// Configuration
// ============================================================================

/// Parameters for surface placement
pub const SurfaceParams = struct {
    // Sea level
    sea_level: i32 = 64,

    // Beach constraints
    beach_max_height_above_sea: i32 = 3,
    beach_max_slope: i32 = 2,
    cliff_min_slope: i32 = 5,
    gravel_erosion_threshold: f32 = 0.7,

    // Coastal zone (continentalness thresholds)
    ocean_threshold: f32 = 0.35,
    beach_band: f32 = 0.05, // Width of beach zone in continentalness units

    // Coastal tree restriction zone
    coastal_no_tree_min: i32 = 8,
    coastal_no_tree_max: i32 = 18,
};

// ============================================================================
// SurfaceBuilder
// ============================================================================

/// Handles surface block placement based on biome and structural conditions.
pub const SurfaceBuilder = struct {
    params: SurfaceParams,

    /// Initialize with default parameters
    pub fn init() SurfaceBuilder {
        return initWithParams(.{});
    }

    /// Initialize with custom parameters
    pub fn initWithParams(params: SurfaceParams) SurfaceBuilder {
        return .{ .params = params };
    }

    /// Determine coastal surface type based on structural signals.
    ///
    /// KEY RULE (Issue #92): Beach requires adjacency to OCEAN water, not just any water.
    /// - Ocean water: continentalness < ocean_threshold
    /// - Inland water (lakes/rivers): continentalness >= ocean_threshold but below sea level
    ///
    /// Beach forms ONLY when:
    /// 1. This block is LAND (above sea level)
    /// 2. This block is near OCEAN (continentalness indicates ocean proximity)
    /// 3. Height is within beach_max_height_above_sea of sea level
    /// 4. Slope is gentle
    ///
    /// Inland water (lakes/rivers) get grass/dirt banks, NOT sand.
    pub fn getCoastalSurfaceType(
        self: *const SurfaceBuilder,
        continentalness: f32,
        slope: i32,
        height: i32,
        erosion: f32,
    ) CoastalSurfaceType {
        const p = self.params;

        // CONSTRAINT 1: Height above sea level
        // Beaches only exist in a tight band around sea level
        const height_above_sea = height - p.sea_level;

        // If underwater or more than N blocks above sea, never a beach
        if (height_above_sea < -1 or height_above_sea > p.beach_max_height_above_sea) {
            return .none;
        }

        // CONSTRAINT 2: Must be adjacent to OCEAN
        // Beach only in a VERY narrow band just above ocean threshold
        const near_ocean = continentalness >= p.ocean_threshold and
            continentalness < (p.ocean_threshold + p.beach_band);

        if (!near_ocean) {
            return .none;
        }

        // CONSTRAINT 3: Classify based on slope and erosion

        // Steep slopes become cliffs (stone)
        if (slope >= p.cliff_min_slope) {
            return .cliff;
        }

        // High erosion areas become gravel beaches
        if (erosion >= p.gravel_erosion_threshold and slope <= p.beach_max_slope + 1) {
            return .gravel_beach;
        }

        // Gentle slopes at sea level become sand beaches
        if (slope <= p.beach_max_slope) {
            return .sand_beach;
        }

        // Moderate slopes - no special treatment
        return .none;
    }

    /// Get block type at a specific Y coordinate.
    ///
    /// KEY RULE: Distinguish between ocean floor and inland water floor:
    /// - Ocean floor: sand in shallow water, gravel/clay in deep water
    /// - Inland water floor (lakes/rivers): dirt/gravel, NOT sand (no lake beaches)
    pub fn getBlockAt(
        self: *const SurfaceBuilder,
        y: i32,
        terrain_height: i32,
        biome: Biome,
        filler_depth: i32,
        is_ocean_water: bool,
        is_underwater: bool,
    ) BlockType {
        const sea_level = self.params.sea_level;
        const sea: f32 = @floatFromInt(sea_level);

        // Bedrock floor
        if (y == 0) return .bedrock;

        // Above terrain: water or air
        if (y > terrain_height) {
            if (y <= sea_level) return .water;
            return .air;
        }

        // Ocean floor: sand in shallow water, clay/gravel in deep
        if (is_ocean_water and is_underwater and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 12) return .sand; // Shallow ocean: sand
            if (depth <= 30) return .clay; // Medium depth: clay
            return .gravel; // Deep: gravel
        }

        // Ocean shallow underwater filler for continuity
        if (is_ocean_water and is_underwater and y > terrain_height - 3) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 12) return .sand;
        }

        // INLAND WATER (lakes/rivers): dirt/gravel banks, NOT sand
        // This prevents "lake beaches" - inland water should look natural
        if (!is_ocean_water and is_underwater and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 8) return .dirt; // Shallow lake: dirt banks
            if (depth <= 20) return .gravel; // Medium: gravel
            return .clay; // Deep lake: clay
        }

        // Surface block - elevation-aware surface morphing (Issue #110)
        if (y == terrain_height) {
            // Plains -> Grassland (low) -> Rolling Hills (mid) -> Windswept/Rocky (high)
            if (biome == .plains) {
                if (y > 110) return .stone; // High windswept areas
                if (y > 90) return .gravel; // Transition
            }
            // Forest -> Standard -> Rocky peaks
            if (biome == .forest) {
                if (y > 120) return .stone;
            }

            if (biome == .snowy_mountains or biome == .snow_tundra) return .snow_block;
            return biome.getSurfaceBlock();
        }

        // Filler blocks (dirt layer under surface)
        if (y > terrain_height - filler_depth) return biome.getFillerBlock();

        // Deep underground
        return .stone;
    }

    /// Apply surface block with coastal override
    pub fn getSurfaceBlock(
        self: *const SurfaceBuilder,
        y: i32,
        terrain_height: i32,
        biome: Biome,
        filler_depth: i32,
        is_ocean_water: bool,
        is_underwater: bool,
        coastal_type: CoastalSurfaceType,
    ) BlockType {
        // Get base block
        var block = self.getBlockAt(y, terrain_height, biome, filler_depth, is_ocean_water, is_underwater);

        const is_surface = (y == terrain_height);
        const is_near_surface = (y > terrain_height - 3 and y <= terrain_height);

        // Apply structural coastal surface types (ocean beaches only)
        if (is_surface and block != .air and block != .water and block != .bedrock) {
            switch (coastal_type) {
                .sand_beach => block = .sand,
                .gravel_beach => block = .gravel,
                .cliff => block = .stone,
                .none => {},
            }
        } else if (is_near_surface and (coastal_type == .sand_beach or coastal_type == .gravel_beach) and block == .dirt) {
            block = if (coastal_type == .gravel_beach) .gravel else .sand;
        }

        return block;
    }

    /// Check if position is in coastal no-tree zone
    pub fn isInCoastalNoTreeZone(self: *const SurfaceBuilder, height: i32) bool {
        const p = self.params;
        const diff = height - p.sea_level;
        return diff >= 0 and diff <= p.coastal_no_tree_max and diff >= p.coastal_no_tree_min;
    }

    /// Get filler depth for a biome
    pub fn getFillerDepth(_: *const SurfaceBuilder, biome_id: BiomeId) i32 {
        const biome_def = biome_mod.getBiomeDefinition(biome_id);
        return biome_def.surface.depth_range;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SurfaceBuilder coastal type detection" {
    const builder = SurfaceBuilder.init();

    // Sand beach: low slope, near ocean, at sea level
    const sand = builder.getCoastalSurfaceType(0.37, 1, 65, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.sand_beach, sand);

    // Cliff: high slope
    const cliff = builder.getCoastalSurfaceType(0.37, 6, 65, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.cliff, cliff);

    // Gravel beach: high erosion
    const gravel = builder.getCoastalSurfaceType(0.37, 2, 65, 0.8);
    try std.testing.expectEqual(CoastalSurfaceType.gravel_beach, gravel);

    // Too far inland: no coastal type
    const inland = builder.getCoastalSurfaceType(0.50, 1, 70, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, inland);

    // Too high above sea: no coastal type
    const high = builder.getCoastalSurfaceType(0.37, 1, 80, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, high);
}

test "SurfaceBuilder bedrock at y=0" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(0, 50, .plains, 3, false, false);
    try std.testing.expectEqual(BlockType.bedrock, block);
}

test "SurfaceBuilder water above terrain below sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(60, 55, .plains, 3, false, true);
    try std.testing.expectEqual(BlockType.water, block);
}

test "SurfaceBuilder air above terrain above sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(80, 70, .plains, 3, false, false);
    try std.testing.expectEqual(BlockType.air, block);
}

test "SurfaceBuilder ocean floor shallow" {
    const builder = SurfaceBuilder.init();
    // Shallow ocean (depth <= 12): sand
    const block = builder.getBlockAt(55, 55, .ocean, 3, true, true);
    try std.testing.expectEqual(BlockType.sand, block);
}

test "SurfaceBuilder inland water floor" {
    const builder = SurfaceBuilder.init();
    // Inland water should be dirt, not sand
    const block = builder.getBlockAt(60, 60, .plains, 3, false, true);
    try std.testing.expectEqual(BlockType.dirt, block);
}
