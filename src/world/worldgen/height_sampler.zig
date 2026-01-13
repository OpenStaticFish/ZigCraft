//! HeightSampler - Terrain height computation component
//!
//! This module computes terrain height from noise values using V7-style
//! multi-layer terrain generation. It handles ocean/land decisions,
//! mountain/ridge generation, path carving, and peak compression.
//!
//! Part of Issue #147: Modularize Terrain Generation Pipeline

const std = @import("std");
const noise_mod = @import("noise.zig");
const smoothstep = noise_mod.smoothstep;
const clamp01 = noise_mod.clamp01;
const noise_sampler_mod = @import("noise_sampler.zig");
const NoiseSampler = noise_sampler_mod.NoiseSampler;
const ColumnNoiseValues = noise_sampler_mod.ColumnNoiseValues;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const PathInfo = region_pkg.PathInfo;
const world_class = @import("world_class.zig");
const ContinentalZone = world_class.ContinentalZone;

// ============================================================================
// Path System Constants
// ============================================================================
const VALLEY_DEPTH: f32 = 10.0;
const RIVER_DEPTH: f32 = 15.0;

// ============================================================================
// Configuration
// ============================================================================

/// Parameters for height computation
pub const HeightParams = struct {
    // Sea level
    sea_level: i32 = 64,

    // Continental zone thresholds
    ocean_threshold: f32 = 0.35,
    continental_deep_ocean_max: f32 = 0.20,
    continental_coast_max: f32 = 0.42,
    continental_inland_low_max: f32 = 0.60,
    continental_inland_high_max: f32 = 0.75,

    // Mountains
    mount_amp: f32 = 60.0,
    mount_cap: f32 = 120.0,
    mount_inland_min: f32 = 0.60,
    mount_inland_max: f32 = 0.80,
    mount_peak_min: f32 = 0.55,
    mount_peak_max: f32 = 0.85,
    mount_rugged_min: f32 = 0.35,
    mount_rugged_max: f32 = 0.75,

    // Ridges
    ridge_amp: f32 = 25.0,
    ridge_inland_min: f32 = 0.50,
    ridge_inland_max: f32 = 0.70,
    ridge_sparsity: f32 = 0.50,

    // Detail
    highland_range: f32 = 80.0,

    // Peak compression
    peak_compression_offset: f32 = 80.0,
    peak_compression_range: f32 = 80.0,
};

// ============================================================================
// HeightSampler
// ============================================================================

/// Computes terrain height from noise values.
/// Uses V7-style multi-layer terrain with region constraints.
pub const HeightSampler = struct {
    params: HeightParams,

    /// Initialize with default parameters
    pub fn init() HeightSampler {
        return initWithParams(.{});
    }

    /// Initialize with custom parameters
    pub fn initWithParams(params: HeightParams) HeightSampler {
        return .{ .params = params };
    }

    /// Get sea level
    pub fn getSeaLevel(self: *const HeightSampler) i32 {
        return self.params.sea_level;
    }

    /// Get sea level as float
    pub fn getSeaLevelFloat(self: *const HeightSampler) f32 {
        return @floatFromInt(self.params.sea_level);
    }

    /// Map continentalness value (0-1) to explicit zone
    pub fn getContinentalZone(self: *const HeightSampler, c: f32) ContinentalZone {
        const p = self.params;
        if (c < p.continental_deep_ocean_max) {
            return .deep_ocean;
        } else if (c < p.ocean_threshold) {
            return .ocean;
        } else if (c < p.continental_coast_max) {
            return .coast;
        } else if (c < p.continental_inland_low_max) {
            return .inland_low;
        } else if (c < p.continental_inland_high_max) {
            return .inland_high;
        } else {
            return .mountain_core;
        }
    }

    /// Check if a position is ocean based on continentalness
    pub fn isOcean(self: *const HeightSampler, continentalness: f32) bool {
        return continentalness < self.params.ocean_threshold;
    }

    /// Get mountain mask for height amplification
    pub fn getMountainMask(self: *const HeightSampler, pv: f32, e: f32, c: f32) f32 {
        const p = self.params;
        const inland = smoothstep(p.mount_inland_min, p.mount_inland_max, c);
        const peak_factor = smoothstep(p.mount_peak_min, p.mount_peak_max, pv);
        const rugged_factor = 1.0 - smoothstep(p.mount_rugged_min, p.mount_rugged_max, e);
        return inland * peak_factor * rugged_factor;
    }

    /// Base height from continentalness - only called for LAND (c >= ocean_threshold)
    fn getBaseHeight(self: *const HeightSampler, c: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // Coastal zone: rises from sea level
        if (c < p.continental_coast_max) {
            const range = p.continental_coast_max - p.ocean_threshold;
            const t = (c - p.ocean_threshold) / range;
            return sea + t * 8.0; // 0 to +8 blocks
        }

        // Inland Low: plains/forests
        if (c < p.continental_inland_low_max) {
            const range = p.continental_inland_low_max - p.continental_coast_max;
            const t = (c - p.continental_coast_max) / range;
            return sea + 8.0 + t * 12.0; // +8 to +20
        }

        // Inland High: hills
        if (c < p.continental_inland_high_max) {
            const range = p.continental_inland_high_max - p.continental_inland_low_max;
            const t = (c - p.continental_inland_low_max) / range;
            return sea + 20.0 + t * 15.0; // +20 to +35
        }

        // Mountain Core
        const t = smoothstep(p.continental_inland_high_max, 1.0, c);
        return sea + 35.0 + t * 25.0; // +35 to +60
    }

    /// Process path system effects on terrain
    fn processPath(path_info: PathInfo) struct { depth: f32, slope_suppress: f32 } {
        var path_depth: f32 = 0.0;
        var slope_suppress: f32 = 0.0;

        switch (path_info.path_type) {
            .valley => {
                path_depth = path_info.influence * VALLEY_DEPTH;
                slope_suppress = path_info.influence * 0.6;
            },
            .river => {
                path_depth = path_info.influence * RIVER_DEPTH;
                slope_suppress = path_info.influence * 0.8;
            },
            .plains_corridor => {
                path_depth = path_info.influence * 2.0;
                slope_suppress = path_info.influence * 0.9;
            },
            .none => {},
        }

        return .{ .depth = path_depth, .slope_suppress = slope_suppress };
    }

    /// Compute V7-style blended terrain height
    fn computeV7Terrain(noise: ColumnNoiseValues, mood_mult: f32) f32 {
        // Apply persistence variation to both heights
        const base_modulated = noise.terrain_base * noise.terrain_persist;
        const alt_modulated = noise.terrain_alt * noise.terrain_persist;

        // Blend between base and alt using height_select
        // select near 0 = more base terrain (rolling hills)
        // select near 1 = more alt terrain (flatter)
        const blend = clamp01((noise.height_select + 8.0) / 16.0);

        return std.math.lerp(base_modulated, alt_modulated, blend) * mood_mult;
    }

    /// STRUCTURE-FIRST height computation with V7-style multi-layer terrain.
    ///
    /// The KEY change: Ocean is decided by continentalness ALONE.
    /// Land uses blended terrain layers for varied terrain character.
    /// Region constraints suppress/exaggerate features per role.
    ///
    /// This is the main entry point for height computation.
    ///
    /// Parameters:
    /// - reduction: LOD reduction level (0-4). Higher values simplify noise sampling.
    pub fn computeHeight(
        self: *const HeightSampler,
        noise_sampler: *const NoiseSampler,
        noise: ColumnNoiseValues,
        region: RegionInfo,
        path_info: PathInfo,
        reduction: u8,
    ) f32 {
        // Validate reduction is in expected range (0-4 for LOD0-LOD3)
        std.debug.assert(reduction <= 4);

        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // ============================================================
        // STEP 1: HARD OCEAN DECISION
        // If continentalness < ocean_threshold, this is OCEAN.
        // Return ocean depth and STOP. No land logic runs here.
        // ============================================================
        if (noise.continentalness < p.ocean_threshold) {
            // Ocean depth varies smoothly with continentalness
            const ocean_depth_factor = noise.continentalness / p.ocean_threshold;
            const deep_ocean_depth = sea - 55.0;
            const shallow_ocean_depth = sea - 12.0;

            // Very minimal seabed variation - oceans should be BORING
            const seabed_detail = noise_sampler.getSeabedDetail(noise.warped_x, noise.warped_z, reduction);

            return std.math.lerp(deep_ocean_depth, shallow_ocean_depth, ocean_depth_factor) + seabed_detail;
        }

        // ============================================================
        // STEP 2: PATH SYSTEM (Priority Override)
        // Movement paths override region suppression locally
        // ============================================================
        const path_effects = processPath(path_info);

        // ============================================================
        // STEP 3: V7-STYLE MULTI-LAYER TERRAIN (Issue #105)
        // Blend terrain_base and terrain_alt using height_select
        // ============================================================
        const mood_mult = region_pkg.getHeightMultiplier(region);
        const v7_terrain = computeV7Terrain(noise, mood_mult);

        // ============================================================
        // STEP 4: LAND - Combine V7 terrain with continental base
        // ============================================================
        var height = self.getBaseHeight(noise.continentalness) + v7_terrain - path_effects.depth;

        // ============================================================
        // STEP 5: Mountains & Ridges - REGION-CONSTRAINED
        // Only apply if allowHeightDrama is true
        // ============================================================
        if (region_pkg.allowHeightDrama(region) and noise.continentalness > p.continental_inland_low_max) {
            const m_mask = self.getMountainMask(noise.peaks_valleys, noise.erosion, noise.continentalness);
            const lift_noise = noise_sampler.getMountainLift(noise.warped_x, noise.warped_z, reduction);
            const mount_lift = (m_mask * lift_noise * p.mount_amp) / (1.0 + (m_mask * lift_noise * p.mount_amp) / p.mount_cap);
            height += mount_lift * mood_mult;

            const ridge_params = NoiseSampler.RidgeParams{
                .inland_min = p.ridge_inland_min,
                .inland_max = p.ridge_inland_max,
                .sparsity = p.ridge_sparsity,
            };
            const ridge_val = noise_sampler.getRidgeFactor(noise.warped_x, noise.warped_z, noise.continentalness, reduction, ridge_params);
            height += ridge_val * p.ridge_amp * mood_mult;
        }

        // ============================================================
        // STEP 6: Fine Detail - Attenuated by slope suppression
        // ============================================================
        const erosion_smooth = smoothstep(0.5, 0.75, noise.erosion);
        const land_factor = smoothstep(p.continental_coast_max, p.continental_inland_low_max, noise.continentalness);
        const hills_atten = (1.0 - erosion_smooth) * land_factor * (1.0 - path_effects.slope_suppress);

        // Small-scale detail
        const elev01 = clamp01((height - sea) / p.highland_range);
        const detail_atten = 1.0 - smoothstep(0.3, 0.85, elev01);

        const detail = noise_sampler.getDetail(noise.warped_x, noise.warped_z, reduction);
        height += detail * detail_atten * hills_atten * mood_mult;

        // ============================================================
        // STEP 7: Post-Processing - Peak compression
        // ============================================================
        const peak_start = sea + p.peak_compression_offset;
        if (height > peak_start) {
            const h_above = height - peak_start;
            const compressed = p.peak_compression_range * (1.0 - std.math.exp(-h_above / p.peak_compression_range));
            height = peak_start + compressed;
        }

        // ============================================================
        // STEP 8: River Carving - REGION-CONSTRAINED
        // ============================================================
        if (region_pkg.allowRiver(region) and noise.river_mask > 0.001 and noise.continentalness > p.continental_coast_max) {
            const river_bed = sea - 4.0;
            const carve_alpha = smoothstep(0.0, 1.0, noise.river_mask);
            if (height > river_bed) {
                height = std.math.lerp(height, river_bed, carve_alpha);
            }
        }

        return height;
    }

    /// Simplified height computation for quick sampling
    /// Uses pre-computed noise values directly without additional sampling
    pub fn computeHeightSimple(
        self: *const HeightSampler,
        c: f32,
        e: f32,
        pv: f32,
        v7_terrain: f32,
        seabed_detail: f32,
        mood_mult: f32,
    ) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // Ocean
        if (c < p.ocean_threshold) {
            const ocean_depth_factor = c / p.ocean_threshold;
            const deep_ocean_depth = sea - 55.0;
            const shallow_ocean_depth = sea - 12.0;
            return std.math.lerp(deep_ocean_depth, shallow_ocean_depth, ocean_depth_factor) + seabed_detail;
        }

        // Land
        var height = self.getBaseHeight(c) + v7_terrain * mood_mult;

        // Basic mountain contribution for simplified version
        if (c > p.continental_inland_low_max) {
            const m_mask = self.getMountainMask(pv, e, c);
            const mount_contrib = m_mask * p.mount_amp * 0.5; // Simplified
            height += mount_contrib * mood_mult;
        }

        // Peak compression
        const peak_start = sea + p.peak_compression_offset;
        if (height > peak_start) {
            const h_above = height - peak_start;
            const compressed = p.peak_compression_range * (1.0 - std.math.exp(-h_above / p.peak_compression_range));
            height = peak_start + compressed;
        }

        return height;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HeightSampler continental zones" {
    const sampler = HeightSampler.init();

    // Deep ocean
    try std.testing.expectEqual(ContinentalZone.deep_ocean, sampler.getContinentalZone(0.1));

    // Ocean
    try std.testing.expectEqual(ContinentalZone.ocean, sampler.getContinentalZone(0.25));

    // Coast
    try std.testing.expectEqual(ContinentalZone.coast, sampler.getContinentalZone(0.38));

    // Inland low
    try std.testing.expectEqual(ContinentalZone.inland_low, sampler.getContinentalZone(0.50));

    // Inland high
    try std.testing.expectEqual(ContinentalZone.inland_high, sampler.getContinentalZone(0.70));

    // Mountain core
    try std.testing.expectEqual(ContinentalZone.mountain_core, sampler.getContinentalZone(0.90));
}

test "HeightSampler ocean detection" {
    const sampler = HeightSampler.init();

    try std.testing.expect(sampler.isOcean(0.0));
    try std.testing.expect(sampler.isOcean(0.34));
    try std.testing.expect(!sampler.isOcean(0.35));
    try std.testing.expect(!sampler.isOcean(0.5));
}

test "HeightSampler mountain mask range" {
    const sampler = HeightSampler.init();

    // Mountain mask should be in 0-1 range
    const m1 = sampler.getMountainMask(0.8, 0.3, 0.8);
    try std.testing.expect(m1 >= 0.0 and m1 <= 1.0);

    const m2 = sampler.getMountainMask(0.2, 0.8, 0.4);
    try std.testing.expect(m2 >= 0.0 and m2 <= 1.0);
}
