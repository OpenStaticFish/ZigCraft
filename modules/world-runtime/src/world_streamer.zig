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
const LODManager = @import("world-lod").LODManager;
const ChunkResolver = @import("world-lod").ChunkResolver;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;
const SaveManager = @import("world-persistence").SaveManager;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;
const GpuAccelerationCoordinator = @import("gpu_acceleration_coordinator.zig").GpuAccelerationCoordinator;
const ChunkQueueCoordinator = @import("chunk_queue_coordinator.zig").ChunkQueueCoordinator;
const LODStreamingCoordinator = @import("world-lod").LODStreamingCoordinator;
const QueueStats = @import("world-lod").lod_streaming_coordinator.QueueStats;
const build_options = @import("world_runtime_options");

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

pub const PlayerMovement = @import("world-lod").lod_streaming_coordinator.PlayerMovement;

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
    lod_coordinator: LODStreamingCoordinator,
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
    const MIN_LOD_WORKERS = 1;
    const MAX_LOD_WORKERS = 8;

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, render_distance: i32, lod_enabled: bool, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher: ?*GpuMesher) !*WorldStreamer {
        const streamer = try allocator.create(WorldStreamer);
        errdefer allocator.destroy(streamer);

        // Reserve LOD capacity from the same CPU budget as full-detail work
        // while preserving the foreground pool caps. This leaves capacity for
        // the main thread and graphics driver.
        // This keeps horizon generation responsive without creating two pools
        // that each try to saturate every core.
        const cpu_count = std.Thread.getCpuCount() catch MIN_GEN_WORKERS + MIN_MESH_WORKERS;
        const total_budget = @max(@as(usize, 5), cpu_count -| 1);
        const requested_lod_workers = if (lod_enabled)
            std.math.clamp(cpu_count / 2, MIN_LOD_WORKERS, MAX_LOD_WORKERS)
        else
            0;
        const lod_worker_reserve = @min(requested_lod_workers, total_budget -| (MIN_GEN_WORKERS + MIN_MESH_WORKERS));
        const foreground_budget = total_budget - lod_worker_reserve;
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
            .lod_coordinator = LODStreamingCoordinator.init(render_distance),
            .gpu_acceleration = GpuAccelerationCoordinator.init(gpu_block_buffer, gpu_mesher),
            .vertex_allocator = vertex_allocator,
            .last_diag_generated = 0,
            .last_diag_meshed = 0,
            .last_diag_uploaded = 0,
        };

        streamer.queue_coordinator = try ChunkQueueCoordinator.init(allocator, storage, generator, atlas, gen_queue, mesh_queue, vertex_allocator, max_uploads_per_frame, &streamer.gpu_acceleration);
        errdefer streamer.queue_coordinator.deinit();

        log.log.info("WorldStreamer workers: gen={} mesh={} lod_reserve={} (cpu={})", .{ gen_worker_count, mesh_worker_count, lod_worker_reserve, cpu_count });

        streamer.gen_pool = try WorkerPool.init(allocator, gen_worker_count, gen_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processGenJob);
        errdefer streamer.gen_pool.deinit();

        streamer.mesh_pool = try WorkerPool.init(allocator, mesh_worker_count, mesh_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processMeshJob);
        errdefer streamer.mesh_pool.deinit();

        try streamer.warmupInitialChunks();
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
            self.lod_coordinator.forceRescan();
            self.has_processed_unloads = false;
        }
    }

    pub fn setRenderDistance(self: *WorldStreamer, distance: i32) void {
        _ = self.lod_coordinator.setRenderDistance(distance);
    }

    pub fn getActiveRenderDistance(self: *const WorldStreamer) i32 {
        return self.lod_coordinator.getActiveRenderDistance();
    }

    pub fn isStartupBusy(self: *WorldStreamer, target_render_dist: i32) bool {
        if (self.lod_coordinator.isStartupBusy(self.getStats(), target_render_dist)) return true;
        if (self.queue_coordinator.hasInFlightWork()) return true;
        if (!self.has_scanned_missing_chunks) return true;

        const pc_x = self.lod_coordinator.last_pc.x;
        const pc_z = self.lod_coordinator.last_pc.z;
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
                self.generator.generate(&data.chunk, null) catch |err| {
                    log.log.warn("STARTUP_WARMUP_GEN_FAILED: ({},{}) {}", .{ cx, cz, err });
                    data.chunk.state = .missing;
                    continue;
                };
                if (!data.chunk.generated) {
                    data.chunk.state = .missing;
                    continue;
                }
                data.chunk.state = .generated;
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

    pub fn setLODManager(self: *WorldStreamer, lod_manager: ?*LODManager) void {
        self.lod_coordinator.setLODManager(lod_manager);
        self.queue_coordinator.setLODManager(lod_manager);
        if (lod_manager) |mgr| {
            // Resolver lets deferred ingestions fetch resident chunks. The
            // returned pointer is consumed synchronously within the manager's
            // main-thread update, so it does not need pinning.
            mgr.setChunkResolver(.{
                .ptr = self.storage,
                .resolve_fn = resolveChunkFromStorage,
                .capture_near_fn = captureNearChunkFromStorage,
            });
            // Warmup predates SaveManager attachment and has not checked disk.
            // Do not promote its origin chunk to authoritative near source.
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
        if (self.paused) return;

        self.frame_counter += 1;

        self.updateStreaming(player_pos, dt) catch |err| {
            log.log.warn("updateStreaming error (non-fatal): {}", .{err});
        };
        self.queue_coordinator.processUploads();
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const unload_render_dist = self.lod_coordinator.targetRenderDistance();
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

            if (self.lod_coordinator.lod_manager) |lod_mgr| {
                const lod0_r = lod_mgr.config.getChunkRenderRadius();
                const pc_x = self.lod_coordinator.last_pc.x;
                const pc_z = self.lod_coordinator.last_pc.z;
                const check_dirs = [_][2]i32{ .{ lod0_r, 0 }, .{ -lod0_r, 0 }, .{ 0, lod0_r }, .{ 0, -lod0_r } };
                var renderable_at_boundary: u32 = 0;
                var missing_at_boundary: u32 = 0;
                for (check_dirs) |dir| {
                    const cx = pc_x + dir[0];
                    const cz = pc_z + dir[1];
                    if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                        if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null) {
                            renderable_at_boundary += 1;
                        } else {
                            if (missing_at_boundary == 0) {
                                log.log.warn("  BOUNDARY_CHUNK: ({},{}) state={} (expected renderable)", .{ cx, cz, data.chunk.state });
                            }
                            missing_at_boundary += 1;
                        }
                    } else {
                        if (missing_at_boundary == 0) {
                            log.log.warn("  BOUNDARY_CHUNK: ({},{}) NOT IN STORAGE", .{ cx, cz });
                        }
                        missing_at_boundary += 1;
                    }
                }
                if (missing_at_boundary > 0) {
                    log.log.warn("  BOUNDARY: {}/4 chunks at LOD0 boundary (r={}) are NOT renderable", .{ missing_at_boundary, lod0_r });
                }
            }
        }
    }

    fn updateStreaming(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        self.gpu_acceleration.refreshForceCpuMeshing(self.frame_counter, self.storage);

        const frame = self.lod_coordinator.beginFrame(self.storage, self.gen_queue, self.mesh_queue, player_pos, dt, self.frame_counter);
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
        self.lod_coordinator.updateLOD(player_pos, self.storage);

        if (!self.lod_coordinator.startup_mesh_finalized and !self.isStartupBusy(self.lod_coordinator.render_distance)) {
            self.finalizeStartupArea(frame.pc_x, frame.pc_z, 1);
            self.lod_coordinator.startup_mesh_finalized = true;
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
        self.storage.chunks_mutex.lock();
        const chunk_data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlock();
            return;
        };

        // Claim mesh ownership through the same state machine used by workers.
        // Pins prevent eviction, but do not prevent a queued worker from
        // mutating the mesh concurrently.
        const previous_state = chunk_data.chunk.state;
        if (previous_state != .generated and previous_state != .renderable) {
            self.storage.chunks_mutex.unlock();
            return;
        }
        chunk_data.chunk.state = .meshing;

        chunk_data.chunk.pin();
        const neighbors = NeighborChunks{
            .north = if (self.storage.chunks.get(.{ .x = cx, .z = cz - 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .south = if (self.storage.chunks.get(.{ .x = cx, .z = cz + 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .east = if (self.storage.chunks.get(.{ .x = cx + 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .west = if (self.storage.chunks.get(.{ .x = cx - 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
        };
        self.storage.chunks_mutex.unlock();

        defer {
            chunk_data.chunk.unpin();
            if (neighbors.north) |n| @constCast(n).unpin();
            if (neighbors.south) |s| @constCast(s).unpin();
            if (neighbors.east) |e| @constCast(e).unpin();
            if (neighbors.west) |w| @constCast(w).unpin();
        }

        chunk_data.render.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
            log.log.warn("STARTUP_FINALIZE_MESH_FAILED: ({},{}) {}", .{ cx, cz, err });
            self.storage.chunks_mutex.lock();
            if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                if (data.chunk.state == .meshing) data.chunk.state = previous_state;
            }
            self.storage.chunks_mutex.unlock();
            return;
        };
        chunk_data.render.mesh.upload(self.vertex_allocator);

        self.storage.chunks_mutex.lock();
        if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
            if (data.chunk.state == .meshing) {
                data.chunk.state = if (data.render.mesh.ready) .renderable else previous_state;
                if (data.render.mesh.ready) {
                    data.chunk.dirty = false;
                    data.chunk.mesh_attempts = 0;
                }
            }
        }
        self.storage.chunks_mutex.unlock();
    }

    fn processUnloads(self: *WorldStreamer, player_pos: Vec3) !void {
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const render_dist_unload = self.lod_coordinator.targetRenderDistance();
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
            const unload_candidate = blk: {
                self.storage.chunks_mutex.lock();
                defer self.storage.chunks_mutex.unlock();

                const data = self.storage.chunks.get(key) orelse continue;
                if (data.chunk.state == .generating or data.chunk.state == .meshing or
                    data.chunk.state == .uploading or data.chunk.isPinned())
                {
                    continue;
                }
                const previous_state = data.chunk.state;
                data.chunk.pin();
                data.chunk.state = .unloading;
                break :blk .{ .chunk = &data.chunk, .previous_state = previous_state };
            };
            const chunk = unload_candidate.chunk;

            // Do not acquire the LOD manager while holding chunks_mutex: LOD
            // visibility takes the locks in the opposite order. The pin keeps
            // this authoritative snapshot alive through edit ingestion/save.
            var defer_unload = false;
            if (chunk.generated) {
                if (self.lod_coordinator.lod_manager) |manager| {
                    const retain_pending = manager.isInRange(key.x, key.z);
                    const pending_mask = manager.flushEditedChunkForUnload(key.x, key.z, chunk, retain_pending);
                    defer_unload = retain_pending and pending_mask != 0;
                }
            }

            // Keep an edited full-detail source resident while visible LOD
            // levels are still in flight. Once the player leaves the LOD
            // horizon, the persisted chunk becomes the durable repair source.
            if (defer_unload) {
                self.storage.chunks_mutex.lock();
                if (self.storage.chunks.get(key)) |data| {
                    if (&data.chunk == chunk and data.chunk.state == .unloading) {
                        data.chunk.state = unload_candidate.previous_state;
                    }
                }
                chunk.unpin();
                self.storage.chunks_mutex.unlock();
                continue;
            }

            const save_enqueued = chunk.modified and chunk.generated and self.save_manager != null;
            if (save_enqueued) self.save_manager.?.enqueueSave(chunk);

            self.gpu_acceleration.freeChunk(key.x, key.z);

            self.storage.chunks_mutex.lock();
            if (self.storage.chunks.get(key)) |data| {
                if (&data.chunk == chunk and data.chunk.state == .unloading) {
                    if (save_enqueued) data.chunk.modified = false;
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
        const target_render_dist = self.lod_coordinator.targetRenderDistance();
        const render_dist = @min(self.getActiveRenderDistance(), target_render_dist);

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

/// ChunkResolver callback: look up a resident, generated chunk by coordinate.
/// The returned pointer is only valid for synchronous use on the main thread
/// (it is not pinned); the LOD manager consumes it immediately within update().
fn resolveChunkFromStorage(ptr: *anyopaque, cx: i32, cz: i32) ?*const world_core.Chunk {
    const storage: *ChunkStorage = @ptrCast(@alignCast(ptr));
    storage.chunks_mutex.lockShared();
    defer storage.chunks_mutex.unlockShared();
    const entry = storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse return null;
    switch (entry.chunk.state) {
        .missing, .queued_for_generation, .generating => return null,
        else => {},
    }
    if (!entry.chunk.generated) return null;
    return &entry.chunk;
}

/// Value-only callback for near replay. Follow mutation's lighting -> storage
/// order; the shared storage lock supplies lifetime, lighting_mutex excludes
/// block edits. Neither lock is held when the manager receives the summary.
fn captureNearChunkFromStorage(ptr: *anyopaque, cx: i32, cz: i32) ?LODManager.NearChunkSummary {
    const storage: *ChunkStorage = @ptrCast(@alignCast(ptr));
    storage.lighting_mutex.lock();
    defer storage.lighting_mutex.unlock();
    storage.chunks_mutex.lockShared();
    defer storage.chunks_mutex.unlockShared();
    const entry = storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse return null;
    switch (entry.chunk.state) {
        .missing, .queued_for_generation, .generating => return null,
        else => {},
    }
    if (!entry.chunk.generated) return null;
    return LODManager.NearChunkSummary.capture(&entry.chunk);
}

test "near source resolver rejects generating chunks and returns value ownership after unload" {
    const testing = std.testing;
    const summary = capture: {
        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();
        const data = try storage.getOrCreate(0, 0);
        data.chunk.generated = true;
        data.chunk.setBlock(0, 10, 0, .stone);
        for ([_]Chunk.State{ .missing, .queued_for_generation, .generating }) |state| {
            data.chunk.state = state;
            try testing.expect(captureNearChunkFromStorage(&storage, 0, 0) == null);
            try testing.expect(resolveChunkFromStorage(&storage, 0, 0) == null);
        }
        data.chunk.state = .unloading;
        const captured = captureNearChunkFromStorage(&storage, 0, 0).?;
        try testing.expect(!data.chunk.isPinned());
        break :capture captured;
    };
    var source = try world_core.LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod0);
    defer source.deinit();
    try testing.expectEqual(@as(u32, 256), summary.apply(&source, 0, 0, 0, 0, 32, .edited));
    try testing.expectEqual(@as(f32, 11), source.getHeight(0, 0));
}

test "near source manager attachment does not capture warmup before save lookup" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const origin = try storage.getOrCreate(0, 0);
    origin.chunk.generated = true;
    origin.chunk.state = .renderable;
    origin.chunk.setBlock(0, 10, 0, .stone);
    var config = @import("world-lod").lod_chunk.LODConfig{ .memory_budget_mb = 0 };
    var manager = try LODManager.initCacheTestManager(testing.allocator, "");
    defer manager.cache_io.deinit();
    defer manager.ingestion_queue.deinit(testing.allocator);
    defer manager.near_sources.deinit(testing.allocator);
    defer manager.near_source_retries.deinit(testing.allocator);
    manager.config = config.interface();
    manager.near_source_enabled = true;
    manager.near_source_limit = 0;
    var streamer: WorldStreamer = undefined;
    streamer.storage = &storage;
    streamer.lod_coordinator = .init(16);
    streamer.setLODManager(&manager);
    try testing.expectEqual(@as(u64, 1), manager.near_source_sequence.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), manager.near_sources.count());
    try testing.expectEqual(@as(usize, 0), manager.near_source_retries.items.len);
    try testing.expect(manager.ingestion_queue.chunk_resolver != null);
}
