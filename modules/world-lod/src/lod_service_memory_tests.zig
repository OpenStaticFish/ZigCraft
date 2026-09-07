const std = @import("std");
const testing = std.testing;
const engine_core = @import("engine-core");
const Vec3 = @import("engine-math").Vec3;
const rhi = @import("engine-rhi");
const lod = @import("lod_chunk.zig");
const LODManager = @import("lod_manager.zig").LODManager;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const context = @import("lod_manager_context.zig");
const core = @import("lod_manager_core_ops.zig");
const gpu = @import("lod_upload_queue.zig");
const service = @import("lod_service.zig");
const MiB = 1024 * 1024;

// Mock only the renderer resource boundary; manager accounting, admission,
// service wheels, upload selection and lifecycle publication are real.
const Fixture = struct {
    manager: LODManager = undefined,
    queue: engine_core.job_system.JobQueue = undefined,
    config: lod.LODConfig = .{
        .memory_budget_mb = 4,
        .max_uploads_per_frame = 3,
        .active_lod_count = 5,
        .chunk_render_radius = 2,
        .radii = .{ 32, 64, 128, 256, 1024 },
    },
    allocated_bytes: usize = 0,
    retired_bytes: usize = 0,
    direct_retired_bytes: usize = 0,
    compact_retired_bytes: usize = 0,
    costs: [lod.LODLevel.count]usize = @splat(0),
    memory_cost_calls: usize = 0,
    calls: usize = 0,
    staging_calls: usize = 0,
    prepared_headroom: ?usize = null,

    fn init(self: *Fixture) !void {
        self.manager = try LODManager.initCacheTestManager(testing.allocator, "");
        errdefer self.manager.cache_io.deinit();
        errdefer self.manager.ingestion_queue.deinit(testing.allocator);
        self.queue = engine_core.job_system.JobQueue.init(testing.allocator);
        errdefer self.queue.deinit();
        self.manager.config = self.config.interface();
        self.manager.job_dispatcher = .{ .queues = @splat(&self.queue) };
        self.manager.renderer = .{ .render_fn = undefined, .deinit_fn = undefined, .ptr = self, .memory_stats_fn = memoryStats };
        self.manager.gpu_bridge = .{
            .on_upload = upload,
            .on_destroy = destroy,
            .on_wait_idle = waitIdle,
            .on_upload_cost = stagingCost,
            .on_upload_memory_cost = memoryCost,
            .ctx = self,
        };
        var initialized: usize = 0;
        errdefer for (0..initialized) |i| self.manager.upload_queues[i].deinit();
        for (0..lod.LODLevel.count) |i| {
            self.manager.regions[i] = gpu.RegionMap.init(testing.allocator);
            self.manager.meshes[i] = gpu.MeshMap.init(testing.allocator);
            self.manager.upload_queues[i] = try engine_core.ring_buffer.RingBuffer(*lod.LODChunk).init(testing.allocator, 8);
            initialized += 1;
        }
        self.manager.generation_tokens.enableServiceLanes(&service.WHEEL);
    }

    fn deinit(self: *Fixture) void {
        self.manager.cache_io.deinit();
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
                testing.allocator.destroy(mesh.*);
            }
            self.manager.regions[i].deinit();
            self.manager.meshes[i].deinit();
            self.manager.upload_queues[i].deinit();
        }
        self.queue.deinit();
        self.manager.ingestion_queue.deinit(testing.allocator);
        self.manager.generation_tokens.deinit(testing.allocator);
        self.manager.transition_tokens.deinit(testing.allocator);
        self.manager.fade_tokens.deinit(testing.allocator);
    }

    fn enqueue(self: *Fixture, level: lod.LODLevel, lane: u3) !*lod.LODChunk {
        const chunk = try testing.allocator.create(lod.LODChunk);
        chunk.* = lod.LODChunk.init(0, 0, level);
        errdefer testing.allocator.destroy(chunk);
        chunk.service_lane = lane;
        chunk.setState(.uploading);
        chunk.data = .{ .simplified = try lod.LODSimplifiedData.initWithGridSize(testing.allocator, level, 2) };
        errdefer chunk.deinit(testing.allocator);
        const i = @intFromEnum(level);
        try self.manager.regions[i].put(chunk.key(), chunk);
        errdefer _ = self.manager.regions[i].remove(chunk.key());
        const mesh = try testing.allocator.create(LODMesh);
        errdefer testing.allocator.destroy(mesh);
        mesh.* = LODMesh.init(testing.allocator, level);
        mesh.pending_vertices = try testing.allocator.alloc(rhi.Vertex, 1);
        errdefer mesh.clearPendingVertices();
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi.Vertex));
        try self.manager.meshes[i].put(chunk.key(), mesh);
        errdefer _ = self.manager.meshes[i].remove(chunk.key());
        try self.manager.upload_queues[i].push(chunk);
        self.manager.pending_region_count += 1;
        return chunk;
    }

    fn memoryStats(ptr: *anyopaque) gpu.LODRendererMemoryStats {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        return .{
            .pool_gpu_capacity_bytes = self.allocated_bytes,
            .pool_gpu_retired_bytes = self.retired_bytes,
            .direct_gpu_retired_bytes = self.direct_retired_bytes,
            .compact_pool_retired_bytes = self.compact_retired_bytes,
        };
    }

    fn memoryCost(mesh: *LODMesh, ptr: *anyopaque) usize {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.memory_cost_calls += 1;
        return self.costs[@intFromEnum(mesh.lodLevel())];
    }

    fn stagingCost(mesh: *LODMesh, ptr: *anyopaque) @import("lod_mesh_resources.zig").LODStagingCost {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.staging_calls += 1;
        // Exercise the oversized-staging escape hatch after memory admission.
        return .{ .payload_bytes = mesh.pendingUploadBytes(), .migration_bytes = 8 * MiB };
    }

    fn upload(mesh: *LODMesh, ptr: *anyopaque) rhi.RhiError!void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.allocated_bytes += memoryCost(mesh, ptr);
        mesh.vertex_count = @intCast(mesh.pending_vertices.?.len);
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
};

test "LOD service memory prepares upload strategy against lane headroom before admission" {
    const Planner = struct {
        fn prepare(mesh: *LODMesh, available: usize, ptr: *anyopaque) void {
            const fixture: *Fixture = @ptrCast(@alignCast(ptr));
            fixture.prepared_headroom = available;
            // Mock a resource planner choosing a smaller dedicated allocation;
            // production renderer tests cover the actual buffer-routing choice.
            if (available >= MiB / 4) fixture.costs[@intFromEnum(mesh.lodLevel())] = MiB / 4;
        }
    };
    for ([_]u3{ 1, 3 }) |lane| {
        var fixture: Fixture = .{};
        try fixture.init();
        defer fixture.deinit();
        const chunk = try fixture.enqueue(.lod1, lane);
        fixture.allocated_bytes = 2 * MiB;
        fixture.costs[1] = 4 * MiB;
        fixture.manager.gpu_bridge.on_prepare_upload = Planner.prepare;
        fixture.manager.updateStats();
        const expected = service.memoryLimit(lane, 4 * MiB) -| fixture.manager.memory_governor.logical_admission_bytes;
        fixture.manager.processUploadsWithBudget(1);
        try testing.expectEqual(expected, fixture.prepared_headroom.?);
        try testing.expectEqual(@as(usize, 1), fixture.calls);
        try testing.expectEqual(lod.LODState.renderable, chunk.getState());
        try testing.expectEqual(@as(usize, 0), fixture.manager.pending_region_count);
        try testing.expectEqual(@as(usize, 2 * MiB + MiB / 4), fixture.allocated_bytes);
    }
}

test "LOD service memory keeps dedicated retirement debt charged until provider completion" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const chunk = try fixture.enqueue(.lod1, 1);
    fixture.manager.profiling.enabled = true;
    fixture.allocated_bytes = MiB;
    fixture.direct_retired_bytes = 2 * MiB;
    fixture.costs[1] = MiB;
    fixture.manager.processUploadsWithBudget(1);
    try testing.expectEqual(@as(usize, 0), fixture.calls);
    try testing.expectEqual(lod.LODState.uploading, chunk.getState());
    try testing.expectEqual(@as(u64, 2 * MiB), fixture.manager.stats.direct_gpu_retired_bytes);
    try testing.expectEqual(@as(u64, 2 * MiB), fixture.manager.profiling.snapshot().direct_gpu_retired_bytes);
    try testing.expect(fixture.manager.memory_governor.used_bytes > 3 * MiB);

    // The renderer's deferred-resource tests verify the actual fence protocol.
    // Here its completion report must make pending work admissible, not before.
    fixture.direct_retired_bytes = 0;
    fixture.manager.processUploadsWithBudget(1);
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    try testing.expectEqual(lod.LODState.renderable, chunk.getState());
    fixture.manager.updateStats();
    try testing.expectEqual(@as(u64, 0), fixture.manager.stats.direct_gpu_retired_bytes);
}

test "LOD service memory limit reserves a rounded quarter across lanes and budget range" {
    const max = std.math.maxInt(usize);
    for (0..service.CLASS_COUNT) |lane_index| {
        const lane: u3 = @intCast(lane_index);
        try testing.expectEqual(max, service.memoryLimit(lane, 0));
        for (1..1025) |budget| {
            const expected = if (lane < 3) budget else budget * 3 / 4;
            try testing.expectEqual(expected, service.memoryLimit(lane, budget));
        }
        for ([_]usize{ 256 * MiB, max - 1, max }) |budget| {
            const expected: usize = @intCast(if (lane < 3) @as(u128, budget) else @as(u128, budget) * 3 / 4);
            try testing.expectEqual(expected, service.memoryLimit(lane, budget));
        }
    }
}

test "LOD service memory admission reserves headroom while legacy and unlimited retain hard semantics" {
    const levels = [_]lod.LODLevel{ .lod4, .lod0, .lod1, .lod4, .lod2 };
    for ([_]u32{ 4, 0 }) |budget_mb| {
        for (0..6) |case| {
            var f: Fixture = .{};
            try f.init();
            defer f.deinit();
            f.config.memory_budget_mb = budget_mb;
            // Scheduler admission refreshes live accounting. Model the occupied
            // bytes at the renderer boundary instead of seeding a stale logical
            // total that production would immediately replace.
            f.allocated_bytes = 3 * MiB;
            f.manager.updateStats();
            if (case == 5) {
                try f.manager.queueLODRegions(.lod4, Vec3.zero, null, null);
                try testing.expect(f.manager.pending_region_count > 0);
            } else {
                const lane: u3 = @intCast(case);
                var scan: context.LODScanState = .{};
                var result: @import("lod_scheduler.zig").ScheduleResult = .{};
                for (0..16) |_| {
                    result = try f.manager.queueLODService(levels[case], lane, &scan, 128, Vec3.zero, null, null);
                    if (result.admitted > 0 or result.memory_blocked) break;
                }
                const denied = budget_mb != 0 and lane >= 3;
                try testing.expectEqual(denied, result.memory_blocked);
                try testing.expectEqual(@as(usize, if (denied) 0 else 1), result.admitted);
            }
            if (budget_mb != 0) {
                try testing.expect(f.manager.memory_governor.logical_admission_bytes <= 4 * MiB);
                // Even urgent and legacy admissions stop at the hard cap.
                f.allocated_bytes = 4 * MiB;
                f.manager.updateStats();
                const before = f.manager.pending_region_count;
                try f.manager.queueLODRegions(.lod0, Vec3.zero, null, null);
                var scan: context.LODScanState = .{};
                const result = try f.manager.queueLODService(.lod1, 2, &scan, 128, Vec3.zero, null, null);
                try testing.expect(result.memory_blocked);
                try testing.expectEqual(before, f.manager.pending_region_count);
            }
        }
    }
}

test "LOD service memory exhausted background admission retains an urgent turn" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.config.memory_budget_mb = 16;
    f.allocated_bytes = 12 * MiB;
    f.manager.updateStats();
    f.manager.service_admission_wheel.cursor = 2; // Horizon denial precedes urgent turns.
    core.queueServiceAdmissions(&f.manager, Vec3.zero, null, null);
    const admitted = f.manager.service_counters.snapshot().admitted;
    // The wheel begins with a horizon denial, then preserves the next near
    // turn. The configured legacy reservation admits four urgent regions into
    // the remaining hard-cap headroom without granting background a turn.
    try testing.expect(admitted[@intFromEnum(service.Class.near1)] > 0);
    for (3..5) |lane| {
        try testing.expectEqual(@as(u64, 0), admitted[lane]);
        try testing.expect(f.manager.service_memory_blocked[lane] > 0);
    }
    try testing.expectEqual(@as(usize, 16 * MiB), f.manager.memory_governor.logical_admission_bytes);
    try testing.expectEqual(@as(u32, 4), f.manager.pending_region_count);
}

test "LOD service memory upload background cannot enter reserve but local and near can" {
    for (0..service.CLASS_COUNT) |lane| {
        for ([_]usize{ 3 * MiB, 3 * MiB + 1, 4 * MiB }) |peak| {
            var f: Fixture = .{};
            try f.init();
            defer f.deinit();
            const chunk = try f.enqueue(.lod1, @intCast(lane));
            f.manager.updateStats();
            f.costs[1] = peak - f.manager.memory_governor.logical_admission_bytes;
            f.manager.processUploadsWithBudget(1);
            const denied = lane >= 3 and peak > 3 * MiB;
            try testing.expectEqual(@as(usize, if (denied) 0 else 1), f.calls);
            try testing.expectEqual(f.calls, f.staging_calls);
            try testing.expectEqual(!denied, chunk.isRenderable());
            try testing.expectEqual(denied, f.manager.memory_governor.pressure_pending);
            try testing.expectEqual(@as(usize, 0), f.manager.memory_governor.required_upload_bytes);
            try testing.expectEqual(@as(usize, if (denied) 1 else 0), f.manager.upload_queues[1].count());
            try testing.expect(!chunk.isPinned());
        }
    }
}

test "LOD service memory hard upload denial wins before soft and oversized staging exceptions" {
    for (0..service.CLASS_COUNT) |lane| {
        for ([_]bool{ false, true }) |impossible| {
            var f: Fixture = .{};
            try f.init();
            defer f.deinit();
            const chunk = try f.enqueue(.lod1, @intCast(lane));
            f.manager.updateStats();
            f.costs[1] = 4 * MiB + 1 - if (impossible) @as(usize, 0) else f.manager.memory_governor.logical_admission_bytes;
            f.manager.processUploadsWithBudget(1);
            try testing.expectEqual(@as(usize, 0), f.calls);
            try testing.expectEqual(@as(usize, 0), f.staging_calls);
            try testing.expectEqual(if (impossible) @as(usize, 0) else f.costs[1], f.manager.memory_governor.required_upload_bytes);
            try testing.expect(f.manager.memory_governor.pressure_pending);
            try testing.expectEqual(lod.LODState.uploading, chunk.getState());
            try testing.expect(!chunk.isPinned());
        }
    }
}

test "LOD service memory soft denial preserves the minimum achievable hard recovery request" {
    for ([_]u3{ 3, 4 }) |lane| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.allocated_bytes = 3 * MiB;
        f.costs = .{ 2 * MiB, MiB, 0, 0, 1 };
        const near0 = try f.enqueue(.lod0, 1);
        const near1 = try f.enqueue(.lod1, 2);
        const background = try f.enqueue(.lod4, lane);
        f.manager.processUploadsWithBudget(1);
        try testing.expectEqual(@as(usize, 0), f.calls);
        try testing.expectEqual(@as(usize, 0), f.staging_calls);
        try testing.expectEqual(@as(usize, MiB), f.manager.memory_governor.required_upload_bytes);
        try testing.expect(f.manager.memory_governor.pressure_pending);
        for ([_]*lod.LODChunk{ near0, near1, background }) |chunk| {
            try testing.expectEqual(lod.LODState.uploading, chunk.getState());
            try testing.expect(!chunk.isPinned());
        }
    }
}

test "LOD service memory zero growth drains pending CPU above soft and hard limits and zero budget is unlimited" {
    for ([_]u3{ 3, 4 }) |lane| {
        for ([_]usize{ 3 * MiB, 4 * MiB, 8 * MiB }) |allocated| {
            var f: Fixture = .{};
            try f.init();
            defer f.deinit();
            f.allocated_bytes = allocated;
            if (allocated == 8 * MiB) {
                f.config.memory_budget_mb = 0;
                f.costs[4] = MiB;
            }
            const chunk = try f.enqueue(.lod4, lane);
            f.manager.updateStats();
            const before = f.manager.memory_governor.logical_admission_bytes;
            f.manager.processUploadsWithBudget(1);
            f.manager.updateStats();
            try testing.expectEqual(@as(usize, 1), f.calls);
            try testing.expect(chunk.isRenderable());
            try testing.expect(f.manager.meshes[4].get(chunk.key()).?.pending_vertices == null);
            try testing.expectEqual(before + f.costs[4] - @sizeOf(rhi.Vertex), f.manager.memory_governor.logical_admission_bytes);
            try testing.expectEqual(@as(usize, 0), f.manager.memory_governor.required_upload_bytes);
            try testing.expect(!f.manager.memory_governor.pressure_pending);
        }
    }
}

test "LOD service memory soft denied owed upload yields to urgent lanes and retries after headroom returns" {
    for ([_]u3{ 3, 4 }) |lane| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.allocated_bytes = 3 * MiB;
        f.costs = .{ 1, 1, 1, 0, MiB / 2 };
        const background = try f.enqueue(.lod4, lane);
        f.manager.service_upload_owed = .{
            .key = background.key(),
            .job_token = background.job_token,
            .source_revision = background.source_revision,
            .service_lane = lane,
            .priority = 0,
            .stage = .upload,
        };
        for ([_]lod.LODLevel{ .lod0, .lod1, .lod2 }, 0..) |level, urgent_lane| {
            _ = try f.enqueue(level, @intCast(urgent_lane));
        }
        f.manager.processUploadsWithBudget(0);
        try testing.expectEqual(@as(usize, 3), f.calls);
        try testing.expectEqual(@as(usize, 3), f.staging_calls);
        try testing.expectEqualSlices(u64, &.{ 1, 1, 1, 0, 0 }, &f.manager.service_counters.snapshot().renderable);
        try testing.expectEqual(@as(usize, 0), f.manager.memory_governor.required_upload_bytes);
        try testing.expect(f.manager.memory_governor.pressure_pending);
        try testing.expect(f.manager.service_upload_owed == null);
        try testing.expectEqual(lod.LODState.uploading, background.getState());
        try testing.expectEqual(@as(u32, 1), f.manager.pending_region_count);
        f.manager.processUploadsWithBudget(0);
        try testing.expectEqual(@as(usize, 3), f.calls);
        try testing.expectEqual(@as(usize, 1), f.manager.upload_queues[4].count());
        // Model completed renderer trim/retirement, not credit before release.
        f.allocated_bytes = MiB;
        f.manager.processUploadsWithBudget(0);
        try testing.expectEqual(@as(usize, 4), f.calls);
        try testing.expect(background.isRenderable());
        try testing.expectEqual(@as(u32, 0), f.manager.pending_region_count);
    }
}

test "LOD service memory soft parked uploads permit near radius cooldown without discounting bytes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.allocated_bytes = 3 * MiB;
    f.costs = @splat(1024);
    const horizon = try f.enqueue(.lod4, 3);
    const refinement = try f.enqueue(.lod3, 4);
    f.manager.memory_governor.radius_shrink_chunks[1] = 10;
    f.manager.processUploadsWithBudget(0);
    try testing.expectEqual(@as(usize, 0), f.calls);
    try testing.expectEqual(@as(usize, 0), f.manager.memory_governor.required_upload_bytes);
    const logical = f.manager.memory_governor.logical_admission_bytes;
    const pending_cpu = f.manager.stats.pending_cpu_upload_bytes;
    try testing.expect(logical > 3 * MiB and logical < 4 * MiB * 4 / 5);
    try testing.expectEqual(@as(u64, 2 * @sizeOf(rhi.Vertex)), pending_cpu);
    f.memory_cost_calls = 0;
    f.manager.updateStats();
    try testing.expectEqual(@as(usize, 0), f.memory_cost_calls);
    const now = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    try f.manager.enforceMemoryBudget();
    try testing.expectEqual(@as(usize, 2), f.memory_cost_calls);
    try testing.expect(f.manager.memory_governor.reexpand_after_ms.? >= now + 2000);
    try testing.expectEqual(@as(i32, 10), f.manager.memory_governor.radius_shrink_chunks[1]);
    // Drive the existing deadline explicitly, without sleeps or shorter policy.
    f.manager.memory_governor.reexpand_after_ms = std.math.maxInt(i64);
    try f.manager.enforceMemoryBudget();
    try testing.expectEqual(@as(i32, 10), f.manager.memory_governor.radius_shrink_chunks[1]);
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), f.manager.memory_governor.reexpand_after_ms);
    f.manager.memory_governor.reexpand_after_ms = 0;
    try f.manager.enforceMemoryBudget();
    try testing.expectEqual(@as(i32, 9), f.manager.memory_governor.radius_shrink_chunks[1]);
    try testing.expectEqual(@as(?i64, null), f.manager.memory_governor.reexpand_after_ms);
    try testing.expectEqual(logical, f.manager.memory_governor.logical_admission_bytes);
    try testing.expectEqual(logical, f.manager.memory_governor.used_bytes);
    try testing.expectEqual(pending_cpu, f.manager.stats.pending_cpu_upload_bytes);
    try testing.expectEqual(@as(u32, 2), f.manager.pending_region_count);
    try testing.expectEqual(horizon, f.manager.upload_queues[4].peek().?);
    try testing.expectEqual(refinement, f.manager.upload_queues[3].peek().?);
    try testing.expectEqual(@as(usize, 0), f.calls);

    // Reach exactly 80% including source and parked CPU payloads. Discounting
    // those payloads would incorrectly reopen the cooldown below low water.
    f.allocated_bytes = 4 * MiB * 4 / 5 - (logical - f.allocated_bytes);
    f.manager.updateStats();
    try testing.expectEqual(@as(usize, 4 * MiB * 4 / 5), f.manager.memory_governor.logical_admission_bytes);
    f.memory_cost_calls = 0;
    f.manager.memory_governor.reexpand_after_ms = 0;
    try f.manager.enforceMemoryBudget();
    try testing.expectEqual(@as(i32, 9), f.manager.memory_governor.radius_shrink_chunks[1]);
    try testing.expectEqual(@as(?i64, null), f.manager.memory_governor.reexpand_after_ms);
    try testing.expectEqual(@as(usize, 0), f.memory_cost_calls);
}

test "LOD service memory parked recovery rechecks live costs lane and pin before expiring cooldown" {
    const Change = enum { hard_denial, zero_growth, soft_fits, urgent, pinned, no_cost_callback };
    for (std.meta.tags(Change)) |change| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.allocated_bytes = 2 * MiB;
        const chunk = try f.enqueue(.lod4, 3);
        f.manager.updateStats();
        const logical = f.manager.memory_governor.logical_admission_bytes;
        f.costs[4] = 4 * MiB - logical; // Exact hard fit, but exceeds soft headroom.
        f.manager.memory_governor.radius_shrink_chunks[1] = 10;
        try f.manager.enforceMemoryBudget();
        try testing.expect(f.manager.memory_governor.reexpand_after_ms != null);
        f.manager.memory_governor.reexpand_after_ms = 0;
        switch (change) {
            .hard_denial => f.costs[4] += 1,
            .zero_growth => f.costs[4] = 0,
            .soft_fits => f.costs[4] = 3 * MiB - logical,
            .urgent => chunk.service_lane = 1,
            .pinned => chunk.pin(),
            .no_cost_callback => f.manager.gpu_bridge.on_upload_memory_cost = null,
        }
        defer if (change == .pinned) chunk.unpin();
        try f.manager.enforceMemoryBudget();
        try testing.expectEqual(@as(i32, 10), f.manager.memory_governor.radius_shrink_chunks[1]);
        try testing.expectEqual(@as(?i64, null), f.manager.memory_governor.reexpand_after_ms);
        try testing.expectEqual(logical, f.manager.memory_governor.logical_admission_bytes);
        try testing.expectEqual(@as(usize, 0), f.manager.memory_governor.required_upload_bytes);
        try testing.expectEqual(@as(usize, 1), f.manager.upload_queues[4].count());
    }
}

test "LOD service memory parked recovery rejects other worker states queues retirement and deferred debt" {
    const Blocker = enum { queued_for_generation, generating, generated, meshing, mesh_ready, worker_queue, generation_token, transition_token, hard_request, pool_retired, compact_retired, deferred };
    for (std.meta.tags(Blocker)) |blocker| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.allocated_bytes = 3 * MiB;
        f.costs = @splat(1024);
        const background = try f.enqueue(.lod4, 3);
        f.manager.memory_governor.radius_shrink_chunks[1] = 10;
        f.manager.updateStats();
        try f.manager.enforceMemoryBudget();
        try testing.expect(f.manager.memory_governor.reexpand_after_ms != null);
        switch (blocker) {
            .queued_for_generation, .generating, .generated, .meshing, .mesh_ready => {
                const worker = try f.enqueue(.lod1, 4);
                worker.setState(switch (blocker) {
                    .queued_for_generation => .queued_for_generation,
                    .generating => .generating,
                    .generated => .generated,
                    .meshing => .meshing,
                    .mesh_ready => .mesh_ready,
                    else => unreachable,
                });
                // Even matching aggregate pending/ring counts cannot hide a
                // different resident lifecycle state awaiting reconciliation.
            },
            .worker_queue => try f.queue.push(.{ .type = .chunk_meshing, .dist_sq = 0, .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 0 } } }),
            .generation_token => f.manager.enqueueTransition(background.key(), background, .generation),
            .transition_token => f.manager.enqueueTransition(background.key(), background, .mesh),
            .hard_request => f.manager.memory_governor.required_upload_bytes = 1024,
            .pool_retired => f.retired_bytes = 1024,
            .compact_retired => f.compact_retired_bytes = 1024,
            .deferred => {
                const mesh = try testing.allocator.create(LODMesh);
                mesh.* = LODMesh.init(testing.allocator, .lod1);
                f.manager.queueMeshDeletion(mesh);
            },
        }
        defer if (blocker == .deferred) {
            const mesh = f.manager.mesh_disposal.queue.items[0];
            testing.allocator.destroy(mesh);
            f.manager.mesh_disposal.queue.deinit(testing.allocator);
        };
        f.manager.updateStats();
        f.manager.memory_governor.reexpand_logical_bytes = f.manager.memory_governor.logical_admission_bytes;
        f.manager.memory_governor.reexpand_after_ms = 0;
        try f.manager.enforceMemoryBudget();
        try testing.expectEqual(@as(i32, 10), f.manager.memory_governor.radius_shrink_chunks[1]);
        try testing.expectEqual(@as(?i64, null), f.manager.memory_governor.reexpand_after_ms);
    }
}

test "LOD service memory parked recovery requires matching live pending rings and CPU payloads" {
    const Mismatch = enum { missing_queue, duplicate_queue, pending_count, wrong_level_queue, unrelated_cpu, missing_mesh, inactive_level, too_many_pending };
    for (std.meta.tags(Mismatch)) |mismatch| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        f.allocated_bytes = 3 * MiB;
        f.costs = @splat(1024);
        const background = try f.enqueue(.lod4, 4);
        f.manager.memory_governor.radius_shrink_chunks[1] = 10;
        f.manager.updateStats();
        try f.manager.enforceMemoryBudget();
        try testing.expect(f.manager.memory_governor.reexpand_after_ms != null);
        switch (mismatch) {
            .missing_queue => _ = f.manager.upload_queues[4].pop(),
            .duplicate_queue => try f.manager.upload_queues[4].push(background),
            .pending_count => f.manager.pending_region_count += 1,
            .wrong_level_queue => {
                _ = f.manager.upload_queues[4].pop();
                try f.manager.upload_queues[3].push(background);
            },
            .unrelated_cpu => {
                const chunk = try f.enqueue(.lod1, 1);
                _ = f.manager.upload_queues[1].pop();
                f.manager.markRegionRenderable(chunk.key(), chunk);
                // Retained CPU payload on otherwise completed work must not be
                // subtracted as if it belonged to the parked background mesh.
            },
            .missing_mesh => {
                const mesh = f.manager.meshes[4].fetchRemove(background.key()).?.value;
                mesh.clearPendingVertices();
                testing.allocator.destroy(mesh);
            },
            .inactive_level => f.config.active_lod_count = 4,
            .too_many_pending => {
                for (0..context.MAX_PENDING_LOD_REGIONS) |_| try f.manager.upload_queues[4].push(background);
                f.manager.pending_region_count = @intCast(context.MAX_PENDING_LOD_REGIONS + 1);
            },
        }
        f.manager.updateStats();
        f.manager.memory_governor.reexpand_logical_bytes = f.manager.memory_governor.logical_admission_bytes;
        f.manager.memory_governor.reexpand_after_ms = 0;
        f.memory_cost_calls = 0;
        const queued_before = f.manager.upload_queues[4].count();
        try f.manager.enforceMemoryBudget();
        try testing.expectEqual(@as(i32, 10), f.manager.memory_governor.radius_shrink_chunks[1]);
        try testing.expectEqual(@as(?i64, null), f.manager.memory_governor.reexpand_after_ms);
        try testing.expectEqual(queued_before, f.manager.upload_queues[4].count());
        try testing.expect(f.memory_cost_calls <= f.manager.pending_region_count);
        if (mismatch == .too_many_pending) try testing.expectEqual(@as(usize, 0), f.memory_cost_calls);
    }
}
