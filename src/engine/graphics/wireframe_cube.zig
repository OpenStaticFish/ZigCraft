//! Shared wireframe cube geometry (line list).

const rhi_pkg = @import("rhi.zig");
const Vertex = rhi_pkg.Vertex;

/// Create a vertex with the given position (color is overwritten at draw time).
fn makeVertex(x: f32, y: f32, z: f32) Vertex {
    return .{
        .pos = .{ x, y, z },
        .color = .{ 0, 0, 0 },
        .normal = .{ 0, 1, 0 },
        .uv = .{ 0, 0 },
        .tile_id = 0,
        .skylight = 15,
        .blocklight = .{ 15, 15, 15 },
        .ao = 1.0,
    };
}

/// Vertices for a 1x1x1 cube wireframe (line list, 12 edges).
pub const line_vertices = [_]Vertex{
    // Bottom face edges (y = 0)
    makeVertex(0.0, 0.0, 0.0),
    makeVertex(1.0, 0.0, 0.0),
    makeVertex(1.0, 0.0, 0.0),
    makeVertex(1.0, 0.0, 1.0),
    makeVertex(1.0, 0.0, 1.0),
    makeVertex(0.0, 0.0, 1.0),
    makeVertex(0.0, 0.0, 1.0),
    makeVertex(0.0, 0.0, 0.0),

    // Top face edges (y = 1)
    makeVertex(0.0, 1.0, 0.0),
    makeVertex(1.0, 1.0, 0.0),
    makeVertex(1.0, 1.0, 0.0),
    makeVertex(1.0, 1.0, 1.0),
    makeVertex(1.0, 1.0, 1.0),
    makeVertex(0.0, 1.0, 1.0),
    makeVertex(0.0, 1.0, 1.0),
    makeVertex(0.0, 1.0, 0.0),

    // Vertical edges
    makeVertex(0.0, 0.0, 0.0),
    makeVertex(0.0, 1.0, 0.0),
    makeVertex(1.0, 0.0, 0.0),
    makeVertex(1.0, 1.0, 0.0),
    makeVertex(1.0, 0.0, 1.0),
    makeVertex(1.0, 1.0, 1.0),
    makeVertex(0.0, 0.0, 1.0),
    makeVertex(0.0, 1.0, 1.0),
};

pub const line_vertex_count: u32 = @intCast(line_vertices.len);
