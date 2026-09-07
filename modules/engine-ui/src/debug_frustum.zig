//! Debug frustum wireframe visualization.
//! Renders the camera frustum as a 3D wireframe overlay.

const std = @import("std");
const rhi = @import("engine-rhi").rhi;
const RenderContext = rhi.RenderContext;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Vertex = rhi.Vertex;

pub const FRUSTUM_EDGE_COUNT: u32 = 12;
pub const FRUSTUM_VERTEX_COUNT: u32 = FRUSTUM_EDGE_COUNT * 2;

fn makeVertex(x: f32, y: f32, z: f32, r: f32, g: f32, b: f32) Vertex {
    return Vertex.init(.{ x, y, z }, .{ r, g, b }, .{ 0, 1, 0 }, .{ 0, 0 }, 0, 1.0, .{ 1.0, 1.0, 1.0 }, 1.0);
}

pub const DebugFrustum = struct {
    pub const Color = struct {
        r: f32,
        g: f32,
        b: f32,
    };

    pub const DefaultColor = Color{ .r = 0.0, .g = 0.9, .b = 0.9 };

    pub fn extractCorners(proj: Mat4, view: Mat4) [8]Vec3 {
        const inv_vp = proj.multiply(view).inverse();
        const m = inv_vp.data;

        const corners_ndc = [8][4]f32{
            .{ -1.0, -1.0, 0.0, 1.0 },
            .{ 1.0, -1.0, 0.0, 1.0 },
            .{ 1.0, 1.0, 0.0, 1.0 },
            .{ -1.0, 1.0, 0.0, 1.0 },
            .{ -1.0, -1.0, 1.0, 1.0 },
            .{ 1.0, -1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0, 1.0 },
            .{ -1.0, 1.0, 1.0, 1.0 },
        };

        var world_corners: [8]Vec3 = undefined;
        for (0..8) |i| {
            const nx = corners_ndc[i][0];
            const ny = corners_ndc[i][1];
            const nz = corners_ndc[i][2];
            const nw = corners_ndc[i][3];

            // Mat4 uses column-major layout: m[col][row]
            // Transform from clip space to world space
            const wx = m[0][0] * nx + m[1][0] * ny + m[2][0] * nz + m[3][0] * nw;
            const wy = m[0][1] * nx + m[1][1] * ny + m[2][1] * nz + m[3][1] * nw;
            const wz = m[0][2] * nx + m[1][2] * ny + m[2][2] * nz + m[3][2] * nw;
            const ww = m[0][3] * nx + m[1][3] * ny + m[2][3] * nz + m[3][3] * nw;

            world_corners[i] = Vec3.init(wx / ww, wy / ww, wz / ww);
        }

        return world_corners;
    }

    pub fn buildLineVertices(corners: [8]Vec3, color: Color) [FRUSTUM_VERTEX_COUNT]Vertex {
        const c = corners;

        const edge_pairs = [12][2]usize{
            .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 },
            .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 },
            .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
        };

        var verts: [FRUSTUM_VERTEX_COUNT]Vertex = undefined;
        for (0..FRUSTUM_EDGE_COUNT) |i| {
            const a = c[edge_pairs[i][0]];
            const b = c[edge_pairs[i][1]];
            verts[i * 2] = makeVertex(a.x, a.y, a.z, color.r, color.g, color.b);
            verts[i * 2 + 1] = makeVertex(b.x, b.y, b.z, color.r, color.g, color.b);
        }
        return verts;
    }

    pub fn draw(
        rc: RenderContext,
        buffer_handle: rhi.BufferHandle,
        vertex_count: u32,
        cam_pos: Vec3,
    ) void {
        const rel_x = -cam_pos.x;
        const rel_y = -cam_pos.y;
        const rel_z = -cam_pos.z;
        const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));
        rc.setModelMatrix(model, Vec3.init(DefaultColor.r, DefaultColor.g, DefaultColor.b));
        rc.draw(buffer_handle, @as(u32, @intCast(vertex_count)), .lines);
    }
};
