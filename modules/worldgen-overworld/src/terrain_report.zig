//! Deterministic worldgen baseline reporting for biome and height distribution.

const std = @import("std");
const world_core = @import("world-core");
const biome_mod = @import("biome.zig");
const region_mod = @import("region.zig");
const TerrainShapeGenerator = @import("terrain_shape_generator.zig").TerrainShapeGenerator;

const Allocator = std.mem.Allocator;
const BiomeId = biome_mod.BiomeId;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;

pub const representative_seeds = [_]u64{ 42, 1337, 424242, 8675309, 987654321 };
pub const default_origin_x: i32 = -256;
pub const default_origin_z: i32 = -256;
pub const default_width: u32 = 512;
pub const default_depth: u32 = 512;

const BIOME_COUNT = @typeInfo(BiomeId).@"enum".fields.len;
const ROLE_PROFILE_COUNT = 5;

pub const RoleEffectProfileId = enum {
    transit,
    lake_destination,
    forest_destination,
    mountain_destination,
    boundary,
};

pub const RoleEffectProfile = struct {
    id: RoleEffectProfileId,
    sample_count: u32,
    min_height: i32,
    max_height: i32,
    average_height: f64,
    average_slope: f64,
    mountain_coverage: f64,
    vegetation_multiplier: f32,
    drama_mask: f32,
    river_mask: f32,
    subbiome_mask: f32,
    biome_counts: [BIOME_COUNT]u32,

    pub fn biomeCount(self: RoleEffectProfile, biome_id: BiomeId) u32 {
        return self.biome_counts[@intFromEnum(biome_id)];
    }

    pub fn heightRange(self: RoleEffectProfile) i32 {
        return self.max_height - self.min_height;
    }
};

pub const TerrainReport = struct {
    seed: u64,
    origin_x: i32,
    origin_z: i32,
    width: u32,
    depth: u32,
    sample_count: u32,
    biome_counts: [BIOME_COUNT]u32,
    min_height: i32,
    max_height: i32,
    average_height: f64,
    sea_level_coverage: f64,
    /// Columns with room for water above the integer terrain surface. Land at
    /// sea level is dry, but is included in sea_level_coverage.
    water_coverage: f64,
    ocean_ratio: f64,
    land_ratio: f64,
    mountain_coverage: f64,
    role_effect_profiles: [ROLE_PROFILE_COUNT]RoleEffectProfile,

    pub fn biomeCount(self: TerrainReport, biome_id: BiomeId) u32 {
        return self.biome_counts[@intFromEnum(biome_id)];
    }
};

const ColumnSample = struct {
    height: i32,
    continentalness: f32,
    erosion: f32,
    ridge_mask: f32,
    river_mask: f32,
    temperature: f32,
    humidity: f32,
    is_ocean: bool,
};

pub fn sampleDefaultRegion(allocator: Allocator, seed: u64) !TerrainReport {
    return sampleRegion(allocator, seed, default_origin_x, default_origin_z, default_width, default_depth);
}

pub fn sampleRegion(
    allocator: Allocator,
    seed: u64,
    origin_x: i32,
    origin_z: i32,
    width: u32,
    depth: u32,
) !TerrainReport {
    if (width == 0 or depth == 0) return error.EmptySampleRegion;

    const sample_count = try std.math.mul(u32, width, depth);
    const samples = try allocator.alloc(ColumnSample, sample_count);
    defer allocator.free(samples);

    var generator = TerrainShapeGenerator.init(seed);

    var report = TerrainReport{
        .seed = seed,
        .origin_x = origin_x,
        .origin_z = origin_z,
        .width = width,
        .depth = depth,
        .sample_count = sample_count,
        .biome_counts = [_]u32{0} ** BIOME_COUNT,
        .min_height = std.math.maxInt(i32),
        .max_height = std.math.minInt(i32),
        .average_height = 0.0,
        .sea_level_coverage = 0.0,
        .water_coverage = 0.0,
        .ocean_ratio = 0.0,
        .land_ratio = 0.0,
        .mountain_coverage = 0.0,
        .role_effect_profiles = undefined,
    };

    var height_sum: i64 = 0;
    var sea_level_or_below_count: u32 = 0;
    var water_count: u32 = 0;
    var ocean_count: u32 = 0;
    var mountain_count: u32 = 0;
    const sea_level = generator.getSeaLevel();

    var z: u32 = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const wx_i = origin_x + @as(i32, @intCast(x));
            const wz_i = origin_z + @as(i32, @intCast(z));
            const column = generator.sampleColumnData(@floatFromInt(wx_i), @floatFromInt(wz_i), 0);
            const height = column.terrain_height_i;

            samples[idx] = .{
                .height = height,
                .continentalness = column.continentalness,
                .erosion = column.erosion,
                .ridge_mask = column.ridge_mask,
                .river_mask = column.river_mask,
                .temperature = column.temperature,
                .humidity = column.humidity,
                .is_ocean = column.is_ocean,
            };

            report.min_height = @min(report.min_height, height);
            report.max_height = @max(report.max_height, height);
            height_sum += height;
            if (height <= sea_level) sea_level_or_below_count += 1;
            if (height < sea_level) water_count += 1;
            if (column.is_ocean) ocean_count += 1;
            if (height >= sea_level + 48 or column.ridge_mask >= 0.65) mountain_count += 1;
        }
    }

    z = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const sample = samples[idx];
            const slope = maxNeighborSlope(samples, x, z, width, depth);
            const climate = generator.getBiomeSource().computeClimate(
                sample.temperature,
                sample.humidity,
                sample.height,
                sample.continentalness,
                sample.erosion,
                CHUNK_SIZE_Y,
            );
            const structural = biome_mod.StructuralParams{
                .height = sample.height,
                .slope = slope,
                .continentalness = sample.continentalness,
                .ridge_mask = sample.ridge_mask,
            };
            const biome_id = generator.getBiomeSource().selectBiome(climate, structural, sample.river_mask);
            report.biome_counts[@intFromEnum(biome_id)] += 1;
        }
    }

    const denominator: f64 = @floatFromInt(sample_count);
    report.average_height = @as(f64, @floatFromInt(height_sum)) / denominator;
    report.sea_level_coverage = @as(f64, @floatFromInt(sea_level_or_below_count)) / denominator;
    report.water_coverage = @as(f64, @floatFromInt(water_count)) / denominator;
    report.ocean_ratio = @as(f64, @floatFromInt(ocean_count)) / denominator;
    report.land_ratio = 1.0 - report.ocean_ratio;
    report.mountain_coverage = @as(f64, @floatFromInt(mountain_count)) / denominator;
    report.role_effect_profiles = try sampleRoleEffectProfiles(allocator, &generator);

    return report;
}

pub fn writeReport(writer: anytype, report: TerrainReport) !void {
    try writer.print(
        \\worldgen terrain report
        \\seed: {d}
        \\region: origin=({d},{d}) size={d}x{d} samples={d}
        \\height: min={d} max={d} avg={d:.2}
        \\coverage: sea_level_or_below={d:.4} water={d:.4} ocean={d:.4} land={d:.4} mountain={d:.4}
        \\biomes:
        \\
    , .{
        report.seed,
        report.origin_x,
        report.origin_z,
        report.width,
        report.depth,
        report.sample_count,
        report.min_height,
        report.max_height,
        report.average_height,
        report.sea_level_coverage,
        report.water_coverage,
        report.ocean_ratio,
        report.land_ratio,
        report.mountain_coverage,
    });

    var i: usize = 0;
    while (i < BIOME_COUNT) : (i += 1) {
        const biome_id: BiomeId = @enumFromInt(i);
        const count = report.biomeCount(biome_id);
        if (count == 0) continue;
        const percent = @as(f64, @floatFromInt(count)) * 100.0 / @as(f64, @floatFromInt(report.sample_count));
        try writer.print("  {s}: {d} ({d:.2}%)\n", .{ @tagName(biome_id), count, percent });
    }

    try writer.print("region role effects:\n", .{});
    for (report.role_effect_profiles) |profile| {
        try writer.print(
            "  {s}: height_range={d} avg_height={d:.2} avg_slope={d:.2} mountain={d:.4} vegetation_mult={d:.2} drama={d:.2} river={d:.2} subbiome={d:.2}\n",
            .{
                @tagName(profile.id),
                profile.heightRange(),
                profile.average_height,
                profile.average_slope,
                profile.mountain_coverage,
                profile.vegetation_multiplier,
                profile.drama_mask,
                profile.river_mask,
                profile.subbiome_mask,
            },
        );
    }
}

fn sampleRoleEffectProfiles(allocator: Allocator, generator: *const TerrainShapeGenerator) ![ROLE_PROFILE_COUNT]RoleEffectProfile {
    const profile_ids = [_]RoleEffectProfileId{ .transit, .lake_destination, .forest_destination, .mountain_destination, .boundary };
    var profiles: [ROLE_PROFILE_COUNT]RoleEffectProfile = undefined;
    for (profile_ids, 0..) |profile_id, i| {
        profiles[i] = try sampleRoleEffectProfile(allocator, generator, profile_id);
    }
    return profiles;
}

fn sampleRoleEffectProfile(allocator: Allocator, generator: *const TerrainShapeGenerator, profile_id: RoleEffectProfileId) !RoleEffectProfile {
    const width: u32 = 64;
    const depth: u32 = 64;
    const origin_x: i32 = 96;
    const origin_z: i32 = 96;
    const sample_count = try std.math.mul(u32, width, depth);
    const controls = controlsForProfile(profile_id);

    const samples = try allocator.alloc(ColumnSample, sample_count);
    defer allocator.free(samples);

    var profile = RoleEffectProfile{
        .id = profile_id,
        .sample_count = sample_count,
        .min_height = std.math.maxInt(i32),
        .max_height = std.math.minInt(i32),
        .average_height = 0.0,
        .average_slope = 0.0,
        .mountain_coverage = 0.0,
        .vegetation_multiplier = controls.vegetation_mult,
        .drama_mask = controls.drama_mask,
        .river_mask = controls.river_mask,
        .subbiome_mask = controls.subbiome_mask,
        .biome_counts = [_]u32{0} ** BIOME_COUNT,
    };

    var height_sum: i64 = 0;
    var mountain_count: u32 = 0;
    const sea_level = generator.getSeaLevel();

    var z: u32 = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const wx_i = origin_x + @as(i32, @intCast(x));
            const wz_i = origin_z + @as(i32, @intCast(z));
            const column = generator.sampleColumnDataWithControls(@floatFromInt(wx_i), @floatFromInt(wz_i), 0, controls);
            const height = column.terrain_height_i;

            samples[idx] = .{
                .height = height,
                .continentalness = column.continentalness,
                .erosion = column.erosion,
                .ridge_mask = column.ridge_mask,
                .river_mask = column.river_mask,
                .temperature = column.temperature,
                .humidity = column.humidity,
                .is_ocean = column.is_ocean,
            };

            profile.min_height = @min(profile.min_height, height);
            profile.max_height = @max(profile.max_height, height);
            height_sum += height;
            if (height >= sea_level + 48 or column.ridge_mask >= 0.65) mountain_count += 1;
        }
    }

    var slope_sum: i64 = 0;
    z = 0;
    while (z < depth) : (z += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const idx = index(x, z, width);
            const sample = samples[idx];
            const slope = maxNeighborSlope(samples, x, z, width, depth);
            slope_sum += slope;
            const climate = generator.getBiomeSource().computeClimate(
                sample.temperature,
                sample.humidity,
                sample.height,
                sample.continentalness,
                sample.erosion,
                CHUNK_SIZE_Y,
            );
            const structural = biome_mod.StructuralParams{
                .height = sample.height,
                .slope = slope,
                .continentalness = sample.continentalness,
                .ridge_mask = sample.ridge_mask,
            };
            const biome_id = generator.getBiomeSource().selectBiome(climate, structural, sample.river_mask);
            profile.biome_counts[@intFromEnum(biome_id)] += 1;
        }
    }

    const denominator: f64 = @floatFromInt(sample_count);
    profile.average_height = @as(f64, @floatFromInt(height_sum)) / denominator;
    profile.average_slope = @as(f64, @floatFromInt(slope_sum)) / denominator;
    profile.mountain_coverage = @as(f64, @floatFromInt(mountain_count)) / denominator;
    return profile;
}

fn controlsForProfile(profile_id: RoleEffectProfileId) region_mod.RegionControls {
    const info = regionInfoForProfile(profile_id);
    return .{
        .height_mult = region_mod.getHeightMultiplier(info),
        .vegetation_mult = region_mod.getVegetationMultiplier(info),
        .drama_mask = if (region_mod.allowHeightDrama(info)) 1.0 else 0.0,
        .river_mask = if (region_mod.allowRiver(info)) 1.0 else 0.0,
        .subbiome_mask = if (region_mod.allowSubBiomes(info)) 1.0 else 0.0,
    };
}

fn regionInfoForProfile(profile_id: RoleEffectProfileId) region_mod.RegionInfo {
    const role: region_mod.RegionRole = switch (profile_id) {
        .transit => .transit,
        .lake_destination, .forest_destination, .mountain_destination => .destination,
        .boundary => .boundary,
    };
    const focus: region_mod.FeatureFocus = switch (profile_id) {
        .transit, .boundary => .none,
        .lake_destination => .lake,
        .forest_destination => .forest,
        .mountain_destination => .mountain,
    };
    return .{
        .mood = .calm,
        .role = role,
        .focus = focus,
        .center_x = 0,
        .center_z = 0,
    };
}

fn maxNeighborSlope(samples: []const ColumnSample, x: u32, z: u32, width: u32, depth: u32) i32 {
    const current = samples[index(x, z, width)].height;
    var max_slope: i32 = 0;
    if (x > 0) max_slope = @max(max_slope, heightDelta(current, samples[index(x - 1, z, width)].height));
    if (x + 1 < width) max_slope = @max(max_slope, heightDelta(current, samples[index(x + 1, z, width)].height));
    if (z > 0) max_slope = @max(max_slope, heightDelta(current, samples[index(x, z - 1, width)].height));
    if (z + 1 < depth) max_slope = @max(max_slope, heightDelta(current, samples[index(x, z + 1, width)].height));
    return max_slope;
}

fn heightDelta(a: i32, b: i32) i32 {
    return if (a > b) a - b else b - a;
}

fn index(x: u32, z: u32, width: u32) u32 {
    return x + z * width;
}

test "TerrainReport is deterministic for fixed seed and region" {
    const allocator = std.testing.allocator;

    const first = try sampleRegion(allocator, 42, -32, -32, 64, 64);
    const second = try sampleRegion(allocator, 42, -32, -32, 64, 64);

    try std.testing.expectEqual(first.seed, second.seed);
    try std.testing.expectEqual(first.origin_x, second.origin_x);
    try std.testing.expectEqual(first.origin_z, second.origin_z);
    try std.testing.expectEqual(first.width, second.width);
    try std.testing.expectEqual(first.depth, second.depth);
    try std.testing.expectEqual(first.sample_count, second.sample_count);
    try std.testing.expectEqualSlices(u32, &first.biome_counts, &second.biome_counts);
    try std.testing.expectEqual(first.min_height, second.min_height);
    try std.testing.expectEqual(first.max_height, second.max_height);
    try std.testing.expectEqual(first.average_height, second.average_height);
    try std.testing.expectEqual(first.sea_level_coverage, second.sea_level_coverage);
    try std.testing.expectEqual(first.water_coverage, second.water_coverage);
    try std.testing.expectEqual(first.ocean_ratio, second.ocean_ratio);
    try std.testing.expectEqual(first.land_ratio, second.land_ratio);
    try std.testing.expectEqual(first.mountain_coverage, second.mountain_coverage);
    for (first.role_effect_profiles, second.role_effect_profiles) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try std.testing.expectEqual(a.sample_count, b.sample_count);
        try std.testing.expectEqual(a.min_height, b.min_height);
        try std.testing.expectEqual(a.max_height, b.max_height);
        try std.testing.expectEqual(a.average_height, b.average_height);
        try std.testing.expectEqual(a.average_slope, b.average_slope);
        try std.testing.expectEqual(a.mountain_coverage, b.mountain_coverage);
        try std.testing.expectEqualSlices(u32, &a.biome_counts, &b.biome_counts);
    }
}

test "TerrainReport metrics cover the full sample area" {
    const allocator = std.testing.allocator;

    const report = try sampleRegion(allocator, 424242, -64, 16, 64, 64);

    var biome_total: u32 = 0;
    for (report.biome_counts) |count| biome_total += count;

    try std.testing.expectEqual(report.sample_count, biome_total);
    try std.testing.expect(report.min_height <= report.max_height);
    try std.testing.expect(report.average_height >= @as(f64, @floatFromInt(report.min_height)));
    try std.testing.expect(report.average_height <= @as(f64, @floatFromInt(report.max_height)));
    try std.testing.expect(report.sea_level_coverage >= 0.0 and report.sea_level_coverage <= 1.0);
    try std.testing.expect(report.water_coverage >= 0.0 and report.water_coverage <= report.sea_level_coverage);
    try std.testing.expect(report.ocean_ratio >= 0.0 and report.ocean_ratio <= 1.0);
    try std.testing.expect(report.land_ratio >= 0.0 and report.land_ratio <= 1.0);
    try std.testing.expect(report.mountain_coverage >= 0.0 and report.mountain_coverage <= 1.0);
    try std.testing.expectApproxEqAbs(1.0, report.ocean_ratio + report.land_ratio, 0.000001);
    for (report.role_effect_profiles) |profile| {
        var profile_biome_total: u32 = 0;
        for (profile.biome_counts) |count| profile_biome_total += count;

        try std.testing.expectEqual(profile.sample_count, profile_biome_total);
        try std.testing.expect(profile.min_height <= profile.max_height);
        try std.testing.expect(profile.average_height >= @as(f64, @floatFromInt(profile.min_height)));
        try std.testing.expect(profile.average_height <= @as(f64, @floatFromInt(profile.max_height)));
        try std.testing.expect(profile.average_slope >= 0.0);
        try std.testing.expect(profile.mountain_coverage >= 0.0 and profile.mountain_coverage <= 1.0);
    }
}

test "TerrainReport role profiles preserve region pacing controls" {
    const allocator = std.testing.allocator;

    const report = try sampleRegion(allocator, 424242, -64, 16, 64, 64);
    const transit = report.role_effect_profiles[@intFromEnum(RoleEffectProfileId.transit)];
    const forest = report.role_effect_profiles[@intFromEnum(RoleEffectProfileId.forest_destination)];
    const mountain = report.role_effect_profiles[@intFromEnum(RoleEffectProfileId.mountain_destination)];
    const boundary = report.role_effect_profiles[@intFromEnum(RoleEffectProfileId.boundary)];

    try std.testing.expect(transit.heightRange() < boundary.heightRange());
    try std.testing.expect(transit.average_slope < boundary.average_slope);
    try std.testing.expect(mountain.heightRange() > boundary.heightRange());
    try std.testing.expect(mountain.mountain_coverage >= boundary.mountain_coverage);
    try std.testing.expect(forest.vegetation_multiplier > transit.vegetation_multiplier);
    try std.testing.expect(forest.vegetation_multiplier > boundary.vegetation_multiplier);
    try std.testing.expect(forest.subbiome_mask > transit.subbiome_mask);
}

test "TerrainReport water coverage matches surface water placement" {
    const allocator = std.testing.allocator;
    const report = try sampleRegion(allocator, 42, -128, -128, 256, 256);
    const generator = TerrainShapeGenerator.init(42);
    const builder = generator.getSurfaceBuilder();
    const sea_level = generator.getSeaLevel();
    var water_count: u32 = 0;
    var dry_sea_level_count: u32 = 0;
    var z: i32 = -128;
    while (z < 128) : (z += 1) {
        var x: i32 = -128;
        while (x < 128) : (x += 1) {
            const column = generator.sampleColumnData(@floatFromInt(x), @floatFromInt(z), 0);
            const block = builder.getBlockAt(sea_level, column.terrain_height_i, .plains, 3, column.is_ocean, column.is_underwater);
            if (block == .water) water_count += 1;
            if (column.terrain_height_i == sea_level) {
                try std.testing.expect(block != .water and block != .air);
                dry_sea_level_count += 1;
            }
        }
    }
    try std.testing.expect(water_count > 0);
    try std.testing.expect(dry_sea_level_count > 0);
    const denominator: f64 = @floatFromInt(report.sample_count);
    try std.testing.expectEqual(@as(f64, @floatFromInt(water_count)) / denominator, report.water_coverage);
    try std.testing.expectEqual(@as(f64, @floatFromInt(water_count + dry_sea_level_count)) / denominator, report.sea_level_coverage);

    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeReport(&writer, report);
    var coverage_buffer: [128]u8 = undefined;
    const coverage = try std.fmt.bufPrint(&coverage_buffer, "sea_level_or_below={d:.4} water={d:.4}", .{ report.sea_level_coverage, report.water_coverage });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), coverage) != null);
}

test "representative seeds keep varied but readable spawn regions" {
    const allocator = std.testing.allocator;

    var total_samples: u32 = 0;
    var ocean_samples: u32 = 0;
    var forest_samples: u32 = 0;
    var wetland_samples: u32 = 0;
    var dry_samples: u32 = 0;
    var mountain_samples: u32 = 0;

    for (representative_seeds) |seed| {
        const report = try sampleRegion(allocator, seed, -128, -128, 256, 256);
        errdefer std.debug.print("spawn seed {d}: ocean={d:.6} water={d:.6} sea_level={d:.6} mountain={d:.6} height={d}..{d}\n", .{
            seed, report.ocean_ratio, report.water_coverage, report.sea_level_coverage, report.mountain_coverage, report.min_height, report.max_height,
        });
        try std.testing.expect(report.ocean_ratio <= 0.30);
        try std.testing.expect(report.water_coverage <= 0.30);
        try std.testing.expect(report.mountain_coverage <= 0.12);

        // Local spawn readability is not a climate-diversity survey. Cover more
        // than the 900-block continental and 1400-block macro-climate spreads,
        // at full noise detail with the same number of survey samples per seed.
        var survey = try @import("climate_snapshot.zig").capture(allocator, .{
            .seed = seed,
            .origin_x = -1024,
            .origin_z = -1024,
            .width = 256,
            .depth = 256,
            .step = 8.0,
            .reduction = 0,
        });
        defer survey.deinit(allocator);
        const generator = TerrainShapeGenerator.init(seed);
        for (survey.samples) |sample| {
            // Snapshots assume flat slopes. Reselect with actual one-block
            // neighbors, not height differences across the eight-block grid.
            var slope: i32 = 0;
            for ([_][2]f32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |offset| {
                const neighbor = generator.sampleColumnData(sample.world_x + offset[0], sample.world_z + offset[1], 0);
                slope = @max(slope, heightDelta(sample.height, neighbor.terrain_height_i));
            }
            const selected = generator.getBiomeSource().selectBiome(.{
                .temperature = sample.temperature,
                .humidity = sample.humidity,
                .elevation = sample.elevation,
                .continentalness = sample.continentalness,
                .ruggedness = sample.ruggedness,
            }, .{
                .height = sample.height,
                .slope = slope,
                .continentalness = sample.continentalness,
                .ridge_mask = sample.ridge_mask,
            }, sample.river_mask);
            total_samples += 1;
            switch (selected) {
                .ocean, .warm_ocean, .cold_ocean, .frozen_ocean, .deep_ocean => ocean_samples += 1,
                .forest, .birch_forest, .dark_forest, .flower_forest, .taiga, .snowy_taiga, .old_growth_taiga, .jungle, .bamboo_jungle, .sparse_jungle => forest_samples += 1,
                .swamp, .mangrove_swamp => wetland_samples += 1,
                .desert, .savanna, .savanna_plateau, .windswept_savanna, .badlands, .wooded_badlands, .eroded_badlands => dry_samples += 1,
                else => {},
            }
            if (sample.height >= generator.getSeaLevel() + 48 or sample.ridge_mask >= 0.65) mountain_samples += 1;
        }
    }

    const denominator: f64 = @floatFromInt(total_samples);
    errdefer std.debug.print("spawn totals: samples={d} ocean={d} forest={d} wetland={d} dry={d} mountain={d}\n", .{
        total_samples, ocean_samples, forest_samples, wetland_samples, dry_samples, mountain_samples,
    });
    try std.testing.expect(@as(f64, @floatFromInt(ocean_samples)) / denominator >= 0.03);
    try std.testing.expect(@as(f64, @floatFromInt(forest_samples)) / denominator >= 0.08);
    try std.testing.expect(@as(f64, @floatFromInt(wetland_samples)) / denominator >= 0.005);
    try std.testing.expect(@as(f64, @floatFromInt(dry_samples)) / denominator >= 0.003);
    try std.testing.expect(@as(f64, @floatFromInt(mountain_samples)) / denominator >= 0.002);
}
