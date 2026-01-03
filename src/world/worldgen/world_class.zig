//! World Classification Map - authoritative world layout for LOD
//!
//! Computed ONCE per region, deterministically
//! All LOD levels sample from this SAME map (no re-computation)
//!
//! LOD-INVARIANT: These values MUST be identical for all LODs:
//! - Biome ID
//! - Region Role / Mood
//! - Land vs water decision
//! - Sand vs grass vs rock surface type
//! - Lake existence (not shape detail)
//! - Path / valley / river masks

const std = @import("std");
const BiomeId = @import("biome.zig").BiomeId;
const region = @import("region.zig");

// Re-export region types for convenience
pub const RegionRole = region.RegionRole;
pub const PathType = region.PathType;

pub const CELL_SIZE: u32 = 8;

/// Surface types (what's on top at this position)
pub const SurfaceType = enum(u8) {
    grass,
    sand,
    rock,
    snow,
    water_deep,
    water_shallow,
    dirt,
    stone,
};

/// Continental zones - structural terrain classification
/// (distinct from RegionRole which is about gameplay/features)
pub const ContinentalZone = enum(u8) {
    deep_ocean,
    ocean,
    coast,
    inland_low,
    inland_high,
    mountain_core,

    /// Get zone name as string for debugging
    pub fn name(self: ContinentalZone) []const u8 {
        return switch (self) {
            .deep_ocean => "Deep Ocean",
            .ocean => "Ocean",
            .coast => "Coast",
            .inland_low => "Inland Low",
            .inland_high => "Inland High",
            .mountain_core => "Mountain Core",
        };
    }
};

/// Single classification cell
pub const ClassCell = struct {
    /// Main biome ID (from biome blending)
    biome_id: BiomeId,
    /// What surface material is on top
    surface_type: SurfaceType,
    /// Is this position water (boolean)
    is_water: bool,
    /// Continental zone for terrain structure
    continental_zone: ContinentalZone,
    /// Region role for feature control (transit/destination/boundary)
    region_role: RegionRole,
    /// Path influence at this location
    path_type: PathType,
};

/// Derive surface type from biome and terrain parameters
pub fn deriveSurfaceType(
    biome_id: BiomeId,
    height: i32,
    sea_level: i32,
    is_ocean: bool,
) SurfaceType {
    // Water cases
    if (is_ocean and height < sea_level - 30) return .water_deep;
    if (is_ocean and height < sea_level) return .water_shallow;

    // Biome-based surface
    return switch (biome_id) {
        .desert, .badlands, .beach => .sand,
        .snow_tundra, .snowy_mountains => .snow,
        .mountains => if (height > 120) .rock else .stone,
        .deep_ocean, .ocean => .sand,
        else => .grass,
    };
}

/// World Classification Map
pub const WorldClassMap = struct {
    /// Grid dimensions
    const GRID_SIZE_X: u32 = 10;
    const GRID_SIZE_Z: u32 = 10;
    const CELL_COUNT: u32 = GRID_SIZE_X * GRID_SIZE_Z;

    /// Classification grid (2D array of cells)
    cells: [CELL_COUNT]ClassCell,

    /// Initialize classification map
    pub fn init() WorldClassMap {
        return .{
            .cells = undefined,
        };
    }

    /// Get classification cell at local grid coordinates
    pub fn getCell(self: *const WorldClassMap, gx: u32, gz: u32) *const ClassCell {
        if (gx >= GRID_SIZE_X or gz >= GRID_SIZE_Z) {
            // Return default cell for out of bounds
            const default_cell = ClassCell{
                .biome_id = .plains,
                .surface_type = .grass,
                .is_water = false,
                .continental_zone = .inland_low,
                .region_role = .transit,
                .path_type = .none,
            };
            return &default_cell;
        }
        return &self.cells[gx + gz * GRID_SIZE_X];
    }
};
