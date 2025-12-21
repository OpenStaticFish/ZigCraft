//! UI System for rendering 2D interface elements.
//! Uses orthographic projection and immediate-mode style rendering.

const std = @import("std");
const c = @import("../../c.zig").c;

const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Shader = @import("../graphics/shader.zig").Shader;
const Rect = @import("../core/interfaces.zig").Rect;
const InputEvent = @import("../core/interfaces.zig").InputEvent;

pub const UISystem = struct {
    shader: Shader,
    texture_shader: Shader,
    vao: c.GLuint,
    vbo: c.GLuint,
    tex_vao: c.GLuint,
    tex_vbo: c.GLuint,
    screen_width: f32,
    screen_height: f32,

    const vertex_shader =
        \\#version 330 core
        \\layout (location = 0) in vec2 aPos;
        \\layout (location = 1) in vec4 aColor;
        \\out vec4 vColor;
        \\uniform mat4 projection;
        \\void main() {
        \\    gl_Position = projection * vec4(aPos, 0.0, 1.0);
        \\    vColor = aColor;
        \\}
    ;

    const fragment_shader =
        \\#version 330 core
        \\in vec4 vColor;
        \\out vec4 FragColor;
        \\void main() {
        \\    FragColor = vColor;
        \\}
    ;

    const texture_vertex_shader =
        \\#version 330 core
        \\layout (location = 0) in vec2 aPos;
        \\layout (location = 1) in vec2 aTexCoord;
        \\out vec2 vTexCoord;
        \\uniform mat4 projection;
        \\void main() {
        \\    gl_Position = projection * vec4(aPos, 0.0, 1.0);
        \\    vTexCoord = aTexCoord;
        \\}
    ;

    const texture_fragment_shader =
        \\#version 330 core
        \\in vec2 vTexCoord;
        \\out vec4 FragColor;
        \\uniform sampler2D uTexture;
        \\void main() {
        \\    FragColor = texture(uTexture, vTexCoord);
        \\}
    ;

    pub fn init(width: u32, height: u32) !UISystem {
        const shader = try Shader.initSimple(vertex_shader, fragment_shader);
        const tex_shader = try Shader.initSimple(texture_vertex_shader, texture_fragment_shader);

        var vao: c.GLuint = undefined;
        var vbo: c.GLuint = undefined;
        c.glGenVertexArrays().?(1, &vao);
        c.glGenBuffers().?(1, &vbo);

        c.glBindVertexArray().?(vao);
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, vbo);

        // Position (2 floats) + Color (4 floats) = 6 floats per vertex
        const stride: c.GLsizei = 6 * @sizeOf(f32);
        c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
        c.glEnableVertexAttribArray().?(0);
        c.glVertexAttribPointer().?(1, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));
        c.glEnableVertexAttribArray().?(1);

        // Texture VAO/VBO
        var tex_vao: c.GLuint = undefined;
        var tex_vbo: c.GLuint = undefined;
        c.glGenVertexArrays().?(1, &tex_vao);
        c.glGenBuffers().?(1, &tex_vbo);
        c.glBindVertexArray().?(tex_vao);
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, tex_vbo);
        // Position (2) + TexCoord (2) = 4 floats
        const tex_stride: c.GLsizei = 4 * @sizeOf(f32);
        c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, tex_stride, null);
        c.glEnableVertexAttribArray().?(0);
        c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, tex_stride, @ptrFromInt(2 * @sizeOf(f32)));
        c.glEnableVertexAttribArray().?(1);

        c.glBindVertexArray().?(0);

        return .{
            .shader = shader,
            .texture_shader = tex_shader,
            .vao = vao,
            .vbo = vbo,
            .tex_vao = tex_vao,
            .tex_vbo = tex_vbo,
            .screen_width = @floatFromInt(width),
            .screen_height = @floatFromInt(height),
        };
    }

    pub fn deinit(self: *UISystem) void {
        self.shader.deinit();
        self.texture_shader.deinit();
        c.glDeleteVertexArrays().?(1, &self.vao);
        c.glDeleteBuffers().?(1, &self.vbo);
        c.glDeleteVertexArrays().?(1, &self.tex_vao);
        c.glDeleteBuffers().?(1, &self.tex_vbo);
    }

    pub fn resize(self: *UISystem, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    /// Begin UI rendering (call before drawing any UI elements)
    pub fn begin(self: *UISystem) void {
        // Disable depth test and culling for UI
        c.glDisable(c.GL_DEPTH_TEST);
        c.glDisable(c.GL_CULL_FACE);

        self.shader.use();

        // Orthographic projection: (0,0) at top-left
        const proj = Mat4.orthographic(0, self.screen_width, self.screen_height, 0, -1, 1);
        self.shader.setMat4("projection", &proj.data);

        c.glBindVertexArray().?(self.vao);
    }

    /// End UI rendering (call after drawing all UI elements)
    pub fn end(self: *UISystem) void {
        _ = self;
        c.glBindVertexArray().?(0);
        c.glEnable(c.GL_DEPTH_TEST);
        c.glEnable(c.GL_CULL_FACE);
    }

    /// Draw a filled rectangle
    pub fn drawRect(self: *UISystem, rect: Rect, color: Color) void {
        const x = rect.x;
        const y = rect.y;
        const w = rect.width;
        const h = rect.height;

        // Two triangles forming a quad
        // Each vertex: x, y, r, g, b, a
        const vertices = [_]f32{
            // Triangle 1
            x,     y,     color.r, color.g, color.b, color.a,
            x + w, y,     color.r, color.g, color.b, color.a,
            x + w, y + h, color.r, color.g, color.b, color.a,
            // Triangle 2
            x,     y,     color.r, color.g, color.b, color.a,
            x + w, y + h, color.r, color.g, color.b, color.a,
            x,     y + h, color.r, color.g, color.b, color.a,
        };

        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_DYNAMIC_DRAW);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }

    /// Draw a textured rectangle
    pub fn drawTexture(self: *UISystem, texture_id: c.GLuint, rect: Rect) void {
        const x = rect.x;
        const y = rect.y;
        const w = rect.width;
        const h = rect.height;

        self.texture_shader.use();
        const proj = Mat4.orthographic(0, self.screen_width, self.screen_height, 0, -1, 1);
        self.texture_shader.setMat4("projection", &proj.data);

        c.glActiveTexture().?(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
        self.texture_shader.setInt("uTexture", 0);

        const vertices = [_]f32{
            // pos, uv
            x,     y,     0.0, 0.0,
            x + w, y,     1.0, 0.0,
            x + w, y + h, 1.0, 1.0,
            x,     y,     0.0, 0.0,
            x + w, y + h, 1.0, 1.0,
            x,     y + h, 0.0, 1.0,
        };

        c.glBindVertexArray().?(self.tex_vao);
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, self.tex_vbo);
        c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_DYNAMIC_DRAW);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
        c.glBindVertexArray().?(0);

        // Re-use default shader for other elements
        self.shader.use();
        c.glBindVertexArray().?(self.vao);
    }

    /// Draw a rectangle outline
    pub fn drawRectOutline(self: *UISystem, rect: Rect, color: Color, thickness: f32) void {
        // Top
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, color);
        // Bottom
        self.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - thickness, .width = rect.width, .height = thickness }, color);
        // Left
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, color);
        // Right
        self.drawRect(.{ .x = rect.x + rect.width - thickness, .y = rect.y, .width = thickness, .height = rect.height }, color);
    }
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    pub const dark_gray = Color{ .r = 0.2, .g = 0.2, .b = 0.2 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            .a = 1.0,
        };
    }
};

/// Base widget structure (implement interface pattern)
pub const Widget = struct {
    bounds: Rect,
    visible: bool = true,
    enabled: bool = true,

    // Virtual functions
    drawFn: *const fn (*Widget) void,
    handleInputFn: *const fn (*Widget, InputEvent) bool,

    pub fn draw(self: *Widget, widget: *Widget) void {
        if (self.visible) {
            self.drawFn(widget);
        }
    }

    pub fn handleInput(self: *Widget, widget: *Widget, event: InputEvent) bool {
        if (self.enabled) {
            return self.handleInputFn(widget, event);
        }
        return false;
    }
};
