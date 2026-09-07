const std = @import("std");

const TextureAtlas = @import("engine-assets").TextureAtlas;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const rhi_types = @import("engine-rhi").rhi_types;
const Chunk = @import("world-core").Chunk;
const world_core = @import("world-core");
const lod_manager = @import("lod_manager.zig");
const LODManager = lod_manager.LODManager;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODStats = lod_manager.LODStats;
const LODProfilingCollector = @import("lod_stats.zig").LODProfilingCollector;
const MAX_LOD_REGIONS = @import("lod_manager_context.zig").MAX_LOD_REGIONS;
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODChunk = lod_chunk.LODChunk;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;
const LODColumnProvenance = world_core.LODColumnProvenance;
const regionSizeBlocks = world_core.regionSizeBlocks;
const world_worldgen = @import("world-worldgen");
const ColumnInfo = world_worldgen.ColumnInfo;
const Generator = world_worldgen.Generator;
const RegionInfo = world_worldgen.region.RegionInfo;

fn lodGeneratorFromGenerator(generator: Generator) LODGenerator {
    return .{
        .ptr = generator.ptr,
        .generate_heightmap_only = generator.vtable.generateHeightmapOnly,
        .maybe_recenter_cache = generator.vtable.maybeRecenterCache,
        .seed = generator.getSeed(),
        .identity_hash = std.hash.Wyhash.hash(0, generator.info.name),
        .version = generator.info.version,
    };
}

test "LODManager initialization" {
    const allocator = std.testing.allocator;

    const MockState = struct {
        buffer_created: bool = false,
        buffer_destroyed: bool = false,
        prepare_saw_stats: bool = false,
        prepare_saw_profiling: bool = false,
    };

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) error{OutOfMemory}!void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) ColumnInfo {
            return undefined;
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator", .version = 1 },
    };

    var config = LODConfig{
        .radii = .{ 8, 16, 32, 64, 128 },
    };

    var mock_state = MockState{};
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, ctx: *anyopaque) void {
                const state: *MockState = @ptrCast(@alignCast(ctx));
                state.buffer_destroyed = true;
            }
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&mock_state),
    };

    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32, _: lod_gpu.LODRenderLayer, _: ?*LODStats, _: ?*LODProfilingCollector) void {}
        }.f,
        .prepare_frame_fn = struct {
            fn f(ctx: *anyopaque, _: u64, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: ?i32, _: i32, stats: ?*LODStats, profiling: ?*LODProfilingCollector) void {
                const state: *MockState = @ptrCast(@alignCast(ctx));
                state.prepare_saw_stats = stats != null;
                state.prepare_saw_profiling = profiling != null;
            }
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&mock_state),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, lodGeneratorFromGenerator(mock_gen), &mock_atlas);
    mgr.cleanup_covered_regions = false;

    const stats = mgr.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.totalGenerating());
    mgr.profiling.enabled = true;
    mgr.prepareFrame(1, Mat4.identity, Vec3.zero, null, null, null, mgr.config.getChunkRenderRadius());
    try std.testing.expect(mock_state.prepare_saw_stats);
    try std.testing.expect(mock_state.prepare_saw_profiling);

    mgr.deinit();

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(5));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(12));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(24));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(50));
}

test "LODManager end-to-end covered cleanup" {
    const allocator = std.testing.allocator;

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) error{OutOfMemory}!void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) ColumnInfo {
            return .{ .height = 0, .biome = .plains, .is_ocean = false, .temperature = 0, .humidity = 0, .continentalness = 0 };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator", .version = 1 },
    };

    var config = LODConfig{
        .radii = .{ 2, 4, 8, 16, 32 },
    };

    var noop_ctx: u8 = 0;
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&noop_ctx),
    };

    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32, _: lod_gpu.LODRenderLayer, _: ?*LODStats, _: ?*LODProfilingCollector) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&noop_ctx),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, lodGeneratorFromGenerator(mock_gen), &mock_atlas);
    mgr.cleanup_covered_regions = false;
    defer mgr.deinit();

    try mgr.update(Vec3.zero, Vec3.zero, null, null);

    const Checker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    const key = lod_chunk.LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const chunk = try allocator.create(LODChunk);
    chunk.* = LODChunk.init(1, 0, .lod1);
    chunk.state = .renderable;
    try mgr.regions[1].put(key, chunk);

    const mesh = try allocator.create(LODMesh);
    mesh.* = LODMesh.init(allocator, .lod1);
    mesh.ready = true;
    mesh.vertex_count = 100;
    try mgr.meshes[1].put(key, mesh);

    var dummy: u8 = 0;
    try mgr.update(Vec3.zero, Vec3.zero, Checker.isLoaded, &dummy);
    try std.testing.expect(mgr.regions[1].contains(key));

    const FullChecker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };

    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);

    try std.testing.expect(mgr.regions[1].contains(key));
}

test "LODStats aggregation" {
    var stats = LODStats{};
    stats.recordState(1, .renderable);
    stats.recordState(1, .renderable);
    stats.recordState(2, .generating);

    try std.testing.expectEqual(@as(u32, 2), stats.loaded[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.generating[2]);
    try std.testing.expectEqual(@as(u32, 2), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 1), stats.totalGenerating());

    stats.addMemory(2 * 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 2), stats.memory_used_mb);
    stats.profiling.enabled = true;

    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.memory_used_mb);
    try std.testing.expect(!stats.profiling.enabled);
}

test "LODManager constants" {
    try std.testing.expect(MAX_LOD_REGIONS > 0);
    try std.testing.expect(LODLevel.count >= 2);
}

test "LODManager preserves the CPU heightfield fallback for far LODs" {
    var config = LODConfig{ .mesh_path = .qem };
    const manager = try buildIngestionManager(std.testing.allocator, &config);
    defer manager.deinit();

    // Far LODs must not inherit an optional mesh path. They retain the
    // CPU-expanded heightfield route when a future renderer path is unavailable.
    try std.testing.expectEqual(@import("engine-rhi").LODMeshPath.heightfield, manager.effectiveMeshPath(.lod3));
    try std.testing.expectEqual(@import("engine-rhi").LODMeshPath.heightfield, manager.effectiveMeshPath(.lod4));
}

// ---------------------------------------------------------------------------
// Chunk-derived LOD ingestion (issue #752 Phase 2)
// ---------------------------------------------------------------------------

/// Minimal manager + mock glue shared by the ingestion tests. The caller owns
/// `config` (it must outlive the returned manager, since ILODConfig references it).
fn buildIngestionManager(allocator: std.mem.Allocator, config: *LODConfig) !*LODManager {
    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) error{OutOfMemory}!void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) ColumnInfo {
            return .{ .height = 0, .biome = .plains, .is_ocean = false, .temperature = 0, .humidity = 0, .continentalness = 0 };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator", .version = 1 },
    };

    var noop_ctx: u8 = 0;
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&noop_ctx),
    };

    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32, _: lod_gpu.LODRenderLayer, _: ?*LODStats, _: ?*LODProfilingCollector) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&noop_ctx),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    const mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, lodGeneratorFromGenerator(mock_gen), &mock_atlas);
    mgr.cleanup_covered_regions = false;
    return mgr;
}

/// Place a region at (rx,rz,lod) with simplified data, pre-seeding cell
/// (gx,gz) as worldgen so ingestion can be observed upgrading it.
fn placeSimplifiedRegion(mgr: *LODManager, allocator: std.mem.Allocator, rx: i32, rz: i32, lod: LODLevel) !*LODChunk {
    const key = lod_chunk.LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };
    const lchunk = try allocator.create(LODChunk);
    lchunk.* = LODChunk.init(rx, rz, lod);
    lchunk.data = .{ .simplified = try LODSimplifiedData.init(allocator, lod) };
    lchunk.state = .renderable;
    try mgr.regions[@intFromEnum(lod)].put(key, lchunk);
    return lchunk;
}

test "ingestChunk upgrades worldgen region data and schedules a remesh" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 } };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    // Pre-seed cell (0,0) as worldgen at height 10.
    lchunk.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .{ .is_surface = false, .surface_height = 0, .depth = 0, .coverage = 0 }, .{ .sky_light = 15, .block_light = 0, .ambient_occlusion = 1.0 }, .{ .tree_coverage = 0, .avg_tree_height = 0, .offset_x = 0, .offset_z = 0, .trunk = .air, .leaves = .air });
    try std.testing.expectEqual(LODColumnProvenance.worldgen, lchunk.data.simplified.getColumnProvenance(0, 0));

    // Real chunk at (0,0) with terrain at y=64.
    var chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 64) : (y += 1) {
        const block: world_core.BlockType = if (y == 64) .grass else if (y > 60) .dirt else .stone;
        chunk.setBlock(0, y, 0, block);
    }

    mgr.ingestChunk(0, 0, &chunk, .chunk_derived);

    try std.testing.expectEqual(@as(f32, 64.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.chunk_derived, lchunk.data.simplified.getColumnProvenance(0, 0));
    // A renderable region is flipped back to .generated to trigger a remesh.
    try std.testing.expectEqual(lod_chunk.LODState.generated, lchunk.state);
    try std.testing.expect(lchunk.dirty);
    try std.testing.expect(lchunk.store_dirty);
}

test "ingestChunk defers while a cancelled worker still pins source data" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 } };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    lchunk.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .empty, .daylight, .empty);
    lchunk.state = .generated;
    lchunk.pin();
    defer lchunk.unpin();

    var chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 64) : (y += 1) chunk.setBlock(0, y, 0, .stone);

    mgr.ingestChunk(0, 0, &chunk, .edited);

    try std.testing.expectEqual(@as(f32, 10.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.worldgen, lchunk.data.simplified.getColumnProvenance(0, 0));
    try std.testing.expect(mgr.ingestion_queue.pending_ingestions.items.len > 0);
}

test "ingestChunk into generated source invalidates stale mesh transition" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 } };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    lchunk.state = .generated;
    const old_token = lchunk.job_token;

    var chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 64) : (y += 1) chunk.setBlock(0, y, 0, .stone);

    mgr.ingestChunk(0, 0, &chunk, .edited);

    try std.testing.expectEqual(old_token + 1, lchunk.job_token);
    const token = mgr.transition_tokens.pop() orelse return error.ExpectedMeshTransition;
    try std.testing.expectEqual(@import("lod_manager_context.zig").LifecycleStage.mesh, token.stage);
    try std.testing.expectEqual(lchunk.job_token, token.job_token);
    try std.testing.expectEqual(lchunk.source_revision, token.source_revision);
}

test "ingestChunk provenance authority: edited beats chunk_derived, worldgen cannot overwrite" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 } };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);

    var derived_chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 50) : (y += 1) chunk_derived_setBlock(&derived_chunk, 0, y, 0, .stone);

    // 1. chunk_derived sets height to 50.
    mgr.ingestChunk(0, 0, &derived_chunk, .chunk_derived);
    try std.testing.expectEqual(@as(f32, 50.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.chunk_derived, lchunk.data.simplified.getColumnProvenance(0, 0));

    // 2. An edit raises the column to y=80 with edited provenance.
    var edited_chunk = Chunk.init(0, 0);
    var ey: u32 = 0;
    while (ey <= 80) : (ey += 1) chunk_derived_setBlock(&edited_chunk, 0, ey, 0, .stone);
    mgr.ingestChunk(0, 0, &edited_chunk, .edited);
    try std.testing.expectEqual(@as(f32, 80.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.edited, lchunk.data.simplified.getColumnProvenance(0, 0));

    // 3. A later worldgen regeneration must NOT overwrite the edited column.
    var regen_chunk = Chunk.init(0, 0);
    var ry: u32 = 0;
    while (ry <= 5) : (ry += 1) chunk_derived_setBlock(&regen_chunk, 0, ry, 0, .stone);
    mgr.ingestChunk(0, 0, &regen_chunk, .worldgen);
    try std.testing.expectEqual(@as(f32, 80.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.edited, lchunk.data.simplified.getColumnProvenance(0, 0));
}

test "markChunkEdited coalesces and re-ingests via the resolver on update" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 } };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);

    // Resolver returns a fixed edited chunk for any coordinate.
    const ResolverState = struct { chunk: *const Chunk };
    var edited_chunk = Chunk.init(0, 0);
    var ey: u32 = 0;
    while (ey <= 90) : (ey += 1) chunk_derived_setBlock(&edited_chunk, 0, ey, 0, .stone);
    var rstate = ResolverState{ .chunk = &edited_chunk };
    const resolve_fn = struct {
        fn f(ptr: *anyopaque, cx: i32, cz: i32) ?*const Chunk {
            _ = cx;
            _ = cz;
            const s: *ResolverState = @ptrCast(@alignCast(ptr));
            return s.chunk;
        }
    }.f;
    mgr.setChunkResolver(.{ .ptr = @ptrCast(&rstate), .resolve_fn = resolve_fn });

    // Queue several rapid edits to the same chunk; they should coalesce.
    mgr.markChunkEdited(0, 0);
    mgr.markChunkEdited(0, 0);
    mgr.markChunkEdited(0, 0);

    // update() drains the edit queue on its cooldown (starts expired).
    for (0..4) |_| try mgr.update(Vec3.zero, Vec3.zero, null, null);

    try std.testing.expectEqual(@as(f32, 90.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.edited, lchunk.data.simplified.getColumnProvenance(0, 0));

    // Explicit save points bypass the coalescing cooldown and persist edits in
    // the same transaction rather than losing them to a later frame.
    edited_chunk.setBlock(0, 90, 0, .air);
    lchunk.setState(.renderable);
    if (lchunk.isPinned()) lchunk.unpin();
    mgr.markChunkEdited(0, 0);
    mgr.ingestion_queue.edit_cooldown = 1.0;
    mgr.flushEditedChunksNow();
    try std.testing.expectEqual(@as(f32, 89.0), lchunk.data.simplified.getHeight(0, 0));
}

test "edited chunk unload consumes queued work before resolver removal" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 }, .active_lod_count = 2 };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    lchunk.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .empty, .daylight, .empty);

    var edited_chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 72) : (y += 1) chunk_derived_setBlock(&edited_chunk, 0, y, 0, .stone);
    mgr.markChunkEdited(0, 0);

    try std.testing.expectEqual(@as(u8, 0), mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, false));
    try std.testing.expectEqual(@as(f32, 72.0), lchunk.data.simplified.getHeight(0, 0));
    try std.testing.expectEqual(LODColumnProvenance.edited, lchunk.data.simplified.getColumnProvenance(0, 0));
    try std.testing.expectEqual(@as(usize, 0), mgr.ingestion_queue.edit_dirty.count());
    try std.testing.expectEqual(@as(u8, 0), mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, false));
}

test "edited chunk unload retains in-flight LOD work inside the horizon" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 }, .active_lod_count = 2 };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lchunk = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    lchunk.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .empty, .daylight, .empty);
    lchunk.state = .meshing;

    var edited_chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 72) : (y += 1) chunk_derived_setBlock(&edited_chunk, 0, y, 0, .stone);
    mgr.markChunkEdited(0, 0);

    const lod1_mask = @as(u8, 1) << @intFromEnum(LODLevel.lod1);
    try std.testing.expectEqual(lod1_mask, mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, true));
    try std.testing.expectEqual(@as(usize, 1), mgr.ingestion_queue.pending_ingestions.items.len);
    try std.testing.expectEqual(@as(f32, 10.0), lchunk.data.simplified.getHeight(0, 0));

    lchunk.state = .renderable;
    try std.testing.expectEqual(@as(u8, 0), mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, true));
    try std.testing.expectEqual(@as(usize, 0), mgr.ingestion_queue.pending_ingestions.items.len);
    try std.testing.expectEqual(@as(f32, 72.0), lchunk.data.simplified.getHeight(0, 0));
}

test "deferred edited ingestion retries only levels still pending" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 }, .active_lod_count = 3 };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    const lod1 = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod1);
    const lod2 = try placeSimplifiedRegion(mgr, allocator, 0, 0, .lod2);
    lod1.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .empty, .daylight, .empty);
    lod2.data.simplified.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, .empty, .daylight, .empty);
    lod2.state = .meshing;

    var edited_chunk = Chunk.init(0, 0);
    var y: u32 = 0;
    while (y <= 72) : (y += 1) chunk_derived_setBlock(&edited_chunk, 0, y, 0, .stone);
    mgr.markChunkEdited(0, 0);

    const lod2_mask = @as(u8, 1) << @intFromEnum(LODLevel.lod2);
    try std.testing.expectEqual(lod2_mask, mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, true));
    const lod1_revision = lod1.source_revision;
    try std.testing.expectEqual(@as(f32, 72.0), lod1.data.simplified.getHeight(0, 0));

    lod2.state = .renderable;
    try std.testing.expectEqual(@as(u8, 0), mgr.flushEditedChunkForUnload(0, 0, &edited_chunk, true));
    try std.testing.expectEqual(lod1_revision, lod1.source_revision);
    try std.testing.expectEqual(@as(f32, 72.0), lod2.data.simplified.getHeight(0, 0));
}

test "bounded edited chunk flush preserves work beyond the frame budget" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .active_lod_count = 2 };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();
    mgr.ingestion_queue.drain_per_frame = 2;

    mgr.markChunkEdited(0, 0);
    mgr.markChunkEdited(1, 0);
    mgr.markChunkEdited(2, 0);
    mgr.flushEditedChunksBounded();

    try std.testing.expectEqual(@as(usize, 1), mgr.ingestion_queue.edit_dirty.count());
    try std.testing.expectEqual(@as(usize, 2), mgr.ingestion_queue.pending_ingestions.items.len);
}

fn chunk_derived_setBlock(chunk: *Chunk, x: u32, y: u32, z: u32, block: world_core.BlockType) void {
    chunk.setBlock(x, y, z, block);
}

test "enforceMemoryBudget requests reclamation without shrinking empty refinement rings" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .radii = .{ 2, 4, 8, 16, 32 }, .memory_budget_mb = 1 };
    const mgr = try buildIngestionManager(allocator, &config);
    defer mgr.deinit();

    // Retained backing can exceed the budget with no evictable regions.
    // Shrinking empty rings cannot release it and used to prevent recovery.
    mgr.memory_governor.used_bytes = 50_000_000;
    try mgr.enforceMemoryBudget();

    try std.testing.expect(mgr.memory_governor.pressure_pending);
    for (mgr.memory_governor.radius_shrink_chunks) |shrink| try std.testing.expectEqual(@as(i32, 0), shrink);
}
