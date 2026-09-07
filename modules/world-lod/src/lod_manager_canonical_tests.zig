const std = @import("std");
const testing = std.testing;
const core = @import("world-core");
const engine = @import("engine-core");
const rhi = @import("engine-rhi");
const Manager = @import("lod_manager.zig").LODManager;
const ops = @import("lod_manager_generation_ops.zig");
const lod = @import("lod_chunk.zig");
const Mesh = @import("lod_mesh.zig").LODMesh;
const gpu = @import("lod_upload_queue.zig");
const Atlas = @import("engine-assets").TextureAtlas;
const BudgetAllocator = @import("lod_budget_allocator.zig").BudgetAllocator;
const eviction = @import("lod_manager_eviction_ops.zig");

const Mock = struct {
    generated: usize = 0,
    uploads: usize = 0,
    fail_saved: bool = false,
    fail_upload: bool = false,
    memory_cost: usize = 0,
    pool_memory_bytes: usize = 0,

    fn heightmap(_: *anyopaque, _: *core.LODSimplifiedData, _: i32, _: i32, _: core.LODLevel, _: ?*const std.atomic.Value(bool)) void {}
    fn recenter(_: *anyopaque, _: i32, _: i32) bool {
        return false;
    }
    fn load(ptr: *anyopaque, _: i32, _: i32, _: std.mem.Allocator) !?Manager.SceneSummary {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        if (self.fail_saved) return error.SavedSourceReadFailed;
        return null;
    }
    fn generate(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator, _: ?*const std.atomic.Value(bool)) !Manager.SceneSummary {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.generated += 1;
        const chunk = try allocator.create(core.Chunk);
        defer allocator.destroy(chunk);
        chunk.* = core.Chunk.init(cx, cz);
        var summary = try Manager.SceneSummary.capture(allocator, chunk);
        summary.origin = .generated;
        return summary;
    }
    fn upload(mesh: *Mesh, ptr: *anyopaque) rhi.RhiError!void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.uploads += 1;
        if (self.fail_upload) return error.OutOfMemory;
        mesh.vertex_count = if (mesh.pending_vertices) |vertices| @intCast(vertices.len) else 0;
        mesh.ready = true;
        mesh.clearPendingVertices();
    }
    fn destroy(_: *Mesh, _: *anyopaque) void {}
    fn idle(_: *anyopaque) void {}
    fn memoryCost(_: *Mesh, ptr: *anyopaque) usize {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        return self.memory_cost;
    }
    fn memoryStats(ptr: *anyopaque) gpu.LODRendererMemoryStats {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        return .{ .pool_gpu_capacity_bytes = self.pool_memory_bytes };
    }
};

fn init(config: *lod.LODConfig, mock: *Mock, atlas: *const Atlas) !*Manager {
    const manager = try testing.allocator.create(Manager);
    manager.* = try Manager.initCacheTestManager(testing.allocator, "");
    manager.config = config.interface();
    manager.atlas = atlas;
    manager.job_dispatcher = .{ .queues = undefined };
    manager.gpu_bridge = .{ .ctx = mock, .on_upload = Mock.upload, .on_destroy = Mock.destroy, .on_wait_idle = Mock.idle, .on_upload_memory_cost = Mock.memoryCost };
    manager.renderer = .{ .ptr = mock, .render_fn = undefined, .deinit_fn = undefined, .memory_stats_fn = Mock.memoryStats };
    manager.generator = .{
        .ptr = mock,
        .generate_heightmap_only = Mock.heightmap,
        .maybe_recenter_cache = Mock.recenter,
        .seed = 42,
        .identity_hash = 99,
        .version = 1,
        .load_chunk_summary = Mock.load,
        .generate_chunk_summary = Mock.generate,
    };
    for (0..core.LODLevel.count) |i| {
        manager.regions[i] = gpu.RegionMap.init(testing.allocator);
        manager.meshes[i] = gpu.MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try engine.ring_buffer.RingBuffer(*lod.LODChunk).init(testing.allocator, 4);
        const queue = try testing.allocator.create(engine.job_system.JobQueue);
        queue.* = engine.job_system.JobQueue.init(testing.allocator);
        manager.job_dispatcher.queues[i] = queue;
    }
    manager.job_dispatcher.queues[core.LODLevel.count - 1].enableServiceLanes(&@import("lod_service.zig").WHEEL);
    manager.source_hierarchy = try Manager.SourceHierarchy.init(testing.allocator, manager.generator, manager.job_dispatcher.queues[core.LODLevel.count - 1], 16 * 1024 * 1024);
    manager.beginUploadFrame(8 * 1024 * 1024);
    return manager;
}

fn atlasFixture() Atlas {
    var atlas: Atlas = undefined;
    atlas.tile_mappings = @splat(.{ .top = 1, .bottom = 1, .side = 1 });
    atlas.tile_luminance = @splat(Atlas.BlockTileLuminance.uniform(1));
    atlas.tile_colors = @splat(.{ .top = 0xffffff, .bottom = 0xffffff, .side = 0xffffff });
    return atlas;
}

fn resident(manager: *Manager, level: core.LODLevel, rx: i32) !*lod.LODChunk {
    const region = try testing.allocator.create(lod.LODChunk);
    region.* = lod.LODChunk.init(rx, 0, level);
    region.job_token = 1;
    region.service_lane = 1;
    region.setState(.renderable);
    region.data = .{ .simplified = try core.LODSimplifiedData.init(testing.allocator, level) };
    const mesh = try testing.allocator.create(Mesh);
    mesh.* = Mesh.init(testing.allocator, level);
    mesh.ready = true;
    mesh.vertex_count = 3;
    try manager.regions[@intFromEnum(level)].put(region.key(), region);
    try manager.meshes[@intFromEnum(level)].put(region.key(), mesh);
    return region;
}

fn runRefresh(manager: *Manager) !void {
    const job = manager.job_dispatcher.queues[core.LODLevel.count - 1].tryPop() orelse return error.NoRefreshJob;
    try testing.expectEqual(engine.job_system.JobType.generic, job.type);
    job.data.generic.process_fn(job.data.generic.context);
}

test "canonical manager initial worker attaches SceneGrid at every level" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    for (0..core.LODLevel.count) |i| {
        const level: core.LODLevel = @enumFromInt(i);
        const region = try testing.allocator.create(lod.LODChunk);
        region.* = lod.LODChunk.init(0, 0, level);
        region.job_token = 1;
        region.setState(.generating);
        try manager.regions[i].put(region.key(), region);
        ops.processLODJob(manager, .{
            .type = .chunk_generation,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .lod_level = @intCast(i), .job_token = 1, .lod_radius = config.radii[i] } },
        });
        try testing.expectEqual(lod.LODState.generated, region.getState());
        try testing.expect(region.data.simplified.scene_grid != null);
        const quota = region.canonical_allocator.?;
        try testing.expectEqual(quota.allocator().ptr, region.data.simplified.allocator.ptr);
        try testing.expect(quota.snapshot().peak <= BudgetAllocator.default_quota_bytes);
        try testing.expect(!region.isPinned());
        region.setState(.meshing);
        ops.processLODJob(manager, .{
            .type = .chunk_meshing,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .lod_level = @intCast(i), .job_token = 1, .lod_radius = config.radii[i] } },
        });
        try testing.expectEqual(lod.LODState.mesh_ready, region.getState());
        try testing.expectEqual(quota.allocator().ptr, manager.meshes[i].get(region.key()).?.allocator.ptr);
    }
    ops.drainCanonicalChanges(manager);
    for (0..core.LODLevel.count) |i| {
        const region = manager.regions[i].get(.{ .rx = 0, .rz = 0, .lod = @enumFromInt(i) }).?;
        try testing.expect(region.canonical_refresh_requested.load(.acquire));
    }
    try testing.expect(!manager.cacheEnabled());
    try testing.expect(manager.loadCachedSourceData(.{ .rx = 0, .rz = 0, .lod = .lod4 }) == null);
}

test "canonical refresh retains old data and mesh through worker OOM and failed GPU upload" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    const region = try resident(manager, .lod0, 0);
    const old_mesh = manager.meshes[0].get(region.key()).?;
    const old_heights = region.data.simplified.heightmap.ptr;
    var chunk = core.Chunk.init(0, 0);
    chunk.setBlock(0, 180, 0, .stone);
    manager.source_hierarchy.?.submit(try manager.captureSceneChunk(&chunk, .live));
    ops.drainCanonicalChanges(manager);
    ops.queueCanonicalRefreshes(manager);
    try testing.expect(region.isPinned());
    const failed_job = manager.job_dispatcher.queues[core.LODLevel.count - 1].tryPop().?;
    const failed_work: *ops.CanonicalRefresh = @ptrCast(@alignCast(failed_job.data.generic.context));
    failed_work.quota.limit_bytes = 0;
    failed_job.data.generic.process_fn(failed_job.data.generic.context);
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expectEqual(old_mesh, manager.meshes[0].get(region.key()).?);
    try testing.expectEqual(old_heights, region.data.simplified.heightmap.ptr);
    try testing.expect(manager.regionContributesGeometry(region.key(), region));
    try testing.expect(region.canonical_refresh_requested.load(.acquire));
    try testing.expectEqual(@as(usize, 0), mock.uploads);

    manager.update_tick = 31;
    ops.queueCanonicalRefreshes(manager);
    try runRefresh(manager);
    mock.fail_upload = true;
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expectEqual(old_mesh, manager.meshes[0].get(region.key()).?);
    try testing.expectEqual(old_heights, region.data.simplified.heightmap.ptr);
    try testing.expectEqual(lod.LODState.renderable, region.getState());
    try testing.expectEqual(@as(usize, 1), manager.getCanonicalDiagnostics().refresh_outstanding);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.maintenance_staging_bytes);
    manager.processUploads();
    manager.processUploadsWithBudget(1024);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.maintenance_staging_bytes);
    // A change during the build/upload does not discard a useful snapshot.
    region.canonical_refresh_requested.store(true, .release);
    mock.fail_upload = false;
    manager.beginUploadFrame(1); // One oversized upload may progress, never trim too.
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.maintenance_staging_bytes);
    try testing.expect(old_mesh != manager.meshes[0].get(region.key()).?);
    try testing.expect(region.data.simplified.scene_grid != null);
    try testing.expect(region.max_height >= 181);
    try testing.expect(region.canonical_refresh_requested.load(.acquire));
    try testing.expectEqual(@as(usize, 1), manager.mesh_disposal.queue.items.len);
    try testing.expectEqual(@as(usize, 0), manager.getCanonicalDiagnostics().refresh_outstanding);
    try testing.expect(!region.isPinned());
}

test "canonical refresh admission is bounded and queue cleanup preserves source lifetime" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    for (0..12) |i| {
        const region = try resident(manager, .lod0, @intCast(i));
        region.canonical_refresh_requested.store(true, .release);
    }
    ops.queueCanonicalRefreshes(manager);
    try testing.expectEqual(@as(usize, 8), manager.getCanonicalDiagnostics().refresh_outstanding);
    // Generic cleanup can run under JobQueue's lock while main owns Self's.
    manager.mutex.lock();
    manager.job_dispatcher.queues[core.LODLevel.count - 1].clear();
    manager.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), manager.getCanonicalDiagnostics().refresh_outstanding);
    const source = manager.source_hierarchy.?;
    manager.stopWorkersAndJoin();
    manager.stopWorkersAndJoin();
    try testing.expectEqual(source, manager.source_hierarchy.?);
    try testing.expect(source.memoryBytes() > 0);
    var it = manager.regions[0].valueIterator();
    while (it.next()) |region| {
        try testing.expect(!region.*.isPinned());
        try testing.expectEqual(lod.LODState.renderable, region.*.getState());
    }
}

test "canonical manager known empty replacement contributes parent coverage" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    const region = try resident(manager, .lod0, 0);
    region.canonical_refresh_requested.store(true, .release);
    ops.queueCanonicalRefreshes(manager);
    try runRefresh(manager);
    ops.drainCanonicalRefreshes(manager, false);
    const mesh = manager.meshes[0].get(region.key()).?;
    try testing.expect(!mesh.isRenderable());
    try testing.expect(mesh.isCoverageReady());
    try testing.expect(manager.regionContributesGeometry(region.key(), region));
    try testing.expectEqual(@as(u8, 1), manager.countRenderableChildren(region.key().parentKey().?));
}

test "canonical manager saved source read errors never call procedural generator" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock = Mock{ .fail_saved = true };
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    const region = try resident(manager, .lod0, 0);
    const old_mesh = manager.meshes[0].get(region.key()).?;
    try testing.expectError(error.SavedSourceReadFailed, ops.attachCanonicalGrid(manager, &region.data.simplified, region.key(), null));
    try testing.expectEqual(@as(usize, 0), mock.generated);
    try testing.expect(region.data.simplified.scene_grid == null);
    try testing.expectEqual(old_mesh, manager.meshes[0].get(region.key()).?);
    try testing.expect(manager.regionContributesGeometry(region.key(), region));
}

test "canonical refresh releases memory blocked background slots and admits near work" {
    var config = lod.LODConfig{ .memory_budget_mb = 256 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    var background: [5]*lod.LODChunk = undefined;
    for (&background, 0..) |*region, i| {
        region.* = try resident(manager, .lod0, @intCast(i));
        region.*.service_lane = 3;
        region.*.canonical_refresh_requested.store(true, .release);
    }
    ops.queueCanonicalRefreshes(manager);
    try testing.expectEqual(@as(usize, 4), manager.canonical_refresh_count.load(.acquire));
    try testing.expectEqual(@as(usize, 4), manager.canonical_background_refresh_count.load(.acquire));
    for (0..4) |_| try runRefresh(manager);
    mock.memory_cost = 512 * 1024 * 1024;
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expectEqual(@as(usize, 0), manager.canonical_refresh_count.load(.acquire));
    try testing.expectEqual(@as(usize, 0), manager.canonical_background_refresh_count.load(.acquire));
    var backed_off: usize = 0;
    for (background) |region| {
        try testing.expect(!region.isPinned());
        try testing.expect(manager.regionContributesGeometry(region.key(), region));
        if (region.canonical_retry_tick > manager.update_tick) backed_off += 1;
    }
    try testing.expectEqual(@as(usize, 4), backed_off);
    const near = try resident(manager, .lod0, 7);
    const old_mesh = manager.meshes[0].get(near.key()).?;
    near.canonical_refresh_requested.store(true, .release);
    ops.queueCanonicalRefreshes(manager);
    try testing.expect(near.refresh_in_flight.load(.acquire));
    try testing.expect(manager.canonical_background_refresh_count.load(.acquire) <= 4);
    // The fifth background candidate is allowed, but cannot hide near progress.
    while (manager.job_dispatcher.queues[core.LODLevel.count - 1].count() > 0) try runRefresh(manager);
    mock.memory_cost = 0;
    manager.beginUploadFrame(8 * 1024 * 1024);
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expect(old_mesh != manager.meshes[0].get(near.key()).?);
    try testing.expect(!near.refresh_in_flight.load(.acquire));
}

test "canonical refresh newer provisional geometry cannot replace known air or partial coverage" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    const region = try resident(manager, .lod0, 0);
    region.canonical_refresh_requested.store(true, .release);
    ops.queueCanonicalRefreshes(manager);
    try runRefresh(manager);
    ops.drainCanonicalRefreshes(manager, false);
    const old_mesh = manager.meshes[0].get(region.key()).?;
    const old_grid = region.data.simplified.scene_grid.?;
    try testing.expect(old_mesh.isCoverageReady() and !old_mesh.isRenderable());
    manager.update_tick = 31;
    region.canonical_refresh_requested.store(true, .release);
    ops.queueCanonicalRefreshes(manager);
    try runRefresh(manager);
    const work = for (manager.canonical_completions) |slot| {
        if (slot) |completion| break completion;
    } else return error.NoCompletion;
    const replacement = work.data.?.scene_grid.?;
    replacement.source_epoch = old_grid.source_epoch + 1;
    const info = replacement.columnInfo(0, 0);
    info.known_area = 0;
    info.approximate = true;
    info.offset = @intCast(replacement.spans.items.len);
    info.count = 1;
    try replacement.spans.append(work.quota.allocator(), .{ .min_y = 0, .max_y = 20, .block = .stone, .biome = .plains, .light = core.PackedLight.init(15, 0) });
    try work.mesh.?.buildFromSceneGrid(replacement, &atlas);
    const uploads = mock.uploads;
    manager.beginUploadFrame(8 * 1024 * 1024);
    ops.drainCanonicalRefreshes(manager, false);
    try testing.expectEqual(uploads, mock.uploads);
    try testing.expectEqual(old_mesh, manager.meshes[0].get(region.key()).?);
    try testing.expectEqual(old_grid, region.data.simplified.scene_grid.?);
    try testing.expect(region.canonical_refresh_requested.load(.acquire));
    var partial = try core.lod_scene.SceneGrid.init(testing.allocator, 0, 0, 4, 1);
    defer partial.deinit();
    var newer = try core.lod_scene.SceneGrid.init(testing.allocator, 0, 0, 4, 1);
    defer newer.deinit();
    try partial.appendColumn(0, 0, &.{}, 7, 16, true);
    try newer.appendColumn(0, 0, &.{}, 6, 16, true);
    try testing.expect(!ops.preservesKnownCoverage(&partial, &newer));
    newer.columnInfo(0, 0).known_area = 7;
    try testing.expect(ops.preservesKnownCoverage(&partial, &newer));
}

test "canonical coverage rejects equal-area chunk identity swaps at coarse sizes" {
    const scene = core.lod_scene;
    const a: scene.KnownChunk = .{ .cx = -1, .cz = -1 };
    const b: scene.KnownChunk = .{ .cx = 0, .cz = -1 };
    const span: scene.SceneSpan = .{ .min_y = 10, .max_y = 20, .block = .stone, .biome = .plains, .coverage = 0.25, .light = core.PackedLight.init(15, 0) };
    for ([_]u32{ 32, 64, 128 }) |size| {
        for ([_]bool{ false, true }) |known_air| {
            var old = try scene.SceneGrid.init(testing.allocator, -16, -16, size, 1);
            defer old.deinit();
            try old.appendColumn(0, 0, if (known_air) &.{} else &.{span}, 256, size * size, true);
            try old.known_chunks.append(testing.allocator, a);

            var swapped = try scene.SceneGrid.init(testing.allocator, -16, -16, size, 1);
            defer swapped.deinit();
            try swapped.appendColumn(0, 0, &.{span}, 256, size * size, true);
            try swapped.known_chunks.append(testing.allocator, b);
            swapped.source_epoch = old.source_epoch + 1;
            try testing.expectEqual(old.columnInfo(0, 0).known_area, swapped.columnInfo(0, 0).known_area);
            try testing.expect(!ops.preservesKnownCoverage(&old, &swapped));

            var superset = try swapped.clone(testing.allocator);
            defer superset.deinit();
            superset.known_chunks.clearRetainingCapacity();
            try superset.known_chunks.appendSlice(testing.allocator, &.{ a, b });
            superset.columnInfo(0, 0).known_area = 512;
            try testing.expect(ops.preservesKnownCoverage(&old, &superset));
            try testing.expect(ops.preservesKnownCoverage(&swapped, &superset));
            try testing.expect(!ops.preservesKnownCoverage(&superset, &old));

            // New contents for the SAME source remain allowed, including an edit
            // to previously known air. A newer epoch cannot substitute chunk B.
            swapped.known_chunks.items[0] = a;
            try testing.expect(ops.preservesKnownCoverage(&old, &swapped));
            swapped.known_chunks.clearRetainingCapacity();
            try testing.expect(!ops.preservesKnownCoverage(&old, &swapped));
        }
    }
}

test "canonical quota owner survives pool upload and releases after mesh destruction" {
    const Resources = struct {
        pub fn createBuffer(_: *@This(), _: usize, _: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
            return 1;
        }
        pub fn updateBuffer(_: *@This(), _: rhi.BufferHandle, _: usize, _: []const u8) rhi.RhiError!void {}
        pub fn destroyBuffer(_: *@This(), _: rhi.BufferHandle) void {}
    };
    var resources: Resources = .{};
    const adapter = @import("lod_mesh_resources.zig").LODMeshResources.fromProvider(Resources, &resources);
    var pool = @import("lod_vertex_pool.zig").LODVertexPool.init(testing.allocator, .lod0, 1024);
    defer pool.deinit(adapter);
    const quota = try BudgetAllocator.init(testing.allocator, 1024);
    var mesh = Mesh.init(quota.allocator(), .lod0);
    quota.retain();
    mesh.allocator_owner = .{ .ptr = quota, .release_fn = BudgetAllocator.releaseOwner, .parent_allocator = testing.allocator };
    mesh.pending_vertices = try mesh.allocator.alloc(rhi.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi.Vertex));
    quota.release(); // The job has gone away before upload.
    try testing.expectEqual(@as(usize, 2), quota.snapshot().refs);
    try pool.uploadMesh(&mesh, adapter);
    try testing.expectEqual(@as(usize, 0), quota.snapshot().used);
    try testing.expectEqual(@as(usize, 1), quota.snapshot().refs);
    try testing.expectEqual(@as(usize, 3 * @sizeOf(rhi.Vertex)), quota.snapshot().peak);
    // The mesh may allocate another bounded payload after the first was freed.
    mesh.pending_vertices = try mesh.allocator.alloc(rhi.Vertex, 1);
    pool.destroyMesh(&mesh);
    try testing.expectEqual(@as(usize, 0), quota.snapshot().used);
    mesh.deinit(adapter);
    try testing.expect(mesh.allocator_owner == null);
    try testing.expectEqual(testing.allocator.ptr, mesh.allocator.ptr);
}

const EditCapture = struct {
    manager: *Manager,
    chunk: *core.Chunk,
    calls: usize = 0,
    fail: bool = false,

    fn capture(ptr: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator) !?Manager.SceneSummary {
        const self: *EditCapture = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (cx != self.chunk.chunk_x or cz != self.chunk.chunk_z) return null;
        if (self.fail) return error.CaptureFailed;
        const revision = self.manager.source_hierarchy.?.reserveRevision();
        var summary = try Manager.SceneSummary.capture(allocator, self.chunk);
        summary.origin = .live;
        summary.revision = revision;
        return summary;
    }
};

fn capturedBlock(manager: *Manager, chunk: *const core.Chunk, y: u16) ?core.BlockType {
    const provider = manager.source_hierarchy.?.provider();
    provider.lock_fn(provider.ptr);
    const acquired = provider.acquire_fn(provider.ptr, chunk.chunk_x, chunk.chunk_z);
    provider.unlock_fn(provider.ptr);
    const lease = acquired orelse return null;
    defer lease.release();
    for (lease.summary.column(0, 0)) |run| {
        if (y >= run.min_y and y < run.max_y) return run.block;
    }
    return .air;
}

test "canonical manager bulk edit marks coalesce without immediate capture" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    var chunk = core.Chunk.init(-2, 3);
    chunk.generated = true;
    var capture = EditCapture{ .manager = manager, .chunk = &chunk };
    manager.scene_resolver = .{ .ptr = &capture, .capture_scene_fn = EditCapture.capture };
    for (0..4096) |i| {
        chunk.setBlock(0, 20, 0, if (i % 2 == 0) .stone else .gold_ore);
        manager.markChunkEdited(chunk.chunk_x, chunk.chunk_z);
    }
    try testing.expectEqual(@as(usize, 0), capture.calls);
    try testing.expectEqual(@as(usize, 1), manager.ingestion_queue.pending_ingestions.items.len);
    manager.flushEditedChunksNow();
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(core.BlockType.gold_ore, capturedBlock(manager, &chunk, 20).?);
    try testing.expectEqual(@as(usize, 0), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expect(chunk.modified);
    manager.flushEditedChunksNow();
    try testing.expectEqual(@as(usize, 1), capture.calls);
}

test "canonical manager rejected edit admission and failed captures remain durable" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    var chunk = core.Chunk.init(0, 0);
    chunk.generated = true;
    chunk.setBlock(0, 20, 0, .stone);
    var capture = EditCapture{ .manager = manager, .chunk = &chunk, .fail = true };
    manager.scene_resolver = .{ .ptr = &capture, .capture_scene_fn = EditCapture.capture };
    try manager.ingestion_queue.edit_dirty.ensureTotalCapacity(1);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    manager.allocator = failing.allocator();
    manager.markChunkEdited(0, 0);
    manager.allocator = testing.allocator;
    try testing.expectEqual(@as(usize, 0), capture.calls);
    try testing.expect(manager.ingestion_queue.edit_dirty.contains(.{ .cx = 0, .cz = 0 }));
    manager.drainPendingIngestions();
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(@as(usize, 1), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(core.LODColumnProvenance.edited, manager.ingestion_queue.pending_ingestions.items[0].provenance);
    try testing.expect(capturedBlock(manager, &chunk, 20) == null);
    capture.fail = false;
    chunk.setBlock(0, 20, 0, .gold_ore);
    manager.flushEditedChunksNow();
    try testing.expectEqual(@as(usize, 2), capture.calls);
    try testing.expectEqual(core.BlockType.gold_ore, capturedBlock(manager, &chunk, 20).?);
    try testing.expectEqual(@as(usize, 0), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(@as(u32, 0), manager.ingestion_queue.edit_dirty.count());
}

test "canonical manager full edited queue retains genuine fallback edits and flushes both stores once" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    var chunk = core.Chunk.init(0, 0);
    chunk.generated = true;
    chunk.setBlock(0, 20, 0, .stone);
    var capture = EditCapture{ .manager = manager, .chunk = &chunk };
    manager.scene_resolver = .{ .ptr = &capture, .capture_scene_fn = EditCapture.capture };
    const limit = @import("lod_manager_context.zig").MAX_PENDING_INGESTIONS;
    for (0..limit) |i| manager.markChunkEdited(@intCast(i + 1), 0);
    for (0..100) |_| manager.markChunkEdited(0, 0);
    manager.requestIngestion(-1, 0, .chunk_derived);
    try testing.expectEqual(@as(usize, 0), capture.calls);
    try testing.expectEqual(limit, manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(@as(u32, 1), manager.ingestion_queue.edit_dirty.count());
    try testing.expect(manager.ingestion_queue.edit_dirty.contains(.{ .cx = 0, .cz = 0 }));
    try testing.expect(!manager.ingestion_queue.edit_dirty.contains(.{ .cx = -1, .cz = 0 }));
    manager.flushEditedChunksNow();
    try testing.expectEqual(limit + 1, capture.calls);
    try testing.expectEqual(core.BlockType.stone, capturedBlock(manager, &chunk, 20).?);
    try testing.expectEqual(limit, manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(@as(u32, 0), manager.ingestion_queue.edit_dirty.count());
}

test "canonical manager bounded fallback drain does not starve behind an absent hash key" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    try manager.ingestion_queue.edit_dirty.put(.{ .cx = 0, .cz = 0 }, {});
    try manager.ingestion_queue.edit_dirty.put(.{ .cx = 1, .cz = 0 }, {});
    var it = manager.ingestion_queue.edit_dirty.keyIterator();
    const absent = it.next().?.*;
    var chunk = core.Chunk.init(1 - absent.cx, 0);
    chunk.generated = true;
    chunk.setBlock(0, 20, 0, .stone);
    var capture = EditCapture{ .manager = manager, .chunk = &chunk };
    manager.scene_resolver = .{ .ptr = &capture, .capture_scene_fn = EditCapture.capture };
    manager.ingestion_queue.drain_per_frame = 1;
    manager.drainPendingIngestions();
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expect(capturedBlock(manager, &chunk, 20) == null);
    manager.flushEditedChunksBounded();
    try testing.expectEqual(@as(usize, 2), capture.calls);
    try testing.expectEqual(core.BlockType.stone, capturedBlock(manager, &chunk, 20).?);
    try testing.expectEqual(@as(usize, 1), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(absent.cx, manager.ingestion_queue.pending_ingestions.items[0].cx);
}

test "canonical manager unload captures final edit before cooldown and retains failed work" {
    var config = lod.LODConfig{ .memory_budget_mb = 0 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    var chunk = core.Chunk.init(0, 0);
    chunk.generated = true;
    chunk.state = .unloading;
    var capture = EditCapture{ .manager = manager, .chunk = &chunk };
    manager.scene_resolver = .{ .ptr = &capture, .capture_scene_fn = EditCapture.capture };
    chunk.setBlock(0, 20, 0, .stone);
    manager.markChunkEdited(0, 0);
    chunk.setBlock(0, 20, 0, .gold_ore);
    manager.markChunkEdited(0, 0);
    manager.ingestion_queue.edit_cooldown = 10;
    manager.flushEditedChunks();
    try testing.expectEqual(@as(usize, 0), capture.calls);
    try testing.expectEqual(@as(u8, 0), manager.flushEditedChunkForUnload(0, 0, &chunk, false));
    try testing.expectEqual(@as(usize, 1), capture.calls);
    try testing.expectEqual(core.BlockType.gold_ore, capturedBlock(manager, &chunk, 20).?);
    try testing.expectEqual(@as(usize, 0), manager.ingestion_queue.pending_ingestions.items.len);
    chunk.setBlock(0, 20, 0, .air);
    manager.markChunkEdited(0, 0);
    capture.fail = true;
    try testing.expectEqual(@as(u8, 0xff), manager.flushEditedChunkForUnload(0, 0, &chunk, false));
    try testing.expectEqual(@as(usize, 1), manager.ingestion_queue.pending_ingestions.items.len);
    try testing.expectEqual(core.BlockType.gold_ore, capturedBlock(manager, &chunk, 20).?);
    capture.fail = false;
    try testing.expectEqual(@as(u8, 0), manager.flushEditedChunkForUnload(0, 0, &chunk, false));
    try testing.expectEqual(core.BlockType.air, capturedBlock(manager, &chunk, 20).?);
    try testing.expect(chunk.modified);
    try testing.expectEqual(@as(usize, 0), manager.ingestion_queue.pending_ingestions.items.len);
}

test "canonical memory completed CPU payloads release unused allowance for GPU admission" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 64, .max_uploads_per_frame = 2 };
    var mock = Mock{ .memory_cost = 2 * MiB };
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.update_tick = 1;

    // Retained scene storage is real CPU allocation, independent of the two
    // completed upload payloads. No quota or GPU budget is raised for admission.
    const source = try resident(manager, .lod4, 0);
    const grid = try testing.allocator.create(core.lod_scene.SceneGrid);
    grid.* = try core.lod_scene.SceneGrid.init(testing.allocator, 0, 0, 8, 1);
    source.data.simplified.scene_grid = grid;
    try grid.spans.ensureTotalCapacityPrecise(testing.allocator, 15 * MiB / @sizeOf(core.lod_scene.SceneSpan));
    const regions = [_]*lod.LODChunk{
        try resident(manager, .lod1, 4),
        try resident(manager, .lod1, 5),
    };
    for (regions, 0..) |region, i| {
        const mesh = manager.meshes[1].get(region.key()).?;
        mesh.ready = false;
        mesh.vertex_count = 0;
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, MiB / @sizeOf(rhi.Vertex));
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi.Vertex));
        region.setState(if (i == 0) .mesh_ready else .uploading);
        if (i == 0) {
            manager.enqueueTransition(region.key(), region, .upload);
        } else try manager.upload_queues[1].push(region);
    }
    manager.pending_region_count = 2;
    manager.updateStats();
    try testing.expect(manager.stats.source_data_cpu_bytes >= 15 * MiB);
    try testing.expect(manager.stats.source_cache_reservation_bytes > 0);
    try testing.expectEqual(manager.stats.source_cache_reservation_bytes, manager.stats.logical_admission_reservation_bytes);
    try testing.expectEqual(manager.memory_governor.used_bytes + manager.stats.source_cache_reservation_bytes, manager.memory_governor.logical_admission_bytes);
    try testing.expect(mock.memory_cost <= 64 * MiB - manager.memory_governor.logical_admission_bytes);
    try manager.processStateTransitions(@import("engine-math").Vec3.zero);
    manager.processUploadsWithBudget(0);
    try testing.expectEqual(@as(usize, 2), mock.uploads);
    for (regions) |region| try testing.expectEqual(lod.LODState.renderable, region.getState());
    try testing.expectEqual(@as(usize, 0), manager.pending_region_count);
}

test "canonical memory CPU reservation follows allocation stages completion pins and retries" {
    var config = lod.LODConfig{ .memory_budget_mb = 64 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    const region = try resident(manager, .lod1, 4);
    const mesh = manager.meshes[1].get(region.key()).?;
    mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 3);
    const expected = BudgetAllocator.admission_bytes - eviction.regionMemoryBytes(region, mesh);
    for ([_]lod.LODState{ .queued_for_generation, .generating, .generated, .queued_for_mesh, .meshing }) |state| {
        region.setState(state);
        manager.updateStats();
        try testing.expectEqual(@as(u64, expected) + manager.stats.source_cache_reservation_bytes, manager.stats.logical_admission_reservation_bytes);
    }
    for ([_]lod.LODState{ .mesh_ready, .uploading, .missing, .renderable, .unloading }) |state| {
        region.setState(state);
        manager.updateStats();
        try testing.expectEqual(manager.stats.source_cache_reservation_bytes, manager.stats.logical_admission_reservation_bytes);
    }
    region.pin();
    for ([_]lod.LODState{ .missing, .mesh_ready, .uploading, .renderable }) |state| {
        region.setState(state);
        manager.updateStats();
        const cpu_completion = state == .missing or state == .mesh_ready;
        try testing.expectEqual(@as(u64, if (cpu_completion) expected else 0) + manager.stats.source_cache_reservation_bytes, manager.stats.logical_admission_reservation_bytes);
    }
    region.unpin();
    region.setState(.mesh_ready);
    manager.updateStats();
    const completed = manager.memory_governor.logical_admission_bytes;
    region.setState(.generated); // A CPU retry reacquires the same unused allowance.
    manager.updateStats();
    try testing.expectEqual(completed + expected, manager.memory_governor.logical_admission_bytes);
}

test "canonical admission reserves retained source cache before region work" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 256 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    // Model production's 256 MiB canonical source-cache allowance. The cache
    // is empty now, but exact source preparation can fill it concurrently with
    // the 24 MiB region reservations.
    manager.source_hierarchy.?.cache_budget_bytes = 64 * MiB;
    manager.cleanup_covered_regions = false;

    var scan: @import("lod_manager_context.zig").LODScanState = .{};
    var admitted: usize = 0;
    for (0..64) |_| {
        const result = try manager.queueLODService(.lod0, 1, &scan, 128, @import("engine-math").Vec3.zero, null, null);
        admitted += result.admitted;
        if (result.memory_blocked) break;
    }
    // The first admission itself refreshes canonical accounting: 64 MiB of
    // retained-source capacity plus eight 24 MiB canonical admissions reaches
    // the cap. A ninth must remain queued; cold start cannot first reserve ten
    // regions and only then discover the source-cache reservation.
    try testing.expectEqual(@as(usize, 8), admitted);
    try testing.expectEqual(@as(usize, 8), manager.pending_region_count);
    try testing.expect(manager.stats.source_cache_reservation_bytes >= 63 * MiB);
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 256 * MiB);
    try testing.expectEqual(@as(u64, 0), manager.stats.evictions);
}

test "canonical scheduler re-admits an unpinned missing region with one fresh allowance" {
    var config = lod.LODConfig{ .memory_budget_mb = 64 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 0;

    var scan: @import("lod_manager_context.zig").LODScanState = .{};
    try testing.expectEqual(@as(usize, 1), (try manager.queueLODService(.lod0, 1, &scan, 1, @import("engine-math").Vec3.zero, null, null)).admitted);
    var regions = manager.regions[0].valueIterator();
    const region = regions.next().?.*;
    region.setState(.missing);
    manager.pending_region_count = 0; // Models eviction/cancellation after its reservation release.
    manager.updateStats();
    const released_logical = manager.memory_governor.logical_admission_bytes;

    scan = .{};
    const retried = try manager.queueLODService(.lod0, 1, &scan, 1, @import("engine-math").Vec3.zero, null, null);
    try testing.expectEqual(@as(usize, 1), retried.admitted);
    try testing.expectEqual(released_logical + BudgetAllocator.admission_bytes, manager.memory_governor.logical_admission_bytes);
    try testing.expectEqual(@as(u32, 1), manager.pending_region_count);
}

fn addEvictableGeneratedRegion(manager: *Manager, rx: i32) !void {
    const region = try resident(manager, .lod1, rx);
    region.setState(.generated);
    const parent = region.key().parentKey().?;
    if (!manager.regions[@intFromEnum(parent.lod)].contains(parent)) {
        _ = try resident(manager, parent.lod, parent.rx);
    }
    manager.pending_region_count += 1;
}

test "canonical near admission reclaims bounded distant headroom and maintains the hard cap on retry" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 64, .active_lod_count = 3, .chunk_render_radius = 2, .radii = .{ 8, 64, 128, 256, 512 } };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 0;
    try addEvictableGeneratedRegion(manager, 10);
    try addEvictableGeneratedRegion(manager, 12);
    manager.updateStats();
    try testing.expect(manager.memory_governor.logical_admission_bytes < 64 * MiB);
    try testing.expect(manager.memory_governor.logical_admission_bytes > 64 * MiB - BudgetAllocator.admission_bytes);

    var scan: @import("lod_manager_context.zig").LODScanState = .{};
    const denied = try manager.queueLODService(.lod1, 2, &scan, 128, @import("engine-math").Vec3.zero, null, null);
    try testing.expect(denied.memory_blocked);
    try testing.expectEqual(BudgetAllocator.admission_bytes, manager.memory_governor.required_admission_bytes);
    try manager.enforceMemoryBudget();
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 64 * MiB - BudgetAllocator.admission_bytes);

    const admitted = try manager.queueLODService(.lod1, 2, &scan, 128, @import("engine-math").Vec3.zero, null, null);
    try testing.expectEqual(@as(usize, 1), admitted.admitted);
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 64 * MiB);
    const retry = try manager.queueLODService(.lod1, 2, &scan, 128, @import("engine-math").Vec3.zero, null, null);
    try testing.expect(retry.memory_blocked);
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 64 * MiB);
}

test "canonical refresh reclaims distant headroom for a near stale region" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 64, .active_lod_count = 3, .chunk_render_radius = 2, .radii = .{ 8, 64, 128, 256, 512 } };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 0;
    try addEvictableGeneratedRegion(manager, 10);
    try addEvictableGeneratedRegion(manager, 12);
    const near = try resident(manager, .lod1, 1);
    near.service_lane = 2;
    near.canonical_refresh_requested.store(true, .release);
    manager.updateStats();

    ops.queueCanonicalRefreshes(manager);
    try testing.expectEqual(BudgetAllocator.admission_bytes, manager.memory_governor.required_admission_bytes);
    try testing.expect(!near.isPinned());
    try manager.enforceMemoryBudget();
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 64 * MiB - BudgetAllocator.admission_bytes);
    ops.queueCanonicalRefreshes(manager);
    try testing.expect(near.isPinned());
    try testing.expectEqual(@as(usize, 1), manager.getCanonicalDiagnostics().refresh_outstanding);
    try testing.expect(manager.memory_governor.logical_admission_bytes <= 64 * MiB);
}

test "canonical configured horizon upload reclaims stale outer work without spending the near reserve" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 64, .active_lod_count = 5, .chunk_render_radius = 2, .radii = .{ 8, 64, 128, 256, 512 } };
    var mock = Mock{ .memory_cost = 8 * MiB };
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 0;
    try addEvictableGeneratedRegion(manager, 10);
    try addEvictableGeneratedRegion(manager, 12);
    const horizon = try resident(manager, .lod4, 3);
    horizon.service_lane = @intFromEnum(@import("lod_service.zig").Class.horizon);
    horizon.setState(.uploading);
    try manager.upload_queues[4].push(horizon);
    manager.pending_region_count += 1;
    manager.updateStats();
    const soft_limit = 64 * MiB * 3 / 4;
    try testing.expect(manager.memory_governor.logical_admission_bytes > soft_limit - mock.memory_cost);

    manager.processUploadsWithBudget(0);
    try testing.expectEqual(@as(usize, 0), mock.uploads);
    try testing.expectEqual(mock.memory_cost, manager.memory_governor.required_horizon_upload_bytes);
    try manager.enforceMemoryBudget();
    try testing.expect(manager.memory_governor.logical_admission_bytes <= soft_limit - mock.memory_cost);
    try testing.expectEqual(lod.LODState.uploading, horizon.getState());

    manager.beginUploadFrame(0);
    manager.processUploadsWithBudget(0);
    try testing.expectEqual(@as(usize, 1), mock.uploads);
    try testing.expectEqual(lod.LODState.renderable, horizon.getState());
    try testing.expect(manager.memory_governor.logical_admission_bytes <= soft_limit);
}

test "canonical horizon publishes through near-consumed reserve without eviction" {
    const MiB = 1024 * 1024;
    const horizon_lane = @intFromEnum(@import("lod_service.zig").Class.horizon);
    const horizon_upload_bytes = 1 * MiB;
    var config = lod.LODConfig{
        .memory_budget_mb = 256,
        .active_lod_count = 5,
        .max_uploads_per_frame = 1,
    };
    // The pool contains 64 MiB assigned to the near mesh plus 103 MiB of
    // global slack. Only the active near range is reserve consumption.
    var mock = Mock{ .memory_cost = horizon_upload_bytes, .pool_memory_bytes = 167 * MiB };
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 64 * MiB;

    const near = try resident(manager, .lod0, 0);
    near.service_lane = @intFromEnum(@import("lod_service.zig").Class.local_fallback);
    const near_mesh = manager.meshes[0].get(near.key()).?;
    near_mesh.capacity = @intCast((64 * MiB) / @sizeOf(rhi.Vertex));
    near_mesh.pooled = true;

    var horizons: [3]*lod.LODChunk = undefined;
    for (&horizons, 0..) |*slot, i| {
        const region = try resident(manager, .lod4, @intCast(i));
        region.service_lane = horizon_lane;
        region.setState(.uploading);
        const mesh = manager.meshes[4].get(region.key()).?;
        mesh.ready = false;
        mesh.vertex_count = 0;
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, horizon_upload_bytes / @sizeOf(rhi.Vertex));
        try manager.upload_queues[4].push(region);
        slot.* = region;
    }
    manager.pending_region_count = horizons.len;
    manager.updateStats();

    const budget = 256 * MiB;
    const static_soft_limit = @import("lod_service.zig").memoryLimit(horizon_lane, budget);
    try testing.expect(manager.memory_governor.logical_admission_bytes > static_soft_limit);
    try testing.expect(manager.memory_governor.logical_admission_bytes + horizon_upload_bytes <= budget);
    try testing.expect(manager.memory_governor.near_exclusive_bytes >= 64 * MiB);

    // Each publication is admitted by the production upload path. There are no
    // evictable fallback victims in this fixture, so this proves the service
    // policy itself—not recovery—makes the bounded horizon work feasible.
    for (0..horizons.len) |_| {
        manager.beginUploadFrame(0);
        manager.processUploadsWithBudget(0);
    }
    try testing.expectEqual(horizons.len, mock.uploads);
    for (horizons) |region| try testing.expectEqual(lod.LODState.renderable, region.getState());
    try testing.expectEqual(@as(u64, 0), manager.stats.evictions);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.required_horizon_upload_bytes);
}

test "canonical infeasible admission does not request blind recovery" {
    var config = lod.LODConfig{ .memory_budget_mb = 16 };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    manager.source_hierarchy.?.cache_budget_bytes = 0;
    var scan: @import("lod_manager_context.zig").LODScanState = .{};
    const denied = try manager.queueLODService(.lod0, 1, &scan, 1, @import("engine-math").Vec3.zero, null, null);
    try testing.expect(denied.memory_blocked);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.required_admission_bytes);
    try testing.expect(!manager.memory_governor.pressure_pending);
}

test "canonical eviction preserves the local service collar under pressure" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{
        .memory_budget_mb = 64,
        .active_lod_count = 3,
        .chunk_render_radius = 2,
        .radii = .{ 8, 64, 128, 256, 512 },
    };
    var mock = Mock{ .pool_memory_bytes = 60 * MiB };
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();

    // LOD1 region (1, 0) starts at chunk x=4, inside the scheduler's
    // full-detail radius plus its four-chunk local-service collar. The distant
    // candidates can be reclaimed, but this target must remain admissible for
    // the next near-service turn even while known GPU debt is over budget.
    const target = try resident(manager, .lod1, 1);
    target.setState(.generated);
    _ = try resident(manager, target.key().parentKey().?.lod, target.key().parentKey().?.rx);
    for ([_]i32{ 10, 12 }) |rx| {
        const region = try resident(manager, .lod1, rx);
        region.setState(.generated);
        const parent = region.key().parentKey().?;
        if (!manager.regions[@intFromEnum(parent.lod)].contains(parent)) _ = try resident(manager, parent.lod, parent.rx);
    }
    manager.pending_region_count = 3;
    manager.updateStats();
    try testing.expect(manager.memory_governor.logical_admission_bytes > 64 * MiB);
    try manager.enforceMemoryBudget();
    try testing.expect(manager.regions[1].contains(target.key()));
}

test "canonical memory eviction removes exact generated reservation without extra victims or GPU credit" {
    const MiB = 1024 * 1024;
    var config = lod.LODConfig{ .memory_budget_mb = 64, .active_lod_count = 3, .chunk_render_radius = 2, .radii = .{ 8, 64, 128, 256, 512 } };
    var mock: Mock = .{};
    const atlas = atlasFixture();
    const manager = try init(&config, &mock, &atlas);
    defer manager.deinit();
    // This regression isolates region-reservation release. Source-cache
    // admission is covered separately and intentionally has no spare capacity here.
    manager.source_hierarchy.?.cache_budget_bytes = 0;
    var keys: [3]lod.LODRegionKey = undefined;
    for (&keys, 0..) |*key, i| {
        const region = try resident(manager, .lod1, @intCast((i + 1) * 4));
        key.* = region.key();
        region.setState(.generated);
        const parent_key = key.parentKey().?;
        _ = try resident(manager, parent_key.lod, parent_key.rx);
        const mesh = manager.meshes[1].get(key.*).?;
        mesh.ready = false;
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 64);
    }
    manager.pending_region_count = 3;
    const victim = manager.regions[1].get(keys[2]).?;
    const victim_mesh = manager.meshes[1].get(keys[2]).?;
    victim_mesh.capacity = 128; // A previous upload may still own backing.
    const retained_gpu = 128 * @sizeOf(rhi.Vertex);
    const released_cpu = eviction.regionMemoryBytes(victim, victim_mesh);
    manager.updateStats();
    const used_before = manager.memory_governor.used_bytes;
    const logical_before = manager.memory_governor.logical_admission_bytes;
    try testing.expect(logical_before > 64 * MiB);
    try manager.enforceMemoryBudget();
    try testing.expect(!manager.regions[1].contains(keys[2]));
    for (keys[0..2]) |key| try testing.expect(manager.regions[1].contains(key));
    try testing.expectEqual(@as(u32, 1), manager.stats.evictions);
    try testing.expectEqual(@as(usize, 2), manager.pending_region_count);
    try testing.expectEqual(used_before - released_cpu, manager.memory_governor.used_bytes);
    try testing.expectEqual(logical_before - BudgetAllocator.admission_bytes, manager.memory_governor.logical_admission_bytes);
    const logical_after = manager.memory_governor.logical_admission_bytes;
    const shrink = manager.memory_governor.radius_shrink_chunks;
    try testing.expectEqual(@as(i32, 17), shrink[1]);
    manager.updateStats();
    try testing.expectEqual(logical_after, manager.memory_governor.logical_admission_bytes);
    try testing.expectEqual(used_before - released_cpu, manager.memory_governor.used_bytes);
    try testing.expectEqual(@as(u64, retained_gpu), manager.stats.deferred_deletion_gpu_bytes);
    try testing.expectEqual(@as(u64, 0), manager.stats.deferred_deletion_cpu_bytes);
    try manager.enforceMemoryBudget();
    try testing.expectEqual(@as(u32, 1), manager.stats.evictions);
    try testing.expectEqualSlices(i32, &shrink, &manager.memory_governor.radius_shrink_chunks);
}

test "canonical memory distance and coverage eviction retain pending bytes but release CPU allowance" {
    const Checker = struct {
        fn loaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };
    for ([_]bool{ false, true }) |covered| {
        var config = lod.LODConfig{ .memory_budget_mb = 64, .chunk_render_radius = 64 };
        var mock: Mock = .{};
        const atlas = atlasFixture();
        const manager = try init(&config, &mock, &atlas);
        defer manager.deinit();
        const region = try resident(manager, .lod1, if (covered) 0 else 1000);
        const key = region.key();
        region.setState(.generated);
        const mesh = manager.meshes[1].get(key).?;
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 64);
        manager.pending_region_count = 1;
        const source_bytes = eviction.regionMemoryBytes(region, null);
        const reservation = eviction.unusedCpuBuildReservation(manager, region, mesh);
        manager.updateStats();
        const used = manager.memory_governor.used_bytes;
        const logical = manager.memory_governor.logical_admission_bytes;
        if (covered) {
            manager.unloadLODWhereChunksLoaded(Checker.loaded, &mock);
        } else try manager.unloadDistantForLevel(.lod1, config.radii[1]);
        try testing.expect(!manager.regions[1].contains(key));
        try testing.expectEqual(used - source_bytes, manager.memory_governor.used_bytes);
        try testing.expectEqual(logical - source_bytes - reservation, manager.memory_governor.logical_admission_bytes);
        manager.updateStats();
        try testing.expectEqual(logical - source_bytes - reservation, manager.memory_governor.logical_admission_bytes);
        try testing.expectEqual(@as(u64, 64 * @sizeOf(rhi.Vertex)), manager.stats.deferred_deletion_cpu_bytes);
    }
}
