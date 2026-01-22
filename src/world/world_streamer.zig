//! World streamer - handles asynchronous chunk loading and unloading.

const std = @import("std");
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Chunk = @import("chunk.zig").Chunk;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const JobQueue = @import("../engine/core/job_system.zig").JobQueue;
const WorkerPool = @import("../engine/core/job_system.zig").WorkerPool;
const Job = @import("../engine/core/job_system.zig").Job;
const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;
const Generator = @import("worldgen/generator_interface.zig").Generator;
const LODManager = @import("lod_manager.zig").LODManager;
const worldToChunk = @import("chunk.zig").worldToChunk;
const CHUNK_UNLOAD_BUFFER = @import("chunk.zig").CHUNK_UNLOAD_BUFFER;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const log = @import("../engine/core/log.zig");

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

/// Player movement tracking for predictive chunk loading
pub const PlayerMovement = struct {
    /// Normalized movement direction (0,0 if stationary)
    dir_x: f32 = 0,
    dir_z: f32 = 0,
    /// Speed in blocks/second
    speed: f32 = 0,
    /// Last position for velocity calculation
    last_pos: Vec3 = Vec3.init(0, 0, 0),
    /// Whether we have valid velocity data
    has_velocity: bool = false,

    /// Update with new position, returns true if direction changed significantly
    pub fn update(self: *PlayerMovement, pos: Vec3, dt: f32) bool {
        if (dt <= 0.001) return false;

        const dx = pos.x - self.last_pos.x;
        const dz = pos.z - self.last_pos.z;
        self.last_pos = pos;

        const dist = @sqrt(dx * dx + dz * dz);
        self.speed = dist / dt;

        // Only track direction if moving fast enough (> 2 blocks/sec)
        if (self.speed < 2.0) {
            self.has_velocity = false;
            return false;
        }

        const old_dx = self.dir_x;
        const old_dz = self.dir_z;

        self.dir_x = dx / dist;
        self.dir_z = dz / dist;
        self.has_velocity = true;

        // Check if direction changed significantly (> 45 degrees)
        const dot = old_dx * self.dir_x + old_dz * self.dir_z;
        return dot < 0.707; // cos(45°)
    }

    /// Calculate priority weight for a chunk based on movement direction.
    /// Returns a multiplier: < 1.0 for chunks ahead, > 1.0 for chunks behind.
    pub fn priorityWeight(self: *const PlayerMovement, chunk_dx: i32, chunk_dz: i32) f32 {
        if (!self.has_velocity) return 1.0;

        const cdx: f32 = @floatFromInt(chunk_dx);
        const cdz: f32 = @floatFromInt(chunk_dz);
        const dist = @sqrt(cdx * cdx + cdz * cdz);
        if (dist < 0.001) return 0.5; // Player's chunk gets high priority

        // Dot product with movement direction: 1.0 = ahead, -1.0 = behind
        const dot = (cdx * self.dir_x + cdz * self.dir_z) / dist;

        // Map [-1, 1] to [0.5, 1.5] - chunks ahead get 0.5x distance weight
        return 1.0 - dot * 0.5;
    }
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
    upload_queue: RingBuffer(ChunkKey),

    player_movement: PlayerMovement,
    last_pc: struct { x: i32, z: i32 },
    render_distance: i32,

    paused: bool = false,

    const GEN_WORKERS = 4;
    const MESH_WORKERS = 3;

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, render_distance: i32) !*WorldStreamer {
        const streamer = try allocator.create(WorldStreamer);

        const gen_queue = try allocator.create(JobQueue);
        gen_queue.* = JobQueue.init(allocator);

        const mesh_queue = try allocator.create(JobQueue);
        mesh_queue.* = JobQueue.init(allocator);

        streamer.* = .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .gen_pool = undefined,
            .mesh_pool = undefined,
            .upload_queue = try RingBuffer(ChunkKey).init(allocator, 256),
            .player_movement = .{},
            .last_pc = .{ .x = 9999, .z = 9999 },
            .render_distance = render_distance,
        };

        streamer.gen_pool = try WorkerPool.init(allocator, GEN_WORKERS, gen_queue, streamer, processGenJob);
        streamer.mesh_pool = try WorkerPool.init(allocator, MESH_WORKERS, mesh_queue, streamer, processMeshJob);

        return streamer;
    }

    pub fn deinit(self: *WorldStreamer) void {
        self.gen_queue.stop();
        self.mesh_queue.stop();

        self.gen_pool.deinit();
        self.mesh_pool.deinit();

        self.gen_queue.deinit();
        self.mesh_queue.deinit();
        self.allocator.destroy(self.gen_queue);
        self.allocator.destroy(self.mesh_queue);

        self.upload_queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn setPaused(self: *WorldStreamer, paused: bool) void {
        self.paused = paused;
        self.gen_queue.setPaused(paused);
        self.mesh_queue.setPaused(paused);

        if (paused) {
            // Reset chunks that were waiting for generation or meshing
            self.storage.chunks_mutex.lock();
            defer self.storage.chunks_mutex.unlock();
            var iter = self.storage.iteratorUnsafe();
            while (iter.next()) |entry| {
                const chunk = &entry.value_ptr.*.chunk;
                if (chunk.state == .generating) {
                    chunk.state = .missing;
                } else if (chunk.state == .meshing) {
                    chunk.state = .generated;
                }
            }
        } else {
            // Force chunk rescan on next update
            self.last_pc = .{ .x = 9999, .z = 9999 };
        }
    }

    pub fn setRenderDistance(self: *WorldStreamer, distance: i32) void {
        if (self.render_distance != distance) {
            self.render_distance = distance;
            // Force chunk rescan on next update
            self.last_pc = .{ .x = 9999, .z = 9999 };
        }
    }

    pub fn update(self: *WorldStreamer, player_pos: Vec3, dt: f32, lod_manager: ?*LODManager) !void {
        if (self.paused) return;

        // Update velocity tracking for predictive loading
        _ = self.player_movement.update(player_pos, dt);

        const pc = worldToChunk(@intFromFloat(player_pos.x), @intFromFloat(player_pos.z));
        const moved = pc.chunk_x != self.last_pc.x or pc.chunk_z != self.last_pc.z;

        if (moved) {
            self.last_pc = .{ .x = pc.chunk_x, .z = pc.chunk_z };

            try self.gen_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z);
            try self.mesh_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z);

            // Clamp generation distance to LOD0 radius if LOD is active
            const render_dist = if (lod_manager) |mgr| @min(self.render_distance, mgr.config.radii[0]) else self.render_distance;

            var cz = pc.chunk_z - render_dist;
            while (cz <= pc.chunk_z + render_dist) : (cz += 1) {
                var cx = pc.chunk_x - render_dist;
                while (cx <= pc.chunk_x + render_dist) : (cx += 1) {
                    const dx = cx - pc.chunk_x;
                    const dz = cz - pc.chunk_z;
                    const dist_sq = dx * dx + dz * dz;

                    if (dist_sq > render_dist * render_dist) continue;

                    const data = try self.storage.getOrCreate(cx, cz);

                    switch (data.chunk.state) {
                        .missing => {
                            const weight = self.player_movement.priorityWeight(dx, dz);
                            const weighted_dist: i32 = @intFromFloat(@as(f32, @floatFromInt(dist_sq)) * weight);

                            try self.gen_queue.push(.{
                                .type = .chunk_generation,
                                .dist_sq = weighted_dist,
                                .data = .{
                                    .chunk = .{
                                        .x = cx,
                                        .z = cz,
                                        .job_token = data.chunk.job_token,
                                    },
                                },
                            });
                            data.chunk.state = .generating;
                        },
                        // .queued_for_generation is handled implicitly by the job queue.
                        // .generating state persists until the job completes.
                        else => {},
                    }
                }
            }
        }

        self.storage.chunks_mutex.lockShared();
        var mesh_iter = self.storage.iteratorUnsafe();

        const render_dist = if (lod_manager) |mgr| @min(self.render_distance, mgr.config.radii[0]) else self.render_distance;

        while (mesh_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                const dx = data.chunk.chunk_x - pc.chunk_x;
                const dz = data.chunk.chunk_z - pc.chunk_z;
                if (dx * dx + dz * dz <= render_dist * render_dist) {
                    const weight = self.player_movement.priorityWeight(dx, dz);
                    const weighted_dist: i32 = @intFromFloat(@as(f32, @floatFromInt(dx * dx + dz * dz)) * weight);

                    try self.mesh_queue.push(.{
                        .type = .chunk_meshing,
                        .dist_sq = weighted_dist,
                        .data = .{
                            .chunk = .{
                                .x = data.chunk.chunk_x,
                                .z = data.chunk.chunk_z,
                                .job_token = data.chunk.job_token,
                            },
                        },
                    });
                    data.chunk.state = .meshing;
                }
            } else if (data.chunk.state == .mesh_ready) {
                data.chunk.state = .uploading;
                try self.upload_queue.push(key);
            } else if (data.chunk.state == .renderable and data.chunk.dirty) {
                data.chunk.dirty = false;
                data.chunk.state = .generated;
            }
        }
        self.storage.chunks_mutex.unlockShared();

        // Update LOD manager if enabled
        if (lod_manager) |lod_mgr| {
            const velocity = Vec3.init(
                self.player_movement.dir_x * self.player_movement.speed,
                0,
                self.player_movement.dir_z * self.player_movement.speed,
            );
            try lod_mgr.update(player_pos, velocity, ChunkStorage.isChunkRenderable, self.storage);
        }
    }

    pub fn processUploads(self: *WorldStreamer, vertex_allocator: *GlobalVertexAllocator, max_uploads: usize) void {
        var uploads: usize = 0;
        while (!self.upload_queue.isEmpty() and uploads < max_uploads) {
            const key = self.upload_queue.pop() orelse break;
            if (self.storage.get(key.x, key.z)) |data| {
                if (data.chunk.state != .uploading) continue;

                data.mesh.upload(vertex_allocator);
                if (data.mesh.ready) {
                    data.chunk.state = .renderable;
                } else {
                    data.chunk.state = .mesh_ready;
                }
                uploads += 1;
            }
        }
    }

    pub fn processUnloads(self: *WorldStreamer, player_pos: Vec3, vertex_allocator: *GlobalVertexAllocator, lod_manager: ?*LODManager) !void {
        const pc = worldToChunk(@intFromFloat(player_pos.x), @intFromFloat(player_pos.z));
        const render_dist_unload = if (lod_manager) |mgr| @min(self.render_distance, mgr.config.radii[0]) else self.render_distance;
        const unload_dist_sq = (render_dist_unload + CHUNK_UNLOAD_BUFFER) * (render_dist_unload + CHUNK_UNLOAD_BUFFER);

        self.storage.chunks_mutex.lock();
        var to_remove = std.ArrayListUnmanaged(ChunkKey).empty;
        defer to_remove.deinit(self.allocator);

        var unload_iter = self.storage.iteratorUnsafe();
        while (unload_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const dx = key.x - pc.chunk_x;
            const dz = key.z - pc.chunk_z;
            if (dx * dx + dz * dz > unload_dist_sq) {
                if (data.chunk.state != .generating and data.chunk.state != .meshing and
                    !data.chunk.isPinned())
                {
                    try to_remove.append(self.allocator, key);
                }
            }
        }

        for (to_remove.items) |key| {
            _ = self.storage.removeUnlocked(key.x, key.z, vertex_allocator);
        }
        self.storage.chunks_mutex.unlock();
    }

    fn processGenJob(ctx: *anyopaque, job: Job) void {
        const self: *WorldStreamer = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const dx = cx - self.last_pc.x;
        const dz = cz - self.last_pc.z;
        const max_dist = self.render_distance + CHUNK_UNLOAD_BUFFER;
        if (dx * dx + dz * dz > max_dist * max_dist) {
            if (chunk_data.chunk.state == .generating) {
                chunk_data.chunk.state = .missing;
            }
            self.storage.chunks_mutex.unlockShared();
            return;
        }

        chunk_data.chunk.pin();
        self.storage.chunks_mutex.unlockShared();

        defer chunk_data.chunk.unpin();

        if (chunk_data.chunk.state == .generating and chunk_data.chunk.job_token == job.data.chunk.job_token) {
            self.generator.generate(&chunk_data.chunk, &self.gen_queue.abort_worker);
            if (self.gen_queue.abort_worker) {
                chunk_data.chunk.state = .missing;
                return;
            }
            chunk_data.chunk.state = .generated;
            self.markNeighborsForRemesh(cx, cz);
        }
    }

    fn processMeshJob(ctx: *anyopaque, job: Job) void {
        const self: *WorldStreamer = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const dx = cx - self.last_pc.x;
        const dz = cz - self.last_pc.z;
        const max_dist = self.render_distance + CHUNK_UNLOAD_BUFFER;
        if (dx * dx + dz * dz > max_dist * max_dist) {
            if (chunk_data.chunk.state == .meshing) {
                chunk_data.chunk.state = .generated;
            }
            self.storage.chunks_mutex.unlockShared();
            return;
        }

        chunk_data.chunk.pin();
        const neighbors = NeighborChunks{
            .north = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz - 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .south = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz + 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .east = if (self.storage.chunks.get(ChunkKey{ .x = cx + 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .west = if (self.storage.chunks.get(ChunkKey{ .x = cx - 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
        };
        self.storage.chunks_mutex.unlockShared();

        defer {
            chunk_data.chunk.unpin();
            if (neighbors.north) |n| @as(*Chunk, @constCast(n)).unpin();
            if (neighbors.south) |s| @as(*Chunk, @constCast(s)).unpin();
            if (neighbors.east) |e| @as(*Chunk, @constCast(e)).unpin();
            if (neighbors.west) |w| @as(*Chunk, @constCast(w)).unpin();
        }

        if (chunk_data.chunk.state == .meshing and chunk_data.chunk.job_token == job.data.chunk.job_token) {
            chunk_data.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
                log.log.err("Mesh build failed for chunk ({}, {}): {}", .{ cx, cz, err });
            };
            if (self.mesh_queue.abort_worker) {
                chunk_data.chunk.state = .generated;
                return;
            }
            chunk_data.chunk.state = .mesh_ready;
        }
    }

    fn markNeighborsForRemesh(self: *WorldStreamer, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();
        for (offsets) |off| {
            if (self.storage.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                if (data.chunk.state == .renderable) {
                    data.chunk.state = .generated;
                } else if (data.chunk.state == .mesh_ready or data.chunk.state == .uploading or data.chunk.state == .meshing) {
                    data.chunk.dirty = true;
                }
            }
        }
    }

    pub fn getStats(self: *WorldStreamer) struct { gen_queue: usize, mesh_queue: usize, upload_queue: usize } {
        self.gen_queue.mutex.lock();
        const gen_count = self.gen_queue.jobs.count();
        self.gen_queue.mutex.unlock();

        self.mesh_queue.mutex.lock();
        const mesh_count = self.mesh_queue.jobs.count();
        self.mesh_queue.mutex.unlock();

        return .{
            .gen_queue = gen_count,
            .mesh_queue = mesh_count,
            .upload_queue = self.upload_queue.count(),
        };
    }
};
