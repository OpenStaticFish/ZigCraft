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
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const Vertex = @import("../engine/graphics/rhi.zig").Vertex;
const log = @import("../engine/core/log.zig");

const JobSystem = @import("../engine/core/job_system.zig");
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;

const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;

const TerrainGenerator = @import("worldgen/generator.zig").TerrainGenerator;
const LODMesh = @import("lod_mesh.zig").LODMesh;

/// Statistics for LOD system monitoring
pub const LODStats = struct {
    lod0_loaded: u32 = 0,
    lod1_loaded: u32 = 0,
    lod2_loaded: u32 = 0,
    lod3_loaded: u32 = 0,
    lod0_generating: u32 = 0,
    lod1_generating: u32 = 0,
    lod2_generating: u32 = 0,
    lod3_generating: u32 = 0,
    memory_used_mb: u32 = 0,
    upgrades_pending: u32 = 0,
    downgrades_pending: u32 = 0,

    pub fn totalLoaded(self: *const LODStats) u32 {
        return self.lod0_loaded + self.lod1_loaded + self.lod2_loaded + self.lod3_loaded;
    }

    pub fn totalGenerating(self: *const LODStats) u32 {
        return self.lod0_generating + self.lod1_generating + self.lod2_generating + self.lod3_generating;
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
    lod1_regions: std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80),
    lod2_regions: std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80),
    lod3_regions: std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80),

    // Mesh storage per LOD level
    lod1_meshes: std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80),
    lod2_meshes: std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80),
    lod3_meshes: std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80),

    // Separate job queues per LOD level
    // LOD3 queue processes first (fast), LOD0 queue last (slow but priority)
    lod1_gen_queue: *JobQueue,
    lod2_gen_queue: *JobQueue,
    lod3_gen_queue: *JobQueue,

    // Worker pool for LOD generation
    lod_gen_pool: ?*WorkerPool,

    // Upload queues per LOD level
    lod1_upload_queue: RingBuffer(*LODChunk),
    lod2_upload_queue: RingBuffer(*LODChunk),
    lod3_upload_queue: RingBuffer(*LODChunk),

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
    generator: *TerrainGenerator,

    // Paused state
    paused: bool,

    // Memory tracking
    memory_used_bytes: usize,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan/GL optimization)
    deletion_queue: std.ArrayListUnmanaged(*LODMesh),
    deletion_timer: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: LODConfig, rhi: RHI, generator: *TerrainGenerator) !*LODManager {
        const mgr = try allocator.create(LODManager);

        // Create job queues for each LOD level
        const lod1_queue = try allocator.create(JobQueue);
        lod1_queue.* = JobQueue.init(allocator);

        const lod2_queue = try allocator.create(JobQueue);
        lod2_queue.* = JobQueue.init(allocator);

        const lod3_queue = try allocator.create(JobQueue);
        lod3_queue.* = JobQueue.init(allocator);

        mgr.* = .{
            .allocator = allocator,
            .config = config,
            .lod1_regions = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80).init(allocator),
            .lod2_regions = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80).init(allocator),
            .lod3_regions = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80).init(allocator),
            .lod1_meshes = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80).init(allocator),
            .lod2_meshes = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80).init(allocator),
            .lod3_meshes = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80).init(allocator),
            .lod1_gen_queue = lod1_queue,
            .lod2_gen_queue = lod2_queue,
            .lod3_gen_queue = lod3_queue,
            .lod_gen_pool = null, // Will be initialized below
            .lod1_upload_queue = try RingBuffer(*LODChunk).init(allocator, 32),
            .lod2_upload_queue = try RingBuffer(*LODChunk).init(allocator, 32),
            .lod3_upload_queue = try RingBuffer(*LODChunk).init(allocator, 32),
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
        };

        // Initialize worker pool for LOD generation and meshing (3 workers for LOD tasks)
        mgr.lod_gen_pool = try WorkerPool.init(allocator, 3, lod3_queue, mgr, processLODJob);

        log.log.info("LODManager initialized with radii: LOD0={}, LOD1={}, LOD2={}, LOD3={}", .{
            config.lod0_radius,
            config.lod1_radius,
            config.lod2_radius,
            config.lod3_radius,
        });

        return mgr;
    }

    pub fn deinit(self: *LODManager) void {
        // Stop queues
        self.lod1_gen_queue.stop();
        self.lod2_gen_queue.stop();
        self.lod3_gen_queue.stop();

        // Cleanup worker pool
        if (self.lod_gen_pool) |pool| {
            pool.deinit();
        }

        // Cleanup queues
        self.lod1_gen_queue.deinit();
        self.lod2_gen_queue.deinit();
        self.lod3_gen_queue.deinit();
        self.allocator.destroy(self.lod1_gen_queue);
        self.allocator.destroy(self.lod2_gen_queue);
        self.allocator.destroy(self.lod3_gen_queue);

        // Cleanup upload queues
        self.lod1_upload_queue.deinit();
        self.lod2_upload_queue.deinit();
        self.lod3_upload_queue.deinit();

        // Cleanup meshes
        var mesh_iter1 = self.lod1_meshes.iterator();
        while (mesh_iter1.next()) |entry| {
            entry.value_ptr.*.deinit(self.rhi);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod1_meshes.deinit();

        var mesh_iter2 = self.lod2_meshes.iterator();
        while (mesh_iter2.next()) |entry| {
            entry.value_ptr.*.deinit(self.rhi);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod2_meshes.deinit();

        var mesh_iter3 = self.lod3_meshes.iterator();
        while (mesh_iter3.next()) |entry| {
            entry.value_ptr.*.deinit(self.rhi);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod3_meshes.deinit();

        // Cleanup regions
        var iter1 = self.lod1_regions.iterator();
        while (iter1.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod1_regions.deinit();

        var iter2 = self.lod2_regions.iterator();
        while (iter2.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod2_regions.deinit();

        var iter3 = self.lod3_regions.iterator();
        while (iter3.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.lod3_regions.deinit();

        self.transition_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Update LOD system with player position
    pub fn update(self: *LODManager, player_pos: Vec3, player_velocity: Vec3) !void {
        if (self.paused) return;

        // Deferred deletion handling (Issue #119: Performance optimization)
        // Clean up deleted meshes once per second to avoid waitIdle stalls
        self.deletion_timer += 0.016; // Approx 60fps delta
        if (self.deletion_timer >= 1.0 or self.deletion_queue.items.len > 100) {
            if (self.deletion_queue.items.len > 0) {
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

        const pc = worldToChunk(@intFromFloat(player_pos.x), @intFromFloat(player_pos.z));
        _ = pc.chunk_x != self.player_cx or pc.chunk_z != self.player_cz; // Track movement for future use

        self.player_cx = pc.chunk_x;
        self.player_cz = pc.chunk_z;

        // Issue #119 Phase 4: Recenter classification cache if player moved far enough.
        // This ensures LOD chunks have cache coverage for consistent biome/surface data.
        const player_wx: i32 = @intFromFloat(player_pos.x);
        const player_wz: i32 = @intFromFloat(player_pos.z);
        _ = self.generator.maybeRecenterCache(player_wx, player_wz);

        // Queue LOD regions that need loading (also queue on first frame)
        // Priority: LOD3 first (fast, fills horizon), then LOD2, LOD1
        try self.queueLODRegions(.lod3, player_velocity);
        try self.queueLODRegions(.lod2, player_velocity);
        try self.queueLODRegions(.lod1, player_velocity);

        // Process state transitions
        try self.processStateTransitions();

        // Process uploads (limited per frame)
        self.processUploads();

        // Update stats
        self.updateStats();

        // Unload distant regions
        try self.unloadDistantRegions();
    }

    /// Queue LOD regions that need generation
    fn queueLODRegions(self: *LODManager, lod: LODLevel, velocity: Vec3) !void {
        const radius = switch (lod) {
            .lod0 => self.config.lod0_radius, // LOD0 handled by existing World
            .lod1 => self.config.lod1_radius,
            .lod2 => self.config.lod2_radius,
            .lod3 => self.config.lod3_radius,
        };

        // Skip LOD0 - handled by existing World system
        if (lod == .lod0) return;

        var queued_count: u32 = 0;

        const scale: i32 = @intCast(lod.chunksPerSide());
        const region_radius = @divFloor(radius, scale) + 1;

        const player_rx = @divFloor(self.player_cx, scale);
        const player_rz = @divFloor(self.player_cz, scale);

        self.mutex.lock();
        defer self.mutex.unlock();

        const storage = switch (lod) {
            .lod0 => unreachable,
            .lod1 => &self.lod1_regions,
            .lod2 => &self.lod2_regions,
            .lod3 => &self.lod3_regions,
        };

        // All LOD jobs go to LOD3 queue (worker pool processes from there)
        // We encode the actual LOD level in the dist_sq high bits
        const queue = self.lod3_gen_queue;
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
                const key = LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };

                // Only queue if region doesn't already exist
                if (storage.get(key) == null) {
                    queued_count += 1;
                    // Create new LOD chunk
                    const chunk = try self.allocator.create(LODChunk);
                    chunk.* = LODChunk.init(rx, rz, lod);
                    chunk.job_token = self.next_job_token;
                    self.next_job_token += 1;

                    try storage.put(key, chunk);

                    // Calculate velocity-weighted priority
                    const dx = rx - player_rx;
                    const dz = rz - player_rz;
                    const dist_sq = dx * dx + dz * dz;
                    var priority = dist_sq;
                    queued_count += 1;
                    if (has_velocity) {
                        const fdx: f32 = @floatFromInt(dx);
                        const fdz: f32 = @floatFromInt(dz);
                        const dist = @sqrt(fdx * fdx + fdz * fdz);
                        if (dist > 0.01) {
                            const dot = (fdx * vel_dx + fdz * vel_dz) / dist;
                            // Ahead = lower priority number, behind = higher
                            const weight = 1.0 - dot * 0.5;
                            priority = @intFromFloat(@as(f32, @floatFromInt(dist_sq)) * weight);
                        }
                    }

                    // Encode LOD level in high bits of dist_sq
                    const encoded_priority = (priority & 0x0FFFFFFF) | lod_bits;

                    // Queue for generation
                    try queue.push(.{
                        .type = .generation,
                        .chunk_x = rx, // Using chunk coords for region coords
                        .chunk_z = rz,
                        .job_token = chunk.job_token,
                        .dist_sq = encoded_priority,
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

        // Check LOD1 regions
        var iter1 = self.lod1_regions.iterator();
        while (iter1.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.state == .generated) {
                const dx = chunk.region_x * 4 - self.player_cx;
                const dz = chunk.region_z * 4 - self.player_cz;
                const dist_sq = dx * dx + dz * dz;

                chunk.state = .meshing;
                try self.lod3_gen_queue.push(.{
                    .type = .meshing,
                    .chunk_x = chunk.region_x,
                    .chunk_z = chunk.region_z,
                    .job_token = chunk.job_token,
                    .dist_sq = (dist_sq & 0x0FFFFFFF) | (@as(i32, @intFromEnum(LODLevel.lod1)) << 28),
                });
            } else if (chunk.state == .mesh_ready) {
                chunk.state = .uploading;
                try self.lod1_upload_queue.push(chunk);
            }
        }

        // Check LOD2 regions
        var iter2 = self.lod2_regions.iterator();
        while (iter2.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.state == .generated) {
                const dx = chunk.region_x * 8 - self.player_cx;
                const dz = chunk.region_z * 8 - self.player_cz;
                const dist_sq = dx * dx + dz * dz;

                chunk.state = .meshing;
                try self.lod3_gen_queue.push(.{
                    .type = .meshing,
                    .chunk_x = chunk.region_x,
                    .chunk_z = chunk.region_z,
                    .job_token = chunk.job_token,
                    .dist_sq = (dist_sq & 0x0FFFFFFF) | (@as(i32, @intFromEnum(LODLevel.lod2)) << 28),
                });
            } else if (chunk.state == .mesh_ready) {
                chunk.state = .uploading;
                try self.lod2_upload_queue.push(chunk);
            }
        }

        // Check LOD3 regions
        var iter3 = self.lod3_regions.iterator();
        while (iter3.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.state == .generated) {
                const dx = chunk.region_x * 16 - self.player_cx;
                const dz = chunk.region_z * 16 - self.player_cz;
                const dist_sq = dx * dx + dz * dz;

                chunk.state = .meshing;
                try self.lod3_gen_queue.push(.{
                    .type = .meshing,
                    .chunk_x = chunk.region_x,
                    .chunk_z = chunk.region_z,
                    .job_token = chunk.job_token,
                    .dist_sq = (dist_sq & 0x0FFFFFFF) | (@as(i32, @intFromEnum(LODLevel.lod3)) << 28),
                });
            } else if (chunk.state == .mesh_ready) {
                chunk.state = .uploading;
                try self.lod3_upload_queue.push(chunk);
            }
        }
    }

    /// Process GPU uploads (limited per frame)
    fn processUploads(self: *LODManager) void {
        const max_uploads = self.config.max_uploads_per_frame;
        var uploads: u32 = 0;

        // Process LOD3 first (furthest, should be ready first)
        while (!self.lod3_upload_queue.isEmpty() and uploads < max_uploads) {
            if (self.lod3_upload_queue.pop()) |chunk| {
                // Upload mesh to GPU
                const key = LODRegionKey{
                    .rx = chunk.region_x,
                    .rz = chunk.region_z,
                    .lod = chunk.lod_level,
                };
                if (self.lod3_meshes.get(key)) |mesh| {
                    mesh.upload(self.rhi);
                }
                chunk.state = .renderable;
                uploads += 1;
            }
        }

        // Then LOD2
        while (!self.lod2_upload_queue.isEmpty() and uploads < max_uploads) {
            if (self.lod2_upload_queue.pop()) |chunk| {
                const key = LODRegionKey{
                    .rx = chunk.region_x,
                    .rz = chunk.region_z,
                    .lod = chunk.lod_level,
                };
                if (self.lod2_meshes.get(key)) |mesh| {
                    mesh.upload(self.rhi);
                }
                chunk.state = .renderable;
                uploads += 1;
            }
        }

        // Then LOD1
        while (!self.lod1_upload_queue.isEmpty() and uploads < max_uploads) {
            if (self.lod1_upload_queue.pop()) |chunk| {
                const key = LODRegionKey{
                    .rx = chunk.region_x,
                    .rz = chunk.region_z,
                    .lod = chunk.lod_level,
                };
                if (self.lod1_meshes.get(key)) |mesh| {
                    mesh.upload(self.rhi);
                }
                chunk.state = .renderable;
                uploads += 1;
            }
        }
    }

    /// Unload regions that are too far from player
    fn unloadDistantRegions(self: *LODManager) !void {
        // Use same radius as queuing to prevent accumulation
        try self.unloadDistantForLevel(.lod1, self.config.lod1_radius);
        try self.unloadDistantForLevel(.lod2, self.config.lod2_radius);
        try self.unloadDistantForLevel(.lod3, self.config.lod3_radius);
    }

    fn unloadDistantForLevel(self: *LODManager, lod: LODLevel, max_radius: i32) !void {
        const storage = switch (lod) {
            .lod0 => return,
            .lod1 => &self.lod1_regions,
            .lod2 => &self.lod2_regions,
            .lod3 => &self.lod3_regions,
        };

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
                    const meshes = switch (lod) {
                        .lod0 => return,
                        .lod1 => &self.lod1_meshes,
                        .lod2 => &self.lod2_meshes,
                        .lod3 => &self.lod3_meshes,
                    };
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
        self.stats = .{};
        var mem_usage: u32 = 0;

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var iter1 = self.lod1_regions.iterator();
        while (iter1.next()) |entry| {
            if (entry.value_ptr.*.state == .renderable) {
                self.stats.lod1_loaded += 1;
            } else if (entry.value_ptr.*.state == .generating) {
                self.stats.lod1_generating += 1;
            }
            // Approx memory: 32x32 grid * (height(2) + biome(2) + block(2) + color(4)) = 10240 bytes
            mem_usage += 10240;
        }

        var iter2 = self.lod2_regions.iterator();
        while (iter2.next()) |entry| {
            if (entry.value_ptr.*.state == .renderable) {
                self.stats.lod2_loaded += 1;
            } else if (entry.value_ptr.*.state == .generating) {
                self.stats.lod2_generating += 1;
            }
            mem_usage += 10240;
        }

        var iter3 = self.lod3_regions.iterator();
        while (iter3.next()) |entry| {
            if (entry.value_ptr.*.state == .renderable) {
                self.stats.lod3_loaded += 1;
            } else if (entry.value_ptr.*.state == .generating) {
                self.stats.lod3_generating += 1;
            }
            mem_usage += 10240;
        }

        // Add mesh memory
        var mesh_iter1 = self.lod1_meshes.iterator();
        while (mesh_iter1.next()) |entry| {
            mem_usage += entry.value_ptr.*.capacity * @sizeOf(Vertex);
        }
        var mesh_iter2 = self.lod2_meshes.iterator();
        while (mesh_iter2.next()) |entry| {
            mem_usage += entry.value_ptr.*.capacity * @sizeOf(Vertex);
        }
        var mesh_iter3 = self.lod3_meshes.iterator();
        while (mesh_iter3.next()) |entry| {
            mem_usage += entry.value_ptr.*.capacity * @sizeOf(Vertex);
        }

        self.stats.memory_used_mb = mem_usage / (1024 * 1024);
        self.memory_used_bytes = mem_usage;
    }

    /// Get current statistics
    pub fn getStats(self: *LODManager) LODStats {
        return self.stats;
    }

    /// Pause all LOD generation
    pub fn pause(self: *LODManager) void {
        self.paused = true;
        self.lod1_gen_queue.setPaused(true);
        self.lod2_gen_queue.setPaused(true);
        self.lod3_gen_queue.setPaused(true);
    }

    /// Resume LOD generation
    pub fn unpause(self: *LODManager) void {
        self.paused = false;
        self.lod1_gen_queue.setPaused(false);
        self.lod2_gen_queue.setPaused(false);
        self.lod3_gen_queue.setPaused(false);
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

    /// Render all LOD meshes
    pub fn render(self: *LODManager, view_proj: Mat4, camera_pos: Vec3) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const frustum = Frustum.fromViewProj(view_proj);
        const player_cx = @as(f32, @floatFromInt(self.player_cx));
        const player_cz = @as(f32, @floatFromInt(self.player_cz));
        const world_scale: f32 = @floatFromInt(CHUNK_SIZE_X);

        const lod0_r2 = @as(f32, @floatFromInt(self.config.lod0_radius * self.config.lod0_radius));
        const lod1_r2 = @as(f32, @floatFromInt(self.config.lod1_radius * self.config.lod1_radius));
        const lod2_r2 = @as(f32, @floatFromInt(self.config.lod2_radius * self.config.lod2_radius));

        // Render LOD3
        var iter3 = self.lod3_meshes.iterator();
        while (iter3.next()) |entry| {
            const mesh = entry.value_ptr.*;
            if (!mesh.ready or mesh.vertex_count == 0) continue;
            if (self.lod3_regions.get(entry.key_ptr.*)) |chunk| {
                if (chunk.state != .renderable) continue;
                const bounds = chunk.worldBounds();

                // Annular masking: Cull if entirely within LOD2 radius
                const dx = (@as(f32, @floatFromInt(bounds.min_x + bounds.max_x)) * 0.5) / world_scale - player_cx;
                const dz = (@as(f32, @floatFromInt(bounds.min_z + bounds.max_z)) * 0.5) / world_scale - player_cz;
                if (dx * dx + dz * dz < lod2_r2 - 64.0) continue;

                if (!frustum.intersectsAABB(AABB.init(Vec3.init(@floatFromInt(bounds.min_x), -camera_pos.y, @floatFromInt(bounds.min_z)).sub(camera_pos), Vec3.init(@floatFromInt(bounds.max_x), 256.0 - camera_pos.y, @floatFromInt(bounds.max_z)).sub(camera_pos)))) continue;

                self.rhi.setModelMatrix(Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z)));
                mesh.draw(self.rhi);
            }
        }

        // Render LOD2
        var iter2 = self.lod2_meshes.iterator();
        while (iter2.next()) |entry| {
            const mesh = entry.value_ptr.*;
            if (!mesh.ready or mesh.vertex_count == 0) continue;
            if (self.lod2_regions.get(entry.key_ptr.*)) |chunk| {
                if (chunk.state != .renderable) continue;
                const bounds = chunk.worldBounds();

                // Annular masking: Cull if entirely within LOD1 radius
                const dx = (@as(f32, @floatFromInt(bounds.min_x + bounds.max_x)) * 0.5) / world_scale - player_cx;
                const dz = (@as(f32, @floatFromInt(bounds.min_z + bounds.max_z)) * 0.5) / world_scale - player_cz;
                if (dx * dx + dz * dz < lod1_r2 - 16.0) continue;

                if (!frustum.intersectsAABB(AABB.init(Vec3.init(@floatFromInt(bounds.min_x), -camera_pos.y, @floatFromInt(bounds.min_z)).sub(camera_pos), Vec3.init(@floatFromInt(bounds.max_x), 256.0 - camera_pos.y, @floatFromInt(bounds.max_z)).sub(camera_pos)))) continue;

                self.rhi.setModelMatrix(Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z)));
                mesh.draw(self.rhi);
            }
        }

        // Render LOD1
        var iter1 = self.lod1_meshes.iterator();
        while (iter1.next()) |entry| {
            const mesh = entry.value_ptr.*;
            if (!mesh.ready or mesh.vertex_count == 0) continue;
            if (self.lod1_regions.get(entry.key_ptr.*)) |chunk| {
                if (chunk.state != .renderable) continue;
                const bounds = chunk.worldBounds();

                // Annular masking: Cull if entirely within LOD0 radius
                const dx = (@as(f32, @floatFromInt(bounds.min_x + bounds.max_x)) * 0.5) / world_scale - player_cx;
                const dz = (@as(f32, @floatFromInt(bounds.min_z + bounds.max_z)) * 0.5) / world_scale - player_cz;
                if (dx * dx + dz * dz < lod0_r2 - 4.0) continue;

                if (!frustum.intersectsAABB(AABB.init(Vec3.init(@floatFromInt(bounds.min_x), -camera_pos.y, @floatFromInt(bounds.min_z)).sub(camera_pos), Vec3.init(@floatFromInt(bounds.max_x), 256.0 - camera_pos.y, @floatFromInt(bounds.max_z)).sub(camera_pos)))) continue;

                self.rhi.setModelMatrix(Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z)));
                mesh.draw(self.rhi);
            }
        }
    }

    /// Get or create mesh for a LOD region
    fn getOrCreateMesh(self: *LODManager, key: LODRegionKey) !*LODMesh {
        self.mutex.lock();
        defer self.mutex.unlock();

        const meshes = switch (key.lod) {
            .lod0 => return error.InvalidLODLevel,
            .lod1 => &self.lod1_meshes,
            .lod2 => &self.lod2_meshes,
            .lod3 => &self.lod3_meshes,
        };

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
        .rx = job.chunk_x,
        .rz = job.chunk_z,
        .lod = lod_level,
    };

    self.mutex.lockShared();
    const storage = switch (lod_level) {
        .lod0 => {
            self.mutex.unlockShared();
            return;
        },
        .lod1 => &self.lod1_regions,
        .lod2 => &self.lod2_regions,
        .lod3 => &self.lod3_regions,
    };

    const chunk = storage.get(key) orelse {
        self.mutex.unlockShared();
        return;
    };

    // Stale job check (too far from player)
    const scale: i32 = @intCast(lod_level.chunksPerSide());
    const player_rx = @divFloor(self.player_cx, scale);
    const player_rz = @divFloor(self.player_cz, scale);
    const dx = job.chunk_x - player_rx;
    const dz = job.chunk_z - player_rz;
    const radius = switch (lod_level) {
        .lod0 => self.config.lod0_radius,
        .lod1 => self.config.lod1_radius,
        .lod2 => self.config.lod2_radius,
        .lod3 => self.config.lod3_radius,
    };
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
    if (chunk.job_token != job.job_token) return;

    switch (job.type) {
        .generation => {
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
        .meshing => {
            if (chunk.state != .meshing) return;

            self.buildMeshForChunk(chunk) catch |err| {
                log.log.err("Failed to build LOD{} async mesh: {}", .{ @intFromEnum(lod_level), err });
                chunk.state = .generated; // Retry later
                return;
            };
            chunk.state = .mesh_ready;
        },
    }
}

// Tests
test "LODManager initialization" {
    const allocator = std.testing.allocator;

    // We can't fully test without RHI, but we can test the config
    const config = LODConfig{
        .lod0_radius = 8,
        .lod1_radius = 16,
        .lod2_radius = 32,
        .lod3_radius = 64,
    };

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(5));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(12));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(24));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(50));

    _ = allocator;
}
