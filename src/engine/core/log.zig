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
