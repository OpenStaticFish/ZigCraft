//! World streamer - handles asynchronous chunk loading and unloading.
//!
//! This module manages the lifecycle of chunks around the player, coordinating
//! generation, meshing, and GPU upload through a multi-threaded job system.
//!
//! ## Chunk State Machine
//!
//! Chunks flow through the following states:
//! ```
//! missing -> generating -> generated -> meshing -> mesh_ready -> uploading -> renderable
//!    ^                                                                    |
//!    |                    (dirty flag triggers remesh)                    |
//!    +--------------------------------------------------------------------+
//! ```
//!
//! - **missing**: Chunk not yet loaded or queued
//! - **generating**: Terrain generation job in progress (worker thread)
//! - **generated**: Terrain data ready, awaiting mesh job
//! - **meshing**: Mesh building job in progress (worker thread)
//! - **mesh_ready**: Mesh data built, awaiting GPU upload
//! - **uploading**: Mesh being uploaded to GPU (main thread)
//! - **renderable**: Ready for drawing
//!
//! ## Dual Queue Architecture
//!
//! The streamer uses two independent job queues with dedicated worker pools:
//! - **gen_queue** (4 workers): Terrain generation via `processGenJob`
//! - **mesh_queue** (3 workers): Mesh building via `processMeshJob`
//!
//! This separation prevents meshing from blocking generation and allows
//! independent prioritization.
//!
//! ## Thread Safety
//!
//! - ChunkStorage is protected by `chunks_mutex` (shared/exclusive locking)
//! - Workers read/write chunk data under lock protection
//! - GPU uploads happen on the main thread via `processUploads()`
//! - Never call RHI or windowing from worker threads
//!
//! ## Predictive Loading
//!
//! PlayerMovement tracking enables priority weighting based on velocity:
//! - Chunks in movement direction get lower distance weight (higher priority)
//! - Chunks behind the player get higher distance weight (lower priority)
//! - This improves perceived loading speed during fast travel

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const world_meshing = @import("world-meshing");
const ChunkStorage = world_meshing.ChunkStorage;
const NeighborChunks = world_meshing.NeighborChunks;
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const WorkerPool = engine_core.WorkerPool;
const Generator = @import("world-worldgen").Generator;
const GlobalVertexAllocator = world_meshing.GlobalVertexAllocator;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;
const SaveManager = @import("world-persistence").SaveManager;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;
const GpuAccelerationCoordinator = @import("gpu_acceleration_coordinator.zig").GpuAccelerationCoordinator;
const ChunkQueueCoordinator = @import("chunk_queue_coordinator.zig").ChunkQueueCoordinator;
const MeshInputSnapshot = @import("chunk_queue_coordinator.zig").MeshInputSnapshot;
const build_options = @import("world_runtime_options");

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

pub const PlayerMovement = struct {
    dir_x: f32 = 0,
    dir_z: f32 = 0,
    speed: f32 = 0,
    last_pos: Vec3 = Vec3.init(0, 0, 0),
    has_velocity: bool = false,

    pub fn update(self: *PlayerMovement, pos: Vec3, dt: f32) bool {
        if (dt <= 0.001) return false;
        const dx = pos.x - self.last_pos.x;
        const dz = pos.z - self.last_pos.z;
        self.last_pos = pos;
        const distance = @sqrt(dx * dx + dz * dz);
        self.speed = distance / dt;
        if (self.speed < 2.0) {
            self.has_velocity = false;
            return false;
        }
        const old_x = self.dir_x;
        const old_z = self.dir_z;
        self.dir_x = dx / distance;
        self.dir_z = dz / distance;
        self.has_velocity = true;
        return old_x * self.dir_x + old_z * self.dir_z < 0.707;
    }

    pub fn priorityWeight(self: PlayerMovement, chunk_dx: i32, chunk_dz: i32) f32 {
        if (!self.has_velocity) return 1.0;
        const dx: f32 = @floatFromInt(chunk_dx);
        const dz: f32 = @floatFromInt(chunk_dz);
        const distance = @sqrt(dx * dx + dz * dz);
        if (distance < 0.001) return 0.5;
        return 1.0 - (dx * self.dir_x + dz * self.dir_z) / distance * 0.5;
    }
};

pub const QueueStats = struct {
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};

pub const WorldStreamer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    generator: Generator,
    atlas: *const TextureAtlas,

    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    gen_pool: *WorkerPool,
    mesh_pool: *WorkerPool,
    queue_coordinator: ChunkQueueCoordinator,
    render_distance: i32,
    active_render_distance: i32,
    startup_stream_radius: i32,
    player_movement: PlayerMovement = .{},
    last_pc: struct { x: i32, z: i32 } = .{ .x = 0, .z = 0 },
    startup_mesh_finalized: bool = false,
    gpu_acceleration: GpuAccelerationCoordinator,

    vertex_allocator: *GlobalVertexAllocator,

    paused: bool = false,
    save_manager: ?*SaveManager = null,

    frame_counter: u64 = 0,
    has_scanned_missing_chunks: bool = false,
    last_missing_scan_pc_x: i32 = 0,
    last_missing_scan_pc_z: i32 = 0,
    last_missing_scan_render_dist: i32 = 0,
    has_processed_unloads: bool = false,
    last_unload_pc_x: i32 = 0,
    last_unload_pc_z: i32 = 0,
    last_unload_render_dist: i32 = 0,
    last_diag_generated: u64 = 0,
    last_diag_meshed: u64 = 0,
    last_diag_uploaded: u64 = 0,

    const MIN_GEN_WORKERS = 2;
    const MAX_GEN_WORKERS = 10;
    const MIN_MESH_WORKERS = 2;
    const MAX_MESH_WORKERS = 8;
    const STARTUP_RADIUS_INITIAL = 3;
    const STARTUP_RADIUS_STEP = 2;
    const STARTUP_PREFETCH_RINGS = 2;
    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, render_distance: i32, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher: ?*GpuMesher, save_manager: ?*SaveManager) !*WorldStreamer {
        const streamer = try allocator.create(WorldStreamer);
        errdefer allocator.destroy(streamer);

        const cpu_count = std.Thread.getCpuCount() catch MIN_GEN_WORKERS + MIN_MESH_WORKERS;
        const total_budget = @max(@as(usize, 5), cpu_count -| 1);
        const foreground_budget = total_budget;
        // Generation is the dominant startup stage after coalescing boundary
        // remeshes, so allocate roughly two thirds of the foreground workers
        // to generation and the remainder to meshing.
        const gen_capacity = @max(MIN_GEN_WORKERS, foreground_budget -| MIN_MESH_WORKERS);
        const default_gen = @min(std.math.clamp((foreground_budget * 2 + 2) / 3, MIN_GEN_WORKERS, MAX_GEN_WORKERS), gen_capacity);
        const default_mesh = std.math.clamp(foreground_budget - default_gen, MIN_MESH_WORKERS, MAX_MESH_WORKERS);
        const gen_worker_count = engine_core.envInt("ZIGCRAFT_GEN_WORKERS", default_gen);
        const mesh_worker_count = engine_core.envInt("ZIGCRAFT_MESH_WORKERS", default_mesh);

        const gen_queue = try allocator.create(JobQueue);
        gen_queue.* = JobQueue.init(allocator);
        errdefer {
            gen_queue.deinit();
            allocator.destroy(gen_queue);
        }

        const mesh_queue = try allocator.create(JobQueue);
        mesh_queue.* = JobQueue.init(allocator);
        errdefer {
            mesh_queue.deinit();
            allocator.destroy(mesh_queue);
        }

        streamer.* = .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .gen_pool = undefined,
            .mesh_pool = undefined,
            .queue_coordinator = undefined,
            .render_distance = @max(render_distance, 2),
            .active_render_distance = @min(@max(render_distance, 2), STARTUP_RADIUS_INITIAL),
            .startup_stream_radius = @min(@max(render_distance, 2), STARTUP_RADIUS_INITIAL),
            .gpu_acceleration = GpuAccelerationCoordinator.init(gpu_block_buffer, gpu_mesher),
            .vertex_allocator = vertex_allocator,
            .last_diag_generated = 0,
            .last_diag_meshed = 0,
            .last_diag_uploaded = 0,
        };

        streamer.queue_coordinator = try ChunkQueueCoordinator.init(allocator, storage, generator, atlas, gen_queue, mesh_queue, vertex_allocator, max_uploads_per_frame, &streamer.gpu_acceleration);
        errdefer streamer.queue_coordinator.deinit();
        streamer.setSaveManager(save_manager);
        try streamer.warmupInitialChunks();

        log.log.info("WorldStreamer workers: gen={} mesh={} (cpu={})", .{ gen_worker_count, mesh_worker_count, cpu_count });

        streamer.gen_pool = try WorkerPool.init(allocator, gen_worker_count, gen_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processGenJob);
        errdefer {
            gen_queue.stop();
            streamer.gen_pool.deinit();
        }

        streamer.mesh_pool = try WorkerPool.init(allocator, mesh_worker_count, mesh_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processMeshJob);
        if (gpu_mesher) |mesher| mesher.setRemeshCallback(&streamer.queue_coordinator, enqueueGpuRemesh);

        return streamer;
    }

    pub fn deinit(self: *WorldStreamer) void {
        if (self.gpu_acceleration.gpu_mesher) |mesher| mesher.setRemeshCallback(null, null);
        self.gen_queue.stop();
        self.mesh_queue.stop();

        self.gen_pool.deinit();
        self.mesh_pool.deinit();

        self.gen_queue.deinit();
        self.mesh_queue.deinit();
        self.allocator.destroy(self.gen_queue);
        self.allocator.destroy(self.mesh_queue);

        self.queue_coordinator.deinit();
        self.allocator.destroy(self);
    }

    fn enqueueGpuRemesh(context: *anyopaque, cx: i32, cz: i32, job_token: u32) void {
        const coordinator: *ChunkQueueCoordinator = @ptrCast(@alignCast(context));
        coordinator.enqueuePendingMesh(cx, cz, job_token);
    }

    pub fn setPaused(self: *WorldStreamer, paused: bool) void {
        self.paused = paused;
        self.gen_queue.setPaused(paused);
        self.mesh_queue.setPaused(paused);

        if (paused) {
            self.queue_coordinator.resetPausedChunks();
        } else {
            self.has_scanned_missing_chunks = false;
            self.has_processed_unloads = false;
        }
    }

    pub fn setRenderDistance(self: *WorldStreamer, distance: i32) void {
        const previous_active = self.active_render_distance;
        self.render_distance = @max(distance, 2);
        self.startup_stream_radius = @min(self.render_distance, @max(previous_active, STARTUP_RADIUS_INITIAL));
        self.active_render_distance = self.startup_stream_radius;
        self.startup_mesh_finalized = false;
        self.has_scanned_missing_chunks = false;
    }

    pub fn getActiveRenderDistance(self: *const WorldStreamer) i32 {
        return self.active_render_distance;
    }

    pub fn isStartupBusy(self: *WorldStreamer, target_render_dist: i32) bool {
        if (self.active_render_distance < target_render_dist) return true;
        if (self.queue_coordinator.hasInFlightWork()) return true;
        if (!self.has_scanned_missing_chunks) return true;

        const pc_x = self.last_pc.x;
        const pc_z = self.last_pc.z;
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        // Startup finalization only remeshes the camera neighborhood. The
        // bounded missing-chunk scan plus empty queues above proves the wider
        // disk has drained without rescanning millions of coordinates here.
        const radius_i64: i64 = 1;
        var cz = @as(i64, pc_z) - radius_i64;
        while (cz <= @as(i64, pc_z) + radius_i64) : (cz += 1) {
            var cx = @as(i64, pc_x) - radius_i64;
            while (cx <= @as(i64, pc_x) + radius_i64) : (cx += 1) {
                const dx = cx - @as(i64, pc_x);
                const dz = cz - @as(i64, pc_z);
                if (dx * dx + dz * dz > radius_i64 * radius_i64) continue;
                if (cx < std.math.minInt(i32) or cx > std.math.maxInt(i32) or cz < std.math.minInt(i32) or cz > std.math.maxInt(i32)) continue;
                const data = self.storage.chunks.get(.{ .x = @intCast(cx), .z = @intCast(cz) }) orelse return true;
                if (data.chunk.state != .renderable or !data.render.mesh.ready) return true;
            }
        }
        return false;
    }

    fn warmupInitialChunks(self: *WorldStreamer) !void {
        // Keep only the center chunk on the synchronous startup path. The
        // normal prioritized worker pipeline fills the surrounding ring after
        // the first frame instead of serially generating and meshing nine
        // chunks before the world can appear.
        const warmup_radius: i32 = 0;

        var cz: i32 = -warmup_radius;
        while (cz <= warmup_radius) : (cz += 1) {
            var cx: i32 = -warmup_radius;
            while (cx <= warmup_radius) : (cx += 1) {
                const data = try self.storage.getOrCreate(cx, cz);
                if (data.chunk.generated) continue;

                data.chunk.state = .generating;
                const loaded = if (self.save_manager) |sm| sm.loadChunk(cx, cz, &data.chunk) else .not_found;
                switch (loaded) {
                    .not_found => {
                        try self.generator.generate(&data.chunk, null);
                        data.chunk.lighting_valid = true;
                    },
                    .success, .success_relight_required => {},
                    .read_error, .corrupt_data => return error.SaveLoadFailed,
                }
                if (!data.chunk.generated) {
                    data.chunk.state = .missing;
                    continue;
                }
                data.chunk.state = .generated;
                _ = data.chunk.rebuildMapSurface();
                self.storage.markMapSurfaceChanged();
                // Warmup runs before worker pools start. Reconciliation still
                // requires the completed chunk to be published as generated.
                if (loaded == .success_relight_required) {
                    var lighting = @import("lighting_engine.zig").WorldLightingEngine.init(self.storage, self.allocator);
                    if (!try lighting.reconcileLegacyArea(cx, cz)) return error.InitialLightingUnavailable;
                }
            }
        }

        cz = -warmup_radius;
        while (cz <= warmup_radius) : (cz += 1) {
            var cx: i32 = -warmup_radius;
            while (cx <= warmup_radius) : (cx += 1) {
                const data = self.storage.get(cx, cz) orelse continue;
                if (!data.chunk.generated) continue;

                const neighbors = NeighborChunks{
                    .north = if (self.storage.get(cx, cz - 1)) |n| &n.chunk else null,
                    .south = if (self.storage.get(cx, cz + 1)) |s| &s.chunk else null,
                    .east = if (self.storage.get(cx + 1, cz)) |e| &e.chunk else null,
                    .west = if (self.storage.get(cx - 1, cz)) |w| &w.chunk else null,
                };

                data.render.mesh.buildWithNeighbors(&data.chunk, neighbors, self.atlas) catch |err| {
                    log.log.warn("STARTUP_WARMUP_MESH_FAILED: ({},{}) {}", .{ cx, cz, err });
                    data.chunk.state = .generated;
                    continue;
                };

                data.chunk.state = .mesh_ready;
                data.render.mesh.upload(self.vertex_allocator);
                if (data.render.mesh.ready) {
                    data.chunk.state = .renderable;
                    data.chunk.dirty = false;
                    _ = self.queue_coordinator.chunks_uploaded_total.fetchAdd(1, .monotonic);
                } else {
                    data.chunk.state = .generated;
                }
            }
        }
    }

    pub fn setSaveManager(self: *WorldStreamer, sm: ?*SaveManager) void {
        self.save_manager = sm;
        self.queue_coordinator.setSaveManager(sm);
    }

    pub fn requestDirtyRemesh(self: *WorldStreamer, center_cx: i32, center_cz: i32) void {
        self.queue_coordinator.requestDirtyRemesh(center_cx, center_cz);
    }

    pub fn enqueueMutationLighting(self: *WorldStreamer, mutation: *WorldMutationCoordinator, result: WorldMutationCoordinator.MutationResult) !void {
        if (result.lighting_update == .none) {
            self.requestDirtyRemesh(result.chunk_x, result.chunk_z);
            return;
        }

        const context = try self.allocator.create(MutationLightingJob);
        errdefer self.allocator.destroy(context);
        context.* = .{
            .allocator = self.allocator,
            .mutation = mutation,
            .queue_coordinator = &self.queue_coordinator,
            .result = result,
        };
        const queued = try self.mesh_queue.tryPush(.{
            .type = .generic,
            .priority = -1,
            .data = .{ .generic = .{
                .context = context,
                .process_fn = processMutationLighting,
                .cleanup_fn = cleanupMutationLighting,
            } },
        });
        if (!queued) {
            self.allocator.destroy(context);
            try mutation.updateLighting(result);
            self.requestDirtyRemesh(result.chunk_x, result.chunk_z);
        }
    }

    pub fn updateFrame(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        if (self.save_manager) |sm| {
            if (sm.load_failed.load(.acquire)) return error.SaveLoadFailed;
        }
        if (self.paused) return;

        self.frame_counter += 1;

        self.updateStreaming(player_pos, dt) catch |err| {
            log.log.warn("updateStreaming error (non-fatal): {}", .{err});
        };
        self.queue_coordinator.processUploads();
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const unload_render_dist = self.render_distance;
        const needs_unload_scan = !self.has_processed_unloads or
            self.last_unload_pc_x != pc.chunk_x or
            self.last_unload_pc_z != pc.chunk_z or
            self.last_unload_render_dist != unload_render_dist or
            self.frame_counter % 60 == 0;
        if (needs_unload_scan) {
            var unload_succeeded = true;
            self.processUnloads(player_pos) catch |err| {
                log.log.warn("processUnloads error (non-fatal): {}", .{err});
                unload_succeeded = false;
            };
            if (unload_succeeded) {
                self.has_processed_unloads = true;
                self.last_unload_pc_x = pc.chunk_x;
                self.last_unload_pc_z = pc.chunk_z;
                self.last_unload_render_dist = unload_render_dist;
            }
        }
        if (self.frame_counter % 300 == 0) {
            self.logChunkStateSummary();
        }
    }

    fn logChunkStateSummary(self: *WorldStreamer) void {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var counts = [_]u32{0} ** 10;
        var renderable_no_alloc: u32 = 0;
        var renderable_not_ready: u32 = 0;
        var total: u32 = 0;

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const data = entry.value_ptr.*;
            total += 1;
            switch (data.chunk.state) {
                .missing => counts[0] += 1,
                .queued_for_generation => counts[1] += 1,
                .generating => counts[2] += 1,
                .generated => counts[3] += 1,
                .queued_for_mesh => counts[4] += 1,
                .meshing => counts[5] += 1,
                .mesh_ready => counts[6] += 1,
                .uploading => counts[7] += 1,
                .renderable => {
                    counts[8] += 1;
                    if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null) {
                        renderable_no_alloc += 1;
                    }
                    if (!data.render.mesh.ready) {
                        renderable_not_ready += 1;
                    }
                },
                .unloading => counts[9] += 1,
            }
        }

        if (build_options.startup_diagnostic_seconds == 0) {
            log.log.info("CHUNK_STATES [frame={}]: total={} | missing={} qgen={} gen={} gentd={} qmesh={} meshing={} mready={} uploading={} renderable={} unloading={} | no_alloc={} not_ready={}", .{
                self.frame_counter,  total,
                counts[0],           counts[1],
                counts[2],           counts[3],
                counts[4],           counts[5],
                counts[6],           counts[7],
                counts[8],           counts[9],
                renderable_no_alloc, renderable_not_ready,
            });

            if (renderable_no_alloc > 0) {
                log.log.warn("  {} chunks renderable with no allocations (max 3 recovery attempts)", .{renderable_no_alloc});
            }
        }
    }

    fn updateStreaming(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        self.gpu_acceleration.refreshForceCpuMeshing(self.frame_counter, self.storage);

        _ = self.player_movement.update(player_pos, dt);
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const moved = pc.chunk_x != self.last_pc.x or pc.chunk_z != self.last_pc.z;
        self.last_pc = .{ .x = pc.chunk_x, .z = pc.chunk_z };
        if (moved) {
            self.gen_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
            self.mesh_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
        }
        if (self.startup_stream_radius < self.render_distance and self.frame_counter % 10 == 0 and !self.queue_coordinator.hasInFlightWork()) {
            self.startup_stream_radius = @min(self.render_distance, self.startup_stream_radius + STARTUP_RADIUS_STEP);
        }
        self.active_render_distance = self.startup_stream_radius;
        const stream_dist = @min(self.render_distance, self.active_render_distance + STARTUP_RADIUS_STEP * STARTUP_PREFETCH_RINGS);
        const frame = .{ .pc_x = pc.chunk_x, .pc_z = pc.chunk_z, .stream_dist = stream_dist, .movement = self.player_movement };
        self.queue_coordinator.setView(frame.pc_x, frame.pc_z, frame.stream_dist);

        if (self.frame_counter % 600 == 0) {
            self.logMissingChunkDiagnostic(frame.pc_x, frame.pc_z);
        }

        // The required chunk set changes only after crossing a chunk boundary or
        // changing view distance. A periodic scan remains as a safety net for a
        // failed queue insertion without taking the storage writer lock every frame.
        const missing_rescan_requested = self.queue_coordinator.takeMissingRescanRequest();
        if (missing_rescan_requested) self.queue_coordinator.restartMissingScan();
        const needs_missing_scan = missing_rescan_requested or
            !self.has_scanned_missing_chunks or
            self.last_missing_scan_pc_x != frame.pc_x or
            self.last_missing_scan_pc_z != frame.pc_z or
            self.last_missing_scan_render_dist != frame.stream_dist or
            self.frame_counter % 60 == 0;
        if (needs_missing_scan) {
            self.has_scanned_missing_chunks = self.queue_coordinator.scanForMissingChunks(frame.pc_x, frame.pc_z, frame.stream_dist, frame.movement) catch |err| result: {
                log.log.warn("scanForMissingChunks error (non-fatal): {}", .{err});
                break :result false;
            };
            self.last_missing_scan_pc_x = frame.pc_x;
            self.last_missing_scan_pc_z = frame.pc_z;
            self.last_missing_scan_render_dist = frame.stream_dist;
        }
        self.queue_coordinator.processChunkStates(frame.pc_x, frame.pc_z, frame.stream_dist, self.frame_counter);
        if (!self.startup_mesh_finalized and !self.isStartupBusy(self.render_distance)) {
            self.finalizeStartupArea(frame.pc_x, frame.pc_z, 1);
            self.startup_mesh_finalized = true;
        }
    }

    fn finalizeStartupArea(self: *WorldStreamer, pc_x: i32, pc_z: i32, radius: i32) void {
        var cz = pc_z - radius;
        while (cz <= pc_z + radius) : (cz += 1) {
            var cx = pc_x - radius;
            while (cx <= pc_x + radius) : (cx += 1) {
                self.finalizeChunkMesh(cx, cz);
            }
        }
    }

    fn finalizeChunkMesh(self: *WorldStreamer, cx: i32, cz: i32) void {
        const claimed = claim: {
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();

            const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse return;
            if (!data.chunk.generated or (data.chunk.state != .generated and data.chunk.state != .renderable)) return;
            const neighbors = MeshInputSnapshot.residentNeighbors(self.storage, cx, cz);
            const snapshot = MeshInputSnapshot.capture(self.allocator, &data.chunk, neighbors) catch |err| {
                log.log.warn("STARTUP_FINALIZE_SNAPSHOT_FAILED: ({},{}) {}", .{ cx, cz, err });
                return;
            };
            data.chunk.state = .meshing;
            data.chunk.pin();
            inline for (.{ "north", "south", "east", "west" }) |name| {
                if (@field(neighbors, name)) |neighbor| @constCast(neighbor).pin();
            }
            break :claim .{ .data = data, .snapshot = snapshot, .neighbors = neighbors, .job_token = data.chunk.job_token };
        };
        defer {
            claimed.snapshot.deinit(self.allocator);
            claimed.data.chunk.unpin();
            inline for (.{ "north", "south", "east", "west" }) |name| {
                if (@field(claimed.neighbors, name)) |neighbor| @constCast(neighbor).unpin();
            }
        }

        var built_mesh = world_meshing.ChunkMesh.init(self.allocator);
        defer built_mesh.deinitWithoutRHI();
        var build_succeeded = true;
        built_mesh.buildWithNeighbors(&claimed.snapshot.chunks[0], claimed.snapshot.neighbors, self.atlas) catch |err| {
            log.log.warn("STARTUP_FINALIZE_MESH_FAILED: ({},{}) {}", .{ cx, cz, err });
            build_succeeded = false;
        };

        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();
        const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse return;
        // A reset or new job owns its state and pending output. Never overwrite
        // it, or publish vertices built before an edit or neighbor arrival.
        if (data != claimed.data or data.chunk.state != .meshing or data.chunk.job_token != claimed.job_token) return;
        const neighbors = MeshInputSnapshot.residentNeighbors(self.storage, cx, cz);
        if (!build_succeeded or !claimed.snapshot.matches(&data.chunk, neighbors)) {
            data.chunk.state = .generated;
            data.chunk.dirty = true;
            self.queue_coordinator.enqueuePendingMesh(cx, cz, claimed.job_token);
            return;
        }
        data.render.mesh.takePendingFrom(&built_mesh);
        data.render.mesh.upload(self.vertex_allocator);
        // ready may describe old GPU allocations after a failed upload. Pending
        // vertices must be consumed before this revision can be called clean.
        const upload_complete = data.render.mesh.ready and data.render.mesh.pending_solid == null and
            data.render.mesh.pending_cutout == null and data.render.mesh.pending_fluid == null;
        data.chunk.state = if (upload_complete) .renderable else .generated;
        data.chunk.dirty = !upload_complete;
        if (upload_complete) {
            data.chunk.mesh_attempts = 0;
        } else {
            self.queue_coordinator.enqueuePendingMesh(cx, cz, claimed.job_token);
        }
    }

    fn processUnloads(self: *WorldStreamer, player_pos: Vec3) !void {
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const render_dist_unload = self.render_distance;
        const unload_distance = @as(i128, render_dist_unload) + CHUNK_UNLOAD_BUFFER;
        const unload_dist_sq = unload_distance * unload_distance;

        var to_remove = std.ArrayListUnmanaged(ChunkKey).empty;
        defer to_remove.deinit(self.allocator);

        {
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();

            var unload_iter = self.storage.iteratorUnsafe();
            while (unload_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const data = entry.value_ptr.*;
                const dx = @as(i128, key.x) - @as(i128, pc.chunk_x);
                const dz = @as(i128, key.z) - @as(i128, pc.chunk_z);
                if (dx * dx + dz * dz > unload_dist_sq) {
                    if (data.chunk.state != .generating and data.chunk.state != .meshing and
                        data.chunk.state != .uploading and
                        !data.chunk.isPinned())
                    {
                        try to_remove.append(self.allocator, key);
                    }
                }
            }
        }

        for (to_remove.items) |key| {
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            const unload_candidate = blk: {
                self.storage.chunks_mutex.lock();
                defer self.storage.chunks_mutex.unlock();

                const data = self.storage.chunks.get(key) orelse continue;
                if (data.chunk.state == .generating or data.chunk.state == .meshing or
                    data.chunk.state == .uploading or data.chunk.isPinned())
                {
                    continue;
                }
                data.chunk.pin();
                errdefer data.chunk.unpin();
                if (data.chunk.modified and data.chunk.generated) {
                    if (self.save_manager) |sm| {
                        // Keep the dirty resident chunk if snapshot acceptance
                        // fails. No GPU/storage release may precede acceptance.
                        try sm.enqueueSave(&data.chunk);
                        data.chunk.modified = false;
                    }
                }
                data.chunk.state = .unloading;
                break :blk .{ .chunk = &data.chunk };
            };
            const chunk = unload_candidate.chunk;

            self.gpu_acceleration.freeChunk(key.x, key.z);

            self.storage.chunks_mutex.lock();
            if (self.storage.chunks.get(key)) |data| {
                if (&data.chunk == chunk and data.chunk.state == .unloading) {
                    data.chunk.unpin();
                    _ = self.storage.removeUnlocked(key.x, key.z, self.vertex_allocator);
                } else {
                    chunk.unpin();
                }
            } else {
                chunk.unpin();
            }
            self.storage.chunks_mutex.unlock();
        }
    }

    fn logMissingChunkDiagnostic(self: *WorldStreamer, pc_x: i32, pc_z: i32) void {
        const target_render_dist = self.render_distance;
        const render_dist = self.render_distance;

        var counts = [_]u32{0} ** 10;
        var missing_keys = std.ArrayListUnmanaged(ChunkKey).empty;
        defer missing_keys.deinit(self.allocator);

        self.storage.chunks_mutex.lockShared();
        const radius = @as(i64, render_dist);
        const diagnostic_grid_radius: i64 = 8;
        var sample_z = -diagnostic_grid_radius;
        while (sample_z <= diagnostic_grid_radius) : (sample_z += 1) {
            var sample_x = -diagnostic_grid_radius;
            while (sample_x <= diagnostic_grid_radius) : (sample_x += 1) {
                if (sample_x * sample_x + sample_z * sample_z > diagnostic_grid_radius * diagnostic_grid_radius) continue;
                const cx = @as(i64, pc_x) + @divTrunc(sample_x * radius, diagnostic_grid_radius);
                const cz = @as(i64, pc_z) + @divTrunc(sample_z * radius, diagnostic_grid_radius);
                if (cx < std.math.minInt(i32) or cx > std.math.maxInt(i32) or cz < std.math.minInt(i32) or cz > std.math.maxInt(i32)) continue;
                const chunk_x: i32 = @intCast(cx);
                const chunk_z: i32 = @intCast(cz);

                if (self.storage.chunks.get(.{ .x = chunk_x, .z = chunk_z })) |data| {
                    switch (data.chunk.state) {
                        .missing => counts[0] += 1,
                        .queued_for_generation => counts[1] += 1,
                        .generating => counts[2] += 1,
                        .generated => counts[3] += 1,
                        .queued_for_mesh => counts[4] += 1,
                        .meshing => counts[5] += 1,
                        .mesh_ready => counts[6] += 1,
                        .uploading => counts[7] += 1,
                        .renderable => counts[8] += 1,
                        .unloading => counts[9] += 1,
                    }
                } else {
                    counts[0] += 1;
                    missing_keys.append(self.allocator, .{ .x = chunk_x, .z = chunk_z }) catch {};
                }
            }
        }
        self.storage.chunks_mutex.unlockShared();

        const generated_total = self.queue_coordinator.chunks_generated_total.load(.monotonic);
        const meshed_total = self.queue_coordinator.chunks_meshed_total.load(.monotonic);
        const uploaded_total = self.queue_coordinator.chunks_uploaded_total.load(.monotonic);
        const generated_delta = generated_total - self.last_diag_generated;
        const meshed_delta = meshed_total - self.last_diag_meshed;
        const uploaded_delta = uploaded_total - self.last_diag_uploaded;
        self.last_diag_generated = generated_total;
        self.last_diag_meshed = meshed_total;
        self.last_diag_uploaded = uploaded_total;

        log.log.info("CHUNK_DIAG_SAMPLE [frame={}] pc=({},{}) rd={}/{} | missing={} qgen={} gen={} gentd={} qmesh={} mesh={} mready={} upload={} render={} unload={} | not_in_storage={} | throughput gen={}/{} mesh={}/{} upload={}/{}", .{
            self.frame_counter,     pc_x,            pc_z,            render_dist,  target_render_dist,
            counts[0],              counts[1],       counts[2],       counts[3],    counts[4],
            counts[5],              counts[6],       counts[7],       counts[8],    counts[9],
            missing_keys.items.len, generated_delta, generated_total, meshed_delta, meshed_total,
            uploaded_delta,         uploaded_total,
        });

        if (missing_keys.items.len > 0 and missing_keys.items.len <= 20) {
            var buf: [512]u8 = undefined;
            var len: usize = 0;
            const prefix = "  NOT_IN_STORAGE: ";
            @memcpy(buf[0..prefix.len], prefix);
            len = prefix.len;
            for (missing_keys.items) |k| {
                const txt = std.fmt.bufPrint(buf[len..], "({},{}) ", .{ k.x, k.z }) catch break;
                len += txt.len;
            }
            log.log.info("{s}", .{buf[0..len]});
        }

        const pipeline_busy = counts[1] > 0 or counts[2] > 0 or counts[4] > 0 or counts[5] > 0;
        if (!pipeline_busy and (counts[3] > 0 or counts[6] > 0 or counts[7] > 0)) {
            log.log.warn("  stalled chunks: generated={} mesh_ready={} uploading={} (should be 0 at steady state)", .{
                counts[3], counts[6], counts[7],
            });
        }
    }

    pub fn getStats(self: *WorldStreamer) QueueStats {
        self.gen_queue.mutex.lock();
        const gen_count = self.gen_queue.jobs.count();
        self.gen_queue.mutex.unlock();

        self.mesh_queue.mutex.lock();
        const mesh_count = self.mesh_queue.jobs.count();
        self.mesh_queue.mutex.unlock();

        return .{
            .gen_queue = gen_count,
            .mesh_queue = mesh_count,
            .upload_queue = self.queue_coordinator.upload_queue.count(),
        };
    }
};

const MutationLightingJob = struct {
    allocator: std.mem.Allocator,
    mutation: *WorldMutationCoordinator,
    queue_coordinator: *ChunkQueueCoordinator,
    result: WorldMutationCoordinator.MutationResult,
};

fn processMutationLighting(raw_context: *anyopaque) void {
    const context: *MutationLightingJob = @ptrCast(@alignCast(raw_context));
    context.mutation.updateLighting(context.result) catch |err| {
        log.log.warn("BLOCK_LIGHTING_ERROR: ({},{}) update failed: {}", .{ context.result.chunk_x, context.result.chunk_z, err });
    };
    context.queue_coordinator.requestDirtyRemesh(context.result.chunk_x, context.result.chunk_z);
    const allocator = context.allocator;
    allocator.destroy(context);
}

fn cleanupMutationLighting(raw_context: *anyopaque) void {
    const context: *MutationLightingJob = @ptrCast(@alignCast(raw_context));
    const allocator = context.allocator;
    allocator.destroy(context);
}

test "startup mesh finalization allocation failures preserve output and release pins" {
    const testing = std.testing;
    // Snapshot, mask, and the three scratch vertex buffers. Every injected
    // failure returns before atlas or GPU access, through the real finalizer.
    for (0..5) |fail_index| {
        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();
        const target = try storage.getOrCreate(0, 0);
        const east = try storage.getOrCreate(1, 0);
        target.chunk.generated = true;
        target.chunk.state = .renderable;
        target.chunk.dirty = false;
        east.chunk.generated = true;
        east.chunk.state = .generated;
        const old_pending = try testing.allocator.alloc(@import("engine-rhi").Vertex, 1);
        target.render.mesh.pending_solid = old_pending;

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var gpu = GpuAccelerationCoordinator.init(null, null);
        // Only storage, allocator and pending-mesh bookkeeping are used on these
        // failure paths. No worker pools or graphics objects are initialized.
        var streamer: WorldStreamer = undefined;
        streamer.allocator = failing.allocator();
        streamer.storage = &storage;
        streamer.atlas = undefined;
        streamer.queue_coordinator = try ChunkQueueCoordinator.init(testing.allocator, &storage, undefined, undefined, undefined, undefined, undefined, 0, &gpu);
        defer streamer.queue_coordinator.deinit();

        streamer.finalizeChunkMesh(0, 0);
        try testing.expectEqual(if (fail_index == 0) Chunk.State.renderable else Chunk.State.generated, target.chunk.state);
        try testing.expectEqual(fail_index != 0, target.chunk.dirty);
        try testing.expectEqual(old_pending.ptr, target.render.mesh.pending_solid.?.ptr);
        try testing.expect(!target.chunk.isPinned());
        try testing.expect(!east.chunk.isPinned());
        try testing.expectEqual(@as(usize, if (fail_index == 0) 0 else 1), streamer.queue_coordinator.pending_mesh_incoming.items.len);
        try testing.expect(storage.lighting_mutex.tryLock());
        storage.lighting_mutex.unlock();
        try testing.expect(storage.chunks_mutex.tryLock());
        storage.chunks_mutex.unlock();
    }
}
