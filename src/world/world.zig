//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const BlockType = @import("block.zig").BlockType;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToLocal = @import("chunk.zig").worldToLocal;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const TerrainGenerator = @import("worldgen/generator.zig").TerrainGenerator;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const RenderStats = @import("world_renderer.zig").RenderStats;
const JobQueue = @import("../engine/core/job_system.zig").JobQueue;
const WorkerPool = @import("../engine/core/job_system.zig").WorkerPool;
const Job = @import("../engine/core/job_system.zig").Job;
const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;
const log = @import("../engine/core/log.zig");

const LODConfig = @import("lod_chunk.zig").LODConfig;
const CHUNK_UNLOAD_BUFFER = @import("chunk.zig").CHUNK_UNLOAD_BUFFER;

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

pub const ChunkPos = struct { x: i32, z: i32 };

pub const World = struct {
    storage: ChunkStorage,
    streamer: *WorldStreamer,
    renderer: *WorldRenderer,
    allocator: std.mem.Allocator,
    generator: TerrainGenerator,
    render_distance: i32,
    rhi: RHI,
    paused: bool = false,
    max_uploads_per_frame: usize,
    safe_mode: bool,
    safe_render_distance: i32,

    // LOD System (Issue #114)
    lod_manager: ?*LODManager,
    lod_enabled: bool,

    pub fn init(allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI) !*World {
        const world = try allocator.create(World);

        const storage = ChunkStorage.init(allocator);
        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;
        const safe_render_distance: i32 = if (safe_mode) @min(render_distance, 8) else render_distance;
        const max_uploads: usize = if (safe_mode) @as(usize, 4) else @as(usize, 32);
        if (safe_mode) {
            std.log.warn("ZIGCRAFT_SAFE_MODE enabled: limiting uploads to {} per frame", .{max_uploads});
            if (safe_render_distance != render_distance) {
                std.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance to {}", .{safe_render_distance});
            }
        }

        world.* = .{
            .storage = storage,
            .streamer = undefined,
            .renderer = undefined,
            .allocator = allocator,
            .render_distance = safe_render_distance,
            .generator = TerrainGenerator.init(seed, allocator),
            .rhi = rhi,
            .paused = false,
            .max_uploads_per_frame = max_uploads,
            .safe_mode = safe_mode,
            .safe_render_distance = safe_render_distance,
            .lod_manager = null,
            .lod_enabled = false,
        };

        world.streamer = try WorldStreamer.init(allocator, &world.storage, &world.generator, render_distance);
        world.renderer = try WorldRenderer.init(allocator, rhi, &world.storage);

        return world;
    }

    /// Initialize with LOD system enabled for extended render distances
    pub fn initWithLOD(allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI, lod_config: LODConfig) !*World {
        const world = try init(allocator, render_distance, seed, rhi);

        // Initialize LOD manager with generator reference
        world.lod_manager = try LODManager.init(allocator, lod_config, rhi, &world.generator);
        world.lod_enabled = true;

        log.log.info("World initialized with LOD system enabled (LOD3 radius: {} chunks)", .{lod_config.lod3_radius});

        return world;
    }

    pub fn deinit(self: *World) void {
        self.rhi.waitIdle();
        self.streamer.deinit();

        // Storage must be deinitialized before renderer because it uses the renderer's vertex_allocator
        // to free mesh buffers.
        // On shutdown we can skip per-chunk GPU frees since the allocator is destroyed next.
        self.storage.deinitWithoutRHI();
        self.renderer.deinit();

        // Cleanup LOD manager if enabled
        if (self.lod_manager) |lod_mgr| {
            lod_mgr.deinit();
        }

        self.allocator.destroy(self);
    }

    pub fn pauseGeneration(self: *World) void {
        self.paused = true;
        self.streamer.setPaused(true);

        // Pause LOD manager if enabled
        if (self.lod_manager) |lod_mgr| {
            lod_mgr.pause();
        }
    }

    pub fn resumeGeneration(self: *World) void {
        self.paused = false;
        self.streamer.setPaused(false);

        // Resume LOD manager if enabled
        if (self.lod_manager) |lod_mgr| {
            lod_mgr.unpause();
        }
    }

    /// Set render distance and trigger chunk loading/unloading update
    pub fn setRenderDistance(self: *World, distance: i32) void {
        const target = if (self.safe_mode) @min(distance, self.safe_render_distance) else distance;

        if (self.render_distance != target) {
            if (self.safe_mode and target != distance) {
                std.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance {} -> {}", .{ distance, target });
            }
            std.log.info("Render distance changed: {} -> {}", .{ self.render_distance, target });
            self.render_distance = target;
            self.streamer.setRenderDistance(target);

            // Only update LOD0 radius - LOD1/2/3 are fixed for "infinite" terrain view
            if (self.lod_manager) |lod_mgr| {
                lod_mgr.config.lod0_radius = target;
                std.log.info("LOD0 radius updated to match render distance: {}", .{target});
            }
        }
    }

    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        return self.storage.getOrCreate(chunk_x, chunk_z);
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

        // Update skylight for this column
        data.chunk.updateSkylightColumn(local.x, local.z);

        // Mark neighbor chunks dirty if block is on chunk boundary
        // This ensures their meshes update to show/hide faces correctly
        if (local.x == 0) {
            if (self.getChunk(cp.chunk_x - 1, cp.chunk_z)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.x == CHUNK_SIZE_X - 1) {
            if (self.getChunk(cp.chunk_x + 1, cp.chunk_z)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.z == 0) {
            if (self.getChunk(cp.chunk_x, cp.chunk_z - 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.z == CHUNK_SIZE_Z - 1) {
            if (self.getChunk(cp.chunk_x, cp.chunk_z + 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
    }

    /// Get chunk data at chunk coordinates.
    /// WARNING: Returned pointer is only guaranteed valid if called from the main thread
    /// and used before the next call to World.update (which may unload chunks).
    /// If accessing from a background thread, the chunk must be pinned first.
    pub fn getChunk(self: *World, cx: i32, cz: i32) ?*ChunkData {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();
        return self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz });
    }

    pub fn update(self: *World, player_pos: Vec3, dt: f32) !void {
        // Process deferred vertex memory reclamation for this frame slot.
        // Safe because beginFrame() has already waited for this slot's fence.
        self.renderer.vertex_allocator.tick(self.renderer.rhi.getFrameIndex());

        try self.streamer.update(player_pos, dt, self.lod_manager);

        // Process a few uploads per frame
        self.streamer.processUploads(self.renderer.vertex_allocator, self.max_uploads_per_frame);

        // Process unloads
        try self.streamer.processUnloads(player_pos, self.renderer.vertex_allocator, self.lod_manager);

        // NOTE: LOD Manager update is handled inside streamer.update() now
    }

    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3) void {
        self.renderer.render(view_proj, camera_pos, self.render_distance, self.lod_manager);
    }

    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3) void {
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, self.render_distance, self.lod_manager);
    }

    pub fn getRenderStats(self: *const World) RenderStats {
        return self.renderer.last_render_stats;
    }

    pub fn getStats(self: *World) struct { chunks_loaded: usize, total_vertices: u64, gen_queue: usize, mesh_queue: usize, upload_queue: usize } {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();
        var total_verts: u64 = 0;
        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.mesh.solid_allocation) |alloc| total_verts += alloc.count;
            if (entry.value_ptr.*.mesh.fluid_allocation) |alloc| total_verts += alloc.count;
        }

        const streamer_stats = self.streamer.getStats();

        return .{
            .chunks_loaded = self.storage.chunks.count(),
            .total_vertices = total_verts,
            .gen_queue = streamer_stats.gen_queue,
            .mesh_queue = streamer_stats.mesh_queue,
            .upload_queue = streamer_stats.upload_queue,
        };
    }

    /// Get LOD system statistics (returns null if LOD not enabled)
    pub fn getLODStats(self: *World) ?@import("lod_manager.zig").LODStats {
        if (self.lod_manager) |lod_mgr| {
            return lod_mgr.getStats();
        }
        return null;
    }

    /// Check if LOD system is enabled
    pub fn isLODEnabled(self: *const World) bool {
        return self.lod_enabled;
    }
};
