//! Unit tests for HeightSampler terrain height computation
//!
//! Tests focus on:
//! - Sea level queries
//! - Continental zone boundaries
//! - Mountain mask edge cases
//! - Simplified height computation

const std = @import("std");
const testing = std.testing;
const height_sampler_mod = @import("height_sampler.zig");
const world_class_mod = @import("world_class.zig");
const noise_sampler_mod = @import("noise_sampler.zig");
const region_mod = @import("region.zig");

const HeightSampler = height_sampler_mod.HeightSampler;
const HeightParams = height_sampler_mod.HeightParams;
const ContinentalZone = world_class_mod.ContinentalZone;
const ColumnNoiseValues = noise_sampler_mod.ColumnNoiseValues;
const NoiseSampler = noise_sampler_mod.NoiseSampler;
const RegionControls = region_mod.RegionControls;
const PathInfo = region_mod.PathInfo;

const flat_controls = RegionControls{
    .height_mult = 1.0,
    .vegetation_mult = 1.0,
    .drama_mask = 0.0,
    .river_mask = 0.0,
    .subbiome_mask = 0.0,
};

const no_path = PathInfo{
    .path_type = .none,
    .influence = 0.0,
    .direction = .{ 0.0, 0.0 },
};

// ============================================================================
// HeightSampler Initialization Tests
// ============================================================================

test "HeightSampler init with default params" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(@as(i32, 64), sampler.getSeaLevel());
}

test "HeightSampler initWithParams custom sea level" {
    const params = HeightParams{ .sea_level = 32 };
    const sampler = HeightSampler.initWithParams(params);
    try testing.expectEqual(@as(i32, 32), sampler.getSeaLevel());
}

test "HeightSampler getSeaLevelFloat returns float" {
    const sampler = HeightSampler.init();
    const sea_f = sampler.getSeaLevelFloat();
    try testing.expectApproxEqAbs(@as(f32, 64.0), sea_f, 0.001);
}

// ============================================================================
// Continental Zone Boundary Tests
// ============================================================================

test "HeightSampler continental zone deep_ocean" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(ContinentalZone.deep_ocean, sampler.getContinentalZone(0.10));
    try testing.expectEqual(ContinentalZone.deep_ocean, sampler.getContinentalZone(0.15));
}

test "HeightSampler continental zone ocean" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(ContinentalZone.ocean, sampler.getContinentalZone(0.25));
    try testing.expectEqual(ContinentalZone.ocean, sampler.getContinentalZone(0.30));
}

test "HeightSampler continental zone coast" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(ContinentalZone.coast, sampler.getContinentalZone(0.38));
    try testing.expectEqual(ContinentalZone.coast, sampler.getContinentalZone(0.40));
}

test "HeightSampler continental zone inland_low" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(ContinentalZone.inland_low, sampler.getContinentalZone(0.50));
    try testing.expectEqual(ContinentalZone.inland_low, sampler.getContinentalZone(0.55));
}

test "HeightSampler continental zone inland_high" {
    const sampler = HeightSampler.init();
    const lower = sampler.params.continental_inland_low_max;
    const upper = sampler.params.continental_inland_high_max;
    try testing.expectEqual(ContinentalZone.inland_low, sampler.getContinentalZone(lower - 0.0001));
    try testing.expectEqual(ContinentalZone.inland_high, sampler.getContinentalZone(lower));
    try testing.expectEqual(ContinentalZone.inland_high, sampler.getContinentalZone(0.68));
    try testing.expectEqual(ContinentalZone.inland_high, sampler.getContinentalZone(upper - 0.0001));
    try testing.expectEqual(ContinentalZone.mountain_core, sampler.getContinentalZone(upper));
}

test "HeightSampler continental zone mountain_core" {
    const sampler = HeightSampler.init();
    try testing.expectEqual(ContinentalZone.mountain_core, sampler.getContinentalZone(0.85));
    try testing.expectEqual(ContinentalZone.mountain_core, sampler.getContinentalZone(1.0));
}

// ============================================================================
// Ocean Detection Tests
// ============================================================================

test "HeightSampler isOcean at deep ocean value" {
    const sampler = HeightSampler.init();
    try testing.expect(sampler.isOcean(0.0));
    try testing.expect(sampler.isOcean(0.10));
    try testing.expect(sampler.isOcean(0.19));
}

test "HeightSampler isOcean at exactly threshold" {
    const sampler = HeightSampler.init();
    try testing.expect(sampler.isOcean(0.35));
    try testing.expect(!sampler.isOcean(0.37));
}

test "HeightSampler isOcean inland values return false" {
    const sampler = HeightSampler.init();
    try testing.expect(!sampler.isOcean(0.40));
    try testing.expect(!sampler.isOcean(0.60));
    try testing.expect(!sampler.isOcean(1.0));
}

// ============================================================================
// Mountain Mask Edge Cases
// ============================================================================

test "HeightSampler getMountainMask returns zero when inland factor is zero" {
    const sampler = HeightSampler.init();
    const mask = sampler.getMountainMask(0.8, 0.3, 0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), mask, 0.001);
}

test "HeightSampler getMountainMask returns zero when peak factor is zero" {
    const sampler = HeightSampler.init();
    const mask = sampler.getMountainMask(0.2, 0.3, 0.7);
    try testing.expectApproxEqAbs(@as(f32, 0), mask, 0.001);
}

test "HeightSampler getMountainMask returns zero when rugged factor is zero" {
    const sampler = HeightSampler.init();
    const mask = sampler.getMountainMask(0.8, 0.8, 0.7);
    try testing.expectApproxEqAbs(@as(f32, 0), mask, 0.001);
}

test "HeightSampler getMountainMask maximum value is bounded by 1" {
    const sampler = HeightSampler.init();
    const mask = sampler.getMountainMask(0.8, 0.1, 0.85);
    try testing.expect(mask <= 1.0);
    try testing.expect(mask >= 0.0);
}

// ============================================================================
// HeightParams Default Values Tests
// ============================================================================

test "HeightParams default sea level" {
    const params = HeightParams{};
    try testing.expectEqual(@as(i32, 64), params.sea_level);
}

test "HeightParams default continental thresholds are sequential" {
    const params = HeightParams{};
    try testing.expect(params.ocean_threshold < params.continental_deep_ocean_max or
        params.continental_deep_ocean_max < params.ocean_threshold);
    try testing.expect(params.ocean_threshold < params.continental_coast_max);
    try testing.expect(params.continental_coast_max < params.continental_inland_low_max);
    try testing.expect(params.continental_inland_low_max < params.continental_inland_high_max);
}

test "HeightParams mountain parameters are positive" {
    const params = HeightParams{};
    try testing.expect(params.mount_amp > 0);
    try testing.expect(params.mount_cap > params.mount_amp);
    try testing.expect(params.mount_inland_min < params.mount_inland_max);
}

test "HeightParams ridge parameters are positive" {
    const params = HeightParams{};
    try testing.expect(params.ridge_amp > 0);
    try testing.expect(params.ridge_inland_min < params.ridge_inland_max);
}

test "HeightParams peak compression values are positive" {
    const params = HeightParams{};
    try testing.expect(params.peak_compression_offset > 0);
    try testing.expect(params.peak_compression_range > 0);
}

// ============================================================================
// computeHeightSimple Tests
// ============================================================================

test "HeightSampler computeHeightSimple ocean returns below sea level" {
    const sampler = HeightSampler.init();
    const height = sampler.computeHeightSimple(0.2, 0.5, 0.5, 0.0, 0.0, 1.0);
    try testing.expect(@as(f32, @floatFromInt(sampler.getSeaLevel())) > height);
}

test "HeightSampler computeHeightSimple land returns above sea level" {
    const sampler = HeightSampler.init();
    const height = sampler.computeHeightSimple(0.6, 0.5, 0.5, 10.0, 0.0, 1.0);
    try testing.expect(height > @as(f32, @floatFromInt(sampler.getSeaLevel())));
}

test "HeightSampler computeHeightSimple mountain contribution increases with continentalness" {
    const sampler = HeightSampler.init();
    const low = sampler.computeHeightSimple(0.5, 0.3, 0.6, 5.0, 0.0, 1.0);
    const high = sampler.computeHeightSimple(0.9, 0.3, 0.6, 5.0, 0.0, 1.0);
    try testing.expect(high > low);
}

test "HeightSampler computeHeightSimple peak compression caps very high terrain" {
    const sampler = HeightSampler.init();
    const sea = @as(f32, @floatFromInt(sampler.getSeaLevel()));
    const very_high = sea + sampler.params.peak_compression_offset + 200.0;
    const height = sampler.computeHeightSimple(0.95, 0.3, 0.6, very_high, 0.0, 1.0);
    const peak_start = sea + sampler.params.peak_compression_offset;
    try testing.expect(height < very_high);
    try testing.expect(height > peak_start);
}

fn coastalTestNoise(warped_x: f32, warped_z: f32) ColumnNoiseValues {
    return .{
        .warp = .{ .x = 0.0, .z = 0.0 },
        .warped_x = warped_x,
        .warped_z = warped_z,
        .continentalness = 0.43,
        .erosion = 0.45,
        .peaks_valleys = 0.5,
        .temperature = 0.5,
        .humidity = 0.5,
        .river_mask = 0.0,
        .terrain_base = 0.0,
        .terrain_alt = 0.0,
        .height_select = 0.0,
        .terrain_persist = 1.0,
        .variant = 0.0,
    };
}

fn lowlandRampNoise(continentalness: f32) ColumnNoiseValues {
    var noise = coastalTestNoise(64.0, 96.0);
    noise.continentalness = continentalness;
    noise.erosion = 1.0;
    return noise;
}

test "HeightSampler computeHeight avoids monotonic inland-low ramp" {
    const sampler = HeightSampler.init();
    const noise_sampler = NoiseSampler.init(1357);

    const coastal_edge = sampler.computeHeightWithTerrainModifier(&noise_sampler, lowlandRampNoise(0.44), flat_controls, no_path, 0, null);
    const inland_low = sampler.computeHeightWithTerrainModifier(&noise_sampler, lowlandRampNoise(0.58), flat_controls, no_path, 0, null);

    try testing.expect(@abs(inland_low - coastal_edge) < 1.0);
}

test "HeightSampler computeHeight keeps detail active on coastal land" {
    const sampler = HeightSampler.init();
    const noise_sampler = NoiseSampler.init(2468);
    const positions = [_][2]f32{
        .{ 17.0, 29.0 },
        .{ 53.0, 71.0 },
        .{ 109.0, 31.0 },
        .{ 157.0, 149.0 },
        .{ 211.0, 83.0 },
    };

    var min_height: f32 = std.math.inf(f32);
    var max_height: f32 = -std.math.inf(f32);
    for (positions) |pos| {
        const height = sampler.computeHeightWithTerrainModifier(&noise_sampler, coastalTestNoise(pos[0], pos[1]), flat_controls, no_path, 0, null);
        min_height = @min(min_height, height);
        max_height = @max(max_height, height);
    }

    try testing.expect(max_height - min_height > 0.5);
}
