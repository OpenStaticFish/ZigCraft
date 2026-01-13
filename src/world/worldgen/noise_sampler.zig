//! NoiseSampler - Pure noise generation component for terrain pipeline
//!
//! This module owns all ConfiguredNoise instances and provides raw sampled values
//! for terrain generation. It is a pure math component with no side effects,
//! making it easy to test and swap for different dimensions (e.g., Overworld vs Nether).
//!
//! Part of Issue #147: Modularize Terrain Generation Pipeline

const std = @import("std");
const noise_mod = @import("noise.zig");
const Noise = noise_mod.Noise;
const smoothstep = noise_mod.smoothstep;
const clamp01 = noise_mod.clamp01;
const ConfiguredNoise = noise_mod.ConfiguredNoise;
const NoiseParams = noise_mod.NoiseParams;
const Vec3f = noise_mod.Vec3f;

// ============================================================================
// Noise Configuration Parameters
// ============================================================================

/// Create NoiseParams with a seed offset from base seed
fn makeNoiseParams(base_seed: u64, offset: u64, spread: f32, scale: f32, off: f32, octaves: u16, persist: f32) NoiseParams {
    return .{
        .seed = base_seed +% offset,
        .spread = Vec3f.uniform(spread),
        .scale = scale,
        .offset = off,
        .octaves = octaves,
        .persist = persist,
        .lacunarity = 2.0,
        .flags = .{},
    };
}

/// Configuration parameters for climate sampling
pub const ClimateConfig = struct {
    temperature_macro_scale: f32 = 1.0 / 2000.0,
    temperature_local_scale: f32 = 1.0 / 200.0,
    humidity_macro_scale: f32 = 1.0 / 2000.0,
    humidity_local_scale: f32 = 1.0 / 200.0,
    climate_macro_weight: f32 = 0.75,
};

/// Configuration parameters for terrain noise
pub const TerrainConfig = struct {
    warp_amplitude: f32 = 30.0,
    continental_scale: f32 = 1.0 / 1500.0,
    erosion_scale: f32 = 1.0 / 400.0,
    peaks_scale: f32 = 1.0 / 300.0,
    detail_scale: f32 = 1.0 / 32.0,
    detail_amp: f32 = 6.0,
    coast_jitter_scale: f32 = 1.0 / 150.0,
    seabed_scale: f32 = 1.0 / 100.0,
    seabed_amp: f32 = 2.0,
    river_scale: f32 = 1.0 / 800.0,
    river_min: f32 = 0.90,
    river_max: f32 = 0.95,
    ridge_scale: f32 = 1.0 / 400.0,
};

// ============================================================================
// Output Structures
// ============================================================================

/// Warp offset for domain warping
pub const Warp = struct {
    x: f32,
    z: f32,
};

/// All noise values needed for a single column
/// Batching these together reduces redundant noise sampling
pub const ColumnNoiseValues = struct {
    // Domain warp
    warp: Warp,
    warped_x: f32,
    warped_z: f32,

    // Continental structure
    continentalness: f32,
    erosion: f32,
    peaks_valleys: f32,

    // Climate
    temperature: f32,
    humidity: f32,

    // Rivers
    river_mask: f32,

    // V7-style terrain layers
    terrain_base: f32,
    terrain_alt: f32,
    height_select: f32,
    terrain_persist: f32,

    // Variant for sub-biomes
    variant: f32,
};

// ============================================================================
// NoiseSampler
// ============================================================================

/// Pure noise sampling component for terrain generation.
/// All noise generators are configured at init and provide deterministic outputs.
pub const NoiseSampler = struct {
    // Domain warp
    warp_noise_x: ConfiguredNoise,
    warp_noise_z: ConfiguredNoise,

    // Continental structure
    continentalness_noise: ConfiguredNoise,
    erosion_noise: ConfiguredNoise,
    peaks_noise: ConfiguredNoise,

    // Climate
    temperature_noise: ConfiguredNoise,
    humidity_noise: ConfiguredNoise,
    temperature_local_noise: ConfiguredNoise,
    humidity_local_noise: ConfiguredNoise,

    // Terrain detail
    detail_noise: ConfiguredNoise,
    coast_jitter_noise: ConfiguredNoise,
    seabed_noise: ConfiguredNoise,
    beach_exposure_noise: ConfiguredNoise,
    filler_depth_noise: ConfiguredNoise,

    // Mountains & ridges
    mountain_lift_noise: ConfiguredNoise,
    ridge_noise: ConfiguredNoise,

    // Rivers
    river_noise: ConfiguredNoise,

    // V7-style multi-layer terrain (Issue #105)
    terrain_base: ConfiguredNoise,
    terrain_alt: ConfiguredNoise,
    height_select: ConfiguredNoise,
    terrain_persist: ConfiguredNoise,

    // Variant noise for sub-biomes (Issue #110)
    variant_noise: ConfiguredNoise,

    // Configuration
    climate_config: ClimateConfig,
    terrain_config: TerrainConfig,
    seed: u64,

    /// Initialize NoiseSampler with a world seed
    pub fn init(seed: u64) NoiseSampler {
        return initWithConfig(seed, .{}, .{});
    }

    /// Initialize NoiseSampler with custom configuration
    /// Allows different dimensions to use different noise parameters
    pub fn initWithConfig(seed: u64, climate_config: ClimateConfig, terrain_config: TerrainConfig) NoiseSampler {
        const tc = terrain_config;
        return .{
            // Domain warp
            .warp_noise_x = ConfiguredNoise.init(makeNoiseParams(seed, 10, 200, tc.warp_amplitude, 0, 3, 0.5)),
            .warp_noise_z = ConfiguredNoise.init(makeNoiseParams(seed, 11, 200, tc.warp_amplitude, 0, 3, 0.5)),

            // Continental structure
            .continentalness_noise = ConfiguredNoise.init(makeNoiseParams(seed, 20, 1500, 1.0, 0, 4, 0.5)),
            .erosion_noise = ConfiguredNoise.init(makeNoiseParams(seed, 30, 400, 1.0, 0, 4, 0.5)),
            .peaks_noise = ConfiguredNoise.init(makeNoiseParams(seed, 40, 300, 1.0, 0, 5, 0.5)),

            // Climate
            .temperature_noise = ConfiguredNoise.init(makeNoiseParams(seed, 50, 2000, 1.0, 0, 3, 0.5)),
            .humidity_noise = ConfiguredNoise.init(makeNoiseParams(seed, 60, 2000, 1.0, 0, 3, 0.5)),
            .temperature_local_noise = ConfiguredNoise.init(makeNoiseParams(seed, 70, 200, 1.0, 0, 3, 0.5)),
            .humidity_local_noise = ConfiguredNoise.init(makeNoiseParams(seed, 80, 200, 1.0, 0, 3, 0.5)),

            // Terrain detail
            .detail_noise = ConfiguredNoise.init(makeNoiseParams(seed, 90, 32, tc.detail_amp, 0, 3, 0.5)),
            .coast_jitter_noise = ConfiguredNoise.init(makeNoiseParams(seed, 100, 150, 0.03, 0, 2, 0.5)),
            .seabed_noise = ConfiguredNoise.init(makeNoiseParams(seed, 110, 100, tc.seabed_amp, 0, 2, 0.5)),
            .beach_exposure_noise = ConfiguredNoise.init(makeNoiseParams(seed, 130, 100, 1.0, 0, 3, 0.5)),
            .filler_depth_noise = ConfiguredNoise.init(makeNoiseParams(seed, 140, 64, 1.0, 0, 3, 0.5)),

            // Mountains & ridges
            .mountain_lift_noise = ConfiguredNoise.init(makeNoiseParams(seed, 150, 400, 1.0, 0, 3, 0.5)),
            .ridge_noise = ConfiguredNoise.init(makeNoiseParams(seed, 160, 400, 1.0, 0, 5, 0.5)),

            // Rivers
            .river_noise = ConfiguredNoise.init(makeNoiseParams(seed, 120, 800, 1.0, 0, 4, 0.5)),

            // V7-style terrain layers - spread values based on Luanti defaults
            .terrain_base = ConfiguredNoise.init(makeNoiseParams(seed, 1001, 300, 35, 4, 5, 0.6)),
            .terrain_alt = ConfiguredNoise.init(makeNoiseParams(seed, 1002, 300, 20, 4, 5, 0.6)),
            .height_select = ConfiguredNoise.init(makeNoiseParams(seed, 1003, 250, 16, -8, 6, 0.6)),
            .terrain_persist = ConfiguredNoise.init(makeNoiseParams(seed, 1004, 1000, 0.15, 0.6, 3, 0.6)),

            // Variant noise for sub-biomes (Issue #110)
            .variant_noise = ConfiguredNoise.init(makeNoiseParams(seed, 1008, 250, 1.0, 0.0, 3, 0.5)),

            .climate_config = climate_config,
            .terrain_config = terrain_config,
            .seed = seed,
        };
    }

    // ========================================================================
    // Individual Noise Sampling Methods
    // ========================================================================

    /// Compute domain warp offset for a position
    pub fn computeWarp(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) Warp {
        const octaves: u16 = if (3 > reduction) 3 - @as(u16, reduction) else 1;
        const offset_x = self.warp_noise_x.get2DOctaves(x, z, octaves);
        const offset_z = self.warp_noise_z.get2DOctaves(x, z, octaves);
        return .{ .x = offset_x, .z = offset_z };
    }

    /// Get continentalness value (0-1)
    /// Low values = ocean, high values = inland
    pub fn getContinentalness(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        // Slow octave reduction for structure preservation
        const octaves: u16 = if (4 > (reduction / 2)) 4 - @as(u16, (reduction / 2)) else 2;
        const val = self.continentalness_noise.get2DOctaves(x, z, octaves);
        return (val + 1.0) * 0.5;
    }

    /// Get erosion value (0-1)
    /// High erosion = smoother terrain
    pub fn getErosion(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const octaves: u16 = if (4 > (reduction / 2)) 4 - @as(u16, (reduction / 2)) else 2;
        const val = self.erosion_noise.get2DOctaves(x, z, octaves);
        return (val + 1.0) * 0.5;
    }

    /// Get peaks/valleys value using ridged noise
    pub fn getPeaksValleys(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const octaves: u16 = if (5 > reduction) 5 - @as(u16, reduction) else 1;
        return self.peaks_noise.noise.ridged2D(x, z, octaves, 2.0, 0.5, self.terrain_config.peaks_scale);
    }

    /// Get temperature value (0-1)
    /// 0 = cold, 1 = hot
    pub fn getTemperature(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const cc = self.climate_config;
        const macro_octaves: u16 = if (3 > (reduction / 2)) 3 - @as(u16, (reduction / 2)) else 2;
        const local_octaves: u16 = if (2 > reduction) 2 - @as(u16, reduction) else 1;
        const macro = self.temperature_noise.get2DNormalizedOctaves(x, z, macro_octaves);
        const local = self.temperature_local_noise.get2DNormalizedOctaves(x, z, local_octaves);
        var t = cc.climate_macro_weight * macro + (1.0 - cc.climate_macro_weight) * local;
        t = (t - 0.5) * 2.2 + 0.5;
        return clamp01(t);
    }

    /// Get humidity value (0-1)
    /// 0 = dry, 1 = wet
    pub fn getHumidity(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const cc = self.climate_config;
        const macro_octaves: u16 = if (3 > (reduction / 2)) 3 - @as(u16, (reduction / 2)) else 2;
        const local_octaves: u16 = if (2 > reduction) 2 - @as(u16, reduction) else 1;
        const macro = self.humidity_noise.get2DNormalizedOctaves(x, z, macro_octaves);
        const local = self.humidity_local_noise.get2DNormalizedOctaves(x, z, local_octaves);
        var h = cc.climate_macro_weight * macro + (1.0 - cc.climate_macro_weight) * local;
        h = (h - 0.5) * 2.2 + 0.5;
        return clamp01(h);
    }

    /// Get river mask value (0-1)
    /// Higher values = more river-like
    pub fn getRiverMask(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const tc = self.terrain_config;
        const octaves: u32 = if (4 > reduction) 4 - reduction else 1;
        const r = self.river_noise.noise.ridged2D(x, z, octaves, 2.0, 0.5, tc.river_scale);
        const river_val = 1.0 - r;
        return smoothstep(tc.river_min, tc.river_max, river_val);
    }

    /// Get ridge factor for mountain ridges
    pub fn getRidgeFactor(self: *const NoiseSampler, x: f32, z: f32, c: f32, reduction: u8, ridge_params: RidgeParams) f32 {
        const inland_factor = smoothstep(ridge_params.inland_min, ridge_params.inland_max, c);
        const octaves: u32 = if (5 > reduction) 5 - reduction else 1;
        const ridge_val = self.ridge_noise.noise.ridged2D(x, z, octaves, 2.0, 0.5, self.terrain_config.ridge_scale);
        const sparsity_mask = smoothstep(ridge_params.sparsity - 0.15, ridge_params.sparsity + 0.15, ridge_val);
        return inland_factor * sparsity_mask * ridge_val;
    }

    /// Parameters for ridge factor calculation
    pub const RidgeParams = struct {
        inland_min: f32 = 0.50,
        inland_max: f32 = 0.70,
        sparsity: f32 = 0.50,
    };

    /// Get coast jitter for shoreline variation
    pub fn getCoastJitter(self: *const NoiseSampler, x: f32, z: f32) f32 {
        return self.coast_jitter_noise.get2DOctaves(x, z, 2);
    }

    /// Get seabed variation
    pub fn getSeabedDetail(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const octaves: u32 = if (2 > reduction) 2 - reduction else 1;
        return self.seabed_noise.get2DOctaves(x, z, @intCast(octaves));
    }

    /// Get detail noise for fine terrain variation.
    ///
    /// NOTE: The LOD multiplier intentionally reduces detail contribution at higher
    /// reduction levels. At reduction=4, lod_mult becomes 0.0, completely eliminating
    /// detail noise. This is by design: distant terrain (high LOD) should appear
    /// smooth without fine-grained variation that causes visual noise/aliasing.
    pub fn getDetail(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        std.debug.assert(reduction <= 4); // Valid reduction range is 0-4
        const octaves: u32 = if (3 > reduction) 3 - reduction else 1;
        const lod_mult = (1.0 - 0.25 * @as(f32, @floatFromInt(reduction)));
        return self.detail_noise.get2DOctaves(x, z, @intCast(octaves)) * lod_mult;
    }

    /// Get mountain lift noise
    pub fn getMountainLift(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const octaves: u32 = if (3 > reduction) 3 - reduction else 1;
        return (self.mountain_lift_noise.get2DOctaves(x, z, @intCast(octaves)) + 1.0) * 0.5;
    }

    /// Get V7-style terrain base
    pub fn getTerrainBase(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        return self.terrain_base.get2DOctaves(x, z, self.terrain_base.params.octaves -| reduction);
    }

    /// Get V7-style terrain alt
    pub fn getTerrainAlt(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        return self.terrain_alt.get2DOctaves(x, z, self.terrain_alt.params.octaves -| reduction);
    }

    /// Get V7-style height select (blend between base and alt)
    pub fn getHeightSelect(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        return self.height_select.get2DOctaves(x, z, self.height_select.params.octaves -| reduction);
    }

    /// Get V7-style terrain persistence modifier
    pub fn getTerrainPersist(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        return self.terrain_persist.get2DOctaves(x, z, self.terrain_persist.params.octaves -| reduction);
    }

    /// Get variant noise for sub-biomes
    pub fn getVariant(self: *const NoiseSampler, x: f32, z: f32, reduction: u8) f32 {
        const octaves: u16 = if (3 > reduction) 3 - @as(u16, reduction) else 1;
        return self.variant_noise.get2DOctaves(x, z, octaves);
    }

    /// Get beach exposure noise
    pub fn getBeachExposure(self: *const NoiseSampler, x: f32, z: f32) f32 {
        return self.beach_exposure_noise.get2DNormalizedOctaves(x, z, 2);
    }

    /// Get filler depth noise
    pub fn getFillerDepth(self: *const NoiseSampler, x: f32, z: f32) f32 {
        return self.filler_depth_noise.get2DNormalizedOctaves(x, z, 3);
    }

    // ========================================================================
    // Batch Sampling
    // ========================================================================

    /// Sample all noise values for a column at once
    /// This is more efficient when multiple values are needed
    pub fn sampleColumn(self: *const NoiseSampler, wx: f32, wz: f32, reduction: u8) ColumnNoiseValues {
        // Apply domain warp first
        const warp = self.computeWarp(wx, wz, reduction);
        const xw = wx + warp.x;
        const zw = wz + warp.z;

        return .{
            .warp = warp,
            .warped_x = xw,
            .warped_z = zw,
            .continentalness = self.getContinentalness(xw, zw, reduction),
            .erosion = self.getErosion(xw, zw, reduction),
            .peaks_valleys = self.getPeaksValleys(xw, zw, reduction),
            .temperature = self.getTemperature(xw, zw, reduction),
            .humidity = self.getHumidity(xw, zw, reduction),
            .river_mask = self.getRiverMask(xw, zw, reduction),
            .terrain_base = self.getTerrainBase(xw, zw, reduction),
            .terrain_alt = self.getTerrainAlt(xw, zw, reduction),
            .height_select = self.getHeightSelect(xw, zw, reduction),
            .terrain_persist = self.getTerrainPersist(xw, zw, reduction),
            .variant = self.getVariant(xw, zw, reduction),
        };
    }

    /// Get the seed used to initialize this sampler
    pub fn getSeed(self: *const NoiseSampler) u64 {
        return self.seed;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NoiseSampler deterministic output" {
    const sampler = NoiseSampler.init(12345);

    // Same inputs should give same outputs
    const c1 = sampler.getContinentalness(100.0, 200.0, 0);
    const c2 = sampler.getContinentalness(100.0, 200.0, 0);
    try std.testing.expectEqual(c1, c2);

    // Different positions should give different values
    const c3 = sampler.getContinentalness(500.0, 600.0, 0);
    try std.testing.expect(c1 != c3);
}

test "NoiseSampler values in expected range" {
    const sampler = NoiseSampler.init(42);

    // Continentalness should be 0-1
    const c = sampler.getContinentalness(0.0, 0.0, 0);
    try std.testing.expect(c >= 0.0 and c <= 1.0);

    // Temperature should be 0-1
    const t = sampler.getTemperature(0.0, 0.0, 0);
    try std.testing.expect(t >= 0.0 and t <= 1.0);

    // Humidity should be 0-1
    const h = sampler.getHumidity(0.0, 0.0, 0);
    try std.testing.expect(h >= 0.0 and h <= 1.0);
}

test "NoiseSampler batch sampling matches individual" {
    const sampler = NoiseSampler.init(99999);
    const x: f32 = 123.0;
    const z: f32 = 456.0;
    const reduction: u8 = 0;

    // Get values individually
    const warp = sampler.computeWarp(x, z, reduction);
    const xw = x + warp.x;
    const zw = z + warp.z;
    const c_individual = sampler.getContinentalness(xw, zw, reduction);
    const t_individual = sampler.getTemperature(xw, zw, reduction);

    // Get values via batch
    const column = sampler.sampleColumn(x, z, reduction);

    // Should match
    try std.testing.expectEqual(c_individual, column.continentalness);
    try std.testing.expectEqual(t_individual, column.temperature);
}

test "NoiseSampler different seeds produce different results" {
    const sampler1 = NoiseSampler.init(111);
    const sampler2 = NoiseSampler.init(222);

    const c1 = sampler1.getContinentalness(100.0, 100.0, 0);
    const c2 = sampler2.getContinentalness(100.0, 100.0, 0);

    try std.testing.expect(c1 != c2);
}
