const std = @import("std");
const testing = std.testing;
const engine_core = @import("engine-core");
const rhi = @import("engine-rhi");
const lod_chunk = @import("lod_chunk.zig");
const LODChunk = lod_chunk.LODChunk;
const LODLevel = lod_chunk.LODLevel;
const LODConfig = lod_chunk.LODConfig;
const LODManager = @import("lod_manager.zig").LODManager;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const gpu = @import("lod_upload_queue.zig");
const service = @import("lod_service.zig");
const vertex_bytes = @sizeOf(rhi.Vertex);

const UploadMock = struct {
    calls: usize = 0,
    memory_calls: usize = 0,
    staging_calls: usize = 0,
    far_staging_bytes: usize = 0,
    far_memory_bytes: usize = 0,
    fail: bool = false,

    fn upload(mesh: *LODMesh, ctx: *anyopaque) rhi.RhiError!void {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return error.OutOfMemory;
        mesh.vertex_count = @intCast(mesh.pending_vertices.?.len);
        mesh.opaque_vertex_count = mesh.vertex_count;
        mesh.ready = true;
        mesh.clearPendingVertices();
    }

    fn destroy(_: *LODMesh, _: *anyopaque) void {}
    fn waitIdle(_: *anyopaque) void {
        unreachable;
    }

    fn stagingCost(mesh: *LODMesh, ctx: *anyopaque) @import("lod_mesh_resources.zig").LODStagingCost {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.staging_calls += 1;
        return .{ .payload_bytes = mesh.pendingUploadBytes(), .migration_bytes = if (mesh.lodLevel() == .lod4) self.far_staging_bytes else 0 };
    }

    fn memoryCost(mesh: *LODMesh, ctx: *anyopaque) usize {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.memory_calls += 1;
        std.debug.assert(self.memory_calls <= 128);
        return if (mesh.lodLevel() == .lod4) self.far_memory_bytes else 0;
    }
};

fn initManager(config: *LODConfig, mock: *UploadMock) !LODManager {
    var manager = try LODManager.initCacheTestManager(testing.allocator, "");
    manager.config = config.interface();
    manager.renderer = .{ .render_fn = undefined, .deinit_fn = undefined, .ptr = mock };
    manager.gpu_bridge = .{
        .on_upload = UploadMock.upload,
        .on_destroy = UploadMock.destroy,
        .on_wait_idle = UploadMock.waitIdle,
        .on_upload_cost = UploadMock.stagingCost,
        .on_upload_memory_cost = UploadMock.memoryCost,
        .ctx = mock,
    };
    for (0..LODLevel.count) |i| {
        manager.regions[i] = gpu.RegionMap.init(testing.allocator);
        manager.meshes[i] = gpu.MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try engine_core.ring_buffer.RingBuffer(*LODChunk).init(testing.allocator, 4);
        manager.job_dispatcher.queues[i] = try testing.allocator.create(engine_core.job_system.JobQueue);
        manager.job_dispatcher.queues[i].* = engine_core.job_system.JobQueue.init(testing.allocator);
    }
    return manager;
}

fn deinitManager(manager: *LODManager) void {
    manager.cache_io.deinit();
    for (0..LODLevel.count) |i| {
        var regions = manager.regions[i].valueIterator();
        while (regions.next()) |chunk| {
            chunk.*.deinit(testing.allocator);
            testing.allocator.destroy(chunk.*);
        }
        var meshes = manager.meshes[i].valueIterator();
        while (meshes.next()) |mesh| {
            mesh.*.clearPendingVertices();
            testing.allocator.destroy(mesh.*);
        }
        manager.regions[i].deinit();
        manager.meshes[i].deinit();
        manager.upload_queues[i].deinit();
        manager.job_dispatcher.queues[i].deinit();
        testing.allocator.destroy(manager.job_dispatcher.queues[i]);
    }
    manager.ingestion_queue.edit_dirty.deinit();
    manager.generation_tokens.deinit(testing.allocator);
    manager.transition_tokens.deinit(testing.allocator);
    manager.fade_tokens.deinit(testing.allocator);
}

fn enqueue(manager: *LODManager, lod: LODLevel, rx: i32, lane: u3, empty: bool) !*LODChunk {
    const chunk = try testing.allocator.create(LODChunk);
    chunk.* = LODChunk.init(rx, 0, lod);
    chunk.service_lane = lane;
    chunk.setState(.uploading);
    chunk.data = .{ .simplified = try lod_chunk.LODSimplifiedData.initWithGridSize(testing.allocator, lod, 2) };
    const i = @intFromEnum(lod);
    try manager.regions[i].put(chunk.key(), chunk);
    if (!empty) {
        const mesh = try testing.allocator.create(LODMesh);
        mesh.* = LODMesh.init(testing.allocator, lod);
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 1);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi.Vertex));
        try manager.meshes[i].put(chunk.key(), mesh);
    }
    try manager.upload_queues[i].push(chunk);
    manager.pending_region_count += 1;
    return chunk;
}

test "LOD service upload weighted turns persist with continuous coarse work and lane FIFO" {
    var config = LODConfig{ .max_uploads_per_frame = 1, .memory_budget_mb = 0 };
    var mock: UploadMock = .{};
    var manager = try initManager(&config, &mock);
    defer deinitManager(&manager);
    const levels = [_]LODLevel{ .lod0, .lod0, .lod1, .lod4, .lod3 };
    var first: [service.CLASS_COUNT]*LODChunk = undefined;
    var second: [service.CLASS_COUNT]*LODChunk = undefined;
    for ([_]u3{ 1, 0, 2, 3, 4 }) |lane| first[lane] = try enqueue(&manager, levels[lane], lane, lane, false);
    for ([_]u3{ 1, 0, 2, 3, 4 }) |lane| second[lane] = try enqueue(&manager, levels[lane], 10 + @as(i32, lane), lane, false);
    var expected: [service.CLASS_COUNT]u64 = @splat(0);
    for (0..2) |cycle| {
        for (service.WHEEL, 0..) |lane, turn| {
            // Both coarse classes are replenished faster than they drain.
            const rx: i32 = @intCast(100 + cycle * service.WHEEL.len + turn);
            _ = try enqueue(&manager, .lod4, rx, 3, false);
            _ = try enqueue(&manager, .lod3, rx, 4, false);
            manager.processUploadsWithBudget(vertex_bytes);
            expected[lane] += 1;
            try testing.expectEqualSlices(u64, &expected, &manager.service_counters.snapshot().renderable);
            try testing.expect(first[lane].isRenderable());
            if (expected[lane] >= 2) try testing.expect(second[lane].isRenderable());
            try testing.expectEqual(cycle * service.WHEEL.len + turn + 1, mock.calls);
        }
    }
}

test "LOD service upload first owed migration runs next call despite replenished small work" {
    var config = LODConfig{ .max_uploads_per_frame = 1, .memory_budget_mb = 1 };
    var mock = UploadMock{ .far_staging_bytes = 64 * 1024 * 1024, .far_memory_bytes = 1024 };
    var manager = try initManager(&config, &mock);
    defer deinitManager(&manager);
    const huge = try enqueue(&manager, .lod4, 0, 4, false);
    const later_huge = try enqueue(&manager, .lod4, 1, 4, false);
    const small = try enqueue(&manager, .lod1, 0, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(small.isRenderable() and !huge.isRenderable());
    try testing.expect(lod_chunk.LODRegionKey.eql(huge.key(), manager.service_upload_owed.?.key));
    const cursor = manager.service_upload_wheel.cursor;
    const next_small = try enqueue(&manager, .lod1, 1, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(huge.isRenderable());
    try testing.expect(!later_huge.isRenderable() and !next_small.isRenderable());
    try testing.expect(manager.service_upload_owed == null);
    try testing.expectEqual(cursor, manager.service_upload_wheel.cursor);
    try testing.expectEqual(@as(usize, 0), manager.memory_governor.maintenance_staging_bytes);
    try testing.expectEqual(@as(usize, 2), mock.calls);
    // The bonus did not consume/reset an ordinary turn or create another bonus.
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(next_small.isRenderable() and !later_huge.isRenderable());
    try testing.expect(manager.service_upload_owed == null);
    // Level rotation visits the near level first after the owed LOD4 upload,
    // then discovers the next migration on the following ordinary selection.
    const replenished = try enqueue(&manager, .lod1, 2, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(replenished.isRenderable() and !later_huge.isRenderable());
    try testing.expect(lod_chunk.LODRegionKey.eql(later_huge.key(), manager.service_upload_owed.?.key));
    const final_small = try enqueue(&manager, .lod1, 3, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(later_huge.isRenderable() and !final_small.isRenderable());
    try testing.expect(manager.service_upload_owed == null);
}

test "LOD service upload old LOD3 progresses despite continual same lane LOD0 uploads" {
    inline for (.{ false, true }) |oversized| {
        var config = LODConfig{ .active_lod_count = 5, .max_uploads_per_frame = 1, .memory_budget_mb = 1 };
        var mock: UploadMock = .{};
        var manager = try initManager(&config, &mock);
        defer deinitManager(&manager);
        const old = try enqueue(&manager, .lod3, 0, 4, false);
        const mesh = manager.meshes[3].get(old.key()).?;
        if (oversized) {
            mesh.clearPendingVertices();
            mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 2);
            @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi.Vertex));
        }

        // Unlike LOD4, LOD3 starts AFTER LOD0 in the legacy level order.
        // Restarting that order on each call would never inspect the old mesh.
        const first_small = try enqueue(&manager, .lod0, 0, 4, false);
        manager.processUploadsWithBudget(vertex_bytes);
        try testing.expect(first_small.isRenderable() and !old.isRenderable());
        try testing.expect(manager.service_upload_owed == null);
        const next_small = try enqueue(&manager, .lod0, 1, 4, false);
        manager.processUploadsWithBudget(vertex_bytes);
        try testing.expectEqual(@as(usize, 2), mock.calls);

        if (oversized) {
            try testing.expect(next_small.isRenderable() and !old.isRenderable());
            const owed = manager.service_upload_owed.?;
            try testing.expect(lod_chunk.LODRegionKey.eql(old.key(), owed.key));
            try testing.expect(owed.matches(old));
            try testing.expectEqual(old.service_lane, owed.service_lane);
            const cursor = manager.service_upload_wheel.cursor;
            const replenished = try enqueue(&manager, .lod0, 2, 4, false);
            manager.processUploadsWithBudget(vertex_bytes);
            try testing.expect(!replenished.isRenderable());
            try testing.expectEqual(cursor, manager.service_upload_wheel.cursor);
            try testing.expectEqual(@as(usize, 3), mock.calls);
        } else {
            try testing.expect(!next_small.isRenderable());
        }
        try testing.expect(old.isRenderable());
        try testing.expect(!old.isPinned());
        try testing.expect(mesh.pending_vertices == null);
        try testing.expect(manager.service_upload_owed == null);
        try testing.expectEqual(@as(usize, 0), manager.memory_governor.maintenance_staging_bytes);
        try testing.expectEqual(@as(u64, if (oversized) 3 else 2), manager.service_counters.snapshot().renderable[4]);
    }
}

test "LOD service upload memory denied owed cannot reach staging or block small work" {
    var config = LODConfig{ .max_uploads_per_frame = 1, .memory_budget_mb = 1 };
    var mock = UploadMock{ .far_staging_bytes = 64 * 1024 * 1024, .far_memory_bytes = 1024 };
    var manager = try initManager(&config, &mock);
    defer deinitManager(&manager);
    const huge = try enqueue(&manager, .lod4, 0, 4, false);
    _ = try enqueue(&manager, .lod1, 0, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(manager.service_upload_owed != null);
    mock.far_memory_bytes = 1024 * 1024;
    const staging_before = mock.staging_calls;
    const small = try enqueue(&manager, .lod1, 1, 4, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(small.isRenderable() and !huge.isRenderable());
    try testing.expect(manager.service_upload_owed == null);
    try testing.expectEqual(staging_before + 1, mock.staging_calls);
    try testing.expectEqual(mock.far_memory_bytes, manager.memory_governor.required_upload_bytes);
    try testing.expect(manager.memory_governor.pressure_pending);
    const calls_before = mock.memory_calls;
    config.max_uploads_per_frame = 8;
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expectEqual(calls_before + 1, mock.memory_calls);
    try testing.expectEqual(@as(usize, 2), mock.calls);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[4].count());
    try testing.expect(!huge.isPinned());
    try testing.expect(manager.meshes[4].get(huge.key()).?.pending_vertices != null);
}

test "LOD service upload stale or unqueued owed identity has no bonus effect" {
    inline for (.{ "job_token", "source_revision", "service_lane", "unqueued" }) |invalidated| {
        var config = LODConfig{ .max_uploads_per_frame = 1, .memory_budget_mb = 0 };
        var mock = UploadMock{ .far_staging_bytes = 64 * 1024 * 1024 };
        var manager = try initManager(&config, &mock);
        defer deinitManager(&manager);
        const huge = try enqueue(&manager, .lod4, 0, 4, false);
        _ = try enqueue(&manager, .lod1, 0, 4, false);
        manager.processUploadsWithBudget(vertex_bytes);
        try testing.expect(manager.service_upload_owed != null);
        if (comptime std.mem.eql(u8, invalidated, "unqueued")) {
            try testing.expectEqual(huge, manager.upload_queues[4].pop().?);
        } else {
            @field(huge, invalidated) +%= 1;
            if (comptime std.mem.eql(u8, invalidated, "service_lane")) huge.service_lane = 3;
        }
        const small = try enqueue(&manager, .lod1, 1, 4, false);
        manager.processUploadsWithBudget(vertex_bytes);
        try testing.expect(small.isRenderable() and !huge.isRenderable());
        try testing.expectEqual(@as(usize, 2), mock.calls);
        if (manager.service_upload_owed) |renewed| {
            try testing.expect(renewed.matches(huge));
            try testing.expectEqual(huge.service_lane, renewed.service_lane);
        }
    }
}

test "LOD service upload counts only actual renderable transitions including empty completion" {
    var config = LODConfig{ .max_uploads_per_frame = 1, .memory_budget_mb = 0 };
    var mock = UploadMock{ .fail = true };
    var manager = try initManager(&config, &mock);
    defer deinitManager(&manager);
    const chunk = try enqueue(&manager, .lod1, 0, 2, false);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expectEqual(@as(u64, 0), manager.service_counters.snapshot().renderable[2]);
    try testing.expectEqual(lod_chunk.LODState.uploading, chunk.getState());
    mock.fail = false;
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().renderable[2]);
    manager.markRegionRenderable(chunk.key(), chunk);
    try testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().renderable[2]);
    const empty = try enqueue(&manager, .lod0, 0, 0, true);
    manager.processUploadsWithBudget(vertex_bytes);
    try testing.expect(empty.isRenderable());
    try testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().renderable[0]);
    try testing.expectEqual(@as(usize, 2), mock.calls);
    try testing.expectEqual(@as(u32, 0), manager.pending_region_count);
}
