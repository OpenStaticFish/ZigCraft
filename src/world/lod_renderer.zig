//! LOD Renderer - handles culling and drawing of LOD meshes using MDI.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODMesh = @import("lod_mesh.zig").LODMesh;

const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const rhi_mod = @import("../engine/graphics/rhi.zig");

// Import LODManager for type definitions
const lod_manager_mod = @import("lod_manager.zig");
const LODManager = lod_manager_mod.LODManager;

pub const LODRenderer = struct {
    allocator: std.mem.Allocator,
    rhi: RHI,

    // MDI Resources (Moved from LODManager)
    instance_data: std.ArrayListUnmanaged(rhi_mod.InstanceData),
    draw_list: std.ArrayListUnmanaged(*LODMesh),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    frame_index: usize,

    pub fn init(allocator: std.mem.Allocator, rhi: RHI) !*LODRenderer {
        const renderer = try allocator.create(LODRenderer);

        // Init MDI buffers (capacity for ~2048 LOD regions)
        const max_regions = 2048;
        const instance_buffer = try rhi.createBuffer(max_regions * @sizeOf(rhi_mod.InstanceData), .storage);
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = instance_buffer;
        }

        renderer.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .instance_data = .empty,
            .draw_list = .empty,
            .instance_buffers = instance_buffers,
            .frame_index = 0,
        };

        return renderer;
    }

    pub fn deinit(self: *LODRenderer) void {
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

    /// Render all LOD meshes
    pub fn render(
        self: *LODRenderer,
        manager: *LODManager,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?LODManager.ChunkChecker,
        checker_ctx: ?*anyopaque,
    ) void {
        const frustum = Frustum.fromViewProj(view_proj);
        const lod_y_offset: f32 = -3.0;

        // Check and free LOD meshes where all underlying chunks are loaded
        if (chunk_checker) |checker| {
            manager.unloadLODWhereChunksLoaded(checker, checker_ctx.?);
        }

        self.instance_data.clearRetainingCapacity();
        self.draw_list.clearRetainingCapacity();

        // Collect visible meshes
        // Process LOD3, LOD2, LOD1 in order
        self.collectVisibleMeshes(manager, &manager.lod3_meshes, &manager.lod3_regions, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx) catch {};
        self.collectVisibleMeshes(manager, &manager.lod2_meshes, &manager.lod2_regions, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx) catch {};
        self.collectVisibleMeshes(manager, &manager.lod1_meshes, &manager.lod1_regions, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx) catch {};

        if (self.instance_data.items.len == 0) return;

        for (self.draw_list.items, 0..) |mesh, i| {
            const instance = self.instance_data.items[i];
            self.rhi.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
            self.rhi.draw(mesh.buffer_handle, mesh.vertex_count, .triangles);
        }
    }

    fn collectVisibleMeshes(
        self: *LODRenderer,
        manager: *LODManager,
        meshes: *const std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80),
        regions: *const std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80),
        view_proj: Mat4,
        camera_pos: Vec3,
        frustum: Frustum,
        lod_y_offset: f32,
        chunk_checker: ?LODManager.ChunkChecker,
        checker_ctx: ?*anyopaque,
    ) !void {
        var iter = meshes.iterator();
        while (iter.next()) |entry| {
            const mesh = entry.value_ptr.*;
            if (!mesh.ready or mesh.vertex_count == 0) continue;
            if (regions.get(entry.key_ptr.*)) |chunk| {
                if (chunk.state != .renderable) continue;
                const bounds = chunk.worldBounds();

                if (chunk_checker) |checker| {
                    if (manager.areAllChunksLoaded(bounds, checker, checker_ctx.?)) continue;
                }

                const aabb_min = Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, 0.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z);
                const aabb_max = Vec3.init(@as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, 256.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z);
                if (!frustum.intersectsAABB(AABB.init(aabb_min, aabb_max))) continue;

                const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                try self.instance_data.append(self.allocator, .{
                    .view_proj = view_proj,
                    .model = model,
                    .mask_radius = 0,
                    .padding = .{ 0, 0, 0 },
                });
                try self.draw_list.append(self.allocator, mesh);
            }
        }
    }
};
