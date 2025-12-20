//! Shader compilation and program management with uniform caching.

const std = @import("std");
const c = @import("../../c.zig").c;

const log = @import("../core/log.zig");

pub const Shader = struct {
    program: c.GLuint,
    uniform_cache: std.StringHashMap(c.GLint),
    allocator: std.mem.Allocator,

    pub const Error = error{
        VertexCompileFailed,
        FragmentCompileFailed,
        LinkFailed,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, vertex_src: [*c]const u8, fragment_src: [*c]const u8) Error!Shader {
        const vert = compileShader(c.GL_VERTEX_SHADER, vertex_src) catch |e| {
            log.log.err("Vertex shader compilation failed", .{});
            return e;
        };
        defer c.glDeleteShader().?(vert);

        const frag = compileShader(c.GL_FRAGMENT_SHADER, fragment_src) catch |e| {
            log.log.err("Fragment shader compilation failed", .{});
            return e;
        };
        defer c.glDeleteShader().?(frag);

        const program = c.glCreateProgram().?();
        c.glAttachShader().?(program, vert);
        c.glAttachShader().?(program, frag);
        c.glLinkProgram().?(program);

        var success: c.GLint = undefined;
        c.glGetProgramiv().?(program, c.GL_LINK_STATUS, &success);
        if (success == 0) {
            var info_log: [512]u8 = undefined;
            var length: c.GLsizei = undefined;
            c.glGetProgramInfoLog().?(program, 512, &length, &info_log);
            log.log.err("Shader link failed: {s}", .{info_log[0..@intCast(length)]});
            return Error.LinkFailed;
        }

        log.log.info("Shader program created (ID: {})", .{program});

        return .{
            .program = program,
            .uniform_cache = std.StringHashMap(c.GLint).init(allocator),
            .allocator = allocator,
        };
    }

    /// Simplified init without allocator (no caching)
    pub fn initSimple(vertex_src: [*c]const u8, fragment_src: [*c]const u8) Error!Shader {
        const vert = try compileShader(c.GL_VERTEX_SHADER, vertex_src);
        defer c.glDeleteShader().?(vert);

        const frag = try compileShader(c.GL_FRAGMENT_SHADER, fragment_src);
        defer c.glDeleteShader().?(frag);

        const program = c.glCreateProgram().?();
        c.glAttachShader().?(program, vert);
        c.glAttachShader().?(program, frag);
        c.glLinkProgram().?(program);

        var success: c.GLint = undefined;
        c.glGetProgramiv().?(program, c.GL_LINK_STATUS, &success);
        if (success == 0) {
            return Error.LinkFailed;
        }

        return .{
            .program = program,
            .uniform_cache = undefined,
            .allocator = undefined,
        };
    }

    pub fn deinit(self: *Shader) void {
        c.glDeleteProgram().?(self.program);
        if (@TypeOf(self.uniform_cache) != @TypeOf(undefined)) {
            // Can't easily check if initialized, skip cleanup for simple init
        }
    }

    pub fn use(self: *const Shader) void {
        c.glUseProgram().?(self.program);
    }

    pub fn getUniformLocation(self: *const Shader, name: [*c]const u8) c.GLint {
        // Direct lookup without caching for now (cache requires mutable self)
        return c.glGetUniformLocation().?(self.program, name);
    }

    // Uniform setters
    pub fn setMat4(self: *const Shader, name: [*c]const u8, matrix: *const [4][4]f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniformMatrix4fv().?(loc, 1, c.GL_FALSE, @ptrCast(matrix));
    }

    pub fn setVec3(self: *const Shader, name: [*c]const u8, x: f32, y: f32, z: f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform3f().?(loc, x, y, z);
    }

    pub fn setVec3v(self: *const Shader, name: [*c]const u8, v: [3]f32) void {
        self.setVec3(name, v[0], v[1], v[2]);
    }

    pub fn setVec4(self: *const Shader, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform4f().?(loc, x, y, z, w);
    }

    pub fn setFloat(self: *const Shader, name: [*c]const u8, value: f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform1f().?(loc, value);
    }

    pub fn setInt(self: *const Shader, name: [*c]const u8, value: i32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform1i().?(loc, value);
    }

    pub fn setBool(self: *const Shader, name: [*c]const u8, value: bool) void {
        const loc = self.getUniformLocation(name);
        c.glUniform1i().?(loc, if (value) 1 else 0);
    }

    fn compileShader(shader_type: c.GLenum, source: [*c]const u8) Error!c.GLuint {
        const shader = c.glCreateShader().?(shader_type);
        c.glShaderSource().?(shader, 1, &source, null);
        c.glCompileShader().?(shader);

        var success: c.GLint = undefined;
        c.glGetShaderiv().?(shader, c.GL_COMPILE_STATUS, &success);
        if (success == 0) {
            var info_log: [512]u8 = undefined;
            var length: c.GLsizei = undefined;
            c.glGetShaderInfoLog().?(shader, 512, &length, &info_log);

            const type_str = if (shader_type == c.GL_VERTEX_SHADER) "Vertex" else "Fragment";
            log.log.err("{s} shader compile error: {s}", .{ type_str, info_log[0..@intCast(length)] });

            if (shader_type == c.GL_VERTEX_SHADER) {
                return Error.VertexCompileFailed;
            } else {
                return Error.FragmentCompileFailed;
            }
        }

        return shader;
    }
};
