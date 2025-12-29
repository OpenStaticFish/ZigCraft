//! Terrain generator using Luanti-style phased pipeline per worldgen-luanti-style.md
//! Phase A: Terrain Shape (stone + water only, biome-agnostic)
//! Phase B: Biome Calculation (climate space, weights)
//! Phase C: Surface Dusting (top/filler replacement)
//! Phase D: Cave Carving
//! Phase E: Decorations and Features

const std = @import("std");
const noise_mod = @import("noise.zig");
const Noise = noise_mod.Noise;
const smoothstep = noise_mod.smoothstep;
const clamp01 = noise_mod.clamp01;
const CaveSystem = @import("caves.zig").CaveSystem;
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const BiomeDefinition = biome_mod.BiomeDefinition;
const ClimateParams = biome_mod.ClimateParams;
const gen_region = @import("gen_region.zig");
const GenRegion = gen_region.GenRegion;
const GenRegionCache = gen_region.GenRegionCache;
const REGION_SIZE_X = gen_region.REGION_SIZE_X;
const REGION_SIZE_Z = gen_region.REGION_SIZE_Z;
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const MAX_LIGHT = @import("../chunk.zig").MAX_LIGHT;
const BlockType = @import("../block.zig").BlockType;
const Biome = @import("../block.zig").Biome;

/// Explicit continentalness zones for terrain structure
pub const ContinentalZone = enum {
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

/// Terrain generation parameters
const Params = struct {
    warp_scale: f32 = 1.0 / 1100.0,
    warp_amplitude: f32 = 50.0,
    continental_scale: f32 = 1.0 / 800.0,
    continental_deep_ocean_max: f32 = 0.35,
    continental_ocean_max: f32 = 0.45,
    continental_coast_max: f32 = 0.50,
    continental_inland_low_max: f32 = 0.65,
    continental_inland_high_max: f32 = 0.80,
    erosion_scale: f32 = 1.0 / 600.0,
    peaks_scale: f32 = 1.0 / 900.0,
    temperature_macro_scale: f32 = 1.0 / 600.0,
    temperature_local_scale: f32 = 1.0 / 120.0,
    humidity_macro_scale: f32 = 1.0 / 500.0,
    humidity_local_scale: f32 = 1.0 / 100.0,
    climate_macro_weight: f32 = 0.60,
    temp_lapse: f32 = 0.25,
    sea_level: i32 = 64,
    mount_amp: f32 = 90.0,
    mount_cap: f32 = 200.0,
    detail_scale: f32 = 1.0 / 150.0,
    detail_amp: f32 = 12.0,
    highland_range: f32 = 100.0,
    coast_jitter_scale: f32 = 1.0 / 650.0,
    seabed_scale: f32 = 1.0 / 280.0,
    seabed_amp: f32 = 6.0,
    river_scale: f32 = 1.0 / 1200.0,
    river_min: f32 = 0.74,
    river_max: f32 = 0.84,
    river_depth_max: f32 = 12.0,
    // Structural coastline parameters (replaces post-process shore_dist search)
    coast_continentalness_min: f32 = 0.45, // Where coast zone begins
    coast_continentalness_max: f32 = 0.52, // Where coast zone ends
    beach_max_height_above_sea: i32 = 4, // Max blocks above sea level for beach
    beach_max_slope: i32 = 2, // Gentle slopes become sand beaches
    cliff_min_slope: i32 = 5, // Steep slopes become stone cliffs
    gravel_erosion_threshold: f32 = 0.7, // High erosion areas get gravel
    coastal_no_tree_min: i32 = 8,
    coastal_no_tree_max: i32 = 18,
    mount_inland_min: f32 = 0.48,
    mount_inland_max: f32 = 0.70,
    mount_peak_min: f32 = 0.60,
    mount_peak_max: f32 = 0.90,
    mount_rugged_min: f32 = 0.45,
    mount_rugged_max: f32 = 0.85,
    mid_freq_hill_scale: f32 = 1.0 / 100.0,
    mid_freq_hill_amp: f32 = 20.0,
    peak_compression_offset: f32 = 90.0,
    peak_compression_range: f32 = 100.0,
    terrace_step: f32 = 4.0,
    ridge_scale: f32 = 1.0 / 1400.0,
    ridge_amp: f32 = 60.0,
    ridge_inland_min: f32 = 0.50,
    ridge_inland_max: f32 = 0.85,
    ridge_sparsity: f32 = 0.65,
};

pub const TerrainGenerator = struct {
    warp_noise_x: Noise,
    warp_noise_z: Noise,
    continentalness_noise: Noise,
    erosion_noise: Noise,
    peaks_noise: Noise,
    temperature_noise: Noise,
    humidity_noise: Noise,
    temperature_local_noise: Noise,
    humidity_local_noise: Noise,
    detail_noise: Noise,
    coast_jitter_noise: Noise,
    seabed_noise: Noise,
    river_noise: Noise,
    beach_exposure_noise: Noise,
    cave_system: CaveSystem,
    filler_depth_noise: Noise,
    mountain_lift_noise: Noise,
    ridge_noise: Noise,
    params: Params,
    allocator: std.mem.Allocator,

    pub fn init(seed: u64, allocator: std.mem.Allocator) TerrainGenerator {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        return .{
            .warp_noise_x = Noise.init(random.int(u64)),
            .warp_noise_z = Noise.init(random.int(u64)),
            .continentalness_noise = Noise.init(random.int(u64)),
            .erosion_noise = Noise.init(random.int(u64)),
            .peaks_noise = Noise.init(random.int(u64)),
            .temperature_noise = Noise.init(random.int(u64)),
            .humidity_noise = Noise.init(random.int(u64)),
            .temperature_local_noise = Noise.init(random.int(u64)),
            .humidity_local_noise = Noise.init(random.int(u64)),
            .detail_noise = Noise.init(random.int(u64)),
            .coast_jitter_noise = Noise.init(random.int(u64)),
            .seabed_noise = Noise.init(random.int(u64)),
            .river_noise = Noise.init(random.int(u64)),
            .beach_exposure_noise = Noise.init(random.int(u64)),
            .cave_system = CaveSystem.init(seed),
            .filler_depth_noise = Noise.init(random.int(u64)),
            .mountain_lift_noise = Noise.init(random.int(u64)),
            .ridge_noise = Noise.init(random.int(u64)),
            .params = .{},
            .allocator = allocator,
        };
    }

    pub const ColumnInfo = struct {
        height: i32,
        biome: BiomeId,
        is_ocean: bool,
        temperature: f32,
        humidity: f32,
        continentalness: f32,
    };

    pub fn getColumnInfo(self: *const TerrainGenerator, wx: f32, wz: f32) ColumnInfo {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);
        const warp = self.computeWarp(wx, wz);
        const xw = wx + warp.x;
        const zw = wz + warp.z;
        const c = self.getContinentalness(xw, zw);
        const e = self.getErosion(xw, zw);
        const pv = self.getPeaksValleys(xw, zw);
        const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 3, 2.0, 0.5, p.coast_jitter_scale) * 0.05;
        const c_jittered = clamp01(c + coast_jitter);
        var terrain_height = self.computeHeight(c_jittered, e, pv, xw, zw);
        const river_mask = self.getRiverMask(xw, zw);
        const ridge_mask = self.getRidgeFactor(xw, zw, c_jittered);
        if (river_mask > 0 and terrain_height > sea - 5) {
            const river_depth = river_mask * p.river_depth_max;
            terrain_height = @min(terrain_height, terrain_height - river_depth);
        }
        if (terrain_height < sea) {
            const deep_factor = 1.0 - smoothstep(p.continental_deep_ocean_max, 0.5, c_jittered);
            const seabed_detail = self.seabed_noise.fbm2D(xw, zw, 5, 2.0, 0.5, p.seabed_scale) * p.seabed_amp;
            const base_seabed = sea - 18.0 - deep_factor * 35.0;
            terrain_height = @min(terrain_height, base_seabed + seabed_detail);
        }
        const terrain_height_i: i32 = @intFromFloat(terrain_height);
        const is_ocean = terrain_height < sea;
        const altitude_offset: f32 = @max(0, terrain_height - sea);
        var temperature = self.getTemperature(xw, zw);
        temperature = clamp01(temperature - (altitude_offset / 512.0) * p.temp_lapse);
        const humidity = self.getHumidity(xw, zw);
        const climate = biome_mod.computeClimateParams(temperature, humidity, terrain_height_i, c_jittered, e, p.sea_level, CHUNK_SIZE_Y);

        const slope: i32 = 1;
        const structural = biome_mod.StructuralParams{
            .height = terrain_height_i,
            .slope = slope,
            .continentalness = c_jittered,
            .ridge_mask = ridge_mask,
        };

        const biome_id = biome_mod.selectBiomeWithConstraintsAndRiver(climate, structural, river_mask);
        return .{
            .height = terrain_height_i,
            .biome = biome_id,
            .is_ocean = is_ocean,
            .temperature = temperature,
            .humidity = humidity,
            .continentalness = c_jittered,
        };
    }

    pub fn generate(self: *const TerrainGenerator, chunk: *Chunk, stop_flag: ?*const bool) void {
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        var surface_heights: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId = undefined;
        var secondary_biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId = undefined;
        var biome_blends: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var filler_depths: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var is_ocean_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool = undefined;
        var cave_region_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var debug_temperatures: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var debug_humidities: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var debug_continentalness: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var continentalness_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var erosion_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var ridge_masks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var river_masks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var temperatures: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var humidities: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));
                const warp = self.computeWarp(wx, wz);
                const xw = wx + warp.x;
                const zw = wz + warp.z;
                const c = self.getContinentalness(xw, zw);
                const e_val = self.getErosion(xw, zw);
                const pv = self.getPeaksValleys(xw, zw);
                const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 3, 2.0, 0.5, p.coast_jitter_scale) * 0.05;
                const c_jittered = clamp01(c + coast_jitter);
                erosion_values[idx] = e_val;
                var terrain_height = self.computeHeight(c_jittered, e_val, pv, xw, zw);
                const river_mask = self.getRiverMask(xw, zw);
                const ridge_mask = self.getRidgeFactor(xw, zw, c_jittered);
                if (river_mask > 0 and terrain_height > sea - 5) {
                    const river_depth = river_mask * p.river_depth_max;
                    terrain_height = @min(terrain_height, terrain_height - river_depth);
                }
                if (terrain_height < sea) {
                    const deep_factor = 1.0 - smoothstep(p.continental_deep_ocean_max, 0.5, c_jittered);
                    const seabed_detail = self.seabed_noise.fbm2D(xw, zw, 5, 2.0, 0.5, p.seabed_scale) * p.seabed_amp;
                    const base_seabed = sea - 18.0 - deep_factor * 35.0;
                    terrain_height = @min(terrain_height, base_seabed + seabed_detail);
                }
                var terrain_height_i: i32 = @intFromFloat(terrain_height);
                const altitude_offset: f32 = @max(0, terrain_height - sea);
                var temperature = self.getTemperature(xw, zw);
                temperature = clamp01(temperature - (altitude_offset / 512.0) * p.temp_lapse);
                const humidity = self.getHumidity(xw, zw);
                debug_temperatures[idx] = temperature;
                debug_humidities[idx] = humidity;
                debug_continentalness[idx] = c_jittered;
                temperatures[idx] = temperature;
                humidities[idx] = humidity;
                continentalness_values[idx] = c_jittered;
                ridge_masks[idx] = ridge_mask;
                river_masks[idx] = river_mask;
                terrain_height_i = @intFromFloat(terrain_height);
                const is_ocean = terrain_height < sea;
                surface_heights[idx] = terrain_height_i;
                is_ocean_flags[idx] = is_ocean;
                cave_region_values[idx] = self.cave_system.getCaveRegionValue(wx, wz);
            }
        }

        var slopes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_h = surface_heights[idx];
                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx + CHUNK_SIZE_X]))));
                slopes[idx] = max_slope;
            }
        }

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_height_i = surface_heights[idx];
                const temperature = temperatures[idx];
                const humidity = humidities[idx];
                const continentalness = continentalness_values[idx];
                const erosion = erosion_values[idx];
                const ridge_mask = ridge_masks[idx];
                const slope = slopes[idx];
                const river_mask = river_masks[idx];
                const climate = biome_mod.computeClimateParams(temperature, humidity, terrain_height_i, continentalness, erosion, p.sea_level, CHUNK_SIZE_Y);

                const structural = biome_mod.StructuralParams{
                    .height = terrain_height_i,
                    .slope = slope,
                    .continentalness = continentalness,
                    .ridge_mask = ridge_mask,
                };

                const biome_id = biome_mod.selectBiomeWithConstraintsAndRiver(climate, structural, river_mask);
                biome_ids[idx] = biome_id;
                secondary_biome_ids[idx] = biome_id;
                biome_blends[idx] = 0.0;
                chunk.setBiome(local_x, local_z, biome_id);

                const biome_def = biome_mod.getBiomeDefinition(biome_id);
                filler_depths[idx] = biome_def.surface.depth_range;
            }
        }

        var coastal_types: [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType = undefined;
        var exposure_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;

        // Compute structural coastal surface types (replaces shore_dist search - Issue #95)
        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));
                exposure_values[idx] = self.beach_exposure_noise.fbm2DNormalized(wx, wz, 2, 2.0, 0.5, 1.0 / 200.0);

                // Use structural signals instead of distance search
                const continentalness = continentalness_values[idx];
                const slope = slopes[idx];
                const height = surface_heights[idx];
                const erosion = erosion_values[idx];

                coastal_types[idx] = self.getCoastalSurfaceType(continentalness, slope, height, erosion);
            }
        }

        var worm_carve_map = self.cave_system.generateWormCaves(chunk, &surface_heights, self.allocator) catch {
            self.generateWithoutWormCavesInternal(chunk, &surface_heights, &biome_ids, &secondary_biome_ids, &biome_blends, &filler_depths, &is_ocean_flags, &cave_region_values, &coastal_types, &slopes, &exposure_values, sea);
            return;
        };
        defer worm_carve_map.deinit();

        var debug_beach_count: u32 = 0;
        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_height_i = surface_heights[idx];
                const filler_depth = filler_depths[idx];
                const is_ocean = is_ocean_flags[idx];
                const cave_region = cave_region_values[idx];
                const coastal_type = coastal_types[idx];
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Structural coastal surface detection (Issue #95)
                const is_sand_beach = coastal_type == .sand_beach;
                const is_gravel_beach = coastal_type == .gravel_beach;
                const is_cliff = coastal_type == .cliff;
                if (is_sand_beach or is_gravel_beach) debug_beach_count += 1;

                var y: i32 = 0;
                const primary_biome_id = biome_ids[idx];
                const secondary_biome_id = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < blend;
                const active_biome_id = if (use_secondary) secondary_biome_id else primary_biome_id;
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean, sea);
                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    // Apply structural coastal surface types
                    if (is_surface and block != .air and block != .water and block != .bedrock) {
                        if (is_sand_beach) {
                            block = .sand;
                        } else if (is_gravel_beach) {
                            block = .gravel;
                        } else if (is_cliff) {
                            block = .stone;
                        }
                    } else if (is_near_surface and (is_sand_beach or is_gravel_beach) and block == .dirt) {
                        block = if (is_gravel_beach) .gravel else .sand;
                    }
                    if (block != .air and block != .water and block != .bedrock) {
                        const wy: f32 = @floatFromInt(y);
                        const should_carve_worm = worm_carve_map.get(local_x, @intCast(y), local_z);
                        const should_carve_cavity = self.cave_system.shouldCarveNoiseCavity(wx, wy, wz, terrain_height_i, cave_region);
                        if (should_carve_worm or should_carve_cavity) {
                            block = if (y < p.sea_level) .water else .air;
                        }
                    }
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }
        chunk.generated = true;
        if (stop_flag) |sf| if (sf.*) return;
        self.generateOres(chunk);
        if (stop_flag) |sf| if (sf.*) return;
        self.generateFeatures(chunk, &biome_ids, &secondary_biome_ids, &biome_blends);
        if (stop_flag) |sf| if (sf.*) return;
        self.computeSkylight(chunk);
        if (stop_flag) |sf| if (sf.*) return;
        self.computeBlockLight(chunk) catch |err| {
            std.debug.print("Failed to compute block light: {}\n", .{err});
        };
        chunk.dirty = true;
        self.printDebugStats(world_x, world_z, &debug_temperatures, &debug_humidities, &debug_continentalness, &biome_ids, debug_beach_count);
    }

    fn generateWithoutWormCavesInternal(self: *const TerrainGenerator, chunk: *Chunk, surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, secondary_biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, biome_blends: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, filler_depths: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, is_ocean_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool, cave_region_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, coastal_types: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType, slopes: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, exposure_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, sea: f32) void {
        _ = exposure_values;
        _ = slopes;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const p = self.params;
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_height_i = surface_heights[idx];
                const filler_depth = filler_depths[idx];
                const is_ocean = is_ocean_flags[idx];
                const cave_region = cave_region_values[idx];
                const coastal_type = coastal_types[idx];
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Structural coastal surface detection (Issue #95)
                const is_sand_beach = coastal_type == .sand_beach;
                const is_gravel_beach = coastal_type == .gravel_beach;
                const is_cliff = coastal_type == .cliff;

                var y: i32 = 0;
                const primary_biome_id = biome_ids[idx];
                const secondary_biome_id = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < blend;
                const active_biome_id = if (use_secondary) secondary_biome_id else primary_biome_id;
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean, sea);
                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    // Apply structural coastal surface types
                    if (is_surface and block != .air and block != .water and block != .bedrock) {
                        if (is_sand_beach) {
                            block = .sand;
                        } else if (is_gravel_beach) {
                            block = .gravel;
                        } else if (is_cliff) {
                            block = .stone;
                        }
                    } else if (is_near_surface and (is_sand_beach or is_gravel_beach) and block == .dirt) {
                        block = if (is_gravel_beach) .gravel else .sand;
                    }
                    if (block != .air and block != .water and block != .bedrock) {
                        const wy: f32 = @floatFromInt(y);
                        if (self.cave_system.shouldCarveNoiseCavity(wx, wy, wz, terrain_height_i, cave_region)) {
                            block = if (y < p.sea_level) .water else .air;
                        }
                    }
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }
        chunk.generated = true;
        self.generateOres(chunk);
        self.generateFeatures(chunk, biome_ids, secondary_biome_ids, biome_blends);
        self.computeSkylight(chunk);
        self.computeBlockLight(chunk) catch {};
        chunk.dirty = true;
    }

    fn printDebugStats(self: *const TerrainGenerator, world_x: i32, world_z: i32, t_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, h_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, c_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, b_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, beach_count: u32) void {
        const chunk_id = @as(u32, @bitCast(world_x)) +% @as(u32, @bitCast(world_z));
        if (chunk_id % 64 != 0) return;
        var t_min: f32 = 1.0;
        var t_max: f32 = 0.0;
        var t_sum: f32 = 0.0;
        var h_min: f32 = 1.0;
        var h_max: f32 = 0.0;
        var h_sum: f32 = 0.0;
        var c_min: f32 = 1.0;
        var c_max: f32 = 0.0;
        var c_sum: f32 = 0.0;
        var biome_counts: [21]u32 = [_]u32{0} ** 21;
        var zone_counts: [6]u32 = [_]u32{0} ** 6;
        var t_hot: u32 = 0;
        var h_dry: u32 = 0;
        for (0..CHUNK_SIZE_X * CHUNK_SIZE_Z) |i| {
            t_min = @min(t_min, t_vals[i]);
            t_max = @max(t_max, t_vals[i]);
            t_sum += t_vals[i];
            h_min = @min(h_min, h_vals[i]);
            h_max = @max(h_max, h_vals[i]);
            h_sum += h_vals[i];
            c_min = @min(c_min, c_vals[i]);
            c_max = @max(c_max, c_vals[i]);
            c_sum += c_vals[i];
            if (t_vals[i] > 0.7) t_hot += 1;
            if (h_vals[i] < 0.25) h_dry += 1;
            const bid = @intFromEnum(b_ids[i]);
            if (bid < 21) biome_counts[bid] += 1;
            const zone = self.getContinentalZone(c_vals[i]);
            const zone_idx: u32 = @intFromEnum(zone);
            if (zone_idx < 6) zone_counts[zone_idx] += 1;
        }
        const n: f32 = @floatFromInt(CHUNK_SIZE_X * CHUNK_SIZE_Z);
        std.debug.print("\n=== WORLDGEN DEBUG @ chunk ({}, {}) ===\n", .{ world_x, world_z });
        std.debug.print("T: min={d:.2} max={d:.2} avg={d:.2} | hot(>0.7): {}%\n", .{ t_min, t_max, t_sum / n, t_hot * 100 / @as(u32, @intCast(CHUNK_SIZE_X * CHUNK_SIZE_Z)) });
        std.debug.print("H: min={d:.2} max={d:.2} avg={d:.2} | dry(<0.25): {}%\n", .{ h_min, h_max, h_sum / n, h_dry * 100 / @as(u32, @intCast(CHUNK_SIZE_X * CHUNK_SIZE_Z)) });
        std.debug.print("C: min={d:.2} max={d:.2} avg={d:.2}\n", .{ c_min, c_max, c_sum / n });
        std.debug.print("Beach triggers: {} / {}\n", .{ beach_count, CHUNK_SIZE_X * CHUNK_SIZE_Z });
        std.debug.print("Continental Zones: ", .{});
        for (zone_counts, 0..) |count, zi| {
            if (count > 0) {
                const zone: ContinentalZone = @enumFromInt(@as(u8, @intCast(zi)));
                std.debug.print("{s}={} ", .{ zone.name(), count });
            }
        }
        std.debug.print("\n", .{});
        std.debug.print("Biomes: ", .{});
        const biome_names = [_][]const u8{ "deep_ocean", "ocean", "beach", "plains", "forest", "taiga", "desert", "snow_tundra", "mountains", "snowy_mountains", "river", "swamp", "mangrove", "jungle", "savanna", "badlands", "mushroom", "foothills", "marsh", "dry_plains", "coastal" };
        for (biome_counts, 0..) |count, bi| {
            if (count > 0) std.debug.print("{s}={} ", .{ biome_names[bi], count });
        }
        std.debug.print("\n", .{});
    }

    fn computeWarp(self: *const TerrainGenerator, x: f32, z: f32) struct { x: f32, z: f32 } {
        const p = self.params;
        const offset_x = self.warp_noise_x.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        const offset_z = self.warp_noise_z.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        return .{ .x = offset_x, .z = offset_z };
    }

    fn getContinentalness(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.continentalness_noise.fbm2D(x, z, 4, 2.0, 0.5, self.params.continental_scale);
        return (val + 1.0) * 0.5;
    }

    /// Map continentalness value (0-1) to explicit zone
    pub fn getContinentalZone(self: *const TerrainGenerator, c: f32) ContinentalZone {
        const p = self.params;
        if (c < p.continental_deep_ocean_max) {
            return .deep_ocean;
        } else if (c < p.continental_ocean_max) {
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

    fn getErosion(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.erosion_noise.fbm2D(x, z, 4, 2.0, 0.5, self.params.erosion_scale);
        return (val + 1.0) * 0.5;
    }

    fn getPeaksValleys(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        return self.peaks_noise.ridged2D(x, z, 5, 2.0, 0.5, self.params.peaks_scale);
    }

    fn getTemperature(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        const macro = self.temperature_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.temperature_macro_scale);
        const local = self.temperature_local_noise.fbm2DNormalized(x, z, 2, 2.0, 0.5, p.temperature_local_scale);
        var t = p.climate_macro_weight * macro + (1.0 - p.climate_macro_weight) * local;
        t = (t - 0.5) * 2.2 + 0.5;
        return clamp01(t);
    }

    fn getHumidity(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        const macro = self.humidity_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.humidity_macro_scale);
        const local = self.humidity_local_noise.fbm2DNormalized(x, z, 2, 2.0, 0.5, p.humidity_local_scale);
        var h = p.climate_macro_weight * macro + (1.0 - p.climate_macro_weight) * local;
        h = (h - 0.5) * 2.2 + 0.5;
        return clamp01(h);
    }

    fn getMountainMask(self: *const TerrainGenerator, pv: f32, e: f32, c: f32) f32 {
        const p = self.params;
        const inland = smoothstep(p.mount_inland_min, p.mount_inland_max, c);
        const peak_factor = smoothstep(p.mount_peak_min, p.mount_peak_max, pv);
        const rugged_factor = 1.0 - smoothstep(p.mount_rugged_min, p.mount_rugged_max, e);
        return inland * peak_factor * rugged_factor;
    }

    fn getRidgeFactor(self: *const TerrainGenerator, x: f32, z: f32, c: f32) f32 {
        const p = self.params;
        const inland_factor = smoothstep(p.ridge_inland_min, p.ridge_inland_max, c);
        const ridge_val = self.ridge_noise.ridged2D(x, z, 5, 2.0, 0.5, p.ridge_scale);
        const sparsity_mask = smoothstep(p.ridge_sparsity - 0.15, p.ridge_sparsity + 0.15, ridge_val);
        return inland_factor * sparsity_mask * ridge_val;
    }

    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32, x: f32, z: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);
        var base_height: f32 = undefined;
        if (c < 0.45) {
            const ocean_t = c / 0.45;
            base_height = sea - 45.0 + ocean_t * 40.0;
        } else if (c < 0.52) {
            const coast_t = (c - 0.45) / 0.07;
            base_height = sea - 5.0 + coast_t * 13.0;
        } else {
            const inland_t = smoothstep(0.52, 0.90, c);
            base_height = sea + 8.0 + inland_t * 42.0;
        }
        const m_mask = self.getMountainMask(pv, e, c);
        const lift_scale: f32 = 1.0 / 800.0;
        const lift_noise = (self.mountain_lift_noise.fbm2D(x, z, 4, 2.0, 0.5, lift_scale) + 1.0) * 0.5;
        const mount_lift_raw = m_mask * lift_noise * p.mount_amp;
        const mount_lift = mount_lift_raw / (1.0 + mount_lift_raw / p.mount_cap);
        base_height += mount_lift;
        const ridge_factor = self.getRidgeFactor(x, z, c);
        const ridge_lift = ridge_factor * p.ridge_amp;
        base_height += ridge_lift;
        const mid_noise = self.detail_noise.fbm2D(x + 5000.0, z + 5000.0, 3, 2.0, 0.5, p.mid_freq_hill_scale);
        const land_mult = smoothstep(0.50, 0.65, c);
        base_height += mid_noise * p.mid_freq_hill_amp * land_mult;
        const elev01 = clamp01((base_height - sea) / p.highland_range);
        const detail_atten = 1.0 - smoothstep(0.3, 0.85, elev01);
        const detail = self.detail_noise.fbm2D(x, z, 5, 2.0, 0.5, p.detail_scale) * p.detail_amp;
        base_height += detail * detail_atten;
        const peak_start = sea + p.peak_compression_offset;
        if (base_height > peak_start) {
            const h_above = base_height - peak_start;
            const compressed = p.peak_compression_range * (1.0 - std.math.exp(-h_above / p.peak_compression_range));
            base_height = peak_start + compressed;
        }
        if (m_mask > 0.3 and e < 0.4) {
            const terrace_strength: f32 = 0.2 * (1.0 - e);
            const terraced = @round(base_height / p.terrace_step) * p.terrace_step;
            base_height = std.math.lerp(base_height, terraced, terrace_strength);
        }
        return base_height;
    }

    fn getRiverMask(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        const r = self.river_noise.ridged2D(x, z, 4, 2.0, 0.5, p.river_scale);
        const river_val = 1.0 - r;
        return smoothstep(p.river_min, p.river_max, river_val);
    }

    /// Coastal surface type determined by structural signals (continentalness, slope, erosion)
    /// Replaces the post-process shore_dist search with structure-first approach
    pub const CoastalSurfaceType = enum {
        none, // Not in coastal zone
        sand_beach, // Gentle slope near sea level -> sand
        gravel_beach, // High erosion coastal area -> gravel
        cliff, // Steep slope in coastal zone -> stone
    };

    /// Determine coastal surface type based on structural signals
    /// This is the core of the structure-first beach generation (Issue #95)
    pub fn getCoastalSurfaceType(self: *const TerrainGenerator, continentalness: f32, slope: i32, height: i32, erosion: f32) CoastalSurfaceType {
        const p = self.params;
        const sea_level = p.sea_level;

        // Check if we're in the coastal zone based on continentalness
        const in_coast_zone = continentalness >= p.coast_continentalness_min and
            continentalness <= p.coast_continentalness_max;

        if (!in_coast_zone) {
            return .none;
        }

        // Check height - must be near sea level
        const height_above_sea = height - sea_level;
        if (height_above_sea < 0 or height_above_sea > p.beach_max_height_above_sea) {
            return .none;
        }

        // Steep slopes become cliffs (stone)
        if (slope >= p.cliff_min_slope) {
            return .cliff;
        }

        // High erosion areas become gravel beaches
        if (erosion >= p.gravel_erosion_threshold and slope <= p.beach_max_slope + 1) {
            return .gravel_beach;
        }

        // Gentle slopes become sand beaches
        if (slope <= p.beach_max_slope) {
            return .sand_beach;
        }

        // Moderate slopes in coast zone - no special treatment
        return .none;
    }

    fn getBlockAt(self: *const TerrainGenerator, y: i32, terrain_height: i32, biome: Biome, filler_depth: i32, is_ocean: bool, sea: f32) BlockType {
        _ = self;
        const sea_level: i32 = @intFromFloat(sea);
        if (y == 0) return .bedrock;
        if (y > terrain_height) {
            if (y <= sea_level) return .water;
            return .air;
        }
        if (is_ocean and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            if (depth <= 8) return .sand;
            if (depth <= 20) return .clay;
            return .gravel;
        }
        if (y == terrain_height) {
            if (biome == .snowy_mountains or biome == .snow_tundra) return .snow_block;
            return biome.getSurfaceBlock();
        }
        if (y > terrain_height - filler_depth) return biome.getFillerBlock();
        return .stone;
    }

    fn generateOres(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(self.erosion_noise.seed +% @as(u64, @bitCast(@as(i64, chunk.chunk_x))) *% 59381 +% @as(u64, @bitCast(@as(i64, chunk.chunk_z))) *% 28411);
        const random = prng.random();
        self.placeOreVeins(chunk, .coal_ore, 20, 6, 10, 128, random);
        self.placeOreVeins(chunk, .iron_ore, 10, 4, 5, 64, random);
        self.placeOreVeins(chunk, .gold_ore, 3, 3, 2, 32, random);
        self.placeOreVeins(chunk, .glowstone, 8, 4, 5, 40, random);
    }

    fn placeOreVeins(self: *const TerrainGenerator, chunk: *Chunk, block: BlockType, count: u32, size: u32, min_y: i32, max_y: i32, random: std.Random) void {
        _ = self;
        for (0..count) |_| {
            const cx = random.uintLessThan(u32, CHUNK_SIZE_X);
            const cz = random.uintLessThan(u32, CHUNK_SIZE_Z);
            const range = max_y - min_y;
            if (range <= 0) continue;
            const cy = min_y + @as(i32, @intCast(random.uintLessThan(u32, @intCast(range))));
            const vein_size = random.uintLessThan(u32, size) + 2;
            var i: u32 = 0;
            while (i < vein_size) : (i += 1) {
                const ox = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oy = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const oz = @as(i32, @intCast(random.uintLessThan(u32, 4))) - 2;
                const tx = @as(i32, @intCast(cx)) + ox;
                const ty = cy + oy;
                const tz = @as(i32, @intCast(cz)) + oz;
                if (chunk.getBlockSafe(tx, ty, tz) == .stone) {
                    if (tx >= 0 and tx < CHUNK_SIZE_X and ty >= 0 and ty < CHUNK_SIZE_Y and tz >= 0 and tz < CHUNK_SIZE_Z) chunk.setBlock(@intCast(tx), @intCast(ty), @intCast(tz), block);
                }
            }
        }
    }

    fn generateFeatures(self: *const TerrainGenerator, chunk: *Chunk, biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, secondary_biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, biome_blends: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32) void {
        var prng = std.Random.DefaultPrng.init(self.continentalness_noise.seed ^ @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^ (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32));
        const random = prng.random();
        const p = self.params;
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(chunk.getWorldX() + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(chunk.getWorldZ() + @as(i32, @intCast(local_z)));
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);
                const surface_y = self.findSurface(chunk, local_x, local_z);
                const sea_level_u: u32 = @intCast(p.sea_level);
                const near_sea_level = surface_y <= sea_level_u + 6;
                const coastal_factor = smoothstep(0.45, 0.52, c_val);
                const elevation_factor: f32 = if (near_sea_level and c_val < 0.48) 0.5 else 1.0;
                const tree_suppress_final = coastal_factor * elevation_factor;
                const primary = biome_ids[idx];
                const secondary = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                const prim_def = biome_mod.getBiomeDefinition(primary);
                const sec_def = biome_mod.getBiomeDefinition(secondary);
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const active_def = if (dither < blend) sec_def else prim_def;
                const profile = active_def.vegetation;
                const tree_density = std.math.lerp(prim_def.vegetation.tree_density, sec_def.vegetation.tree_density, blend) * tree_suppress_final;
                const cactus_density = std.math.lerp(prim_def.vegetation.cactus_density, sec_def.vegetation.cactus_density, blend);
                const bamboo_density = std.math.lerp(prim_def.vegetation.bamboo_density, sec_def.vegetation.bamboo_density, blend) * tree_suppress_final;
                const melon_density = std.math.lerp(prim_def.vegetation.melon_density, sec_def.vegetation.melon_density, blend);
                var placed = false;
                const tree_spacing_check = self.checkTreeSpacing(chunk, local_x, local_z);
                if (!placed and tree_density > 0 and tree_spacing_check and random.float(f32) < tree_density) {
                    if (profile.tree_types.len > 0) {
                        const idx_t = random.uintLessThan(usize, profile.tree_types.len);
                        const tree_type = profile.tree_types[idx_t];
                        const y = self.findSurface(chunk, local_x, local_z);
                        if (y > 0) {
                            const surface_block = chunk.getBlock(local_x, @intCast(y), local_z);
                            if (surface_block == .grass or surface_block == .dirt or surface_block == .mud or surface_block == .mycelium) {
                                self.placeTree(chunk, local_x, @intCast(y + 1), local_z, tree_type, random);
                                placed = true;
                            }
                        }
                    }
                }
                if (!placed and bamboo_density > 0 and random.float(f32) < bamboo_density) {
                    const y = self.findSurface(chunk, local_x, local_z);
                    if (y > 0) {
                        const h = 4 + random.uintLessThan(u32, 8);
                        for (0..h) |i| {
                            const ty = y + 1 + @as(u32, @intCast(i));
                            if (ty < CHUNK_SIZE_Y) chunk.setBlock(local_x, ty, local_z, .bamboo);
                        }
                        placed = true;
                    }
                }
                if (!placed and melon_density > 0 and random.float(f32) < melon_density) {
                    const y = self.findSurface(chunk, local_x, local_z);
                    if (y > 0 and y < CHUNK_SIZE_Y - 1) {
                        chunk.setBlock(local_x, y + 1, local_z, .melon);
                        placed = true;
                    }
                }
                if (!placed and cactus_density > 0 and random.float(f32) < cactus_density) {
                    const y = self.findSurface(chunk, local_x, local_z);
                    if (y > 0) {
                        const surface_block = chunk.getBlock(local_x, @intCast(y), local_z);
                        if ((surface_block == .sand or surface_block == .red_sand) and @as(i32, @intCast(y)) >= self.params.sea_level) {
                            self.placeCactus(chunk, local_x, @intCast(y + 1), local_z, random);
                            placed = true;
                        }
                    }
                }
            }
        }
    }

    fn findSurface(self: *const TerrainGenerator, chunk: *const Chunk, x: u32, z: u32) u32 {
        _ = self;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y > 0) : (y -= 1) {
            if (chunk.getBlock(x, @intCast(y), z) != .air) return @intCast(y);
        }
        return 0;
    }

    fn checkTreeSpacing(self: *const TerrainGenerator, chunk: *const Chunk, x: u32, z: u32) bool {
        _ = self;
        const min_spacing: i32 = 2;
        var dz: i32 = -min_spacing;
        while (dz <= min_spacing) : (dz += 1) {
            var dx: i32 = -min_spacing;
            while (dx <= min_spacing) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const nx = @as(i32, @intCast(x)) + dx;
                const nz = @as(i32, @intCast(z)) + dz;
                if (nx >= 0 and nx < CHUNK_SIZE_X and nz >= 0 and nz < CHUNK_SIZE_Z) {
                    const surface_y = chunk.getHighestSolidY(@intCast(nx), @intCast(nz));
                    var check_y: i32 = @as(i32, @intCast(surface_y)) + 1;
                    const max_check_y = check_y + 3;
                    while (check_y <= max_check_y and check_y < CHUNK_SIZE_Y) : (check_y += 1) {
                        const block = chunk.getBlock(@intCast(nx), @intCast(check_y), @intCast(nz));
                        if (block == .wood or block == .mangrove_log or block == .jungle_log or block == .acacia_log) return false;
                    }
                }
            }
        }
        return true;
    }

    fn placeTree(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, tree_type: biome_mod.TreeType, random: std.Random) void {
        const log_type: BlockType = switch (tree_type) {
            .mangrove => .mangrove_log,
            .jungle => .jungle_log,
            .acacia => .acacia_log,
            .birch, .spruce => .wood,
            else => .wood,
        };
        const leaf_type: BlockType = switch (tree_type) {
            .mangrove => .mangrove_leaves,
            .jungle => .jungle_leaves,
            .acacia => .acacia_leaves,
            .birch, .spruce => .leaves,
            else => .leaves,
        };
        switch (tree_type) {
            .huge_red_mushroom => {
                const height = 5 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mushroom_stem);
                }
                self.placeLeafDisk(chunk, x, y + height, z, 2, .red_mushroom_block);
            },
            .huge_brown_mushroom => {
                const height = 5 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mushroom_stem);
                }
                self.placeLeafDisk(chunk, x, y + height, z, 3, .brown_mushroom_block);
            },
            .mangrove => {
                for (0..3) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mangrove_roots);
                }
                const trunk_start = y + 2;
                const height = 4 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (trunk_start + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, trunk_start + @as(u32, @intCast(i)), z, log_type);
                }
                self.placeLeafDisk(chunk, x, trunk_start + height, z, 2, leaf_type);
            },
            .jungle => {
                const height = 10 + random.uintLessThan(u32, 10);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                }
                self.placeLeafDisk(chunk, x, y + height, z, 3, leaf_type);
                self.placeLeafDisk(chunk, x, y + height - 1, z, 2, leaf_type);
            },
            .acacia => {
                const height = 5 + random.uintLessThan(u32, 3);
                var cx = x;
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y and cx < CHUNK_SIZE_X) chunk.setBlock(cx, y + @as(u32, @intCast(i)), z, log_type);
                    if (i > 2 and random.boolean()) cx = cx +% 1;
                }
                self.placeLeafDisk(chunk, cx, y + height, z, 3, leaf_type);
            },
            .spruce => {
                const height = 6 + random.uintLessThan(u32, 4);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                }
                const leaf_base = y + 2;
                const leaf_top = y + height + 1;
                var ly: u32 = leaf_base;
                while (ly <= leaf_top) : (ly += 1) {
                    const dist = leaf_top - ly;
                    const r: i32 = if (dist > 5) 2 else if (dist > 1) 1 else 0;
                    self.placeLeafDisk(chunk, x, ly, z, r, leaf_type);
                }
                if (leaf_top < CHUNK_SIZE_Y) chunk.setBlock(x, leaf_top, z, leaf_type);
            },
            else => {
                const height = 4 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                }
                const leaf_start = y + height - 2;
                const leaf_end = y + height + 1;
                var ly: u32 = leaf_start;
                while (ly <= leaf_end) : (ly += 1) {
                    const r: i32 = if (ly == leaf_end) 1 else 2;
                    self.placeLeafDisk(chunk, x, ly, z, r, leaf_type);
                }
                if (leaf_end < CHUNK_SIZE_Y) chunk.setBlock(x, leaf_end, z, leaf_type);
            },
        }
    }

    fn placeLeafDisk(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, radius: i32, block: BlockType) void {
        _ = self;
        if (radius < 0) return;
        var lz: i32 = -radius;
        while (lz <= radius) : (lz += 1) {
            var lx: i32 = -radius;
            while (lx <= radius) : (lx += 1) {
                if (lx * lx + lz * lz <= radius * radius + 1) {
                    const target_x = @as(i32, @intCast(x)) + lx;
                    const target_z = @as(i32, @intCast(z)) + lz;
                    if (target_x >= 0 and target_x < CHUNK_SIZE_X and target_z >= 0 and target_z < CHUNK_SIZE_Z and y < CHUNK_SIZE_Y) {
                        if (chunk.getBlock(@intCast(target_x), y, @intCast(target_z)) == .air) chunk.setBlock(@intCast(target_x), y, @intCast(target_z), block);
                    }
                }
            }
        }
    }

    fn placeCactus(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, random: std.Random) void {
        _ = self;
        const height = 2 + random.uintLessThan(u32, 3);
        for (0..height) |i| {
            const cy = y + @as(u32, @intCast(i));
            if (cy < CHUNK_SIZE_Y) chunk.setBlock(x, cy, z, .cactus);
        }
    }

    pub fn computeSkylight(self: *const TerrainGenerator, chunk: *Chunk) void {
        _ = self;
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                var sky_light: u4 = MAX_LIGHT;
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(local_x, uy, local_z);
                    chunk.setSkyLight(local_x, uy, local_z, sky_light);
                    if (block.isOpaque()) {
                        sky_light = 0;
                    } else if (block == .water and sky_light > 0) {
                        sky_light -= 1;
                    }
                }
            }
        }
    }

    const LightNode = struct {
        x: u8,
        y: u16,
        z: u8,
        level: u4,
    };

    pub fn computeBlockLight(self: *const TerrainGenerator, chunk: *Chunk) !void {
        var queue = std.ArrayListUnmanaged(LightNode){};
        defer queue.deinit(self.allocator);
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                var local_x: u32 = 0;
                while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                    const block = chunk.getBlock(local_x, y, local_z);
                    const emission = block.getLightEmission();
                    if (emission > 0) {
                        chunk.setBlockLight(local_x, y, local_z, emission);
                        try queue.append(self.allocator, .{ .x = @intCast(local_x), .y = @intCast(y), .z = @intCast(local_z), .level = emission });
                    }
                }
            }
        }
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            if (node.level <= 1) continue;
            const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
            for (neighbors) |offset| {
                const nx = @as(i32, node.x) + offset[0];
                const ny = @as(i32, node.y) + offset[1];
                const nz = @as(i32, node.z) + offset[2];
                if (nx >= 0 and nx < CHUNK_SIZE_X and ny >= 0 and ny < CHUNK_SIZE_Y and nz >= 0 and nz < CHUNK_SIZE_Z) {
                    const ux: u32 = @intCast(nx);
                    const uy: u32 = @intCast(ny);
                    const uz: u32 = @intCast(nz);
                    const block = chunk.getBlock(ux, uy, uz);
                    if (!block.isOpaque()) {
                        const current_level = chunk.getBlockLight(ux, uy, uz);
                        const next_level = node.level - 1;
                        if (next_level > current_level) {
                            chunk.setBlockLight(ux, uy, uz, next_level);
                            try queue.append(self.allocator, .{ .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz), .level = next_level });
                        }
                    }
                }
            }
        }
    }
};
