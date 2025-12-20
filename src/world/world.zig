//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const BlockType = @import("block.zig").BlockType;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToLocal = @import("chunk.zig").worldToLocal;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const TerrainGenerator = @import("worldgen/generator.zig").TerrainGenerator;

const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const Shader = @import("../engine/graphics/shader.zig").Shader;

const JobSystem = @import("../engine/core/job_system.zig");
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;
const JobType = JobSystem.JobType;

pub const ChunkKey = struct {
    x: i32,
    z: i32,

    pub fn hash(self: ChunkKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.x));
        const uz: u64 = @bitCast(@as(i64, self.z));
        return ux ^ (uz *% 0x9e3779b97f4a7c15);
    }

    pub fn eql(a: ChunkKey, b: ChunkKey) bool {
        return a.x == b.x and a.z == b.z;
    }
};

const ChunkKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkKey) u64 {
        _ = self;
        return key.hash();
    }

    pub fn eql(self: @This(), a: ChunkKey, b: ChunkKey) bool {
        _ = self;
        return a.eql(b);
    }
};

pub const ChunkData = struct {
    chunk: Chunk,
    mesh: ChunkMesh,
};

pub const ChunkPos = struct { x: i32, z: i32 };

pub const RenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
};

pub const World = struct {
    chunks: std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80),
    chunks_mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    generator: TerrainGenerator,
    render_distance: i32,
    last_render_stats: RenderStats,
    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    gen_pool: *WorkerPool,
    mesh_pool: *WorkerPool,
    upload_queue: std.ArrayListUnmanaged(*ChunkData),
    next_job_token: u32,
    last_pc: ChunkPos,

    pub fn init(allocator: std.mem.Allocator, render_distance: i32, seed: u64) !*World {
        const world = try allocator.create(World);

        const gen_queue = try allocator.create(JobQueue);
        gen_queue.* = JobQueue.init(allocator);

        const mesh_queue = try allocator.create(JobQueue);
        mesh_queue.* = JobQueue.init(allocator);

        world.* = .{
            .chunks = std.HashMap(ChunkKey, *ChunkData, ChunkKeyContext, 80).init(allocator),
            .chunks_mutex = .{},
            .allocator = allocator,
            .render_distance = render_distance,
            .generator = TerrainGenerator.init(seed),
            .last_render_stats = .{},
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .gen_pool = undefined,
            .mesh_pool = undefined,
            .upload_queue = .empty,
            .next_job_token = 1,
            .last_pc = .{ .x = 9999, .z = 9999 },
        };

        world.gen_pool = try WorkerPool.init(allocator, 2, gen_queue, world, processGenJob);
        world.mesh_pool = try WorkerPool.init(allocator, 2, mesh_queue, world, processMeshJob);

        return world;
    }

    pub fn deinit(self: *World) void {
        self.gen_queue.stop();
        self.mesh_queue.stop();

        self.gen_pool.deinit();
        self.mesh_pool.deinit();

        self.gen_queue.deinit();
        self.mesh_queue.deinit();
        self.allocator.destroy(self.gen_queue);
        self.allocator.destroy(self.mesh_queue);

        self.upload_queue.deinit(self.allocator);

        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.mesh.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.chunks.deinit();
        self.allocator.destroy(self);
    }

    fn processGenJob(ctx: *anyopaque, job: Job) void {
        const self: *World = @ptrCast(@alignCast(ctx));

        self.chunks_mutex.lock();
        const chunk_data = self.chunks.get(ChunkKey{ .x = job.chunk_x, .z = job.chunk_z }) orelse {
            self.chunks_mutex.unlock();
            return;
        };
        chunk_data.chunk.pin();
        self.chunks_mutex.unlock();

        defer chunk_data.chunk.unpin();

        if (chunk_data.chunk.state == .generating and chunk_data.chunk.job_token == job.job_token) {
            self.generator.generate(&chunk_data.chunk);
            chunk_data.chunk.state = .generated;
            self.markNeighborsForRemesh(job.chunk_x, job.chunk_z);
        }
    }

    fn processMeshJob(ctx: *anyopaque, job: Job) void {
        const self: *World = @ptrCast(@alignCast(ctx));

        self.chunks_mutex.lock();
        const chunk_data = self.chunks.get(ChunkKey{ .x = job.chunk_x, .z = job.chunk_z }) orelse {
            self.chunks_mutex.unlock();
            return;
        };

        chunk_data.chunk.pin();
        const neighbors = NeighborChunks{
            .north = if (self.chunks.get(ChunkKey{ .x = job.chunk_x, .z = job.chunk_z - 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .south = if (self.chunks.get(ChunkKey{ .x = job.chunk_x, .z = job.chunk_z + 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .east = if (self.chunks.get(ChunkKey{ .x = job.chunk_x + 1, .z = job.chunk_z })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .west = if (self.chunks.get(ChunkKey{ .x = job.chunk_x - 1, .z = job.chunk_z })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
        };
        self.chunks_mutex.unlock();

        defer {
            chunk_data.chunk.unpin();
            if (neighbors.north) |n| @as(*Chunk, @constCast(n)).unpin();
            if (neighbors.south) |s| @as(*Chunk, @constCast(s)).unpin();
            if (neighbors.east) |e| @as(*Chunk, @constCast(e)).unpin();
            if (neighbors.west) |w| @as(*Chunk, @constCast(w)).unpin();
        }

        if (chunk_data.chunk.state == .meshing and chunk_data.chunk.job_token == job.job_token) {
            chunk_data.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors) catch {};
            chunk_data.chunk.state = .mesh_ready;
        }
    }

    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();

        const key = ChunkKey{ .x = chunk_x, .z = chunk_z };
        if (self.chunks.get(key)) |data| return data;

        const data = try self.allocator.create(ChunkData);
        data.* = .{
            .chunk = Chunk.init(chunk_x, chunk_z),
            .mesh = ChunkMesh.init(self.allocator),
        };
        data.chunk.job_token = self.next_job_token;
        self.next_job_token += 1;
        try self.chunks.put(key, data);
        return data;
    }

    fn markNeighborsForRemesh(self: *World, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();
        for (offsets) |off| {
            if (self.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                // Only trigger remesh if the chunk is already in a stable state.
                // If it's currently meshing or uploading, we mark it as dirty so it
                // remeshes on the next update cycle after it reaches 'renderable'.
                if (data.chunk.state == .renderable) {
                    data.chunk.state = .generated;
                } else if (data.chunk.state == .mesh_ready or data.chunk.state == .uploading or data.chunk.state == .meshing) {
                    data.chunk.dirty = true;
                }
            }
        }
    }

    pub fn getBlock(self: *World, world_x: i32, world_y: i32, world_z: i32) BlockType {
        if (world_y < 0 or world_y >= 256) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        if (world_y < 0 or world_y >= 256) return;
        const cp = worldToChunk(world_x, world_z);
        const data = try self.getOrCreateChunk(cp.chunk_x, cp.chunk_z);
        const local = worldToLocal(world_x, world_z);
        data.chunk.setBlock(local.x, @intCast(world_y), local.z, block);
    }

    pub fn update(self: *World, player_pos: Vec3) !void {
        const pc = worldToChunk(@intFromFloat(player_pos.x), @intFromFloat(player_pos.z));
        const moved = pc.chunk_x != self.last_pc.x or pc.chunk_z != self.last_pc.z;

        if (moved) {
            self.last_pc = .{ .x = pc.chunk_x, .z = pc.chunk_z };

            var cz = pc.chunk_z - self.render_distance;
            while (cz <= pc.chunk_z + self.render_distance) : (cz += 1) {
                var cx = pc.chunk_x - self.render_distance;
                while (cx <= pc.chunk_x + self.render_distance) : (cx += 1) {
                    const dx = cx - pc.chunk_x;
                    const dz = cz - pc.chunk_z;
                    const dist_sq = dx * dx + dz * dz;

                    if (dist_sq > self.render_distance * self.render_distance) continue;

                    const data = try self.getOrCreateChunk(cx, cz);

                    switch (data.chunk.state) {
                        .missing => {
                            data.chunk.state = .generating;
                            try self.gen_queue.push(.{
                                .type = .generation,
                                .chunk_x = cx,
                                .chunk_z = cz,
                                .job_token = data.chunk.job_token,
                                .dist_sq = dist_sq,
                            });
                        },
                        else => {},
                    }
                }
            }
        }

        self.chunks_mutex.lock();
        var mesh_iter = self.chunks.iterator();
        while (mesh_iter.next()) |entry| {
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                const dx = data.chunk.chunk_x - pc.chunk_x;
                const dz = data.chunk.chunk_z - pc.chunk_z;
                if (dx * dx + dz * dz <= self.render_distance * self.render_distance) {
                    data.chunk.state = .meshing;
                    try self.mesh_queue.push(.{
                        .type = .meshing,
                        .chunk_x = data.chunk.chunk_x,
                        .chunk_z = data.chunk.chunk_z,
                        .job_token = data.chunk.job_token,
                        .dist_sq = dx * dx + dz * dz,
                    });
                }
            } else if (data.chunk.state == .mesh_ready) {
                data.chunk.state = .uploading;
                try self.upload_queue.append(self.allocator, data);
            } else if (data.chunk.state == .renderable and data.chunk.dirty) {
                data.chunk.dirty = false;
                data.chunk.state = .generated;
            }
        }
        self.chunks_mutex.unlock();

        if (self.upload_queue.items.len > 0) {
            const data = self.upload_queue.orderedRemove(0);
            data.mesh.upload();
            // Only transition to renderable if we were still in the uploading state.
            // If we were set back to .generated, we stay there.
            if (data.chunk.state == .uploading) {
                data.chunk.state = .renderable;
            }
        }

        const unload_dist_sq = (self.render_distance + 2) * (self.render_distance + 2);
        self.chunks_mutex.lock();
        var to_remove = std.ArrayListUnmanaged(ChunkKey).empty;
        defer to_remove.deinit(self.allocator);

        var unload_iter = self.chunks.iterator();
        while (unload_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const dx = key.x - pc.chunk_x;
            const dz = key.z - pc.chunk_z;
            if (dx * dx + dz * dz > unload_dist_sq) {
                // Only unload if not currently being processed by a worker or in the upload queue.
                // ALSO check the pin_count to ensure no neighbor lookups are active.
                if (data.chunk.state != .generating and data.chunk.state != .meshing and
                    data.chunk.state != .mesh_ready and data.chunk.state != .uploading and
                    !data.chunk.isPinned())
                {
                    try to_remove.append(self.allocator, key);
                }
            }
        }

        for (to_remove.items) |key| {
            if (self.chunks.get(key)) |data| {
                data.mesh.deinit();
                self.allocator.destroy(data);
                _ = self.chunks.remove(key);
            }
        }
        self.chunks_mutex.unlock();
    }

    pub fn render(self: *World, shader: *const Shader, view_proj: Mat4) void {
        const frustum = Frustum.fromViewProj(view_proj);
        self.last_render_stats = .{};

        self.chunks_mutex.lock();
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;

            if (data.chunk.state != .renderable) continue;

            self.last_render_stats.chunks_total += 1;
            if (!frustum.intersectsChunk(key.x, key.z)) {
                self.last_render_stats.chunks_culled += 1;
                continue;
            }

            self.last_render_stats.chunks_rendered += 1;
            for (data.mesh.subchunks) |s| {
                self.last_render_stats.vertices_rendered += s.count_solid;
            }

            shader.setMat4("transform", &view_proj.data);
            data.mesh.draw(.solid);
        }

        // Fluid pass
        iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            const data = entry.value_ptr.*;
            if (data.chunk.state != .renderable) continue;
            const key = entry.key_ptr.*;
            if (!frustum.intersectsChunk(key.x, key.z)) continue;

            for (data.mesh.subchunks) |s| {
                self.last_render_stats.vertices_rendered += s.count_fluid;
            }

            shader.setMat4("transform", &view_proj.data);
            data.mesh.draw(.fluid);
        }

        self.chunks_mutex.unlock();
    }

    pub fn getRenderStats(self: *const World) RenderStats {
        return self.last_render_stats;
    }

    pub fn getStats(self: *World) struct { chunks_loaded: usize, total_vertices: u64, gen_queue: usize, mesh_queue: usize, upload_queue: usize } {
        self.chunks_mutex.lock();
        defer self.chunks_mutex.unlock();
        var total_verts: u64 = 0;
        var iter = self.chunks.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.*.mesh.subchunks) |s| {
                total_verts += s.count_solid + s.count_fluid;
            }
        }

        self.gen_queue.mutex.lock();
        const gen_count = self.gen_queue.jobs.count();
        self.gen_queue.mutex.unlock();

        self.mesh_queue.mutex.lock();
        const mesh_count = self.mesh_queue.jobs.count();
        self.mesh_queue.mutex.unlock();

        return .{
            .chunks_loaded = self.chunks.count(),
            .total_vertices = total_verts,
            .gen_queue = gen_count,
            .mesh_queue = mesh_count,
            .upload_queue = self.upload_queue.items.len,
        };
    }
};
