const std = @import("std");
const noise_mod = @import("noise.zig");
const clamp01 = noise_mod.clamp01;
const CaveSystem = @import("caves.zig").CaveSystem;
pub const CaveCarveMap = @import("caves.zig").CaveCarveMap;
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const BiomeSource = biome_mod.BiomeSource;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const world_class = @import("world_class.zig");
const ContinentalZone = world_class.ContinentalZone;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const Biome = world_core.Biome;
const BlockType = world_core.BlockType;
const noise_sampler_mod = @import("noise_sampler.zig");
pub const NoiseSampler = noise_sampler_mod.NoiseSampler;
const height_sampler_mod = @import("height_sampler.zig");
pub const HeightSampler = height_sampler_mod.HeightSampler;
const surface_builder_mod = @import("surface_builder.zig");
pub const SurfaceBuilder = surface_builder_mod.SurfaceBuilder;
pub const CoastalSurfaceType = surface_builder_mod.CoastalSurfaceType;
const CoastalGenerator = @import("coastal_generator.zig").CoastalGenerator;

const BIOME_INFLUENCE_SAMPLE_OFFSET: f32 = 8.0;
const BIOME_INFLUENCE_SAMPLE_OFFSET_I: i32 = 8;
const BIOME_TERRAIN_CACHE_SIZE: u32 = CHUNK_SIZE_X + @as(u32, @intCast(BIOME_INFLUENCE_SAMPLE_OFFSET_I * 2));
const OCEAN_PROXIMITY_RADIUS: i32 = 2;
const OCEAN_PROXIMITY_GRID_SIZE: u32 = CHUNK_SIZE_X + @as(u32, @intCast(OCEAN_PROXIMITY_RADIUS * 2));
const CLAMP_TO_SEA_LEVEL_BLEND_THRESHOLD: f32 = 0.65;

pub const Params = struct {
    temp_lapse: f32 = 0.25,
    sea_level: i32 = 64,
    ocean_threshold: f32 = 0.37,
    ridge_inland_min: f32 = 0.48,
    ridge_inland_max: f32 = 0.68,
    ridge_sparsity: f32 = 0.46,
    disable_caves: bool = false,
};

pub const ColumnData = struct {
    terrain_height: f32,
    terrain_height_i: i32,
    continentalness: f32,
    erosion: f32,
    river_mask: f32,
    temperature: f32,
    humidity: f32,
    ridge_mask: f32,
    is_underwater: bool,
    is_ocean: bool,
    cave_region: f32,
};

pub const ChunkPhaseData = struct {
    surface_heights: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
    biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    secondary_biome_ids: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    biome_blends: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    filler_depths: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
    is_underwater_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool,
    is_ocean_water_flags: [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool,
    cave_region_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    continentalness_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    erosion_values: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    ridge_masks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    river_masks: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    temperatures: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    humidities: [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
    slopes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
    coastal_types: [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType,
};

const TerrainModifierCache = [BIOME_TERRAIN_CACHE_SIZE * BIOME_TERRAIN_CACHE_SIZE]biome_mod.TerrainModifier;
const OceanProximityGrid = [OCEAN_PROXIMITY_GRID_SIZE * OCEAN_PROXIMITY_GRID_SIZE]bool;

pub const TerrainShapeGenerator = struct {
    noise_sampler: NoiseSampler,
    height_sampler: HeightSampler,
    surface_builder: SurfaceBuilder,
    biome_source: BiomeSource,
    cave_system: CaveSystem,
    coastal_generator: CoastalGenerator,
    params: Params,

    pub fn init(seed: u64) TerrainShapeGenerator {
        return initWithParams(seed, .{});
    }

    pub fn initWithParams(seed: u64, params: Params) TerrainShapeGenerator {
        const p = params;
        return .{
            .noise_sampler = NoiseSampler.init(seed),
            .height_sampler = HeightSampler.init(),
            .surface_builder = SurfaceBuilder.init(),
            .biome_source = BiomeSource.init(),
            .cave_system = CaveSystem.init(seed),
            .coastal_generator = CoastalGenerator.init(p.ocean_threshold),
            .params = p,
        };
    }

    pub fn getSeed(self: *const TerrainShapeGenerator) u64 {
        return self.noise_sampler.getSeed();
    }

    pub fn getRegionSeed(self: *const TerrainShapeGenerator) u64 {
        return self.noise_sampler.continentalness_noise.params.seed;
    }

    pub fn getSeaLevel(self: *const TerrainShapeGenerator) i32 {
        return self.params.sea_level;
    }

    pub fn getOceanThreshold(self: *const TerrainShapeGenerator) f32 {
        return self.params.ocean_threshold;
    }

    pub fn getContinentalZone(self: *const TerrainShapeGenerator, c: f32) ContinentalZone {
        return self.height_sampler.getContinentalZone(c);
    }

    fn updateSlopes(phase_data: *ChunkPhaseData, stop_flag: ?*const bool) bool {
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_h = phase_data.surface_heights[idx];
                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx + CHUNK_SIZE_X]))));
                phase_data.slopes[idx] = max_slope;
            }
        }
        return true;
    }

    fn hasNearbyOceanWater(
        ocean_grid: *const OceanProximityGrid,
        local_x: u32,
        local_z: u32,
    ) bool {
        const center_x: i32 = @intCast(local_x);
        const center_z: i32 = @intCast(local_z);

        var dz: i32 = -OCEAN_PROXIMITY_RADIUS;
        while (dz <= OCEAN_PROXIMITY_RADIUS) : (dz += 1) {
            var dx: i32 = -OCEAN_PROXIMITY_RADIUS;
            while (dx <= OCEAN_PROXIMITY_RADIUS) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const gx: u32 = @intCast(center_x + dx + OCEAN_PROXIMITY_RADIUS);
                const gz: u32 = @intCast(center_z + dz + OCEAN_PROXIMITY_RADIUS);
                if (ocean_grid[gx + gz * OCEAN_PROXIMITY_GRID_SIZE]) return true;
            }
        }

        return false;
    }

    pub fn getNoiseSampler(self: *const TerrainShapeGenerator) *const NoiseSampler {
        return &self.noise_sampler;
    }

    pub fn getHeightSampler(self: *const TerrainShapeGenerator) *const HeightSampler {
        return &self.height_sampler;
    }

    pub fn getSurfaceBuilder(self: *const TerrainShapeGenerator) *const SurfaceBuilder {
        return &self.surface_builder;
    }

    pub fn getBiomeSource(self: *const TerrainShapeGenerator) *const BiomeSource {
        return &self.biome_source;
    }

    pub fn sampleColumnData(self: *const TerrainShapeGenerator, wx: f32, wz: f32, reduction: u8) ColumnData {
        const region_seed = self.getRegionSeed();
        const wx_i = floatToI32(@floor(wx));
        const wz_i = floatToI32(@floor(wz));
        const controls = region_pkg.getBlendedControls(region_seed, wx_i, wz_i);
        return self.sampleColumnDataWithControls(wx, wz, reduction, controls);
    }

    /// High-detail map sampling without the generation-only nine-point biome
    /// terrain blend. This preserves the requested noise octave detail while
    /// using one representative terrain modifier, reducing near-map sampling
    /// from roughly ten column evaluations to two.
    pub fn sampleMapColumnData(self: *const TerrainShapeGenerator, wx: f32, wz: f32, reduction: u8) ColumnData {
        const region_seed = self.getRegionSeed();
        const wx_i = floatToI32(@floor(wx));
        const wz_i = floatToI32(@floor(wz));
        const controls = region_pkg.getBlendedControls(region_seed, wx_i, wz_i);
        const terrain_modifier = self.sampleTerrainModifierAt(wx, wz, reduction);
        return self.sampleColumnDataWithControlsAndTerrainModifier(wx, wz, reduction, controls, terrain_modifier);
    }

    pub fn sampleColumnDataWithControls(self: *const TerrainShapeGenerator, wx: f32, wz: f32, reduction: u8, controls: region_pkg.RegionControls) ColumnData {
        const terrain_modifier = self.sampleBlendedTerrainModifier(wx, wz, reduction, controls);
        return self.sampleColumnDataWithControlsAndTerrainModifier(wx, wz, reduction, controls, terrain_modifier);
    }

    fn terrainInfluenceWeight(dx: f32, dz: f32) f32 {
        const d2 = dx * dx + dz * dz;
        return 1.0 / (1.0 + d2 / (BIOME_INFLUENCE_SAMPLE_OFFSET * BIOME_INFLUENCE_SAMPLE_OFFSET));
    }

    fn sampleTerrainModifierAt(
        self: *const TerrainShapeGenerator,
        wx: f32,
        wz: f32,
        reduction: u8,
    ) biome_mod.TerrainModifier {
        const wx_i = floatToI32(@floor(wx));
        const wz_i = floatToI32(@floor(wz));
        const controls = region_pkg.getBlendedControls(self.getRegionSeed(), wx_i, wz_i);
        const base_column = self.sampleColumnDataWithControlsAndTerrainModifier(wx, wz, reduction, controls, null);
        const biome_id = self.selectBiomeForColumn(base_column, 1);
        return biome_mod.getBiomeDefinition(biome_id).terrain;
    }

    fn blendTerrainModifiers(samples: [9]biome_mod.TerrainModifier) biome_mod.TerrainModifier {
        var total_weight: f32 = 0.0;
        var height_amplitude: f32 = 0.0;
        var smoothing: f32 = 0.0;
        var clamp_weight: f32 = 0.0;
        var height_offset: f32 = 0.0;

        const offsets = [_][2]f32{
            .{ 0.0, 0.0 },
            .{ -BIOME_INFLUENCE_SAMPLE_OFFSET, 0.0 },
            .{ BIOME_INFLUENCE_SAMPLE_OFFSET, 0.0 },
            .{ 0.0, -BIOME_INFLUENCE_SAMPLE_OFFSET },
            .{ 0.0, BIOME_INFLUENCE_SAMPLE_OFFSET },
            .{ -BIOME_INFLUENCE_SAMPLE_OFFSET, -BIOME_INFLUENCE_SAMPLE_OFFSET },
            .{ BIOME_INFLUENCE_SAMPLE_OFFSET, -BIOME_INFLUENCE_SAMPLE_OFFSET },
            .{ -BIOME_INFLUENCE_SAMPLE_OFFSET, BIOME_INFLUENCE_SAMPLE_OFFSET },
            .{ BIOME_INFLUENCE_SAMPLE_OFFSET, BIOME_INFLUENCE_SAMPLE_OFFSET },
        };

        for (samples, offsets) |terrain, offset| {
            const weight = terrainInfluenceWeight(offset[0], offset[1]);

            total_weight += weight;
            height_amplitude += terrain.height_amplitude * weight;
            smoothing += terrain.smoothing * weight;
            if (terrain.clamp_to_sea_level) clamp_weight += weight;
            height_offset += terrain.height_offset * weight;
        }

        if (total_weight <= 0.0) return .{};
        return .{
            .height_amplitude = height_amplitude / total_weight,
            .smoothing = smoothing / total_weight,
            .clamp_to_sea_level = clamp_weight / total_weight >= CLAMP_TO_SEA_LEVEL_BLEND_THRESHOLD,
            .height_offset = height_offset / total_weight,
        };
    }

    fn sampleBlendedTerrainModifier(
        self: *const TerrainShapeGenerator,
        wx: f32,
        wz: f32,
        reduction: u8,
        center_controls: region_pkg.RegionControls,
    ) biome_mod.TerrainModifier {
        _ = center_controls;
        // Coarse map samples already represent multiple blocks, so the 9-point
        // biome influence blend is visually indistinguishable but multiplies
        // the dominant terrain-modifier sampling cost. Use the center sample
        // from reduction 2+.
        if (reduction >= 2) return self.sampleTerrainModifierAt(wx, wz, reduction);

        const samples = [_]biome_mod.TerrainModifier{
            self.sampleTerrainModifierAt(wx, wz, reduction),
            self.sampleTerrainModifierAt(wx - BIOME_INFLUENCE_SAMPLE_OFFSET, wz, reduction),
            self.sampleTerrainModifierAt(wx + BIOME_INFLUENCE_SAMPLE_OFFSET, wz, reduction),
            self.sampleTerrainModifierAt(wx, wz - BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
            self.sampleTerrainModifierAt(wx, wz + BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
            self.sampleTerrainModifierAt(wx - BIOME_INFLUENCE_SAMPLE_OFFSET, wz - BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
            self.sampleTerrainModifierAt(wx + BIOME_INFLUENCE_SAMPLE_OFFSET, wz - BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
            self.sampleTerrainModifierAt(wx - BIOME_INFLUENCE_SAMPLE_OFFSET, wz + BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
            self.sampleTerrainModifierAt(wx + BIOME_INFLUENCE_SAMPLE_OFFSET, wz + BIOME_INFLUENCE_SAMPLE_OFFSET, reduction),
        };
        return blendTerrainModifiers(samples);
    }

    fn getCachedBlendedTerrainModifier(cache: *const TerrainModifierCache, local_x: u32, local_z: u32) biome_mod.TerrainModifier {
        const center_x = local_x + @as(u32, @intCast(BIOME_INFLUENCE_SAMPLE_OFFSET_I));
        const center_z = local_z + @as(u32, @intCast(BIOME_INFLUENCE_SAMPLE_OFFSET_I));
        const step: u32 = @intCast(BIOME_INFLUENCE_SAMPLE_OFFSET_I);
        const samples = [_]biome_mod.TerrainModifier{
            cache[center_x + center_z * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x - step + center_z * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x + step + center_z * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x + (center_z - step) * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x + (center_z + step) * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x - step + (center_z - step) * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x + step + (center_z - step) * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x - step + (center_z + step) * BIOME_TERRAIN_CACHE_SIZE],
            cache[center_x + step + (center_z + step) * BIOME_TERRAIN_CACHE_SIZE],
        };
        return blendTerrainModifiers(samples);
    }

    fn sampleColumnDataWithControlsAndTerrainModifier(
        self: *const TerrainShapeGenerator,
        wx: f32,
        wz: f32,
        reduction: u8,
        controls: region_pkg.RegionControls,
        terrain_modifier: ?biome_mod.TerrainModifier,
    ) ColumnData {
        const sea: f32 = @floatFromInt(self.params.sea_level);
        var noise = self.noise_sampler.sampleColumn(wx, wz, reduction);
        const cj_octaves: u16 = if (2 > reduction) 2 - @as(u16, reduction) else 1;
        const coast_jitter = self.noise_sampler.coast_jitter_noise.get2DOctaves(noise.warped_x, noise.warped_z, cj_octaves);
        const c_jittered = CoastalGenerator.applyCoastJitter(noise.continentalness, coast_jitter);
        noise.continentalness = c_jittered;
        noise.river_mask = self.noise_sampler.getRiverMask(noise.warped_x, noise.warped_z, reduction);

        const region_seed = self.getRegionSeed();
        const wx_i = floatToI32(@floor(wx));
        const wz_i = floatToI32(@floor(wz));
        const region = region_pkg.getRegion(region_seed, wx_i, wz_i);
        const path_info = region_pkg.getPathInfo(region_seed, wx_i, wz_i, region);
        const ridge_params = NoiseSampler.RidgeParams{
            .inland_min = self.params.ridge_inland_min,
            .inland_max = self.params.ridge_inland_max,
            .sparsity = self.params.ridge_sparsity,
        };
        const ridge_mask = self.noise_sampler.getRidgeFactor(noise.warped_x, noise.warped_z, c_jittered, reduction, ridge_params);
        const terrain_height = self.height_sampler.computeHeightWithTerrainModifier(&self.noise_sampler, noise, controls, path_info, reduction, terrain_modifier);
        const terrain_height_i: i32 = @intFromFloat(terrain_height);

        const altitude_offset: f32 = @max(0, terrain_height - sea);
        var temperature = noise.temperature;
        temperature = clamp01(temperature - (altitude_offset / 512.0) * self.params.temp_lapse);

        return .{
            .terrain_height = terrain_height,
            .terrain_height_i = terrain_height_i,
            .continentalness = c_jittered,
            .erosion = noise.erosion,
            .river_mask = noise.river_mask,
            .temperature = temperature,
            .humidity = noise.humidity,
            .ridge_mask = ridge_mask,
            .is_underwater = terrain_height < sea,
            .is_ocean = c_jittered < self.params.ocean_threshold,
            .cave_region = self.cave_system.getCaveRegionValue(wx, wz),
        };
    }

    fn selectBiomeForColumn(self: *const TerrainShapeGenerator, column: ColumnData, slope: i32) BiomeId {
        const climate = self.biome_source.computeClimate(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            CHUNK_SIZE_Y,
        );
        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = slope,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };
        return self.biome_source.selectBiome(climate, structural, column.river_mask);
    }

    pub fn prepareChunkPhaseData(
        self: *const TerrainShapeGenerator,
        phase_data: *ChunkPhaseData,
        world_x: i32,
        world_z: i32,
        cache_center_x: i32,
        cache_center_z: i32,
        stop_flag: ?*const bool,
    ) bool {
        const controls = region_pkg.RegionControlCorners.init(
            self.getRegionSeed(),
            world_x,
            world_z,
            addWorldOffset(world_x, CHUNK_SIZE_X - 1),
            addWorldOffset(world_z, CHUNK_SIZE_Z - 1),
        );

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx_i = addWorldOffset(world_x, local_x);
                const wz_i = addWorldOffset(world_z, local_z);
                const wx: f32 = @floatFromInt(wx_i);
                const wz: f32 = @floatFromInt(wz_i);
                const column = self.sampleColumnDataWithControlsAndTerrainModifier(wx, wz, 0, controls.sample(wx_i, wz_i), null);

                phase_data.surface_heights[idx] = column.terrain_height_i;
                phase_data.is_underwater_flags[idx] = column.is_underwater;
                phase_data.is_ocean_water_flags[idx] = column.is_ocean;
                phase_data.cave_region_values[idx] = column.cave_region;
                phase_data.temperatures[idx] = column.temperature;
                phase_data.humidities[idx] = column.humidity;
                phase_data.continentalness_values[idx] = column.continentalness;
                phase_data.erosion_values[idx] = column.erosion;
                phase_data.ridge_masks[idx] = column.ridge_mask;
                phase_data.river_masks[idx] = column.river_mask;
            }
        }

        if (!updateSlopes(phase_data, stop_flag)) return false;

        var terrain_modifier_cache: TerrainModifierCache = undefined;
        var terrain_cache_z: u32 = 0;
        while (terrain_cache_z < BIOME_TERRAIN_CACHE_SIZE) : (terrain_cache_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var terrain_cache_x: u32 = 0;
            while (terrain_cache_x < BIOME_TERRAIN_CACHE_SIZE) : (terrain_cache_x += 1) {
                const sample_x = addWorldOffset(world_x, @as(i32, @intCast(terrain_cache_x)) - BIOME_INFLUENCE_SAMPLE_OFFSET_I);
                const sample_z = addWorldOffset(world_z, @as(i32, @intCast(terrain_cache_z)) - BIOME_INFLUENCE_SAMPLE_OFFSET_I);
                terrain_modifier_cache[terrain_cache_x + terrain_cache_z * BIOME_TERRAIN_CACHE_SIZE] = self.sampleTerrainModifierAt(
                    @floatFromInt(sample_x),
                    @floatFromInt(sample_z),
                    0,
                );
            }
        }

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const climate = self.biome_source.computeClimate(
                    phase_data.temperatures[idx],
                    phase_data.humidities[idx],
                    phase_data.surface_heights[idx],
                    phase_data.continentalness_values[idx],
                    phase_data.erosion_values[idx],
                    CHUNK_SIZE_Y,
                );

                const structural = biome_mod.StructuralParams{
                    .height = phase_data.surface_heights[idx],
                    .slope = phase_data.slopes[idx],
                    .continentalness = phase_data.continentalness_values[idx],
                    .ridge_mask = phase_data.ridge_masks[idx],
                };

                const biome_id = self.biome_source.selectBiome(climate, structural, phase_data.river_masks[idx]);
                phase_data.biome_ids[idx] = biome_id;
                phase_data.secondary_biome_ids[idx] = biome_id;
                phase_data.biome_blends[idx] = 0.0;

                const wx_i = addWorldOffset(world_x, local_x);
                const wz_i = addWorldOffset(world_z, local_z);
                const terrain_modifier = getCachedBlendedTerrainModifier(&terrain_modifier_cache, local_x, local_z);
                const column = self.sampleColumnDataWithControlsAndTerrainModifier(
                    @floatFromInt(wx_i),
                    @floatFromInt(wz_i),
                    0,
                    controls.sample(wx_i, wz_i),
                    terrain_modifier,
                );
                phase_data.surface_heights[idx] = column.terrain_height_i;
                phase_data.is_underwater_flags[idx] = column.is_underwater;
                phase_data.is_ocean_water_flags[idx] = column.is_ocean;
                phase_data.cave_region_values[idx] = column.cave_region;
                phase_data.temperatures[idx] = column.temperature;
                phase_data.humidities[idx] = column.humidity;
                phase_data.continentalness_values[idx] = column.continentalness;
                phase_data.erosion_values[idx] = column.erosion;
                phase_data.ridge_masks[idx] = column.ridge_mask;
                phase_data.river_masks[idx] = column.river_mask;
            }
        }

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_h = phase_data.surface_heights[idx];
                var max_slope: i32 = 0;
                if (local_x > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx - 1]))));
                if (local_x < CHUNK_SIZE_X - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx + 1]))));
                if (local_z > 0) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx - CHUNK_SIZE_X]))));
                if (local_z < CHUNK_SIZE_Z - 1) max_slope = @max(max_slope, @as(i32, @intCast(@abs(terrain_h - phase_data.surface_heights[idx + CHUNK_SIZE_X]))));
                phase_data.slopes[idx] = max_slope;
            }
        }

        const EDGE_GRID_SIZE = CHUNK_SIZE_X / biome_mod.EDGE_STEP;

        if (isNearCacheCenter(world_x, world_z, cache_center_x, cache_center_z)) {
            var gz: u32 = 0;
            while (gz < EDGE_GRID_SIZE) : (gz += 1) {
                if (stop_flag) |sf| if (sf.*) return false;
                var gx: u32 = 0;
                while (gx < EDGE_GRID_SIZE) : (gx += 1) {
                    const sample_x = gx * biome_mod.EDGE_STEP + biome_mod.EDGE_STEP / 2;
                    const sample_z = gz * biome_mod.EDGE_STEP + biome_mod.EDGE_STEP / 2;
                    const sample_idx = sample_x + sample_z * CHUNK_SIZE_X;
                    const base_biome = phase_data.biome_ids[sample_idx];
                    const sample_wx = addWorldOffset(world_x, sample_x);
                    const sample_wz = addWorldOffset(world_z, sample_z);
                    const edge_info = self.detectBiomeEdge(sample_wx, sample_wz, base_biome);

                    if (edge_info.edge_band != .none) {
                        if (edge_info.neighbor_biome) |neighbor| {
                            if (biome_mod.getTransitionBiome(base_biome, neighbor)) |transition_biome| {
                                var cell_z: u32 = 0;
                                while (cell_z < biome_mod.EDGE_STEP) : (cell_z += 1) {
                                    var cell_x: u32 = 0;
                                    while (cell_x < biome_mod.EDGE_STEP) : (cell_x += 1) {
                                        const lx = gx * biome_mod.EDGE_STEP + cell_x;
                                        const lz = gz * biome_mod.EDGE_STEP + cell_z;
                                        if (lx < CHUNK_SIZE_X and lz < CHUNK_SIZE_Z) {
                                            const cell_idx = lx + lz * CHUNK_SIZE_X;
                                            const original_biome = phase_data.biome_ids[cell_idx];
                                            phase_data.secondary_biome_ids[cell_idx] = original_biome;
                                            phase_data.biome_ids[cell_idx] = transition_biome;
                                            phase_data.biome_blends[cell_idx] = switch (edge_info.edge_band) {
                                                .inner => 0.3,
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
        }

        if (!updateSlopes(phase_data, stop_flag)) return false;

        var ocean_grid: OceanProximityGrid = undefined;
        var ocean_grid_z: u32 = 0;
        while (ocean_grid_z < OCEAN_PROXIMITY_GRID_SIZE) : (ocean_grid_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var ocean_grid_x: u32 = 0;
            while (ocean_grid_x < OCEAN_PROXIMITY_GRID_SIZE) : (ocean_grid_x += 1) {
                const local_sample_x = @as(i32, @intCast(ocean_grid_x)) - OCEAN_PROXIMITY_RADIUS;
                const local_sample_z = @as(i32, @intCast(ocean_grid_z)) - OCEAN_PROXIMITY_RADIUS;
                const in_chunk = local_sample_x >= 0 and local_sample_x < @as(i32, @intCast(CHUNK_SIZE_X)) and
                    local_sample_z >= 0 and local_sample_z < @as(i32, @intCast(CHUNK_SIZE_Z));
                const has_ocean_water = if (in_chunk) blk: {
                    const idx = @as(u32, @intCast(local_sample_x)) + @as(u32, @intCast(local_sample_z)) * CHUNK_SIZE_X;
                    break :blk phase_data.is_ocean_water_flags[idx] and phase_data.is_underwater_flags[idx];
                } else blk: {
                    const sample_wx = addWorldOffset(world_x, local_sample_x);
                    const sample_wz = addWorldOffset(world_z, local_sample_z);
                    const sample_controls = region_pkg.getBlendedControls(self.getRegionSeed(), sample_wx, sample_wz);
                    const column = self.sampleColumnDataWithControlsAndTerrainModifier(
                        @floatFromInt(sample_wx),
                        @floatFromInt(sample_wz),
                        0,
                        sample_controls,
                        null,
                    );
                    break :blk column.is_ocean and column.is_underwater;
                };
                ocean_grid[ocean_grid_x + ocean_grid_z * OCEAN_PROXIMITY_GRID_SIZE] = has_ocean_water;
            }
        }

        local_z = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const biome_def = biome_mod.getBiomeDefinition(phase_data.biome_ids[idx]);
                phase_data.filler_depths[idx] = biome_def.surface.depth_range;
                phase_data.coastal_types[idx] = if (hasNearbyOceanWater(&ocean_grid, local_x, local_z))
                    CoastalGenerator.getSurfaceType(
                        &self.surface_builder,
                        phase_data.continentalness_values[idx],
                        phase_data.slopes[idx],
                        phase_data.surface_heights[idx],
                        phase_data.erosion_values[idx],
                    )
                else
                    .none;
            }
        }

        return true;
    }

    pub fn fillChunkBlocks(
        self: *const TerrainShapeGenerator,
        chunk: *Chunk,
        phase_data: *const ChunkPhaseData,
        worm_carve_map: ?*const CaveCarveMap,
        stop_flag: ?*const bool,
    ) bool {
        const sea_level = self.params.sea_level;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return false;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const terrain_height_i = phase_data.surface_heights[idx];
                const wx: f32 = @floatFromInt(addWorldOffset(world_x, local_x));
                const wz: f32 = @floatFromInt(addWorldOffset(world_z, local_z));
                const dither = self.noise_sampler.detail_noise.noise.perlin2D(wx * 0.02, wz * 0.02) * 0.5 + 0.5;
                const use_secondary = dither < phase_data.biome_blends[idx];
                const active_biome_id = if (use_secondary) phase_data.secondary_biome_ids[idx] else phase_data.biome_ids[idx];
                const active_biome: Biome = @enumFromInt(@intFromEnum(active_biome_id));

                chunk.setSurfaceHeight(local_x, local_z, @intCast(terrain_height_i));
                chunk.biomes[idx] = active_biome_id;

                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    var block = self.surface_builder.getSurfaceBlock(
                        y,
                        terrain_height_i,
                        active_biome,
                        phase_data.filler_depths[idx],
                        phase_data.is_ocean_water_flags[idx],
                        phase_data.is_underwater_flags[idx],
                        phase_data.coastal_types[idx],
                    );

                    if (!self.params.disable_caves and block != .air and block != .water and block != .bedrock) {
                        const wy: f32 = @floatFromInt(y);
                        const should_carve_worm = if (worm_carve_map) |map| map.get(local_x, @intCast(y), local_z) else false;
                        const should_carve_cavity = self.cave_system.shouldCarve(wx, wy, wz, terrain_height_i, phase_data.cave_region_values[idx]);
                        if (should_carve_worm or should_carve_cavity) {
                            block = carvedBlockReplacement(phase_data.is_underwater_flags[idx], y, sea_level);
                        }
                    }
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        return true;
    }

    pub fn generateWormCaves(
        self: *const TerrainShapeGenerator,
        chunk: *Chunk,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        allocator: std.mem.Allocator,
    ) !CaveCarveMap {
        return self.cave_system.generateWormCaves(chunk, surface_heights, allocator);
    }

    pub fn sampleBiomeAtWorld(self: *const TerrainShapeGenerator, wx: i32, wz: i32) BiomeId {
        const wxf: f32 = @floatFromInt(wx);
        const wzf: f32 = @floatFromInt(wz);
        const controls = region_pkg.getBlendedControls(self.getRegionSeed(), wx, wz);
        const column = self.sampleColumnDataWithControlsAndTerrainModifier(wxf, wzf, 0, controls, null);
        return self.selectBiomeForColumn(column, 1);
    }

    pub fn detectBiomeEdge(
        self: *const TerrainShapeGenerator,
        wx: i32,
        wz: i32,
        center_biome: BiomeId,
    ) biome_mod.BiomeEdgeInfo {
        var detected_neighbor: ?BiomeId = null;
        var closest_band: biome_mod.EdgeBand = .none;

        for (biome_mod.EDGE_CHECK_RADII, 0..) |radius, band_idx| {
            const r: i32 = @intCast(radius);
            const offsets = [_][2]i32{ .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r } };
            for (offsets) |off| {
                const neighbor_biome = self.sampleBiomeAtWorld(addWorldOffset(wx, off[0]), addWorldOffset(wz, off[1]));
                if (neighbor_biome != center_biome and biome_mod.needsTransition(center_biome, neighbor_biome)) {
                    detected_neighbor = neighbor_biome;
                    closest_band = @enumFromInt(3 - @as(u2, @intCast(band_idx)));
                    break;
                }
            }
            if (detected_neighbor != null) break;
        }

        return .{
            .base_biome = center_biome,
            .neighbor_biome = detected_neighbor,
            .edge_band = closest_band,
        };
    }

    pub fn getRegionInfo(self: *const TerrainShapeGenerator, world_x: i32, world_z: i32) RegionInfo {
        return region_pkg.getRegion(self.getRegionSeed(), world_x, world_z);
    }

    pub fn isOceanWater(self: *const TerrainShapeGenerator, wx: f32, wz: f32) bool {
        return self.coastal_generator.isOceanWater(&self.noise_sampler, wx, wz);
    }

    pub fn isInlandWater(self: *const TerrainShapeGenerator, wx: f32, wz: f32, height: i32) bool {
        return self.coastal_generator.isInlandWater(&self.noise_sampler, wx, wz, height, self.params.sea_level);
    }
};

fn addWorldOffset(base: i32, offset: anytype) i32 {
    return clampI32(@as(i64, base) + @as(i64, @intCast(offset)));
}

fn isNearCacheCenter(world_x: i32, world_z: i32, cache_center_x: i32, cache_center_z: i32) bool {
    const dx = @as(i64, world_x) - @as(i64, cache_center_x);
    const dz = @as(i64, world_z) - @as(i64, cache_center_z);
    if (dx <= -256 or dx >= 256 or dz <= -256 or dz >= 256) return false;

    return dx * dx + dz * dz < 256 * 256;
}

fn floatToI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    if (value <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (value >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(value);
}

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

fn carvedBlockReplacement(is_underwater_column: bool, y: i32, sea_level: i32) BlockType {
    return if (is_underwater_column and y < sea_level) .water else .air;
}

test "dry caves carve to air below sea level" {
    try std.testing.expectEqual(BlockType.air, carvedBlockReplacement(false, 20, 64));
}

test "underwater caves remain flooded below sea level" {
    try std.testing.expectEqual(BlockType.water, carvedBlockReplacement(true, 20, 64));
}

test "underwater caves above sea level carve to air" {
    try std.testing.expectEqual(BlockType.air, carvedBlockReplacement(true, 80, 64));
}
