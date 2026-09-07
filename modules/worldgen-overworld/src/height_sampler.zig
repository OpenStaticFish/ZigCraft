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
const PathInfo = region_pkg.PathInfo;
const RegionControls = region_pkg.RegionControls;
const TerrainModifier = @import("biome_registry.zig").TerrainModifier;
const world_class = @import("world_class.zig");

const COASTAL_DETAIL_BLEND_WEIGHT: f32 = 0.45;
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
    ocean_threshold: f32 = 0.37,
    continental_deep_ocean_max: f32 = 0.20,
    continental_coast_max: f32 = 0.44,
    continental_inland_low_max: f32 = 0.58,
    continental_inland_high_max: f32 = 0.72,

    // Mountains
    mount_amp: f32 = 78.0,
    mount_cap: f32 = 140.0,
    mount_inland_min: f32 = 0.56,
    mount_inland_max: f32 = 0.76,
    mount_peak_min: f32 = 0.50,
    mount_peak_max: f32 = 0.82,
    mount_rugged_min: f32 = 0.32,
    mount_rugged_max: f32 = 0.72,

    // Ridges
    ridge_amp: f32 = 34.0,
    ridge_inland_min: f32 = 0.48,
    ridge_inland_max: f32 = 0.68,
    ridge_sparsity: f32 = 0.46,

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
            const t = smoothstep(0.0, 1.0, (c - p.ocean_threshold) / range);
            return sea + t * 2.5; // Narrow shore lift only
        }

        // Inland lowlands use terrain noise for relief, not a continental ramp.
        if (c < p.continental_inland_low_max) {
            return sea + 2.5;
        }

        // Inland High: hills
        if (c < p.continental_inland_high_max) {
            const range = p.continental_inland_high_max - p.continental_inland_low_max;
            const t = smoothstep(0.0, 1.0, (c - p.continental_inland_low_max) / range);
            return sea + 2.5 + t * 27.5; // +2.5 to +30
        }

        // Mountain Core
        const t = smoothstep(p.continental_inland_high_max, 1.0, c);
        return sea + 30.0 + t * 30.0; // +30 to +60
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

    pub fn compressPeakHeight(self: *const HeightSampler, height: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);
        const peak_start = sea + p.peak_compression_offset;
        if (height <= peak_start) return height;

        const h_above = height - peak_start;
        const compressed = p.peak_compression_range * (1.0 - std.math.exp(-h_above / p.peak_compression_range));
        return peak_start + compressed;
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
    /// - reduction: Detail-reduction level (0-4). Higher values simplify noise sampling.
    pub fn computeHeight(
        self: *const HeightSampler,
        noise_sampler: *const NoiseSampler,
        noise: ColumnNoiseValues,
        controls: RegionControls,
        path_info: PathInfo,
        reduction: u8,
    ) f32 {
        return self.computeHeightWithTerrainModifier(noise_sampler, noise, controls, path_info, reduction, null);
    }

    pub fn computeHeightWithTerrainModifier(
        self: *const HeightSampler,
        noise_sampler: *const NoiseSampler,
        noise: ColumnNoiseValues,
        controls: RegionControls,
        path_info: PathInfo,
        reduction: u8,
        terrain_modifier: ?TerrainModifier,
    ) f32 {
        // Validate the supported detail-reduction range.
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
        const mood_mult = controls.height_mult;
        const lowland_mask = smoothstep(p.ocean_threshold, p.continental_coast_max, noise.continentalness) *
            (1.0 - smoothstep(p.continental_inland_low_max, p.continental_inland_high_max, noise.continentalness));
        const terrain_mood = std.math.lerp(mood_mult, @max(mood_mult, 0.7), lowland_mask);
        const v7_terrain = computeV7Terrain(noise, terrain_mood);

        // ============================================================
        // STEP 4: LAND - Combine V7 terrain with continental base
        // ============================================================
        const coastal_ramp = smoothstep(p.ocean_threshold, p.continental_coast_max, noise.continentalness);
        var height = self.getBaseHeight(noise.continentalness) + v7_terrain * coastal_ramp - path_effects.depth * coastal_ramp;

        // ============================================================
        // STEP 5: Mountains & Ridges - REGION-CONSTRAINED
        // Only apply if allowHeightDrama is true
        // ============================================================
        if (controls.drama_mask > 0.001 and noise.continentalness > p.continental_inland_low_max) {
            const m_mask = self.getMountainMask(noise.peaks_valleys, noise.erosion, noise.continentalness);
            const lift_noise = noise_sampler.getMountainLift(noise.warped_x, noise.warped_z, reduction);
            const mount_lift = (m_mask * lift_noise * p.mount_amp) / (1.0 + (m_mask * lift_noise * p.mount_amp) / p.mount_cap);
            height += mount_lift * mood_mult * controls.drama_mask;

            const ridge_params = NoiseSampler.RidgeParams{
                .inland_min = p.ridge_inland_min,
                .inland_max = p.ridge_inland_max,
                .sparsity = p.ridge_sparsity,
            };
            const ridge_val = noise_sampler.getRidgeFactor(noise.warped_x, noise.warped_z, noise.continentalness, reduction, ridge_params);
            height += ridge_val * p.ridge_amp * mood_mult * controls.drama_mask;
        }

        // ============================================================
        // STEP 6: Fine Detail - Attenuated by slope suppression
        // ============================================================
        const erosion_smooth = smoothstep(0.5, 0.75, noise.erosion);
        const land_factor = smoothstep(p.continental_coast_max, p.continental_inland_low_max, noise.continentalness);
        const coastal_detail_factor = coastal_ramp * (1.0 - land_factor) * COASTAL_DETAIL_BLEND_WEIGHT;
        const lowland_detail_factor = @max(land_factor, coastal_detail_factor);
        const hills_atten = (1.0 - erosion_smooth) * lowland_detail_factor * coastal_ramp * (1.0 - path_effects.slope_suppress);

        // Small-scale detail
        const elev01 = clamp01((height - sea) / p.highland_range);
        const detail_atten = 1.0 - smoothstep(0.3, 0.85, elev01);

        const detail = noise_sampler.getDetail(noise.warped_x, noise.warped_z, reduction);
        height += detail * detail_atten * hills_atten * mood_mult;

        // ============================================================
        // STEP 7: Post-Processing - Peak compression
        // ============================================================
        if (terrain_modifier) |modifier| {
            height = modifier.applyHeight(height, sea);
        }
        height = self.compressPeakHeight(height);

        // ============================================================
        // STEP 8: River Carving - REGION-CONSTRAINED
        // ============================================================
        if (controls.river_mask > 0.001 and noise.river_mask > 0.001 and noise.continentalness > p.continental_coast_max) {
            const river_bed = sea - 4.0;
            const carve_alpha = smoothstep(0.0, 1.0, noise.river_mask) * controls.river_mask;
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
        height = self.compressPeakHeight(height);

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
    try std.testing.expect(sampler.isOcean(0.36));
    try std.testing.expect(!sampler.isOcean(0.37));
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

test "HeightSampler peak compression caps extreme mountain output" {
    const sampler = HeightSampler.init();
    const compressed = sampler.compressPeakHeight(320.0);
    const max_asymptote = @as(f32, @floatFromInt(sampler.params.sea_level)) + sampler.params.peak_compression_offset + sampler.params.peak_compression_range;

    try std.testing.expect(compressed < 320.0);
    try std.testing.expect(compressed < max_asymptote);
}

fn testNoiseValues(continentalness: f32, terrain: f32) ColumnNoiseValues {
    return .{
        .warp = .{ .x = 0.0, .z = 0.0 },
        .warped_x = 128.0,
        .warped_z = 256.0,
        .continentalness = continentalness,
        .erosion = 0.5,
        .peaks_valleys = 0.75,
        .temperature = 0.5,
        .humidity = 0.5,
        .river_mask = 0.0,
        .terrain_base = terrain,
        .terrain_alt = terrain,
        .height_select = 0.0,
        .terrain_persist = 1.0,
        .variant = 0.0,
    };
}

const test_controls = RegionControls{
    .height_mult = 1.0,
    .vegetation_mult = 1.0,
    .drama_mask = 0.0,
    .river_mask = 0.0,
    .subbiome_mask = 0.0,
};

const test_path = PathInfo{
    .path_type = .none,
    .influence = 0.0,
    .direction = .{ 0.0, 0.0 },
};

test "HeightSampler applies biome terrain modifiers to land height" {
    const sampler = HeightSampler.init();
    const noise_sampler = NoiseSampler.init(1234);
    const noise = testNoiseValues(0.55, 20.0);
    const sea = sampler.getSeaLevelFloat();

    const base = sampler.computeHeight(&noise_sampler, noise, test_controls, test_path, 0);
    const flattened = sampler.computeHeightWithTerrainModifier(&noise_sampler, noise, test_controls, test_path, 0, .{ .smoothing = 1.0 });
    const amplified = sampler.computeHeightWithTerrainModifier(&noise_sampler, noise, test_controls, test_path, 0, .{ .height_amplitude = 1.25 });
    const clamped = sampler.computeHeightWithTerrainModifier(&noise_sampler, noise, test_controls, test_path, 0, .{ .clamp_to_sea_level = true, .height_offset = -2.0 });

    try std.testing.expect(base > sea);
    try std.testing.expectApproxEqAbs(sea, flattened, 0.0001);
    try std.testing.expect(amplified > base);
    try std.testing.expectApproxEqAbs(sea - 2.0, clamped, 0.0001);
}

test "HeightSampler applies peak compression after terrain amplification" {
    const sampler = HeightSampler.init();
    const noise_sampler = NoiseSampler.init(5678);
    const noise = testNoiseValues(0.9, 300.0);
    const peak_limit = sampler.getSeaLevelFloat() + sampler.params.peak_compression_offset + sampler.params.peak_compression_range;

    const amplified = sampler.computeHeightWithTerrainModifier(&noise_sampler, noise, test_controls, test_path, 0, .{ .height_amplitude = 2.0 });

    try std.testing.expect(amplified < peak_limit);
}
