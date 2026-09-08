const std = @import("std");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Running guarded transfer/readback smoke (not shader robustness verification)...\n", .{});

    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: test-robustness <built robust-demo artifact>\n", .{});
        return error.MissingDemoArtifact;
    }
    // The build must pass addArtifactArg(robust_demo), never a stale installed binary.
    const robust_demo_path = args[1];
    std.debug.print("Testing robust-demo artifact: {s}\n", .{robust_demo_path});

    var argv_buffer: [2][]const u8 = undefined;
    const argv: []const []const u8 = if (init.environ_map.get("ZIGCRAFT_DYNAMIC_LINKER")) |dynamic_linker| blk: {
        if (dynamic_linker.len == 0) {
            argv_buffer[0] = robust_demo_path;
            break :blk argv_buffer[0..1];
        }
        argv_buffer = .{ dynamic_linker, robust_demo_path };
        break :blk &argv_buffer;
    } else blk: {
        argv_buffer[0] = robust_demo_path;
        break :blk argv_buffer[0..1];
    };

    const Outcome = union(enum) {
        demo: anyerror!void,
        deadline: std.Io.Cancelable!void,
    };
    var outcomes: [2]Outcome = undefined;
    var race = std.Io.Select(Outcome).init(init.io, &outcomes);
    // runDemo owns its captured output. Cancellation also kills/reaps its child,
    // including when the child closes both pipes but has not actually exited.
    defer race.cancelDiscard();
    try race.concurrent(.deadline, std.Io.sleep, .{ init.io, .fromSeconds(30), .awake });
    try race.concurrent(.demo, runDemo, .{ allocator, init.io, argv });
    switch (try race.await()) {
        .demo => |result| try result,
        .deadline => |result| {
            try result;
            std.debug.print("Guarded transfer smoke exceeded its 30-second deadline.\n", .{});
            return error.DemoTimeout;
        },
    }
    std.debug.print("Guarded transfer/readback smoke passed; shader OOB behavior remains untested.\n", .{});
}

fn runDemo(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const run_result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const stdout = run_result.stdout;
    const stderr = run_result.stderr;
    const result = run_result.term;
    std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ stdout, stderr });

    // The artifact fails on VkResult, fence, readback, and validation errors.
    // Its exit status, not a reassuring log substring, is the test oracle.
    switch (result) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("robust-demo failed with exit code {d}\n", .{code});
                return error.DemoFailed;
            }
        },
        else => {
            std.debug.print("robust-demo terminated unexpectedly: {any}\n", .{result});
            return error.DemoCrashed;
        },
    }
}
