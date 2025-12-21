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

/// Terrain generation parameters
/// Per worldgen-revamp.md: Separate layers for terrain, climate, surface rules, features
const Params = struct {
    // Section 4.1: Domain Warping
    warp_scale: f32 = 1.0 / 1100.0,
    warp_amplitude: f32 = 50.0,

    // Section 4.2: Continentalness (large scale landmass)
    continental_scale: f32 = 1.0 / 800.0, // Smaller landmasses/oceans to prevent infinite ones
    deep_ocean_threshold: f32 = 0.35, // Per spec: C < 0.35 => deep ocean
    shallow_ocean_threshold: f32 = 0.45, // Per spec: 0.35-0.45 => shallow ocean
    coast_threshold: f32 = 0.50, // Per spec: 0.45-0.55 => coast band

    // Section 4.3: Erosion (sharp vs smooth terrain)
    erosion_scale: f32 = 1.0 / 600.0,

    // Section 4.4: Peaks/Valleys (mountain rhythm)
    peaks_scale: f32 = 1.0 / 900.0,

    // Section 4.5: Climate - 2-layer system (macro + local)
    // Macro: large regional patterns, Local: adds variety within regions
    temperature_macro_scale: f32 = 1.0 / 600.0, // Limits biome max size (~40 chunks)
    temperature_local_scale: f32 = 1.0 / 120.0,
    humidity_macro_scale: f32 = 1.0 / 500.0,
    humidity_local_scale: f32 = 1.0 / 100.0,
    climate_macro_weight: f32 = 0.60, // 60% macro, 40% local for significant breakup
    temp_lapse: f32 = 0.25, // Temperature reduction per altitude

    // Section 5: Height function per worldgen-revamp.md
    sea_level: i32 = 64,
    mount_amp: f32 = 90.0,
    mount_cap: f32 = 200.0, // Per spec: soft cap prevents runaway cliffs
    detail_scale: f32 = 1.0 / 150.0,
    detail_amp: f32 = 12.0,
    highland_range: f32 = 100.0, // For elevation-dependent detail attenuation

    // Section 6: Ocean shaping
    coast_jitter_scale: f32 = 1.0 / 650.0,
    seabed_scale: f32 = 1.0 / 280.0,
    seabed_amp: f32 = 6.0,

    // Section 7: Rivers
    river_scale: f32 = 1.0 / 1200.0,
    river_min: f32 = 0.74,
    river_max: f32 = 0.84,
    river_depth_max: f32 = 12.0,

    // Per worldgen-revamp.md Section 5.1: Beach constraints
    // Typical beach width: 2-5 blocks, wide beaches 6-10 only in exposed zones
    beach_min_width: i32 = 2,
    beach_max_width: i32 = 5,
    beach_max_height_above_sea: i32 = 4, // 0-4 blocks above sea
    beach_max_slope: i32 = 2, // Gentle slope only

    // Per worldgen-revamp.md Section 5.3: Coastal no-tree band
    // Trees begin 8-20 blocks inland (biome dependent)
    coastal_no_tree_min: i32 = 8,
    coastal_no_tree_max: i32 = 18,

    // Section 3.4: Slope limiter for terrain relaxation
    // DISABLED - was causing heavy terracing artifacts
    max_slope_delta: i32 = 6, // Max height difference between neighbors
    relaxation_passes: u32 = 0, // Disabled - natural terrain variation preferred
};

pub const TerrainGenerator = struct {
    // Noise generators for different layers
    // Domain warp (2 noise fields for x/z offset)
    warp_noise_x: Noise,
    warp_noise_z: Noise,

    // Core 2D fields
    continentalness_noise: Noise,
    erosion_noise: Noise,
    peaks_noise: Noise,
    temperature_noise: Noise,
    humidity_noise: Noise,

    // 2-layer climate: local variation layer (higher frequency)
    temperature_local_noise: Noise,
    humidity_local_noise: Noise,

    // Detail and feature noise
    detail_noise: Noise,
    coast_jitter_noise: Noise,
    seabed_noise: Noise,
    river_noise: Noise,

    // Coastal exposure noise for variable beach width (per coastlines.md)
    beach_exposure_noise: Noise,

    // Cave system (worm caves + noise cavities)
    cave_system: CaveSystem,

    // Filler depth variation
    filler_depth_noise: Noise,

    // Per worldgen-revamp.md: separate noise for mountain lift
    mountain_lift_noise: Noise,

    params: Params,
    allocator: std.mem.Allocator,

    pub fn init(seed: u64, allocator: std.mem.Allocator) TerrainGenerator {
        // Derive seeds for different layers to ensure they are independent
        // Per worldgen-revamp.md Section 9: separate scales for C/P/E/T/H/exposure
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
        if (river_mask > 0 and terrain_height > sea - 5) {
            const river_depth = river_mask * p.river_depth_max;
            terrain_height = @min(terrain_height, terrain_height - river_depth);
        }

        if (terrain_height < sea) {
            const deep_factor = 1.0 - smoothstep(p.deep_ocean_threshold, 0.5, c_jittered);
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

        const climate = biome_mod.computeClimateParams(
            temperature,
            humidity,
            terrain_height_i,
            c_jittered,
            e,
            p.sea_level,
            CHUNK_SIZE_Y,
        );

        const selection = biome_mod.selectBiomeWithRiverBlended(climate, river_mask);

        return .{
            .height = terrain_height_i,
            .biome = selection.primary,
            .is_ocean = is_ocean,
            .temperature = temperature,
            .humidity = humidity,
            .continentalness = c_jittered,
        };
    }

    /// Generate terrain for a chunk
    pub fn generate(self: *const TerrainGenerator, chunk: *Chunk) void {
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // First pass: compute surface heights and basic terrain
        var surface_heights: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId = undefined;
        var secondary_biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId = undefined;
        var biome_blends: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var filler_depths: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var is_ocean_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool = undefined;
        var cave_region_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;

        // DEBUG: Collect T/H/C values for stats
        var debug_temperatures: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var debug_humidities: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        var debug_continentalness: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // === Section 4.1: Domain Warping ===
                const warp = self.computeWarp(wx, wz);
                const xw = wx + warp.x;
                const zw = wz + warp.z;

                // === Section 4.2-4.5: Sample core 2D fields ===
                const c = self.getContinentalness(xw, zw);
                const e = self.getErosion(xw, zw);
                const pv = self.getPeaksValleys(xw, zw);

                // === Section 6.1: Coastline jitter ===
                const coast_jitter = self.coast_jitter_noise.fbm2D(xw, zw, 3, 2.0, 0.5, p.coast_jitter_scale) * 0.05;
                const c_jittered = clamp01(c + coast_jitter);

                // === Section 5: Height function ===
                var terrain_height = self.computeHeight(c_jittered, e, pv, xw, zw);

                // === Section 7: River carving ===
                const river_mask = self.getRiverMask(xw, zw);
                if (river_mask > 0 and terrain_height > sea - 5) {
                    const river_depth = river_mask * p.river_depth_max;
                    terrain_height = @min(terrain_height, terrain_height - river_depth);
                }

                // === Section 6.2: Seabed variation for ocean columns ===
                if (terrain_height < sea) {
                    const deep_factor = 1.0 - smoothstep(p.deep_ocean_threshold, 0.5, c_jittered);
                    const seabed_detail = self.seabed_noise.fbm2D(xw, zw, 5, 2.0, 0.5, p.seabed_scale) * p.seabed_amp;
                    const base_seabed = sea - 18.0 - deep_factor * 35.0;
                    terrain_height = @min(terrain_height, base_seabed + seabed_detail);
                }

                // Temp height for biome selection
                var terrain_height_i: i32 = @intFromFloat(terrain_height);

                // === Section 4.5: Climate with altitude adjustment ===
                const altitude_offset: f32 = @max(0, terrain_height - sea);
                var temperature = self.getTemperature(xw, zw);
                temperature = clamp01(temperature - (altitude_offset / 512.0) * p.temp_lapse);
                const humidity = self.getHumidity(xw, zw);

                // DEBUG: Store T/H/C for stats
                debug_temperatures[idx] = temperature;
                debug_humidities[idx] = humidity;
                debug_continentalness[idx] = c_jittered;

                // === Section 8: Biome selection using data-driven system ===
                // (river_mask already computed in Section 7)

                // Compute climate parameters for biome selection
                const climate = biome_mod.computeClimateParams(
                    temperature,
                    humidity,
                    terrain_height_i,
                    c_jittered,
                    e,
                    p.sea_level,
                    CHUNK_SIZE_Y,
                );

                // Select blended biomes
                const selection = biome_mod.selectBiomeWithRiverBlended(climate, river_mask);
                const primary_def = biome_mod.getBiomeDefinition(selection.primary);

                const secondary_def = biome_mod.getBiomeDefinition(selection.secondary);
                _ = secondary_def; // Unused after disabling biome terrain modifiers
                const t = selection.blend_factor;

                // === Biome Terrain Modifiers DISABLED ===
                // Per worldgen-luanti-style.md: "Height is Phase A only. Biome terrain
                // modifiers (if any) are tiny and blended, never hard-switched."
                // These modifiers were causing height discontinuities at biome boundaries,
                // creating the "walls" and terracing artifacts. Height is now computed
                // purely from continentalness/erosion/peaks in computeHeight().
                //
                // Previously this section applied:
                // - smooth_factor: flattened terrain toward sea level
                // - amp_factor: scaled terrain amplitude per biome
                // - clamp_to_sea_level: forced swamps flat
                // - offset_val: shifted height per biome
                // All of these caused visible "walls" at biome transitions.

                // Finalize height and ocean flag
                terrain_height_i = @intFromFloat(terrain_height);
                const is_ocean = terrain_height < sea;

                // Store for second pass
                surface_heights[idx] = terrain_height_i;
                biome_ids[idx] = selection.primary;
                secondary_biome_ids[idx] = selection.secondary;
                biome_blends[idx] = t;
                chunk.setBiome(local_x, local_z, selection.primary);
                filler_depths[idx] = primary_def.surface.depth_range;
                is_ocean_flags[idx] = is_ocean;
                cave_region_values[idx] = self.cave_system.getCaveRegionValue(wx, wz);
            }
        }

        // Relax terrain to prevent vertical cliffs (per worldgen-revamp.md Section 3.4)
        self.relaxTerrain(&surface_heights);

        // === Per worldgen-revamp.md Section 5.2: Ocean-only shoreline distance ===
        // Distinguish ocean water via continentalness (not lakes)
        // Compute shoreDistOcean - distance to nearest ocean water
        var shore_distances: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var slopes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32 = undefined;
        var exposure_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32 = undefined;
        const shore_search_radius: i32 = 12; // Extended search for coastal suppression

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_h = surface_heights[idx];

                // Compute slope (max neighbor delta) for this column
                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - surface_heights[idx + CHUNK_SIZE_X]))));
                slopes[idx] = max_slope;

                // Compute coastal exposure for variable beach width
                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));
                exposure_values[idx] = self.beach_exposure_noise.fbm2DNormalized(wx, wz, 2, 2.0, 0.5, 1.0 / 200.0);

                if (is_ocean_flags[idx]) {
                    // Underwater columns have distance 0
                    shore_distances[idx] = 0;
                } else {
                    // Search for nearest OCEAN water (not lakes)
                    // Per spec: ocean is identified by continentalness, not just water presence
                    var min_dist: i32 = 9999;
                    var dz: i32 = -shore_search_radius;
                    while (dz <= shore_search_radius) : (dz += 1) {
                        var dx: i32 = -shore_search_radius;
                        while (dx <= shore_search_radius) : (dx += 1) {
                            const nx = @as(i32, @intCast(local_x)) + dx;
                            const nz = @as(i32, @intCast(local_z)) + dz;

                            if (nx >= 0 and nx < CHUNK_SIZE_X and nz >= 0 and nz < CHUNK_SIZE_Z) {
                                const nidx = @as(usize, @intCast(nx)) + @as(usize, @intCast(nz)) * CHUNK_SIZE_X;
                                // Only count as ocean if underwater AND low continentalness
                                // This prevents inland lakes from creating beach bands
                                if (is_ocean_flags[nidx]) {
                                    // Check continentalness at neighbor
                                    const nwx: f32 = @floatFromInt(world_x + nx);
                                    const nwz: f32 = @floatFromInt(world_z + nz);
                                    const warp = self.computeWarp(nwx, nwz);
                                    const nc = self.getContinentalness(nwx + warp.x, nwz + warp.z);
                                    // Ocean = low continentalness
                                    if (nc < p.coast_threshold) {
                                        // Chebyshev distance (max of dx, dz)
                                        const dist = @max(@abs(dx), @abs(dz));
                                        min_dist = @min(min_dist, dist);
                                    }
                                }
                            }
                        }
                    }
                    shore_distances[idx] = min_dist;
                }
            }
        }

        // Generate worm caves (crosses chunk boundaries)
        var worm_carve_map = self.cave_system.generateWormCaves(chunk, &surface_heights, self.allocator) catch {
            // If allocation fails, continue without worm caves
            var empty_map: ?@import("caves.zig").CaveCarveMap = null;
            _ = &empty_map;
            return self.generateWithoutWormCaves(chunk, &surface_heights, &biome_ids, &secondary_biome_ids, &biome_blends, &filler_depths, &is_ocean_flags, &cave_region_values, &shore_distances, &slopes, &exposure_values, sea);
        };
        defer worm_carve_map.deinit();

        // DEBUG: Count beach triggers
        var debug_beach_count: u32 = 0;

        // Second pass: fill blocks with cave carving
        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_height_i = surface_heights[idx];
                const filler_depth = filler_depths[idx];
                const is_ocean = is_ocean_flags[idx];
                const cave_region = cave_region_values[idx];
                const shore_dist = shore_distances[idx];
                const slope = slopes[idx];
                _ = exposure_values[idx]; // Reserved for future beach width variation

                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Re-compute coastal status for cliff detection
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);

                // === STRICT Beach conditions ===
                // Beach ONLY at the very edge of water, must be:
                // 1. Very close to ocean (shore_dist 1-3 blocks max)
                // 2. At or just barely above sea level (0-2 blocks)
                // 3. Gentle slope
                // 4. shore_dist must NOT be 9999 (meaning ocean was found nearby)
                const depth_above_sea = terrain_height_i - p.sea_level;
                const is_beach_surface = !is_ocean and
                    shore_dist >= 1 and shore_dist <= 3 and
                    depth_above_sea >= 0 and depth_above_sea <= 2 and
                    slope <= 2;

                if (is_beach_surface) debug_beach_count += 1;

                // Cliff detection DISABLED - was triggering on terraced terrain steps
                // causing massive stone bands across coastal zones
                // TODO: Re-enable with stricter conditions (true vertical cliffs only)
                const is_cliff = false;
                _ = c_val; // Unused after disabling cliff detection

                // Fill column
                var y: i32 = 0;

                // Dither blend for surface blocks (per Phase 2: probabilistic blending)
                const primary_biome_id = biome_ids[idx];
                const secondary_biome_id = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                // Lower frequency for larger, more natural clumps
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < blend;
                const active_biome_id = if (use_secondary) secondary_biome_id else primary_biome_id;
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));

                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean, sea);

                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    if (is_surface and block != .air and block != .water and block != .bedrock) {
                        // === Per worldgen-revamp.md Section 5.2/5.4: Surface rule override ===
                        // Procedural beach surface override (ocean-only, constrained)
                        if (is_beach_surface) {
                            block = .sand;
                        } else if (is_cliff) {
                            block = .stone;
                        }
                        // Note: sand inland is controlled by desert biome, not "near water"
                    } else if (is_near_surface and is_beach_surface and block == .dirt) {
                        // Sand filler below beach surface
                        block = .sand;
                    }

                    // Cave carving (worm caves + noise cavities)
                    if (block != .air and block != .water and block != .bedrock) {
                        const wy: f32 = @floatFromInt(y);
                        const should_carve_worm = worm_carve_map.get(local_x, @intCast(y), local_z);
                        const should_carve_cavity = self.cave_system.shouldCarveNoiseCavity(
                            wx,
                            wy,
                            wz,
                            terrain_height_i,
                            cave_region,
                        );

                        if (should_carve_worm or should_carve_cavity) {
                            block = if (y < p.sea_level) .water else .air;
                        }
                    }

                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        chunk.generated = true;

        // Ores
        self.generateOres(chunk);

        // Features (trees, cacti, etc.)
        self.generateFeatures(chunk, &biome_ids, &secondary_biome_ids, &biome_blends);

        // Compute initial skylight
        self.computeSkylight(chunk);

        // Compute block light
        // If this fails (e.g. OOM), we log and continue. The chunk will effectively have
        // no propagated block light until a dynamic update occurs. This is a safe fallback.
        self.computeBlockLight(chunk) catch |err| {
            std.debug.print("Failed to compute block light: {}\n", .{err});
        };

        chunk.dirty = true;

        // DEBUG: Print stats for this chunk (only every 16th chunk to reduce spam)
        const chunk_id = @as(u32, @bitCast(world_x)) +% @as(u32, @bitCast(world_z));
        if (chunk_id % 64 == 0) {
            // T/H/C stats
            var t_min: f32 = 1.0;
            var t_max: f32 = 0.0;
            var t_sum: f32 = 0.0;
            var h_min: f32 = 1.0;
            var h_max: f32 = 0.0;
            var h_sum: f32 = 0.0;
            var c_min: f32 = 1.0;
            var c_max: f32 = 0.0;
            var c_sum: f32 = 0.0;

            // Biome counts
            var biome_counts: [21]u32 = [_]u32{0} ** 21;
            var t_hot: u32 = 0; // T > 0.7
            var h_dry: u32 = 0; // H < 0.25

            for (0..CHUNK_SIZE_X * CHUNK_SIZE_Z) |i| {
                const t_val = debug_temperatures[i];
                const h_val = debug_humidities[i];
                const c_val = debug_continentalness[i];

                t_min = @min(t_min, t_val);
                t_max = @max(t_max, t_val);
                t_sum += t_val;
                h_min = @min(h_min, h_val);
                h_max = @max(h_max, h_val);
                h_sum += h_val;
                c_min = @min(c_min, c_val);
                c_max = @max(c_max, c_val);
                c_sum += c_val;

                if (t_val > 0.7) t_hot += 1;
                if (h_val < 0.25) h_dry += 1;

                const bid = @intFromEnum(biome_ids[i]);
                if (bid < 21) biome_counts[bid] += 1;
            }

            const n: f32 = @floatFromInt(CHUNK_SIZE_X * CHUNK_SIZE_Z);
            std.debug.print("\n=== WORLDGEN DEBUG @ chunk ({}, {}) ===\n", .{ world_x, world_z });
            std.debug.print("T: min={d:.2} max={d:.2} avg={d:.2} | hot(>0.7): {}%\n", .{ t_min, t_max, t_sum / n, t_hot * 100 / @as(u32, @intCast(CHUNK_SIZE_X * CHUNK_SIZE_Z)) });
            std.debug.print("H: min={d:.2} max={d:.2} avg={d:.2} | dry(<0.25): {}%\n", .{ h_min, h_max, h_sum / n, h_dry * 100 / @as(u32, @intCast(CHUNK_SIZE_X * CHUNK_SIZE_Z)) });
            std.debug.print("C: min={d:.2} max={d:.2} avg={d:.2}\n", .{ c_min, c_max, c_sum / n });
            std.debug.print("Beach triggers: {} / {}\n", .{ debug_beach_count, CHUNK_SIZE_X * CHUNK_SIZE_Z });

            // Print non-zero biome counts
            std.debug.print("Biomes: ", .{});
            const biome_names = [_][]const u8{ "deep_ocean", "ocean", "beach", "plains", "forest", "taiga", "desert", "snow_tundra", "mountains", "snowy_mountains", "river", "swamp", "mangrove", "jungle", "savanna", "badlands", "mushroom", "foothills", "marsh", "dry_plains", "coastal" };
            for (biome_counts, 0..) |count, bi| {
                if (count > 0) {
                    std.debug.print("{s}={} ", .{ biome_names[bi], count });
                }
            }
            std.debug.print("\n", .{});
        }
    }

    /// Fallback generation without worm caves (if allocation fails)
    fn generateWithoutWormCaves(
        self: *const TerrainGenerator,
        chunk: *Chunk,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        secondary_biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        biome_blends: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
        filler_depths: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        is_ocean_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool,
        cave_region_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
        shore_distances: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        slopes: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        exposure_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
        sea: f32,
    ) void {
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
                const shore_dist = shore_distances[idx];
                const slope = slopes[idx];
                _ = exposure_values[idx]; // Reserved for future beach width variation

                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Re-compute coastal status
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);

                // STRICT Beach logic
                const depth_above_sea = terrain_height_i - p.sea_level;
                const is_beach_surface = !is_ocean and
                    shore_dist >= 1 and shore_dist <= 3 and
                    depth_above_sea >= 0 and depth_above_sea <= 2 and
                    slope <= 2;
                // Cliff detection DISABLED - was triggering on terraced terrain
                const is_cliff = false;
                _ = c_val;

                const primary_biome_id = biome_ids[idx];
                const secondary_biome_id = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < blend;
                const active_biome_id = if (use_secondary) secondary_biome_id else primary_biome_id;
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));

                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean, sea);

                    const is_surface = (y == terrain_height_i);
                    const is_near_surface = (y > terrain_height_i - 3 and y <= terrain_height_i);

                    if (is_surface and block != .air and block != .water and block != .bedrock) {
                        if (is_beach_surface) {
                            block = .sand;
                        } else if (is_cliff) {
                            block = .stone;
                        }
                    } else if (is_near_surface and is_beach_surface and block == .dirt) {
                        block = .sand;
                    }

                    // Only noise cavities (no worm caves)
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
        // Fallback: ignore error if block light calc fails (OOM safe)
        self.computeBlockLight(chunk) catch {};
        chunk.dirty = true;
    }

    // ========== Section 4.1: Domain Warping ==========

    fn computeWarp(self: *const TerrainGenerator, x: f32, z: f32) struct { x: f32, z: f32 } {
        const p = self.params;
        const offset_x = self.warp_noise_x.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        const offset_z = self.warp_noise_z.fbm2D(x, z, 3, 2.0, 0.5, p.warp_scale) * p.warp_amplitude;
        return .{ .x = offset_x, .z = offset_z };
    }

    // ========== Section 4.2-4.5: Core 2D Fields ==========

    fn getContinentalness(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.continentalness_noise.fbm2D(x, z, 4, 2.0, 0.5, self.params.continental_scale);
        return (val + 1.0) * 0.5; // Normalize to [0, 1]
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
        // 2-layer climate: macro (regional) + local (variety)
        const macro = self.temperature_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.temperature_macro_scale);
        const local = self.temperature_local_noise.fbm2DNormalized(x, z, 2, 2.0, 0.5, p.temperature_local_scale);
        // Blend: macro + local
        var t = p.climate_macro_weight * macro + (1.0 - p.climate_macro_weight) * local;
        // Stretch from center to fill [0,1] better (Perlin clusters around 0.5)
        t = (t - 0.5) * 2.2 + 0.5;
        return clamp01(t);
    }

    fn getHumidity(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        // 2-layer climate: macro (regional) + local (variety)
        const macro = self.humidity_noise.fbm2DNormalized(x, z, 3, 2.0, 0.5, p.humidity_macro_scale);
        const local = self.humidity_local_noise.fbm2DNormalized(x, z, 2, 2.0, 0.5, p.humidity_local_scale);
        var h = p.climate_macro_weight * macro + (1.0 - p.climate_macro_weight) * local;
        // Stretch from center
        h = (h - 0.5) * 2.2 + 0.5;
        return clamp01(h);
    }

    // ========== Section 5: Height Function (per worldgen-revamp.md) ==========

    /// Per worldgen-revamp.md Section 3.2: Mountain mask = inland * peakMask * ruggedMask
    fn getMountainMask(self: *const TerrainGenerator, pv: f32, e: f32, c: f32) f32 {
        _ = self;
        // Per spec:
        // inland = smoothstep(0.48, 0.70, C)
        // peakMask = smoothstep(0.60, 0.90, P)
        // ruggedMask = 1.0 - smoothstep(0.45, 0.85, E)
        // mountMask = inland * peakMask * ruggedMask
        const inland = smoothstep(0.48, 0.70, c);
        const peak_factor = smoothstep(0.60, 0.90, pv);
        const rugged_factor = 1.0 - smoothstep(0.45, 0.85, e);
        return inland * peak_factor * rugged_factor;
    }

    /// Per worldgen-revamp.md Section 3: Terrain Generator Revamp
    /// Implements:
    /// - 3.1: Base height from continentalness (deep ocean -> inland plateau)
    /// - 3.2: Mountain system with mask + capped lift (fixes "walls")
    /// - 3.3: Elevation-dependent detail attenuation (fixes "busy peaks")
    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32, x: f32, z: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // === Section 3.1: Base height from continentalness ===
        // Key fix: inland terrain must rise ABOVE sea level quickly
        // c < 0.45 = underwater, c > 0.50 = above sea level
        var base_height: f32 = undefined;
        if (c < 0.45) {
            // Ocean: -45 to -5 relative to sea
            const ocean_t = c / 0.45;
            base_height = sea - 45.0 + ocean_t * 40.0;
        } else if (c < 0.52) {
            // Coastal transition: -5 to +8
            const coast_t = (c - 0.45) / 0.07;
            base_height = sea - 5.0 + coast_t * 13.0;
        } else {
            // Inland: +8 to +50 (rises with continentalness)
            const inland_t = smoothstep(0.52, 0.90, c);
            base_height = sea + 8.0 + inland_t * 42.0;
        }

        // === Section 3.2: Mountain lift with soft cap ===
        const m_mask = self.getMountainMask(pv, e, c);
        const lift_scale: f32 = 1.0 / 800.0;
        const lift_noise = (self.mountain_lift_noise.fbm2D(x, z, 4, 2.0, 0.5, lift_scale) + 1.0) * 0.5;
        const mount_lift_raw = m_mask * lift_noise * p.mount_amp;
        const mount_lift = mount_lift_raw / (1.0 + mount_lift_raw / p.mount_cap);
        base_height += mount_lift;

        // MID-FREQUENCY HILLS: Local variation to break uniform slopes
        const mid_freq_scale = 1.0 / 100.0;
        const mid_noise = self.detail_noise.fbm2D(x + 5000.0, z + 5000.0, 3, 2.0, 0.5, mid_freq_scale);
        const mid_amp: f32 = 20.0;
        // Apply more strongly inland
        const land_mult = smoothstep(0.50, 0.65, c);
        base_height += mid_noise * mid_amp * land_mult;

        // === Section 3.3: Elevation-dependent detail attenuation ===
        const elev01 = clamp01((base_height - sea) / p.highland_range);
        const detail_atten = 1.0 - smoothstep(0.3, 0.85, elev01);
        const detail = self.detail_noise.fbm2D(x, z, 5, 2.0, 0.5, p.detail_scale) * p.detail_amp;
        base_height += detail * detail_atten;

        // COMPRESSION: Soft cap peaks
        const peak_start = sea + 90.0;
        if (base_height > peak_start) {
            const h_above = base_height - peak_start;
            const peak_range = 100.0;
            const compressed = peak_range * (1.0 - std.math.exp(-h_above / peak_range));
            base_height = peak_start + compressed;
        }

        // Subtle terracing only in mountain areas
        if (m_mask > 0.3 and e < 0.4) {
            const terrace_step: f32 = 4.0;
            const terrace_strength: f32 = 0.2 * (1.0 - e);
            const terraced = @round(base_height / terrace_step) * terrace_step;
            base_height = std.math.lerp(base_height, terraced, terrace_strength);
        }

        return base_height;
    }

    // ========== Section 7: Rivers ==========

    fn getRiverMask(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const p = self.params;
        // Use ridged noise inverted (valleys are rivers)
        const r = self.river_noise.ridged2D(x, z, 4, 2.0, 0.5, p.river_scale);
        const river_val = 1.0 - r;
        return smoothstep(p.river_min, p.river_max, river_val);
    }

    // ========== Section 8: Biome Selection ==========
    // (See worldgen/biome.zig for data-driven selection logic)

    // ========== Section 9: Surface Layers ==========

    fn getBlockAt(
        self: *const TerrainGenerator,
        y: i32,
        terrain_height: i32,
        biome: Biome,
        filler_depth: i32,
        is_ocean: bool,
        sea: f32,
    ) BlockType {
        _ = self;
        const sea_level: i32 = @intFromFloat(sea);

        if (y == 0) return .bedrock;

        // Above terrain
        if (y > terrain_height) {
            if (y <= sea_level) return .water;
            return .air;
        }

        // Ocean floor - with depth check to prevent gravel seam at shoreline
        if (is_ocean and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            // Shallow water (depth <= 8): always sand to prevent gravel seam
            // This extends beach sand into shallow underwater areas
            if (depth <= 8) {
                return .sand;
            }
            // Medium depth: clay
            if (depth <= 20) {
                return .clay;
            }
            // Deep ocean: gravel
            return .gravel;
        }

        // Surface block
        if (y == terrain_height) {
            // Snow on top of cold biomes
            if (biome == .snowy_mountains or biome == .snow_tundra) {
                return .snow_block;
            }
            return biome.getSurfaceBlock();
        }

        // Filler layers (dirt/sand under surface)
        if (y > terrain_height - filler_depth) {
            return biome.getFillerBlock();
        }

        // Stone below
        return .stone;
    }

    /// Per worldgen-revamp.md Section 3.4: Slope limiter
    /// After generating heightmap, run relaxation passes to enforce maxDelta between neighbors.
    /// This kills giant vertical sheets while preserving mountains.
    fn relaxTerrain(self: *const TerrainGenerator, heights: *[CHUNK_SIZE_X * CHUNK_SIZE_Z]i32) void {
        const p = self.params;
        const max_delta = p.max_slope_delta;

        // Run multiple relaxation passes
        for (0..p.relaxation_passes) |_| {
            // For each cell, if neighbor delta exceeds max, pull toward average
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                var x: u32 = 0;
                while (x < CHUNK_SIZE_X) : (x += 1) {
                    const idx = x + z * CHUNK_SIZE_X;
                    const h = heights[idx];

                    // Check all 4 neighbors and compute clamped average
                    var neighbor_sum: i32 = 0;
                    var neighbor_count: i32 = 0;

                    if (x > 0) {
                        const nh = heights[idx - 1];
                        const clamped = std.math.clamp(nh, h - max_delta, h + max_delta);
                        neighbor_sum += clamped;
                        neighbor_count += 1;
                    }
                    if (x < CHUNK_SIZE_X - 1) {
                        const nh = heights[idx + 1];
                        const clamped = std.math.clamp(nh, h - max_delta, h + max_delta);
                        neighbor_sum += clamped;
                        neighbor_count += 1;
                    }
                    if (z > 0) {
                        const nh = heights[idx - CHUNK_SIZE_X];
                        const clamped = std.math.clamp(nh, h - max_delta, h + max_delta);
                        neighbor_sum += clamped;
                        neighbor_count += 1;
                    }
                    if (z < CHUNK_SIZE_Z - 1) {
                        const nh = heights[idx + CHUNK_SIZE_X];
                        const clamped = std.math.clamp(nh, h - max_delta, h + max_delta);
                        neighbor_sum += clamped;
                        neighbor_count += 1;
                    }

                    if (neighbor_count > 0) {
                        // Blend current height toward clamped neighbor average (gentle relaxation)
                        const avg = @divTrunc(neighbor_sum, neighbor_count);
                        // Only adjust if there's a significant slope violation
                        const max_neighbor_delta = blk: {
                            var max_d: i32 = 0;
                            if (x > 0) max_d = @max(max_d, @as(i32, @intCast(@abs(h - heights[idx - 1]))));
                            if (x < CHUNK_SIZE_X - 1) max_d = @max(max_d, @as(i32, @intCast(@abs(h - heights[idx + 1]))));
                            if (z > 0) max_d = @max(max_d, @as(i32, @intCast(@abs(h - heights[idx - CHUNK_SIZE_X]))));
                            if (z < CHUNK_SIZE_Z - 1) max_d = @max(max_d, @as(i32, @intCast(@abs(h - heights[idx + CHUNK_SIZE_X]))));
                            break :blk max_d;
                        };

                        if (max_neighbor_delta > max_delta) {
                            // Pull toward average to reduce slope
                            heights[idx] = @divTrunc(h + avg, 2);
                        }
                    }
                }
            }
        }
    }

    // ========== Ores ==========

    fn generateOres(self: *const TerrainGenerator, chunk: *Chunk) void {
        var prng = std.Random.DefaultPrng.init(
            self.erosion_noise.seed +%
                @as(u64, @bitCast(@as(i64, chunk.chunk_x))) *% 59381 +%
                @as(u64, @bitCast(@as(i64, chunk.chunk_z))) *% 28411,
        );
        const random = prng.random();

        self.placeOreVeins(chunk, .coal_ore, 20, 6, 10, 128, random);
        self.placeOreVeins(chunk, .iron_ore, 10, 4, 5, 64, random);
        self.placeOreVeins(chunk, .gold_ore, 3, 3, 2, 32, random);
        // Glowstone in deep caves
        self.placeOreVeins(chunk, .glowstone, 8, 4, 5, 40, random);
    }

    fn placeOreVeins(
        self: *const TerrainGenerator,
        chunk: *Chunk,
        block: BlockType,
        count: u32,
        size: u32,
        min_y: i32,
        max_y: i32,
        random: std.Random,
    ) void {
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
                    if (tx >= 0 and tx < CHUNK_SIZE_X and
                        ty >= 0 and ty < CHUNK_SIZE_Y and
                        tz >= 0 and tz < CHUNK_SIZE_Z)
                    {
                        chunk.setBlock(@intCast(tx), @intCast(ty), @intCast(tz), block);
                    }
                }
            }
        }
    }

    // ========== Features (Trees, Cacti, etc.) ==========

    fn generateFeatures(
        self: *const TerrainGenerator,
        chunk: *Chunk,
        biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        secondary_biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        biome_blends: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    ) void {
        var prng = std.Random.DefaultPrng.init(
            self.continentalness_noise.seed ^
                @as(u64, @bitCast(@as(i64, chunk.chunk_x))) ^
                (@as(u64, @bitCast(@as(i64, chunk.chunk_z))) << 32),
        );
        const random = prng.random();
        const p = self.params;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(chunk.getWorldX() + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(chunk.getWorldZ() + @as(i32, @intCast(local_z)));

                // === Per worldgen-revamp.md Section 5.3 & 6.3: Coastal no-tree band ===
                // Trees begin 8-20 blocks inland (biome dependent)
                // Suppress trees near coast and at low elevation
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);

                // Find surface height for elevation-based suppression
                const surface_y = self.findSurface(chunk, local_x, local_z);
                const sea_level_u: u32 = @intCast(p.sea_level);
                const near_sea_level = surface_y <= sea_level_u + 6;

                // Variable no-tree distance based on exposure noise
                const exposure = self.beach_exposure_noise.fbm2DNormalized(wx, wz, 2, 2.0, 0.5, 1.0 / 200.0);
                const no_tree_dist_f: f32 = @as(f32, @floatFromInt(p.coastal_no_tree_min)) +
                    exposure * @as(f32, @floatFromInt(p.coastal_no_tree_max - p.coastal_no_tree_min));

                // Coastal tree suppression:
                // Per spec Section 6.3: if shoreDistOcean <= noTreeDist, set treeDensity = 0
                // Use continentalness as proxy for shore distance (lower = closer to ocean)
                // c_val < 0.45 is ocean/beach, smoothstep from 0.45 to 0.52 for rapid recovery on land
                const coastal_factor = smoothstep(0.45, 0.52, c_val);

                // Also suppress based on elevation near sea level - very relaxed
                const elevation_factor: f32 = if (near_sea_level and c_val < 0.48) 0.5 else 1.0;

                // Combined tree suppression factor
                const tree_suppress_final = coastal_factor * elevation_factor;

                const primary = biome_ids[idx];
                const secondary = secondary_biome_ids[idx];
                const blend = biome_blends[idx];

                const prim_def = biome_mod.getBiomeDefinition(primary);
                const sec_def = biome_mod.getBiomeDefinition(secondary);

                // Use coherent noise for profile selection to match surface blocks
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const active_def = if (dither < blend) sec_def else prim_def;
                const profile = active_def.vegetation;

                // === Per worldgen-revamp.md Section 6.1: Blended density fields ===
                // treeDensity = lerp(densityB, densityA, t) - use blended values
                const tree_density = std.math.lerp(prim_def.vegetation.tree_density, sec_def.vegetation.tree_density, blend) * tree_suppress_final;
                const cactus_density = std.math.lerp(prim_def.vegetation.cactus_density, sec_def.vegetation.cactus_density, blend);
                const bamboo_density = std.math.lerp(prim_def.vegetation.bamboo_density, sec_def.vegetation.bamboo_density, blend) * tree_suppress_final;
                const melon_density = std.math.lerp(prim_def.vegetation.melon_density, sec_def.vegetation.melon_density, blend);

                // Suppress this for debug
                _ = no_tree_dist_f;

                var placed = false;

                // === Per worldgen-revamp.md Section 6.2: Spacing rules ===
                // Use deterministic hash + spacing radius to avoid clumping
                // Minimum 2-3 blocks between tree trunks
                const tree_spacing_check = self.checkTreeSpacing(chunk, local_x, local_z);

                // Trees
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

                // Bamboo
                if (!placed and bamboo_density > 0 and random.float(f32) < bamboo_density) {
                    const y = self.findSurface(chunk, local_x, local_z);
                    if (y > 0) {
                        const h = 4 + random.uintLessThan(u32, 8);
                        for (0..h) |i| {
                            const ty = y + 1 + @as(u32, @intCast(i));
                            if (ty < CHUNK_SIZE_Y) {
                                chunk.setBlock(local_x, ty, local_z, .bamboo);
                            }
                        }
                        placed = true;
                    }
                }

                // Melon
                if (!placed and melon_density > 0 and random.float(f32) < melon_density) {
                    const y = self.findSurface(chunk, local_x, local_z);
                    if (y > 0 and y < CHUNK_SIZE_Y - 1) {
                        chunk.setBlock(local_x, y + 1, local_z, .melon);
                        placed = true;
                    }
                }

                // Cactus
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

    /// Per worldgen-revamp.md Section 6.2: Spacing rules
    /// Check if a tree can be placed at this location without being too close to existing trees
    fn checkTreeSpacing(self: *const TerrainGenerator, chunk: *const Chunk, x: u32, z: u32) bool {
        _ = self;
        const min_spacing: i32 = 2; // Minimum 2 blocks between trunks

        // Check nearby blocks for existing tree trunks (wood)
        var dz: i32 = -min_spacing;
        while (dz <= min_spacing) : (dz += 1) {
            var dx: i32 = -min_spacing;
            while (dx <= min_spacing) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;

                const nx = @as(i32, @intCast(x)) + dx;
                const nz = @as(i32, @intCast(z)) + dz;

                if (nx >= 0 and nx < CHUNK_SIZE_X and nz >= 0 and nz < CHUNK_SIZE_Z) {
                    // Check a few y levels for wood blocks
                    const surface_y = chunk.getHighestSolidY(@intCast(nx), @intCast(nz));
                    var check_y: i32 = @as(i32, @intCast(surface_y)) + 1;
                    const max_check_y = check_y + 3;
                    while (check_y <= max_check_y and check_y < CHUNK_SIZE_Y) : (check_y += 1) {
                        const block = chunk.getBlock(@intCast(nx), @intCast(check_y), @intCast(nz));
                        if (block == .wood or block == .mangrove_log or block == .jungle_log or block == .acacia_log) {
                            return false; // Too close to existing tree
                        }
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
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mushroom_stem);
                    }
                }
                self.placeLeafDisk(chunk, x, y + height, z, 2, .red_mushroom_block);
            },
            .huge_brown_mushroom => {
                const height = 5 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mushroom_stem);
                    }
                }
                self.placeLeafDisk(chunk, x, y + height, z, 3, .brown_mushroom_block);
            },
            .mangrove => {
                // Prop roots
                for (0..3) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, .mangrove_roots);
                    }
                }
                const trunk_start = y + 2;
                const height = 4 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (trunk_start + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, trunk_start + @as(u32, @intCast(i)), z, log_type);
                    }
                }
                self.placeLeafDisk(chunk, x, trunk_start + height, z, 2, leaf_type);
            },
            .jungle => {
                const height = 10 + random.uintLessThan(u32, 10);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                    }
                }
                self.placeLeafDisk(chunk, x, y + height, z, 3, leaf_type);
                self.placeLeafDisk(chunk, x, y + height - 1, z, 2, leaf_type);
            },
            .acacia => {
                const height = 5 + random.uintLessThan(u32, 3);
                var cx = x;
                const cz = z;
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y and cx < CHUNK_SIZE_X) {
                        chunk.setBlock(cx, y + @as(u32, @intCast(i)), cz, log_type);
                    }
                    if (i > 2 and random.boolean()) {
                        cx = cx +% 1;
                    }
                }
                self.placeLeafDisk(chunk, cx, y + height, cz, 3, leaf_type);
            },
            .spruce => {
                const height = 6 + random.uintLessThan(u32, 4);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                    }
                }

                const leaf_base = y + 2;
                const leaf_top = y + height + 1;
                var ly: u32 = leaf_base;
                while (ly <= leaf_top) : (ly += 1) {
                    const dist = leaf_top - ly;
                    const r: i32 = if (dist > 5) 2 else if (dist > 1) 1 else 0;
                    self.placeLeafDisk(chunk, x, ly, z, r, leaf_type);
                }
                if (leaf_top < CHUNK_SIZE_Y) {
                    chunk.setBlock(x, leaf_top, z, leaf_type);
                }
            },
            else => {
                const height = 4 + random.uintLessThan(u32, 3);
                for (0..height) |i| {
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
                        chunk.setBlock(x, y + @as(u32, @intCast(i)), z, log_type);
                    }
                }

                const leaf_start = y + height - 2;
                const leaf_end = y + height + 1;
                var ly: u32 = leaf_start;
                while (ly <= leaf_end) : (ly += 1) {
                    const r: i32 = if (ly == leaf_end) 1 else 2;
                    self.placeLeafDisk(chunk, x, ly, z, r, leaf_type);
                }
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
                    if (target_x >= 0 and target_x < CHUNK_SIZE_X and
                        target_z >= 0 and target_z < CHUNK_SIZE_Z and
                        y < CHUNK_SIZE_Y)
                    {
                        if (chunk.getBlock(@intCast(target_x), y, @intCast(target_z)) == .air) {
                            chunk.setBlock(@intCast(target_x), y, @intCast(target_z), block);
                        }
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
            if (cy < CHUNK_SIZE_Y) {
                chunk.setBlock(x, cy, z, .cactus);
            }
        }
    }

    pub fn computeSkylight(self: *const TerrainGenerator, chunk: *Chunk) void {
        _ = self;

        // For each column, propagate skylight downward
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                var sky_light: u4 = MAX_LIGHT;

                // Start from top of world and go down
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(local_x, uy, local_z);

                    // Set current light level
                    chunk.setSkyLight(local_x, uy, local_z, sky_light);

                    // If block is opaque, skylight becomes 0 below
                    if (block.isOpaque()) {
                        sky_light = 0;
                    }
                    // Water reduces light by 1 per block (roughly)
                    else if (block == .water and sky_light > 0) {
                        sky_light -= 1;
                    }
                    // Transparent blocks (air, leaves) let light through
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

    /// Compute initial block light using BFS
    /// Finds all emissive blocks and propagates light
    pub fn computeBlockLight(self: *const TerrainGenerator, chunk: *Chunk) !void {
        var queue = std.ArrayListUnmanaged(LightNode){};
        defer queue.deinit(self.allocator);

        // 1. Find all light sources
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
                        try queue.append(self.allocator, .{
                            .x = @intCast(local_x),
                            .y = @intCast(y),
                            .z = @intCast(local_z),
                            .level = emission,
                        });
                    }
                }
            }
        }

        // 2. Propagate light (BFS)
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            if (node.level <= 1) continue;

            const neighbors = [6][3]i32{
                .{ 1, 0, 0 }, .{ -1, 0, 0 },
                .{ 0, 1, 0 }, .{ 0, -1, 0 },
                .{ 0, 0, 1 }, .{ 0, 0, -1 },
            };

            for (neighbors) |offset| {
                const nx = @as(i32, node.x) + offset[0];
                const ny = @as(i32, node.y) + offset[1];
                const nz = @as(i32, node.z) + offset[2];

                // Check bounds (intra-chunk only for now)
                if (nx >= 0 and nx < CHUNK_SIZE_X and
                    ny >= 0 and ny < CHUNK_SIZE_Y and
                    nz >= 0 and nz < CHUNK_SIZE_Z)
                {
                    const ux: u32 = @intCast(nx);
                    const uy: u32 = @intCast(ny);
                    const uz: u32 = @intCast(nz);

                    const block = chunk.getBlock(ux, uy, uz);
                    if (!block.isOpaque()) {
                        const current_level = chunk.getBlockLight(ux, uy, uz);
                        // Light decay: -1 normally, more for water?
                        // Simple model: -1 per step
                        const next_level = node.level - 1;

                        if (next_level > current_level) {
                            chunk.setBlockLight(ux, uy, uz, next_level);
                            try queue.append(self.allocator, .{
                                .x = @intCast(nx),
                                .y = @intCast(ny),
                                .z = @intCast(nz),
                                .level = next_level,
                            });
                        }
                    }
                }
            }
        }
    }
};
