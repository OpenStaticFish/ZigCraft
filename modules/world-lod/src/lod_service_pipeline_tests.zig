const std = @import("std");
const testing = std.testing;
const engine_core = @import("engine-core");
const Vec3 = @import("engine-math").Vec3;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi = @import("engine-rhi");
const lod = @import("lod_chunk.zig");
const LODManager = @import("lod_manager.zig").LODManager;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const core = @import("lod_manager_core_ops.zig");
const generation = @import("lod_manager_generation_ops.zig");
const context = @import("lod_manager_context.zig");
const gpu = @import("lod_upload_queue.zig");
const service = @import("lod_service.zig");

fn total(values: @Vector(service.CLASS_COUNT, u64)) u64 {
    return @reduce(.Add, values);
}

const Fixture = struct {
    manager: LODManager = undefined,
    atlas: TextureAtlas = undefined,
    queue: engine_core.job_system.JobQueue = undefined,
    config: lod.LODConfig = .{
        .radii = .{ 32, 64, 128, 256, 1024 },
        .chunk_render_radius = 2,
        .active_lod_count = 5,
        .max_uploads_per_frame = 1,
        // Isolate service from memory admission; budget guards have separate tests.
        .memory_budget_mb = 0,
        .sample_density = @splat(0.0625),
        .mesh_path = .heightfield,
        .vertical_span_budget = 0,
        .compact_tiles_enabled = false,
    },
    generated: usize = 0,
    uploaded: usize = 0,
    executed: [service.CLASS_COUNT]u64 = @splat(0),

    fn init(self: *Fixture) !void {
        self.queue = engine_core.job_system.JobQueue.init(testing.allocator);
        @memset(std.mem.asBytes(&self.atlas.tile_mappings), 0);
        self.atlas.tile_luminance = @splat(TextureAtlas.BlockTileLuminance.uniform(1.0));
        self.atlas.tile_colors = @splat(TextureAtlas.BlockTileColor.uniform(0xffffff));
        // No cache path, cache thread, renderer or worker pool is needed by these
        // production stages. Initialize in place so callback pointers stay valid.
        self.manager = .{
            .allocator = testing.allocator,
            .config = self.config.interface(),
            .regions = undefined,
            .meshes = undefined,
            .job_dispatcher = .{ .queues = @splat(&self.queue) },
            .upload_queues = undefined,
            .transition_queue = .empty,
            .player_cx = .init(0),
            .player_cz = .init(0),
            .scan_states = @splat(.{}),
            .stats = .{},
            .profiling = .init(false),
            .cache_hits = 0,
            .cache_misses = 0,
            .cancelled_jobs = 0,
            .mutex = .{},
            .gpu_bridge = .{ .on_upload = upload, .on_destroy = destroy, .on_wait_idle = waitIdle, .ctx = self },
            .generator = .{ .ptr = self, .generate_heightmap_only = generate, .maybe_recenter_cache = recenter, .seed = 1, .identity_hash = 1, .version = 1 },
            .atlas = &self.atlas,
            .paused = false,
            .memory_governor = .{},
            .mesh_disposal = .{},
            .renderer = undefined,
            .cache_store = .{},
            .cache_io = undefined,
            .ingestion_queue = @import("lod_manager.zig").LODIngestionQueue.init(testing.allocator),
        };
        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| self.manager.upload_queues[i].deinit();
            self.manager.ingestion_queue.deinit(testing.allocator);
            self.queue.deinit();
        }
        for (0..lod.LODLevel.count) |i| {
            self.manager.regions[i] = gpu.RegionMap.init(testing.allocator);
            self.manager.meshes[i] = gpu.MeshMap.init(testing.allocator);
            self.manager.upload_queues[i] = try engine_core.ring_buffer.RingBuffer(*lod.LODChunk).init(testing.allocator, 128);
            initialized += 1;
        }
        self.manager.generation_tokens.enableServiceLanes(&service.WHEEL);
        self.manager.transition_tokens.enableServiceLanes(&service.WHEEL);
        self.queue.enableServiceLanes(&service.WHEEL);
    }

    fn deinit(self: *Fixture) void {
        for (0..lod.LODLevel.count) |i| {
            var chunks = self.manager.regions[i].valueIterator();
            while (chunks.next()) |chunk| {
                std.debug.assert(!chunk.*.isPinned());
                chunk.*.deinit(testing.allocator);
                testing.allocator.destroy(chunk.*);
            }
            var meshes = self.manager.meshes[i].valueIterator();
            while (meshes.next()) |mesh| {
                mesh.*.clearPendingVertices();
                mesh.*.releasePendingCompactTile();
                testing.allocator.destroy(mesh.*);
            }
            self.manager.regions[i].deinit();
            self.manager.meshes[i].deinit();
            self.manager.upload_queues[i].deinit();
        }
        self.queue.deinit();
        self.manager.generation_tokens.deinit(testing.allocator);
        self.manager.transition_tokens.deinit(testing.allocator);
        self.manager.fade_tokens.deinit(testing.allocator);
        self.manager.ingestion_queue.deinit(testing.allocator);
    }

    fn generate(ptr: *anyopaque, data: *lod.LODSimplifiedData, _: i32, _: i32, _: lod.LODLevel, _: ?*const std.atomic.Value(bool)) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.generated += 1;
        for (0..data.width) |z| for (0..data.width) |x| {
            data.setGeneratedColumn(@intCast(x), @intCast(z), 64, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4f8c45, .empty, .daylight, .empty);
        };
    }

    fn recenter(_: *anyopaque, _: i32, _: i32) bool {
        return false;
    }

    fn upload(mesh: *LODMesh, ptr: *anyopaque) rhi.RhiError!void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        const vertices = mesh.pending_vertices orelse return error.InvalidState;
        if (vertices.len == 0 or vertices.len % 3 != 0 or mesh.isCompact()) return error.InvalidState;
        self.uploaded += 1;
        mesh.vertex_count = @intCast(vertices.len);
        mesh.opaque_vertex_count = mesh.vertex_count;
        mesh.ready = true;
        mesh.clearPendingVertices();
    }

    fn destroy(_: *LODMesh, _: *anyopaque) void {
        unreachable;
    }

    fn waitIdle(_: *anyopaque) void {
        unreachable;
    }

    fn tick(self: *Fixture, jobs_per_tick: usize) !void {
        std.debug.assert(jobs_per_tick <= 2);
        self.manager.update_tick += 1;
        const before = self.manager.service_counters.snapshot();
        core.queueServiceAdmissions(&self.manager, Vec3.zero, null, null);
        const admitted = self.manager.service_counters.snapshot().admitted;
        try testing.expect(total(admitted) - total(before.admitted) <= 64);
        try testing.expect(self.manager.pending_region_count <= context.MAX_PENDING_LOD_REGIONS);
        try self.manager.processQueuedGenerations(Vec3.zero);
        try self.manager.processStateTransitions(Vec3.zero);
        for (0..jobs_per_tick) |_| {
            const job = self.queue.tryPop() orelse break;
            const key = lod.LODRegionKey{ .rx = job.data.chunk.x, .rz = job.data.chunk.z, .lod = @enumFromInt(job.data.chunk.lod_level) };
            const chunk = self.manager.regions[@intFromEnum(key.lod)].get(key).?;
            generation.processLODJob(&self.manager, job);
            switch (chunk.getState()) {
                .generated, .mesh_ready => self.executed[job.service_lane] += 1,
                .missing => {}, // Real stale-position rejection after movement.
                else => return error.TestUnexpectedResult,
            }
            try testing.expect(!chunk.isPinned());
        }
        const uploads_before = self.uploaded;
        self.manager.processUploads();
        try testing.expect(self.uploaded - uploads_before <= 1);
        const after = self.manager.service_counters.snapshot();
        try testing.expectEqualSlices(u64, &self.executed, &after.started);
        try testing.expectEqual(self.uploaded, total(after.renderable));
        var renderable: [service.CLASS_COUNT]u64 = @splat(0);
        var pending: usize = 0;
        for (0..lod.LODLevel.count) |i| {
            var chunks = self.manager.regions[i].valueIterator();
            while (chunks.next()) |chunk| {
                try testing.expect(!chunk.*.isPinned());
                switch (chunk.*.getState()) {
                    .queued_for_generation, .generating, .generated, .meshing, .mesh_ready, .uploading => pending += 1,
                    else => {},
                }
                if (!chunk.*.isRenderable()) continue;
                renderable[chunk.*.service_lane] += 1;
                const mesh = self.manager.meshes[i].get(chunk.*.key()).?;
                try testing.expect(mesh.ready and mesh.vertex_count > 0 and mesh.pending_vertices == null);
            }
        }
        try testing.expectEqualSlices(u64, &renderable, &after.renderable);
        try testing.expectEqual(pending, self.manager.pending_region_count);
        for (0..service.CLASS_COUNT) |lane| {
            try testing.expect(after.started[lane] <= after.dispatched[lane]);
            try testing.expect(2 * after.renderable[lane] <= after.started[lane]);
        }
    }
};

test "LOD service pipeline near terrain becomes renderable before horizon backlog drains" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var first_renderable: [service.CLASS_COUNT]?usize = @splat(null);
    // A tick is one admission/dispatch/transition pass, at most two dequeued
    // callbacks, and one upload. This is an opportunity bound, not wall time.
    for (1..257) |tick| {
        try f.tick(2);
        const snapshot = f.manager.getStats().service;
        const horizon = @intFromEnum(service.Class.horizon);
        try testing.expect(snapshot.admitted[horizon] > snapshot.renderable[horizon]);
        for (0..service.CLASS_COUNT) |lane| {
            if (first_renderable[lane] == null and snapshot.renderable[lane] > 0) first_renderable[lane] = tick;
        }
    }
    for (first_renderable) |tick| try testing.expect(tick != null and tick.? <= 256);
    try testing.expect(f.generated > 0);
    try testing.expect(total(f.manager.service_pending_blocked) > 0);
    try testing.expectEqual(@as(i32, 6), f.manager.near_scan_states[0].effective_radius);
    try testing.expectEqual(@as(i32, 6), f.manager.near_scan_states[1].effective_radius);
}

test "LOD service pipeline fresh negative-position demand progresses after pending saturation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    // Fill through real admissions/dispatch, leaving workers unscheduled.
    for (0..16) |_| {
        try f.tick(0);
        if (f.manager.pending_region_count == context.MAX_PENDING_LOD_REGIONS) break;
    }
    try testing.expectEqual(context.MAX_PENDING_LOD_REGIONS, f.manager.pending_region_count);
    const before = f.manager.service_counters.snapshot();
    try testing.expectEqual(@as(u64, 0), total(before.started));
    core.storePlayerChunkPos(&f.manager, -4096, -4096);
    for (0..256) |_| try f.tick(2);
    const after = f.manager.service_counters.snapshot();
    for ([_]service.Class{ .local_fallback, .near0, .near1, .horizon }) |class| {
        const lane = @intFromEnum(class);
        try testing.expect(after.admitted[lane] > before.admitted[lane]);
        try testing.expect(after.started[lane] > before.started[lane]);
        try testing.expect(after.renderable[lane] > before.renderable[lane]);
    }
    const horizon = @intFromEnum(service.Class.horizon);
    try testing.expect(after.admitted[horizon] > after.renderable[horizon]);
    var fresh_horizon_backlog = false;
    for ([_]lod.LODLevel{ .lod0, .lod1, .lod4 }) |level| {
        var fresh_renderable = false;
        var chunks = f.manager.regions[@intFromEnum(level)].valueIterator();
        while (chunks.next()) |chunk| {
            if (chunk.*.isRenderable() and chunk.*.key().chunkBounds().intersectsRadius(-4096, -4096, 6)) fresh_renderable = true;
            // Cumulative admissions include stale work. Require live backlog
            // at the new position too, rather than counting cancelled regions.
            if (chunk.*.service_lane == horizon and !chunk.*.isRenderable() and chunk.*.getState() != .missing and
                chunk.*.key().chunkBounds().intersectsRadius(-4096, -4096, 1024)) fresh_horizon_backlog = true;
        }
        try testing.expect(fresh_renderable);
    }
    try testing.expect(fresh_horizon_backlog);
}

test "LOD service pipeline single-token backpressure preserves near admission turns" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.manager.generation_tokens.capacity = 1;
    f.manager.generation_tokens.overflow_capacity = 0;

    for (0..12) |iteration| {
        f.manager.update_tick += 1;
        core.queueServiceAdmissions(&f.manager, Vec3.zero, null, null);
        try testing.expectEqual(@as(usize, 1), f.manager.generation_tokens.count());
        try testing.expectEqual(@as(usize, 1), f.manager.pending_region_count);
        const admitted = f.manager.service_counters.snapshot().admitted;
        try testing.expectEqual(@as(u64, @intCast(iteration + 1)), total(admitted));
        // The first rejection is near0, despite ample global pending capacity.
        // Consuming that rejected turn alternates fallback/horizon admissions
        // with rejected near turns instead of giving the freed slot to near.
        if (iteration == 0) {
            try testing.expectEqual(@as(usize, 1), f.manager.service_admission_wheel.cursor);
            try testing.expectEqual(@as(u64, 1), f.manager.service_pending_blocked[@intFromEnum(service.Class.near0)]);
        }

        const cursor = f.manager.service_admission_wheel.cursor;
        var owed = f.manager.service_admission_wheel;
        const blocked_lane = owed.next();
        const blocked_before = f.manager.service_pending_blocked[blocked_lane];
        core.queueServiceAdmissions(&f.manager, Vec3.zero, null, null);
        try testing.expectEqual(cursor, f.manager.service_admission_wheel.cursor);
        try testing.expectEqual(blocked_before + 1, f.manager.service_pending_blocked[blocked_lane]);
        try testing.expectEqualSlices(u64, &admitted, &f.manager.service_counters.snapshot().admitted);
        try testing.expectEqual(@as(usize, 1), f.manager.generation_tokens.count());
        try testing.expectEqual(@as(usize, 1), f.manager.pending_region_count);

        // Free the token slot through actual dispatch, then complete both real
        // worker callbacks and mock upload before the next admission pass.
        try f.manager.processQueuedGenerations(Vec3.zero);
        const generation_job = f.queue.tryPop() orelse return error.ExpectedGenerationJob;
        try testing.expectEqual(engine_core.job_system.JobType.chunk_generation, generation_job.type);
        generation.processLODJob(&f.manager, generation_job);
        try f.manager.processStateTransitions(Vec3.zero);
        const mesh_job = f.queue.tryPop() orelse return error.ExpectedMeshJob;
        try testing.expectEqual(engine_core.job_system.JobType.chunk_meshing, mesh_job.type);
        try testing.expectEqual(generation_job.service_lane, mesh_job.service_lane);
        generation.processLODJob(&f.manager, mesh_job);
        try f.manager.processStateTransitions(Vec3.zero);
        f.manager.processUploads();
        try testing.expectEqual(@as(usize, 0), f.manager.generation_tokens.count());
        try testing.expectEqual(@as(usize, 0), f.manager.pending_region_count);
        try testing.expectEqual(iteration + 1, f.uploaded);
    }

    const snapshot = f.manager.service_counters.snapshot();
    for ([_]service.Class{ .near0, .near1, .local_fallback, .horizon }) |class| {
        const lane = @intFromEnum(class);
        try testing.expect(snapshot.admitted[lane] > 0);
        try testing.expectEqual(snapshot.admitted[lane], snapshot.renderable[lane]);
        try testing.expectEqual(2 * snapshot.admitted[lane], snapshot.started[lane]);
        try testing.expectEqual(snapshot.dispatched[lane], snapshot.started[lane]);
    }
}
