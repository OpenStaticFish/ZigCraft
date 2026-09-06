const std = @import("std");
const fs = @import("fs");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const world_core = @import("world-core");
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Vertex = @import("engine-rhi").Vertex;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const RingBuffer = @import("engine-core").ring_buffer.RingBuffer;
const JobQueue = @import("engine-core").job_system.JobQueue;
const Job = @import("engine-core").job_system.Job;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const LODStagingCost = @import("lod_mesh_resources.zig").LODStagingCost;
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_cache = @import("lod_cache.zig");
const cache_io = @import("lod_cache_io.zig");
const lod_store = @import("lod_store.zig");
const manager_mod = @import("lod_manager.zig");
const LODManager = manager_mod.LODManager;
const MAX_CACHE_LOADS_PER_UPDATE = @import("lod_manager_context.zig").MAX_CACHE_LOADS_PER_UPDATE;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = @import("lod_manager_context.zig").DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const wouldExceedUploadBudget = @import("lod_manager_context.zig").wouldExceedUploadBudget;
const cancelWorkOutsideHorizon = @import("lod_manager_core_ops.zig").cancelWorkOutsideHorizon;
const generation_ops = @import("lod_manager_generation_ops.zig");
const testing = std.testing;

test "LODManager cache helpers save and reload source data" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    const key = LODRegionKey{ .rx = 2, .rz = -3, .lod = .lod1 };

    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();
    data.setColumn(1, 1, 72.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF112233, .empty, .daylight, .empty);

    manager.saveCachedSourceData(key, &data);
    manager.flushCacheIO();

    const store_path = try lod_store.containerPath(testing.allocator, save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(store_path);
    fs.cwd().access(store_path, .{}) catch return error.ExpectedStoreContainer;

    var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    defer loaded.deinit();

    const idx = 1 + data.width;
    try testing.expectEqual(data.heightmap[idx], loaded.heightmap[idx]);
    try testing.expectEqual(data.biomes[idx], loaded.biomes[idx]);
    try testing.expectEqual(data.material_layers[idx].foundation, loaded.material_layers[idx].foundation);
}

test "flushDirtyStoresNow persists the latest edited source snapshot" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    const key = LODRegionKey{ .rx = 0, .rz = -1, .lod = .lod4 };
    const chunk = try putTestRegion(&manager, key, .generated);
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod4) };
    chunk.data.simplified.setColumn(1, 1, 64.0, .plains, .{ .surface = .sand, .subsurface = .sand, .foundation = .stone }, 0xc2b280, .{
        .is_surface = true,
        .surface_height = 65.0,
        .depth = 1.0,
        .coverage = 0.5,
    }, .daylight, .empty);
    chunk.data.simplified.setColumnProvenance(1, 1, .edited);
    chunk.markSourceDirty();

    manager.flushDirtyStoresNow();

    var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    defer loaded.deinit();
    const idx = 1 + loaded.width;
    try testing.expect(loaded.water[idx].is_surface);
    try testing.expectEqual(@as(f32, 0.5), loaded.water[idx].coverage);
    try testing.expectEqual(LODColumnProvenance.edited, loaded.provenance[idx]);
}

test "explicit persistence invalidates blocked edited store payloads" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    defer manager.ingestion_queue.pending_ingestions.deinit(testing.allocator);
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    const key = LODRegionKey.fromChunkCoords(0, 0, .lod2);
    var stale = try LODSimplifiedData.init(testing.allocator, key.lod);
    defer stale.deinit();
    stale.setColumn(0, 0, 40.0, .plains, .{ .surface = .stone, .subsurface = .stone, .foundation = .stone }, 0x808080, .empty, .daylight, .empty);
    manager.saveCachedSourceData(key, &stale);
    manager.flushCacheIO();
    var initially_loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    initially_loaded.deinit();

    manager.ingestion_queue.mutex.lock();
    const recorded = manager.recordPendingLocked(0, 0, .edited, @as(u8, 1) << @intFromEnum(LODLevel.lod2));
    manager.ingestion_queue.mutex.unlock();
    try testing.expect(recorded);

    manager.flushDirtyStoresNow();
    manager.invalidatePendingEditedStoresNow();
    try testing.expect(manager.loadCachedSourceData(key) == null);

    // A saturated pending queue re-retains an edit in edit_dirty. Explicit
    // persistence must invalidate that coordinate's full active LOD ladder too.
    manager.saveCachedSourceData(key, &stale);
    manager.flushCacheIO();
    try manager.ingestion_queue.edit_dirty.put(.{ .cx = 0, .cz = 0 }, {});
    manager.invalidatePendingEditedStoresNow();
    try testing.expect(manager.loadCachedSourceData(key) == null);
}

test "flushDirtyStoresNow drains more than one cache pipeline batch" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    const region_count = cache_io.MAX_PENDING_TASKS + 1;
    for (0..region_count) |i| {
        const key = LODRegionKey{ .rx = @intCast(i), .rz = -2, .lod = .lod4 };
        const chunk = try putTestRegion(&manager, key, .generated);
        chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, key.lod) };
        chunk.data.simplified.setColumn(0, 0, @floatFromInt(40 + i), .plains, .{ .surface = .stone, .subsurface = .stone, .foundation = .stone }, 0x808080, .empty, .daylight, .empty);
        chunk.data.simplified.setColumnProvenance(0, 0, .edited);
        chunk.markSourceDirty();
    }

    manager.flushDirtyStoresNow();

    for (0..region_count) |i| {
        const key = LODRegionKey{ .rx = @intCast(i), .rz = -2, .lod = .lod4 };
        var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
        defer loaded.deinit();
        try testing.expectEqual(@as(f32, @floatFromInt(40 + i)), loaded.getHeight(0, 0));
        try testing.expectEqual(LODColumnProvenance.edited, loaded.getColumnProvenance(0, 0));
    }
}

test "LODManager cache helpers delete corrupt cache files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    const legacy_dir = try fs.path.join(testing.allocator, &.{ save_dir_path, "lod_cache" });
    defer testing.allocator.free(legacy_dir);
    try fs.cwd().makePath(legacy_dir);
    const path = try manager.legacyCacheFilePath(save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(path);

    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    try file.writeAll(&.{ 0, 1, 2, 3 });
    file.close();

    try testing.expect(manager.loadCachedSourceData(key) == null);
    try testing.expectError(error.FileNotFound, fs.cwd().openFile(path, .{}));
}

test "LODManager enableCache deletes stale generator-keyed store and writes live header" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 1234,
        .generator_version = 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 1234, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(@as(u64, 42), header.seed);
    try testing.expectEqual(@as(u64, 99), header.generator_identity_hash);
    try testing.expectEqual(@as(u32, 7), header.generator_version);
}

test "LODManager enableCache deletes stale data-version store" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 99,
        .generator_version = 7,
        .lod_data_version = lod_cache.CACHE_VERSION - 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 99, .generator_version = 7, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(lod_cache.CACHE_VERSION, header.lod_data_version);
}

test "LODManager queued generation applies source-store completion asynchronously" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    const key = LODRegionKey{ .rx = 4, .rz = -2, .lod = .lod1 };

    var source = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod1);
    defer source.deinit();
    source.setColumn(2, 3, 81.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF445566, .empty, .daylight, .empty);

    var writer = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer writer.cache_io.deinit();
    writer.config = config.interface();
    writer.cache_store.cache_dir_path = null;
    try writer.enableCache(save_dir_path);
    writer.saveCachedSourceData(key, &source);
    writer.flushCacheIO();
    if (writer.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    writer.ingestion_queue.edit_dirty.deinit();

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.config = config.interface();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    defer manager.ingestion_queue.edit_dirty.deinit();
    defer manager.mesh_disposal.queue.deinit(testing.allocator);

    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(testing.allocator);
        manager.meshes[i] = MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(testing.allocator, 4);
        manager.job_dispatcher.queues[i] = try testing.allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(testing.allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            var region_iter = manager.regions[i].iterator();
            while (region_iter.next()) |entry| {
                entry.value_ptr.*.deinit(testing.allocator);
                testing.allocator.destroy(entry.value_ptr.*);
            }
            manager.regions[i].deinit();
            manager.meshes[i].deinit();
            manager.upload_queues[i].deinit();
            manager.job_dispatcher.queues[i].deinit();
            testing.allocator.destroy(manager.job_dispatcher.queues[i]);
        }
        manager.generation_tokens.deinit(testing.allocator);
        manager.transition_tokens.deinit(testing.allocator);
        manager.fade_tokens.deinit(testing.allocator);
    }

    const chunk = try testing.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    chunk.state = .queued_for_generation;
    chunk.job_token = 9;
    try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
    _ = try manager.generation_tokens.push(testing.allocator, .{ .key = key, .job_token = chunk.job_token, .source_revision = chunk.source_revision, .priority = 0, .stage = .generation });

    try manager.processQueuedGenerations(Vec3.zero);

    // The update-side call only enqueues the read; no source data has been
    // deserialized or applied until the dedicated cache worker completes.
    try testing.expectEqual(@as(u32, 0), manager.cache_hits);
    try testing.expectEqual(LODState.queued_for_generation, chunk.state);
    manager.flushCacheIO();

    try testing.expectEqual(@as(u32, 1), manager.cache_hits);
    try testing.expectEqual(@as(usize, 0), manager.job_dispatcher.queues[LODLevel.count - 1].count());
    try testing.expectEqual(LODState.generated, chunk.state);
    switch (chunk.data) {
        .simplified => |*loaded| {
            const idx = 2 + 3 * loaded.width;
            try testing.expectEqual(source.heightmap[idx], loaded.heightmap[idx]);
            try testing.expectEqual(source.material_layers[idx].foundation, loaded.material_layers[idx].foundation);
        },
        else => return error.ExpectedSimplifiedData,
    }
}

test "LODManager queued generation dispatches beyond cache read budget" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.config = config.interface();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    defer manager.ingestion_queue.edit_dirty.deinit();
    defer manager.mesh_disposal.queue.deinit(testing.allocator);

    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(testing.allocator);
        manager.meshes[i] = MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(testing.allocator, 4);
        manager.job_dispatcher.queues[i] = try testing.allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(testing.allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            var region_iter = manager.regions[i].iterator();
            while (region_iter.next()) |entry| {
                entry.value_ptr.*.deinit(testing.allocator);
                testing.allocator.destroy(entry.value_ptr.*);
            }
            manager.regions[i].deinit();
            manager.meshes[i].deinit();
            manager.upload_queues[i].deinit();
            manager.job_dispatcher.queues[i].deinit();
            testing.allocator.destroy(manager.job_dispatcher.queues[i]);
        }
        manager.generation_tokens.deinit(testing.allocator);
        manager.transition_tokens.deinit(testing.allocator);
        manager.fade_tokens.deinit(testing.allocator);
    }

    const candidate_count = MAX_CACHE_LOADS_PER_UPDATE + 4;
    for (0..candidate_count) |i| {
        const key = LODRegionKey{ .rx = @intCast(i), .rz = 0, .lod = .lod1 };
        const chunk = try testing.allocator.create(LODChunk);
        chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
        chunk.state = .queued_for_generation;
        chunk.job_token = @intCast(i + 1);
        try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
        _ = try manager.generation_tokens.push(testing.allocator, .{ .key = key, .job_token = chunk.job_token, .source_revision = chunk.source_revision, .priority = @intCast(i), .stage = .generation });
    }

    try manager.processQueuedGenerations(Vec3.zero);

    try testing.expectEqual(@as(u32, 0), manager.cache_misses);
    try testing.expectEqual(candidate_count - MAX_CACHE_LOADS_PER_UPDATE, manager.job_dispatcher.queues[LODLevel.count - 1].count());
    manager.flushCacheIO();
    try testing.expectEqual(@as(u32, @intCast(MAX_CACHE_LOADS_PER_UPDATE)), manager.cache_misses);
    try testing.expectEqual(candidate_count, manager.job_dispatcher.queues[LODLevel.count - 1].count());
}

fn initEvictionTestManager(allocator: std.mem.Allocator, config: *LODConfig) !LODManager {
    var manager = try LODManager.initCacheTestManager(allocator, "");
    manager.config = config.interface();
    manager.job_dispatcher.worker_pool = null;
    manager.job_dispatcher.next_token = 1;
    manager.job_dispatcher.stop_flag = std.atomic.Value(bool).init(false);
    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(allocator);
        manager.meshes[i] = MeshMap.init(allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(allocator, 4);
        manager.job_dispatcher.queues[i] = try allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(allocator);
    }
    var bridge_ctx: u8 = 0;
    manager.gpu_bridge = .{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) @import("engine-rhi").RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&bridge_ctx),
    };
    return manager;
}

fn deinitEvictionTestManager(manager: *LODManager) void {
    manager.cache_io.deinit();
    for (0..LODLevel.count) |i| {
        var region_iter = manager.regions[i].iterator();
        while (region_iter.next()) |entry| {
            entry.value_ptr.*.deinit(manager.allocator);
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.regions[i].deinit();

        var mesh_iter = manager.meshes[i].iterator();
        while (mesh_iter.next()) |entry| {
            entry.value_ptr.*.releasePendingCompactTile();
            if (entry.value_ptr.*.pending_vertices) |pending| {
                manager.allocator.free(pending);
            }
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.meshes[i].deinit();
        manager.upload_queues[i].deinit();
        manager.job_dispatcher.queues[i].deinit();
        manager.allocator.destroy(manager.job_dispatcher.queues[i]);
    }
    for (manager.mesh_disposal.queue.items) |mesh| {
        manager.gpu_bridge.destroy(mesh);
        manager.allocator.destroy(mesh);
    }
    manager.mesh_disposal.queue.deinit(manager.allocator);
    manager.ingestion_queue.edit_dirty.deinit();
    manager.near_sources.deinit(manager.allocator);
    manager.near_source_retries.deinit(manager.allocator);
    manager.generation_tokens.deinit(manager.allocator);
    manager.transition_tokens.deinit(manager.allocator);
    manager.fade_tokens.deinit(manager.allocator);
}

test "LODManager reports pool, direct, pending, deferred, and logical admission memory separately" {
    var config = LODConfig{ .memory_budget_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const RendererMemory = struct {
        fn stats(_: *anyopaque) lod_gpu.LODRendererMemoryStats {
            return .{
                .pool_gpu_capacity_bytes = 100,
                .pool_gpu_allocated_bytes = 80,
                .pool_gpu_slack_bytes = 20,
                .pool_cpu_shadow_bytes = 100,
                .compact_pool_capacity_bytes = 60,
                .compact_pool_allocated_bytes = 40,
                .compact_pool_free_bytes = 20,
            };
        }
    };
    manager.renderer = .{
        .render_fn = undefined,
        .deinit_fn = undefined,
        .ptr = undefined,
        .memory_stats_fn = RendererMemory.stats,
    };
    manager.profiling = .init(true);

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    _ = try putTestRegion(&manager, key, .uploading);
    const direct_mesh = try putTestPendingMesh(&manager, key, 3);
    direct_mesh.capacity = 2;

    const deferred = try testing.allocator.create(LODMesh);
    deferred.* = LODMesh.init(testing.allocator, .lod1);
    deferred.capacity = 4;
    deferred.pending_vertices = try testing.allocator.alloc(Vertex, 5);
    manager.queueMeshDeletion(deferred);

    manager.updateStats();
    const stats = manager.getStats();

    const vertex_bytes = @sizeOf(Vertex);
    const expected_direct_gpu = 6 * vertex_bytes;
    const expected_pending = 8 * vertex_bytes;
    const expected_known = 260 + expected_direct_gpu + expected_pending;
    const expected_reservation = 1024 * 1024;
    try testing.expectEqual(@as(u64, 100), stats.pool_gpu_capacity_bytes);
    try testing.expectEqual(@as(u64, 80), stats.pool_gpu_allocated_bytes);
    try testing.expectEqual(@as(u64, 20), stats.pool_gpu_slack_bytes);
    try testing.expectEqual(@as(u64, 100), stats.pool_cpu_shadow_bytes);
    try testing.expectEqual(@as(u64, 60), stats.compact_pool_capacity_bytes);
    try testing.expectEqual(@as(u64, 40), stats.compact_pool_allocated_bytes);
    try testing.expectEqual(@as(u64, expected_direct_gpu), stats.direct_mesh_gpu_bytes);
    try testing.expectEqual(@as(u64, 3 * vertex_bytes), stats.pending_cpu_upload_bytes);
    try testing.expectEqual(@as(u64, 4 * vertex_bytes), stats.deferred_deletion_gpu_bytes);
    try testing.expectEqual(@as(u64, 5 * vertex_bytes), stats.deferred_deletion_cpu_bytes);
    try testing.expectEqual(@as(u64, expected_known), stats.memory_used_bytes);
    try testing.expectEqual(@as(u64, 1), stats.resident_region_count);
    try testing.expectEqual(@as(u64, expected_reservation), stats.logical_admission_reservation_bytes);
    try testing.expectEqual(@as(u64, expected_known + expected_reservation), stats.logical_admission_bytes);
    try testing.expectEqual(@as(u64, expected_known), stats.profiling.known_memory_bytes);
    try testing.expectEqual(@as(u64, 4 * vertex_bytes), stats.profiling.deferred_deletion_bytes);
    try testing.expectEqual(@as(u64, 5 * vertex_bytes), stats.profiling.deferred_deletion_cpu_bytes);
}

test "LODManager pool-exhaustion upload failure falls back to CPU heightfield and requeues LOD4" {
    var config = LODConfig{ .max_uploads_per_frame = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xffffff)} ** world_core.MAX_BLOCK_TYPES;
    manager.atlas = &atlas;

    const key = LODRegionKey{ .rx = 96, .rz = -96, .lod = .lod4 };
    const chunk = try putTestRegion(&manager, key, .uploading);
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod4) };
    const mesh = try manager.getOrCreateMesh(key);
    switch (chunk.data) {
        .simplified => |*data| try mesh.buildCompactTile(data),
        else => unreachable,
    }
    try manager.upload_queues[@intFromEnum(key.lod)].push(chunk);

    // This mirrors a compact pool exhaustion during a large teleport: compact
    // upload fails, while the ordinary CPU mesh upload remains available.
    manager.gpu_bridge.on_upload = struct {
        fn f(candidate: *LODMesh, _: *anyopaque) @import("engine-rhi").RhiError!void {
            if (candidate.isCompact()) return error.OutOfMemory;
        }
    }.f;

    manager.processUploadsWithBudget(std.math.maxInt(usize));
    try testing.expect(!mesh.isCompact());
    try testing.expect(mesh.pendingVerticesForTest() != null);
    try testing.expectEqual(LODState.uploading, chunk.getState());
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[@intFromEnum(key.lod)].count());

    manager.processUploadsWithBudget(std.math.maxInt(usize));
    try testing.expectEqual(LODState.renderable, chunk.getState());
}

test "LODManager compact fallback keeps a renderable compact mesh through injected CPU allocation failure" {
    const DestroyCounter = struct {
        calls: u32 = 0,

        fn destroy(mesh: *LODMesh, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            // Match the production compact-pool callback, which clears all
            // compact counts/state before LODGPUBridge clears pending vertices.
            mesh.clearCompactState();
        }
    };

    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xffffff)} ** world_core.MAX_BLOCK_TYPES;
    manager.atlas = &atlas;

    var destroy_counter = DestroyCounter{};
    manager.gpu_bridge.ctx = &destroy_counter;
    manager.gpu_bridge.on_destroy = DestroyCounter.destroy;

    var chunk = LODChunk.init(0, 0, .lod4);
    defer chunk.deinit(testing.allocator);
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod4) };
    chunk.setState(.renderable);

    const backing = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(backing);
    var failing_storage = std.heap.FixedBufferAllocator.init(backing);
    var mesh = LODMesh.init(failing_storage.allocator(), .lod4);
    defer mesh.clearRetiredState();
    switch (chunk.data) {
        .simplified => |*data| try mesh.buildCompactTile(data),
        else => unreachable,
    }
    mesh.ready = true;
    mesh.vertex_count = mesh.compact_index_count;
    const original_count = mesh.vertex_count;

    // Exhaust exactly the mesh allocator after compact setup. The CPU build
    // must fail before retiring the only renderable representation.
    const compact_end = failing_storage.end_index;
    failing_storage.end_index = backing.len;
    try testing.expectError(error.OutOfMemory, manager.fallbackCompactMeshToCpu(&mesh, &chunk));
    try testing.expectEqual(@as(u32, 0), destroy_counter.calls);
    try testing.expect(chunk.isRenderable());
    try testing.expect(mesh.isCompact());
    try testing.expect(mesh.isRenderable());
    try testing.expectEqual(original_count, mesh.vertex_count);
    try testing.expect(mesh.pendingVerticesForTest() == null);

    // Restore capacity and retry the same transition. This proves the failed
    // attempt was not an empty .renderable state or a no-op retry.
    failing_storage.end_index = compact_end;
    try manager.fallbackCompactMeshToCpu(&mesh, &chunk);
    try testing.expectEqual(@as(u32, 1), destroy_counter.calls);
    try testing.expect(!mesh.isCompact());
    try testing.expect(!mesh.isRenderable());
    try testing.expect(mesh.pendingVerticesForTest() != null);
}

test "LODManager recovers compact draw failure on update path without losing parent fallback" {
    const RecoveryMock = struct {
        allocator: std.mem.Allocator,
        destroy_calls: u32 = 0,
        upload_calls: u32 = 0,

        fn bridge(self: *@This()) LODGPUBridge {
            return .{
                .on_upload = upload,
                .on_destroy = destroy,
                .on_wait_idle = waitIdle,
                .ctx = self,
            };
        }

        fn upload(mesh: *LODMesh, ctx: *anyopaque) @import("engine-rhi").RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.upload_calls += 1;
            const pending = mesh.pending_vertices orelse return;
            mesh.vertex_count = @intCast(pending.len);
            mesh.opaque_vertex_count = @intCast(pending.len);
            mesh.ready = true;
            self.allocator.free(pending);
            mesh.pending_vertices = null;
        }

        fn destroy(_: *LODMesh, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.destroy_calls += 1;
        }

        fn waitIdle(_: *anyopaque) void {}
    };

    var config = LODConfig{ .max_uploads_per_frame = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xffffff)} ** world_core.MAX_BLOCK_TYPES;
    manager.atlas = &atlas;

    var mock = RecoveryMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const parent_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod4 };
    const parent = try putTestRegion(&manager, parent_key, .renderable);
    parent.ready_children = 4;
    _ = try putTestMesh(&manager, parent_key, 3);

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    const chunk = try putTestRegion(&manager, key, .renderable);
    chunk.job_token = 17;
    chunk.source_revision = 3;
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod3) };
    const mesh = try manager.getOrCreateMesh(key);
    switch (chunk.data) {
        .simplified => |*data| try mesh.buildCompactTile(data),
        else => unreachable,
    }
    mesh.setSourceIdentity(chunk.job_token, chunk.source_revision);
    mesh.ready = true;
    mesh.vertex_count = mesh.compact_index_count;

    // The renderer's failed frame only suppresses the broken compact draw. It
    // does not touch RHI or hierarchy state while it holds the shared lock.
    try testing.expect(!mesh.noteCompactBackendDrawFailure());
    try testing.expect(mesh.isRenderable());
    var draw_attempt: u8 = 1;
    while (draw_attempt < LODMesh.COMPACT_BACKEND_FAILURE_LIMIT) : (draw_attempt += 1) {
        const terminal = mesh.noteCompactBackendDrawFailure();
        try testing.expectEqual(draw_attempt + 1 == LODMesh.COMPACT_BACKEND_FAILURE_LIMIT, terminal);
    }
    try testing.expect(!mesh.isRenderable());
    try testing.expectEqual(@as(u32, 0), mock.destroy_calls);
    try testing.expectEqual(LODState.renderable, chunk.getState());
    try testing.expectEqual(@as(u8, 4), parent.readyChildren());

    // The next update owns retirement and CPU fallback publication. Removing
    // the child contribution immediately keeps the parent visible until upload.
    manager.recoverCompactDrawFailures();
    try testing.expectEqual(@as(u32, 1), mock.destroy_calls);
    try testing.expect(chunk.compact_disabled);
    try testing.expect(!mesh.isCompact());
    try testing.expect(mesh.pendingVerticesForTest() != null);
    try testing.expectEqual(LODState.uploading, chunk.getState());
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[@intFromEnum(key.lod)].count());
    try testing.expectEqual(@as(u8, 3), parent.readyChildren());

    manager.processUploadsWithBudget(std.math.maxInt(usize));
    try testing.expectEqual(@as(u32, 1), mock.upload_calls);
    try testing.expectEqual(LODState.renderable, chunk.getState());
    try testing.expect(mesh.isRenderable());
    try testing.expectEqual(@as(u8, 4), parent.readyChildren());
}

test "LODManager ignores stale compact draw failures and retries on source change" {
    const DestroyCounter = struct {
        calls: u32 = 0,

        fn destroy(_: *LODMesh, ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
        }
    };

    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    var counter = DestroyCounter{};
    manager.gpu_bridge.ctx = &counter;
    manager.gpu_bridge.on_destroy = DestroyCounter.destroy;

    const key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod3 };
    const chunk = try putTestRegion(&manager, key, .renderable);
    chunk.job_token = 8;
    chunk.source_revision = 4;
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod3) };
    const mesh = try manager.getOrCreateMesh(key);
    switch (chunk.data) {
        .simplified => |*data| try mesh.buildCompactTile(data),
        else => unreachable,
    }
    mesh.setSourceIdentity(chunk.job_token, chunk.source_revision);
    mesh.ready = true;
    mesh.markCompactDrawFailed();

    // A newer source has its own remesh lifecycle. A late failure from the old
    // representation must neither retire it nor disable compact for the new
    // source/device session.
    chunk.markSourceDirty();
    manager.recoverCompactDrawFailures();
    try testing.expect(!chunk.compact_disabled);
    try testing.expect(mesh.isCompact());
    try testing.expectEqual(LODState.renderable, chunk.getState());
    try testing.expectEqual(@as(u32, 0), counter.calls);

    // A stale job token is rejected by the same identity guard.
    mesh.setSourceIdentity(chunk.job_token, chunk.source_revision);
    chunk.job_token +%= 1;
    manager.recoverCompactDrawFailures();
    try testing.expect(mesh.isCompact());
    try testing.expectEqual(@as(u32, 0), counter.calls);
}

test "LODManager meshes reduced far grids through compact and expanded paths" {
    const Cases = [_]struct { lod: LODLevel, width: u32, compact_capable: bool }{
        .{ .lod = .lod3, .width = 65, .compact_capable = true },
        .{ .lod = .lod4, .width = 65, .compact_capable = true },
        .{ .lod = .lod3, .width = 65, .compact_capable = false },
        .{ .lod = .lod4, .width = 65, .compact_capable = false },
    };

    inline for (Cases) |case| {
        var config = LODConfig{};
        var manager = try initEvictionTestManager(testing.allocator, &config);
        defer deinitEvictionTestManager(&manager);

        var atlas: TextureAtlas = undefined;
        @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
        atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
        atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xffffff)} ** world_core.MAX_BLOCK_TYPES;
        manager.atlas = &atlas;

        var capability_context: u8 = 0;
        manager.gpu_bridge.ctx = &capability_context;
        manager.gpu_bridge.on_supports_compact_gpu_culling = struct {
            fn supports(_: *anyopaque) bool {
                return case.compact_capable;
            }
        }.supports;

        manager.generator = .{
            .ptr = &capability_context,
            .generate_heightmap_only = struct {
                fn generate(_: *anyopaque, data: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {
                    var z: u32 = 0;
                    while (z < data.width) : (z += 1) {
                        var x: u32 = 0;
                        while (x < data.width) : (x += 1) {
                            data.setGeneratedColumn(x, z, 64.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4f8c45, .empty, .daylight, .empty);
                        }
                    }
                }
            }.generate,
            .maybe_recenter_cache = struct {
                fn recenter(_: *anyopaque, _: i32, _: i32) bool {
                    return false;
                }
            }.recenter,
            .seed = 1,
            .identity_hash = 1,
            .version = 1,
        };

        const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = case.lod };
        const chunk = try putTestRegion(&manager, key, .generating);
        chunk.job_token = 1;
        generation_ops.processLODJob(&manager, .{ .type = .chunk_generation, .data = .{ .chunk = .{ .x = key.rx, .z = key.rz, .job_token = chunk.job_token, .lod_level = @intFromEnum(case.lod), .coord_scale = @intCast(case.lod.chunksPerSide()), .lod_radius = 4096 } } });

        try testing.expectEqual(LODState.generated, chunk.getState());
        switch (chunk.data) {
            .simplified => |*data| try testing.expectEqual(case.width, data.width),
            else => return error.TestExpectedEqual,
        }

        try manager.processStateTransitions(Vec3.zero);
        const mesh_job: Job = manager.job_dispatcher.queues[LODLevel.count - 1].pop().?;
        generation_ops.processLODJob(&manager, mesh_job);

        const mesh = manager.meshes[@intFromEnum(case.lod)].get(key) orelse return error.TestExpectedEqual;
        try testing.expectEqual(case.compact_capable, mesh.isCompact());
        if (case.compact_capable) {
            try testing.expectEqual((case.width - 1) * (case.width - 1) * 6, mesh.compact_index_count);
        } else try testing.expect(mesh.pendingVerticesForTest() != null);
        try testing.expectEqual(LODState.mesh_ready, chunk.getState());
    }
}

test "stale generation completion preserves edited source published in flight" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod4 };
    const chunk = try putTestRegion(&manager, key, .generating);
    chunk.job_token = 1;

    const RaceContext = struct {
        manager: *LODManager,
        key: LODRegionKey,
    };
    var context = RaceContext{ .manager = &manager, .key = key };
    manager.generator = .{
        .ptr = &context,
        .generate_heightmap_only = struct {
            fn generate(ptr: *anyopaque, data: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {
                const race: *RaceContext = @ptrCast(@alignCast(ptr));
                for (0..data.width) |z| for (0..data.width) |x| {
                    data.setGeneratedColumn(@intCast(x), @intCast(z), 64.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4f8c45, .empty, .daylight, .empty);
                };

                var edited = LODSimplifiedData.init(testing.allocator, .lod4) catch unreachable;
                edited.setGeneratedColumn(0, 0, 20.0, .plains, .{ .surface = .stone, .subsurface = .stone, .foundation = .stone }, 0x808080, .empty, .daylight, .empty);
                edited.setColumnProvenance(0, 0, .edited);

                race.manager.mutex.lock();
                defer race.manager.mutex.unlock();
                const region = race.manager.regions[@intFromEnum(race.key.lod)].get(race.key).?;
                region.data = .{ .simplified = edited };
                region.markSourceDirty();
            }
        }.generate,
        .maybe_recenter_cache = struct {
            fn recenter(_: *anyopaque, _: i32, _: i32) bool {
                return false;
            }
        }.recenter,
        .seed = 1,
        .identity_hash = 1,
        .version = 1,
    };

    generation_ops.processLODJob(&manager, .{ .type = .chunk_generation, .data = .{ .chunk = .{ .x = key.rx, .z = key.rz, .job_token = chunk.job_token, .lod_level = @intFromEnum(key.lod), .coord_scale = @intCast(key.lod.chunksPerSide()), .lod_radius = 4096 } } });

    try testing.expectEqual(LODState.generated, chunk.getState());
    try testing.expectEqual(@as(f32, 20.0), chunk.data.simplified.getHeight(0, 0));
    try testing.expectEqual(LODColumnProvenance.edited, chunk.data.simplified.getColumnProvenance(0, 0));
}

fn putTestRegion(manager: *LODManager, key: LODRegionKey, state: LODState) !*LODChunk {
    const chunk = try manager.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    chunk.state = state;
    try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
    return chunk;
}

test "near source survives chunk unload and covered region deletion before generation" {
    var config = LODConfig{ .mesh_path = .heightfield, .vertical_span_budget = 0, .sample_density = @splat(0.25) };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    manager.generator.ptr = &config;
    manager.generator.generate_heightmap_only = struct {
        fn generate(_: *anyopaque, data: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {
            for (0..data.width) |z| for (0..data.width) |x| {
                data.setGeneratedColumn(@intCast(x), @intCast(z), 20, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x808080, .empty, .daylight, .empty);
            };
        }
    }.generate;
    // Destroy the full-detail allocation before the first LOD region exists.
    {
        const chunk = try testing.allocator.create(world_core.Chunk);
        defer testing.allocator.destroy(chunk);
        chunk.* = world_core.Chunk.init(-1, -1);
        chunk.setBlock(0, 63, 0, .stone);
        try testing.expect(manager.submitNearChunk(-1, -1, manager.captureNearChunk(chunk, .generated).?));
        try testing.expect(!chunk.isPinned());
    }
    var checker_context: u8 = 0;
    const checker = struct {
        fn loaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    }.loaded;
    // Run the real generation publication path twice, with covered-region
    // cleanup between runs. No resolver or Chunk pointer remains available.
    for (0..2) |_| {
        for ([_]LODLevel{ .lod0, .lod1 }) |lod| {
            const key = LODRegionKey.fromChunkCoords(-1, -1, lod);
            const region = try putTestRegion(&manager, key, .generating);
            region.job_token = 1;
            generation_ops.processLODJob(&manager, .{ .type = .chunk_generation, .data = .{ .chunk = .{
                .x = key.rx,
                .z = key.rz,
                .job_token = 1,
                .lod_level = @intFromEnum(lod),
                .lod_radius = 4096,
            } } });
            const size = world_core.regionSizeBlocks(lod);
            const gx = size - world_core.CHUNK_SIZE_X;
            const gz = size - world_core.CHUNK_SIZE_Z;
            try testing.expectEqual(LODState.generated, region.getState());
            try testing.expectEqual(size + 1, region.data.simplified.width);
            try testing.expect(region.data.simplified.hasVerticalSpans());
            try testing.expectEqual(@as(f32, 64), region.data.simplified.getHeight(gx, gz));
            try testing.expectEqual(LODColumnProvenance.chunk_derived, region.data.simplified.getColumnProvenance(gx, gz));
            try testing.expectEqual(@as(f32, 0), region.data.simplified.getHeight(gx + 1, gz));
            try testing.expectEqual(@as(u8, 0), region.data.simplified.verticalSpanCount(gx + 1, gz));
            _ = try putTestMesh(&manager, key, 0);
        }
        manager.unloadLODWhereChunksLoaded(checker, &checker_context);
        try testing.expectEqual(@as(u32, 0), manager.regions[0].count());
        try testing.expectEqual(@as(u32, 0), manager.regions[1].count());
        try testing.expectEqual(@as(usize, 1), manager.near_sources.count());
    }
    // The experiment never expands coarse source grids or enables their spans.
    try testing.expectEqual(@as(f32, 0.25), manager.sourceSampleDensity(.lod2));
    try testing.expect(!manager.sourceRequiresSpans(.lod2));
}

test "near source replays in flight edits once and rejects stale generated loaded and edited captures" {
    const near_ops = @import("lod_manager_near_source_ops.zig");
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 10, 0, .stone);
    const generated = manager.captureNearChunk(&chunk, .generated).?;
    const loaded = manager.captureNearChunk(&chunk, .loaded).?;
    chunk.setBlock(0, 20, 0, .dirt);
    const older_edit = manager.captureNearChunk(&chunk, .edited).?;
    chunk.setBlock(0, 30, 0, .grass);
    const edit = manager.captureNearChunk(&chunk, .edited).?;
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        const region = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = lod }, .meshing);
        region.data = .{ .simplified = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, lod) };
        region.pin();
    }
    try testing.expect(manager.submitNearChunk(0, 0, edit));
    try testing.expect(manager.submitNearChunk(0, 0, generated));
    try testing.expect(manager.submitNearChunk(0, 0, loaded));
    try testing.expect(manager.submitNearChunk(0, 0, older_edit));
    // A freshly captured procedural snapshot is still weaker than an edit.
    try testing.expect(manager.submitNearChunk(0, 0, manager.captureNearChunk(&chunk, .generated).?));
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        const region = manager.regions[@intFromEnum(lod)].get(.{ .rx = 0, .rz = 0, .lod = lod }).?;
        try testing.expectEqual(@as(f32, 0), region.data.simplified.getHeight(0, 0));
        region.unpin();
        region.setState(.mesh_ready);
    }
    near_ops.replay(&manager, 32);
    for ([_]LODLevel{ .lod0, .lod1 }) |lod| {
        const region = manager.regions[@intFromEnum(lod)].get(.{ .rx = 0, .rz = 0, .lod = lod }).?;
        try testing.expectEqual(@as(f32, 31), region.data.simplified.getHeight(0, 0));
        try testing.expectEqual(LODColumnProvenance.edited, region.data.simplified.getColumnProvenance(0, 0));
        try testing.expectEqual(LODState.generated, region.getState());
        const revision = region.source_revision;
        const token = region.job_token;
        const queued = manager.transition_tokens.count();
        near_ops.replay(&manager, 32);
        try testing.expectEqual(revision, region.source_revision);
        try testing.expectEqual(token, region.job_token);
        try testing.expectEqual(queued, manager.transition_tokens.count());
    }
    const coarse = manager.regions[2].get(.{ .rx = 0, .rz = 0, .lod = .lod2 }).?;
    try testing.expectEqual(LODState.mesh_ready, coarse.getState());
    try testing.expectEqual(@as(f32, 0), coarse.data.simplified.getHeight(0, 0));
}

test "near source cache namespace and memory-only levels leave shipped edited summaries untouched" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(".", &path_buf);
    var config = LODConfig{ .mesh_path = .heightfield, .vertical_span_budget = 0 };
    var shipped = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&shipped);
    try shipped.enableCache(path);
    defer testing.allocator.free(shipped.cache_store.cache_dir_path.?);
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        var source = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, lod);
        defer source.deinit();
        source.setColumn(0, 0, 90, .plains, .{ .surface = .sand, .subsurface = .sand, .foundation = .stone }, 0, .empty, .daylight, .empty);
        source.setColumnProvenance(0, 0, .edited);
        shipped.saveCachedSourceData(.{ .rx = 0, .rz = 0, .lod = lod }, &source);
    }
    shipped.flushCacheIO();

    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    defer manager.ingestion_queue.pending_ingestions.deinit(testing.allocator);
    manager.near_source_enabled = true;
    // A version mismatch used to delete the shipped cache in enableCache.
    manager.generator.version += 1;
    try manager.enableCache(path);
    defer testing.allocator.free(manager.cache_store.cache_dir_path.?);
    const experiment_path = try fs.path.join(testing.allocator, &.{ path, "near-source-v1" });
    defer testing.allocator.free(experiment_path);
    try testing.expectEqualStrings(experiment_path, manager.cache_store.cache_dir_path.?);
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = lod };
        const region = try putTestRegion(&manager, key, .generated);
        region.data = .{ .simplified = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, lod) };
        region.data.simplified.setColumn(0, 0, 40, .plains, .{ .surface = .stone, .subsurface = .stone, .foundation = .stone }, 0, .empty, .daylight, .empty);
        region.data.simplified.setColumnProvenance(0, 0, .edited);
        region.markSourceDirty();
        manager.saveCachedSourceData(key, &region.data.simplified);
    }
    manager.flushDirtyStoresNow();
    for ([_]LODLevel{ .lod0, .lod1 }) |lod| {
        const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = lod };
        try testing.expect(manager.loadCachedSourceData(key) == null);
        try testing.expect((try lod_store.readPayload(testing.allocator, experiment_path, manager.cacheKey(key))) == null);
    }
    const coarse_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    var coarse = manager.loadCachedSourceData(coarse_key) orelse return error.ExpectedCacheHit;
    defer coarse.deinit();
    try testing.expectEqual(@as(f32, 40), coarse.getHeight(0, 0));
    try testing.expectEqual(LODColumnProvenance.edited, coarse.getColumnProvenance(0, 0));

    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(0, 12, 0, .dirt);
    try testing.expect(manager.submitNearChunk(0, 0, manager.captureNearChunk(&chunk, .edited).?));
    manager.storePlayerChunkPos(10000, 10000);
    @import("lod_manager_near_source_ops.zig").prune(&manager);
    manager.requestIngestion(0, 0, .edited);
    manager.invalidatePendingEditedStoresNow();
    // Neither pruning an edit nor invalidation is allowed into the old store.
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        var original = shipped.loadCachedSourceData(.{ .rx = 0, .rz = 0, .lod = lod }) orelse return error.ExpectedCacheHit;
        defer original.deinit();
        try testing.expectEqual(@as(f32, 90), original.getHeight(0, 0));
        try testing.expectEqual(LODColumnProvenance.edited, original.getColumnProvenance(0, 0));
    }
    const header = (try lod_store.readHeader(testing.allocator, path)).?;
    try testing.expectEqual(shipped.generator.version, header.generator_version);
}

test "near source bypasses disk read admission and rejects injected cache hits without reclassifying columns" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(".", &path_buf);
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    try manager.enableCache(path);
    defer testing.allocator.free(manager.cache_store.cache_dir_path.?);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod0 };
    var stale = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, key.lod);
    defer stale.deinit();
    stale.setColumn(0, 0, 90, .plains, .{ .surface = .sand, .subsurface = .sand, .foundation = .stone }, 0, .empty, .daylight, .empty);
    stale.setColumnProvenance(0, 0, .edited);
    const bytes = try lod_cache.serialize(&stale, manager.cacheKey(key), testing.allocator);
    defer testing.allocator.free(bytes);
    const cache_path = manager.cache_store.cache_dir_path.?;
    try lod_store.writePayload(testing.allocator, cache_path, manager.cacheKey(key), bytes, lod_store.DEFAULT_STORE_SIZE_CAP_MB);
    try testing.expect(manager.loadCachedSourceData(key) == null);

    const region = try putTestRegion(&manager, key, .queued_for_generation);
    region.job_token = 7;
    manager.enqueueTransition(key, region, .generation);
    try manager.processQueuedGenerations(Vec3.zero);
    try testing.expectEqual(LODState.generating, region.getState());
    try testing.expect(!region.cache_read_queued);
    try testing.expectEqual(@as(u32, 0), manager.cache_hits);
    try testing.expectEqual(@as(u32, 0), manager.cache_misses);
    _ = manager.job_dispatcher.queues[LODLevel.count - 1].pop().?;

    // Even an old/already queued cache completion cannot seed near authority.
    region.setState(.queued_for_generation);
    region.cache_read_queued = true;
    try testing.expect(try manager.cache_io.enqueueRead(cache_path, key, manager.cacheKey(key), 7));
    manager.flushCacheIO();
    try testing.expectEqual(LODState.generating, region.getState());
    try testing.expect(region.data == .empty);
    try testing.expectEqual(@as(u32, 0), manager.cache_hits);
    try testing.expectEqual(@as(u32, 1), manager.cache_misses);

    manager.saveCachedSourceData(key, &stale);
    manager.flushDirtyStoresNow();
    try manager.ingestion_queue.edit_dirty.put(.{ .cx = 0, .cz = 0 }, {});
    manager.invalidatePendingEditedStoresNow();
    const untouched = (try lod_store.readPayload(testing.allocator, cache_path, manager.cacheKey(key))).?;
    defer testing.allocator.free(untouched);
    try testing.expectEqualSlices(u8, bytes, untouched);
}

test "near source disabled keeps capture and source policy inert" {
    var config = LODConfig{ .mesh_path = .heightfield, .vertical_span_budget = 0, .sample_density = @splat(0.25) };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    const chunk = world_core.Chunk.init(0, 0);
    try testing.expect(manager.captureNearChunk(&chunk, .generated) == null);
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        try testing.expectEqual(@as(f32, 0.25), manager.sourceSampleDensity(lod));
        try testing.expect(!manager.sourceRequiresSpans(lod));
    }
    const region = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod0 }, .generated);
    region.data = .{ .simplified = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0) };
    const revision = region.source_revision;
    const capture = LODManager.NearSourceCapture{ .summary = LODManager.NearChunkSummary.capture(&chunk), .kind = .edited, .sequence = 1 };
    try testing.expect(!manager.submitNearChunk(0, 0, capture));
    try testing.expectEqual(@as(u32, 0), manager.overlayNearSourcesLocked(region));
    try testing.expectEqual(revision, region.source_revision);
    try testing.expectEqual(@as(usize, 0), manager.near_sources.count());
}

test "near source cap prefers nearby summaries and accounts retained capacity after distance pruning" {
    const near_ops = @import("lod_manager_near_source_ops.zig");
    var config = LODConfig{ .memory_budget_mb = 0 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    manager.near_source_limit = 2;
    const chunk = world_core.Chunk.init(0, 0);
    const capture = manager.captureNearChunk(&chunk, .generated).?;
    try testing.expect(manager.submitNearChunk(1, 0, capture));
    try testing.expect(manager.submitNearChunk(2, 0, capture));
    try testing.expect(!manager.submitNearChunk(3, 0, capture));
    try testing.expect(manager.submitNearChunk(0, 0, capture));
    try testing.expectEqual(@as(usize, 2), manager.near_sources.count());
    try testing.expect(manager.near_sources.contains(.{ .cx = 0, .cz = 0 }));
    try testing.expect(!manager.near_sources.contains(.{ .cx = 2, .cz = 0 }));
    const bytes = near_ops.memoryBytes(&manager);
    try testing.expect(bytes >= 2 * @sizeOf(LODManager.NearSourceCapture));
    try testing.expectEqual(bytes, manager.memory_governor.logical_admission_bytes);
    manager.storePlayerChunkPos(10000, 10000);
    near_ops.prune(&manager);
    try testing.expectEqual(@as(usize, 0), manager.near_sources.count());
    try testing.expectEqual(bytes, near_ops.memoryBytes(&manager));
}

test "near source value retries preserve load kind after unload and rotate within a bounded near-only queue" {
    const near_ops = @import("lod_manager_near_source_ops.zig");
    var config = LODConfig{ .memory_budget_mb = 0 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    manager.near_source_limit = 0;
    {
        const chunk = try testing.allocator.create(world_core.Chunk);
        defer testing.allocator.destroy(chunk);
        chunk.* = world_core.Chunk.init(0, 0);
        chunk.setBlock(0, 10, 0, .stone);
        const far = manager.captureNearChunk(chunk, .generated).?;
        try testing.expect(!manager.submitNearChunk(500, 0, far));
        manager.deferNearChunk(500, 0, far);
        const loaded = manager.captureNearChunk(chunk, .loaded).?;
        try testing.expect(!manager.submitNearChunk(1, 0, loaded));
        manager.deferNearChunk(1, 0, loaded);
        try testing.expect(!chunk.isPinned());
    }
    const empty = world_core.Chunk.init(0, 0);
    manager.near_source_limit = 1;
    try testing.expect(manager.submitNearChunk(0, 0, manager.captureNearChunk(&empty, .generated).?));
    near_ops.replay(&manager, 1);
    try testing.expectEqual(@as(usize, 2), manager.near_source_retries.items.len);
    try testing.expectEqual(@as(i32, 1), manager.near_source_retries.items[0].cx);
    try testing.expectEqual(LODManager.NearSourceKind.loaded, manager.near_source_retries.items[0].capture.kind);
    manager.near_source_limit = 2;
    near_ops.replay(&manager, 1);
    try testing.expectEqual(LODManager.NearSourceKind.loaded, manager.near_sources.get(.{ .cx = 1, .cz = 0 }).?.kind);
    const near = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod0 }, .generated);
    near.data = .{ .simplified = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0) };
    try testing.expect(manager.overlayNearSourcesLocked(near) > 0);
    try testing.expectEqual(@as(f32, 11), near.data.simplified.getHeight(16, 0));
    try testing.expectEqual(LODColumnProvenance.edited, near.data.simplified.getColumnProvenance(16, 0));
    try testing.expectEqual(@as(usize, 0), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(@as(u32, 0), manager.regions[2].count());

    const capture = manager.captureNearChunk(&empty, .generated).?;
    for (0..near_ops.MAX_NEAR_SOURCE_RETRIES) |i| manager.deferNearChunk(@intCast(i + 1000), 0, capture);
    try testing.expectEqual(near_ops.MAX_NEAR_SOURCE_RETRIES, manager.near_source_retries.items.len);
    try testing.expectEqual(near_ops.memoryBytes(&manager), manager.memory_governor.logical_admission_bytes);
}

test "near source retirement floor rejects delayed captures and retries after cap eviction and pruning" {
    const near_ops = @import("lod_manager_near_source_ops.zig");
    var config = LODConfig{ .memory_budget_mb = 0 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.near_source_enabled = true;
    manager.near_source_limit = 1;
    const chunk = world_core.Chunk.init(0, 0);
    const generated = manager.captureNearChunk(&chunk, .generated).?;
    const edit = manager.captureNearChunk(&chunk, .edited).?;
    try testing.expect(manager.submitNearChunk(10, 0, edit));
    const delayed_load = manager.captureNearChunk(&chunk, .loaded).?;
    manager.deferNearChunk(10, 0, delayed_load);
    try testing.expect(manager.submitNearChunk(0, 0, manager.captureNearChunk(&chunk, .generated).?));
    try testing.expect(!manager.near_sources.contains(.{ .cx = 10, .cz = 0 }));
    for ([_]LODManager.NearSourceCapture{ generated, edit, delayed_load }) |stale| {
        // Obsolete captures are consumed, never retried or reinserted.
        try testing.expect(manager.submitNearChunk(10, 0, stale));
    }
    near_ops.replay(&manager, 32);
    try testing.expectEqual(@as(usize, 0), manager.near_source_retries.items.len);
    try testing.expect(!manager.near_sources.contains(.{ .cx = 10, .cz = 0 }));

    const before_prune = manager.captureNearChunk(&chunk, .edited).?;
    manager.storePlayerChunkPos(10000, 10000);
    near_ops.prune(&manager);
    try testing.expect(manager.submitNearChunk(0, 0, before_prune));
    try testing.expectEqual(@as(usize, 0), manager.near_sources.count());
    // A genuinely new, trusted capture can seed the coordinate again.
    try testing.expect(manager.submitNearChunk(0, 0, manager.captureNearChunk(&chunk, .loaded).?));
    try testing.expect(manager.submitNearChunk(0, 0, before_prune));
    try testing.expectEqual(LODManager.NearSourceKind.loaded, manager.near_sources.get(.{ .cx = 0, .cz = 0 }).?.kind);
}

fn putTestMesh(manager: *LODManager, key: LODRegionKey, capacity: u32) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.ready = true;
    mesh.vertex_count = capacity;
    mesh.capacity = capacity;
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

fn putTestPendingMesh(manager: *LODManager, key: LODRegionKey, vertex_count: usize) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.pending_vertices = try manager.allocator.alloc(Vertex, vertex_count);
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

test "LODManager backs off size-limited store writes until the cap changes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    var config = LODConfig{ .lod_store_size_cap_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.cache_store.cache_dir_path = try testing.allocator.dupe(u8, save_dir);
    defer testing.allocator.free(manager.cache_store.cache_dir_path.?);
    manager.cache_store.use_config_store_size_cap = true;

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const chunk = try putTestRegion(&manager, key, .generated);
    chunk.data = .{ .simplified = try LODSimplifiedData.init(testing.allocator, .lod1) };
    chunk.store_dirty = true;
    chunk.store_size_limited = true;
    chunk.store_size_limit_cap_mb = 1;

    manager.flushDirtyStores();
    try testing.expect(!chunk.store_write_queued);
    try testing.expect(chunk.store_dirty);

    config.lod_store_size_cap_mb = 2;
    manager.flushDirtyStores();
    try testing.expect(chunk.store_write_queued);
}

const UploadMock = struct {
    allocator: std.mem.Allocator,
    calls: u32 = 0,
    wait_idle_calls: u32 = 0,
    fail_with_pressure: bool = false,
    lod4_migration_bytes: usize = 0,

    fn bridge(self: *UploadMock) LODGPUBridge {
        return .{
            .on_upload = upload,
            .on_destroy = destroy,
            .on_wait_idle = waitIdle,
            .on_upload_cost = uploadCost,
            .ctx = @ptrCast(self),
        };
    }

    fn upload(mesh: *LODMesh, ctx: *anyopaque) @import("engine-rhi").RhiError!void {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail_with_pressure) return error.OutOfMemory;
        if (mesh.pending_vertices) |pending| {
            mesh.vertex_count = @intCast(pending.len);
            mesh.opaque_vertex_count = @intCast(pending.len);
            mesh.ready = true;
            self.allocator.free(pending);
            mesh.pending_vertices = null;
        }
    }

    fn destroy(_: *LODMesh, _: *anyopaque) void {}
    fn waitIdle(ctx: *anyopaque) void {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.wait_idle_calls += 1;
    }
    fn uploadCost(mesh: *LODMesh, ctx: *anyopaque) LODStagingCost {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        return .{
            .payload_bytes = mesh.pendingUploadBytes(),
            .migration_bytes = if (mesh.lodLevel() == .lod4) self.lod4_migration_bytes else 0,
        };
    }
};

test "LODManager upload budget defers remaining queued meshes" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(@sizeOf(Vertex));

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.renderable, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[1].count());
}

test "LODManager upload budget admits one oversized mesh to guarantee progress" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(@sizeOf(Vertex) - 1);

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.renderable, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[1].count());
}

test "LODManager upload budget lets a near upload bypass a far pool migration" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    // The far mesh itself is small, but its pool replacement would restage
    // two additional vertices. The budget must preflight the full migration.
    var mock = UploadMock{ .allocator = testing.allocator, .lod4_migration_bytes = 2 * @sizeOf(Vertex) };
    manager.gpu_bridge = mock.bridge();

    const far_key = LODRegionKey{ .rx = 8, .rz = 0, .lod = .lod4 };
    const near_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const far = try putTestRegion(&manager, far_key, .uploading);
    const near = try putTestRegion(&manager, near_key, .uploading);
    _ = try putTestPendingMesh(&manager, far_key, 1);
    _ = try putTestPendingMesh(&manager, near_key, 1);
    try manager.upload_queues[@intFromEnum(far_key.lod)].push(far);
    try manager.upload_queues[@intFromEnum(near_key.lod)].push(near);

    manager.processUploadsWithBudget(2 * @sizeOf(Vertex));

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.uploading, far.state);
    try testing.expectEqual(LODState.renderable, near.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[@intFromEnum(far_key.lod)].count());

    // On the next frame no smaller work remains, so one over-budget pool
    // migration must be allowed through instead of starving forever.
    manager.processUploadsWithBudget(2 * @sizeOf(Vertex));
    try testing.expectEqual(@as(u32, 2), mock.calls);
    try testing.expectEqual(LODState.renderable, far.state);
    try testing.expectEqual(@as(usize, 0), manager.upload_queues[@intFromEnum(far_key.lod)].count());
}

test "LODManager routine upload and eviction record no streaming device waits" {
    var config = LODConfig{ .max_uploads_per_frame = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();
    manager.profiling = .init(true);

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const chunk = try putTestRegion(&manager, key, .uploading);
    const mesh = try putTestPendingMesh(&manager, key, 1);
    try manager.upload_queues[@intFromEnum(key.lod)].push(chunk);
    manager.processUploadsWithBudget(@sizeOf(Vertex));

    _ = manager.meshes[@intFromEnum(key.lod)].remove(key);
    manager.queueMeshDeletion(mesh);
    manager.processMeshDeletions(1);

    try testing.expectEqual(@as(u32, 0), mock.wait_idle_calls);
    try testing.expectEqual(@as(u64, 0), manager.profiling.snapshot().wait_idle_count);

    manager.waitIdleTracked(.shutdown);
    const profile = manager.profiling.snapshot();
    try testing.expectEqual(@as(u32, 1), mock.wait_idle_calls);
    try testing.expectEqual(@as(u64, 0), profile.wait_idle_count);
    try testing.expectEqual(@as(u64, 1), profile.wait_idle_shutdown_count);
}

test "LOD upload budget permits zero-pending and unlimited uploads" {
    const pending_bytes = @sizeOf(Vertex);

    try testing.expect(!wouldExceedUploadBudget(0, 0, 1));
    try testing.expect(!wouldExceedUploadBudget(0, pending_bytes, 0));
    try testing.expect(!wouldExceedUploadBudget(0, pending_bytes, std.math.maxInt(usize)));
}

test "LODManager staging pressure failure stops upload sweep" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator, .fail_with_pressure = true };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(DEFAULT_LOD_UPLOAD_BUDGET_BYTES);

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.uploading, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 2), manager.upload_queues[1].count());
    try testing.expectEqual(@as(u32, 1), manager.stats.upload_failures);
}

test "LODManager pause cancels queued and pinned stale work" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const queued_generation = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod1 }, .generating);
    queued_generation.job_token = 11;
    const queued_mesh = try putTestRegion(&manager, .{ .rx = 1, .rz = 0, .lod = .lod1 }, .meshing);
    queued_mesh.job_token = 12;
    const running_generation = try putTestRegion(&manager, .{ .rx = 2, .rz = 0, .lod = .lod1 }, .generating);
    running_generation.job_token = 13;
    running_generation.pin();
    defer running_generation.unpin();
    const running_mesh = try putTestRegion(&manager, .{ .rx = 3, .rz = 0, .lod = .lod1 }, .meshing);
    running_mesh.job_token = 14;
    running_mesh.pin();
    defer running_mesh.unpin();
    manager.pending_region_count = 4;

    const queue = manager.job_dispatcher.queues[LODLevel.count - 1];
    try queue.push(.{ .type = .chunk_generation, .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 11, .lod_level = 1 } } });
    try queue.push(.{ .type = .chunk_meshing, .data = .{ .chunk = .{ .x = 1, .z = 0, .job_token = 12, .lod_level = 1 } } });

    manager.pause();

    try testing.expectEqual(@as(usize, 0), queue.count());
    try testing.expectEqual(LODState.missing, queued_generation.state);
    try testing.expectEqual(@as(u32, 12), queued_generation.job_token);
    try testing.expectEqual(LODState.generated, queued_mesh.state);
    try testing.expectEqual(@as(u32, 13), queued_mesh.job_token);
    try testing.expectEqual(LODState.missing, running_generation.state);
    try testing.expectEqual(@as(u32, 14), running_generation.job_token);
    try testing.expect(running_generation.cancellationRequested());
    try testing.expectEqual(LODState.generated, running_mesh.state);
    try testing.expectEqual(@as(u32, 15), running_mesh.job_token);
    try testing.expect(running_mesh.cancellationRequested());
    try testing.expectEqual(@as(usize, 2), manager.pending_region_count);
    try testing.expectEqual(@as(u32, 4), manager.cancelled_jobs);
}

test "LODManager traversal cancels work outside its level horizon" {
    var config = LODConfig{ .radii = .{ 8, 16, 32, 64, 128 } };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const near = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod1 }, .generating);
    near.job_token = 7;
    const stale = try putTestRegion(&manager, .{ .rx = 100, .rz = 100, .lod = .lod1 }, .generating);
    stale.job_token = 9;
    stale.cache_read_queued = true;
    manager.pending_region_count = 2;

    cancelWorkOutsideHorizon(&manager, 0, 0);

    try testing.expectEqual(LODState.generating, near.state);
    try testing.expectEqual(@as(u32, 7), near.job_token);
    try testing.expect(!near.cancellationRequested());
    try testing.expectEqual(LODState.missing, stale.state);
    try testing.expectEqual(@as(u32, 10), stale.job_token);
    try testing.expect(stale.cancellationRequested());
    try testing.expect(!stale.cache_read_queued);
    try testing.expectEqual(@as(usize, 1), manager.pending_region_count);
    try testing.expectEqual(@as(u32, 1), manager.cancelled_jobs);
}

test "LODManager ready child counters update on renderable transitions and removal" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.noteRegionRemoved(child_key, child);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager demoting renderable child clears parent coverage" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.demoteRegionForRemesh(child_key, child);

    try testing.expectEqual(LODState.generated, child.state);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager ready child counters ignore renderable children without geometry" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 0);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);

    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager memory budget eviction skips unsafe regions and evicts farthest first" {
    var config = LODConfig{ .memory_budget_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const budget_bytes = @as(usize, config.memory_budget_mb) * 1024 * 1024;
    const eviction_bytes = 600 * 1024;
    const mesh_capacity: u32 = @intCast(@max(eviction_bytes / @sizeOf(Vertex), 1));
    const mesh_bytes = @as(usize, mesh_capacity) * @sizeOf(Vertex);

    const near_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const far_key = LODRegionKey{ .rx = 20, .rz = 0, .lod = .lod1 };
    const pinned_key = LODRegionKey{ .rx = 40, .rz = 0, .lod = .lod1 };
    const no_parent_key = LODRegionKey{ .rx = 60, .rz = 0, .lod = .lod1 };
    const in_flight_key = LODRegionKey{ .rx = 80, .rz = 0, .lod = .lod1 };

    _ = try putTestRegion(&manager, near_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, far_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, pinned_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, in_flight_key.parentKey().?, .renderable);

    _ = try putTestRegion(&manager, near_key, .renderable);
    _ = try putTestRegion(&manager, far_key, .renderable);
    const pinned_chunk = try putTestRegion(&manager, pinned_key, .renderable);
    pinned_chunk.pin();
    _ = try putTestRegion(&manager, no_parent_key, .renderable);
    _ = try putTestRegion(&manager, in_flight_key, .generating);

    _ = try putTestMesh(&manager, near_key, mesh_capacity);
    _ = try putTestMesh(&manager, far_key, mesh_capacity);
    _ = try putTestMesh(&manager, pinned_key, mesh_capacity);
    _ = try putTestMesh(&manager, no_parent_key, mesh_capacity);
    _ = try putTestMesh(&manager, in_flight_key, mesh_capacity);

    manager.memory_governor.used_bytes = budget_bytes + mesh_bytes;
    try manager.enforceMemoryBudget();

    try testing.expect(!manager.regions[1].contains(far_key));
    try testing.expect(!manager.meshes[1].contains(far_key));
    try testing.expect(manager.regions[1].contains(near_key));
    try testing.expect(manager.regions[1].contains(pinned_key));
    try testing.expect(manager.regions[1].contains(no_parent_key));
    try testing.expect(manager.regions[1].contains(in_flight_key));
    try testing.expect(manager.memory_governor.used_bytes <= budget_bytes);
    try testing.expectEqual(@as(u32, 1), manager.stats.evictions);
    try testing.expectEqual(@as(u32, 1), manager.mesh_disposal.queue.items.len);
}

test "Phase 5 stress repeated teleport eviction cache recovery edits and upload pressure" {
    // Counted cycles intentionally replace elapsed-time assertions. This makes
    // the PR gate short while allowing the scheduled gate to exercise a much
    // longer session with identical ordering and failure conditions.
    const cycles = @min(@import("engine-core").envInt("ZIGCRAFT_PHASE5_STRESS_ITERATIONS", 64), 4096);
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    var config = LODConfig{ .memory_budget_mb = 1, .lod_store_size_cap_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);
    manager.profiling = .init(true);
    manager.cache_store.cache_dir_path = null;
    manager.cache_store.use_config_store_size_cap = true;
    try manager.enableCache(save_dir);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    // Seed an oversized valid container, then replace it through the async
    // cache pipeline under the one-MiB cap. This takes the bounded compaction
    // path instead of merely exercising a synchronous store helper.
    const cache_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    var source = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer source.deinit();
    source.setColumn(0, 0, 64.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4f8c45, .empty, .daylight, .empty);
    const oversized = try testing.allocator.alloc(u8, 1300 * 1024);
    defer testing.allocator.free(oversized);
    @memset(oversized, 0x5a);
    try lod_store.writePayload(testing.allocator, save_dir, manager.cacheKey(cache_key), oversized, lod_store.DEFAULT_STORE_SIZE_CAP_MB);
    manager.saveCachedSourceData(cache_key, &source);
    manager.flushCacheIO();
    const container_path = try lod_store.containerPath(testing.allocator, save_dir, manager.cacheKey(cache_key));
    defer testing.allocator.free(container_path);
    const compacted_file = try fs.cwd().openFile(container_path, .{});
    const compacted_stat = try compacted_file.stat();
    compacted_file.close();
    try testing.expect(compacted_stat.size <= 1024 * 1024);
    var cached = manager.loadCachedSourceData(cache_key) orelse return error.ExpectedCacheHit;
    cached.deinit();

    // A corrupt container must be discarded and subsequently recover through
    // the asynchronous writer, rather than leaving a permanent cache miss.
    const corrupt = try fs.cwd().createFile(container_path, .{ .truncate = true });
    try corrupt.writeAll("corrupt Phase 5 cache container");
    corrupt.close();
    try testing.expect(manager.loadCachedSourceData(cache_key) == null);
    try testing.expectError(error.FileNotFound, fs.cwd().openFile(container_path, .{}));
    manager.saveCachedSourceData(cache_key, &source);
    manager.flushCacheIO();
    cached = manager.loadCachedSourceData(cache_key) orelse return error.ExpectedCacheRecovery;
    cached.deinit();

    const traveler_key = LODRegionKey{ .rx = 10_000, .rz = -10_000, .lod = .lod1 };
    const pausable_key = LODRegionKey{ .rx = 10_001, .rz = -10_000, .lod = .lod1 };
    const traveler = try putTestRegion(&manager, traveler_key, .missing);
    const pausable = try putTestRegion(&manager, pausable_key, .missing);
    const budget_bytes = @as(usize, config.memory_budget_mb) * 1024 * 1024;
    const mesh_capacity: u32 = @intCast((600 * 1024) / @sizeOf(Vertex));
    const mesh_bytes = @as(usize, mesh_capacity) * @sizeOf(Vertex);

    for (0..cycles) |cycle| {
        // Repeated long teleports must invalidate in-flight work without
        // allowing a cancelled state to survive the next unpause.
        traveler.resetCancellation();
        traveler.state = .generating;
        traveler.job_token +%= 1;
        manager.pending_region_count += 1;
        cancelWorkOutsideHorizon(&manager, 0, 0);
        try testing.expectEqual(LODState.missing, traveler.getState());
        try testing.expect(traveler.cancellationRequested());

        pausable.resetCancellation();
        pausable.state = .meshing;
        pausable.job_token +%= 1;
        manager.pause();
        try testing.expectEqual(LODState.generated, pausable.getState());
        try testing.expect(pausable.cancellationRequested());
        manager.unpause();
        try testing.expect(!manager.paused);

        // Force a staging-pressure retry each cycle, then ensure the same
        // upload completes once pressure clears. No streaming path may wait
        // for the entire device to become idle.
        const upload_key = LODRegionKey{ .rx = @intCast(20_000 + cycle), .rz = 0, .lod = .lod1 };
        const upload_chunk = try putTestRegion(&manager, upload_key, .uploading);
        const upload_mesh = try putTestPendingMesh(&manager, upload_key, 1);
        try manager.upload_queues[@intFromEnum(upload_key.lod)].push(upload_chunk);
        mock.fail_with_pressure = true;
        manager.processUploadsWithBudget(DEFAULT_LOD_UPLOAD_BUDGET_BYTES);
        try testing.expectEqual(LODState.uploading, upload_chunk.getState());
        mock.fail_with_pressure = false;
        manager.processUploadsWithBudget(DEFAULT_LOD_UPLOAD_BUDGET_BYTES);
        try testing.expectEqual(LODState.renderable, upload_chunk.getState());
        _ = manager.meshes[@intFromEnum(upload_key.lod)].remove(upload_key);
        manager.queueMeshDeletion(upload_mesh);
        upload_chunk.deinit(testing.allocator);
        testing.allocator.destroy(upload_chunk);
        _ = manager.regions[@intFromEnum(upload_key.lod)].remove(upload_key);
        manager.processMeshDeletions(1);

        // A parent fallback permits the finer child to be evicted under the
        // one-MiB cap. Repeating the operation catches stale resident entries
        // and deferred-deletion growth across a long teleport session.
        const child_key = LODRegionKey{ .rx = @intCast(cycle * 2), .rz = 64, .lod = .lod1 };
        const parent_key = child_key.parentKey().?;
        _ = try putTestRegion(&manager, parent_key, .renderable);
        _ = try putTestRegion(&manager, child_key, .renderable);
        _ = try putTestMesh(&manager, child_key, mesh_capacity);
        manager.memory_governor.used_bytes = budget_bytes + mesh_bytes;
        try manager.enforceMemoryBudget();
        try testing.expect(!manager.regions[@intFromEnum(child_key.lod)].contains(child_key));
        try testing.expect(manager.memory_governor.used_bytes <= budget_bytes);
        manager.processMeshDeletions(1);

        // Edits are deliberately repeated across a small set of coordinates;
        // the coalescing set must remain bounded even as other work churns.
        manager.markChunkEdited(@intCast(cycle % 8), @intCast(-@as(i64, @intCast(cycle % 8))));
        try testing.expect(manager.ingestion_queue.edit_dirty.count() <= 8);
    }

    // Saturate logical admission after the low-memory eviction loop. The
    // scheduler must not add another resident region when its reservation
    // would exceed the configured cap.
    const resident_before = manager.regions[@intFromEnum(LODLevel.lod1)].count();
    manager.memory_governor.logical_admission_bytes = budget_bytes;
    manager.cleanup_covered_regions = false;
    try manager.queueLODRegions(.lod1, Vec3.zero, null, null);
    try testing.expectEqual(resident_before, manager.regions[@intFromEnum(LODLevel.lod1)].count());

    try testing.expect(mock.calls >= cycles * 2);
    try testing.expect(manager.stats.upload_failures >= cycles);
    try testing.expect(manager.cancelled_jobs >= cycles * 2);
    try testing.expectEqual(@as(u32, 0), mock.wait_idle_calls);
    try testing.expectEqual(@as(u64, 0), manager.profiling.snapshot().wait_idle_count);
    for (0..LODLevel.count) |lod_idx| {
        var regions = manager.regions[lod_idx].iterator();
        while (regions.next()) |entry| switch (entry.value_ptr.*.getState()) {
            .queued_for_generation, .generating, .meshing, .uploading => return error.StuckLODState,
            else => {},
        };
        try testing.expectEqual(@as(usize, 0), manager.upload_queues[lod_idx].count());
    }
}
