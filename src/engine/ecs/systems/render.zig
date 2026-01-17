//! Render system for ECS.
//! Currently renders entities as colored wireframe boxes.

const std = @import("std");
const Registry = @import("../manager.zig").Registry;
const rhi_pkg = @import("../../graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const Mat4 = @import("../../math/mat4.zig").Mat4;
const Vec3 = @import("../../math/vec3.zig").Vec3;
const Vertex = rhi_pkg.Vertex;
const wireframe = @import("../../graphics/wireframe_cube.zig");

const OutlineVertexCount = wireframe.line_vertices.len;
const outline_vertices = wireframe.line_vertices;
const outline_vertex_count: u32 = wireframe.line_vertex_count;

fn colorEquals(a: Vec3, b: Vec3) bool {
    const epsilon: f32 = 0.0001;
    return @abs(a.x - b.x) <= epsilon and @abs(a.y - b.y) <= epsilon and @abs(a.z - b.z) <= epsilon;
}

pub const RenderSystem = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    rhi: *RHI,
    scratch_vertices: [OutlineVertexCount]Vertex,
    last_color: Vec3,
    has_last_color: bool,
    missing_transform_logged: bool,

    pub fn init(rhi: *RHI) RenderSystem {
        var scratch_vertices = outline_vertices;
        const buffer = rhi.*.createBuffer(@sizeOf(@TypeOf(outline_vertices)), .vertex);
        rhi.*.uploadBuffer(buffer, std.mem.asBytes(&scratch_vertices));

        return .{
            .buffer_handle = buffer,
            .rhi = rhi,
            .scratch_vertices = scratch_vertices,
            .last_color = Vec3.init(-1.0, -1.0, -1.0),
            .has_last_color = false,
            .missing_transform_logged = false,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.rhi.*.destroyBuffer(self.buffer_handle);
            self.buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
    }

    pub fn render(self: *RenderSystem, registry: *Registry, camera_pos: Vec3) void {
        const meshes = &registry.meshes;

        const log = @import("../../core/log.zig").log;

        for (meshes.components.items, meshes.entities.items) |*mesh, entity_id| {
            if (!mesh.visible) continue;

            // Ensure entity has a transform
            const transform = registry.transforms.getPtr(entity_id) orelse {
                if (!self.missing_transform_logged) {
                    log.warn("ECS render skip: entity missing Transform (id={})", .{entity_id});
                    self.missing_transform_logged = true;
                }
                continue;
            };

            // Determine size from physics if available, otherwise default 1x1x1
            var size = Vec3.one;
            var offset = Vec3.zero;

            if (registry.physics.getPtr(entity_id)) |phys| {
                size = phys.aabb_size;
                // Physics position is at the feet (bottom center)
                // Mesh vertex data is 0..1 (min=0, max=1)
                // We want to center the mesh horizontally around the position,
                // but keep y=0 at the feet.
                // So we translate by (-width/2, 0, -depth/2)
                offset = Vec3.init(-size.x / 2.0, 0, -size.z / 2.0);
            }

            // Camera uses origin-centered view matrix, so we render relative to the camera.
            const rel_pos = transform.position.add(offset).sub(camera_pos);

            // Create model matrix: Translate * Scale
            const model = Mat4.translate(rel_pos).multiply(Mat4.scale(size));

            if (!self.has_last_color or !colorEquals(mesh.color, self.last_color)) {
                self.scratch_vertices = outline_vertices;
                for (self.scratch_vertices[0..]) |*vertex| {
                    vertex.color = .{ mesh.color.x, mesh.color.y, mesh.color.z };
                }
                self.rhi.*.updateBuffer(self.buffer_handle, 0, std.mem.asBytes(&self.scratch_vertices));
                self.last_color = mesh.color;
                self.has_last_color = true;
            }

            if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
                self.rhi.*.setModelMatrix(model, 0); // Mesh ID 0
                // Draw line list (24 vertices = 12 edges)
                self.rhi.*.draw(self.buffer_handle, outline_vertex_count, .lines);
            }
        }
    }
};
