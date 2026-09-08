const std = @import("std");
const App = @import("game/app.zig").App;
const engine_core = @import("engine-core");
const log = engine_core.log;

comptime {
    if (@import("build_options").benchmark and !@import("engine-graphics").skips_presentation) {
        @compileError("The benchmark graphics backend must be compiled without presentation");
    }
}

pub const panic = std.debug.FullPanic(crashPanic);

fn crashPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    engine_core.crash_handler.writePanicDump(first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    engine_core.initCrashHandler();

    log.initDefaultFile() catch |err| {
        std.debug.print("[WARN] failed to initialize file logging: {}\n", .{err});
    };
    defer log.deinit();

    const app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
