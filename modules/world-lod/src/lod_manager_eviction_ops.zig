const std = @import("std");
const Self = @import("lod_manager.zig").LODManager;
const fs = @import("fs");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const ILODConfig = lod_chunk.ILODConfig;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const engine_core = @import("engine-core");
const log = engine_core.log;
const JobSystem = engine_core.job_system;
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const ChunkChecker = lod_gpu.ChunkChecker;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
const lod_service = @import("lod_service.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const TextureAtlas = @import("engine-assets").TextureAtlas;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODStats = @import("lod_stats.zig").LODStats;
const manager_ctx = @import("lod_manager_context.zig");
const ChunkCoordKey = manager_ctx.ChunkCoordKey;
const ChunkCoordKeyContext = manager_ctx.ChunkCoordKeyContext;
const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);
const ChunkResolver = manager_ctx.ChunkResolver;
const PendingIngestion = manager_ctx.PendingIngestion;
const PlayerChunkPos = manager_ctx.PlayerChunkPos;
const MAX_CACHE_LOADS_PER_UPDATE = manager_ctx.MAX_CACHE_LOADS_PER_UPDATE;
const MAX_MEMORY_EVICTIONS_PER_UPDATE = manager_ctx.MAX_MEMORY_EVICTIONS_PER_UPDATE;
const MAX_MESH_DELETIONS_PER_SWEEP = manager_ctx.MAX_MESH_DELETIONS_PER_SWEEP;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = manager_ctx.DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const LOGICAL_LOD_REGION_RESERVATION_BYTES = manager_ctx.LOGICAL_LOD_REGION_RESERVATION_BYTES;
const LOCAL_SERVICE_COLLAR_CHUNKS = manager_ctx.LOCAL_SERVICE_COLLAR_CHUNKS;
const LOD_UPLOAD_BUDGET_ENV = manager_ctx.LOD_UPLOAD_BUDGET_ENV;
const LOD_UPDATE_DIVISOR = manager_ctx.LOD_UPDATE_DIVISOR;
const DELETION_SWEEP_SECONDS = manager_ctx.DELETION_SWEEP_SECONDS;
const CHUNK_COVERAGE_PADDING = manager_ctx.CHUNK_COVERAGE_PADDING;
const MIN_LOD_WORKERS = manager_ctx.MIN_LOD_WORKERS;
const MAX_LOD_WORKERS = manager_ctx.MAX_LOD_WORKERS;
const MAX_PENDING_INGESTIONS = manager_ctx.MAX_PENDING_INGESTIONS;
const PENDING_INGESTION_TTL = manager_ctx.PENDING_INGESTION_TTL;
const EDIT_FLUSH_COOLDOWN = manager_ctx.EDIT_FLUSH_COOLDOWN;
const LOD_FRAME_DT_APPROX = manager_ctx.LOD_FRAME_DT_APPROX;
const lodUploadBudgetBytes = manager_ctx.lodUploadBudgetBytes;
const wouldExceedUploadBudget = manager_ctx.wouldExceedUploadBudget;
const isUploadPressureError = manager_ctx.isUploadPressureError;

/// Unload regions that are too far from player
pub fn unloadDistantRegions(self: *Self) !void {
    const radii = self.config.getRadii();
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    for (0..active_lod_count) |i| {
        try self.unloadDistantForLevel(@enumFromInt(@as(u3, @intCast(i))), radii[i]);
    }
}

pub fn unloadDistantForLevel(self: *Self, lod: LODLevel, max_radius: i32) !void {
    _ = max_radius; // Interface provides current radii
    const radii = self.config.getRadii();
    const lod_radius = radii[@intFromEnum(lod)];
    const storage = &self.regions[@intFromEnum(lod)];

    var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
    defer to_remove.deinit(self.allocator);

    // Hold lock for entire operation to prevent races with worker threads
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlock();

    const player = self.loadPlayerChunkPos();
    var iter = storage.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const chunk = entry.value_ptr.*;

        if (!key.chunkBounds().intersectsRadius(player.cx, player.cz, lod_radius)) {
            if (!chunk.isPinned() and
                chunk.getState() != .generating and
                chunk.getState() != .meshing and
                chunk.getState() != .uploading)
            {
                try to_remove.append(self.allocator, key);
            }
        }
    }

    // Remove after iteration (still under lock)
    if (to_remove.items.len > 0) {
        for (to_remove.items) |key| {
            if (storage.get(key)) |chunk| {
                if (chunk.getState() != .missing and chunk.getState() != .renderable and self.pending_region_count > 0) {
                    self.pending_region_count -= 1;
                }
                // Clean up mesh before removing chunk
                const meshes = &self.meshes[@intFromEnum(lod)];
                releaseRegionSourceAccounting(self, chunk, meshes.get(key));
                self.noteRegionRemoved(key, chunk);
                if (meshes.get(key)) |mesh| {
                    // Push to deferred deletion queue instead of deleting immediately
                    self.queueMeshDeletion(mesh);
                    _ = meshes.remove(key);
                }

                chunk.deinit(self.allocator);
                self.allocator.destroy(chunk);
                _ = storage.remove(key);
            }
        }
    }
}

pub fn queueMeshDeletion(self: *Self, mesh: *LODMesh) void {
    const memory = mesh.memorySnapshot();
    self.mesh_disposal.queue.append(self.allocator, mesh) catch {
        mesh.releasePendingCompactTile();
        self.gpu_bridge.destroy(mesh);
        mesh.releaseAllocatorOwner();
        self.allocator.destroy(mesh);
        return;
    };
    self.profiling.addDeferredDeletionBytes(memory.capacity_bytes);
    self.profiling.addDeferredDeletionCpuBytes(memory.pending_upload_bytes);
}

pub fn processMeshDeletions(self: *Self, max_count: usize) void {
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlock();

    const count = @min(max_count, self.mesh_disposal.queue.items.len);
    if (count == 0) return;

    // Meshes have already spent a full disposal grace period outside the
    // render maps. Whole buffers are retired by the RHI's frame-fence deletion
    // queue; pooled ranges are only returned here, after that grace period.
    // Do not turn routine streaming eviction into a device-global stall.
    var processed: usize = 0;
    while (processed < count) : (processed += 1) {
        const idx = self.mesh_disposal.queue.items.len - 1;
        const mesh = self.mesh_disposal.queue.items[idx];
        const memory = mesh.memorySnapshot();
        self.profiling.removeDeferredDeletionBytes(memory.capacity_bytes);
        self.profiling.removeDeferredDeletionCpuBytes(memory.pending_upload_bytes);
        mesh.releasePendingCompactTile();
        self.gpu_bridge.destroy(mesh);
        mesh.releaseAllocatorOwner();
        self.allocator.destroy(mesh);
        self.mesh_disposal.queue.items.len = idx;
    }
}

pub fn regionMemoryBytes(chunk: *const LODChunk, mesh: ?*LODMesh) usize {
    var total: usize = 0;
    switch (chunk.data) {
        .simplified => |*s| total += s.totalMemoryBytes(),
        else => {},
    }
    if (mesh) |m| {
        const memory = m.memorySnapshot();
        // GPU allocations remain charged throughout deferred deletion. Only
        // source data and pending CPU payloads can be released immediately.
        total += memory.pending_upload_bytes;
    }
    return total;
}

/// Bytes attributable to one region rather than a shared pool/cache. A pooled
/// mesh's active range is still exclusively assigned to that region; only the
/// pool's unallocated slack remains global. This is the only usage that can
/// consume the near-service reserve for background admission.
fn regionExclusiveMemoryBytes(chunk: *const LODChunk, mesh: ?*LODMesh) usize {
    var total = regionMemoryBytes(chunk, mesh);
    if (mesh) |m| {
        const memory = m.memorySnapshot();
        total +|= memory.capacity_bytes;
    }
    return total;
}

/// Caller holds the manager lock. Reserve only allocation work still ahead of
/// the CPU pipeline; upload-ready bytes and GPU growth are charged separately.
pub fn unusedCpuBuildReservation(self: *const Self, chunk: *const LODChunk, mesh: ?*LODMesh) usize {
    if (!self.usesCanonicalSource()) {
        const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
        return if (chunk.data == .empty) @min(budget, LOGICAL_LOD_REGION_RESERVATION_BYTES) else 0;
    }
    const cpu_work = switch (chunk.getState()) {
        .queued_for_generation, .generating, .generated, .queued_for_mesh, .meshing => true,
        // Cancellation/completion can publish a state before CPU ownership is
        // released. An uploading pin, in contrast, belongs to the GPU path.
        .missing, .mesh_ready => chunk.isPinned(),
        .uploading, .renderable, .unloading => false,
    };
    if (!cpu_work) return 0;
    return @import("lod_budget_allocator.zig").BudgetAllocator.admission_bytes -| regionMemoryBytes(chunk, mesh);
}

/// Distance/coverage removal retains the mesh in deferred deletion. Credit
/// only source data and unused CPU allowance, never its pending/GPU buffers.
fn releaseRegionSourceAccounting(self: *Self, chunk: *const LODChunk, mesh: ?*LODMesh) void {
    const source_bytes = regionMemoryBytes(chunk, null);
    const reservation = unusedCpuBuildReservation(self, chunk, mesh);
    self.memory_governor.used_bytes -|= source_bytes;
    self.memory_governor.logical_admission_bytes -|= source_bytes +| reservation;
}

pub fn enforceMemoryBudget(self: *Self) !void {
    const budget_mb = self.config.getMemoryBudgetMB();
    if (budget_mb == 0) return;
    const budget_bytes = @as(usize, budget_mb) * 1024 * 1024;
    const hysteresis_low = (budget_bytes * 4) / 5; // 80% re-expand threshold
    // An urgent CPU admission takes precedence over a pending upload request:
    // admitting local source progress unblocks canonical readiness, whereas
    // background CPU work must not evict protected near coverage.
    const has_urgent_recovery = self.memory_governor.required_admission_bytes != 0 or
        self.memory_governor.required_upload_bytes != 0;
    const recovery_target = if (self.memory_governor.required_admission_bytes != 0)
        budget_bytes -| self.memory_governor.required_admission_bytes
    else if (self.memory_governor.required_upload_bytes != 0)
        budget_bytes -| self.memory_governor.required_upload_bytes
    else if (self.memory_governor.required_horizon_upload_bytes != 0)
        lod_service.memoryLimitWithNearUsage(@intFromEnum(lod_service.Class.horizon), budget_bytes, self.memory_governor.near_exclusive_bytes) -| self.memory_governor.required_horizon_upload_bytes
    else
        budget_bytes;

    const lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlock();

    // Reclaim retained slack while radii are reduced, even in the 80-100%
    // band: otherwise capacity can prevent the hysteresis from ever recovering.
    var reduced = false;
    for (self.memory_governor.radius_shrink_chunks) |shrink| {
        reduced = reduced or shrink != 0;
    }
    if (reduced) self.memory_governor.pressure_pending = true;

    var settled = self.memory_governor.required_upload_bytes == 0 and
        self.mesh_disposal.queue.items.len == 0 and
        self.stats.pool_gpu_retired_bytes == 0 and
        self.stats.direct_gpu_retired_bytes == 0 and
        self.stats.compact_pool_retired_bytes == 0 and
        self.generation_tokens.count() == 0 and self.transition_tokens.count() == 0;
    var queued_uploads: usize = 0;
    for (0..LODLevel.count) |i| {
        queued_uploads += self.upload_queues[i].count();
        settled = settled and self.job_dispatcher.queues[i].count() == 0;
    }
    const logical = @max(self.memory_governor.used_bytes, self.memory_governor.logical_admission_bytes);
    if (settled and reduced and logical < hysteresis_low and self.pending_region_count != 0) {
        // Background uploads intentionally parked by the reserve must not keep
        // near radii shrunk forever. Recheck live costs, never a cached denial:
        // pool growth/trim can change admission without changing chunk state.
        // Cost queries are bounded by pending work and run only in recovery,
        // not in telemetry. All parked bytes still count toward both limits.
        settled = parked: {
            if (queued_uploads != self.pending_region_count or queued_uploads > manager_ctx.MAX_PENDING_LOD_REGIONS) break :parked false;
            const hard_available = budget_bytes -| logical;
            const active = lod_chunk.activeLODCount(self.config);
            var parked_count: usize = 0;
            var parked_cpu_bytes: usize = 0;
            for (0..LODLevel.count) |i| {
                var level_parked: usize = 0;
                var iter = self.regions[i].iterator();
                while (iter.next()) |entry| {
                    const chunk = entry.value_ptr.*;
                    if (chunk.isPinned()) break :parked false;
                    switch (chunk.getState()) {
                        .missing, .renderable => continue,
                        .uploading => {},
                        else => break :parked false,
                    }
                    if (i >= active or (chunk.service_lane != @intFromEnum(lod_service.Class.horizon) and
                        chunk.service_lane != @intFromEnum(lod_service.Class.refinement))) break :parked false;
                    if (parked_count >= self.pending_region_count) break :parked false;
                    const mesh = self.meshes[i].get(entry.key_ptr.*) orelse break :parked false;
                    const cost = self.gpu_bridge.uploadMemoryCost(mesh);
                    const soft_available = lod_service.memoryLimitWithNearUsage(chunk.service_lane, budget_bytes, self.memory_governor.near_exclusive_bytes) -| logical;
                    if (cost == 0 or cost <= soft_available or cost > hard_available) break :parked false;
                    parked_count += 1;
                    level_parked += 1;
                    parked_cpu_bytes += mesh.pendingUploadBytes();
                }
                if (level_parked != self.upload_queues[i].count()) break :parked false;
            }
            break :parked parked_count == self.pending_region_count and parked_cpu_bytes == self.stats.pending_cpu_upload_bytes;
        };
    } else {
        settled = settled and self.pending_region_count == 0 and queued_uploads == 0 and self.stats.pending_cpu_upload_bytes == 0;
    }
    if (reduced and settled and logical < hysteresis_low) {
        const now = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
        if (self.memory_governor.reexpand_after_ms == null or self.memory_governor.reexpand_logical_bytes != logical) {
            self.memory_governor.reexpand_after_ms = now + 2000;
            self.memory_governor.reexpand_logical_bytes = logical;
        } else if (now >= self.memory_governor.reexpand_after_ms.?) {
            for (&self.memory_governor.radius_shrink_chunks) |*shrink| {
                shrink.* = @max(0, shrink.* - 1);
            }
            self.memory_governor.reexpand_after_ms = null;
            log.log.trace("LOD memory settled below 80% budget; re-expanding radii", .{});
        }
    } else {
        self.memory_governor.reexpand_after_ms = null;
    }
    if (@max(self.memory_governor.used_bytes, self.memory_governor.logical_admission_bytes) <= recovery_target) return;
    self.memory_governor.pressure_pending = true;

    const Candidate = struct { key: LODRegionKey, distance_sq: i64, unfinished: bool };
    var candidates = std.ArrayListUnmanaged(Candidate).empty;
    defer candidates.deinit(self.allocator);

    const player = self.loadPlayerChunkPos();
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    const radii = self.config.getRadii();
    for (0..active_lod_count - 1) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const chunk = entry.value_ptr.*;
            if (chunk.isPinned()) continue;
            // Horizon recovery may discard stale outer local/refinement work,
            // but not the horizon candidates waiting for that recovered slot.
            // Otherwise the recovery loop can repeatedly evict its own queued
            // horizon source and never produce configured-horizon coverage.
            if (!has_urgent_recovery and self.memory_governor.required_horizon_upload_bytes != 0 and
                chunk.service_lane == @intFromEnum(lod_service.Class.horizon)) continue;
            switch (chunk.getState()) {
                .renderable, .generated, .mesh_ready, .uploading => {},
                else => continue,
            }
            // Coarsest active LOD regions have no renderable parent fallback and are
            // intentionally excluded so eviction never opens horizon holes.
            const parent = key.parentKey() orelse continue;
            const parent_idx = @intFromEnum(parent.lod);
            const parent_chunk = self.regions[parent_idx].get(parent) orelse continue;
            if (parent_chunk.getState() != .renderable) continue;
            const bounds = key.chunkBounds();
            // Keep full-chunk fallback coverage. Evicting inside this floor
            // cannot be excluded by a safe radius reduction and would requeue.
            // Preserve the same local collar that the scheduler gives near
            // services. Otherwise pressure can evict a near target and then
            // shrink its effective radius below that target, permanently
            // stalling canonical readiness despite fair wheel turns.
            const local_floor = @min(radii[i], @max(0, self.config.getChunkRenderRadius()) +| LOCAL_SERVICE_COLLAR_CHUNKS);
            if (bounds.intersectsRadius(player.cx, player.cz, local_floor)) continue;
            const mesh = self.meshes[i].get(key);
            try candidates.append(self.allocator, .{
                .key = key,
                .distance_sq = bounds.distanceSquaredToPoint(player.cx, player.cz),
                .unfinished = chunk.getState() != .renderable and (mesh == null or !mesh.?.isReady()),
            });
        }
    }

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            if (a.unfinished != b.unfinished) return a.unfinished;
            return a.distance_sq > b.distance_sq;
        }
    }.lt);

    var used = self.memory_governor.used_bytes;
    var reserved = self.memory_governor.logical_admission_bytes -| used;
    // Direct buffers already queued for deletion will pay this deficit after
    // retirement. Do not evict more visible terrain for the same debt, but do
    // not credit these bytes to actual accounting or admission either.
    var deferred_credit: usize = @intCast(self.stats.direct_gpu_retired_bytes);
    for (self.mesh_disposal.queue.items) |mesh| {
        const memory = mesh.memorySnapshot();
        if (!memory.pooled) deferred_credit += memory.capacity_bytes;
    }
    var evicted_count: usize = 0;
    var grew = false;
    for (candidates.items) |candidate| {
        if ((used -| deferred_credit) +| reserved <= recovery_target) break;
        if (evicted_count >= MAX_MEMORY_EVICTIONS_PER_UPDATE) break;
        const idx = @intFromEnum(candidate.key.lod);
        const chunk = self.regions[idx].get(candidate.key) orelse continue;
        if (chunk.isPinned()) continue;
        const state = chunk.getState();
        switch (state) {
            .renderable, .generated, .mesh_ready, .uploading => {},
            else => continue,
        }
        const parent = candidate.key.parentKey() orelse continue;
        const parent_chunk = self.regions[@intFromEnum(parent.lod)].get(parent) orelse continue;
        if (parent_chunk.getState() != .renderable) continue;
        const mesh = self.meshes[idx].get(candidate.key);
        const bytes = regionMemoryBytes(chunk, mesh);
        // Upload queues own raw pointers, unlike the key/token lifecycle heaps.
        // Remove every occurrence before freeing, preserving other entries and
        // their order. Each pop makes room, so requeue cannot allocate or fail.
        for (&self.upload_queues) |*queue| {
            const attempts = queue.count();
            for (0..attempts) |_| {
                const queued = queue.pop().?;
                if (queued != chunk) queue.push(queued) catch unreachable;
            }
        }
        if (state != .renderable) {
            std.debug.assert(self.pending_region_count > 0);
            self.pending_region_count -= 1;
        }
        reserved -|= unusedCpuBuildReservation(self, chunk, mesh);
        self.noteRegionRemoved(candidate.key, chunk);
        if (mesh) |m| {
            const memory = m.memorySnapshot();
            if (!memory.pooled) deferred_credit += memory.capacity_bytes;
            m.clearPendingVertices();
            m.releasePendingCompactTile();
            self.queueMeshDeletion(m);
            _ = self.meshes[idx].remove(candidate.key);
        }
        chunk.deinit(self.allocator);
        self.allocator.destroy(chunk);
        _ = self.regions[idx].remove(candidate.key);
        used = if (bytes >= used) 0 else used - bytes;
        self.memory_governor.used_bytes = used;
        self.memory_governor.logical_admission_bytes = used +| reserved;
        self.stats.evictions += 1;
        evicted_count += 1;

        // The scheduler intersects inclusive chunk footprints, not centers.
        // Integer sqrt minus one excludes even an exact boundary hit. Taking
        // the maximum reduction retains the nearest eviction at each level.
        const distance: i32 = @intCast(@min(std.math.sqrt(@as(u64, @intCast(candidate.distance_sq))), std.math.maxInt(i32)));
        const local_floor = @min(radii[idx], @max(0, self.config.getChunkRenderRadius()) +| LOCAL_SERVICE_COLLAR_CHUNKS);
        const radius = @max(local_floor, distance - 1);
        const shrink = @max(0, radii[idx] - radius);
        if (shrink > self.memory_governor.radius_shrink_chunks[idx]) {
            self.memory_governor.radius_shrink_chunks[idx] = shrink;
            grew = true;
        }
    }
    if (grew) {
        log.log.warn("LOD memory pressure; evicted {} regions this update and shrank finer radii (shrink={any})", .{ evicted_count, self.memory_governor.radius_shrink_chunks });
    }
}

/// Update statistics
pub fn updateStats(self: *Self) void {
    self.stats.reset();
    var source_data_cpu_bytes: usize = 0;
    var direct_mesh_gpu_bytes: usize = 0;
    var pending_cpu_upload_bytes: usize = 0;
    var deferred_deletion_gpu_bytes: usize = 0;
    var deferred_deletion_cpu_bytes: usize = 0;
    var resident_region_count: usize = 0;
    var admission_reservation_bytes: usize = 0;
    var source_cache_reservation_bytes: usize = 0;
    var near_exclusive_bytes: usize = 0;

    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();

    source_data_cpu_bytes += @import("lod_manager_near_source_ops.zig").memoryBytes(self);
    if (self.source_hierarchy) |source| {
        // Source entries and background scratch are allocated independently of
        // a region's 16 MiB quota. Reserve the configured cache capacity until
        // its sampled allocation reaches that capacity; otherwise a cold
        // scheduler can admit 24 MiB regions while the retained source cache
        // fills underneath them and exceed the hard cap.
        const source_bytes = source.memoryBytes();
        source_data_cpu_bytes += source_bytes;
        source_cache_reservation_bytes = source.cache_budget_bytes -| source_bytes;
    }
    source_data_cpu_bytes += self.canonical_refresh_bytes.load(.acquire);
    for (0..LODLevel.count) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            resident_region_count += 1;
            self.stats.recordState(i, chunk.getState());

            // Calculate actual memory usage for this chunk's data
            switch (chunk.data) {
                .simplified => |*s| {
                    source_data_cpu_bytes += s.totalMemoryBytes();
                },
                .empty, .full => {},
            }
            admission_reservation_bytes +|= unusedCpuBuildReservation(self, chunk, self.meshes[i].get(entry.key_ptr.*));
            if (chunk.service_lane < @intFromEnum(lod_service.Class.horizon)) {
                near_exclusive_bytes +|= regionExclusiveMemoryBytes(chunk, self.meshes[i].get(entry.key_ptr.*));
            }
        }

        // Direct meshes own a dedicated GPU buffer. Pooled mesh capacity is a
        // sub-allocation and is accounted once by the renderer pool snapshot.
        var mesh_iter = self.meshes[i].iterator();
        while (mesh_iter.next()) |entry| {
            const mesh = entry.value_ptr.*;
            const memory = mesh.memorySnapshot();
            self.stats.mesh_count[i] += 1;
            self.stats.mesh_vertices[i] += memory.vertex_count;
            pending_cpu_upload_bytes += memory.pending_upload_bytes;
            if (!memory.pooled) direct_mesh_gpu_bytes += memory.capacity_bytes;
        }

        self.stats.gen_queue_depth[i] = @intCast(self.job_dispatcher.queues[i].count());
        self.stats.upload_queue_depth[i] = @intCast(self.upload_queues[i].count());
    }

    // A queued mesh is no longer in the render map. Count its retained GPU
    // allocation and pending CPU vertices independently; pooled allocations
    // remain included in the pool capacity below and must not be double-counted.
    for (self.mesh_disposal.queue.items) |mesh| {
        const memory = mesh.memorySnapshot();
        deferred_deletion_gpu_bytes += memory.capacity_bytes;
        deferred_deletion_cpu_bytes += memory.pending_upload_bytes;
        if (!memory.pooled) direct_mesh_gpu_bytes += memory.capacity_bytes;
    }

    const pool_memory = self.renderer.memoryStats();
    const known_memory_bytes = source_data_cpu_bytes +
        direct_mesh_gpu_bytes +
        pool_memory.pool_gpu_capacity_bytes +
        pool_memory.pool_gpu_retired_bytes +
        pool_memory.direct_gpu_retired_bytes +
        pool_memory.pool_cpu_shadow_bytes +
        // Compact tiles are sub-allocations of this production GPU pool. Its
        // capacity is the real allocation retained by the renderer and must be
        // governed alongside source data; allocated bytes would double-count it.
        pool_memory.compact_pool_capacity_bytes +
        pending_cpu_upload_bytes +
        deferred_deletion_cpu_bytes;
    admission_reservation_bytes = std.math.add(usize, admission_reservation_bytes, source_cache_reservation_bytes) catch std.math.maxInt(usize);
    const logical_admission_bytes = std.math.add(usize, known_memory_bytes, admission_reservation_bytes) catch std.math.maxInt(usize);
    self.stats.addMemory(known_memory_bytes);
    self.stats.pool_gpu_capacity_bytes = @intCast(pool_memory.pool_gpu_capacity_bytes);
    self.stats.pool_gpu_retired_bytes = @intCast(pool_memory.pool_gpu_retired_bytes);
    self.stats.direct_gpu_retired_bytes = @intCast(pool_memory.direct_gpu_retired_bytes);
    self.stats.pool_gpu_allocated_bytes = @intCast(pool_memory.pool_gpu_allocated_bytes);
    self.stats.pool_gpu_slack_bytes = @intCast(pool_memory.pool_gpu_slack_bytes);
    self.stats.pool_cpu_shadow_bytes = @intCast(pool_memory.pool_cpu_shadow_bytes);
    self.stats.compact_pool_capacity_bytes = @intCast(pool_memory.compact_pool_capacity_bytes);
    self.stats.compact_pool_allocated_bytes = @intCast(pool_memory.compact_pool_allocated_bytes);
    self.stats.compact_pool_free_bytes = @intCast(pool_memory.compact_pool_free_bytes);
    self.stats.compact_pool_retired_bytes = @intCast(pool_memory.compact_pool_retired_bytes);
    self.stats.direct_mesh_gpu_bytes = @intCast(direct_mesh_gpu_bytes);
    self.stats.source_data_cpu_bytes = @intCast(source_data_cpu_bytes);
    self.stats.resident_region_count = @intCast(resident_region_count);
    self.stats.source_cache_reservation_bytes = @intCast(source_cache_reservation_bytes);
    self.stats.logical_admission_reservation_bytes = @intCast(admission_reservation_bytes);
    self.stats.logical_admission_bytes = @intCast(logical_admission_bytes);
    self.stats.pending_cpu_upload_bytes = @intCast(pending_cpu_upload_bytes);
    self.stats.deferred_deletion_gpu_bytes = @intCast(deferred_deletion_gpu_bytes);
    self.stats.deferred_deletion_cpu_bytes = @intCast(deferred_deletion_cpu_bytes);
    self.stats.store_hits = self.cache_hits;
    self.stats.store_misses = self.cache_misses;
    self.stats.cache_hits = self.cache_hits;
    self.stats.cache_misses = self.cache_misses;
    self.stats.cancelled_jobs = self.cancelled_jobs;
    self.stats.generation_token_overflows = self.generation_tokens.overflowEvents();
    self.stats.transition_token_overflows = self.transition_tokens.overflowEvents();
    self.stats.fade_token_overflows = self.fade_tokens.overflowEvents();
    self.memory_governor.used_bytes = known_memory_bytes;
    self.memory_governor.logical_admission_bytes = logical_admission_bytes;
    self.memory_governor.near_exclusive_bytes = near_exclusive_bytes;
    self.profiling.setPendingCpuUploadBytes(pending_cpu_upload_bytes);
    self.profiling.setRetiredPoolGpuBytes(pool_memory.pool_gpu_retired_bytes);
    self.profiling.setRetiredDirectGpuBytes(pool_memory.direct_gpu_retired_bytes);
    self.profiling.setMemoryAccounting(
        pool_memory.pool_gpu_capacity_bytes,
        pool_memory.pool_gpu_allocated_bytes,
        pool_memory.pool_gpu_slack_bytes,
        pool_memory.pool_cpu_shadow_bytes,
        pool_memory.compact_pool_capacity_bytes,
        pool_memory.compact_pool_allocated_bytes,
        pool_memory.compact_pool_free_bytes,
        pool_memory.compact_pool_retired_bytes,
        direct_mesh_gpu_bytes,
        known_memory_bytes,
    );

    if (engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false)) {
        const S = struct {
            var counter: u64 = 0;
        };
        S.counter += 1;
        if (S.counter % 120 == 1) {
            log.log.info("LOD_STATS_DIAG gen_q={any} upload_q={any} meshes={any} verts={any} cache_hits={} cache_misses={} cache_hit_rate={d:.2} mem_mb={} upload_failures={} store_hits={} store_misses={} evictions={} ingestion_backlog={} drawn={any} instances={any}", .{
                self.stats.gen_queue_depth,
                self.stats.upload_queue_depth,
                self.stats.mesh_count,
                self.stats.mesh_vertices,
                self.stats.cache_hits,
                self.stats.cache_misses,
                self.stats.cacheHitRate(),
                self.stats.memory_used_mb,
                self.stats.upload_failures,
                self.stats.store_hits,
                self.stats.store_misses,
                self.stats.evictions,
                self.stats.ingestion_backlog,
                self.stats.drawn,
                self.stats.instances,
            });
        }
    }
}

/// Free LOD meshes where all underlying chunks are loaded
pub fn unloadLODWhereChunksLoaded(self: *Self, checker: ChunkChecker, ctx: *anyopaque) void {
    // Lock exclusive because we modify meshes and regions maps
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlock();

    const active_lod_count = lod_chunk.activeLODCount(self.config);
    for (0..active_lod_count) |i| {
        const storage = &self.regions[i];
        const meshes = &self.meshes[i];

        var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
        defer to_remove.deinit(self.allocator);

        var iter = meshes.iterator();
        while (iter.next()) |entry| {
            if (storage.get(entry.key_ptr.*)) |chunk| {
                // Don't unload if being processed (pinned) or not ready
                if (chunk.isPinned() or chunk.getState() == .generating or chunk.getState() == .meshing or chunk.getState() == .uploading) continue;

                const bounds = chunk.worldBounds();
                if (self.areAllChunksLoaded(bounds, checker, ctx)) {
                    to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                }
            }
        }

        for (to_remove.items) |rem_key| {
            if (storage.get(rem_key)) |chunk| {
                releaseRegionSourceAccounting(self, chunk, meshes.get(rem_key));
                self.noteRegionRemoved(rem_key, chunk);
            }
            if (meshes.fetchRemove(rem_key)) |mesh_entry| {
                // Queue for deferred deletion to avoid waitIdle stutter
                self.queueMeshDeletion(mesh_entry.value);
            }
            if (storage.fetchRemove(rem_key)) |chunk_entry| {
                if (chunk_entry.value.getState() != .missing and chunk_entry.value.getState() != .renderable and self.pending_region_count > 0) {
                    self.pending_region_count -= 1;
                }
                chunk_entry.value.deinit(self.allocator);
                self.allocator.destroy(chunk_entry.value);
            }
        }
    }
}

/// Check if all chunks within the given world bounds are loaded and renderable.
/// Checks if all chunks within the LOD0 radius that could cover this LOD region
/// are loaded and renderable. Chunks outside the LOD0 radius are skipped since
/// they represent LOD terrain, not full-detail chunks that would cover this region.
pub fn areAllChunksLoaded(self: *Self, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
    const chunk_radius: i64 = @as(i64, self.config.getChunkRenderRadius());
    const radius_sq = chunk_radius * chunk_radius;
    const player = self.loadPlayerChunkPos();

    const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
    const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
    const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
    const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

    var cz = min_cz;
    while (cz <= max_cz) : (cz += 1) {
        var cx = min_cx;
        while (cx <= max_cx) : (cx += 1) {
            const dx: i64 = @as(i64, cx) - @as(i64, player.cx);
            const dz: i64 = @as(i64, cz) - @as(i64, player.cz);
            if (dx * dx + dz * dz > radius_sq) {
                return false;
            }
            if (!checker(cx, cz, ctx)) {
                return false;
            }
        }
    }
    return true;
}
