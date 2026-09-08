//! Chunk generation, meshing, and upload queue coordination.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const world_meshing = @import("world-meshing");
const ChunkStorage = world_meshing.ChunkStorage;
const NeighborChunks = world_meshing.NeighborChunks;
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const Job = engine_core.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const Generator = @import("world-worldgen").Generator;
const GlobalVertexAllocator = world_meshing.GlobalVertexAllocator;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;
const SaveManager = @import("world-persistence").SaveManager;
const LoadResult = @import("world-persistence").LoadResult;
const GpuAccelerationCoordinator = @import("gpu_acceleration_coordinator.zig").GpuAccelerationCoordinator;
const WorldLightingEngine = @import("lighting_engine.zig").WorldLightingEngine;

/// A pending chunk transition reference captured by a worker when it flips a
/// chunk into the `.generated` state. The main thread later drains the queue
/// and pushes the mesh job. Carries the job_token so stale entries (chunk was
/// reset to `.missing` in the meantime) can be discarded cheaply.
const PendingMeshRef = struct {
    x: i32,
    z: i32,
    job_token: u32,
};

const ChunkRevisions = struct {
    job_token: u32,
    content: u64,
    light: u64,

    /// Caller holds chunks_mutex, including the non-atomic incarnation token.
    fn capture(chunk: *const Chunk) ChunkRevisions {
        return .{
            .job_token = chunk.job_token,
            .content = chunk.content_revision.load(.acquire),
            .light = chunk.light_revision.load(.acquire),
        };
    }

    fn matches(self: ChunkRevisions, chunk: *const Chunk) bool {
        return self.job_token == chunk.job_token and self.content == chunk.content_revision.load(.acquire) and self.light == chunk.light_revision.load(.acquire);
    }
};

const MeshInputRevisions = struct {
    target: ChunkRevisions,
    north: ?ChunkRevisions,
    south: ?ChunkRevisions,
    east: ?ChunkRevisions,
    west: ?ChunkRevisions,

    fn capture(target: *const Chunk, neighbors: NeighborChunks) MeshInputRevisions {
        return .{
            .target = .capture(target),
            .north = if (neighbors.north) |chunk| .capture(chunk) else null,
            .south = if (neighbors.south) |chunk| .capture(chunk) else null,
            .east = if (neighbors.east) |chunk| .capture(chunk) else null,
            .west = if (neighbors.west) |chunk| .capture(chunk) else null,
        };
    }

    fn matches(self: MeshInputRevisions, target: *const Chunk, neighbors: NeighborChunks) bool {
        return self.target.matches(target) and
            matchesOptional(self.north, neighbors.north) and
            matchesOptional(self.south, neighbors.south) and
            matchesOptional(self.east, neighbors.east) and
            matchesOptional(self.west, neighbors.west);
    }

    fn matchesOptional(captured: ?ChunkRevisions, current: ?*const Chunk) bool {
        if (captured) |revisions| return if (current) |chunk| revisions.matches(chunk) else false;
        return current == null;
    }
};

/// Owns only meshing inputs, never a live ChunkData/render payload or its
/// synchronization state. The existing meshers consume Chunk views, so keep
/// their arrays in private Chunks rather than copying any vertex buffers.
pub const MeshInputSnapshot = struct {
    chunks: []Chunk,
    neighbors: NeighborChunks,
    revisions: MeshInputRevisions,

    /// Caller holds lighting_mutex -> chunks_mutex for the entire capture.
    /// Live references retained for later validation must be pinned separately.
    pub fn capture(allocator: std.mem.Allocator, target: *const Chunk, neighbors: NeighborChunks) !MeshInputSnapshot {
        var count: usize = 1;
        inline for (.{ "north", "south", "east", "west" }) |name| {
            if (@field(neighbors, name) != null) count += 1;
        }
        const copies = try allocator.alloc(Chunk, count);
        copyInputs(&copies[0], target);
        var result = MeshInputSnapshot{ .chunks = copies, .neighbors = .empty, .revisions = MeshInputRevisions.capture(target, neighbors) };
        var next: usize = 1;
        inline for (.{ "north", "south", "east", "west" }) |name| {
            if (@field(neighbors, name)) |neighbor| {
                copyInputs(&copies[next], neighbor);
                @field(result.neighbors, name) = &copies[next];
                next += 1;
            }
        }
        return result;
    }

    fn copyInputs(copy: *Chunk, source: *const Chunk) void {
        copy.* = Chunk.init(source.chunk_x, source.chunk_z);
        copy.blocks = source.blocks;
        copy.light = source.light;
        copy.biomes = source.biomes;
    }

    pub fn deinit(self: MeshInputSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
    }

    /// Caller holds lighting_mutex -> chunks_mutex and supplies current resident
    /// neighbors, not the old list (a previously absent neighbor may have arrived).
    pub fn matches(self: MeshInputSnapshot, target: *const Chunk, neighbors: NeighborChunks) bool {
        return self.revisions.matches(target, neighbors);
    }

    /// Caller holds chunks_mutex. Unpublished generation is never a mesh input.
    pub fn residentNeighbors(storage: *ChunkStorage, cx: i32, cz: i32) NeighborChunks {
        var neighbors = NeighborChunks.empty;
        inline for (.{ "north", "south", "east", "west" }, .{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } }) |name, offset| {
            neighbor: {
                const nx = std.math.add(i32, cx, offset[0]) catch break :neighbor;
                const nz = std.math.add(i32, cz, offset[1]) catch break :neighbor;
                if (storage.chunks.get(.{ .x = nx, .z = nz })) |data| {
                    if (data.chunk.generated and data.chunk.state != .generating and data.chunk.state != .unloading) {
                        @field(neighbors, name) = &data.chunk;
                    }
                }
            }
        }
        return neighbors;
    }
};

/// How often (in frames) the slow recovery scan runs. The dominant transitions
/// (.generated -> queued_for_mesh and .mesh_ready -> uploading) are handled
/// every frame by the pending queues; the scan only catches stuck chunks and
/// any state that was reset outside the worker path (e.g. resetPausedChunks).
const RECOVERY_SCAN_PERIOD: u64 = 60;
const MAX_MISSING_SCAN_STEPS: usize = 1024;

pub const ChunkQueueCoordinator = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    generator: Generator,
    atlas: *const TextureAtlas,
    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    upload_queue: RingBuffer(ChunkKey),
    vertex_allocator: *GlobalVertexAllocator,
    gpu: *GpuAccelerationCoordinator,
    max_uploads_per_frame: usize,
    save_manager: ?*SaveManager = null,

    chunks_generated_total: std.atomic.Value(u64) = .init(0),
    chunks_meshed_total: std.atomic.Value(u64) = .init(0),
    chunks_uploaded_total: std.atomic.Value(u64) = .init(0),
    generation_jobs_in_flight: std.atomic.Value(u32) = .init(0),
    mesh_jobs_in_flight: std.atomic.Value(u32) = .init(0),
    last_pc_x: std.atomic.Value(i32) = .init(0),
    last_pc_z: std.atomic.Value(i32) = .init(0),
    effective_render_dist: std.atomic.Value(i32) = .init(0),
    gpu_mesh_enabled: std.atomic.Value(bool) = .init(false),
    missing_scan_initialized: bool = false,
    missing_scan_player_x: i32 = 0,
    missing_scan_player_z: i32 = 0,
    missing_scan_radius: i32 = -1,
    missing_scan_ring: i64 = 0,
    missing_scan_ring_index: i64 = 0,
    missing_rescan_requested: std.atomic.Value(bool) = .init(false),

    // Pending transition queues. Workers append under the respective mutex
    // when they flip a chunk into `.generated` or `.mesh_ready`; the main
    // thread drains these each frame. This replaces the per-frame full-storage
    // scan that previously held chunks_mutex exclusive while iterating every
    // loaded chunk (often 1500+ at high render distance).
    pending_mesh_mutex: engine_core.sync.Mutex = .{},
    pending_mesh_incoming: std.ArrayListUnmanaged(PendingMeshRef) = .empty,
    pending_upload_mutex: engine_core.sync.Mutex = .{},
    pending_upload_incoming: std.ArrayListUnmanaged(ChunkKey) = .empty,

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, gen_queue: *JobQueue, mesh_queue: *JobQueue, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu: *GpuAccelerationCoordinator) !ChunkQueueCoordinator {
        return .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .upload_queue = try RingBuffer(ChunkKey).init(allocator, 256),
            .vertex_allocator = vertex_allocator,
            .gpu = gpu,
            .max_uploads_per_frame = max_uploads_per_frame,
            .gpu_mesh_enabled = .init(gpu.shouldUseGpuMeshReadyPath()),
        };
    }

    pub fn deinit(self: *ChunkQueueCoordinator) void {
        self.upload_queue.deinit();
        self.pending_mesh_incoming.deinit(self.allocator);
        self.pending_upload_incoming.deinit(self.allocator);
    }

    pub fn setSaveManager(self: *ChunkQueueCoordinator, sm: ?*SaveManager) void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();
        self.save_manager = sm;
    }

    pub fn setView(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32) void {
        self.last_pc_x.store(pc_x, .release);
        self.last_pc_z.store(pc_z, .release);
        self.effective_render_dist.store(render_dist, .release);
        // GPU configuration is main-thread-owned; workers read this mirror.
        self.gpu_mesh_enabled.store(self.gpu.shouldUseGpuMeshReadyPath(), .release);
    }

    pub fn takeMissingRescanRequest(self: *ChunkQueueCoordinator) bool {
        return self.missing_rescan_requested.swap(false, .acq_rel);
    }

    pub fn hasInFlightWork(self: *const ChunkQueueCoordinator) bool {
        return self.generation_jobs_in_flight.load(.acquire) > 0 or self.mesh_jobs_in_flight.load(.acquire) > 0;
    }

    pub fn restartMissingScan(self: *ChunkQueueCoordinator) void {
        self.missing_scan_initialized = false;
    }

    fn weightedDistanceSq(dist_sq: i32, movement: anytype, dx: i32, dz: i32) i32 {
        const weighted = @as(f32, @floatFromInt(dist_sq)) * movement.priorityWeight(dx, dz);
        return @max(0, @as(i32, @intFromFloat(@min(weighted, @as(f32, @floatFromInt(std.math.maxInt(i32)))))));
    }

    fn isWithinDistance(dx: i64, dz: i64, radius: i64) bool {
        const wide_dx: i128 = dx;
        const wide_dz: i128 = dz;
        const safe_radius: i128 = @max(radius, 0);
        return wide_dx * wide_dx + wide_dz * wide_dz <= safe_radius * safe_radius;
    }

    fn clampedDistanceSquared(dx: i64, dz: i64) i32 {
        const wide_dx: i128 = dx;
        const wide_dz: i128 = dz;
        const distance_sq = wide_dx * wide_dx + wide_dz * wide_dz;
        return @intCast(@min(distance_sq, std.math.maxInt(i32)));
    }

    fn resetMissingScan(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, radius: i32) void {
        self.missing_scan_initialized = true;
        self.missing_scan_player_x = pc_x;
        self.missing_scan_player_z = pc_z;
        self.missing_scan_radius = radius;
        self.missing_scan_ring = 0;
        self.missing_scan_ring_index = 0;
    }

    fn nextMissingScanCoordinate(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, radius: i64) ?[2]i64 {
        if (self.missing_scan_ring > radius) return null;
        if (self.missing_scan_ring == 0) {
            self.missing_scan_ring = 1;
            self.missing_scan_ring_index = 0;
            return .{ pc_x, pc_z };
        }

        const ring = self.missing_scan_ring;
        const side_length = ring * 2;
        const perimeter_length = side_length * 4;
        const index = self.missing_scan_ring_index;
        const side = @divFloor(index, side_length);
        const offset = @mod(index, side_length);
        const relative = switch (side) {
            0 => [2]i64{ -ring + offset, -ring },
            1 => [2]i64{ ring, -ring + offset },
            2 => [2]i64{ ring - offset, ring },
            else => [2]i64{ -ring, ring - offset },
        };

        self.missing_scan_ring_index += 1;
        if (self.missing_scan_ring_index >= perimeter_length) {
            self.missing_scan_ring += 1;
            self.missing_scan_ring_index = 0;
        }
        return .{ @as(i64, pc_x) + relative[0], @as(i64, pc_z) + relative[1] };
    }

    pub fn resetPausedChunks(self: *ChunkQueueCoordinator) void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.state == .queued_for_generation or chunk.state == .generating) {
                chunk.job_token +%= 1;
                chunk.state = .missing;
            } else if (chunk.state == .queued_for_mesh or chunk.state == .meshing or chunk.state == .uploading) {
                chunk.job_token +%= 1;
                chunk.state = .generated;
            }
        }
    }

    /// Scans a bounded portion of the full-detail disk. Returns true after one
    /// complete pass; false asks the streamer to continue on the next frame.
    pub fn scanForMissingChunks(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32, movement: anytype) !bool {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        const safe_radius = @max(render_dist, 0);
        const radius = @as(i64, safe_radius);
        if (!self.missing_scan_initialized) {
            self.resetMissingScan(pc_x, pc_z, safe_radius);
        } else {
            const previous_radius = self.missing_scan_radius;
            const previous_pass_complete = self.missing_scan_ring > previous_radius;
            if (safe_radius < previous_radius) {
                self.resetMissingScan(pc_x, pc_z, safe_radius);
            } else {
                self.missing_scan_radius = safe_radius;
                if (pc_x != self.missing_scan_player_x or pc_z != self.missing_scan_player_z) {
                    const moved_x = @abs(@as(i64, pc_x) - @as(i64, self.missing_scan_player_x));
                    const moved_z = @abs(@as(i64, pc_z) - @as(i64, self.missing_scan_player_z));
                    self.missing_scan_player_x = pc_x;
                    self.missing_scan_player_z = pc_z;
                    if (previous_pass_complete or @max(moved_x, moved_z) > 8) {
                        self.missing_scan_ring = 0;
                        self.missing_scan_ring_index = 0;
                    }
                } else if (safe_radius == previous_radius and previous_pass_complete) {
                    // Same-radius calls after a completed pass are periodic
                    // recovery scans; start a fresh bounded traversal.
                    self.missing_scan_ring = 0;
                    self.missing_scan_ring_index = 0;
                }
            }
        }

        var examined: usize = 0;
        while (examined < MAX_MISSING_SCAN_STEPS) : (examined += 1) {
            const coordinate = self.nextMissingScanCoordinate(pc_x, pc_z, radius) orelse {
                return true;
            };
            const cx = coordinate[0];
            const cz = coordinate[1];
            const dx = cx - @as(i64, pc_x);
            const dz = cz - @as(i64, pc_z);
            if (!isWithinDistance(dx, dz, radius)) continue;
            if (cx < std.math.minInt(i32) or cx > std.math.maxInt(i32) or cz < std.math.minInt(i32) or cz > std.math.maxInt(i32)) continue;
            const chunk_x: i32 = @intCast(cx);
            const chunk_z: i32 = @intCast(cz);
            const dist_sq = clampedDistanceSquared(dx, dz);

            const key = ChunkKey{ .x = chunk_x, .z = chunk_z };
            const data = self.storage.chunks.get(key) orelse data: {
                const created = try self.storage.createChunkDataUnlocked(chunk_x, chunk_z);
                errdefer self.storage.allocator.destroy(created);
                try self.storage.chunks.put(key, created);
                break :data created;
            };

            switch (data.chunk.state) {
                .missing => {
                    const priority_dist_sq = weightedDistanceSq(dist_sq, movement, @intCast(dx), @intCast(dz));
                    self.gen_queue.push(.{
                        .type = .chunk_generation,
                        .dist_sq = priority_dist_sq,
                        .data = .{ .chunk = .{ .x = chunk_x, .z = chunk_z, .job_token = data.chunk.job_token } },
                    }) catch {
                        self.missing_rescan_requested.store(true, .release);
                        continue;
                    };
                    data.chunk.state = .queued_for_generation;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn processChunkStates(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32, frame_counter: u64) void {
        // Fast path: drain the per-state transition queues that workers
        // appended to. This is O(pending_count) and avoids holding the
        // storage's exclusive lock while iterating every loaded chunk.
        self.drainPendingMesh(pc_x, pc_z, render_dist);
        self.drainPendingUpload();

        // Slow path: a throttled recovery scan that catches stuck chunks and
        // any state reset outside the worker path. Previously this ran every
        // frame; now it runs every RECOVERY_SCAN_PERIOD frames.
        if (frame_counter % RECOVERY_SCAN_PERIOD != 0) return;

        // Fixed-size scratch for chunks the scan flips back to `.generated`
        // (dirty / no-allocations recovery). Sized generously; overflow is
        // silently dropped and picked up by the next scan.
        var recovery_enqueue: [64]PendingMeshRef = undefined;
        var recovery_count: usize = 0;

        self.storage.chunks_mutex.lock();

        var mesh_iter = self.storage.iteratorUnsafe();
        while (mesh_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                // Safety net in case a worker's pending-mesh notification was
                // lost (e.g. allocation failure on append).
                const dx = @as(i64, data.chunk.chunk_x) - @as(i64, pc_x);
                const dz = @as(i64, data.chunk.chunk_z) - @as(i64, pc_z);
                if (isWithinDistance(dx, dz, render_dist)) {
                    self.mesh_queue.push(.{
                        .type = .chunk_meshing,
                        .dist_sq = clampedDistanceSquared(dx, dz),
                        .data = .{ .chunk = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token } },
                    }) catch continue;
                    data.chunk.state = .queued_for_mesh;
                }
            } else if (data.chunk.state == .mesh_ready) {
                // Safety net for lost pending-upload notifications.
                data.chunk.state = .uploading;
                self.upload_queue.push(key) catch {
                    data.chunk.state = .mesh_ready;
                    continue;
                };
            } else if (data.chunk.state == .renderable) {
                if (data.chunk.dirty) {
                    data.chunk.dirty = false;
                    data.chunk.state = .generated;
                    if (recovery_count < recovery_enqueue.len) {
                        recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                        recovery_count += 1;
                    }
                } else if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null and data.chunk.mesh_attempts < 3) {
                    data.chunk.mesh_attempts += 1;
                    log.log.warn("CHUNK_RECOVERY: ({},{}) renderable with no allocations, re-meshing (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    data.chunk.state = .generated;
                    if (recovery_count < recovery_enqueue.len) {
                        recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                        recovery_count += 1;
                    }
                }
            } else if (data.chunk.state == .generating and !data.chunk.isPinned() and frame_counter % 120 == 0) {
                const dx = @as(i64, data.chunk.chunk_x) - @as(i64, pc_x);
                const dz = @as(i64, data.chunk.chunk_z) - @as(i64, pc_z);
                const max_dist = @as(i64, render_dist) + CHUNK_UNLOAD_BUFFER;
                if (isWithinDistance(dx, dz, max_dist)) {
                    data.chunk.job_token += 1;
                    data.chunk.state = .missing;
                    log.log.warn("CHUNK_STUCK: ({},{}) in generating state too long, resetting to missing", .{ data.chunk.chunk_x, data.chunk.chunk_z });
                }
            } else if (data.chunk.state == .uploading and frame_counter % 60 == 0) {
                const dx = @as(i64, data.chunk.chunk_x) - @as(i64, pc_x);
                const dz = @as(i64, data.chunk.chunk_z) - @as(i64, pc_z);
                if (isWithinDistance(dx, dz, render_dist)) {
                    data.chunk.mesh_attempts +|= 1;
                    if (data.chunk.mesh_attempts < 3) {
                        log.log.warn("CHUNK_UPLOAD_STUCK: ({},{}) in uploading state too long, resetting to generated (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                        data.chunk.state = .generated;
                        if (recovery_count < recovery_enqueue.len) {
                            recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                            recovery_count += 1;
                        }
                    } else {
                        log.log.warn("CHUNK_UPLOAD_STUCK: ({},{}) exceeded max upload recovery attempts ({}), leaving as uploading", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    }
                }
            }
        }
        self.storage.chunks_mutex.unlock();

        // Keep notification allocation outside the storage lock. Drains release
        // the pending mutex before taking chunks_mutex, never nesting the two.
        for (recovery_enqueue[0..recovery_count]) |ref| {
            self.enqueuePendingMesh(ref.x, ref.z, ref.job_token);
        }
    }

    /// Worker-facing helper: notify the main thread that a chunk is now in the
    /// `.generated` state and needs a mesh job. Safe to call from any thread;
    /// takes a brief spinlock and never blocks on the storage mutex.
    pub fn enqueuePendingMesh(self: *ChunkQueueCoordinator, cx: i32, cz: i32, job_token: u32) void {
        self.pending_mesh_mutex.lock();
        defer self.pending_mesh_mutex.unlock();
        self.pending_mesh_incoming.append(self.allocator, .{ .x = cx, .z = cz, .job_token = job_token }) catch return;
    }

    /// Worker-facing helper: notify the main thread that a chunk is now in the
    /// `.mesh_ready` state and needs to be uploaded.
    pub fn enqueuePendingUpload(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        self.pending_upload_mutex.lock();
        defer self.pending_upload_mutex.unlock();
        self.pending_upload_incoming.append(self.allocator, .{ .x = cx, .z = cz }) catch return;
    }

    /// Immediately schedules dirty chunks near a runtime edit instead of
    /// waiting for the periodic recovery scan.
    pub fn requestDirtyRemesh(self: *ChunkQueueCoordinator, center_cx: i32, center_cz: i32) void {
        var enqueue_refs: [9]PendingMeshRef = undefined;
        var enqueue_count: usize = 0;

        self.storage.chunks_mutex.lock();
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const data = self.storage.chunks.get(.{ .x = center_cx + dx, .z = center_cz + dz }) orelse continue;
                if (!data.chunk.dirty or !data.chunk.generated) continue;
                switch (data.chunk.state) {
                    .generated, .renderable, .mesh_ready, .uploading => {
                        // Invalidate in-flight GPU/CPU mesh output before the
                        // replacement job is queued.
                        data.chunk.job_token +%= 1;
                        data.chunk.state = .generated;
                        enqueue_refs[enqueue_count] = .{
                            .x = data.chunk.chunk_x,
                            .z = data.chunk.chunk_z,
                            .job_token = data.chunk.job_token,
                        };
                        enqueue_count += 1;
                    },
                    else => {},
                }
            }
        }
        self.storage.chunks_mutex.unlock();

        for (enqueue_refs[0..enqueue_count]) |ref| {
            self.enqueuePendingMesh(ref.x, ref.z, ref.job_token);
        }
    }

    fn drainPendingMesh(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32) void {
        // Swap-and-clear under the pending mutex, then process outside it so
        // worker appends are unblocked as quickly as possible.
        var local: std.ArrayListUnmanaged(PendingMeshRef) = .empty;
        self.pending_mesh_mutex.lock();
        local.appendSlice(self.allocator, self.pending_mesh_incoming.items) catch {
            self.pending_mesh_mutex.unlock();
            return;
        };
        self.pending_mesh_incoming.clearRetainingCapacity();
        self.pending_mesh_mutex.unlock();
        defer local.deinit(self.allocator);

        if (local.items.len == 0) return;

        // Single exclusive-lock batch to validate state + flip to queued.
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (local.items) |ref| {
            const data = self.storage.chunks.get(.{ .x = ref.x, .z = ref.z }) orelse continue;
            if (data.chunk.state != .generated or data.chunk.job_token != ref.job_token) continue;
            const dx = @as(i64, ref.x) - @as(i64, pc_x);
            const dz = @as(i64, ref.z) - @as(i64, pc_z);
            if (!isWithinDistance(dx, dz, render_dist)) continue;
            const dist_sq = clampedDistanceSquared(dx, dz);
            self.mesh_queue.push(.{
                .type = .chunk_meshing,
                .dist_sq = dist_sq,
                .data = .{ .chunk = .{ .x = ref.x, .z = ref.z, .job_token = ref.job_token } },
            }) catch continue;
            data.chunk.state = .queued_for_mesh;
        }
    }

    fn drainPendingUpload(self: *ChunkQueueCoordinator) void {
        var local: std.ArrayListUnmanaged(ChunkKey) = .empty;
        self.pending_upload_mutex.lock();
        local.appendSlice(self.allocator, self.pending_upload_incoming.items) catch {
            self.pending_upload_mutex.unlock();
            return;
        };
        self.pending_upload_incoming.clearRetainingCapacity();
        self.pending_upload_mutex.unlock();
        defer local.deinit(self.allocator);

        if (local.items.len == 0) return;

        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (local.items) |key| {
            const data = self.storage.chunks.get(key) orelse continue;
            if (data.chunk.state != .mesh_ready) continue;
            data.chunk.state = .uploading;
            self.upload_queue.push(key) catch {
                data.chunk.state = .mesh_ready;
            };
        }
    }

    pub fn processUploads(self: *ChunkQueueCoordinator) void {
        var uploads: usize = 0;
        while (!self.upload_queue.isEmpty() and uploads < self.max_uploads_per_frame) {
            const key = self.upload_queue.pop() orelse break;
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            if (self.storage.chunks.get(key)) |data| {
                if (data.chunk.state != .uploading) continue;

                // GPU block uploads read resident blocks; state/dirty flags may
                // also be changed by workers. Neither is protected by main-thread
                // ownership alone. Lock order continues chunks -> mesh here.
                switch (self.gpu.queueGpuMesh(data)) {
                    .queued => {},
                    .deferred => {
                        data.chunk.mesh_attempts +|= 1;
                        if (data.chunk.mesh_attempts >= 8) {
                            // Persistent GPU queue or block-buffer pressure must
                            // not leave the chunk invisible forever.
                            data.chunk.force_cpu_mesh = true;
                            data.chunk.state = .generated;
                            self.enqueuePendingMesh(key.x, key.z, data.chunk.job_token);
                        } else {
                            self.enqueuePendingUpload(key.x, key.z);
                        }
                    },
                    .unavailable => {
                        data.render.mesh.upload(self.vertex_allocator);

                        if (data.render.mesh.diag_tile0_count > 0) {
                            log.log.warn("TILE0_MESH: chunk ({},{}) has {}/{} vertices with tile_id=0 (WHITE)", .{
                                data.chunk.chunk_x,                data.chunk.chunk_z,
                                data.render.mesh.diag_tile0_count, data.render.mesh.diag_total_verts,
                            });
                        }

                        if (data.render.mesh.ready) {
                            if (data.chunk.dirty) {
                                data.chunk.state = .generated;
                                self.enqueuePendingMesh(key.x, key.z, data.chunk.job_token);
                            } else {
                                data.chunk.state = .renderable;
                                data.chunk.mesh_attempts = 0;
                                data.chunk.force_cpu_mesh = false;
                                _ = self.chunks_uploaded_total.fetchAdd(1, .monotonic);
                            }
                        } else {
                            log.log.warn("CHUNK_UPLOAD: ({},{}) upload FAILED (ready=false), reverting to mesh_ready | solid={} cutout={} fluid={}", .{
                                key.x,                                     key.z,
                                data.render.mesh.solid_allocation != null, data.render.mesh.cutout_allocation != null,
                                data.render.mesh.fluid_allocation != null,
                            });
                            data.chunk.state = .mesh_ready;
                            self.enqueuePendingUpload(key.x, key.z);
                        }
                    },
                }
                uploads += 1;
            }
        }
    }

    pub fn processGenJob(ctx: *anyopaque, job: Job) void {
        const self: *ChunkQueueCoordinator = @ptrCast(@alignCast(ctx));
        _ = self.generation_jobs_in_flight.fetchAdd(1, .acq_rel);
        defer _ = self.generation_jobs_in_flight.fetchSub(1, .acq_rel);
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        var save_manager: ?*SaveManager = null;
        const chunk_data = claim: {
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse return;
            if (data.chunk.job_token != job.data.chunk.job_token) return;
            const dx = @as(i64, cx) - self.last_pc_x.load(.acquire);
            const dz = @as(i64, cz) - self.last_pc_z.load(.acquire);
            const max_dist = @as(i64, self.effective_render_dist.load(.acquire)) + CHUNK_UNLOAD_BUFFER;
            if (!isWithinDistance(dx, dz, max_dist)) {
                if (data.chunk.state == .queued_for_generation or (data.chunk.state == .generating and !data.chunk.isPinned())) data.chunk.state = .missing;
                return;
            }
            // A duplicate job must not claim an already-running generation.
            if (data.chunk.state != .queued_for_generation) return;
            data.chunk.state = .generating;
            data.chunk.pin();
            save_manager = self.save_manager;
            break :claim data;
        };
        defer chunk_data.chunk.unpin();

        var published = false;
        defer if (!published) {
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            if (chunk_data.chunk.state == .generating and chunk_data.chunk.job_token == job.data.chunk.job_token) {
                chunk_data.chunk.state = .missing;
                self.missing_rescan_requested.store(true, .release);
            }
        };
        if (self.gen_queue.shouldAbort()) return;
        if (save_manager) |sm| {
            if (sm.load_failed.load(.acquire)) return;
        }

        // Loading/generation may set generated=true before their final writes.
        // Keep all of that work private, including map-surface rebuilding.
        const generated = self.allocator.create(Chunk) catch return;
        defer self.allocator.destroy(generated);
        generated.* = Chunk.init(cx, cz);
        const load_result = if (save_manager) |sm| sm.loadChunk(cx, cz, generated) else LoadResult.not_found;
        switch (load_result) {
            .not_found => {
                // Generator's legacy *const bool cancellation API cannot safely
                // observe the shared queue flag. Cancel between chunks instead.
                self.generator.generate(generated, null) catch |err| {
                    log.log.warn("CHUNK_GEN_ERROR: ({},{}) generator failed: {}", .{ cx, cz, err });
                    return;
                };
                generated.lighting_valid = true;
            },
            .success, .success_relight_required => {},
            .read_error, .corrupt_data => {
                // SaveManager latched the failure for WorldStreamer to surface.
                // Never publish partial load output or regenerate persistent data.
                log.log.err("Save load failed for chunk ({}, {}): {}, generation stopped", .{ cx, cz, load_result });
                return;
            },
        }
        if (self.gen_queue.shouldAbort()) return;
        if (!generated.generated) {
            log.log.warn("CHUNK_GEN_FAILED: ({},{}) generator returned without setting generated=true", .{ cx, cz });
            return;
        }
        if (generated.rebuildMapSurface() == 0) {
            log.log.warn("CHUNK_GEN_EMPTY: ({},{}) generated chunk has ZERO non-air blocks", .{ cx, cz });
            return;
        }

        {
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            if (chunk_data.chunk.state != .generating or chunk_data.chunk.job_token != job.data.chunk.job_token) return;
            // Do not copy job tokens, pins, or atomic revisions from private data.
            inline for (.{ "blocks", "light", "biomes", "heightmap", "map_surface_blocks", "map_surface_heights", "dirty", "modified", "lighting_valid" }) |name| {
                @field(chunk_data.chunk, name) = @field(generated, name);
            }
            chunk_data.chunk.markContentChanged();
            chunk_data.chunk.markLightChanged();
            chunk_data.chunk.map_surface_revision = chunk_data.chunk.content_revision.load(.acquire);
            chunk_data.chunk.generated = true;
            chunk_data.chunk.state = .generated;
            self.storage.markMapSurfaceChanged();
            _ = self.chunks_generated_total.fetchAdd(1, .monotonic);
            published = true;
        }

        // Reconciliation now sees only fully published data and participates in
        // the same input/revision lock protocol as edits and mesh snapshots.
        var lighting = WorldLightingEngine.init(self.storage, self.allocator);
        if (load_result == .success_relight_required) {
            _ = lighting.reconcileLegacyArea(cx, cz) catch |err| blk: {
                log.log.warn("CHUNK_LIGHTING_ERROR: ({},{}) legacy relight failed: {}", .{ cx, cz, err });
                break :blk false;
            };
        } else if (load_result == .success) {
            _ = lighting.reconcileChunkArrival(cx, cz) catch |err| blk: {
                log.log.warn("CHUNK_LIGHTING_ERROR: ({},{}) boundary reconciliation failed: {}", .{ cx, cz, err });
                break :blk false;
            };
        }
        self.markNeighborsForRemesh(cx, cz);
        self.enqueueReadyNeighborhood(cx, cz);
    }

    pub fn processMeshJob(ctx: *anyopaque, job: Job) void {
        const self: *ChunkQueueCoordinator = @ptrCast(@alignCast(ctx));
        _ = self.mesh_jobs_in_flight.fetchAdd(1, .acq_rel);
        defer _ = self.mesh_jobs_in_flight.fetchSub(1, .acq_rel);
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        var snapshot: ?MeshInputSnapshot = null;
        defer if (snapshot) |inputs| inputs.deinit(self.allocator);
        var neighbors = NeighborChunks.empty;
        var mesh_revisions: MeshInputRevisions = undefined;
        const chunk_data = claim: {
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();

            const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse return;
            if (data.chunk.job_token != job.data.chunk.job_token) return;
            const dx = @as(i64, cx) - self.last_pc_x.load(.acquire);
            const dz = @as(i64, cz) - self.last_pc_z.load(.acquire);
            const max_dist = @as(i64, self.effective_render_dist.load(.acquire)) + CHUNK_UNLOAD_BUFFER;
            if (!isWithinDistance(dx, dz, max_dist)) {
                if (data.chunk.state == .queued_for_mesh or (data.chunk.state == .meshing and !data.chunk.isPinned())) data.chunk.state = .generated;
                return;
            }
            if (data.chunk.state != .queued_for_mesh or !data.chunk.generated) return;
            neighbors = MeshInputSnapshot.residentNeighbors(self.storage, cx, cz);
            mesh_revisions = MeshInputRevisions.capture(&data.chunk, neighbors);
            if (!self.gpu_mesh_enabled.load(.acquire) or data.chunk.force_cpu_mesh) {
                snapshot = MeshInputSnapshot.capture(self.allocator, &data.chunk, neighbors) catch {
                    data.chunk.state = .generated;
                    self.enqueuePendingMesh(cx, cz, job.data.chunk.job_token);
                    return;
                };
            }
            // Claim exactly once, after all fallible snapshot allocation. Pins
            // remain until publication, including neighbor revision validation.
            data.chunk.state = .meshing;
            data.chunk.pin();
            inline for (.{ "north", "south", "east", "west" }) |name| {
                if (@field(neighbors, name)) |neighbor| @constCast(neighbor).pin();
            }
            break :claim data;
        };
        defer {
            chunk_data.chunk.unpin();
            inline for (.{ "north", "south", "east", "west" }) |name| {
                if (@field(neighbors, name)) |neighbor| @constCast(neighbor).unpin();
            }
        }

        // Both inputs and output are worker-private during expensive meshing.
        // Stale/failed work must not replace another job's pending vertices.
        var built_mesh = world_meshing.ChunkMesh.init(self.allocator);
        defer built_mesh.deinitWithoutRHI();
        var build_succeeded = true;
        if (snapshot) |inputs| {
            built_mesh.buildWithNeighbors(&inputs.chunks[0], inputs.neighbors, self.atlas) catch |err| {
                log.log.errWithTrace("Mesh build failed for chunk ({}, {}): {}", .{ cx, cz, err });
                build_succeeded = false;
            };
        }
        const aborted = self.mesh_queue.shouldAbort();
        const publishable = publish: {
            // Exclude lighting batches until their revision has been advanced.
            self.storage.lighting_mutex.lock();
            defer self.storage.lighting_mutex.unlock();
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            // A reset/new job owns its own state. Never clobber it on failure.
            if (chunk_data.chunk.state != .meshing or chunk_data.chunk.job_token != job.data.chunk.job_token) return;
            const current_neighbors = MeshInputSnapshot.residentNeighbors(self.storage, cx, cz);
            const inputs_match = if (snapshot) |inputs|
                inputs.matches(&chunk_data.chunk, current_neighbors)
            else
                mesh_revisions.matches(&chunk_data.chunk, current_neighbors);
            if (!build_succeeded or aborted or !inputs_match) {
                chunk_data.chunk.state = .generated;
                break :publish false;
            }
            if (snapshot != null) chunk_data.render.mesh.takePendingFrom(&built_mesh);
            chunk_data.chunk.state = .mesh_ready;
            chunk_data.chunk.dirty = false;
            break :publish true;
        };
        if (!publishable) {
            self.enqueuePendingMesh(cx, cz, job.data.chunk.job_token);
            return;
        }
        self.enqueuePendingUpload(cx, cz);
        _ = self.chunks_meshed_total.fetchAdd(1, .monotonic);
    }

    fn markNeighborsForRemesh(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };

        self.storage.chunks_mutex.lock();
        for (offsets) |off| {
            if (self.storage.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                switch (data.chunk.state) {
                    .renderable => data.chunk.state = .generated,
                    .mesh_ready, .uploading, .meshing => data.chunk.dirty = true,
                    else => {},
                }
            }
        }
        self.storage.chunks_mutex.unlock();
    }

    /// Coalesce startup boundary invalidations by waiting until each generated
    /// chunk's currently-required cardinal neighbors exist before its first or
    /// replacement mesh is queued. The periodic recovery scan remains the
    /// fallback for failed generation or dropped notifications.
    fn enqueueReadyNeighborhood(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };
        const neighbor_offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };
        const pc_x = self.last_pc_x.load(.acquire);
        const pc_z = self.last_pc_z.load(.acquire);
        const render_dist = self.effective_render_dist.load(.acquire);

        var enqueue_refs: [offsets.len]PendingMeshRef = undefined;
        var enqueue_count: usize = 0;

        self.storage.chunks_mutex.lockShared();
        for (offsets) |off| {
            const candidate_x = cx + off[0];
            const candidate_z = cz + off[1];
            const data = self.storage.chunks.get(ChunkKey{ .x = candidate_x, .z = candidate_z }) orelse continue;
            if (data.chunk.state != .generated) continue;

            var neighborhood_ready = true;
            for (neighbor_offsets) |neighbor_off| {
                const neighbor_x = candidate_x + neighbor_off[0];
                const neighbor_z = candidate_z + neighbor_off[1];
                const dx: i64 = @as(i64, neighbor_x) - pc_x;
                const dz: i64 = @as(i64, neighbor_z) - pc_z;
                const render_dist_i64: i64 = render_dist;
                if (dx * dx + dz * dz > render_dist_i64 * render_dist_i64) continue;

                const neighbor = self.storage.chunks.get(ChunkKey{ .x = neighbor_x, .z = neighbor_z });
                if (neighbor == null or !neighbor.?.chunk.generated) {
                    neighborhood_ready = false;
                    break;
                }
            }
            if (!neighborhood_ready) continue;

            enqueue_refs[enqueue_count] = .{
                .x = candidate_x,
                .z = candidate_z,
                .job_token = data.chunk.job_token,
            };
            enqueue_count += 1;
        }
        self.storage.chunks_mutex.unlockShared();

        // Avoid extending the state-lock batch with notification allocation.
        for (enqueue_refs[0..enqueue_count]) |ref| {
            self.enqueuePendingMesh(ref.x, ref.z, ref.job_token);
        }
    }
};

test "stale generation job resets chunk to missing" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(64, 0);
    data.chunk.state = .generating;
    data.chunk.job_token = 7;

    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
        .last_pc_x = std.atomic.Value(i32).init(0),
        .last_pc_z = std.atomic.Value(i32).init(0),
        .effective_render_dist = std.atomic.Value(i32).init(8),
    };
    defer coordinator.deinit();

    ChunkQueueCoordinator.processGenJob(&coordinator, .{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 64, .z = 0, .job_token = 7 } },
    });

    try testing.expectEqual(Chunk.State.missing, data.chunk.state);
}

test "stale mesh job resets chunk to generated" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(64, 0);
    data.chunk.state = .meshing;
    data.chunk.generated = true;
    data.chunk.job_token = 11;

    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
        .last_pc_x = std.atomic.Value(i32).init(0),
        .last_pc_z = std.atomic.Value(i32).init(0),
        .effective_render_dist = std.atomic.Value(i32).init(8),
    };
    defer coordinator.deinit();

    ChunkQueueCoordinator.processMeshJob(&coordinator, .{
        .type = .chunk_meshing,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 64, .z = 0, .job_token = 11 } },
    });

    try testing.expectEqual(Chunk.State.generated, data.chunk.state);
}

test "runtime edits enqueue dirty renderable chunks immediately" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(0, 0);
    data.chunk.generated = true;
    data.chunk.state = .renderable;
    data.chunk.dirty = true;

    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
    };
    defer coordinator.deinit();

    coordinator.requestDirtyRemesh(0, 0);

    try testing.expectEqual(Chunk.State.generated, data.chunk.state);
    try testing.expectEqual(@as(usize, 1), coordinator.pending_mesh_incoming.items.len);
}

test "missing chunk scan cursor covers concentric square rings without duplicates" {
    var coordinator: ChunkQueueCoordinator = undefined;
    coordinator.resetMissingScan(10, -5, 2);

    var coordinates: [25][2]i64 = undefined;
    var count: usize = 0;
    while (coordinator.nextMissingScanCoordinate(10, -5, 2)) |coordinate| {
        try std.testing.expect(count < coordinates.len);
        for (coordinates[0..count]) |previous| {
            try std.testing.expect(previous[0] != coordinate[0] or previous[1] != coordinate[1]);
        }
        coordinates[count] = coordinate;
        count += 1;
    }

    try std.testing.expectEqual(coordinates.len, count);
    try std.testing.expect(MAX_MISSING_SCAN_STEPS < @as(usize, 4096) * 4096);
}

test "mesh input snapshots retain target and neighbor data across runtime edits" {
    const testing = std.testing;
    const boundary = world_meshing.meshing.boundary;
    const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const target = try storage.getOrCreate(0, 0);
    target.chunk.generated = true;
    target.chunk.setBlock(1, 2, 3, .stone);
    target.chunk.setLight(1, 2, 3, world_core.PackedLight.init(7, 4));
    target.chunk.setBiome(1, 3, .forest);
    const offsets = [_][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
    for (offsets) |offset| {
        const neighbor = try storage.getOrCreate(offset[0], offset[1]);
        neighbor.chunk.generated = true;
        neighbor.chunk.fill(.stone);
        @memset(&neighbor.chunk.light, world_core.PackedLight.init(9, 6));
        @memset(&neighbor.chunk.biomes, .forest);
    }
    const snapshot = capture: {
        storage.lighting_mutex.lock();
        defer storage.lighting_mutex.unlock();
        storage.chunks_mutex.lockShared();
        defer storage.chunks_mutex.unlockShared();
        const neighbors = MeshInputSnapshot.residentNeighbors(&storage, 0, 0);
        break :capture try MeshInputSnapshot.capture(testing.allocator, &target.chunk, neighbors);
    };
    defer snapshot.deinit(testing.allocator);

    var mutation = WorldMutationCoordinator.init(&storage, testing.allocator, null, false);
    const samples = [_][2]i32{ .{ 3, -1 }, .{ 3, 16 }, .{ 16, 3 }, .{ -1, 3 } };
    for (samples) |sample| _ = try mutation.applyBlockMutation(sample[0], 2, sample[1], .dirt);
    {
        storage.lighting_mutex.lock();
        defer storage.lighting_mutex.unlock();
        storage.chunks_mutex.lockShared();
        defer storage.chunks_mutex.unlockShared();
        // Target is unchanged: neighbor edits alone must reject publication.
        try testing.expect(!snapshot.matches(&target.chunk, MeshInputSnapshot.residentNeighbors(&storage, 0, 0)));
    }
    _ = try mutation.applyBlockMutation(1, 2, 3, .dirt);
    {
        storage.lighting_mutex.lock();
        defer storage.lighting_mutex.unlock();
        storage.chunks_mutex.lock();
        defer storage.chunks_mutex.unlock();
        var iter = storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            @memset(&entry.value_ptr.*.chunk.light, world_core.PackedLight.init(0, 0));
            @memset(&entry.value_ptr.*.chunk.biomes, .desert);
            entry.value_ptr.*.chunk.markLightChanged();
            entry.value_ptr.*.chunk.markContentChanged();
        }
        try testing.expect(!snapshot.matches(&target.chunk, MeshInputSnapshot.residentNeighbors(&storage, 0, 0)));
    }
    const copy = &snapshot.chunks[0];
    try testing.expectEqual(world_core.BlockType.stone, copy.getBlock(1, 2, 3));
    try testing.expectEqual(@as(u4, 7), copy.getSkyLight(1, 2, 3));
    try testing.expectEqual(world_core.BiomeId.forest, copy.getBiome(1, 3));
    for (samples) |sample| {
        try testing.expectEqual(world_core.BlockType.stone, boundary.getBlockCross(copy, snapshot.neighbors, sample[0], 2, sample[1]));
        try testing.expectEqual(@as(u4, 9), boundary.getLightCross(copy, snapshot.neighbors, sample[0], 2, sample[1]).getSkyLight());
        try testing.expectEqual(world_core.BiomeId.forest, boundary.getBiomeAt(copy, snapshot.neighbors, sample[0], sample[1]));
    }
}

test "mesh job snapshot and build allocation failures release every pin" {
    const testing = std.testing;
    // Snapshot, mask, then each of the three initial vertex buffers.
    for (0..5) |fail_index| {
        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();
        const target = try storage.getOrCreate(0, 0);
        const east = try storage.getOrCreate(1, 0);
        target.chunk.generated = true;
        target.chunk.state = .queued_for_mesh;
        east.chunk.generated = true;
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var queue = JobQueue.init(testing.allocator);
        defer queue.deinit();
        var gpu = GpuAccelerationCoordinator.init(null, null);
        var coordinator = ChunkQueueCoordinator{
            .allocator = failing.allocator(),
            .storage = &storage,
            .generator = undefined,
            .atlas = undefined,
            .gen_queue = &queue,
            .mesh_queue = &queue,
            .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
            .vertex_allocator = undefined,
            .gpu = &gpu,
            .max_uploads_per_frame = 8,
        };
        defer coordinator.deinit();
        ChunkQueueCoordinator.processMeshJob(&coordinator, .{
            .type = .chunk_meshing,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = target.chunk.job_token } },
        });
        try testing.expectEqual(Chunk.State.generated, target.chunk.state);
        try testing.expect(!target.chunk.isPinned());
        try testing.expect(!east.chunk.isPinned());
        try testing.expectEqual(@as(u32, 0), coordinator.mesh_jobs_in_flight.load(.acquire));
        try testing.expectEqual(@as(u64, 0), coordinator.chunks_meshed_total.load(.acquire));
        try testing.expect(target.render.mesh.pending_solid == null);
        try testing.expect(storage.lighting_mutex.tryLock());
        storage.lighting_mutex.unlock();
        try testing.expect(storage.chunks_mutex.tryLock());
        storage.chunks_mutex.unlock();
    }
}

test "generation publishes private data without copying pins and rejects reset work" {
    const testing = std.testing;
    const Probe = struct {
        coordinator: *ChunkQueueCoordinator,
        job: Job,
        reset: bool,
        saw_private: bool = false,
        saw_pin: bool = false,
        locks_released: bool = false,
        calls: usize = 0,

        fn generate(ctx: *anyopaque, chunk: *Chunk, _: ?*const bool) @import("world-worldgen").worldgen_api.WorldgenError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls > 1) return;
            chunk.setBlock(1, 2, 3, .stone);
            chunk.generated = true;
            const storage = self.coordinator.storage;
            if (storage.lighting_mutex.tryLock()) {
                defer storage.lighting_mutex.unlock();
                if (storage.chunks_mutex.tryLock()) {
                    defer storage.chunks_mutex.unlock();
                    self.locks_released = true;
                    const resident = storage.chunks.get(.{ .x = 0, .z = 0 }).?;
                    self.saw_private = chunk != &resident.chunk and !resident.chunk.generated and resident.chunk.getBlock(1, 2, 3) == .air;
                    self.saw_pin = resident.chunk.isPinned();
                }
            }
            // Duplicate dispatch cannot claim the running job a second time.
            ChunkQueueCoordinator.processGenJob(self.coordinator, self.job);
            if (self.reset) self.coordinator.resetPausedChunks();
        }
    };
    for ([_]bool{ false, true }) |reset| {
        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();
        const target = try storage.getOrCreate(0, 0);
        target.chunk.state = .queued_for_generation;
        var queue = JobQueue.init(testing.allocator);
        defer queue.deinit();
        var gpu = GpuAccelerationCoordinator.init(null, null);
        var coordinator = ChunkQueueCoordinator{
            .allocator = testing.allocator,
            .storage = &storage,
            .generator = undefined,
            .atlas = undefined,
            .gen_queue = &queue,
            .mesh_queue = &queue,
            .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
            .vertex_allocator = undefined,
            .gpu = &gpu,
            .max_uploads_per_frame = 8,
        };
        defer coordinator.deinit();
        var probe = Probe{
            .coordinator = &coordinator,
            .job = .{ .type = .chunk_generation, .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = target.chunk.job_token } } },
            .reset = reset,
        };
        coordinator.generator = .{
            .ptr = &probe,
            .info = .{ .name = "probe", .description = "private generation probe", .version = 1 },
            .vtable = &.{ .generate = Probe.generate, .getSeed = undefined, .getRegionInfo = undefined, .getColumnInfo = undefined, .deinit = undefined },
        };
        ChunkQueueCoordinator.processGenJob(&coordinator, probe.job);
        try testing.expect(probe.saw_private and probe.saw_pin and probe.locks_released);
        try testing.expectEqual(@as(usize, 1), probe.calls);
        try testing.expect(!target.chunk.isPinned());
        try testing.expectEqual(@as(u32, 0), coordinator.generation_jobs_in_flight.load(.acquire));
        try testing.expectEqual(!reset, target.chunk.generated);
        try testing.expectEqual(if (reset) Chunk.State.missing else Chunk.State.generated, target.chunk.state);
        try testing.expectEqual(if (reset) world_core.BlockType.air else world_core.BlockType.stone, target.chunk.getBlock(1, 2, 3));
        if (reset) {
            try testing.expect(target.chunk.job_token != probe.job.data.chunk.job_token);
        } else {
            try testing.expectEqual(probe.job.data.chunk.job_token, target.chunk.job_token);
            try testing.expect(target.chunk.mapSurfaceIsCurrent());
        }
    }
}

test "mesh jobs cannot reclaim active or reset lifecycle state" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const target = try storage.getOrCreate(0, 0);
    target.chunk.generated = true;
    target.chunk.state = .meshing;
    target.chunk.pin();
    defer target.chunk.unpin();
    const unpublished = try storage.getOrCreate(1, 0);
    unpublished.chunk.generated = true;
    unpublished.chunk.state = .generating;
    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
    };
    defer coordinator.deinit();
    const job = Job{ .type = .chunk_meshing, .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = target.chunk.job_token } } };
    ChunkQueueCoordinator.processMeshJob(&coordinator, job);
    try testing.expectEqual(Chunk.State.meshing, target.chunk.state);
    try testing.expectEqual(@as(u32, 1), target.chunk.pin_count.load(.monotonic));
    {
        storage.lighting_mutex.lock();
        defer storage.lighting_mutex.unlock();
        storage.chunks_mutex.lock();
        defer storage.chunks_mutex.unlock();
        const neighbors = MeshInputSnapshot.residentNeighbors(&storage, 0, 0);
        try testing.expect(neighbors.east == null);
        const revisions = MeshInputRevisions.capture(&target.chunk, neighbors);
        unpublished.chunk.state = .generated;
        try testing.expect(!revisions.matches(&target.chunk, MeshInputSnapshot.residentNeighbors(&storage, 0, 0)));
    }
    coordinator.resetPausedChunks();
    const reset_token = target.chunk.job_token;
    try testing.expect(reset_token != job.data.chunk.job_token);
    ChunkQueueCoordinator.processMeshJob(&coordinator, job);
    try testing.expectEqual(reset_token, target.chunk.job_token);
    try testing.expectEqual(Chunk.State.generated, target.chunk.state);
    try testing.expectEqual(@as(usize, 0), coordinator.pending_upload_incoming.items.len);
}

test "generation load failures preserve resident and persistent data and stop queued generation" {
    const testing = std.testing;
    const fs = @import("fs");
    const RegionFile = @import("world-persistence").RegionFile;
    const Probe = struct {
        calls: usize = 0,

        fn generate(ctx: *anyopaque, chunk: *Chunk, _: ?*const bool) @import("world-worldgen").worldgen_api.WorldgenError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            chunk.setBlock(1, 2, 3, .stone);
            chunk.generated = true;
        }
    };

    for ([_]LoadResult{ .read_error, .corrupt_data }) |failure| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = fs.Dir{ .inner = tmp.dir };
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const path = try dir.realpath(".", &path_buf);
        const sm = try SaveManager.init(testing.allocator, path, "load_failure", 1, "flat");
        defer sm.deinit();
        sm.running.store(false, .release);
        sm.thread.?.join();
        sm.thread = null;

        const region_name = "regions/r.0.0.mca";
        if (failure == .read_error) {
            const file = try dir.createFile(region_name, .{});
            defer file.close();
            try file.writeAll("valuable but damaged region");
        } else {
            var region_path_buf: [fs.max_path_bytes]u8 = undefined;
            const region_path = try std.fmt.bufPrint(&region_path_buf, "{s}/{s}", .{ path, region_name });
            var region = try RegionFile.create(testing.allocator, region_path);
            defer region.close();
            // Valid region/compression, invalid serialized chunk payload.
            try region.writeChunk(0, 0, "valuable but damaged chunk");
        }
        const disk_before = try dir.readFileAlloc(region_name, testing.allocator, 1024 * 1024);
        defer testing.allocator.free(disk_before);

        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();
        const target = try storage.getOrCreate(0, 0);
        target.chunk.setBlock(1, 2, 3, .gold_ore);
        target.chunk.setLight(1, 2, 3, world_core.PackedLight.init(9, 6));
        target.chunk.setBiome(1, 3, .forest);
        target.chunk.setSurfaceHeight(1, 3, 2);
        _ = target.chunk.rebuildMapSurface();
        target.chunk.generated = true;
        target.chunk.lighting_valid = true;
        target.chunk.state = .queued_for_generation;
        const original = try testing.allocator.create(Chunk);
        defer testing.allocator.destroy(original);
        original.* = target.chunk;

        var queue = JobQueue.init(testing.allocator);
        defer queue.deinit();
        var gpu = GpuAccelerationCoordinator.init(null, null);
        var probe = Probe{};
        var coordinator = ChunkQueueCoordinator{
            .allocator = testing.allocator,
            .storage = &storage,
            .generator = .{
                .ptr = &probe,
                .info = .{ .name = "probe", .description = "generation must not replace failed loads", .version = 1 },
                .vtable = &.{ .generate = Probe.generate, .getSeed = undefined, .getRegionInfo = undefined, .getColumnInfo = undefined, .deinit = undefined },
            },
            .atlas = undefined,
            .gen_queue = &queue,
            .mesh_queue = &queue,
            .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
            .vertex_allocator = undefined,
            .gpu = &gpu,
            .max_uploads_per_frame = 8,
            .save_manager = sm,
        };
        defer coordinator.deinit();
        ChunkQueueCoordinator.processGenJob(&coordinator, .{
            .type = .chunk_generation,
            .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = target.chunk.job_token } },
        });

        try testing.expect(sm.load_failed.load(.acquire));
        try testing.expectEqual(@as(usize, 0), probe.calls);
        try testing.expectEqual(Chunk.State.missing, target.chunk.state);
        try testing.expect(!target.chunk.isPinned());
        try testing.expect(target.chunk.dirty and target.chunk.modified);
        try testing.expect(target.chunk.generated and target.chunk.lighting_valid);
        try testing.expectEqual(original.job_token, target.chunk.job_token);
        try testing.expectEqual(original.content_revision.load(.acquire), target.chunk.content_revision.load(.acquire));
        try testing.expectEqual(original.light_revision.load(.acquire), target.chunk.light_revision.load(.acquire));
        inline for (.{ "blocks", "light", "biomes", "heightmap", "map_surface_blocks", "map_surface_heights" }) |name| {
            try testing.expectEqualSlices(@TypeOf(@field(original, name)[0]), &@field(original, name), &@field(target.chunk, name));
        }
        try testing.expect(target.chunk.mapSurfaceIsCurrent());
        try testing.expectEqual(@as(u64, 0), coordinator.chunks_generated_total.load(.acquire));
        try testing.expectEqual(@as(u32, 0), coordinator.generation_jobs_in_flight.load(.acquire));
        try testing.expectEqual(@as(usize, 0), coordinator.pending_mesh_incoming.items.len);

        const scratch = try testing.allocator.create(Chunk);
        defer testing.allocator.destroy(scratch);
        scratch.* = Chunk.init(0, 0);
        try testing.expectEqual(failure, sm.loadChunk(0, 0, scratch));
        try testing.expectEqual(LoadResult.not_found, sm.loadChunk(-1, 0, scratch));
        const missing = try storage.getOrCreate(-1, 0);
        missing.chunk.state = .queued_for_generation;
        ChunkQueueCoordinator.processGenJob(&coordinator, .{
            .type = .chunk_generation,
            .data = .{ .chunk = .{ .x = -1, .z = 0, .job_token = missing.chunk.job_token } },
        });
        try testing.expectEqual(@as(usize, 0), probe.calls);
        try testing.expect(!missing.chunk.generated and !missing.chunk.isPinned());
        const disk_after = try dir.readFileAlloc(region_name, testing.allocator, 1024 * 1024);
        defer testing.allocator.free(disk_after);
        try testing.expectEqualSlices(u8, disk_before, disk_after);
    }
}
