//! Main renderer that manages OpenGL state and rendering pipeline.

const std = @import("std");
const c = @import("../../c.zig").c;

const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Shader = @import("shader.zig").Shader;
const Mesh = @import("mesh.zig").Mesh;
const log = @import("../core/log.zig");

pub fn setVSync(enabled: bool) void {
    _ = c.SDL_GL_SetSwapInterval(if (enabled) 1 else 0);
    log.log.info("VSync: {}", .{enabled});
}

/// Get OpenGL version as integers
pub fn getGLVersion() struct { major: i32, minor: i32 } {
    var major: c.GLint = undefined;
    var minor: c.GLint = undefined;
    c.glGetIntegerv(c.GL_MAJOR_VERSION, &major);
    c.glGetIntegerv(c.GL_MINOR_VERSION, &minor);
    return .{ .major = major, .minor = minor };
}

/// Check if an OpenGL extension is supported
pub fn hasExtension(name: [*c]const u8) bool {
    var num_extensions: c.GLint = undefined;
    c.glGetIntegerv(c.GL_NUM_EXTENSIONS, &num_extensions);

    var i: c.GLuint = 0;
    while (i < @as(c.GLuint, @intCast(num_extensions))) : (i += 1) {
        const ext = c.glGetStringi(c.GL_EXTENSIONS, i);
        if (ext != null and std.mem.eql(u8, std.mem.span(ext), std.mem.span(name))) {
            return true;
        }
    }
    return false;
}
