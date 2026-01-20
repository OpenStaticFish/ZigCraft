//! Render system for ECS.
//! Currently renders entities as colored wireframe boxes.

const std = @import("std");
const Registry = @import("../manager.zig").Registry;
const components = @import("../components.zig");
const rhi_pkg = @import("../../graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const Mat4 = @import("../../math/mat4.zig").Mat4;
const Vec3 = @import("../../math/vec3.zig").Vec3;
const Vertex = rhi_pkg.Vertex;
const wireframe = @import("../../graphics/wireframe_cube.zig");

pub const RenderSystem = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    rhi: *RHI,
    missing_transform_logged: bool,

    pub fn init(rhi: *RHI) !RenderSystem {
        const buffer = try rhi.*.createBuffer(@sizeOf(@TypeOf(wireframe.line_vertices)), .vertex);
        try rhi.*.uploadBuffer(buffer, std.mem.asBytes(&wireframe.line_vertices));

        return .{
            .buffer_handle = buffer,
            .rhi = rhi,
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
        const logger = @import("../../core/log.zig").log;

        // Check for entities with Mesh but no Transform (potential configuration error)
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

            if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
                self.rhi.*.setModelMatrix(model, mesh.color, 0);
                // Draw line list (24 vertices = 12 edges)
                self.rhi.*.draw(self.buffer_handle, wireframe.line_vertex_count, .lines);
            }
        }
    }
};
