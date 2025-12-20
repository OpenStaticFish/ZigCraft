//! Engine-wide logging system with severity levels.

const std = @import("std");

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
};

pub const Logger = struct {
    min_level: LogLevel = .info,

    pub fn init(min_level: LogLevel) Logger {
        return .{ .min_level = min_level };
    }

    pub fn trace(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    pub fn debug(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn fatal(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    fn log(self: *const Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;

        const level_str = switch (level) {
            .trace => "[TRACE]",
            .debug => "[DEBUG]",
            .info => "[INFO] ",
            .warn => "[WARN] ",
            .err => "[ERROR]",
            .fatal => "[FATAL]",
        };

        std.debug.print("{s} " ++ fmt ++ "\n", .{level_str} ++ args);
    }
};

/// Global logger instance
pub var log = Logger.init(.debug);

/// OpenGL error checking
pub fn checkGLError(location: []const u8) bool {
    const c = @cImport({
        @cInclude("GL/glew.h");
    });

    var had_error = false;
    while (true) {
        const err = c.glGetError();
        if (err == c.GL_NO_ERROR) break;

        const err_str = switch (err) {
            c.GL_INVALID_ENUM => "GL_INVALID_ENUM",
            c.GL_INVALID_VALUE => "GL_INVALID_VALUE",
            c.GL_INVALID_OPERATION => "GL_INVALID_OPERATION",
            c.GL_OUT_OF_MEMORY => "GL_OUT_OF_MEMORY",
            c.GL_INVALID_FRAMEBUFFER_OPERATION => "GL_INVALID_FRAMEBUFFER_OPERATION",
            else => "UNKNOWN",
        };

        log.err("OpenGL error at {s}: {s} (0x{x})", .{ location, err_str, err });
        had_error = true;
    }
    return had_error;
}

/// Clear any pending GL errors
pub fn clearGLErrors() void {
    const c = @cImport({
        @cInclude("GL/glew.h");
    });
    while (c.glGetError() != c.GL_NO_ERROR) {}
}
