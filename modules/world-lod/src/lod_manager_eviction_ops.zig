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
        // Returning a pooled range does not release the renderer's backing
        // buffer or CPU shadow, so it cannot lower the known memory total.
        if (!memory.pooled) total += memory.capacity_bytes;
    }
    return total;
}

pub fn enforceMemoryBudget(self: *Self) !void {
    const budget_mb = self.config.getMemoryBudgetMB();
    if (budget_mb == 0) return;
    const budget_bytes = @as(usize, budget_mb) * 1024 * 1024;
    const hysteresis_low = (budget_bytes * 4) / 5; // 80% re-expand threshold

    // Decay path: comfortably under budget -> gradually re-expand radii.
    if (self.memory_governor.used_bytes < hysteresis_low) {
        const lock_wait_timer = self.profiling.begin();
        self.mutex.lock();
        self.profiling.end(.manager_lock_wait, lock_wait_timer);
        const lock_hold_timer = self.profiling.begin();
        var decayed = false;
        for (&self.memory_governor.radius_shrink_chunks) |*s| {
            if (s.* > 0) {
                s.* -= 1;
                decayed = true;
            }
        }
        self.profiling.end(.manager_lock_hold, lock_hold_timer);
        self.mutex.unlock();
        if (decayed) {
            log.log.trace("LOD memory below 80% budget; re-expanding radii", .{});
        }
        return;
    }

    if (self.memory_governor.used_bytes <= budget_bytes) return; // 80-100% band: hold

    const Candidate = struct { key: LODRegionKey, distance_sq: i64 };
    var candidates = std.ArrayListUnmanaged(Candidate).empty;
    defer candidates.deinit(self.allocator);

    const lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlock();

    const player = self.loadPlayerChunkPos();
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    for (0..active_lod_count) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const chunk = entry.value_ptr.*;
            if (chunk.getState() != .renderable or chunk.isPinned()) continue;
            // Coarsest active LOD regions have no renderable parent fallback and are
            // intentionally excluded so eviction never opens horizon holes.
            const parent = key.parentKey() orelse continue;
            const parent_idx = @intFromEnum(parent.lod);
            const parent_chunk = self.regions[parent_idx].get(parent) orelse continue;
            if (parent_chunk.getState() != .renderable) continue;
            const bounds = key.chunkBounds();
            try candidates.append(self.allocator, .{ .key = key, .distance_sq = bounds.distanceSquaredToPoint(player.cx, player.cz) });
        }
    }

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return a.distance_sq > b.distance_sq;
        }
    }.lt);

    var used = self.memory_governor.used_bytes;
    var evicted_count: usize = 0;
    for (candidates.items) |candidate| {
        if (used <= budget_bytes) break;
        if (evicted_count >= MAX_MEMORY_EVICTIONS_PER_UPDATE) break;
        const idx = @intFromEnum(candidate.key.lod);
        const chunk = self.regions[idx].get(candidate.key) orelse continue;
        if (chunk.getState() != .renderable or chunk.isPinned()) continue;
        const mesh = self.meshes[idx].get(candidate.key);
        const bytes = regionMemoryBytes(chunk, mesh);
        self.noteRegionRemoved(candidate.key, chunk);
        if (mesh) |m| {
            self.queueMeshDeletion(m);
            _ = self.meshes[idx].remove(candidate.key);
        }
        chunk.deinit(self.allocator);
        self.allocator.destroy(chunk);
        _ = self.regions[idx].remove(candidate.key);
        used = if (bytes >= used) 0 else used - bytes;
        self.memory_governor.used_bytes = used;
        self.stats.evictions += 1;
        evicted_count += 1;
    }

    // Any eviction means the active radii are too ambitious for the current
    // budget. Shrink finer bands immediately so evicted regions do not get
    // queued again next update. The coarsest horizon band is exempt so the
    // vista never develops holes.
    if (evicted_count > 0 or self.memory_governor.used_bytes > budget_bytes) {
        const active = lod_chunk.activeLODCount(self.config);
        var grew = false;
        var i: usize = 1;
        while (i + 1 < active) : (i += 1) {
            if (self.memory_governor.radius_shrink_chunks[i] < 64) {
                self.memory_governor.radius_shrink_chunks[i] += 1;
                grew = true;
            }
        }
        if (grew) {
            log.log.warn("LOD memory pressure; evicted {} regions this update and shrank finer radii (shrink={any})", .{ evicted_count, self.memory_governor.radius_shrink_chunks });
        }
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
    var unmaterialized_region_count: usize = 0;

    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();

    source_data_cpu_bytes += @import("lod_manager_near_source_ops.zig").memoryBytes(self);
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
                .empty => unmaterialized_region_count += 1,
                .full => {},
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
        pool_memory.pool_cpu_shadow_bytes +
        // Compact tiles are sub-allocations of this production GPU pool. Its
        // capacity is the real allocation retained by the renderer and must be
        // governed alongside source data; allocated bytes would double-count it.
        pool_memory.compact_pool_capacity_bytes +
        pending_cpu_upload_bytes +
        deferred_deletion_cpu_bytes;
    const budget_bytes = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
    const reservation_per_region = if (budget_bytes == 0) 0 else @min(budget_bytes, LOGICAL_LOD_REGION_RESERVATION_BYTES);
    // Reserve conservatively only for regions that do not have measurable
    // source data yet. Materialized regions are governed by their actual CPU
    // and GPU footprint instead of a permanent per-region distance cap.
    const admission_reservation_bytes = std.math.mul(usize, unmaterialized_region_count, reservation_per_region) catch std.math.maxInt(usize);
    const logical_admission_bytes = std.math.add(usize, known_memory_bytes, admission_reservation_bytes) catch std.math.maxInt(usize);
    self.stats.addMemory(known_memory_bytes);
    self.stats.pool_gpu_capacity_bytes = @intCast(pool_memory.pool_gpu_capacity_bytes);
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
    self.profiling.setPendingCpuUploadBytes(pending_cpu_upload_bytes);
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
