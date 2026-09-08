const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence.zig");
const data = @import("data.zig");
const Settings = data.Settings;
const fs = @import("fs");

test "setTexturePack returns early when same value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.texture_pack);
}

test "setTexturePack changes value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "mypack");
    try testing.expectEqualStrings("mypack", settings.texture_pack);
    persistence.deinit(&settings, allocator);
}

test "setTexturePack handles multiple changes" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "pack1");
    try testing.expectEqualStrings("pack1", settings.texture_pack);

    try persistence.setTexturePack(&settings, allocator, "pack2");
    try testing.expectEqualStrings("pack2", settings.texture_pack);
    persistence.deinit(&settings, allocator);
}

test "setEnvironmentMap returns early when same value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default", .environment_map = "default" };

    try persistence.setEnvironmentMap(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.environment_map);
}

test "setEnvironmentMap changes value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default", .environment_map = "default" };

    try persistence.setEnvironmentMap(&settings, allocator, "sunset.exr");
    try testing.expectEqualStrings("sunset.exr", settings.environment_map);
    persistence.deinit(&settings, allocator);
}

test "Settings.getShadowResolution returns correct resolution" {
    var settings = Settings{};

    settings.shadow_quality = 0;
    try testing.expectEqual(@as(u32, 1024), settings.getShadowResolution());

    settings.shadow_quality = 1;
    try testing.expectEqual(@as(u32, 1536), settings.getShadowResolution());

    settings.shadow_quality = 2;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 3;
    try testing.expectEqual(@as(u32, 4096), settings.getShadowResolution());
}

test "Settings.getShadowResolution clamps out-of-bounds" {
    var settings = Settings{};
    settings.shadow_quality = 99;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

test "Settings.getResolutionIndex finds matching resolution" {
    var settings = Settings{ .window_width = 1920, .window_height = 1080 };
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.getResolutionIndex returns default for unknown" {
    var settings = Settings{ .window_width = 9999, .window_height = 9999 };
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.setResolutionByIndex updates dimensions" {
    var settings = Settings{};
    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);
}

test "Settings.setResolutionByIndex ignores invalid index" {
    var settings = Settings{ .window_width = 1920, .window_height = 1080 };
    settings.setResolutionByIndex(99);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
}

test "Settings default values" {
    const settings = Settings{};
    try testing.expectEqual(@as(i32, 15), settings.render_distance);
    try testing.expectEqual(@as(f32, 50.0), settings.mouse_sensitivity);
    try testing.expectEqual(true, settings.vsync);
    try testing.expectEqual(@as(f32, 45.0), settings.fov);
    try testing.expectEqual(true, settings.textures_enabled);
    try testing.expectEqual(false, settings.wireframe_enabled);
}

test "SHADOW_QUALITIES array has correct values" {
    try testing.expectEqual(@as(u32, 1024), data.SHADOW_QUALITIES[0].resolution);
    try testing.expectEqualStrings("LOW", data.SHADOW_QUALITIES[0].label);

    try testing.expectEqual(@as(u32, 1536), data.SHADOW_QUALITIES[1].resolution);
    try testing.expectEqualStrings("MEDIUM", data.SHADOW_QUALITIES[1].label);

    try testing.expectEqual(@as(u32, 2048), data.SHADOW_QUALITIES[2].resolution);
    try testing.expectEqualStrings("HIGH", data.SHADOW_QUALITIES[2].label);

    try testing.expectEqual(@as(u32, 4096), data.SHADOW_QUALITIES[3].resolution);
    try testing.expectEqualStrings("ULTRA", data.SHADOW_QUALITIES[3].label);
}

test "RESOLUTIONS array has expected entries" {
    try testing.expectEqual(@as(u32, 1920), data.RESOLUTIONS[2].width);
    try testing.expectEqual(@as(u32, 1080), data.RESOLUTIONS[2].height);
    try testing.expectEqualStrings("1920X1080", data.RESOLUTIONS[2].label);
}

test "RESOLUTIONS covers standard resolutions" {
    try testing.expectEqual(@as(u32, 7), data.RESOLUTIONS.len);

    try testing.expectEqual(@as(u32, 1280), data.RESOLUTIONS[0].width);
    try testing.expectEqual(@as(u32, 720), data.RESOLUTIONS[0].height);

    try testing.expectEqual(@as(u32, 1600), data.RESOLUTIONS[1].width);
    try testing.expectEqual(@as(u32, 900), data.RESOLUTIONS[1].height);
}

test "Settings resolution roundtrip" {
    var settings = Settings{};

    for (0..data.RESOLUTIONS.len) |i| {
        settings.setResolutionByIndex(i);
        try testing.expectEqual(@as(usize, i), settings.getResolutionIndex());
    }
}

test "settings save preserves existing JSON on serialization and temporary file creation failures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = fs.Dir{ .inner = tmp.dir };
    var settings = Settings{ .render_distance = 21 };
    try persistence.saveToDir(&settings, testing.allocator, home);
    const before = try home.readFileAlloc(".config/zigcraft/settings.json", testing.allocator, 16 * 1024);
    defer testing.allocator.free(before);

    settings.render_distance = 6;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, persistence.saveToDir(&settings, failing.allocator(), home));
    const after = try home.readFileAlloc(".config/zigcraft/settings.json", testing.allocator, 16 * 1024);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    try home.makePath(".config/zigcraft/settings.json.tmp");
    try testing.expectError(error.IsDir, persistence.saveToDir(&settings, testing.allocator, home));
    const after_create_failure = try home.readFileAlloc(".config/zigcraft/settings.json", testing.allocator, 16 * 1024);
    defer testing.allocator.free(after_create_failure);
    try testing.expectEqualStrings(before, after_create_failure);
}

const SaveFailure = enum { write, sync, rename };

// Inject failures around real filesystem operations so preservation assertions
// inspect the actual previous settings file, not simulated file contents.
const FailingSaveDir = struct {
    inner: fs.Dir,
    failure: SaveFailure,

    pub fn makePath(self: @This(), path: []const u8) !void {
        try self.inner.makePath(path);
    }

    pub fn createFile(self: @This(), path: []const u8, flags: fs.CreateFileOptions) !File {
        return .{ .inner = try self.inner.createFile(path, flags), .failure = self.failure };
    }

    pub fn rename(self: @This(), from: []const u8, to: []const u8) !void {
        if (self.failure == .rename) return error.AccessDenied;
        try self.inner.rename(from, to);
    }

    const File = struct {
        inner: fs.File,
        failure: SaveFailure,

        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            if (self.failure == .write) {
                try self.inner.writeAll(bytes[0..@min(8, bytes.len)]);
                return error.NoSpaceLeft;
            }
            try self.inner.writeAll(bytes);
        }

        pub fn sync(self: @This()) !void {
            if (self.failure == .sync) return error.InputOutput;
            try self.inner.sync();
        }

        pub fn close(self: @This()) void {
            self.inner.close();
        }
    };
};

test "settings save preserves prior JSON on partial write sync and rename failures then replaces on retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = fs.Dir{ .inner = tmp.dir };
    var settings = Settings{ .render_distance = 21 };
    try persistence.saveToDir(&settings, testing.allocator, home);
    const before = try home.readFileAlloc(".config/zigcraft/settings.json", testing.allocator, 16 * 1024);
    defer testing.allocator.free(before);
    settings.render_distance = 6;

    const cases = [_]struct { failure: SaveFailure, expected_error: anyerror }{
        .{ .failure = .write, .expected_error = error.NoSpaceLeft },
        .{ .failure = .sync, .expected_error = error.InputOutput },
        .{ .failure = .rename, .expected_error = error.AccessDenied },
    };
    for (cases) |case| {
        try testing.expectError(case.expected_error, persistence.saveToDir(&settings, testing.allocator, FailingSaveDir{ .inner = home, .failure = case.failure }));
        const after = try home.readFileAlloc(".config/zigcraft/settings.json", testing.allocator, 16 * 1024);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
    }

    try persistence.saveToDir(&settings, testing.allocator, home);
    var loaded = try persistence.loadFromDir(home, testing.allocator);
    defer persistence.deinit(&loaded, testing.allocator);
    try testing.expectEqual(@as(i32, 6), loaded.render_distance);
    try testing.expectError(error.FileNotFound, home.access(".config/zigcraft/settings.json.tmp", .{}));
}

test "settings load propagates missing malformed and allocation failures without leaking strings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = fs.Dir{ .inner = tmp.dir };
    try testing.expectError(error.FileNotFound, persistence.loadFromDir(home, testing.allocator));

    const settings = Settings{ .texture_pack = "custom-pack", .environment_map = "sunset.exr" };
    try persistence.saveToDir(&settings, testing.allocator, home);
    try testing.checkAllAllocationFailures(testing.allocator, loadOwnedStrings, .{home});

    const file = try home.createFile(".config/zigcraft/settings.json", .{});
    defer file.close();
    try file.writeAll("{\"vsync\": []}");
    try testing.expectError(error.UnexpectedToken, persistence.loadFromDir(home, testing.allocator));
}

fn loadOwnedStrings(allocator: std.mem.Allocator, home: fs.Dir) !void {
    var settings = try persistence.loadFromDir(home, allocator);
    defer persistence.deinit(&settings, allocator);
    try testing.expectEqualStrings("custom-pack", settings.texture_pack);
    try testing.expectEqualStrings("sunset.exr", settings.environment_map);
}

test "settings load preserves backend supported values outside menu choices" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = fs.Dir{ .inner = tmp.dir };
    const settings = Settings{
        .render_distance = 99,
        .window_width = 1800,
        .window_height = 1000,
        .taa_blend_factor = 0.25,
        .dynamic_resolution_min_scale = 0.3,
        .dynamic_resolution_max_scale = 0.4,
        .target_fps = 90,
    };
    try persistence.saveToDir(&settings, testing.allocator, home);
    var loaded = try persistence.loadFromDir(home, testing.allocator);
    defer persistence.deinit(&loaded, testing.allocator);
    try testing.expectEqual(@as(i32, 99), loaded.render_distance);
    try testing.expectEqual(@as(u32, 1800), loaded.window_width);
    try testing.expectEqual(@as(u32, 1000), loaded.window_height);
    try testing.expectEqual(@as(f32, 0.25), loaded.taa_blend_factor);
    try testing.expectEqual(@as(f32, 0.3), loaded.dynamic_resolution_min_scale);
    try testing.expectEqual(@as(f32, 0.4), loaded.dynamic_resolution_max_scale);
    try testing.expectEqual(@as(u32, 90), loaded.target_fps);
}
