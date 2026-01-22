//! LOD Manager - orchestrates multi-level chunk loading for extreme render distances.
//!
//! Implements a Distant Horizons-style system where:
//! - LOD0 (0-16 chunks): Full detail, 2x2 chunks merged
//! - LOD1 (16-32 chunks): 2x simplified, 4x4 chunks merged
//! - LOD2 (32-64 chunks): 4x simplified, 8x8 chunks merged
//! - LOD3 (64-100 chunks): 8x simplified, 16x16 chunks merged, heightmap only
//!
//! Key principles:
//! - LOD3 generates first (fast heightmap), fills horizon quickly
//! - LOD0 generates last but gets priority in movement direction
//! - Smooth transitions via fog masking

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;

const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const worldToChunk = @import("chunk.zig").worldToChunk;
const BlockType = @import("block.zig").BlockType;
const BiomeId = @import("worldgen/biome.zig").BiomeId;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const Vertex = @import("../engine/graphics/rhi.zig").Vertex;
const log = @import("../engine/core/log.zig");

const JobSystem = @import("../engine/core/job_system.zig");
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;

const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;

const Generator = @import("worldgen/generator_interface.zig").Generator;
const LODMesh = @import("lod_mesh.zig").LODMesh;

const MAX_LOD_REGIONS = 2048;

comptime {
    if (LODLevel.count < 2) {
        @compileError("LOD system requires at least two levels (LOD0 and at least one simplified level)");
    }
}

/// Statistics for LOD system monitoring
pub const LODStats = struct {
    loaded: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generating: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generated: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    meshing: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_ready: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    uploading: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,

    memory_used_mb: u32 = 0,
    upgrades_pending: u32 = 0,
    downgrades_pending: u32 = 0,

    pub fn totalLoaded(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.loaded) |count| total += count;
        return total;
    }

    pub fn totalGenerating(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.generating) |count| total += count;
        return total;
    }

    pub fn reset(self: *LODStats) void {
        self.loaded = [_]u32{0} ** LODLevel.count;
        self.generating = [_]u32{0} ** LODLevel.count;
        self.generated = [_]u32{0} ** LODLevel.count;
        self.meshing = [_]u32{0} ** LODLevel.count;
        self.mesh_ready = [_]u32{0} ** LODLevel.count;
        self.uploading = [_]u32{0} ** LODLevel.count;
        self.memory_used_mb = 0;
        self.upgrades_pending = 0;
        self.downgrades_pending = 0;
    }

    pub fn recordState(self: *LODStats, lod_idx: usize, state: LODState) void {
        switch (state) {
            .renderable => self.loaded[lod_idx] += 1,
            .generating => self.generating[lod_idx] += 1,
            .generated => self.generated[lod_idx] += 1,
            .meshing => self.meshing[lod_idx] += 1,
            .mesh_ready => self.mesh_ready[lod_idx] += 1,
            .uploading => self.uploading[lod_idx] += 1,
            else => {},
        }
    }

    pub fn addMemory(self: *LODStats, bytes: usize) void {
        const mb = bytes / (1024 * 1024);
        self.memory_used_mb += @intCast(mb);
    }
};

/// LOD transition request
const LODTransition = struct {
    region_key: LODRegionKey,
    target_lod: LODLevel,
    priority: i32,
};

/// Main LOD Manager - coordinates all LOD levels
pub const LODManager = struct {
    allocator: std.mem.Allocator,
    config: LODConfig,

    // Storage per LOD level (LOD0 uses existing World.chunks)
    regions: [LODLevel.count]std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80),

    // Mesh storage per LOD level
    meshes: [LODLevel.count]std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80),

    // Separate job queues per LOD level
    // LOD3 queue processes first (fast), LOD0 queue last (slow but priority)
    gen_queues: [LODLevel.count]*JobQueue,

    // Worker pool for LOD generation
    lod_gen_pool: ?*WorkerPool,

    // Upload queues per LOD level
    upload_queues: [LODLevel.count]RingBuffer(*LODChunk),

    // Transition queue for LOD upgrades/downgrades
    transition_queue: std.ArrayListUnmanaged(LODTransition),

    // Current player position (chunk coords)
    player_cx: i32,
    player_cz: i32,

    // Next job token
    next_job_token: u32,

    // Stats
    stats: LODStats,

    // Mutex for thread safety
    mutex: std.Thread.RwLock,

    // RHI for GPU operations
    rhi: RHI,

    // Terrain generator for LOD generation (mutable for cache recentering)
    generator: Generator,

    // Paused state
    paused: bool,

    // Memory tracking
    memory_used_bytes: usize,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan optimization)
    deletion_queue: std.ArrayListUnmanaged(*LODMesh),
    deletion_timer: f32 = 0,

    // MDI
    instance_data: std.ArrayListUnmanaged(rhi_mod.InstanceData),
    draw_list: std.ArrayListUnmanaged(*LODMesh),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    frame_index: usize,

    pub fn init(allocator: std.mem.Allocator, config: LODConfig, rhi: RHI, generator: Generator) !*LODManager {
        const mgr = try allocator.create(LODManager);

        var regions: [LODLevel.count]std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80) = undefined;
        var meshes: [LODLevel.count]std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80) = undefined;
        var gen_queues: [LODLevel.count]*JobQueue = undefined;
        var upload_queues: [LODLevel.count]RingBuffer(*LODChunk) = undefined;

        for (0..LODLevel.count) |i| {
            regions[i] = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80).init(allocator);
            meshes[i] = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80).init(allocator);

            const queue = try allocator.create(JobQueue);
            queue.* = JobQueue.init(allocator);
            gen_queues[i] = queue;

            upload_queues[i] = try RingBuffer(*LODChunk).init(allocator, 32);
        }

        // Init MDI buffers (capacity for ~MAX_LOD_REGIONS LOD regions)
        const instance_buffer = try rhi.createBuffer(MAX_LOD_REGIONS * @sizeOf(rhi_mod.InstanceData), .storage);
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = instance_buffer;
        }

        mgr.* = .{
            .allocator = allocator,
            .config = config,
            .regions = regions,
            .meshes = meshes,
            .gen_queues = gen_queues,
            .lod_gen_pool = null, // Will be initialized below
            .upload_queues = upload_queues,
            .transition_queue = .empty,
            .player_cx = 0,
            .player_cz = 0,
            .next_job_token = 1,
            .stats = .{},
            .mutex = .{},
            .rhi = rhi,
            .generator = generator,
            .paused = false,
            .memory_used_bytes = 0,
            .update_tick = 0,
            .deletion_queue = .empty,
            .deletion_timer = 0,
            .instance_data = .empty,
            .draw_list = .empty,
            .instance_buffers = instance_buffers,
            .frame_index = 0,
        };

        // Initialize worker pool for LOD generation and meshing (3 workers for LOD tasks)
        // All LOD jobs go to LOD3 queue in original code, we keep it consistent but use generic index
        mgr.lod_gen_pool = try WorkerPool.init(allocator, 3, mgr.gen_queues[LODLevel.count - 1], mgr, processLODJob);

        log.log.info("LODManager initialized with radii: LOD0={}, LOD1={}, LOD2={}, LOD3={}", .{
            config.radii[0],
            config.radii[1],
            config.radii[2],
            config.radii[3],
        });

        return mgr;
    }

    pub fn deinit(self: *LODManager) void {
        // Stop and cleanup queues
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].stop();
        }

        // Cleanup worker pool
        if (self.lod_gen_pool) |pool| {
            pool.deinit();
        }

        for (0..LODLevel.count) |i| {
            self.gen_queues[i].deinit();
            self.allocator.destroy(self.gen_queues[i]);
            self.upload_queues[i].deinit();

            // Cleanup meshes
            var mesh_iter = self.meshes[i].iterator();
            while (mesh_iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.rhi);
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

        // Process any pending deletions
        if (self.deletion_queue.items.len > 0) {
            self.rhi.waitIdle();
            for (self.deletion_queue.items) |mesh| {
                mesh.deinit(self.rhi);
                self.allocator.destroy(mesh);
            }
        }
        self.deletion_queue.deinit(self.allocator);

        if (self.instance_buffers[0] != 0) self.rhi.destroyBuffer(self.instance_buffers[0]);
        for (1..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.instance_buffers[i] != 0 and self.instance_buffers[i] != self.instance_buffers[0]) {
                self.rhi.destroyBuffer(self.instance_buffers[i]);
            }
        }
        self.instance_data.deinit(self.allocator);
        self.draw_list.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Update LOD system with player position
    pub fn update(self: *LODManager, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        if (self.paused) return;

        // Deferred deletion handling (Issue #119: Performance optimization)
        // Clean up deleted meshes once per second to avoid waitIdle stalls
        self.deletion_timer += 0.016; // Approx 60fps delta
        if (self.deletion_timer >= 1.0 or self.deletion_queue.items.len > 50) {
            if (self.deletion_queue.items.len > 0) {
                // Ensure GPU is done with resources before deleting
                self.rhi.waitIdle();
                for (self.deletion_queue.items) |mesh| {
                    mesh.deinit(self.rhi);
                    self.allocator.destroy(mesh);
                }
                self.deletion_queue.clearRetainingCapacity();
            }
            self.deletion_timer = 0;
        }

        // Throttle heavy LOD management logic
        self.update_tick += 1;
        if (self.update_tick % 4 != 0) return; // Only update every 4 frames

        // Issue #211: Clean up LOD chunks that are fully covered by LOD0 (throttled)
        if (chunk_checker) |checker| {
            self.unloadLODWhereChunksLoaded(checker, checker_ctx.?);
        }

        const pc = worldToChunk(@intFromFloat(player_pos.x), @intFromFloat(player_pos.z));
        self.player_cx = pc.chunk_x;
        self.player_cz = pc.chunk_z;

        // Issue #119 Phase 4: Recenter classification cache if player moved far enough.
        // This ensures LOD chunks have cache coverage for consistent biome/surface data.
        const player_wx: i32 = @intFromFloat(player_pos.x);
        const player_wz: i32 = @intFromFloat(player_pos.z);
        _ = self.generator.maybeRecenterCache(player_wx, player_wz);

        // Queue LOD regions that need loading (also queue on first frame)
        // Priority: LOD3 first (fast, fills horizon), then LOD2, LOD1
        // We iterate backwards from LODLevel.count-1 down to 1
        var i: usize = LODLevel.count - 1;
        while (i > 0) : (i -= 1) {
            try self.queueLODRegions(@enumFromInt(@as(u3, @intCast(i))), player_velocity);
        }

        // Process state transitions
        try self.processStateTransitions();

        // Process uploads (limited per frame)
        self.processUploads();

        // Update stats
        self.updateStats();

        // Unload distant regions
        try self.unloadDistantRegions();

        // Issue #211: Clean up LOD chunks that are fully covered by LOD0 (throttled)
        if (chunk_checker) |checker| {
            self.unloadLODWhereChunksLoaded(checker, checker_ctx.?);
        }
    }

    /// Queue LOD regions that need generation
    fn queueLODRegions(self: *LODManager, lod: LODLevel, velocity: Vec3) !void {
        const radius = self.config.radii[@intFromEnum(lod)];

        // Skip LOD0 - handled by existing World system
        if (lod == .lod0) return;

        var queued_count: u32 = 0;

        const scale: i32 = @intCast(lod.chunksPerSide());
        const region_radius = @divFloor(radius, scale) + 1;

        const player_rx = @divFloor(self.player_cx, scale);
        const player_rz = @divFloor(self.player_cz, scale);

        self.mutex.lock();
        defer self.mutex.unlock();

        const storage = &self.regions[@intFromEnum(lod)];

        // All LOD jobs go to LOD3 queue (worker pool processes from there)
        // We encode the actual LOD level in the dist_sq high bits
        const queue = self.gen_queues[LODLevel.count - 1];
        const lod_bits: i32 = @as(i32, @intCast(@intFromEnum(lod))) << 28;

        // Calculate velocity direction for priority
        const vel_len = @sqrt(velocity.x * velocity.x + velocity.z * velocity.z);
        const has_velocity = vel_len > 0.1;
        const vel_dx: f32 = if (has_velocity) velocity.x / vel_len else 0;
        const vel_dz: f32 = if (has_velocity) velocity.z / vel_len else 0;

        var rz = player_rz - region_radius;
        while (rz <= player_rz + region_radius) : (rz += 1) {
            var rx = player_rx - region_radius;
            while (rx <= player_rx + region_radius) : (rx += 1) {
                // Check circular distance to avoid thrashing corner chunks
                const dx = rx - player_rx;
                const dz = rz - player_rz;
                if (dx * dx + dz * dz > region_radius * region_radius) continue;

                const key = LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };

                // Check if region exists and what state it's in
                const existing = storage.get(key);
                const needs_queue = if (existing) |chunk|
                    // Re-queue if stuck in missing state
                    chunk.state == .missing
                else
                    // Queue if doesn't exist
                    true;

                if (needs_queue) {
                    queued_count += 1;

                    // Reuse existing chunk or create new one
                    const chunk = if (existing) |c| c else blk: {
                        const c = try self.allocator.create(LODChunk);
                        c.* = LODChunk.init(rx, rz, lod);
                        try storage.put(key, c);
                        break :blk c;
                    };

                    chunk.job_token = self.next_job_token;
                    self.next_job_token += 1;

                    // Calculate velocity-weighted priority
                    // (dx, dz calculated above)
                    const dist_sq = dx * dx + dz * dz;
                    // Scale priority to match chunk-distance units used by meshing jobs (which are prioritized by chunk dist)
                    // This ensures generation doesn't starve meshing
                    var priority = dist_sq * scale * scale;
                    if (has_velocity) {
                        const fdx: f32 = @floatFromInt(dx);
                        const fdz: f32 = @floatFromInt(dz);
                        const dist = @sqrt(fdx * fdx + fdz * fdz);
                        if (dist > 0.01) {
                            const dot = (fdx * vel_dx + fdz * vel_dz) / dist;
                            // Ahead = lower priority number, behind = higher
                            const weight = 1.0 - dot * 0.5;
                            priority = @intFromFloat(@as(f32, @floatFromInt(priority)) * weight);
                        }
                    }

                    // Encode LOD level in high bits of dist_sq
                    const encoded_priority = (priority & 0x0FFFFFFF) | lod_bits;

                    // Queue for generation
                    try queue.push(.{
                        .type = .chunk_generation,
                        .dist_sq = encoded_priority,
                        .data = .{
                            .chunk = .{
                                .x = rx, // Using chunk coords for region coords
                                .z = rz,
                                .job_token = chunk.job_token,
                            },
                        },
                    });
                    chunk.state = .generating; // Mark as generating, not queued_for_generation
                }
            }
        }
    }

    /// Process state transitions (generated -> meshing -> ready)
    fn processStateTransitions(self: *LODManager) !void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        for (1..LODLevel.count) |i| {
            const lod = @as(LODLevel, @enumFromInt(@as(u3, @intCast(i))));
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                if (chunk.state == .generated) {
                    const scale = @as(i32, @intCast(lod.chunksPerSide()));
                    const dx = chunk.region_x * scale - self.player_cx;
                    const dz = chunk.region_z * scale - self.player_cz;
                    const dist_sq = dx * dx + dz * dz;

                    chunk.state = .meshing;
                    try self.gen_queues[LODLevel.count - 1].push(.{
                        .type = .chunk_meshing,
                        .dist_sq = (dist_sq & 0x0FFFFFFF) | (@as(i32, @intCast(@intFromEnum(lod))) << 28),
                        .data = .{
                            .chunk = .{
                                .x = chunk.region_x,
                                .z = chunk.region_z,
                                .job_token = chunk.job_token,
                            },
                        },
                    });
                } else if (chunk.state == .mesh_ready) {
                    chunk.state = .uploading;
                    try self.upload_queues[i].push(chunk);
                }
            }
        }
    }

    /// Process GPU uploads (limited per frame)
    fn processUploads(self: *LODManager) void {
        const max_uploads = self.config.max_uploads_per_frame;
        var uploads: u32 = 0;

        // Process from highest LOD down (furthest, should be ready first)
        var i: usize = LODLevel.count - 1;
        while (i > 0) : (i -= 1) {
            while (!self.upload_queues[i].isEmpty() and uploads < max_uploads) {
                if (self.upload_queues[i].pop()) |chunk| {
                    // Upload mesh to GPU
                    const key = LODRegionKey{
                        .rx = chunk.region_x,
                        .rz = chunk.region_z,
                        .lod = chunk.lod_level,
                    };
                    if (self.meshes[i].get(key)) |mesh| {
                        mesh.upload(self.rhi) catch |err| {
                            log.log.err("Failed to upload LOD{} mesh: {}", .{ i, err });
                            continue;
                        };
                    }
                    chunk.state = .renderable;
                    uploads += 1;
                }
            }
        }
    }

    /// Unload regions that are too far from player
    fn unloadDistantRegions(self: *LODManager) !void {
        for (1..LODLevel.count) |i| {
            try self.unloadDistantForLevel(@enumFromInt(@as(u3, @intCast(i))), self.config.radii[i]);
        }
    }

    fn unloadDistantForLevel(self: *LODManager, lod: LODLevel, max_radius: i32) !void {
        const storage = &self.regions[@intFromEnum(lod)];

        const scale: i32 = @intCast(lod.chunksPerSide());
        const player_rx = @divFloor(self.player_cx, scale);
        const player_rz = @divFloor(self.player_cz, scale);

        // Use same +1 buffer as queuing to match radius exactly
        const region_radius = @divFloor(max_radius, scale) + 1;

        var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
        defer to_remove.deinit(self.allocator);

        self.mutex.lock();
        var iter = storage.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const chunk = entry.value_ptr.*;

            const dx = key.rx - player_rx;
            const dz = key.rz - player_rz;

            if (dx * dx + dz * dz > region_radius * region_radius) {
                if (!chunk.isPinned() and
                    chunk.state != .generating and
                    chunk.state != .meshing and
                    chunk.state != .uploading)
                {
                    try to_remove.append(self.allocator, key);
                }
            }
        }
        self.mutex.unlock();

        // Remove outside of iteration
        if (to_remove.items.len > 0) {
            for (to_remove.items) |key| {
                if (storage.get(key)) |chunk| {
                    // Clean up mesh before removing chunk
                    const meshes = &self.meshes[@intFromEnum(lod)];
                    if (meshes.get(key)) |mesh| {
                        // Push to deferred deletion queue instead of deleting immediately
                        self.deletion_queue.append(self.allocator, mesh) catch {
                            // Fallback if allocation fails: delete immediately (slow but safe)
                            mesh.deinit(self.rhi);
                            self.allocator.destroy(mesh);
                        };
                        _ = meshes.remove(key);
                    }

                    chunk.deinit(self.allocator);
                    self.allocator.destroy(chunk);
                    _ = storage.remove(key);
                }
            }
        }
    }

    /// Update statistics
    fn updateStats(self: *LODManager) void {
        self.stats.reset();
        var mem_usage: usize = 0;

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        for (0..LODLevel.count) |i| {
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                self.stats.recordState(i, chunk.state);

                // Calculate actual memory usage for this chunk's data
                switch (chunk.data) {
                    .simplified => |*s| {
                        mem_usage += s.totalMemoryBytes();
                    },
                    else => {},
                }
            }

            // Add mesh memory
            var mesh_iter = self.meshes[i].iterator();
            while (mesh_iter.next()) |entry| {
                mem_usage += entry.value_ptr.*.capacity * @sizeOf(Vertex);
            }
        }

        self.stats.addMemory(mem_usage);
        self.memory_used_bytes = mem_usage;
    }

    /// Get current statistics
    pub fn getStats(self: *LODManager) LODStats {
        return self.stats;
    }

    /// Pause all LOD generation
    pub fn pause(self: *LODManager) void {
        self.paused = true;
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].setPaused(true);
        }
    }

    /// Resume LOD generation
    pub fn unpause(self: *LODManager) void {
        self.paused = false;
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].setPaused(false);
        }
    }

    /// Get LOD level for a given chunk distance
    pub fn getLODForDistance(self: *const LODManager, chunk_x: i32, chunk_z: i32) LODLevel {
        const dx = chunk_x - self.player_cx;
        const dz = chunk_z - self.player_cz;
        const dist = @max(@abs(dx), @abs(dz));
        return self.config.getLODForDistance(dist);
    }

    /// Check if a position is within LOD range
    pub fn isInRange(self: *const LODManager, chunk_x: i32, chunk_z: i32) bool {
        const dx = chunk_x - self.player_cx;
        const dz = chunk_z - self.player_cz;
        const dist = @max(@abs(dx), @abs(dz));
        return self.config.isInRange(dist);
    }

    /// Callback type to check if a regular chunk is loaded and renderable
    pub const ChunkChecker = *const fn (chunk_x: i32, chunk_z: i32, ctx: *anyopaque) bool;

    /// Render all LOD meshes
    /// chunk_checker: Optional callback to check if regular chunks cover this region.
    ///                If all chunks in region are loaded, the LOD region is skipped.
    pub fn render(self: *LODManager, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const frustum = Frustum.fromViewProj(view_proj);
        const lod_y_offset: f32 = -3.0;

        self.instance_data.clearRetainingCapacity();
        self.draw_list.clearRetainingCapacity();

        // Collect visible meshes
        // Process from highest LOD down
        var i: usize = LODLevel.count - 1;
        while (i > 0) : (i -= 1) {
            self.collectVisibleMeshes(&self.meshes[i], &self.regions[i], view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx) catch |err| {
                log.log.err("Failed to collect visible meshes for LOD{}: {}", .{ i, err });
            };
        }

        if (self.instance_data.items.len == 0) return;

        for (self.draw_list.items, 0..) |mesh, idx| {
            const instance = self.instance_data.items[idx];
            self.rhi.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
            self.rhi.draw(mesh.buffer_handle, mesh.vertex_count, .triangles);
        }
    }

    fn collectVisibleMeshes(self: *LODManager, meshes: *std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80), regions: *std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80), view_proj: Mat4, camera_pos: Vec3, frustum: Frustum, lod_y_offset: f32, _: ?ChunkChecker, _: ?*anyopaque) !void {
        var iter = meshes.iterator();
        while (iter.next()) |entry| {
            const mesh = entry.value_ptr.*;
            if (!mesh.ready or mesh.vertex_count == 0) continue;
            if (regions.get(entry.key_ptr.*)) |chunk| {
                if (chunk.state != .renderable) continue;
                const bounds = chunk.worldBounds();

                // Issue #211: removed expensive areAllChunksLoaded check from render.
                // Throttled cleanup in update handles this, and shader masking handles partial overlaps.

                const aabb_min = Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, 0.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z);
                const aabb_max = Vec3.init(@as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, 256.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z);
                if (!frustum.intersectsAABB(AABB.init(aabb_min, aabb_max))) continue;

                const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                try self.instance_data.append(self.allocator, .{
                    .view_proj = view_proj,
                    .model = model,
                    .mask_radius = @floatFromInt(self.config.radii[0]),
                    .padding = .{ 0, 0, 0 },
                });
                try self.draw_list.append(self.allocator, mesh);
            }
        }
    }

    /// Free LOD meshes where all underlying chunks are loaded
    fn unloadLODWhereChunksLoaded(self: *LODManager, checker: ChunkChecker, ctx: *anyopaque) void {
        for (1..LODLevel.count) |i| {
            const storage = &self.regions[i];
            const meshes = &self.meshes[i];

            var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
            defer to_remove.deinit(self.allocator);

            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                if (storage.get(entry.key_ptr.*)) |chunk| {
                    // Don't unload if being processed (pinned) or not ready
                    if (chunk.isPinned() or chunk.state == .generating or chunk.state == .meshing or chunk.state == .uploading) continue;

                    const bounds = chunk.worldBounds();
                    if (self.areAllChunksLoaded(bounds, checker, ctx)) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                    }
                }
            }

            for (to_remove.items) |key| {
                if (meshes.fetchRemove(key)) |mesh_entry| {
                    // Queue for deferred deletion to avoid waitIdle stutter
                    self.deletion_queue.append(self.allocator, mesh_entry.value) catch {
                        mesh_entry.value.deinit(self.rhi);
                        self.allocator.destroy(mesh_entry.value);
                    };
                }
                if (storage.fetchRemove(key)) |chunk_entry| {
                    chunk_entry.value.deinit(self.allocator);
                    self.allocator.destroy(chunk_entry.value);
                }
            }
        }
    }

    /// Check if all chunks within the given world bounds are loaded and renderable
    fn areAllChunksLoaded(self: *LODManager, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
        _ = self;
        // Convert world bounds to chunk coordinates
        const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X);
        const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_X);
        const max_cx = @divFloor(bounds.max_x - 1, CHUNK_SIZE_X); // -1 because max is exclusive
        const max_cz = @divFloor(bounds.max_z - 1, CHUNK_SIZE_X);

        // Check every chunk in the region
        var cz = min_cz;
        while (cz <= max_cz) : (cz += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                if (!checker(cx, cz, ctx)) {
                    return false; // At least one chunk is not loaded
                }
            }
        }
        return true; // All chunks are loaded
    }

    /// Get or create mesh for a LOD region
    fn getOrCreateMesh(self: *LODManager, key: LODRegionKey) !*LODMesh {
        self.mutex.lock();
        defer self.mutex.unlock();

        const lod_idx = @intFromEnum(key.lod);
        if (lod_idx == 0 or lod_idx >= LODLevel.count) return error.InvalidLODLevel;

        const meshes = &self.meshes[lod_idx];

        if (meshes.get(key)) |mesh| {
            return mesh;
        }

        const mesh = try self.allocator.create(LODMesh);
        mesh.* = LODMesh.init(self.allocator, key.lod);
        try meshes.put(key, mesh);
        return mesh;
    }

    /// Build mesh for an LOD chunk (called after generation completes)
    fn buildMeshForChunk(self: *LODManager, chunk: *LODChunk) !void {
        const key = LODRegionKey{
            .rx = chunk.region_x,
            .rz = chunk.region_z,
            .lod = chunk.lod_level,
        };

        const mesh = try self.getOrCreateMesh(key);

        switch (chunk.data) {
            .simplified => |*data| {
                const bounds = chunk.worldBounds();
                try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z);
            },
            .full => {
                // LOD0 meshes handled by World, not LODManager
            },
            .empty => {
                // No data to build mesh from
            },
        }
    }
};

/// Worker pool callback for LOD tasks (generation and meshing)
fn processLODJob(ctx: *anyopaque, job: Job) void {
    const self: *LODManager = @ptrCast(@alignCast(ctx));

    // Determine which LOD level this job is for based on encoded priority
    const lod_level: LODLevel = @enumFromInt(@as(u3, @intCast((job.dist_sq >> 28) & 0x7)));
    const key = LODRegionKey{
        .rx = job.data.chunk.x,
        .rz = job.data.chunk.z,
        .lod = lod_level,
    };

    self.mutex.lockShared();
    const lod_idx = @intFromEnum(lod_level);
    if (lod_idx == 0) {
        self.mutex.unlockShared();
        return;
    }
    const storage = &self.regions[lod_idx];

    const chunk = storage.get(key) orelse {
        self.mutex.unlockShared();
        return;
    };

    // Stale job check (too far from player)
    const scale: i32 = @intCast(lod_level.chunksPerSide());
    const player_rx = @divFloor(self.player_cx, scale);
    const player_rz = @divFloor(self.player_cz, scale);
    const dx = job.data.chunk.x - player_rx;
    const dz = job.data.chunk.z - player_rz;
    const radius = self.config.radii[lod_idx];
    const region_radius = @divFloor(radius, scale) + 2;

    if (dx * dx + dz * dz > region_radius * region_radius) {
        if (chunk.state == .generating or chunk.state == .meshing) {
            chunk.state = .missing;
        }
        self.mutex.unlockShared();
        return;
    }

    // Pin chunk during operation
    chunk.pin();
    self.mutex.unlockShared();
    defer chunk.unpin();

    // Skip if token mismatch
    if (chunk.job_token != job.data.chunk.job_token) return;

    switch (job.type) {
        .chunk_generation => {
            if (chunk.state != .generating) return;

            // Initialize simplified data if needed
            if (chunk.data != .simplified) {
                var data = LODSimplifiedData.init(self.allocator, lod_level) catch {
                    chunk.state = .missing;
                    return;
                };

                // Generate heightmap data
                self.generator.generateHeightmapOnly(&data, chunk.region_x, chunk.region_z, lod_level);
                chunk.data = .{ .simplified = data };
            }
            chunk.state = .generated;
        },
        .chunk_meshing => {
            if (chunk.state != .meshing) return;

            self.buildMeshForChunk(chunk) catch |err| {
                log.log.err("Failed to build LOD{} async mesh: {}", .{ @intFromEnum(lod_level), err });
                chunk.state = .generated; // Retry later
                return;
            };
            chunk.state = .mesh_ready;
        },
        else => unreachable,
    }
}

// Tests
test "LODManager initialization" {
    const allocator = std.testing.allocator;

    // We can't fully test without RHI, but we can test the config
    const config = LODConfig{
        .radii = .{ 8, 16, 32, 64 },
    };

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(5));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(12));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(24));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(50));

    _ = allocator;
}

test "LODStats aggregation" {
    var stats = LODStats{};
    stats.recordState(1, .renderable);
    stats.recordState(1, .renderable);
    stats.recordState(2, .generating);

    try std.testing.expectEqual(@as(u32, 2), stats.loaded[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.generating[2]);
    try std.testing.expectEqual(@as(u32, 2), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 1), stats.totalGenerating());

    stats.addMemory(2 * 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 2), stats.memory_used_mb);

    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.memory_used_mb);
}

test "LODManager constants" {
    try std.testing.expect(MAX_LOD_REGIONS > 0);
    try std.testing.expect(LODLevel.count >= 2);
}
