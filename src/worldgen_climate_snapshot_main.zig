const std = @import("std");
const fs = @import("fs");
const climate_snapshot = @import("world-worldgen").climate_snapshot;

const OutputFormat = enum { json, ppm };

const CliOptions = struct {
    config: climate_snapshot.Config = .{},
    output_path: []const u8 = "zig-out/worldgen-climate-snapshot.json",
    format: OutputFormat = .json,
    field: climate_snapshot.Field = .temperature,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    const options = parseArgs(&args) catch |err| switch (err) {
        error.HelpRequested => {
            try writeUsage(init);
            return;
        },
        else => return err,
    };
    var snapshot = try climate_snapshot.capture(allocator, options.config);
    defer snapshot.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    switch (options.format) {
        .json => try climate_snapshot.writeJson(&aw.writer, snapshot),
        .ppm => try climate_snapshot.writeHeatmapPpm(&aw.writer, snapshot, options.field),
    }

    if (std.mem.eql(u8, options.output_path, "-")) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try stdout_writer.interface.writeAll(aw.written());
        try stdout_writer.interface.flush();
        return;
    }

    if (fs.path.dirname(options.output_path)) |dir| {
        try fs.cwd().makePath(dir);
    }
    var file = try fs.cwd().createFile(options.output_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(aw.written());
}

fn writeUsage(init: std.process.Init) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.writeAll(
        \\Usage: zig build worldgen-climate-snapshot -- [options]
        \\
        \\Options:
        \\  --seed <u64>           World seed (default: 42)
        \\  --origin-x <i32>       Snapshot origin X (default: -256)
        \\  --origin-z <i32>       Snapshot origin Z (default: -256)
        \\  --width <u32>          Sample width (default: 128)
        \\  --depth <u32>          Sample depth (default: 128)
        \\  --step <f32>           World-space distance between samples (default: 4)
        \\  --reduction <u8>       Noise octave reduction level (default: 0)
        \\  --format <json|ppm>    Output format (default: json)
        \\  --field <name>         PPM field: temperature, humidity, continentalness, erosion, ruggedness, river_mask, ridge_mask, cave_region, elevation, height
        \\  --output <path|->      Output file or stdout (default: zig-out/worldgen-climate-snapshot.json)
        \\
    );
    try stderr.flush();
}

fn parseArgs(args: *std.process.Args.Iterator) !CliOptions {
    var options = CliOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) return error.HelpRequested;
        const value = args.next() orelse return error.MissingArgumentValue;
        if (std.mem.eql(u8, arg, "--seed")) {
            options.config.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--origin-x")) {
            options.config.origin_x = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, arg, "--origin-z")) {
            options.config.origin_z = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, arg, "--width")) {
            options.config.width = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            options.config.depth = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--step")) {
            options.config.step = try std.fmt.parseFloat(f32, value);
        } else if (std.mem.eql(u8, arg, "--reduction")) {
            options.config.reduction = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, arg, "--output")) {
            options.output_path = value;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (std.mem.eql(u8, value, "json")) {
                options.format = .json;
            } else if (std.mem.eql(u8, value, "ppm")) {
                options.format = .ppm;
            } else {
                return error.InvalidOutputFormat;
            }
        } else if (std.mem.eql(u8, arg, "--field")) {
            options.field = climate_snapshot.parseField(value) orelse return error.InvalidSnapshotField;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}
