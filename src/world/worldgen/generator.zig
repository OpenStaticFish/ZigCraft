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
const ConfiguredNoise = noise_mod.ConfiguredNoise;
const NoiseParams = noise_mod.NoiseParams;
const Vec3f = noise_mod.Vec3f;
const CaveSystem = @import("caves.zig").CaveSystem;
const deco_mod = @import("decorations.zig");
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

// ============================================================================
// Luanti V7-Style Noise Parameters (Issue #105)
// These define the multi-layer terrain generation system
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
    warp_scale: f32 = 1.0 / 200.0,
    warp_amplitude: f32 = 30.0,
    continental_scale: f32 = 1.0 / 1500.0,

    // Continental Zones:
    ocean_threshold: f32 = 0.35,
    continental_deep_ocean_max: f32 = 0.20,
    continental_ocean_max: f32 = 0.35,
    continental_coast_max: f32 = 0.42,
    continental_inland_low_max: f32 = 0.60,
    continental_inland_high_max: f32 = 0.75,

    erosion_scale: f32 = 1.0 / 400.0,
    peaks_scale: f32 = 1.0 / 300.0,
    temperature_macro_scale: f32 = 1.0 / 2000.0,
    temperature_local_scale: f32 = 1.0 / 200.0,
    humidity_macro_scale: f32 = 1.0 / 2000.0,
    humidity_local_scale: f32 = 1.0 / 200.0,
    climate_macro_weight: f32 = 0.75,
    temp_lapse: f32 = 0.25,
    sea_level: i32 = 64,

    // Mountains
    mount_amp: f32 = 60.0,
    mount_cap: f32 = 120.0,
    detail_scale: f32 = 1.0 / 32.0, // SMALL - every ~32 blocks
    detail_amp: f32 = 6.0,
    highland_range: f32 = 80.0,
    coast_jitter_scale: f32 = 1.0 / 150.0,
    seabed_scale: f32 = 1.0 / 100.0,
    seabed_amp: f32 = 2.0,
    river_scale: f32 = 1.0 / 800.0,
    river_min: f32 = 0.90,
    river_max: f32 = 0.95,
    river_depth_max: f32 = 6.0,

    // Beach - very narrow
    coast_continentalness_min: f32 = 0.35,
    coast_continentalness_max: f32 = 0.40,
    beach_max_height_above_sea: i32 = 3,
    beach_max_slope: i32 = 2,
    cliff_min_slope: i32 = 5,
    gravel_erosion_threshold: f32 = 0.7,
    coastal_no_tree_min: i32 = 8,
    coastal_no_tree_max: i32 = 18,

    // Mountains
    mount_inland_min: f32 = 0.60,
    mount_inland_max: f32 = 0.80,
    mount_peak_min: f32 = 0.55,
    mount_peak_max: f32 = 0.85,
    mount_rugged_min: f32 = 0.35,
    mount_rugged_max: f32 = 0.75,

    mid_freq_hill_scale: f32 = 1.0 / 64.0, // SMALL - hills every ~64 blocks
    mid_freq_hill_amp: f32 = 12.0,
    peak_compression_offset: f32 = 80.0,
    peak_compression_range: f32 = 80.0,
    terrace_step: f32 = 4.0,
    ridge_scale: f32 = 1.0 / 400.0,
    ridge_amp: f32 = 25.0,
    ridge_inland_min: f32 = 0.50,
    ridge_inland_max: f32 = 0.70,
    ridge_sparsity: f32 = 0.50,
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

    // V7-style multi-layer terrain noises (Issue #105)
    terrain_base: ConfiguredNoise,
    terrain_alt: ConfiguredNoise,
    height_select: ConfiguredNoise,
    terrain_persist: ConfiguredNoise,

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

            // V7-style terrain layers - spread values based on Luanti defaults
            // terrain_base: Base terrain shape, rolling hills character
            // spread=300 for features every ~300 blocks (was 600 in Luanti, smaller for Minecraft feel)
            .terrain_base = ConfiguredNoise.init(makeNoiseParams(seed, 1001, 300, 35, 4, 5, 0.6)),

            // terrain_alt: Alternate terrain shape, flatter character
            // Blended with terrain_base using height_select
            .terrain_alt = ConfiguredNoise.init(makeNoiseParams(seed, 1002, 300, 20, 4, 5, 0.6)),

            // height_select: Blend factor between base and alt terrain
            // Controls where terrain has base vs alt character
            .height_select = ConfiguredNoise.init(makeNoiseParams(seed, 1003, 250, 16, -8, 6, 0.6)),

            // terrain_persist: Detail variation multiplier
            // Modulates how much fine detail appears in different areas
            .terrain_persist = ConfiguredNoise.init(makeNoiseParams(seed, 1004, 1000, 0.15, 0.6, 3, 0.6)),
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
        const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 2, 2.0, 0.5, p.coast_jitter_scale) * 0.03;
        const c_jittered = clamp01(c + coast_jitter);
        const river_mask = self.getRiverMask(xw, zw);
        // computeHeight now handles ocean vs land decision internally
        const terrain_height = self.computeHeight(c_jittered, e, pv, xw, zw, river_mask);
        const ridge_mask = self.getRidgeFactor(xw, zw, c_jittered);
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
        var is_underwater_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool = undefined; // Any water (ocean or lake)
        var is_ocean_water_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool = undefined; // True ocean (c < threshold)
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
                const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 2, 2.0, 0.5, p.coast_jitter_scale) * 0.03;
                const c_jittered = clamp01(c + coast_jitter);
                erosion_values[idx] = e_val;
                const river_mask = self.getRiverMask(xw, zw);
                // computeHeight now handles ocean vs land decision internally
                const terrain_height = self.computeHeight(c_jittered, e_val, pv, xw, zw, river_mask);
                const ridge_mask = self.getRidgeFactor(xw, zw, c_jittered);
                const terrain_height_i: i32 = @intFromFloat(terrain_height);
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
                const is_underwater = terrain_height < sea;
                const is_ocean_water = c_jittered < p.ocean_threshold;
                surface_heights[idx] = terrain_height_i;
                is_underwater_flags[idx] = is_underwater;
                is_ocean_water_flags[idx] = is_ocean_water;
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

        // === Phase B: Base Biome Selection ===
        // First pass: compute base biomes for all columns
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
            }
        }

        // === Phase B2: Edge Detection and Transition Biome Injection (Issue #102) ===
        // Use coarse grid sampling to detect biome boundaries and inject transition biomes
        const EDGE_GRID_SIZE = CHUNK_SIZE_X / biome_mod.EDGE_STEP; // 4 cells for 16-block chunk

        // For each coarse grid cell, detect if we're near a biome edge
        var gz: u32 = 0;
        while (gz < EDGE_GRID_SIZE) : (gz += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var gx: u32 = 0;
            while (gx < EDGE_GRID_SIZE) : (gx += 1) {
                // Sample at the center of each grid cell
                const sample_x = gx * biome_mod.EDGE_STEP + biome_mod.EDGE_STEP / 2;
                const sample_z = gz * biome_mod.EDGE_STEP + biome_mod.EDGE_STEP / 2;
                const sample_idx = sample_x + sample_z * CHUNK_SIZE_X;
                const base_biome = biome_ids[sample_idx];

                // Detect edge using world coordinates (allows sampling outside chunk)
                const sample_wx = world_x + @as(i32, @intCast(sample_x));
                const sample_wz = world_z + @as(i32, @intCast(sample_z));
                const edge_info = self.detectBiomeEdge(sample_wx, sample_wz, base_biome);

                // If edge detected, apply transition biome to this grid cell
                if (edge_info.edge_band != .none) {
                    if (edge_info.neighbor_biome) |neighbor| {
                        if (biome_mod.getTransitionBiome(base_biome, neighbor)) |transition_biome| {
                            // Apply transition biome to all blocks in this grid cell
                            var cell_z: u32 = 0;
                            while (cell_z < biome_mod.EDGE_STEP) : (cell_z += 1) {
                                var cell_x: u32 = 0;
                                while (cell_x < biome_mod.EDGE_STEP) : (cell_x += 1) {
                                    const lx = gx * biome_mod.EDGE_STEP + cell_x;
                                    const lz = gz * biome_mod.EDGE_STEP + cell_z;
                                    if (lx < CHUNK_SIZE_X and lz < CHUNK_SIZE_Z) {
                                        const cell_idx = lx + lz * CHUNK_SIZE_X;
                                        // Store transition as primary, original as secondary for blending
                                        secondary_biome_ids[cell_idx] = biome_ids[cell_idx];
                                        biome_ids[cell_idx] = transition_biome;
                                        // Set blend factor based on edge band (inner = more blend)
                                        biome_blends[cell_idx] = switch (edge_info.edge_band) {
                                            .inner => 0.3, // Closer to boundary: more original showing through
                                            .middle => 0.2,
                                            .outer => 0.1,
                                            .none => 0.0,
                                        };
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // === Phase B3: Finalize biome data ===
        // Set biomes on chunk and compute filler depths
        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const biome_id = biome_ids[idx];
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
            self.generateWithoutWormCavesInternal(chunk, &surface_heights, &biome_ids, &secondary_biome_ids, &biome_blends, &filler_depths, &is_underwater_flags, &is_ocean_water_flags, &cave_region_values, &coastal_types, &slopes, &exposure_values, sea);
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
                const is_underwater = is_underwater_flags[idx];
                const is_ocean_water = is_ocean_water_flags[idx];
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

                // Populate chunk heightmap and biomes (Issue #107)
                chunk.setSurfaceHeight(local_x, local_z, @intCast(terrain_height_i));
                chunk.biomes[idx] = active_biome_id;

                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean_water, is_underwater, sea);
                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    // Apply structural coastal surface types (ocean beaches only)
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
                        // Use updated multi-algorithm cave system (Issue #108)
                        const should_carve_cavity = self.cave_system.shouldCarve(wx, wy, wz, terrain_height_i, cave_region);
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
        self.generateFeatures(chunk);
        if (stop_flag) |sf| if (sf.*) return;
        self.computeSkylight(chunk);
        if (stop_flag) |sf| if (sf.*) return;
        self.computeBlockLight(chunk) catch |err| {
            std.debug.print("Failed to compute block light: {}\n", .{err});
        };
        chunk.dirty = true;
        self.printDebugStats(world_x, world_z, &debug_temperatures, &debug_humidities, &debug_continentalness, &biome_ids, debug_beach_count);
    }

    fn generateWithoutWormCavesInternal(self: *const TerrainGenerator, chunk: *Chunk, surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, secondary_biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, biome_blends: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, filler_depths: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, is_underwater_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool, is_ocean_water_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool, cave_region_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, coastal_types: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType, slopes: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32, exposure_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, sea: f32) void {
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
                const is_underwater = is_underwater_flags[idx];
                const is_ocean_water = is_ocean_water_flags[idx];
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

                // Populate chunk heightmap and biomes (Issue #107)
                chunk.setSurfaceHeight(local_x, local_z, @intCast(terrain_height_i));
                chunk.biomes[idx] = active_biome_id;

                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean_water, is_underwater, sea);
                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    // Apply structural coastal surface types (ocean beaches only)
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
                        if (self.cave_system.shouldCarve(wx, wy, wz, terrain_height_i, cave_region)) {
                            block = if (y < p.sea_level) .water else .air;
                        }
                    }
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }
        chunk.generated = true;
        self.generateOres(chunk);
        self.generateFeatures(chunk);
        self.computeSkylight(chunk);
        self.computeBlockLight(chunk) catch {};
        chunk.dirty = true;
    }

    fn printDebugStats(self: *const TerrainGenerator, world_x: i32, world_z: i32, t_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, h_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, c_vals: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32, b_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId, beach_count: u32) void {
        // Debug output disabled by default. Set to true to enable debugging.
        const debug_enabled = false;
        if (!debug_enabled) return;

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
    /// Updated to match STRUCTURE-FIRST thresholds
    pub fn getContinentalZone(self: *const TerrainGenerator, c: f32) ContinentalZone {
        const p = self.params;
        if (c < p.continental_deep_ocean_max) { // 0.20
            return .deep_ocean;
        } else if (c < p.ocean_threshold) { // 0.30 - HARD ocean cutoff
            return .ocean;
        } else if (c < p.continental_coast_max) { // 0.55
            return .coast;
        } else if (c < p.continental_inland_low_max) { // 0.75
            return .inland_low;
        } else if (c < p.continental_inland_high_max) { // 0.90
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

    /// Base height from continentalness - only called for LAND (c >= ocean_threshold)
    fn getBaseHeight(self: *const TerrainGenerator, c: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // Coastal zone: 0.35 to 0.42 - rises from sea level
        if (c < p.continental_coast_max) {
            const range = p.continental_coast_max - p.ocean_threshold;
            const t = (c - p.ocean_threshold) / range;
            return sea + t * 8.0; // 0 to +8 blocks
        }

        // Inland Low: 0.42 to 0.60 - plains/forests
        if (c < p.continental_inland_low_max) {
            const range = p.continental_inland_low_max - p.continental_coast_max;
            const t = (c - p.continental_coast_max) / range;
            return sea + 8.0 + t * 12.0; // +8 to +20
        }

        // Inland High: 0.60 to 0.75 - hills
        if (c < p.continental_inland_high_max) {
            const range = p.continental_inland_high_max - p.continental_inland_low_max;
            const t = (c - p.continental_inland_low_max) / range;
            return sea + 20.0 + t * 15.0; // +20 to +35
        }

        // Mountain Core: > 0.75
        const t = smoothstep(p.continental_inland_high_max, 1.0, c);
        return sea + 35.0 + t * 25.0; // +35 to +60
    }

    /// STRUCTURE-FIRST height computation with V7-style multi-layer terrain.
    /// The KEY change: Ocean is decided by continentalness ALONE.
    /// Land uses blended terrain layers for varied terrain character.
    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32, x: f32, z: f32, river_mask: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // ============================================================
        // STEP 1: HARD OCEAN DECISION
        // If continentalness < ocean_threshold, this is OCEAN.
        // Return ocean depth and STOP. No land logic runs here.
        // ============================================================
        if (c < p.ocean_threshold) {
            // Ocean depth varies smoothly with continentalness
            // c=0.0 -> deepest (-50 from sea)
            // c=ocean_threshold -> shallow (-15 from sea)
            const ocean_depth_factor = c / p.ocean_threshold; // 0..1 within ocean
            const deep_ocean_depth = sea - 55.0;
            const shallow_ocean_depth = sea - 12.0;

            // Very minimal seabed variation - oceans should be BORING
            const seabed_detail = self.seabed_noise.fbm2D(x, z, 2, 2.0, 0.5, p.seabed_scale) * p.seabed_amp;

            return std.math.lerp(deep_ocean_depth, shallow_ocean_depth, ocean_depth_factor) + seabed_detail;
        }

        // ============================================================
        // STEP 2: V7-STYLE MULTI-LAYER TERRAIN (Issue #105)
        // Blend terrain_base and terrain_alt using height_select
        // This creates varied terrain where different areas have
        // noticeably different character (rolling vs flat vs hilly)
        // ============================================================
        const base_height = self.terrain_base.get2D(x, z);
        const alt_height = self.terrain_alt.get2D(x, z);
        const select = self.height_select.get2D(x, z);
        const persist = self.terrain_persist.get2D(x, z);

        // Apply persistence variation to both heights
        const base_modulated = base_height * persist;
        const alt_modulated = alt_height * persist;

        // Blend between base and alt using height_select
        // select near 0 = more base terrain (rolling hills)
        // select near 1 = more alt terrain (flatter)
        const blend = clamp01((select + 8.0) / 16.0);
        const v7_terrain = std.math.lerp(base_modulated, alt_modulated, blend);

        // ============================================================
        // STEP 3: LAND - Combine V7 terrain with continental base
        // Only reaches here if c >= ocean_threshold
        // ============================================================
        var height = self.getBaseHeight(c) + v7_terrain;

        // ============================================================
        // STEP 4: Mountains & Ridges - AGGRESSIVELY GATED
        // Only apply in inland zones (c > coast_max)
        // Mountains require: deep inland + high peak noise
        // ============================================================
        const land_factor = smoothstep(p.continental_coast_max, p.continental_inland_low_max, c);

        // Mountains only in continental cores
        if (c > p.continental_inland_low_max) {
            const m_mask = self.getMountainMask(pv, e, c);
            const lift_scale: f32 = 1.0 / 1000.0;
            const lift_noise = (self.mountain_lift_noise.fbm2D(x, z, 3, 2.0, 0.5, lift_scale) + 1.0) * 0.5;
            const mount_lift = (m_mask * lift_noise * p.mount_amp) / (1.0 + (m_mask * lift_noise * p.mount_amp) / p.mount_cap);
            height += mount_lift;

            const ridge_val = self.getRidgeFactor(x, z, c);
            height += ridge_val * p.ridge_amp;
        }

        // ============================================================
        // STEP 5: Fine Detail - Small-scale variation
        // Attenuated by erosion and in high elevations
        // ============================================================
        const erosion_smooth = smoothstep(0.5, 0.75, e);
        const hills_atten = (1.0 - erosion_smooth) * land_factor;

        // Small-scale detail (every ~32 blocks)
        const elev01 = clamp01((height - sea) / p.highland_range);
        const detail_atten = 1.0 - smoothstep(0.3, 0.85, elev01);
        const detail = self.detail_noise.fbm2D(x, z, 3, 2.0, 0.5, p.detail_scale) * p.detail_amp;
        height += detail * detail_atten * hills_atten;

        // ============================================================
        // STEP 6: Post-Processing - Peak compression
        // ============================================================
        const peak_start = sea + p.peak_compression_offset;
        if (height > peak_start) {
            const h_above = height - peak_start;
            const compressed = p.peak_compression_range * (1.0 - std.math.exp(-h_above / p.peak_compression_range));
            height = peak_start + compressed;
        }

        // ============================================================
        // STEP 7: River Carving - only on land
        // ============================================================
        if (river_mask > 0.001 and c > p.continental_coast_max) {
            const river_bed = sea - 4.0;
            const carve_alpha = smoothstep(0.0, 1.0, river_mask);
            if (height > river_bed) {
                height = std.math.lerp(height, river_bed, carve_alpha);
            }
        }

        return height;
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
        none, // Not in coastal zone OR near inland water (use biome default)
        sand_beach, // Gentle slope near sea level, adjacent to OCEAN -> sand
        gravel_beach, // High erosion coastal area adjacent to OCEAN -> gravel
        cliff, // Steep slope in coastal zone -> stone
    };

    /// Determine coastal surface type based on structural signals
    ///
    /// KEY FIX (Issue #92): Beach requires adjacency to OCEAN water, not just any water.
    /// - Ocean water: continentalness < ocean_threshold (0.30)
    /// - Inland water (lakes/rivers): continentalness >= ocean_threshold but below sea level
    ///
    /// Beach forms ONLY when:
    /// 1. This block is LAND (above sea level)
    /// 2. This block is near OCEAN (continentalness indicates ocean proximity)
    /// 3. Height is within beach_max_height_above_sea of sea level
    /// 4. Slope is gentle
    ///
    /// Inland water (lakes/rivers) get grass/dirt banks, NOT sand.
    pub fn getCoastalSurfaceType(self: *const TerrainGenerator, continentalness: f32, slope: i32, height: i32, erosion: f32) CoastalSurfaceType {
        const p = self.params;
        const sea_level = p.sea_level;

        // CONSTRAINT 1: Height above sea level
        // Beaches only exist in a tight band around sea level
        const height_above_sea = height - sea_level;

        // If underwater or more than 3 blocks above sea, never a beach
        if (height_above_sea < -1 or height_above_sea > p.beach_max_height_above_sea) {
            return .none;
        }

        // CONSTRAINT 2: Must be adjacent to OCEAN
        // Beach only in a VERY narrow band just above ocean threshold
        const beach_band = 0.05; // Only 0.05 continentalness = ~100 blocks at this scale
        const near_ocean = continentalness >= p.ocean_threshold and
            continentalness < (p.ocean_threshold + beach_band);

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

    /// Check if a position is ocean water (used for beach adjacency checks)
    /// Ocean = continentalness < ocean_threshold (structure-first definition)
    pub fn isOceanWater(self: *const TerrainGenerator, wx: f32, wz: f32) bool {
        const p = self.params;
        const warp = self.computeWarp(wx, wz);
        const xw = wx + warp.x;
        const zw = wz + warp.z;
        const c = self.getContinentalness(xw, zw);

        // Ocean is defined by continentalness alone in structure-first approach
        return c < p.ocean_threshold;
    }

    /// Check if a position is inland water (lake/river)
    /// Inland water = underwater BUT continentalness >= ocean_threshold
    pub fn isInlandWater(self: *const TerrainGenerator, wx: f32, wz: f32, height: i32) bool {
        const p = self.params;
        const warp = self.computeWarp(wx, wz);
        const xw = wx + warp.x;
        const zw = wz + warp.z;
        const c = self.getContinentalness(xw, zw);

        // Inland water: below sea level but in a land zone
        return height < p.sea_level and c >= p.ocean_threshold;
    }

    /// Get block type at a specific Y coordinate
    ///
    /// KEY FIX: Distinguish between ocean floor and inland water floor:
    /// - Ocean floor: sand in shallow water, gravel/clay in deep water
    /// - Inland water floor (lakes/rivers): dirt/gravel, NOT sand (no lake beaches)
    fn getBlockAt(self: *const TerrainGenerator, y: i32, terrain_height: i32, biome: Biome, filler_depth: i32, is_ocean_water: bool, is_underwater: bool, sea: f32) BlockType {
        _ = self;
        const sea_level: i32 = @intFromFloat(sea);
        if (y == 0) return .bedrock;
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

    pub fn generateFeatures(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(self.continentalness_noise.seed ^ @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^ (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32));
        const random = prng.random();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const surface_y = chunk.getSurfaceHeight(local_x, local_z);
                if (surface_y <= 0 or surface_y >= CHUNK_SIZE_Y - 1) continue;

                // Use the biome stored in the chunk (populated during terrain gen)
                const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];

                // Get surface block to check if we can place on it
                const surface_block = chunk.getBlock(local_x, @intCast(surface_y), local_z);

                // Try decorations
                for (deco_mod.DECORATIONS) |deco| {
                    switch (deco) {
                        .simple => |s| {
                            if (!self.isBiomeAllowed(s.biomes, biome)) continue;
                            if (!self.isBlockAllowed(s.place_on, surface_block)) continue;
                            if (random.float(f32) >= s.probability) continue;

                            // Place simple decoration
                            chunk.setBlock(local_x, @intCast(surface_y + 1), local_z, s.block);
                            break; // Only one decoration per column
                        },
                        .schematic => |s| {
                            if (!self.isBiomeAllowed(s.biomes, biome)) continue;
                            if (!self.isBlockAllowed(s.place_on, surface_block)) continue;
                            if (random.float(f32) >= s.probability) continue;

                            // Place schematic
                            self.placeSchematic(chunk, local_x, @intCast(surface_y + 1), local_z, s.schematic, random);
                            break;
                        },
                    }
                }
            }
        }
    }

    fn isBiomeAllowed(self: *const TerrainGenerator, allowed: []const BiomeId, current: BiomeId) bool {
        _ = self;
        if (allowed.len == 0) return true;
        for (allowed) |b| {
            if (b == current) return true;
        }
        return false;
    }

    fn isBlockAllowed(self: *const TerrainGenerator, allowed: []const BlockType, current: BlockType) bool {
        _ = self;
        for (allowed) |b| {
            if (b == current) return true;
        }
        return false;
    }

    fn placeSchematic(self: *const TerrainGenerator, chunk: *Chunk, x: u32, y: u32, z: u32, schematic: deco_mod.Schematic, random: std.Random) void {
        _ = self;
        _ = random;
        const center_x = @as(i32, @intCast(x));
        const center_y = @as(i32, @intCast(y));
        const center_z = @as(i32, @intCast(z));

        for (schematic.blocks) |sb| {
            const bx = center_x + sb.offset[0] - schematic.center_x;
            const by = center_y + sb.offset[1];
            const bz = center_z + sb.offset[2] - schematic.center_z;

            if (bx >= 0 and bx < CHUNK_SIZE_X and bz >= 0 and bz < CHUNK_SIZE_Z and by >= 0 and by < CHUNK_SIZE_Y) {
                // Don't overwrite existing solid blocks to avoid trees deleting ground
                const existing = chunk.getBlock(@intCast(bx), @intCast(by), @intCast(bz));
                if (existing == .air or existing.isTransparent()) {
                    chunk.setBlock(@intCast(bx), @intCast(by), @intCast(bz), sb.block);
                }
            }
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

    // =========================================================================
    // Biome Edge Detection (Issue #102)
    // =========================================================================

    /// Sample biome at arbitrary world coordinates (deterministic, no chunk dependency)
    /// This is a lightweight version of getColumnInfo for edge detection sampling
    pub fn sampleBiomeAtWorld(self: *const TerrainGenerator, wx: i32, wz: i32) BiomeId {
        const p = self.params;
        const wxf: f32 = @floatFromInt(wx);
        const wzf: f32 = @floatFromInt(wz);

        // Compute warped coordinates
        const warp = self.computeWarp(wxf, wzf);
        const xw = wxf + warp.x;
        const zw = wzf + warp.z;

        // Get structural parameters
        const c = self.getContinentalness(xw, zw);
        const e = self.getErosion(xw, zw);
        const pv = self.getPeaksValleys(xw, zw);
        const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 2, 2.0, 0.5, p.coast_jitter_scale) * 0.03;
        const c_jittered = clamp01(c + coast_jitter);
        const river_mask = self.getRiverMask(xw, zw);

        // Compute height for climate calculation
        const terrain_height = self.computeHeight(c_jittered, e, pv, xw, zw, river_mask);
        const terrain_height_i: i32 = @intFromFloat(terrain_height);
        const sea: f32 = @floatFromInt(p.sea_level);

        // Get climate parameters
        const altitude_offset: f32 = @max(0, terrain_height - sea);
        var temperature = self.getTemperature(xw, zw);
        temperature = clamp01(temperature - (altitude_offset / 512.0) * p.temp_lapse);
        const humidity = self.getHumidity(xw, zw);

        // Build climate params
        const climate = biome_mod.computeClimateParams(
            temperature,
            humidity,
            terrain_height_i,
            c_jittered,
            e,
            p.sea_level,
            CHUNK_SIZE_Y,
        );

        // Structural params (simplified - no slope calculation for sampling)
        const ridge_mask = self.getRidgeFactor(xw, zw, c_jittered);
        const structural = biome_mod.StructuralParams{
            .height = terrain_height_i,
            .slope = 1, // Assume low slope for sampling
            .continentalness = c_jittered,
            .ridge_mask = ridge_mask,
        };

        return biome_mod.selectBiomeWithConstraintsAndRiver(climate, structural, river_mask);
    }

    /// Detect if a position is near a biome boundary that needs a transition zone
    /// Returns edge info including the neighboring biome and proximity band
    pub fn detectBiomeEdge(
        self: *const TerrainGenerator,
        wx: i32,
        wz: i32,
        center_biome: BiomeId,
    ) biome_mod.BiomeEdgeInfo {
        var detected_neighbor: ?BiomeId = null;
        var closest_band: biome_mod.EdgeBand = .none;

        // Check at each radius (4, 8, 12 blocks) - from closest to farthest
        for (biome_mod.EDGE_CHECK_RADII, 0..) |radius, band_idx| {
            const r: i32 = @intCast(radius);
            const offsets = [_][2]i32{
                .{ r, 0 }, // East
                .{ -r, 0 }, // West
                .{ 0, r }, // South
                .{ 0, -r }, // North
            };

            for (offsets) |off| {
                const neighbor_biome = self.sampleBiomeAtWorld(wx + off[0], wz + off[1]);

                // Check if this neighbor differs and needs a transition
                if (neighbor_biome != center_biome and biome_mod.needsTransition(center_biome, neighbor_biome)) {
                    detected_neighbor = neighbor_biome;
                    // Band index: 0=4 blocks (inner), 1=8 blocks (middle), 2=12 blocks (outer)
                    // EdgeBand: inner=3, middle=2, outer=1
                    closest_band = @enumFromInt(3 - @as(u2, @intCast(band_idx)));
                    break;
                }
            }

            // If we found an edge at this radius, stop checking farther radii
            if (detected_neighbor != null) break;
        }

        return .{
            .base_biome = center_biome,
            .neighbor_biome = detected_neighbor,
            .edge_band = closest_band,
        };
    }
};
