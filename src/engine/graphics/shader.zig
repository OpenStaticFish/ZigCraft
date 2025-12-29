//! Shader compilation and program management with uniform caching.
//! This module provides a backend-agnostic interface for shader programs.

const std = @import("std");
const rhi = @import("rhi.zig");
const c = @import("../../c.zig").c;

const log = @import("../core/log.zig");

pub const Shader = struct {
    handle: rhi.ShaderHandle,
    uniform_cache: ?std.StringHashMap(i32),
    allocator: ?std.mem.Allocator,
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
                .uniform_cache = std.StringHashMap(i32).init(allocator),
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
            .uniform_cache = null,
            .allocator = null,
            .uses_opengl = true,
        };
    }

    pub fn initFromFile(allocator: std.mem.Allocator, vert_path: []const u8, frag_path: []const u8) !Shader {
        var dir = std.fs.cwd();
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
        if (self.uniform_cache) |*cache| {
            cache.deinit();
        }
    }

    pub fn use(self: *const Shader) void {
        c.glUseProgram().?(self.handle);
    }

    /// Get uniform location with caching. On first call for a given name,
    /// queries OpenGL and caches the result. Subsequent calls return cached value.
    pub fn getUniformLocation(self: *Shader, name: [:0]const u8) i32 {
        // Check cache first (if caching is enabled)
        if (self.uniform_cache) |*cache| {
            if (cache.get(name)) |cached_loc| {
                return cached_loc;
            }

            // Cache miss - query OpenGL
            const loc: i32 = c.glGetUniformLocation().?(self.handle, name.ptr);

            // Store in cache (best effort, ignore allocation failure)
            cache.put(name, loc) catch {};

            return loc;
        }

        // No cache available - direct lookup
        return c.glGetUniformLocation().?(self.handle, name.ptr);
    }

    /// Get uniform location without caching (const version for temporary shaders)
    pub fn getUniformLocationUncached(self: *const Shader, name: [:0]const u8) i32 {
        return c.glGetUniformLocation().?(self.handle, name.ptr);
    }

    // Uniform setters - use uncached version since these take const self
    pub fn setMat4(self: *const Shader, name: [:0]const u8, matrix: *const [4][4]f32) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniformMatrix4fv().?(loc, 1, c.GL_FALSE, @ptrCast(matrix));
    }

    pub fn setVec3(self: *const Shader, name: [:0]const u8, x: f32, y: f32, z: f32) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniform3f().?(loc, x, y, z);
    }

    pub fn setVec3v(self: *const Shader, name: [:0]const u8, v: [3]f32) void {
        self.setVec3(name, v[0], v[1], v[2]);
    }

    pub fn setVec4(self: *const Shader, name: [:0]const u8, x: f32, y: f32, z: f32, w: f32) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniform4f().?(loc, x, y, z, w);
    }

    pub fn setFloat(self: *const Shader, name: [:0]const u8, value: f32) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniform1f().?(loc, value);
    }

    pub fn setInt(self: *const Shader, name: [:0]const u8, value: i32) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniform1i().?(loc, value);
    }

    pub fn setBool(self: *const Shader, name: [:0]const u8, value: bool) void {
        const loc = self.getUniformLocationUncached(name);
        c.glUniform1i().?(loc, if (value) 1 else 0);
    }

    // Cached versions of uniform setters for persistent shaders
    pub fn setMat4Cached(self: *Shader, name: [:0]const u8, matrix: *const [4][4]f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniformMatrix4fv().?(loc, 1, c.GL_FALSE, @ptrCast(matrix));
    }

    pub fn setVec3Cached(self: *Shader, name: [:0]const u8, x: f32, y: f32, z: f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform3f().?(loc, x, y, z);
    }

    pub fn setFloatCached(self: *Shader, name: [:0]const u8, value: f32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform1f().?(loc, value);
    }

    pub fn setIntCached(self: *Shader, name: [:0]const u8, value: i32) void {
        const loc = self.getUniformLocation(name);
        c.glUniform1i().?(loc, value);
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
