//! Terrain generator orchestrator for Luanti-style phased worldgen.
//! Phase responsibilities are delegated to dedicated subsystems.

const std = @import("std");
const sync = @import("sync");
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const RegionMood = region_pkg.RegionMood;
const world_class = @import("world_class.zig");
const ContinentalZone = world_class.ContinentalZone;
const SurfaceType = world_class.SurfaceType;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const regionSizeBlocks = world_core.regionSizeBlocks;
const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
const gen_region = @import("gen_region.zig");
const ClassificationCache = gen_region.ClassificationCache;
const gen_interface = @import("worldgen-api");
const Generator = gen_interface.Generator;
const GeneratorInfo = gen_interface.GeneratorInfo;
const WorldgenError = gen_interface.WorldgenError;
const ColumnInfo = gen_interface.ColumnInfo;
const MapSample = gen_interface.MapSample;
const log = @import("engine-core").log;

const terrain_shape_mod = @import("terrain_shape_generator.zig");
const TerrainShapeGenerator = terrain_shape_mod.TerrainShapeGenerator;
const NoiseSampler = terrain_shape_mod.NoiseSampler;
const HeightSampler = terrain_shape_mod.HeightSampler;
const SurfaceBuilder = terrain_shape_mod.SurfaceBuilder;
const CoastalSurfaceType = terrain_shape_mod.CoastalSurfaceType;
const BiomeSource = @import("biome.zig").BiomeSource;
const BiomeDecorator = @import("biome_decorator.zig").BiomeDecorator;
const lod_coloring = @import("lod_coloring.zig");
const tree_hints = @import("tree_hints.zig");
const LightingComputer = @import("worldgen-common").LightingComputer;
const Mutex = sync.Mutex;

pub const OverworldGenerator = struct {
    pub const INFO = GeneratorInfo{
        .name = "Overworld",
        .description = "Standard terrain with diverse biomes and caves.",
        // Version 4 applies biome transitions independently of cache location.
        // Generated summaries must be refreshed; saved chunks remain authoritative.
        .version = 4,
    };

    allocator: std.mem.Allocator,
    classification_cache: ClassificationCache,
    cache_center_x: i32,
    cache_center_z: i32,
    cache_mutex: Mutex,
    terrain_shape: TerrainShapeGenerator,
    biome_decorator: BiomeDecorator,
    basic_chunks_only: bool,

    /// Distance threshold for cache recentering (blocks).
    pub const CACHE_RECENTER_THRESHOLD: i32 = 512;

    pub const InitParams = struct {
        terrain_shape: terrain_shape_mod.Params = .{},
        basic_chunks_only: bool = false,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider) OverworldGenerator {
        return initWithParams(seed, allocator, decoration_provider, .{});
    }

    pub fn initWithParams(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider, params: InitParams) OverworldGenerator {
        return .{
            .allocator = allocator,
            .classification_cache = ClassificationCache.init(),
            .cache_center_x = 0,
            .cache_center_z = 0,
            .cache_mutex = .{},
            .terrain_shape = TerrainShapeGenerator.initWithParams(seed, params.terrain_shape),
            .biome_decorator = BiomeDecorator.init(seed, decoration_provider),
            .basic_chunks_only = params.basic_chunks_only,
        };
    }

    /// Release owned resources before the struct is destroyed.
    ///
    /// All fields of `OverworldGenerator` are inline value types with no heap
    /// allocations (`classification_cache` is a fixed 256x256 inline grid,
    /// `cache_mutex` is an inline primitive, and `terrain_shape` /
    /// `biome_decorator` own no heap memory), so there is nothing to free here
    /// today. This hook is still invoked by `deinitWrapper` so that any future
    /// heap-owning field is cleaned up through the erased `Generator` interface
    /// instead of leaking silently.
    pub fn deinit(self: *OverworldGenerator) void {
        _ = self;
    }

    pub fn getNoiseSampler(self: *const OverworldGenerator) *const NoiseSampler {
        return self.terrain_shape.getNoiseSampler();
    }

    pub fn getHeightSampler(self: *const OverworldGenerator) *const HeightSampler {
        return self.terrain_shape.getHeightSampler();
    }

    pub fn getSurfaceBuilder(self: *const OverworldGenerator) *const SurfaceBuilder {
        return self.terrain_shape.getSurfaceBuilder();
    }

    pub fn getBiomeSource(self: *const OverworldGenerator) *const BiomeSource {
        return self.terrain_shape.getBiomeSource();
    }

    pub fn getSeed(self: *const OverworldGenerator) u64 {
        return self.terrain_shape.getSeed();
    }

    pub fn getRegionInfo(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionInfo {
        return self.terrain_shape.getRegionInfo(world_x, world_z);
    }

    pub fn getMood(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionMood {
        return self.getRegionInfo(world_x, world_z).mood;
    }

    pub fn getColumnInfo(self: *const OverworldGenerator, wx: f32, wz: f32) ColumnInfo {
        return self.getColumnInfoReduced(wx, wz, 0);
    }

    pub fn getColumnInfoReduced(self: *const OverworldGenerator, wx: f32, wz: f32, reduction: u8) ColumnInfo {
        const column = self.terrain_shape.sampleColumnData(wx, wz, @min(reduction, 4));
        return .{
            .height = column.terrain_height_i,
            .biome = self.selectColumnBiome(column),
            .is_ocean = column.continentalness < self.terrain_shape.getOceanThreshold(),
            .temperature = column.temperature,
            .humidity = column.humidity,
            .continentalness = column.continentalness,
        };
    }

    /// Samples terrain, biome, climate, and water in one terrain-shape query.
    /// Rivers remain encoded by the biome and river mask.
    pub fn getMapSampleReduced(self: *const OverworldGenerator, wx: f32, wz: f32, reduction: u8) MapSample {
        const column = self.terrain_shape.sampleMapColumnData(wx, wz, @min(reduction, 4));
        return .{
            .terrain_height = column.terrain_height_i,
            .biome = self.selectColumnBiome(column),
            .water = classifyMapWater(column),
            .sea_level = self.terrain_shape.getSeaLevel(),
            .temperature = column.temperature,
            .humidity = column.humidity,
            .continentalness = column.continentalness,
            .river_mask = column.river_mask,
            .ridge_mask = column.ridge_mask,
        };
    }

    fn selectColumnBiome(self: *const OverworldGenerator, column: terrain_shape_mod.ColumnData) BiomeId {
        const climate = self.terrain_shape.biome_source.computeClimate(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            CHUNK_SIZE_Y,
        );

        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = 1,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };
        return self.terrain_shape.biome_source.selectBiome(climate, structural, column.river_mask);
    }

    fn classifyMapWater(column: terrain_shape_mod.ColumnData) gen_interface.MapWaterClassification {
        if (!column.is_underwater) return .none;
        // sampleColumnData already computed warped, coast-jittered
        // continentalness. Re-running the full-resolution warp and continent
        // noise here doubled the expensive work for every underwater inland
        // sample without adding useful map detail.
        return if (column.is_ocean) .ocean else .inland;
    }

    pub fn maybeRecenterCache(self: *OverworldGenerator, player_x: i32, player_z: i32) bool {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        const dx = player_x - self.cache_center_x;
        const dz = player_z - self.cache_center_z;
        if (dx * dx + dz * dz > CACHE_RECENTER_THRESHOLD * CACHE_RECENTER_THRESHOLD) {
            self.classification_cache.recenter(player_x, player_z);
            self.cache_center_x = player_x;
            self.cache_center_z = player_z;
            return true;
        }
        return false;
    }

    pub fn generate(self: *OverworldGenerator, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void {
        chunk.generated = false;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

            if (!self.classification_cache.contains(world_x, world_z)) {
                self.classification_cache.recenter(world_x, world_z);
                self.cache_center_x = world_x;
                self.cache_center_z = world_z;
            }
        }

        const phase_data = try self.allocator.create(terrain_shape_mod.ChunkPhaseData);
        defer self.allocator.destroy(phase_data);
        if (!self.terrain_shape.prepareChunkPhaseData(
            phase_data,
            world_x,
            world_z,
            stop_flag,
        )) return;

        self.cache_mutex.lock();
        self.populateClassificationCache(
            world_x,
            world_z,
            &phase_data.surface_heights,
            &phase_data.biome_ids,
            &phase_data.continentalness_values,
            &phase_data.is_ocean_water_flags,
            &phase_data.coastal_types,
        );
        self.cache_mutex.unlock();

        var worm_map_opt = if (self.terrain_shape.params.disable_caves)
            null
        else
            self.terrain_shape.generateWormCaves(
                chunk,
                &phase_data.surface_heights,
                self.allocator,
            ) catch null;
        defer if (worm_map_opt) |*map| map.deinit();
        const worm_map_ptr: ?*const terrain_shape_mod.CaveCarveMap = if (worm_map_opt) |*map| map else null;

        if (!self.terrain_shape.fillChunkBlocks(chunk, phase_data, worm_map_ptr, stop_flag)) return;
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            self.biome_decorator.generateOres(chunk);
            if (stop_flag) |sf| if (sf.*) return;
            self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
            if (stop_flag) |sf| if (sf.*) return;
        }
        LightingComputer.computeSkylight(chunk, self.allocator) catch |err| {
            log.log.errWithTrace("Failed to compute skylight for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
            return err;
        };
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            LightingComputer.computeBlockLight(chunk, self.allocator) catch |err| {
                log.log.errWithTrace("Failed to compute block light for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
                return err;
            };
        }

        chunk.generated = true;
        chunk.dirty = true;
    }

    pub fn generateFeatures(self: *const OverworldGenerator, chunk: *Chunk) void {
        if (self.basic_chunks_only) return;
        self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
    }

    pub fn isOceanWater(self: *const OverworldGenerator, wx: f32, wz: f32) bool {
        return self.terrain_shape.isOceanWater(wx, wz);
    }

    pub fn isInlandWater(self: *const OverworldGenerator, wx: f32, wz: f32, height: i32) bool {
        return self.terrain_shape.isInlandWater(wx, wz, height);
    }

    pub fn getContinentalZone(self: *const OverworldGenerator, c: f32) ContinentalZone {
        return self.terrain_shape.getContinentalZone(c);
    }

    /// Provisional analytical LOD estimates, independent of classification cache
    /// availability. Canonical summaries must capture fully generated chunks.
    pub fn generateHeightmapOnly(self: *const OverworldGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
        if (data.width < 2) return;

        const region_size_i: i32 = @intCast(regionSizeBlocks(lod_level));
        const region_size_f: f32 = @floatFromInt(region_size_i);
        const grid_max: f32 = @floatFromInt(data.width - 1);
        const world_x = region_x * region_size_i;
        const world_z = region_z * region_size_i;
        const sea_level = self.terrain_shape.getSeaLevel();
        // Kept allocated (cheap: empty HashMap, no heap use until first put) so
        // tree hints can be re-enabled per-level in sampleRepresentativeLODColumn
        // without a signature change. Currently unused since compute_tree_hints
        // is false for all LOD levels.
        var tree_hint_cache = TreeHintCache.init(self.allocator);
        defer tree_hint_cache.deinit();

        var gz: u32 = 0;
        while (gz < data.width) : (gz += 1) {
            if (stop_flag) |sf| if (sf.load(.acquire)) return;
            var gx: u32 = 0;
            while (gx < data.width) : (gx += 1) {
                const wx = @as(f32, @floatFromInt(world_x)) + (@as(f32, @floatFromInt(gx)) / grid_max) * region_size_f;
                const wz = @as(f32, @floatFromInt(world_z)) + (@as(f32, @floatFromInt(gz)) / grid_max) * region_size_f;
                const sample = self.sampleRepresentativeLODColumn(wx, wz, region_size_f / grid_max, sea_level, &tree_hint_cache, lod_level);
                data.setGeneratedColumn(gx, gz, sample.height, sample.biome, sample.layers, sample.color, sample.water, sample.lighting, sample.vegetation);
            }
        }
    }

    const RepresentativeLODColumn = struct {
        height: f32,
        biome: BiomeId,
        layers: world_core.LODMaterialLayers,
        color: u32,
        water: world_core.LODWaterState,
        lighting: world_core.LODLightingHint,
        vegetation: world_core.LODVegetationHint,
    };

    const ClassifiedLODSample = struct {
        wx_i: i32,
        wz_i: i32,
        terrain_height: f32,
        terrain_height_i: i32,
        biome: BiomeId,
        surface_block: BlockType,
        render_water_surface: bool,
    };

    const TreeHintChunk = tree_hints.TreeHintChunk;
    const TreeHintCache = std.AutoHashMap(u64, TreeHintChunk);

    fn sampleRepresentativeLODColumn(self: *const OverworldGenerator, wx: f32, wz: f32, cell_span: f32, sea_level: i32, tree_hint_cache: *TreeHintCache, lod_level: LODLevel) RepresentativeLODColumn {
        // Single center sample. The previous 3x3 (9-sample) grid sampled a
        // sub-block neighborhood (sample_radius ~= cell_span/2 ~= 0.5-1.3
        // blocks), so 8 of 9 samples were nearly co-located and returned
        // near-identical results — ~9x cost for negligible anti-aliasing.
        // One sample cuts LOD heightmap generation ~9x (the dominant LOD
        // loading bottleneck; was producing <1 region/sec/worker).
        const sample_offsets = [_]f32{0.0};
        const sample_radius = @min(cell_span * 0.5, 48.0);
        // Exact tree-coverage hints are computed via computeChunkTreeHints, which
        // evaluates a full 256-column chunk of biome/decoration/tree noise per
        // cache miss. LOD columns span many chunks with little reuse, so tree
        // hints dominated gen cost (~30x the heightmap on lod3: 5.3s -> 0.04s
        // per region). Keep that path disabled by default and use a cheap
        // biome/tree-registry estimate so distant forests still have canopy
        // geometry without regressing generation latency.
        const compute_exact_tree_hints: bool = switch (lod_level) {
            .lod0, .lod1, .lod2, .lod3, .lod4 => false,
        };

        var block_counts = [_]u32{0} ** world_core.MAX_BLOCK_TYPES;
        var biome_counts = [_]u32{0} ** 256;
        var color_r: u32 = 0;
        var color_g: u32 = 0;
        var color_b: u32 = 0;
        var terrain_height_sum: f32 = 0.0;
        var terrain_min: f32 = std.math.floatMax(f32);
        var terrain_max: f32 = -std.math.floatMax(f32);
        var water_depth_sum: f32 = 0.0;
        var water_samples: u32 = 0;
        var total_samples: u32 = 0;

        for (sample_offsets) |oz| {
            for (sample_offsets) |ox| {
                const sample = self.classifyLODSample(wx + ox * sample_radius, wz + oz * sample_radius, sea_level);
                const block_index = @intFromEnum(sample.surface_block);
                if (block_index < block_counts.len) block_counts[block_index] += 1;
                biome_counts[@intFromEnum(sample.biome)] += 1;

                const color = lod_coloring.colorForSample(sample.biome, sample.surface_block);
                color_r += (color >> 16) & 0xFF;
                color_g += (color >> 8) & 0xFF;
                color_b += color & 0xFF;
                terrain_height_sum += sample.terrain_height;
                terrain_min = @min(terrain_min, sample.terrain_height);
                terrain_max = @max(terrain_max, sample.terrain_height);
                total_samples += 1;

                if (sample.render_water_surface) {
                    water_samples += 1;
                    water_depth_sum += @floatFromInt(@max(sea_level - sample.terrain_height_i, 0));
                }
            }
        }

        const water_coverage = if (total_samples == 0) 0.0 else @as(f32, @floatFromInt(water_samples)) / @as(f32, @floatFromInt(total_samples));
        const dominant_block = dominantBlock(block_counts);
        const dominant_biome = dominantBiome(biome_counts);
        const render_water_surface = water_coverage >= 0.25;
        const surface_block: BlockType = if (render_water_surface) .water else dominant_block;
        const avg_height = terrain_height_sum / @as(f32, @floatFromInt(@max(total_samples, 1)));
        const terrain_range = @max(terrain_max - terrain_min, 0.0);
        const land_height = if (terrain_range > 12.0)
            avg_height + terrain_range * 0.35
        else
            avg_height;
        const height = if (render_water_surface)
            @as(f32, @floatFromInt(sea_level))
        else
            land_height;
        const avg_color = packAverageColor(color_r, color_g, color_b, @max(total_samples, 1));
        const vegetation_hint = if (render_water_surface)
            world_core.LODVegetationHint.empty
        else if (compute_exact_tree_hints)
            self.actualTreeHintInArea(wx, wz, sample_radius, dominant_biome, tree_hint_cache)
        else
            tree_hints.estimatedTreeHintForBiome(dominant_biome, wx, wz, self.terrain_shape.getSeed());
        return .{
            .height = height,
            .biome = dominant_biome,
            .layers = makeMaterialLayers(surface_block, dominant_biome, render_water_surface),
            .color = avg_color,
            .water = .{
                .is_surface = render_water_surface,
                .surface_height = if (render_water_surface) @floatFromInt(sea_level) else 0.0,
                .depth = if (water_samples == 0) 0.0 else water_depth_sum / @as(f32, @floatFromInt(water_samples)),
                .coverage = water_coverage,
            },
            .lighting = makeLightingHint(render_water_surface),
            .vegetation = vegetation_hint,
        };
    }

    fn actualTreeHintAtColumn(self: *const OverworldGenerator, target_wx: i32, target_wz: i32, cache: *TreeHintCache) world_core.LODVegetationHint {
        const chunk_x = @divFloor(target_wx, @as(i32, @intCast(CHUNK_SIZE_X)));
        const chunk_z = @divFloor(target_wz, @as(i32, @intCast(CHUNK_SIZE_Z)));
        const local_x: u32 = @intCast(@mod(target_wx, @as(i32, @intCast(CHUNK_SIZE_X))));
        const local_z: u32 = @intCast(@mod(target_wz, @as(i32, @intCast(CHUNK_SIZE_Z))));
        const idx = local_x + local_z * CHUNK_SIZE_X;
        const key = tree_hints.cacheKey(chunk_x, chunk_z);

        if (cache.get(key)) |hints| return hints[idx];

        const hints = self.computeChunkTreeHints(chunk_x, chunk_z);
        const result = hints[idx];
        cache.put(key, hints) catch |err| {
            log.log.warn("TreeHintCache: failed to cache tree hints for chunk ({}, {}): {}", .{ chunk_x, chunk_z, err });
        };
        return result;
    }

    fn actualTreeHintInArea(self: *const OverworldGenerator, center_wx: f32, center_wz: f32, radius: f32, dominant_biome: BiomeId, cache: *TreeHintCache) world_core.LODVegetationHint {
        const min_x: i32 = @intFromFloat(@floor(center_wx - radius));
        const max_x: i32 = @intFromFloat(@ceil(center_wx + radius));
        const min_z: i32 = @intFromFloat(@floor(center_wz - radius));
        const max_z: i32 = @intFromFloat(@ceil(center_wz + radius));
        const min_chunk_x = @divFloor(min_x, @as(i32, @intCast(CHUNK_SIZE_X)));
        const max_chunk_x = @divFloor(max_x, @as(i32, @intCast(CHUNK_SIZE_X)));
        const min_chunk_z = @divFloor(min_z, @as(i32, @intCast(CHUNK_SIZE_Z)));
        const max_chunk_z = @divFloor(max_z, @as(i32, @intCast(CHUNK_SIZE_Z)));

        var tree_count: u32 = 0;
        var height_sum: f32 = 0.0;
        var offset_x_sum: f32 = 0.0;
        var offset_z_sum: f32 = 0.0;
        var best = world_core.LODVegetationHint.empty;

        var chunk_z = min_chunk_z;
        while (chunk_z <= max_chunk_z) : (chunk_z += 1) {
            var chunk_x = min_chunk_x;
            while (chunk_x <= max_chunk_x) : (chunk_x += 1) {
                const key = tree_hints.cacheKey(chunk_x, chunk_z);
                const hints = blk: {
                    if (cache.get(key)) |cached| break :blk cached;
                    const computed = self.computeChunkTreeHints(chunk_x, chunk_z);
                    cache.put(key, computed) catch |err| {
                        log.log.warn("TreeHintCache: failed to cache tree hints for chunk ({}, {}): {}", .{ chunk_x, chunk_z, err });
                    };
                    break :blk computed;
                };
                const chunk_world_x = chunk_x * @as(i32, @intCast(CHUNK_SIZE_X));
                const chunk_world_z = chunk_z * @as(i32, @intCast(CHUNK_SIZE_Z));

                var lz: u32 = 0;
                while (lz < CHUNK_SIZE_Z) : (lz += 1) {
                    const wz = chunk_world_z + @as(i32, @intCast(lz));
                    if (wz < min_z or wz > max_z) continue;
                    var lx: u32 = 0;
                    while (lx < CHUNK_SIZE_X) : (lx += 1) {
                        const wx = chunk_world_x + @as(i32, @intCast(lx));
                        if (wx < min_x or wx > max_x) continue;
                        const hint = hints[lx + lz * CHUNK_SIZE_X];
                        if (hint.tree_coverage <= 0.0) continue;
                        tree_count += 1;
                        height_sum += hint.avg_tree_height;
                        offset_x_sum += @as(f32, @floatFromInt(wx)) - center_wx;
                        offset_z_sum += @as(f32, @floatFromInt(wz)) - center_wz;
                        if (best.tree_coverage <= 0.0) best = hint;
                    }
                }
            }
        }

        if (tree_count == 0) return world_core.LODVegetationHint.empty;

        const blocks = if (best.leaves == .air) tree_hints.blocksForBiome(dominant_biome) else tree_hints.TreeBlocks{ .trunk = best.trunk, .leaves = best.leaves };
        const area = @max(1.0, (radius * 2.0 + 1.0) * (radius * 2.0 + 1.0));
        return .{
            .tree_coverage = std.math.clamp(@as(f32, @floatFromInt(tree_count)) / area * 24.0, 0.0, 1.0),
            .avg_tree_height = height_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_x = offset_x_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_z = offset_z_sum / @as(f32, @floatFromInt(tree_count)),
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    fn computeChunkTreeHints(self: *const OverworldGenerator, chunk_x: i32, chunk_z: i32) TreeHintChunk {
        const world_x = chunk_x * @as(i32, @intCast(CHUNK_SIZE_X));
        const world_z = chunk_z * @as(i32, @intCast(CHUNK_SIZE_Z));
        return tree_hints.computeChunkTreeHints(.{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .world_x = world_x,
            .world_z = world_z,
            .sea_level = self.terrain_shape.getSeaLevel(),
            .terrain_region_seed = self.terrain_shape.getRegionSeed(),
            .decorator_region_seed = self.biome_decorator.region_seed,
            .noise_sampler = self.terrain_shape.getNoiseSampler(),
            .classify_context = self,
            .classify_fn = classifyTreeHintSample,
        });
    }

    fn classifyTreeHintSample(context: *const anyopaque, wx: f32, wz: f32, sea_level: i32, controls: region_pkg.RegionControlCorners) tree_hints.ClassifiedSample {
        const self: *const OverworldGenerator = @ptrCast(@alignCast(context));
        _ = controls;
        const sample = self.classifyLODSample(wx, wz, sea_level);
        return .{
            .biome = sample.biome,
            .surface_block = sample.surface_block,
            .terrain_height_i = sample.terrain_height_i,
        };
    }

    fn classifyLODSample(self: *const OverworldGenerator, wx: f32, wz: f32, sea_level: i32) ClassifiedLODSample {
        const wx_i: i32 = @intFromFloat(@floor(wx));
        const wz_i: i32 = @intFromFloat(@floor(wz));
        const column = self.sampleFullDetailColumnData(wx, wz, wx_i, wz_i);
        const render_water_surface = column.terrain_height_i < sea_level;

        // Coarse cache cells retain one pre-dither column's classification, not
        // this column's final biome/material. Mixing that with analytical heights
        // made provisional LOD change as full chunks arrived or the cache moved.
        const climate = biome_mod.computeClimateParams(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            sea_level,
            CHUNK_SIZE_Y,
        );

        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = 0,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };

        const biome_id = biome_mod.selectBiomeWithConstraintsAndRiver(climate, structural, column.river_mask);
        return .{
            .wx_i = wx_i,
            .wz_i = wz_i,
            .terrain_height = column.terrain_height,
            .terrain_height_i = column.terrain_height_i,
            .biome = biome_id,
            .surface_block = self.getSurfaceBlock(biome_id, column.terrain_height_i, sea_level, render_water_surface),
            .render_water_surface = render_water_surface,
        };
    }

    /// Samples terrain with the same chunk-local region controls as
    /// `prepareChunkPhaseData`. Canonical blended controls can select a very
    /// different terrain height and place an LOD surface above the real chunk.
    fn sampleFullDetailColumnData(self: *const OverworldGenerator, wx: f32, wz: f32, wx_i: i32, wz_i: i32) terrain_shape_mod.ColumnData {
        const chunk_x = @divFloor(wx_i, CHUNK_SIZE_X) * CHUNK_SIZE_X;
        const chunk_z = @divFloor(wz_i, CHUNK_SIZE_Z) * CHUNK_SIZE_Z;
        const controls = region_pkg.RegionControlCorners.init(
            self.terrain_shape.getRegionSeed(),
            chunk_x,
            chunk_z,
            chunk_x + CHUNK_SIZE_X - 1,
            chunk_z + CHUNK_SIZE_Z - 1,
        );
        return self.terrain_shape.sampleColumnDataWithControls(wx, wz, 0, controls.sample(wx_i, wz_i));
    }

    fn dominantBlock(counts: [world_core.MAX_BLOCK_TYPES]u32) BlockType {
        var best_index: usize = @intFromEnum(BlockType.grass);
        var best_count: u32 = 0;
        for (counts, 0..) |count, i| {
            if (count > best_count) {
                best_index = i;
                best_count = count;
            }
        }
        return @enumFromInt(best_index);
    }

    fn dominantBiome(counts: [256]u32) BiomeId {
        var best_index: usize = @intFromEnum(BiomeId.plains);
        var best_count: u32 = 0;
        for (counts, 0..) |count, i| {
            if (count > best_count) {
                best_index = i;
                best_count = count;
            }
        }
        return @enumFromInt(best_index);
    }

    fn packAverageColor(r_sum: u32, g_sum: u32, b_sum: u32, count: u32) u32 {
        const r = r_sum / count;
        const g = g_sum / count;
        const b = b_sum / count;
        return (r << 16) | (g << 8) | b;
    }

    fn makeMaterialLayers(surface_block: BlockType, biome_id: BiomeId, render_water_surface: bool) world_core.LODMaterialLayers {
        if (render_water_surface and (surface_block == .ice or surface_block == .packed_ice)) {
            return .{
                .surface = surface_block,
                .subsurface = .water,
                .foundation = .stone,
            };
        }

        if (render_water_surface) {
            const floor_block: BlockType = switch (biome_id) {
                .deep_ocean, .frozen_ocean, .cold_ocean, .stony_shore, .frozen_river => .gravel,
                .ocean, .river, .beach, .snowy_beach => .sand,
                else => .dirt,
            };
            return .{
                .surface = .water,
                .subsurface = floor_block,
                .foundation = .stone,
            };
        }

        return .{
            .surface = surface_block,
            .subsurface = registryFillerBlock(biome_id),
            .foundation = .stone,
        };
    }

    fn registrySurfaceBlock(biome_id: BiomeId) BlockType {
        return biome_mod.getBiomeDefinition(biome_id).surface.top;
    }

    fn registryFillerBlock(biome_id: BiomeId) BlockType {
        return biome_mod.getBiomeDefinition(biome_id).surface.filler;
    }

    fn surfaceTypeForBlock(block: BlockType) SurfaceType {
        return switch (block) {
            .sand, .red_sand => .sand,
            .snow_block, .ice, .packed_ice, .blue_ice => .snow,
            .stone, .cobblestone, .mossy_cobblestone => .stone,
            .gravel => .rock,
            .dirt, .coarse_dirt, .rooted_dirt, .podzol, .mud, .mycelium => .dirt,
            .water => .water_shallow,
            else => .grass,
        };
    }

    fn makeLightingHint(render_water_surface: bool) world_core.LODLightingHint {
        return .{
            .sky_light = 15,
            .block_light = 0,
            .ambient_occlusion = if (render_water_surface) 0.92 else 1.0,
        };
    }

    fn getSurfaceBlock(_: *const OverworldGenerator, biome_id: BiomeId, height: i32, sea_level: i32, render_water_surface: bool) BlockType {
        if (render_water_surface and biome_id == .frozen_ocean) return .ice;
        if (render_water_surface and biome_id == .frozen_river) return .ice;
        if (render_water_surface or height < sea_level) return .water;
        return registrySurfaceBlock(biome_id);
    }

    fn populateClassificationCache(
        self: *OverworldGenerator,
        world_x: i32,
        world_z: i32,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        continentalness_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
        is_ocean_water_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool,
        coastal_types: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType,
    ) void {
        const sea_level = self.terrain_shape.getSeaLevel();
        const region_seed = self.terrain_shape.getRegionSeed();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx = world_x + @as(i32, @intCast(local_x));
                const wz = world_z + @as(i32, @intCast(local_z));
                if (self.classification_cache.has(wx, wz)) continue;

                const biome_id = biome_ids[idx];
                const height = surface_heights[idx];
                const continentalness = continentalness_values[idx];
                const is_ocean = is_ocean_water_flags[idx];
                const coastal_type = coastal_types[idx];

                const surface_type = self.deriveSurfaceTypeInternal(
                    biome_id,
                    height,
                    sea_level,
                    is_ocean,
                    coastal_type,
                );

                const continental_zone = self.terrain_shape.getContinentalZone(continentalness);
                const region_info = region_pkg.getRegion(region_seed, wx, wz);
                const path_info = region_pkg.getPathInfo(region_seed, wx, wz, region_info);

                self.classification_cache.put(wx, wz, .{
                    .biome_id = biome_id,
                    .surface_type = surface_type,
                    .is_water = height < sea_level,
                    .continental_zone = continental_zone,
                    .region_role = region_info.role,
                    .path_type = path_info.path_type,
                });
            }
        }
    }

    fn deriveSurfaceTypeInternal(
        _: *const OverworldGenerator,
        biome_id: BiomeId,
        height: i32,
        sea_level: i32,
        is_ocean: bool,
        coastal_type: CoastalSurfaceType,
    ) SurfaceType {
        if (is_ocean and height < sea_level - 30) return .water_deep;
        if (is_ocean and height < sea_level) return .water_shallow;

        switch (coastal_type) {
            .sand_beach => return .sand,
            .gravel_beach => return .rock,
            .cliff => return .stone,
            .none => {},
        }

        const surface_block = registrySurfaceBlock(biome_id);
        if ((biome_id == .mountains or biome_id == .jagged_peaks or biome_id == .stony_peaks) and height > 120) return .rock;
        return surfaceTypeForBlock(surface_block);
    }

    pub fn generator(self: *OverworldGenerator) Generator {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
            .info = INFO,
        };
    }

    const VTABLE = Generator.VTable{
        .generate = generateWrapper,
        .generateHeightmapOnly = generateHeightmapOnlyWrapper,
        .maybeRecenterCache = maybeRecenterCacheWrapper,
        .getSeed = getSeedWrapper,
        .getRegionInfo = getRegionInfoWrapper,
        .getColumnInfo = getColumnInfoWrapper,
        .getColumnInfoReduced = getColumnInfoReducedWrapper,
        .getMapSampleReduced = getMapSampleReducedWrapper,
        .column_info_thread_safe = true,
        .deinit = deinitWrapper,
    };

    fn generateWrapper(ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) WorldgenError!void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        try self.generate(chunk, stop_flag);
    }

    fn generateHeightmapOnlyWrapper(ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
        const self: *const OverworldGenerator = @ptrCast(@alignCast(ptr));
        self.generateHeightmapOnly(data, region_x, region_z, lod_level, stop_flag);
    }

    fn maybeRecenterCacheWrapper(ptr: *anyopaque, player_x: i32, player_z: i32) bool {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.maybeRecenterCache(player_x, player_z);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn getColumnInfoReducedWrapper(ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) ColumnInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfoReduced(wx, wz, reduction);
    }

    fn getMapSampleReducedWrapper(ptr: *anyopaque, wx: f32, wz: f32, reduction: u8) MapSample {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getMapSampleReduced(wx, wz, reduction);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }
};

test "LOD classification matches full-detail chunk controls and sea-level water" {
    var gen = OverworldGenerator.initWithParams(12345, std.testing.allocator, testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    const sea_level = gen.terrain_shape.getSeaLevel();
    const positions = [_][2]i32{
        .{ -1025, -1025 },
        .{ -513, 511 },
        .{ -1, 0 },
        .{ 0, 0 },
        .{ 511, 513 },
        .{ 1025, -1025 },
    };
    for (positions) |position| {
        const wx: f32 = @floatFromInt(position[0]);
        const wz: f32 = @floatFromInt(position[1]);
        const chunk_x = @divFloor(position[0], CHUNK_SIZE_X) * CHUNK_SIZE_X;
        const chunk_z = @divFloor(position[1], CHUNK_SIZE_Z) * CHUNK_SIZE_Z;
        const controls = region_pkg.RegionControlCorners.init(
            gen.terrain_shape.getRegionSeed(),
            chunk_x,
            chunk_z,
            chunk_x + CHUNK_SIZE_X - 1,
            chunk_z + CHUNK_SIZE_Z - 1,
        );
        const column = gen.terrain_shape.sampleColumnDataWithControls(wx, wz, 0, controls.sample(position[0], position[1]));
        const lod_sample = gen.classifyLODSample(wx, wz, sea_level);
        try std.testing.expectEqual(column.terrain_height_i, lod_sample.terrain_height_i);
        try std.testing.expectEqual(column.terrain_height_i < sea_level, lod_sample.render_water_surface);
    }
}

test "LOD surface height matches generated full-detail terrain at chunk origin" {
    var gen = OverworldGenerator.initWithParams(12345, std.testing.allocator, testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    var chunk = Chunk.init(0, 0);
    try gen.generate(&chunk, null);

    var top_solid_y: i32 = 0;
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y >= 0) : (y -= 1) {
        const block = chunk.getBlock(0, @intCast(y), 0);
        if (block != .air and block != .water) {
            top_solid_y = y;
            break;
        }
    }

    const lod_sample = gen.classifyLODSample(0.0, 0.0, gen.terrain_shape.getSeaLevel());
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(top_solid_y)), lod_sample.terrain_height, 1.0);
}

fn testDecorationProvider() DecorationProvider {
    const NoopProvider = struct {
        fn decorate(_: ?*anyopaque, _: DecorationProvider.DecorationContext) void {}

        const VTABLE = DecorationProvider.VTable{
            .decorate = decorate,
        };
    };

    return .{ .ptr = null, .vtable = &NoopProvider.VTABLE };
}

test "OverworldGenerator propagates phase allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var gen = OverworldGenerator.initWithParams(0, failing.allocator(), testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    var chunk = Chunk.init(0, 0);
    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}

test "OverworldGenerator propagates lighting allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var gen = OverworldGenerator.initWithParams(0, failing.allocator(), testDecorationProvider(), .{
        .terrain_shape = .{ .disable_caves = true },
        .basic_chunks_only = true,
    });
    defer gen.deinit();

    var chunk = Chunk.init(0, 0);
    try std.testing.expectError(error.OutOfMemory, gen.generate(&chunk, null));
    try std.testing.expect(!chunk.generated);
}
