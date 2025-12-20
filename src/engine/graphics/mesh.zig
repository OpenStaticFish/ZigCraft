//! Mesh abstraction for VAO/VBO management.

const std = @import("std");
const c = @import("../../c.zig").c;

pub const Mesh = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
    ebo: c.GLuint,
    vertex_count: u32,
    index_count: u32,
    has_indices: bool,

    pub const Vertex = struct {
        position: [3]f32,
        color: [3]f32,
        normal: [3]f32 = .{ 0, 1, 0 },
        uv: [2]f32 = .{ 0, 0 },
    };

    /// Create mesh from vertex data (no indices)
    pub fn init(vertices: []const f32, floats_per_vertex: u32) Mesh {
        var vao: c.GLuint = undefined;
        var vbo: c.GLuint = undefined;

        c.glGenVertexArrays().?(1, &vao);
        c.glGenBuffers().?(1, &vbo);

        c.glBindVertexArray().?(vao);
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, vbo);
        c.glBufferData().?(
            c.GL_ARRAY_BUFFER,
            @intCast(vertices.len * @sizeOf(f32)),
            vertices.ptr,
            c.GL_STATIC_DRAW,
        );

        const stride: c.GLsizei = @intCast(floats_per_vertex * @sizeOf(f32));

        // Position (location 0)
        c.glVertexAttribPointer().?(0, 3, c.GL_FLOAT, c.GL_FALSE, stride, null);
        c.glEnableVertexAttribArray().?(0);

        // Color (location 1) - offset by 3 floats
        if (floats_per_vertex >= 6) {
            c.glVertexAttribPointer().?(1, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(3 * @sizeOf(f32)));
            c.glEnableVertexAttribArray().?(1);
        }

        // Normal (location 2) - offset by 6 floats
        if (floats_per_vertex >= 9) {
            c.glVertexAttribPointer().?(2, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(6 * @sizeOf(f32)));
            c.glEnableVertexAttribArray().?(2);
        }

        // UV (location 3) - offset by 9 floats
        if (floats_per_vertex >= 11) {
            c.glVertexAttribPointer().?(3, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(9 * @sizeOf(f32)));
            c.glEnableVertexAttribArray().?(3);
        }

        c.glBindVertexArray().?(0);

        return .{
            .vao = vao,
            .vbo = vbo,
            .ebo = 0,
            .vertex_count = @intCast(vertices.len / floats_per_vertex),
            .index_count = 0,
            .has_indices = false,
        };
    }

    /// Create mesh with indices
    pub fn initIndexed(vertices: []const f32, floats_per_vertex: u32, indices: []const u32) Mesh {
        var mesh = init(vertices, floats_per_vertex);
        mesh.has_indices = true;
        mesh.index_count = @intCast(indices.len);

        c.glBindVertexArray().?(mesh.vao);

        c.glGenBuffers().?(1, &mesh.ebo);
        c.glBindBuffer().?(c.GL_ELEMENT_ARRAY_BUFFER, mesh.ebo);
        c.glBufferData().?(
            c.GL_ELEMENT_ARRAY_BUFFER,
            @intCast(indices.len * @sizeOf(u32)),
            indices.ptr,
            c.GL_STATIC_DRAW,
        );

        c.glBindVertexArray().?(0);

        return mesh;
    }

    pub fn deinit(self: *Mesh) void {
        c.glDeleteVertexArrays().?(1, &self.vao);
        c.glDeleteBuffers().?(1, &self.vbo);
        if (self.has_indices) {
            c.glDeleteBuffers().?(1, &self.ebo);
        }
    }

    pub fn draw(self: *const Mesh) void {
        c.glBindVertexArray().?(self.vao);
        if (self.has_indices) {
            c.glDrawElements(c.GL_TRIANGLES, @intCast(self.index_count), c.GL_UNSIGNED_INT, null);
        } else {
            c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(self.vertex_count));
        }
    }

    /// Update vertex data (for dynamic meshes like chunk meshes)
    pub fn updateVertices(self: *Mesh, vertices: []const f32, floats_per_vertex: u32) void {
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData().?(
            c.GL_ARRAY_BUFFER,
            @intCast(vertices.len * @sizeOf(f32)),
            vertices.ptr,
            c.GL_DYNAMIC_DRAW,
        );
        self.vertex_count = @intCast(vertices.len / floats_per_vertex);
    }
};

/// Create a simple cube mesh (useful for testing)
pub fn createCubeMesh() Mesh {
    const vertices = [_]f32{
        // Front face (z = 0.5) - Red
        -0.5, -0.5, 0.5,  1.0, 0.0, 0.0,
        0.5,  -0.5, 0.5,  1.0, 0.0, 0.0,
        0.5,  0.5,  0.5,  1.0, 0.0, 0.0,
        -0.5, -0.5, 0.5,  1.0, 0.0, 0.0,
        0.5,  0.5,  0.5,  1.0, 0.0, 0.0,
        -0.5, 0.5,  0.5,  1.0, 0.0, 0.0,

        // Back face (z = -0.5) - Green
        0.5,  -0.5, -0.5, 0.0, 1.0, 0.0,
        -0.5, -0.5, -0.5, 0.0, 1.0, 0.0,
        -0.5, 0.5,  -0.5, 0.0, 1.0, 0.0,
        0.5,  -0.5, -0.5, 0.0, 1.0, 0.0,
        -0.5, 0.5,  -0.5, 0.0, 1.0, 0.0,
        0.5,  0.5,  -0.5, 0.0, 1.0, 0.0,

        // Top face (y = 0.5) - Blue
        -0.5, 0.5,  0.5,  0.0, 0.0, 1.0,
        0.5,  0.5,  0.5,  0.0, 0.0, 1.0,
        0.5,  0.5,  -0.5, 0.0, 0.0, 1.0,
        -0.5, 0.5,  0.5,  0.0, 0.0, 1.0,
        0.5,  0.5,  -0.5, 0.0, 0.0, 1.0,
        -0.5, 0.5,  -0.5, 0.0, 0.0, 1.0,

        // Bottom face (y = -0.5) - Yellow
        -0.5, -0.5, -0.5, 1.0, 1.0, 0.0,
        0.5,  -0.5, -0.5, 1.0, 1.0, 0.0,
        0.5,  -0.5, 0.5,  1.0, 1.0, 0.0,
        -0.5, -0.5, -0.5, 1.0, 1.0, 0.0,
        0.5,  -0.5, 0.5,  1.0, 1.0, 0.0,
        -0.5, -0.5, 0.5,  1.0, 1.0, 0.0,

        // Right face (x = 0.5) - Magenta
        0.5,  -0.5, 0.5,  1.0, 0.0, 1.0,
        0.5,  -0.5, -0.5, 1.0, 0.0, 1.0,
        0.5,  0.5,  -0.5, 1.0, 0.0, 1.0,
        0.5,  -0.5, 0.5,  1.0, 0.0, 1.0,
        0.5,  0.5,  -0.5, 1.0, 0.0, 1.0,
        0.5,  0.5,  0.5,  1.0, 0.0, 1.0,

        // Left face (x = -0.5) - Cyan
        -0.5, -0.5, -0.5, 0.0, 1.0, 1.0,
        -0.5, -0.5, 0.5,  0.0, 1.0, 1.0,
        -0.5, 0.5,  0.5,  0.0, 1.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 1.0, 1.0,
        -0.5, 0.5,  0.5,  0.0, 1.0, 1.0,
        -0.5, 0.5,  -0.5, 0.0, 1.0, 1.0,
    };

    return Mesh.init(&vertices, 6);
}
