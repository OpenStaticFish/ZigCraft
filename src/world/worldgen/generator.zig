//! Terrain generator using layered noise stack per worldgen-spec2.md
//! Implements: domain warping, multi-noise biomes, controlled caves,
//! ocean shaping, river carving, and varied mountain/cliff generation.
//! Now uses data-driven biome system from biome.zig per biomes.md spec.

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
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const MAX_LIGHT = @import("../chunk.zig").MAX_LIGHT;
const BlockType = @import("../block.zig").BlockType;
const Biome = @import("../block.zig").Biome;

/// Terrain generation parameters
const Params = struct {
    // Section 4.1: Domain Warping
    warp_scale: f32 = 1.0 / 1100.0,
    warp_amplitude: f32 = 50.0,

    // Section 4.2: Continentalness (large scale landmass)
    continental_scale: f32 = 1.0 / 2600.0,
    deep_ocean_threshold: f32 = 0.45,
    coast_threshold: f32 = 0.55,

    // Section 4.3: Erosion (sharp vs smooth terrain)
    erosion_scale: f32 = 1.0 / 1100.0,

    // Section 4.4: Peaks/Valleys (mountain rhythm)
    peaks_scale: f32 = 1.0 / 1400.0,

    // Section 4.5: Climate
    temperature_scale: f32 = 1.0 / 5000.0,
    humidity_scale: f32 = 1.0 / 4000.0,
    temp_lapse: f32 = 0.25, // Temperature reduction per altitude

    // Section 5: Height function
    sea_level: i32 = 64,
    mount_amp: f32 = 90.0,
    detail_scale: f32 = 1.0 / 220.0,
    detail_amp: f32 = 12.0,

    // Section 6: Ocean shaping
    coast_jitter_scale: f32 = 1.0 / 650.0,
    seabed_scale: f32 = 1.0 / 280.0,
    seabed_amp: f32 = 6.0,

    // Section 7: Rivers
    river_scale: f32 = 1.0 / 1200.0,
    river_min: f32 = 0.74,
    river_max: f32 = 0.84,
    river_depth_max: f32 = 12.0,
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

    // Detail and feature noise
    detail_noise: Noise,
    coast_jitter_noise: Noise,
    seabed_noise: Noise,
    river_noise: Noise,

    // Cave system (worm caves + noise cavities)
    cave_system: CaveSystem,

    // Filler depth variation
    filler_depth_noise: Noise,

    params: Params,
    allocator: std.mem.Allocator,

    pub fn init(seed: u64, allocator: std.mem.Allocator) TerrainGenerator {
        // Derive seeds for different layers to ensure they are independent
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
            .detail_noise = Noise.init(random.int(u64)),
            .coast_jitter_noise = Noise.init(random.int(u64)),
            .seabed_noise = Noise.init(random.int(u64)),
            .river_noise = Noise.init(random.int(u64)),
            .cave_system = CaveSystem.init(seed),
            .filler_depth_noise = Noise.init(random.int(u64)),
            .params = .{},
            .allocator = allocator,
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
                const t = selection.blend_factor;

                // === Biome Terrain Modifiers (Blended) ===
                // Apply data-driven modifiers with blending to shape the terrain
                const smooth_factor = std.math.lerp(primary_def.terrain.smoothing, secondary_def.terrain.smoothing, t);
                const amp_factor = std.math.lerp(primary_def.terrain.height_amplitude, secondary_def.terrain.height_amplitude, t);
                const offset_val = std.math.lerp(primary_def.terrain.height_offset, secondary_def.terrain.height_offset, t);

                if (smooth_factor > 0) {
                    const diff = terrain_height - sea;
                    terrain_height = sea + diff * (1.0 - smooth_factor);
                }

                if (amp_factor != 1.0) {
                    const diff = terrain_height - sea;
                    // Only apply amplitude scaling to land to avoid messing up seabed
                    if (terrain_height > sea) {
                        terrain_height = sea + diff * amp_factor;
                    }
                }

                // Clamping (hard to blend boolean, check if primary has it)
                if (primary_def.terrain.clamp_to_sea_level and t < 0.5) {
                    // For swamp: flatten near sea level
                    if (terrain_height > sea - 5 and terrain_height < sea + 5) {
                        terrain_height = std.math.lerp(terrain_height, sea, 0.8);
                    }
                }

                terrain_height += offset_val;

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

        // Relax terrain to prevent vertical cliffs
        self.relaxTerrain(&surface_heights);

        // Generate worm caves (crosses chunk boundaries)
        var worm_carve_map = self.cave_system.generateWormCaves(chunk, &surface_heights, self.allocator) catch {
            // If allocation fails, continue without worm caves
            var empty_map: ?@import("caves.zig").CaveCarveMap = null;
            _ = &empty_map;
            return self.generateWithoutWormCaves(chunk, &surface_heights, &biome_ids, &secondary_biome_ids, &biome_blends, &filler_depths, &is_ocean_flags, &cave_region_values, sea);
        };
        defer worm_carve_map.deinit();

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

                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Re-compute coastal status and slope for procedural beaches
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);
                // Tighten coastal zone to prevent massive inland beaches
                const is_coastal_zone = c_val > 0.50 and c_val < 0.62;

                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx + CHUNK_SIZE_X]))));

                // Fill column
                var y: i32 = 0;

                // Dither blend for surface blocks
                const primary_biome_id = biome_ids[idx];
                const secondary_biome_id = secondary_biome_ids[idx];
                const blend = biome_blends[idx];
                // Lower frequency for larger, more natural clumps (0.1 -> 0.02)
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < blend;
                const active_biome_id = if (use_secondary) secondary_biome_id else primary_biome_id;
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));

                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.getBlockAt(y, terrain_height_i, active_biome, filler_depth, is_ocean, sea);

                    // Procedural Beach/Cliff rules
                    if (block == active_biome.getSurfaceBlock()) {
                        const sl = p.sea_level;
                        if (is_coastal_zone and max_slope >= 3 and y >= sl) {
                            block = .stone; // Cliff
                        } else if (is_coastal_zone and max_slope <= 1 and y >= sl - 2 and y <= sl + 1) {
                            block = .sand; // Beach
                        }
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

                const wx: f32 = @floatFromInt(world_x + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(world_z + @as(i32, @intCast(local_z)));

                // Re-compute coastal status and slope
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);
                const is_coastal_zone = c_val > 0.50 and c_val < 0.62;

                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_height_i - surface_heights[idx + CHUNK_SIZE_X]))));

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

                    // Procedural Beach/Cliff rules
                    if (block == active_biome.getSurfaceBlock()) {
                        const sl = p.sea_level;
                        if (is_coastal_zone and max_slope >= 3 and y >= sl) {
                            block = .stone;
                        } else if (is_coastal_zone and max_slope <= 1 and y >= sl - 2 and y <= sl + 1) {
                            block = .sand;
                        }
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
        const val = self.temperature_noise.fbm2D(x, z, 3, 2.0, 0.5, self.params.temperature_scale);
        return (val + 1.0) * 0.5;
    }

    fn getHumidity(self: *const TerrainGenerator, x: f32, z: f32) f32 {
        const val = self.humidity_noise.fbm2D(x, z, 3, 2.0, 0.5, self.params.humidity_scale);
        return (val + 1.0) * 0.5;
    }

    // ========== Section 5: Height Function ==========

    fn getMountainMask(self: *const TerrainGenerator, pv: f32, e: f32, c: f32) f32 {
        _ = self;
        // Mountains require: Inland, High Peaks, Rugged (low erosion)
        const inland = smoothstep(0.48, 0.70, c);
        const peak_factor = smoothstep(0.60, 0.90, pv);
        const rugged_factor = 1.0 - smoothstep(0.45, 0.85, e);
        return inland * peak_factor * rugged_factor;
    }

    fn computeHeight(self: *const TerrainGenerator, c: f32, e: f32, pv: f32, x: f32, z: f32) f32 {
        const p = self.params;
        const sea: f32 = @floatFromInt(p.sea_level);

        // Section 5.1: Base height from continentalness
        // Broader smoothstep range to flatten the coast and push it inland (more water)
        const land_factor = smoothstep(0.30, 0.95, c);
        var base_height = std.math.lerp(sea - 60.0, sea + 90.0, land_factor);

        // Section 5.2: Mountain lift with soft cap
        const m_mask = self.getMountainMask(pv, e, c);
        var mount = std.math.pow(f32, m_mask, 1.6) * p.mount_amp;
        const mount_cap = 200.0;
        mount = mount / (1.0 + mount / mount_cap);
        base_height += mount;

        // ATTENUATION: Reduce detail noise at higher altitudes to avoid jagged peaks
        const elev_norm = clamp01((base_height - sea) / 120.0);
        const detail_atten = 1.0 - smoothstep(0.3, 0.9, elev_norm);

        // Section 5.3: Local detail (hills)
        const detail = self.detail_noise.fbm2D(x, z, 5, 2.0, 0.5, p.detail_scale) * p.detail_amp * detail_atten;
        base_height += detail;

        // COMPRESSION: Soft cap peaks to prevent needle terrain
        const peak_start = sea + 90.0;
        if (base_height > peak_start) {
            const h_above = base_height - peak_start;
            const peak_range = 100.0;
            // Smoothly compress height as it goes higher
            const compressed = peak_range * (1.0 - std.math.exp(-h_above / peak_range));
            base_height = peak_start + compressed;
        }

        // Section 5.5: Cliff/terrace shaping - reduce smoothness in rugged areas
        // Higher erosion = smoother terrain, lower = more cliffs
        // We can add subtle terracing in low-erosion mountain areas
        if (m_mask > 0.3 and e < 0.4) {
            const terrace_step: f32 = 4.0;
            const terrace_strength: f32 = 0.25 * (1.0 - e);
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

        // Ocean floor
        if (is_ocean and y == terrain_height) {
            const depth: f32 = sea - @as(f32, @floatFromInt(terrain_height));
            return biome.getOceanFloorBlock(depth);
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

    fn relaxTerrain(self: *const TerrainGenerator, heights: *[CHUNK_SIZE_X * CHUNK_SIZE_Z]i32) void {
        _ = self;
        const max_diff = 2;
        const iterations = 4;

        for (0..iterations) |_| {
            var changed = false;

            // Forward pass
            var i: usize = 0;
            while (i < heights.len) : (i += 1) {
                var h = heights[i];
                const x = i % CHUNK_SIZE_X;
                const z = i / CHUNK_SIZE_X;

                // West
                if (x > 0) {
                    const n = heights[i - 1];
                    if (h - n > max_diff) {
                        h = n + max_diff;
                        heights[i] = h;
                        changed = true;
                    } else if (n - h > max_diff) {
                        h = n - max_diff;
                        heights[i] = h;
                        changed = true;
                    }
                }
                // North
                if (z > 0) {
                    const n = heights[i - CHUNK_SIZE_X];
                    if (h - n > max_diff) {
                        h = n + max_diff;
                        heights[i] = h;
                        changed = true;
                    } else if (n - h > max_diff) {
                        h = n - max_diff;
                        heights[i] = h;
                        changed = true;
                    }
                }
            }

            // Backward pass
            var j: usize = heights.len;
            while (j > 0) {
                j -= 1;
                var h = heights[j];
                const x = j % CHUNK_SIZE_X;
                const z = j / CHUNK_SIZE_X;

                // East
                if (x < CHUNK_SIZE_X - 1) {
                    const n = heights[j + 1];
                    if (h - n > max_diff) {
                        h = n + max_diff;
                        heights[j] = h;
                        changed = true;
                    } else if (n - h > max_diff) {
                        h = n - max_diff;
                        heights[j] = h;
                        changed = true;
                    }
                }
                // South
                if (z < CHUNK_SIZE_Z - 1) {
                    const n = heights[j + CHUNK_SIZE_X];
                    if (h - n > max_diff) {
                        h = n + max_diff;
                        heights[j] = h;
                        changed = true;
                    } else if (n - h > max_diff) {
                        h = n - max_diff;
                        heights[j] = h;
                        changed = true;
                    }
                }
            }

            if (!changed) break;
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

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx: f32 = @floatFromInt(chunk.getWorldX() + @as(i32, @intCast(local_x)));
                const wz: f32 = @floatFromInt(chunk.getWorldZ() + @as(i32, @intCast(local_z)));

                // Coastal suppression
                const warp = self.computeWarp(wx, wz);
                const c_val = self.getContinentalness(wx + warp.x, wz + warp.z);
                const tree_suppress = smoothstep(0.58, 0.62, c_val);

                const primary = biome_ids[idx];
                const secondary = secondary_biome_ids[idx];
                const blend = biome_blends[idx];

                const prim_def = biome_mod.getBiomeDefinition(primary);
                const sec_def = biome_mod.getBiomeDefinition(secondary);

                // Use coherent noise for profile selection to match surface blocks
                const dither = self.detail_noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const active_def = if (dither < blend) sec_def else prim_def;
                const profile = active_def.vegetation;

                const tree_density = std.math.lerp(prim_def.vegetation.tree_density, sec_def.vegetation.tree_density, blend) * tree_suppress;
                const cactus_density = std.math.lerp(prim_def.vegetation.cactus_density, sec_def.vegetation.cactus_density, blend);
                const bamboo_density = std.math.lerp(prim_def.vegetation.bamboo_density, sec_def.vegetation.bamboo_density, blend);
                const melon_density = std.math.lerp(prim_def.vegetation.melon_density, sec_def.vegetation.melon_density, blend);

                var placed = false;

                // Trees
                if (!placed and tree_density > 0 and random.float(f32) < tree_density) {
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
                    if (y + @as(u32, @intCast(i)) < CHUNK_SIZE_Y) {
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
