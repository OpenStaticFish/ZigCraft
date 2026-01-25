//! Block Outline Renderer
//! Renders a wireframe-style cube around the currently targeted block using thin quads.

const std = @import("std");
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Vertex = rhi_pkg.Vertex;

/// Line thickness for the outline (0.035 = 3.5cm, subtle but visible)
const LINE_THICKNESS: f32 = 0.035;

/// Expansion to avoid z-fighting (sit slightly outside block)
const EXPAND: f32 = 0.004;

/// Create a vertex with the given position
fn makeVertex(x: f32, y: f32, z: f32) Vertex {
    return .{
        .pos = .{ x, y, z },
        .color = .{ 0.0, 0.0, 0.0 }, // Black outline
        .normal = .{ 0, 1, 0 },
        .uv = .{ 0, 0 },
        .tile_id = 0,
        .skylight = 15,
        .blocklight = .{ 15, 15, 15 },
        .ao = 1.0,
    };
}

/// Generate vertices for a thin quad (2 triangles = 6 vertices)
/// from point (x0,y0,z0) to (x1,y1,z1), extended by thickness in the given direction
fn makeEdgeQuad(
    comptime result: *[6]Vertex,
    x0: f32,
    y0: f32,
    z0: f32,
    x1: f32,
    y1: f32,
    z1: f32,
    tx: f32,
    ty: f32,
    tz: f32,
) void {
    // 4 corners of the quad
    const a = makeVertex(x0, y0, z0);
    const b = makeVertex(x1, y1, z1);
    const c = makeVertex(x1 + tx, y1 + ty, z1 + tz);
    const d = makeVertex(x0 + tx, y0 + ty, z0 + tz);

    // Two triangles: a-b-c and a-c-d
    result[0] = a;
    result[1] = b;
    result[2] = c;
    result[3] = a;
    result[4] = c;
    result[5] = d;
}

/// Generate all 12 edges as thin quads
/// Each edge is represented as 2 quads * 2 sides (double-sided) = 4 quads
const outline_vertices = blk: {
    const s: f32 = -EXPAND; // Start
    const e: f32 = 1.0 + EXPAND; // End
    const t: f32 = LINE_THICKNESS;

    // 12 edges * 2 quads * 2 sides * 6 vertices = 288 vertices
    var verts: [288]Vertex = undefined;
    var idx: usize = 0;

    // Helper to add a quad (single sided)
    const addQuad = struct {
        fn f(v: *[288]Vertex, i: *usize, p0: Vertex, p1: Vertex, p2: Vertex, p3: Vertex) void {
            // Triangle 1
            v[i.*] = p0;
            i.* += 1;
            v[i.*] = p1;
            i.* += 1;
            v[i.*] = p2;
            i.* += 1;
            // Triangle 2
            v[i.*] = p0;
            i.* += 1;
            v[i.*] = p2;
            i.* += 1;
            v[i.*] = p3;
            i.* += 1;
        }
    }.f;

    // Helper to add an edge with two quads (perpendicular), DOUBLE SIDED
    const addEdge = struct {
        fn f(v: *[288]Vertex, i: *usize, x0: f32, y0: f32, z0: f32, x1: f32, y1: f32, z1: f32, t1x: f32, t1y: f32, t1z: f32, t2x: f32, t2y: f32, t2z: f32) void {
            const addDoubleSidedQuad = struct {
                fn g(v_arr: *[288]Vertex, idx_ptr: *usize, c0: Vertex, c1: Vertex, c2: Vertex, c3: Vertex) void {
                    // Front face
                    addQuad(v_arr, idx_ptr, c0, c1, c2, c3);
                    // Back face (reverse winding)
                    addQuad(v_arr, idx_ptr, c0, c3, c2, c1);
                }
            }.g;

            // First quad
            const q1_c0 = makeVertex(x0, y0, z0);
            const q1_c1 = makeVertex(x1, y1, z1);
            const q1_c2 = makeVertex(x1 + t1x, y1 + t1y, z1 + t1z);
            const q1_c3 = makeVertex(x0 + t1x, y0 + t1y, z0 + t1z);
            addDoubleSidedQuad(v, i, q1_c0, q1_c1, q1_c2, q1_c3);

            // Second quad
            const q2_c0 = makeVertex(x0, y0, z0);
            const q2_c1 = makeVertex(x1, y1, z1);
            const q2_c2 = makeVertex(x1 + t2x, y1 + t2y, z1 + t2z);
            const q2_c3 = makeVertex(x0 + t2x, y0 + t2y, z0 + t2z);
            addDoubleSidedQuad(v, i, q2_c0, q2_c1, q2_c2, q2_c3);
        }
    }.f;

    // Bottom face edges (horizontal, y = s)
    addEdge(&verts, &idx, s, s, s, e, s, s, 0, t, 0, 0, 0, t); // Edge 0-1
    addEdge(&verts, &idx, e, s, s, e, s, e, 0, t, 0, -t, 0, 0); // Edge 1-2
    addEdge(&verts, &idx, e, s, e, s, s, e, 0, t, 0, 0, 0, -t); // Edge 2-3
    addEdge(&verts, &idx, s, s, e, s, s, s, 0, t, 0, t, 0, 0); // Edge 3-0

    // Top face edges (horizontal, y = e)
    addEdge(&verts, &idx, s, e, s, e, e, s, 0, -t, 0, 0, 0, t); // Edge 4-5
    addEdge(&verts, &idx, e, e, s, e, e, e, 0, -t, 0, -t, 0, 0); // Edge 5-6
    addEdge(&verts, &idx, e, e, e, s, e, e, 0, -t, 0, 0, 0, -t); // Edge 6-7
    addEdge(&verts, &idx, s, e, e, s, e, s, 0, -t, 0, t, 0, 0); // Edge 7-4

    // Vertical edges
    addEdge(&verts, &idx, s, s, s, s, e, s, t, 0, 0, 0, 0, t); // Edge 0-4
    addEdge(&verts, &idx, e, s, s, e, e, s, -t, 0, 0, 0, 0, t); // Edge 1-5
    addEdge(&verts, &idx, e, s, e, e, e, e, -t, 0, 0, 0, 0, -t); // Edge 2-6
    addEdge(&verts, &idx, s, s, e, s, e, e, t, 0, 0, 0, 0, -t); // Edge 3-7

    break :blk verts;
};

pub const BlockOutline = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    rhi: RHI,

    pub fn init(rhi: RHI) !BlockOutline {
        const buffer = try rhi.createBuffer(@sizeOf(@TypeOf(outline_vertices)), .vertex);
        try rhi.uploadBuffer(buffer, std.mem.asBytes(&outline_vertices));

        return .{
            .buffer_handle = buffer,
            .rhi = rhi,
        };
    }

    pub fn deinit(self: *BlockOutline) void {
        if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.rhi.destroyBuffer(self.buffer_handle);
            self.buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
    }

    /// Draw outline at the given block position
    pub fn draw(self: *const BlockOutline, block_x: i32, block_y: i32, block_z: i32, camera_pos: Vec3) void {
        const rel_x = @as(f32, @floatFromInt(block_x)) - camera_pos.x;
        const rel_y = @as(f32, @floatFromInt(block_y)) - camera_pos.y;
        const rel_z = @as(f32, @floatFromInt(block_z)) - camera_pos.z;

        const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));
        self.rhi.setSelectionMode(true);
        self.rhi.setModelMatrix(model, Vec3.one, 0);
        self.rhi.draw(self.buffer_handle, 288, .triangles);
        self.rhi.setSelectionMode(false);
    }
};
