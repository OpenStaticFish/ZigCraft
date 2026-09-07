//! Test aggregator for ZigCraft.
//!
//! This file imports all test modules. Individual tests live in their
//! respective modules (math_tests, noise_tests, etc.) or in dedicated
//! test files alongside the source they validate. Module-owned test blocks
//! are registered from direct source roots in build.zig.
//!
//! Run with: zig build test

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
    // Inline module test files (Issue #551)
    _ = @import("math_tests.zig");
    _ = @import("noise_tests.zig");
    _ = @import("worldgen_tests.zig");
    _ = @import("shadow_cascade_tests.zig");
    _ = @import("interface_mock_tests.zig");
    _ = @import("world_inline_tests.zig");
    _ = @import("collision_tests.zig");

    // ECS and engine tests
    _ = @import("engine-ecs").ecs_tests;
    _ = @import("job_system_tests.zig");
    _ = @import("engine-graphics").vulkan_device;
    _ = @import("engine-graphics").vulkan_device_tests;
    _ = @import("engine-graphics").vulkan_device_internal_tests;
    _ = @import("engine-graphics").rhi_state_control_tests;
    _ = @import("engine-graphics").ssao_system_tests;
    _ = @import("engine-graphics").pipeline_manager_tests;
    _ = @import("engine-graphics").pipeline_manager_edge_tests;
    _ = @import("engine-graphics").pipeline_specialized_tests;
    _ = @import("engine-graphics").pipeline_specialized_edge_tests;
    _ = @import("engine-graphics").descriptor_bindings_tests;
    _ = @import("engine-graphics").descriptor_bindings_edge_tests;
    _ = @import("engine-graphics").descriptor_manager_tests;
    _ = @import("engine-graphics").descriptor_manager_error_tests;
    _ = @import("engine-graphics").shader_registry_tests;
    _ = @import("engine-graphics").screenshot_tests;
    _ = @import("engine-graphics").frame_manager_tests;
    _ = @import("engine-graphics").final_composition;
    _ = @import("engine-graphics").render_pass_manager_tests;
    _ = @import("engine-graphics").rhi_frame_orchestration_tests;
    _ = @import("engine-graphics").rhi_pass_orchestration_tests;
    _ = @import("engine-graphics").vulkan_frame_tests;
    _ = @import("engine-graphics").utils_tests;
    _ = @import("vulkan_tests.zig");
    _ = @import("engine-graphics").rhi_tests;
    _ = @import("engine-rhi").rhi_contract_tests;
    _ = @import("engine-rhi").culling;
    _ = @import("engine-clouds").cloud_system;
    _ = @import("engine-shadows").shadow_cascade_tests;
    _ = @import("engine-graphics").shadow_tests;
    _ = @import("engine-shadows").shadow_system_tests;
    _ = @import("engine-math").utils_tests;
    _ = @import("engine-math").voxel_tests;
    _ = @import("engine-math").frustum_tests;
    _ = @import("engine-math").mat4_tests;
    _ = @import("world-meshing").world_tests;
    _ = @import("world-worldgen").schematics;
    _ = @import("world-worldgen").tree_registry;
    _ = @import("world-worldgen").climate_snapshot;
    _ = @import("world-worldgen").caves_tests;
    _ = @import("world-worldgen").coastal_generator_tests;
    _ = @import("world-worldgen").biome_registry_tests;
    _ = @import("world-worldgen").biome_selector_tests;
    _ = @import("world-worldgen").height_sampler_tests;
    _ = @import("world-worldgen").terrain_modifier_tests;
    _ = @import("world-worldgen").terrain_shape_generator_tests;
    _ = @import("world-worldgen").terrain_report;
    _ = @import("engine-atmosphere").atmosphere_tests;
    _ = @import("game-core").settings_tests;
    _ = @import("game-core").input_settings;
    _ = @import("game/player_tests.zig");
    _ = @import("game/inventory_tests.zig");
    _ = @import("game/screen_tests.zig");
    _ = @import("game/world_list_tests.zig");
    _ = @import("game/session_tests.zig");
    _ = @import("game/input_mapper_tests.zig");
    _ = @import("game-ui").menu_theme_tests;
    _ = @import("game-ui").screen_tests;
    _ = @import("game-ui").settings_ui_tests;
    _ = @import("game-ui").world_list_tests;
    _ = @import("game-core").settings_persistence_tests;
    _ = @import("world-persistence").region_file;
    _ = @import("world-persistence").chunk_serializer;
    _ = @import("world-persistence").level_data;
    _ = @import("world-persistence").save_manager;
    _ = @import("world-meshing").chunk_storage_tests;
    _ = @import("world-meshing").chunk_storage_extended_tests;
    _ = @import("world-meshing").gpu_block_buffer_tests;
    _ = @import("world-core").block_tests;
    _ = @import("world-core").block_registry_tests;
    _ = @import("world-core").block_biome_tests;
    _ = @import("world-core").chunk_tests;
    _ = @import("world-core").chunk_fill_tests;
    _ = @import("world-core").chunk_extended_tests;
    _ = @import("world-meshing").chunk_mesh_tests;
    _ = @import("world-meshing").chunk_storage_interface_tests;
    _ = @import("world-core").biome_and_block_tests;
    _ = @import("world-core").packed_light_tests;
    _ = @import("world-meshing").meshing.boundary_cross_tests;
    _ = @import("world-meshing").meshing.boundary_tests;
    _ = @import("world-core").world_coord_tests;
    _ = @import("world-core").world_block_fill_tests;
    _ = @import("world-meshing").world_interface_vtable_tests;
    _ = @import("world-runtime").world_mutation;
    _ = @import("world-runtime").world_diagnostics_tests;
    _ = @import("world-runtime").world_facade_tests;
    _ = @import("engine-audio").sdl_audio;
    _ = @import("engine-input").input_tests;
    _ = @import("text_input_tests.zig");
    _ = @import("engine-ui").font;
    _ = @import("engine-ui").rmlui;
    _ = @import("engine-ui").debug_shadow_overlay;
    _ = @import("game-core").hotbar;
    _ = @import("game-core").session_hud;
    _ = @import("game-ui").singleplayer_wizard;
    _ = @import("game-ui").rml_markup;
}
