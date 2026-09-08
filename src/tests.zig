//! Test aggregator for ZigCraft.
//!
//! This root owns application-level tests only. Each module's root.zig imports
//! its local test_root.zig and is passed directly to addTest in build.zig.
//! Named module imports DO NOT register dependency test declarations.
//! Keep new inline/companion tests reachable through file-relative imports in
//! the owning test_root.zig, not through facade exports here.
//!
//! Run: devenv shell zig build test
//! Inventory: devenv shell zig build test-discovery
//! Focus: devenv shell zig build test-<module> -Dtest-filter="name"
//! Both aggregate and per-family steps reject filters selecting no named tests.

const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

test "WorldStreamer prioritizes chunks in the player movement direction" {
    const PlayerMovement = @import("world-runtime").PlayerMovement;
    const Vec3 = @import("engine-math").Vec3;

    var movement = PlayerMovement{};
    try std.testing.expect(movement.update(Vec3.init(8, 0, 0), 1.0));
    try std.testing.expect(movement.priorityWeight(1, 0) < movement.priorityWeight(-1, 0));
}

test "benchmark warmup waits for stable geometry before sampling" {
    const BenchmarkRunner = @import("game-core").BenchmarkRunner;
    const GpuTimingResults = @import("engine-rhi").GpuTimingResults;
    const WorldStats = @import("engine-ui").WorldStats;

    var runner = try BenchmarkRunner.init(std.testing.allocator, "low", "stationary", 6, 1, 1, "Debug", "test", "unused.json");
    defer runner.deinit();
    const world_stats = WorldStats{
        .chunks_total = 1,
        .chunks_rendered = 1,
        .chunks_culled = 0,
        .vertices_rendered = 3,
        .gen_queue = 0,
        .mesh_queue = 0,
        .upload_queue = 0,
    };
    const gpu_timing = std.mem.zeroes(GpuTimingResults);

    try runner.recordFrame(0.5, 120, gpu_timing, world_stats, 1, 1);
    try std.testing.expect(!runner.warmup_ready);
    try runner.recordFrame(0.5, 120, gpu_timing, world_stats, 1, 1);
    try std.testing.expect(runner.warmup_ready);
    try std.testing.expectEqual(@as(usize, 0), runner.samples.items.len);

    try runner.recordFrame(0.5, 120, gpu_timing, world_stats, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), runner.samples.items.len);
}

test {
    _ = @import("game/app.zig");
    _ = @import("game/audio_system_manager.zig");
    _ = @import("math_tests.zig");
    _ = @import("noise_tests.zig");
    _ = @import("worldgen_tests.zig");
    _ = @import("shadow_cascade_tests.zig");
    _ = @import("interface_mock_tests.zig");
    _ = @import("world_inline_tests.zig");
    _ = @import("collision_tests.zig");

    _ = @import("job_system_tests.zig");
    _ = @import("vulkan_tests.zig");
    _ = @import("game/player_tests.zig");
    _ = @import("game/inventory_tests.zig");
    _ = @import("game/screen_tests.zig");
    _ = @import("game/world_list_tests.zig");
    _ = @import("game/session_tests.zig");
    _ = @import("game/input_mapper_tests.zig");
    _ = @import("text_input_tests.zig");
}
