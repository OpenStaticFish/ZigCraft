//! Render system for ECS.
//! Currently renders entities as colored wireframe boxes.

const std = @import("std");
const Registry = @import("../manager.zig").Registry;
const components = @import("../components.zig");
const rhi_pkg = @import("engine-rhi").rhi;
const ResourceManager = rhi_pkg.ResourceManager;
const RenderContext = rhi_pkg.RenderContext;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const Vertex = rhi_pkg.Vertex;

fn makeWireframeVertex(x: f32, y: f32, z: f32) Vertex {
    return Vertex.init(
        .{ x, y, z },
        .{ 1.0, 1.0, 1.0 },
        .{ 0, 1, 0 },
        .{ 0, 0 },
        0,
        1.0,
        .{ 1.0, 1.0, 1.0 },
        1.0,
    );
}

const wireframe_line_vertices = [_]Vertex{
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
};

const wireframe_line_vertex_count: u32 = @intCast(wireframe_line_vertices.len);

fn makeSolidVertex(x: f32, y: f32, z: f32) Vertex {
    return Vertex.init(.{ x, y, z }, .{ 1.0, 1.0, 1.0 }, .{ 0, 1, 0 }, .{ 0, 0 }, 0xffff, 1.0, .{ 1.0, 1.0, 1.0 }, 1.0);
}

const solid_box_vertices = [_]Vertex{
    // Bottom, top, front, right, back, left.
    makeSolidVertex(0, 0, 0), makeSolidVertex(1, 0, 1), makeSolidVertex(1, 0, 0), makeSolidVertex(0, 0, 0), makeSolidVertex(0, 0, 1), makeSolidVertex(1, 0, 1),
    makeSolidVertex(0, 1, 0), makeSolidVertex(1, 1, 0), makeSolidVertex(1, 1, 1), makeSolidVertex(0, 1, 0), makeSolidVertex(1, 1, 1), makeSolidVertex(0, 1, 1),
    makeSolidVertex(0, 0, 0), makeSolidVertex(1, 0, 0), makeSolidVertex(1, 1, 0), makeSolidVertex(0, 0, 0), makeSolidVertex(1, 1, 0), makeSolidVertex(0, 1, 0),
    makeSolidVertex(1, 0, 0), makeSolidVertex(1, 0, 1), makeSolidVertex(1, 1, 1), makeSolidVertex(1, 0, 0), makeSolidVertex(1, 1, 1), makeSolidVertex(1, 1, 0),
    makeSolidVertex(1, 0, 1), makeSolidVertex(0, 0, 1), makeSolidVertex(0, 1, 1), makeSolidVertex(1, 0, 1), makeSolidVertex(0, 1, 1), makeSolidVertex(1, 1, 1),
    makeSolidVertex(0, 0, 1), makeSolidVertex(0, 0, 0), makeSolidVertex(0, 1, 0), makeSolidVertex(0, 0, 1), makeSolidVertex(0, 1, 0), makeSolidVertex(0, 1, 1),
};

const solid_box_vertex_count: u32 = @intCast(solid_box_vertices.len);

pub const RenderSystem = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    solid_buffer_handle: rhi_pkg.BufferHandle,
    resources: ResourceManager,
    missing_transform_logged: bool,

    pub fn init(resources: ResourceManager) !RenderSystem {
        const buffer = try resources.createBuffer(@sizeOf(@TypeOf(wireframe_line_vertices)), .vertex);
        errdefer resources.destroyBuffer(buffer);
        try resources.uploadBuffer(buffer, std.mem.asBytes(&wireframe_line_vertices));
        const solid_buffer = try resources.createBuffer(@sizeOf(@TypeOf(solid_box_vertices)), .vertex);
        errdefer resources.destroyBuffer(solid_buffer);
        try resources.uploadBuffer(solid_buffer, std.mem.asBytes(&solid_box_vertices));

        return .{
            .buffer_handle = buffer,
            .solid_buffer_handle = solid_buffer,
            .resources = resources,
            .missing_transform_logged = false,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.resources.destroyBuffer(self.buffer_handle);
            self.buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
        if (self.solid_buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.resources.destroyBuffer(self.solid_buffer_handle);
            self.solid_buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
    }

    fn boxModel(registry: *Registry, entity_id: u64, transform: *const components.Transform, camera_pos: Vec3) Mat4 {
        var size = Vec3.one;
        var offset = Vec3.zero;
        if (registry.physics.getPtr(entity_id)) |phys| {
            size = phys.aabb_size;
            offset = Vec3.init(-size.x / 2.0, 0, -size.z / 2.0);
        }
        return Mat4.translate(transform.position.add(offset).sub(camera_pos)).multiply(Mat4.scale(size));
    }

    pub fn render(self: *RenderSystem, ctx: RenderContext, registry: *Registry, camera_pos: Vec3) void {
        const logger = @import("engine-core").log.log;

        if (!self.missing_transform_logged) {
            for (registry.meshes.entities.items) |entity_id| {
                if (!registry.transforms.has(entity_id)) {
                    logger.warn("ECS render skip: entity missing Transform (id={})", .{entity_id});
                    self.missing_transform_logged = true;
                    break;
                }
            }
        }

        var q = registry.query(.{ components.Mesh, components.Transform });
        while (q.next()) |row| {
            const mesh = row.components[0];
            const transform = row.components[1];
            const entity_id = row.entity;

            if (!mesh.visible) continue;

            const model = boxModel(registry, entity_id, transform, camera_pos);

            if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
                ctx.setModelMatrix(model, mesh.color);
                ctx.draw(self.buffer_handle, wireframe_line_vertex_count, .lines);
            }
        }
    }

    pub fn renderShadowCasters(self: *RenderSystem, ctx: RenderContext, registry: *Registry, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void {
        if (self.solid_buffer_handle == rhi_pkg.InvalidBufferHandle) return;
        var q = registry.query(.{ components.Mesh, components.Transform });
        while (q.next()) |row| {
            const mesh = row.components[0];
            const transform = row.components[1];
            if (!mesh.visible) continue;

            var size = Vec3.one;
            var offset = Vec3.zero;
            if (registry.physics.getPtr(row.entity)) |phys| {
                size = phys.aabb_size;
                offset = Vec3.init(-size.x / 2.0, 0, -size.z / 2.0);
            }
            const min = transform.position.add(offset);
            const max = min.add(size);
            if (max.x < caster_min.x or min.x > caster_max.x or max.y < caster_min.y or min.y > caster_max.y or max.z < caster_min.z or min.z > caster_max.z) continue;

            ctx.setModelMatrix(boxModel(registry, row.entity, transform, camera_pos), Vec3.one);
            ctx.drawOffset(self.solid_buffer_handle, solid_box_vertex_count, .triangles, 0);
        }
    }
};

test "solid entity shadow box uses triangle geometry without atlas sampling" {
    try std.testing.expectEqual(@as(usize, 36), solid_box_vertices.len);
    try std.testing.expect(solid_box_vertices.len % 3 == 0);
    for (solid_box_vertices) |vertex| {
        try std.testing.expectEqual(@as(u32, 0xffff), vertex.packed_meta & 0xffff);
    }
}
