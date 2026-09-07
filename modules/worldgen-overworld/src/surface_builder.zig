//! SurfaceBuilder - Surface block placement rules component
//!
//! This module defines rules for placing surface blocks based on biome,
//! structural conditions (slope, height, coastal proximity), and depth.
//! It separates surface placement logic from terrain shape generation.
//!
//! Part of Issue #147: Modularize Terrain Generation Pipeline

const std = @import("std");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const Biome = world_core.Biome;
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const BiomeDefinition = biome_mod.BiomeDefinition;
const Chunk = world_core.Chunk;

// ============================================================================
// Types
// ============================================================================

/// Coastal surface type determined by structural signals
pub const CoastalSurfaceType = enum {
    none, // Not in coastal zone OR near inland water (use biome default)
    sand_beach, // Gentle slope near sea level, adjacent to OCEAN -> sand
    gravel_beach, // Reserved for explicit gravel shore biomes; not auto-painted broadly
    cliff, // Reserved for explicit cliff biomes; not auto-painted broadly
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
    beach_max_slope: i32 = 1,
    cliff_min_slope: i32 = 5, // Reserved; structural coasts no longer auto-paint cliffs.
    gravel_erosion_threshold: f32 = 0.7, // Reserved for explicit shore biomes.

    // Coastal zone (continentalness thresholds)
    ocean_threshold: f32 = 0.37,
    beach_band: f32 = 0.035, // Width of beach zone in continentalness units
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
    /// 4. Slope is very gentle
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

        _ = erosion;

        // Do not auto-paint cliffs or gravel beaches from slope/erosion here.
        // Broad structural overrides made coastlines look like concrete slabs;
        // biome-specific shore types should opt into those materials explicitly.
        if (slope > p.beach_max_slope) return .none;

        // Gentle slopes at sea level become sand beaches
        return .sand_beach;
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
        const biome_id: BiomeId = @enumFromInt(@intFromEnum(biome));
        const biome_def = biome_mod.getBiomeDefinition(biome_id);

        // Bedrock floor
        if (y == 0) return .bedrock;

        // Above terrain: water or air
        if (y > terrain_height) {
            if ((biome == .frozen_ocean or biome == .frozen_river) and y == sea_level) return .ice;
            if (y <= sea_level) return .water;
            return .air;
        }

        // Ocean floor: sand in shallow water, clay/gravel in deep
        if (is_ocean_water and is_underwater and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 5) return .sand; // Only the immediate waterline should be sandy.
            if (depth <= 30) return .clay; // Medium depth: clay
            return .gravel; // Deep: gravel
        }

        // Ocean shallow underwater filler for continuity
        if (is_ocean_water and is_underwater and y > terrain_height - 3) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 5) return .sand;
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
            if (biome == .forest or biome == .birch_forest or biome == .dark_forest or biome == .flower_forest) {
                if (y > 120) return .stone;
            }

            if (biome == .snowy_mountains or biome == .snow_tundra or biome == .snowy_taiga or biome == .snowy_slopes or biome == .snowy_beach) return .snow_block;
            if (biome == .frozen_ocean) return .packed_ice;
            if (biome == .frozen_river) return .ice;
            return biome_def.surface.top;
        }

        // Filler blocks (dirt layer under surface)
        if (y > terrain_height - filler_depth) return biome_def.surface.filler;

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
        const coastal_fill_depth = @max(filler_depth, 3);
        const is_coastal_fill = (y > terrain_height - coastal_fill_depth and y <= terrain_height);

        // Apply structural coastal surface types (ocean beaches only)
        if (is_surface and block != .air and block != .water and block != .bedrock) {
            switch (coastal_type) {
                .sand_beach => block = .sand,
                .gravel_beach, .cliff => {},
                .none => {},
            }
        } else if (is_coastal_fill and coastal_type == .sand_beach and block != .air and block != .water and block != .bedrock) {
            block = .sand;
        }

        return block;
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

    // Steep coasts keep their biome surface; broad auto-painted stone looked artificial.
    const cliff = builder.getCoastalSurfaceType(0.37, 6, 65, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, cliff);

    // High erosion no longer auto-paints gravel slabs.
    const gravel = builder.getCoastalSurfaceType(0.37, 2, 65, 0.8);
    try std.testing.expectEqual(CoastalSurfaceType.none, gravel);

    // Too far inland: no coastal type
    const inland = builder.getCoastalSurfaceType(0.50, 1, 70, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, inland);

    // Too high above sea: no coastal type
    const high = builder.getCoastalSurfaceType(0.37, 1, 80, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, high);
}

test "SurfaceBuilder beach band matches coastal biome range" {
    const builder = SurfaceBuilder.init();

    const upper_beach = builder.getCoastalSurfaceType(0.40, 1, 67, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.sand_beach, upper_beach);

    const inland = builder.getCoastalSurfaceType(0.41, 1, 67, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, inland);
}

test "SurfaceBuilder coastal beach replaces exposed filler" {
    const builder = SurfaceBuilder.init();
    const coastal_type = builder.getCoastalSurfaceType(0.38, 1, 65, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.sand_beach, coastal_type);

    // At height 65 the minimum three-block beach layer occupies Y=63..65.
    // Deeper biome filler extends that layer, but never paints the stone below it.
    const cases = [_]struct { filler_depth: i32, bottom_sand_y: i32, stone_y: i32 }{
        .{ .filler_depth = 1, .bottom_sand_y = 63, .stone_y = 62 },
        .{ .filler_depth = 3, .bottom_sand_y = 63, .stone_y = 62 },
        .{ .filler_depth = 5, .bottom_sand_y = 61, .stone_y = 60 },
    };
    for (cases) |case| {
        var y = case.bottom_sand_y;
        while (y <= 65) : (y += 1) {
            try std.testing.expectEqual(BlockType.sand, builder.getSurfaceBlock(y, 65, .plains, case.filler_depth, false, false, coastal_type));
        }
        try std.testing.expectEqual(BlockType.stone, builder.getSurfaceBlock(case.stone_y, 65, .plains, case.filler_depth, false, false, coastal_type));
        try std.testing.expectEqual(BlockType.air, builder.getSurfaceBlock(66, 65, .plains, case.filler_depth, false, false, coastal_type));
        try std.testing.expectEqual(BlockType.bedrock, builder.getSurfaceBlock(0, 65, .plains, case.filler_depth, false, false, coastal_type));
    }
    try std.testing.expectEqual(BlockType.dirt, builder.getSurfaceBlock(64, 65, .plains, 3, false, false, .none));

    // The old fixture forced a beach at height 70, above the shoreline band.
    const high_coast = builder.getCoastalSurfaceType(0.38, 1, 70, 0.3);
    try std.testing.expectEqual(CoastalSurfaceType.none, high_coast);
    try std.testing.expectEqual(BlockType.stone, builder.getSurfaceBlock(65, 70, .plains, 3, false, false, high_coast));
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

test "SurfaceBuilder freezes cold biome water surface" {
    const builder = SurfaceBuilder.init();
    const frozen_ocean = builder.getBlockAt(64, 55, .frozen_ocean, 3, true, true);
    try std.testing.expectEqual(BlockType.ice, frozen_ocean);

    const below_ice = builder.getBlockAt(63, 55, .frozen_ocean, 3, true, true);
    try std.testing.expectEqual(BlockType.water, below_ice);

    const frozen_river = builder.getBlockAt(64, 55, .frozen_river, 3, false, true);
    try std.testing.expectEqual(BlockType.ice, frozen_river);
}

test "SurfaceBuilder air above terrain above sea level" {
    const builder = SurfaceBuilder.init();
    const block = builder.getBlockAt(80, 70, .plains, 3, false, false);
    try std.testing.expectEqual(BlockType.air, block);
}

test "SurfaceBuilder ocean floor material depth boundaries" {
    // Sand is confined to the immediate waterline; depth 9 is clay, not sand.
    const cases = [_]struct { depth: i32, block: BlockType }{
        .{ .depth = 1, .block = .sand },
        .{ .depth = 5, .block = .sand },
        .{ .depth = 6, .block = .clay },
        .{ .depth = 9, .block = .clay },
        .{ .depth = 30, .block = .clay },
        .{ .depth = 31, .block = .gravel },
    };
    for ([_]i32{ 64, 80 }) |sea_level| {
        const builder = SurfaceBuilder.initWithParams(.{ .sea_level = sea_level });
        for (cases) |case| {
            const floor_y = sea_level - case.depth;
            try std.testing.expectEqual(case.block, builder.getBlockAt(floor_y, floor_y, .ocean, 3, true, true));
            try std.testing.expectEqual(BlockType.water, builder.getBlockAt(floor_y + 1, floor_y, .ocean, 3, true, true));
        }

        const shallow_floor_y = sea_level - 5;
        try std.testing.expectEqual(BlockType.sand, builder.getBlockAt(shallow_floor_y - 2, shallow_floor_y, .ocean, 3, true, true));
        try std.testing.expectEqual(BlockType.stone, builder.getBlockAt(shallow_floor_y - 3, shallow_floor_y, .ocean, 3, true, true));
    }
}

test "SurfaceBuilder inland water floor" {
    const builder = SurfaceBuilder.init();
    // Inland water should be dirt, not sand
    const block = builder.getBlockAt(60, 60, .plains, 3, false, true);
    try std.testing.expectEqual(BlockType.dirt, block);
}
