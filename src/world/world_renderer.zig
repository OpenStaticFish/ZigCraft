//! World renderer - handles chunk rendering, culling, and MDI.

const std = @import("std");
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const worldToChunk = @import("chunk.zig").worldToChunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const World = @import("world.zig").World; // Circular dependency if not careful, better avoid. But isChunkRenderable callback needs it?
// Actually isChunkRenderable uses World* but only needs access to storage/chunk state.

pub const RenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
};

pub const WorldRenderer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    rhi: RHI,

    vertex_allocator: *GlobalVertexAllocator,
    visible_chunks: std.ArrayListUnmanaged(*ChunkData),
    last_render_stats: RenderStats,

    // MDI Resources
    instance_data: std.ArrayListUnmanaged(rhi_mod.InstanceData),
    solid_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    fluid_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    frame_index: usize,
    mdi_instance_offset: usize,
    mdi_command_offset: usize,

    pub fn init(allocator: std.mem.Allocator, rhi: RHI, storage: *ChunkStorage) !*WorldRenderer {
        const renderer = try allocator.create(WorldRenderer);

        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;
        const vertex_capacity_mb: usize = if (safe_mode) 1024 else 2048;

        if (safe_mode) {
            std.log.warn("ZIGCRAFT_SAFE_MODE enabled: GlobalVertexAllocator reduced to {}MB", .{vertex_capacity_mb});
        }

        const vertex_allocator = try allocator.create(GlobalVertexAllocator);
        vertex_allocator.* = try GlobalVertexAllocator.init(allocator, rhi, vertex_capacity_mb);

        const max_chunks = 16384;
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        var indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = try rhi.createBuffer(max_chunks * @sizeOf(rhi_mod.InstanceData), .storage);
            indirect_buffers[i] = try rhi.createBuffer(max_chunks * @sizeOf(rhi_mod.DrawIndirectCommand) * 2, .indirect);
        }

        renderer.* = .{
            .allocator = allocator,
            .storage = storage,
            .rhi = rhi,
            .vertex_allocator = vertex_allocator,
            .visible_chunks = .empty,
            .last_render_stats = .{},
            .instance_data = .empty,
            .solid_commands = .empty,
            .fluid_commands = .empty,
            .instance_buffers = instance_buffers,
            .indirect_buffers = indirect_buffers,
            .frame_index = 0,
            .mdi_instance_offset = 0,
            .mdi_command_offset = 0,
        };

        return renderer;
    }

    pub fn deinit(self: *WorldRenderer) void {
        self.visible_chunks.deinit(self.allocator);

        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.instance_buffers[i] != 0) self.rhi.destroyBuffer(self.instance_buffers[i]);
            if (self.indirect_buffers[i] != 0) self.rhi.destroyBuffer(self.indirect_buffers[i]);
        }
        self.instance_data.deinit(self.allocator);
        self.solid_commands.deinit(self.allocator);
        self.fluid_commands.deinit(self.allocator);

        self.vertex_allocator.deinit();
        self.allocator.destroy(self.vertex_allocator);
        self.allocator.destroy(self);
    }

    pub fn render(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, render_distance: i32, lod_manager: ?*LODManager) void {
        self.last_render_stats = .{};

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (lod_manager) |lod_mgr| {
            lod_mgr.render(view_proj, camera_pos, ChunkStorage.isChunkRenderable, @ptrCast(self.storage));
        }

        self.visible_chunks.clearRetainingCapacity();

        const frustum = Frustum.fromViewProj(view_proj);
        const pc = worldToChunk(@intFromFloat(camera_pos.x), @intFromFloat(camera_pos.z));
        const render_dist = if (lod_manager) |mgr| @min(render_distance, mgr.config.radii[0]) else render_distance;

        var cz = pc.chunk_z - render_dist;
        while (cz <= pc.chunk_z + render_dist) : (cz += 1) {
            var cx = pc.chunk_x - render_dist;
            while (cx <= pc.chunk_x + render_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.fluid_allocation != null) {
                        if (frustum.intersectsChunkRelative(cx, cz, camera_pos.x, camera_pos.y, camera_pos.z)) {
                            self.visible_chunks.append(self.allocator, data) catch {};
                        } else {
                            self.last_render_stats.chunks_culled += 1;
                        }
                    }
                }
            }
        }

        self.last_render_stats.chunks_total = @intCast(self.storage.chunks.count());

        for (self.visible_chunks.items) |data| {
            self.last_render_stats.chunks_rendered += 1;
            const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
            const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);
            const rel_x = chunk_world_x - camera_pos.x;
            const rel_z = chunk_world_z - camera_pos.z;
            const rel_y = -camera_pos.y;
            const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

            self.rhi.setModelMatrix(model, Vec3.one, 0);

            if (data.mesh.solid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.rhi.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
            if (data.mesh.fluid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.rhi.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
        }

        self.mdi_instance_offset = 0;
        self.mdi_command_offset = 0;
    }

    pub fn renderShadowPass(self: *WorldRenderer, light_space_matrix: Mat4, camera_pos: Vec3, render_distance: i32, lod_manager: ?*LODManager) void {
        const shadow_frustum = Frustum.fromViewProj(light_space_matrix);

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        const frustum = shadow_frustum;
        const pc = worldToChunk(@intFromFloat(camera_pos.x), @intFromFloat(camera_pos.z));
        const render_dist = if (lod_manager) |mgr| @min(render_distance, mgr.config.radii[0]) else render_distance;

        var cz = pc.chunk_z - render_dist;
        while (cz <= pc.chunk_z + render_dist) : (cz += 1) {
            var cx = pc.chunk_x - render_dist;
            while (cx <= pc.chunk_x + render_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.fluid_allocation != null) {
                        const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
                        const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);

                        if (!frustum.intersectsChunkRelative(cx, cz, camera_pos.x, camera_pos.y, camera_pos.z)) {
                            continue;
                        }

                        const rel_x = chunk_world_x - camera_pos.x;
                        const rel_z = chunk_world_z - camera_pos.z;
                        const rel_y = -camera_pos.y;
                        const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

                        if (data.mesh.solid_allocation) |alloc| {
                            self.rhi.setModelMatrix(model, Vec3.one, 0);

                            self.rhi.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                        }
                    }
                }
            }
        }

        self.mdi_instance_offset = 0;
        self.mdi_command_offset = 0;
    }
};
