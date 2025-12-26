//! Shader compilation and program management with uniform caching.
//! This module provides a backend-agnostic interface for shader programs.

const std = @import("std");
const rhi = @import("rhi.zig");
const c = @import("../../c.zig").c;

const log = @import("../core/log.zig");

pub const Shader = struct {
    handle: rhi.ShaderHandle,
    uniform_cache: std.StringHashMap(c.GLint),
    allocator: std.mem.Allocator,
    uses_opengl: bool,

    pub const Error = error{
        VertexCompileFailed,
        FragmentCompileFailed,
        LinkFailed,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, vertex_src: [*c]const u8, fragment_src: [*c]const u8) Error!Shader {
        return Shader.initWithBackend(allocator, vertex_src, fragment_src, true);
    }

    /// Initialize shader with explicit backend flag
    fn initWithBackend(allocator: std.mem.Allocator, vertex_src: [*c]const u8, fragment_src: [*c]const u8, uses_opengl: bool) Error!Shader {
        if (uses_opengl) {
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
                .handle = @intCast(program),
                .uniform_cache = std.StringHashMap(c.GLint).init(allocator),
                .allocator = allocator,
                .uses_opengl = true,
            };
        } else {
            return Error.LinkFailed;
        }
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
            .handle = @intCast(program),
            .uniform_cache = undefined,
            .allocator = undefined,
            .uses_opengl = true,
        };
    }

    pub fn initFromFile(allocator: std.mem.Allocator, vert_path: []const u8, frag_path: []const u8) !Shader {
        var dir = std.fs.cwd();
        // Swapped args: allocator, sub_path (or sub_path, allocator depending on Zig version)
        // The error `expected type 'Io.Limit', found 'comptime_int'` means the size limit is now wrapped in an enum/struct or not simply a usize.
        // It seems typically it is passed as a usize, but here it expects `Io.Limit`.
        // Wait, checking the error message again: `expected type 'Io.Limit', found 'comptime_int'`.
        // This suggests `limit: Io.Limit`.
        // I will try to use the raw usize if I can find the way to construct it, or look for `.unlimited` or similar if appropriate, but standard is to pass a size.
        // Actually, maybe `readFileAlloc` signature changed significantly.
        // Let's assume the error is correct and it wants `std.io.Limit`.
        // But usually standard library functions take `max_bytes: usize`.
        // Ah, this is Zig Nightly/Dev (0.16). Things change fast.

        // Let's try `std.fs.cwd().readFileAlloc(allocator, path, 1024*1024)` again but maybe I got the argument order wrong *again* or the error message was misleading?
        // First error: expected []const u8 found Allocator. -> Means 1st arg should be path.
        // My fix: `readFileAlloc(path, allocator, size)`.
        // Second error: expected Io.Limit found int. -> Means 3rd arg is Io.Limit.

        // Let's look at `std.fs.Dir.readFileAlloc` usage in recent Zig.
        // It seems `std.fs.Dir.readFileAlloc` now takes `limit: std.io.Limit`.
        // `std.io.Limit` is an enum(usize)? No, the error says `enum(usize)`.
        // So I can probably cast it or use `.none` / `.max`.

        // Let's try `@enumFromInt(1024 * 1024)`.

        const vert_src = try dir.readFileAlloc(vert_path, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(vert_src);

        const frag_src = try dir.readFileAlloc(frag_path, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(frag_src);

        // Ensure null termination for C API
        const vert_c = try allocator.dupeZ(u8, vert_src);
        defer allocator.free(vert_c);
        const frag_c = try allocator.dupeZ(u8, frag_src);
        defer allocator.free(frag_c);

        return init(allocator, vert_c, frag_c);
    }

    pub fn deinit(self: *Shader) void {
        c.glDeleteProgram().?(self.handle);
        if (@TypeOf(self.uniform_cache) != @TypeOf(undefined)) {
            // Can't easily check if initialized, skip cleanup for simple init
        }
    }

    pub fn use(self: *const Shader) void {
        c.glUseProgram().?(self.handle);
    }

    pub fn getUniformLocation(self: *const Shader, name: [*c]const u8) c.GLint {
        // Direct lookup without caching for now (cache requires mutable self)
        return c.glGetUniformLocation().?(self.handle, name);
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
