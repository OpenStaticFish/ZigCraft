const std = @import("std");
const lod_options = @import("world_lod_options");
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
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Vertex = @import("engine-rhi").Vertex;
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
const lod_service = @import("lod_service.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const TextureAtlas = @import("engine-assets").TextureAtlas;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODStats = @import("lod_stats.zig").LODStats;
const manager_ctx = @import("lod_manager_context.zig");
const LODIngestionQueue = @import("lod_manager.zig").LODIngestionQueue;
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
const TELEPORT_CANCEL_DISTANCE_CHUNKS: i32 = 32;

pub fn storePlayerChunkPos(self: *Self, cx: i32, cz: i32) void {
    self.player_cx.store(cx, .release);
    self.player_cz.store(cz, .release);
}

pub fn loadPlayerChunkPos(self: *const Self) PlayerChunkPos {
    return .{
        .cx = self.player_cx.load(.acquire),
        .cz = self.player_cz.load(.acquire),
    };
}

pub fn init(allocator: std.mem.Allocator, config: ILODConfig, gpu_bridge: LODGPUBridge, render_iface: LODRenderInterface, generator: LODGenerator, atlas: *const TextureAtlas) !*Self {
    const mgr = try allocator.create(Self);
    errdefer allocator.destroy(mgr);

    var regions: [LODLevel.count]RegionMap = undefined;
    var meshes: [LODLevel.count]MeshMap = undefined;
    var gen_queues: [LODLevel.count]*JobQueue = undefined;
    var upload_queues: [LODLevel.count]RingBuffer(*LODChunk) = undefined;
    var initialized_levels: usize = 0;

    errdefer {
        var i: usize = 0;
        while (i < initialized_levels) : (i += 1) {
            upload_queues[i].deinit();
            gen_queues[i].deinit();
            allocator.destroy(gen_queues[i]);
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    for (0..LODLevel.count) |i| {
        var region_map = RegionMap.init(allocator);
        errdefer region_map.deinit();

        var mesh_map = MeshMap.init(allocator);
        errdefer mesh_map.deinit();

        const queue = try allocator.create(JobQueue);
        errdefer allocator.destroy(queue);
        queue.* = JobQueue.init(allocator);
        errdefer queue.deinit();

        var upload_queue = try RingBuffer(*LODChunk).init(allocator, 128);
        errdefer upload_queue.deinit();

        regions[i] = region_map;
        meshes[i] = mesh_map;
        gen_queues[i] = queue;
        upload_queues[i] = upload_queue;
        initialized_levels += 1;
    }

    mgr.* = .{
        .allocator = allocator,
        .config = config,
        .regions = regions,
        .meshes = meshes,
        .job_dispatcher = .{ .queues = gen_queues },
        .upload_queues = upload_queues,
        .transition_queue = .empty,
        .player_cx = std.atomic.Value(i32).init(0),
        .player_cz = std.atomic.Value(i32).init(0),
        .scan_states = [_]manager_ctx.LODScanState{manager_ctx.LODScanState{}} ** LODLevel.count,
        .stats = .{},
        .profiling = .init(engine_core.envFlag("ZIGCRAFT_LOD_PROFILE", false) or lod_options.benchmark_lod_profile),
        .cache_hits = 0,
        .cache_misses = 0,
        .cancelled_jobs = 0,
        .mutex = .{},
        .gpu_bridge = gpu_bridge,
        .generator = generator,
        .atlas = atlas,
        .paused = false,
        .memory_governor = .{},
        .update_tick = 0,
        .mesh_disposal = .{},
        .renderer = render_iface,
        .cleanup_covered_regions = true,
        .cache_store = .{ .store_size_cap_mb = config.getLODStoreSizeCapMB(), .use_config_store_size_cap = true },
        .cache_io = undefined,
        .ingestion_queue = LODIngestionQueue.init(allocator),
        .near_source_enabled = engine_core.envFlag("ZIGCRAFT_LOD_NEAR_SOURCE", false),
    };

    mgr.cache_io = try @import("lod_cache_io.zig").CacheIoPipeline.init(allocator, &mgr.profiling);
    errdefer mgr.cache_io.deinit();

    const cpu_count = std.Thread.getCpuCount() catch MIN_LOD_WORKERS;
    const total_budget = @max(@as(usize, 5), cpu_count -| 1);
    const foreground_minimum: usize = 4;
    const lod_capacity = @max(MIN_LOD_WORKERS, total_budget -| foreground_minimum);
    const lod_worker_count = @min(std.math.clamp(cpu_count / 2, MIN_LOD_WORKERS, MAX_LOD_WORKERS), lod_capacity);

    // Opt in only while queues are empty, before the shared worker pool starts.
    mgr.generation_tokens.enableServiceLanes(&lod_service.WHEEL);
    mgr.transition_tokens.enableServiceLanes(&lod_service.WHEEL);
    mgr.job_dispatcher.queues[LODLevel.count - 1].enableServiceLanes(&lod_service.WHEEL);
    if (engine_core.envFlag("ZIGCRAFT_LOD_CANONICAL", false) and generator.generate_chunk_summary != null) {
        const budget = @as(usize, config.getMemoryBudgetMB()) * 1024 * 1024;
        mgr.source_hierarchy = try Self.SourceHierarchy.init(allocator, generator, mgr.job_dispatcher.queues[LODLevel.count - 1], std.math.clamp(budget / 4, 16 * 1024 * 1024, 64 * 1024 * 1024));
        mgr.near_source_enabled = false;
    }
    errdefer if (mgr.source_hierarchy) |source| source.deinit();
    mgr.job_dispatcher.worker_pool = try WorkerPool.init(allocator, lod_worker_count, mgr.job_dispatcher.queues[LODLevel.count - 1], mgr, @import("lod_manager_generation_ops.zig").processLODJob);

    const radii = config.getRadii();
    log.log.info("LODManager initialized with radii: {any} | workers={}", .{
        radii,
        lod_worker_count,
    });

    return mgr;
}

pub fn stopWorkersAndJoin(self: *Self) void {
    if (self.job_dispatcher.stop_flag.swap(true, .acq_rel)) return;
    // Abort any in-flight heightmap jobs BEFORE joining the worker pool.
    // Coarse-LOD heightmap generation can take seconds per region and is
    // only interruptible via this flag (checked inside the generation loop).
    // This is the ONLY place stop_flag is set: normal pause()/unpause() and
    // map-open leave it false so LOD generation runs uninterrupted.

    const cancellation_lock_wait_timer = self.profiling.begin();
    self.mutex.lock();
    self.profiling.end(.manager_lock_wait, cancellation_lock_wait_timer);
    const cancellation_lock_hold_timer = self.profiling.begin();
    for (0..LODLevel.count) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| entry.value_ptr.*.requestCancellation();
    }
    self.profiling.end(.manager_lock_hold, cancellation_lock_hold_timer);
    self.mutex.unlock();

    // Stop and cleanup queues
    for (0..LODLevel.count) |i| {
        self.job_dispatcher.queues[i].stop();
    }

    // Cleanup worker pool. In-flight heightmap jobs were aborted by
    // stop_flag above, so this join completes promptly.
    if (self.job_dispatcher.worker_pool) |pool| {
        pool.deinit();
        self.job_dispatcher.worker_pool = null;
    }
}

pub fn deinit(self: *Self) void {
    self.stopWorkersAndJoin();
    @import("lod_manager_generation_ops.zig").drainCanonicalRefreshes(self, true);
    if (self.source_hierarchy) |source| {
        source.deinit();
        self.source_hierarchy = null;
    }

    // This is an explicit shutdown boundary: it is permitted to wait for the
    // dedicated cache worker and flush source snapshots before region storage
    // is released. The normal update path only enqueues/drains completions.
    self.shutdownCacheIO();
    self.cache_io.deinit();

    // All LOD workers and cache I/O are stopped. This is the sole manager
    // lifecycle boundary allowed to issue a device-wide synchronization; the
    // shutdown bucket keeps it out of runtime streaming telemetry.
    self.waitIdleTracked(.shutdown);

    for (0..LODLevel.count) |i| {
        self.job_dispatcher.queues[i].deinit();
        self.allocator.destroy(self.job_dispatcher.queues[i]);
        self.upload_queues[i].deinit();

        // Cleanup meshes
        var mesh_iter = self.meshes[i].iterator();
        while (mesh_iter.next()) |entry| {
            entry.value_ptr.*.releasePendingCompactTile();
            self.gpu_bridge.destroy(entry.value_ptr.*);
            entry.value_ptr.*.releaseAllocatorOwner();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.meshes[i].deinit();

        // Cleanup regions
        var region_iter = self.regions[i].iterator();
        while (region_iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.regions[i].deinit();
    }

    self.transition_queue.deinit(self.allocator);

    // Process any pending deletions after all LOD users have stopped.
    self.processMeshDeletions(std.math.maxInt(usize));
    self.mesh_disposal.queue.deinit(self.allocator);

    if (self.cache_store.cache_dir_path) |path| {
        self.allocator.free(path);
    }

    self.ingestion_queue.deinit(self.allocator);
    self.near_sources.deinit(self.allocator);
    self.near_source_retries.deinit(self.allocator);
    self.generation_tokens.deinit(self.allocator);
    self.transition_tokens.deinit(self.allocator);
    self.fade_tokens.deinit(self.allocator);

    // NOTE: LODManager does NOT own the renderer lifetime.
    // The renderer is owned by World and deinit'd there.

    self.allocator.destroy(self);
}

/// Update LOD system with player position
pub fn update(self: *Self, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    const update_timer = self.profiling.begin();
    defer self.profiling.end(.update, update_timer);
    self.beginUploadFrame(lodUploadBudgetBytes());
    self.memory_governor.required_admission_bytes = 0;
    self.memory_governor.required_admission_lane = @intFromEnum(lod_service.Class.refinement);
    // Completion application only: no filesystem or serialization occurs on
    // this frame/update path.
    self.drainCacheCompletions();
    // The GPU-culling scale fixture is already fully resident through the
    // production upload bridge. Do not let normal streaming add finer coverage
    // or evict its fixed source set while it is being measured.
    if (self.benchmark_fixture_active) {
        self.updateStats();
        return;
    }
    if (self.paused) return;
    if (self.usesCanonicalSource()) {
        @import("lod_manager_generation_ops.zig").drainCanonicalChanges(self);
        if (self.update_tick % 2 == 0) @import("lod_manager_generation_ops.zig").drainCanonicalRefreshes(self, false);
    }

    // Render detects compact submission failure under its shared lock. Only
    // this update thread may retire its GPU range and publish CPU fallback.
    self.recoverCompactDrawFailures();

    // Deferred deletion is frame-safe: renderer resource destruction retires
    // buffers/ranges through its frame-fence path rather than stalling the
    // device during routine streaming.
    self.mesh_disposal.timer += LOD_FRAME_DT_APPROX;
    if (self.mesh_disposal.timer >= DELETION_SWEEP_SECONDS) {
        self.processMeshDeletions(MAX_MESH_DELETIONS_PER_SWEEP);
        self.mesh_disposal.timer = 0;
    }

    // Safety: Check for NaN/Inf player position
    if (!std.math.isFinite(player_pos.x) or !std.math.isFinite(player_pos.z)) return;

    const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
    const previous_pc = self.loadPlayerChunkPos();
    self.storePlayerChunkPos(pc.chunk_x, pc.chunk_z);
    if (pc.chunk_x != previous_pc.cx or pc.chunk_z != previous_pc.cz) @import("lod_manager_near_source_ops.zig").prune(self);
    const moved_x = @abs(@as(i64, pc.chunk_x) - @as(i64, previous_pc.cx));
    const moved_z = @abs(@as(i64, pc.chunk_z) - @as(i64, previous_pc.cz));
    const teleport_distance_sq = @as(i64, TELEPORT_CANCEL_DISTANCE_CHUNKS) * TELEPORT_CANCEL_DISTANCE_CHUNKS;
    if (moved_x * moved_x + moved_z * moved_z >= teleport_distance_sq) {
        cancelWorkOutsideHorizon(self, pc.chunk_x, pc.chunk_z);
    }

    // Refresh spatial priorities without changing queue-owned FIFO tickets or
    // the service wheel. The rebuild is lazy, only on sufficiently large queues.
    self.job_dispatcher.queues[LODLevel.count - 1].updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};

    // Throttle heavy LOD management logic (generation queuing, state processing, unloads).
    // LOD management involves iterating over thousands of potential regions and can
    // take several milliseconds. LOD_UPDATE_DIVISOR bounds that frequency
    // while uploads and transition retirement continue on intervening updates.
    self.update_tick += 1;
    if (self.update_tick % LOD_UPDATE_DIVISOR != 0) {
        self.processUploads();
        self.decayTransitionFrames();
        return;
    }

    if (self.cleanup_covered_regions) {
        if (chunk_checker) |checker| {
            self.unloadLODWhereChunksLoaded(checker, checker_ctx.?);
        }
    }

    // Issue #119 Phase 4: Recenter classification cache if player moved far enough.
    // This ensures LOD chunks have cache coverage for consistent biome/surface data.
    const player_wx: i32 = @intFromFloat(player_pos.x);
    const player_wz: i32 = @intFromFloat(player_pos.z);
    _ = self.generator.maybeRecenterCache(player_wx, player_wz);

    const scheduling_timer = self.profiling.begin();
    queueServiceAdmissions(self, player_velocity, chunk_checker, checker_ctx);
    self.profiling.end(.scheduling, scheduling_timer);

    self.processQueuedGenerations(player_velocity) catch |err| {
        log.log.warn("LOD cache/generation dispatch error: {} (non-fatal)", .{err});
    };

    // Process state transitions
    if (self.usesCanonicalSource()) @import("lod_manager_generation_ops.zig").queueCanonicalRefreshes(self);
    @import("lod_manager_near_source_ops.zig").replay(self, 32);
    const transitions_timer = self.profiling.begin();
    self.processStateTransitions(player_velocity) catch |err| {
        log.log.warn("LOD state transitions error: {} (non-fatal)", .{err});
    };
    self.profiling.end(.state_transition, transitions_timer);

    // Process uploads (limited per frame)
    self.processUploads();

    // Update stats
    self.updateStats();
    const eviction_timer = self.profiling.begin();
    self.enforceMemoryBudget() catch |err| {
        log.log.warn("LOD memory budget eviction error: {} (non-fatal)", .{err});
    };
    self.profiling.end(.eviction, eviction_timer);

    // Periodic WARN-level LOD stats so logs/zigcraft.log shows LOD fill
    // progress by default (no env vars needed). update_tick counts frames;
    // every ~180 frames (~3s @ 60fps) gives a trend over a 20s diagnostic run.
    if (self.update_tick % 180 == 0) {
        const s = self.stats;
        log.log.warn("LOD_STATS: loaded={any} generating={any} meshing={any} genQ={} uploadQ={any} meshes={any} cache_hit/miss={}/{} store_hit/miss={}/{} evictions={}", .{
            s.loaded,
            s.generating,
            s.meshing,
            s.gen_queue_depth[LODLevel.count - 1],
            s.upload_queue_depth,
            s.mesh_count,
            s.cache_hits,
            s.cache_misses,
            s.store_hits,
            s.store_misses,
            s.evictions,
        });
    }

    // Unload distant regions
    const distant_eviction_timer = self.profiling.begin();
    self.unloadDistantRegions() catch |err| {
        log.log.warn("LOD unload error: {} (non-fatal)", .{err});
    };
    self.profiling.end(.eviction, distant_eviction_timer);

    // Chunk-derived ingestion: replay deferred ingestions, flush debounced
    // player edits, and persist any dirty source regions to the store.
    self.drainPendingIngestions();
    self.flushEditedChunks();
    self.flushDirtyStores();
    self.decayTransitionFrames();
}

/// One heavy update: at most 64 admissions and 512 examined coordinates per
/// class (2560 total). The wheel survives movement and pending-slot pressure.
pub fn queueServiceAdmissions(self: *Self, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) void {
    self.mutex.lockShared();
    const active = lod_chunk.activeLODCount(self.config);
    self.mutex.unlockShared();
    const coarsest = active - 1;
    var scans: [lod_service.CLASS_COUNT]usize = @splat(0);
    var exhausted: [lod_service.CLASS_COUNT]bool = @splat(false);
    var refinement_exhausted: [LODLevel.count]bool = @splat(false);
    var admitted: usize = 0;
    var turns: usize = 0;
    while (admitted < 64 and turns < 384) : (turns += 1) {
        self.mutex.lockShared();
        const pending_full = self.pending_region_count >= manager_ctx.MAX_PENDING_LOD_REGIONS;
        self.mutex.unlockShared();
        // Do not consume the next opportunity while globally blocked. A single
        // slot released next update must belong to the next class, not horizon.
        if (pending_full) {
            var next = self.service_admission_wheel;
            self.service_pending_blocked[next.next()] +|= 1;
            break;
        }
        const wheel_before = self.service_admission_wheel;
        const lane = self.service_admission_wheel.next();
        if (exhausted[lane] or scans[lane] >= 512) continue;
        const class: lod_service.Class = @enumFromInt(lane);
        var level: usize = coarsest;
        var scan_state = &self.scan_states[coarsest];
        switch (class) {
            .local_fallback => scan_state = &self.local_fallback_scan_state,
            .near0, .near1 => {
                level = if (class == .near0) 0 else 1;
                if (level >= coarsest) {
                    exhausted[lane] = true;
                    continue;
                }
                scan_state = &self.near_scan_states[level];
            },
            .horizon => {},
            .refinement => {
                var selected = false;
                for (0..coarsest) |_| {
                    level = self.refinement_level_cursor % coarsest;
                    self.refinement_level_cursor = (level + 1) % coarsest;
                    if (refinement_exhausted[level]) continue;
                    selected = true;
                    break;
                }
                if (!selected) {
                    exhausted[lane] = true;
                    continue;
                }
                scan_state = &self.scan_states[level];
            },
        }
        self.service_opportunities[lane] +|= 1;
        const result = self.queueLODService(@enumFromInt(level), lane, scan_state, @min(128, 512 - scans[lane]), velocity, chunk_checker, checker_ctx) catch |err| {
            log.log.warn("LOD service queue error for class {s}: {} (non-fatal)", .{ @tagName(class), err });
            // A failing call may already have examined its entire allowance.
            scans[lane] += @min(128, 512 - scans[lane]);
            exhausted[lane] = true;
            continue;
        };
        scans[lane] += result.examined;
        admitted += result.admitted;
        for (0..result.admitted) |_| self.service_counters.record(.admitted, lane);
        if (result.pending_blocked) self.service_pending_blocked[lane] +|= 1;
        if (result.memory_blocked) self.service_memory_blocked[lane] +|= 1;
        if (result.exhausted or result.memory_blocked) {
            if (class == .refinement) {
                refinement_exhausted[level] = true;
            } else {
                exhausted[lane] = true;
            }
        }
        if (result.pending_blocked) {
            // A full lifecycle queue is backpressure too. Preserve the turn
            // when no admission happened, just as for a full pending-region cap.
            if (result.admitted == 0) self.service_admission_wheel = wheel_before;
            break;
        }
    }
}

/// Get current statistics
pub fn getStats(self: *Self) LODStats {
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();
    var snapshot = self.stats;
    snapshot.profiling = self.profiling.snapshot();
    snapshot.service = self.service_counters.snapshot();
    return snapshot;
}

/// Pause all LOD generation
pub fn pause(self: *Self) void {
    self.paused = true;
    for (0..LODLevel.count) |i| {
        self.job_dispatcher.queues[i].setPaused(true);
    }

    // setPaused clears queued jobs. In-flight jobs are cancelled through their
    // per-region signal and token so they cannot publish stale data after an
    // unpause, even when unpause happens before a worker checks cancellation.
    self.mutex.lock();
    defer self.mutex.unlock();
    for (0..LODLevel.count) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.refresh_in_flight.load(.acquire)) chunk.requestCancellation();
            switch (chunk.getState()) {
                .generating => {
                    chunk.requestCancellation();
                    chunk.job_token +%= 1;
                    chunk.cache_read_queued = false;
                    if (self.pending_region_count > 0) self.pending_region_count -= 1;
                    chunk.setState(.missing);
                    self.cancelled_jobs +|= 1;
                },
                .meshing => {
                    chunk.requestCancellation();
                    chunk.job_token +%= 1;
                    // The generated source data remains valid. Requeue the
                    // mesh transition after unpause without discarding its
                    // pending admission slot.
                    chunk.setState(.generated);
                    self.enqueueTransition(entry.key_ptr.*, chunk, .mesh);
                    self.cancelled_jobs +|= 1;
                },
                .queued_for_generation => {
                    chunk.requestCancellation();
                    chunk.job_token +%= 1;
                    chunk.cache_read_queued = false;
                    if (self.pending_region_count > 0) self.pending_region_count -= 1;
                    chunk.setState(.missing);
                    self.cancelled_jobs +|= 1;
                },
                else => {},
            }
        }
    }
}

pub fn cancelWorkOutsideHorizon(self: *Self, player_cx: i32, player_cz: i32) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const radii = self.config.getRadii();
    const active = lod_chunk.activeLODCount(self.config);
    for (0..LODLevel.count) |i| {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.getState() == .renderable and chunk.refresh_in_flight.load(.acquire)) {
                if (i >= active or !entry.key_ptr.*.chunkBounds().intersectsRadius(player_cx, player_cz, radii[i])) chunk.requestCancellation();
                continue;
            }
            switch (chunk.getState()) {
                .queued_for_generation, .generating, .meshing => {},
                else => continue,
            }
            if (i < active and entry.key_ptr.*.chunkBounds().intersectsRadius(player_cx, player_cz, radii[i])) continue;

            const was_generation = chunk.getState() != .meshing;
            chunk.requestCancellation();
            chunk.job_token +%= 1;
            chunk.cache_read_queued = false;
            if (was_generation and self.pending_region_count > 0) self.pending_region_count -= 1;
            chunk.setState(if (was_generation) .missing else .generated);
            if (!was_generation) self.enqueueTransition(entry.key_ptr.*, chunk, .mesh);
            self.cancelled_jobs +|= 1;
        }
    }
}

/// Resume LOD generation
pub fn unpause(self: *Self) void {
    self.paused = false;
    for (0..LODLevel.count) |i| {
        self.job_dispatcher.queues[i].setPaused(false);
    }
}

/// Get LOD level for a given chunk distance
pub fn getLODForDistance(self: *const Self, chunk_x: i32, chunk_z: i32) LODLevel {
    const player = self.loadPlayerChunkPos();
    const dist_sq = pointDistanceSquared(chunk_x, chunk_z, player.cx, player.cz);
    const radii = self.config.getRadii();

    const active_lod_count = lod_chunk.activeLODCount(self.config);
    for (0..active_lod_count) |i| {
        const radius_sq = @as(i64, radii[i]) * @as(i64, radii[i]);
        if (dist_sq <= radius_sq) return @enumFromInt(@as(u3, @intCast(i)));
    }

    return @enumFromInt(@as(u3, @intCast(active_lod_count - 1)));
}

/// Check if a position is within LOD range
pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
    const radii = self.config.getRadii();
    const max_radius = radii[lod_chunk.activeLODCount(self.config) - 1];
    const player = self.loadPlayerChunkPos();
    const dist_sq = pointDistanceSquared(chunk_x, chunk_z, player.cx, player.cz);
    return dist_sq <= @as(i64, max_radius) * @as(i64, max_radius);
}

/// Render all LOD meshes
/// chunk_checker: Optional callback to check if regular chunks cover this region.
///                If all chunks in region are loaded, the LOD region is skipped.
///
/// NOTE: Acquires a shared lock on LODManager. LODRenderer must NOT attempt to acquire
/// a write lock on LODManager during rendering to avoid deadlocks.
pub fn render(self: *Self, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, layer: LODRenderLayer) void {
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();

    const visibility_timer = self.profiling.begin();
    defer self.profiling.end(.visibility, visibility_timer);
    self.renderer.render(&self.meshes, &self.regions, self.config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, &self.stats, if (self.profiling.enabled) &self.profiling else null);
}

/// Renders a layer using a WorldRenderer-monotonic frame serial. The concrete
/// LOD renderer projects visibility once for a serial and reuses safe value
/// snapshots for the terrain and water submissions.
pub fn renderFrame(self: *Self, frame_serial: u64, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, detail_render_radius: i32, layer: LODRenderLayer) void {
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();

    self.renderer.renderFrame(frame_serial, &self.meshes, &self.regions, self.config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, detail_render_radius, layer, &self.stats, if (self.profiling.enabled) &self.profiling else null);
}

pub fn prepareFrame(self: *Self, frame_serial: u64, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, max_distance_chunks: ?i32, detail_render_radius: i32) void {
    if (self.memory_governor.pressure_pending) {
        // Refresh after all update-side allocations. Only prepass preparation
        // may relocate pools, before GPU candidates or graphics draws exist.
        self.updateStats();
        const budget = @as(usize, self.config.getMemoryBudgetMB()) * 1024 * 1024;
        self.gpu_bridge.memoryPressure(if (budget == 0) std.math.maxInt(usize) else budget, self.memory_governor.logical_admission_bytes, self.memory_governor.maintenance_staging_bytes);
        self.memory_governor.pressure_pending = false;
    }
    const lock_wait_timer = self.profiling.begin();
    self.mutex.lockShared();
    self.profiling.end(.manager_lock_wait, lock_wait_timer);
    const lock_hold_timer = self.profiling.begin();
    defer self.profiling.end(.manager_lock_hold, lock_hold_timer);
    defer self.mutex.unlockShared();
    self.renderer.prepareFrame(frame_serial, &self.meshes, &self.regions, self.config, view_proj, camera_pos, chunk_checker, checker_ctx, max_distance_chunks, detail_render_radius, &self.stats, if (self.profiling.enabled) &self.profiling else null);
}

pub fn pointDistanceSquared(x0: i32, z0: i32, x1: i32, z1: i32) i64 {
    const dx = @as(i64, x0) - @as(i64, x1);
    const dz = @as(i64, z0) - @as(i64, z1);
    const distance_sq = @as(i128, dx) * dx + @as(i128, dz) * dz;
    return @intCast(@min(distance_sq, std.math.maxInt(i64)));
}

test "LODManager service admissions preserve the next class while pending is full" {
    const allocator = std.testing.allocator;
    var config = LODConfig{ .memory_budget_mb = 0 };
    var manager = try Self.initCacheTestManager(allocator, "");
    defer manager.cache_io.deinit();
    defer manager.ingestion_queue.deinit(allocator);
    defer manager.generation_tokens.deinit(allocator);
    manager.config = config.interface();
    manager.cleanup_covered_regions = false;
    var queue = JobQueue.init(allocator);
    defer queue.deinit();
    manager.job_dispatcher = .{ .queues = @splat(&queue) };
    manager.generation_tokens.enableServiceLanes(&lod_service.WHEEL);
    for (&manager.regions) |*regions| regions.* = RegionMap.init(allocator);
    defer {
        for (&manager.regions) |*regions| {
            var it = regions.valueIterator();
            while (it.next()) |chunk| {
                chunk.*.deinit(allocator);
                allocator.destroy(chunk.*);
            }
            regions.deinit();
        }
    }

    // Model one released global slot at a time. The first four opportunities
    // all have cold candidates, so a whole-pass horizon policy fails this test.
    manager.pending_region_count = manager_ctx.MAX_PENDING_LOD_REGIONS - 1;
    for (lod_service.WHEEL[0..4], 0..) |lane, index| {
        if (index != 0) manager.pending_region_count -= 1;
        queueServiceAdmissions(&manager, Vec3.zero, null, null);
        try std.testing.expectEqual(manager_ctx.MAX_PENDING_LOD_REGIONS, manager.pending_region_count);
        const token = manager.generation_tokens.pop().?;
        try std.testing.expectEqual(lane, token.service_lane);
        try std.testing.expectEqual(lane, manager.regions[@intFromEnum(token.key.lod)].get(token.key).?.service_lane);
        try std.testing.expectEqual(@as(u64, 1), manager.service_counters.snapshot().admitted[lane]);
        const cursor = manager.service_admission_wheel.cursor;
        manager.storePlayerChunkPos(1, 1);
        queueServiceAdmissions(&manager, Vec3.zero, null, null);
        try std.testing.expectEqual(cursor, manager.service_admission_wheel.cursor);
        try std.testing.expectEqual(@as(usize, 0), manager.generation_tokens.count());
        manager.storePlayerChunkPos(0, 0);
    }
}
