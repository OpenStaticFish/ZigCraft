const std = @import("std");

// This file owns the monorepo dependency graph. modules/*/build.zig are package
// name/source stubs, not standalone builds with independently resolved imports.
// Reuse defineBuildOptions/defineModules with the repository-root Build rather
// than duplicating this graph for tools or tests.
pub const BuildOptions = struct {
    options: *std.Build.Step.Options,
    engine_ui_options: *std.Build.Step.Options,
    worldgen_overworld_options: *std.Build.Step.Options,
    world_runtime_options: *std.Build.Step.Options,
    engine_graphics_options: *std.Build.Step.Options,
    enable_debug_shadows: bool,
    enable_imgui: bool,
    enable_rmlui: bool,
    chunk_debug_mode: bool,
    chunk_debug_enable: []const u8,
    startup_diagnostic_seconds: u32,
    skip_present: bool,
    monitor_index: i32,
    monitor_name: []const u8,
    window_video_driver: []const u8,
    window_no_focus: bool,
    shadow_test_variant: []const u8,
    benchmark_preset: []const u8,
    benchmark_scenario: []const u8,
    benchmark_duration: u32,
    benchmark_output: []const u8,
    benchmark_render_distance: i32,
    benchmark_world: []const u8,
    sanitize_c: ?std.zig.SanitizeC,
};

pub const BuildModules = struct {
    zig_math: *std.Build.Module,
    zig_noise: *std.Build.Module,
    fs_module: *std.Build.Module,
    sync_module: *std.Build.Module,
    c_module: *std.Build.Module,
    engine_math: *std.Build.Module,
    engine_audio: *std.Build.Module,
    engine_core: *std.Build.Module,
    engine_ecs: *std.Build.Module,
    engine_input: *std.Build.Module,
    engine_physics: *std.Build.Module,
    engine_rhi: *std.Build.Module,
    engine_graphics: *std.Build.Module,
    engine_assets_impl: *std.Build.Module,
    engine_camera_impl: *std.Build.Module,
    engine_clouds_impl: *std.Build.Module,
    engine_atmosphere_impl: *std.Build.Module,
    engine_shadows_impl: *std.Build.Module,
    engine_lighting_impl: *std.Build.Module,
    engine_assets: *std.Build.Module,
    engine_camera: *std.Build.Module,
    engine_clouds: *std.Build.Module,
    engine_atmosphere: *std.Build.Module,
    engine_shadows: *std.Build.Module,
    engine_lighting: *std.Build.Module,
    engine_ui: *std.Build.Module,
    world_core: *std.Build.Module,
    worldgen_api: *std.Build.Module,
    worldgen_common: *std.Build.Module,
    worldgen_overworld: *std.Build.Module,
    worldgen_overworld_v2: *std.Build.Module,
    worldgen_flat: *std.Build.Module,
    worldgen_test: *std.Build.Module,
    world_worldgen: *std.Build.Module,
    world_meshing: *std.Build.Module,
    world_runtime: *std.Build.Module,
    world_persistence: *std.Build.Module,
    game_core: *std.Build.Module,
    game_ui: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = defineBuildOptions(b, optimize);
    const modules = defineModules(b, target, optimize, opts);
    defineBuildSteps(b, target, optimize, opts, modules);
}

pub fn defineModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: BuildOptions,
) BuildModules {
    const options = opts.options;
    const enable_imgui = opts.enable_imgui;
    const enable_rmlui = opts.enable_rmlui;
    const engine_ui_options = opts.engine_ui_options;
    const world_runtime_options = opts.world_runtime_options;
    const engine_graphics_options = opts.engine_graphics_options;
    const shadow_test_variant = opts.shadow_test_variant;
    const sanitize_c = opts.sanitize_c;

    const zig_math = b.createModule(.{
        .root_source_file = b.path("libs/zig-math/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_noise = b.createModule(.{
        .root_source_file = b.path("libs/zig-noise/noise.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fs_module = b.createModule(.{
        .root_source_file = b.path("modules/engine-core/src/fs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sync_module = b.createModule(.{
        .root_source_file = b.path("modules/engine-core/src/sync.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_module.addIncludePath(b.path("libs/stb"));
    c_module.linkSystemLibrary("sdl3", .{});
    c_module.linkSystemLibrary("vulkan", .{});
    // Native implementations belong to one module, including when that module
    // is reached through several dependencies of a direct module test root.
    c_module.link_libc = true;
    c_module.addCSourceFile(.{ .file = b.path("libs/stb/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    c_module.addCSourceFile(.{ .file = b.path("libs/stb/stb_truetype_impl.c"), .flags = &.{"-std=c99"} });

    const engine_math = b.createModule(.{ .root_source_file = b.path("modules/engine-math/src/root.zig"), .target = target, .optimize = optimize });
    const engine_audio = b.createModule(.{ .root_source_file = b.path("modules/engine-audio/src/root.zig"), .target = target, .optimize = optimize });
    const engine_core = b.createModule(.{ .root_source_file = b.path("modules/engine-core/src/root.zig"), .target = target, .optimize = optimize });
    const engine_ecs = b.createModule(.{ .root_source_file = b.path("modules/engine-ecs/src/root.zig"), .target = target, .optimize = optimize });
    const engine_input = b.createModule(.{ .root_source_file = b.path("modules/engine-input/src/root.zig"), .target = target, .optimize = optimize });
    const engine_physics = b.createModule(.{ .root_source_file = b.path("modules/engine-physics/src/root.zig"), .target = target, .optimize = optimize });
    const engine_rhi = b.createModule(.{ .root_source_file = b.path("modules/engine-rhi/src/root.zig"), .target = target, .optimize = optimize });
    const engine_graphics = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/root.zig"), .target = target, .optimize = optimize });
    const engine_assets_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/assets_root.zig"), .target = target, .optimize = optimize });
    const engine_camera_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/camera_root.zig"), .target = target, .optimize = optimize });
    const engine_clouds_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/clouds_root.zig"), .target = target, .optimize = optimize });
    const engine_atmosphere_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/atmosphere_root.zig"), .target = target, .optimize = optimize });
    const engine_shadows_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/shadows_root.zig"), .target = target, .optimize = optimize });
    const engine_lighting_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/lighting_root.zig"), .target = target, .optimize = optimize });
    const engine_assets = b.createModule(.{ .root_source_file = b.path("modules/engine-assets/src/root.zig"), .target = target, .optimize = optimize });
    const engine_camera = b.createModule(.{ .root_source_file = b.path("modules/engine-camera/src/root.zig"), .target = target, .optimize = optimize });
    const engine_clouds = b.createModule(.{ .root_source_file = b.path("modules/engine-clouds/src/root.zig"), .target = target, .optimize = optimize });
    const engine_atmosphere = b.createModule(.{ .root_source_file = b.path("modules/engine-atmosphere/src/root.zig"), .target = target, .optimize = optimize });
    const engine_shadows = b.createModule(.{ .root_source_file = b.path("modules/engine-shadows/src/root.zig"), .target = target, .optimize = optimize });
    const engine_lighting = b.createModule(.{ .root_source_file = b.path("modules/engine-lighting/src/root.zig"), .target = target, .optimize = optimize });
    const engine_ui = b.createModule(.{ .root_source_file = b.path("modules/engine-ui/src/root.zig"), .target = target, .optimize = optimize });
    const world_core = b.createModule(.{ .root_source_file = b.path("modules/world-core/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_api = b.createModule(.{ .root_source_file = b.path("modules/worldgen-api/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_common = b.createModule(.{ .root_source_file = b.path("modules/worldgen-common/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_overworld = b.createModule(.{ .root_source_file = b.path("modules/worldgen-overworld/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_overworld_v2 = b.createModule(.{ .root_source_file = b.path("modules/worldgen-overworld-v2/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_flat = b.createModule(.{ .root_source_file = b.path("modules/worldgen-flat/src/root.zig"), .target = target, .optimize = optimize });
    const worldgen_test = b.createModule(.{ .root_source_file = b.path("modules/worldgen-test/src/root.zig"), .target = target, .optimize = optimize });
    const world_worldgen = b.createModule(.{ .root_source_file = b.path("modules/world-worldgen/src/root.zig"), .target = target, .optimize = optimize });
    const world_meshing = b.createModule(.{ .root_source_file = b.path("modules/world-meshing/src/root.zig"), .target = target, .optimize = optimize });
    const world_runtime = b.createModule(.{ .root_source_file = b.path("modules/world-runtime/src/root.zig"), .target = target, .optimize = optimize });
    const world_persistence = b.createModule(.{ .root_source_file = b.path("modules/world-persistence/src/root.zig"), .target = target, .optimize = optimize });
    world_persistence.addAnonymousImport("level_fixture_v0_1", .{ .root_source_file = b.path("modules/world-persistence/test-fixtures/v0.1/level.dat") });
    const game_core = b.createModule(.{ .root_source_file = b.path("modules/game-core/src/root.zig"), .target = target, .optimize = optimize });
    const game_ui = b.createModule(.{ .root_source_file = b.path("modules/game-ui/src/root.zig"), .target = target, .optimize = optimize });

    applySanitizeC(sanitize_c, &.{
        zig_math,
        zig_noise,
        fs_module,
        sync_module,
        c_module,
        engine_math,
        engine_audio,
        engine_core,
        engine_ecs,
        engine_input,
        engine_physics,
        engine_rhi,
        engine_graphics,
        engine_assets_impl,
        engine_camera_impl,
        engine_clouds_impl,
        engine_atmosphere_impl,
        engine_shadows_impl,
        engine_lighting_impl,
        engine_assets,
        engine_camera,
        engine_clouds,
        engine_atmosphere,
        engine_shadows,
        engine_lighting,
        engine_ui,
        world_core,
        worldgen_api,
        worldgen_common,
        worldgen_overworld,
        worldgen_overworld_v2,
        worldgen_flat,
        worldgen_test,
        world_worldgen,
        world_meshing,
        world_runtime,
        world_persistence,
        game_core,
        game_ui,
    });

    const modules = BuildModules{
        .zig_math = zig_math,
        .zig_noise = zig_noise,
        .fs_module = fs_module,
        .sync_module = sync_module,
        .c_module = c_module,
        .engine_math = engine_math,
        .engine_audio = engine_audio,
        .engine_core = engine_core,
        .engine_ecs = engine_ecs,
        .engine_input = engine_input,
        .engine_physics = engine_physics,
        .engine_rhi = engine_rhi,
        .engine_graphics = engine_graphics,
        .engine_assets_impl = engine_assets_impl,
        .engine_camera_impl = engine_camera_impl,
        .engine_clouds_impl = engine_clouds_impl,
        .engine_atmosphere_impl = engine_atmosphere_impl,
        .engine_shadows_impl = engine_shadows_impl,
        .engine_lighting_impl = engine_lighting_impl,
        .engine_assets = engine_assets,
        .engine_camera = engine_camera,
        .engine_clouds = engine_clouds,
        .engine_atmosphere = engine_atmosphere,
        .engine_shadows = engine_shadows,
        .engine_lighting = engine_lighting,
        .engine_ui = engine_ui,
        .world_core = world_core,
        .worldgen_api = worldgen_api,
        .worldgen_common = worldgen_common,
        .worldgen_overworld = worldgen_overworld,
        .worldgen_overworld_v2 = worldgen_overworld_v2,
        .worldgen_flat = worldgen_flat,
        .worldgen_test = worldgen_test,
        .world_worldgen = world_worldgen,
        .world_meshing = world_meshing,
        .world_runtime = world_runtime,
        .world_persistence = world_persistence,
        .game_core = game_core,
        .game_ui = game_ui,
    };

    engine_math.addImport("zig-math", zig_math);
    addSharedImports(engine_audio, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_audio.addImport("engine-math", engine_math);
    engine_audio.addImport("engine-core", engine_core);
    addSharedImports(engine_core, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(engine_ecs, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_ecs.addImport("engine-core", engine_core);
    engine_ecs.addImport("engine-math", engine_math);
    engine_ecs.addImport("engine-physics", engine_physics);
    engine_ecs.addImport("engine-rhi", engine_rhi);
    engine_ecs.addImport("engine-ecs", engine_ecs);
    addSharedImports(engine_input, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_input.addImport("engine-core", engine_core);
    engine_input.addImport("engine-input", engine_input);

    engine_physics.addImport("zig-math", zig_math);
    addSharedImports(engine_rhi, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_rhi.addImport("engine-math", engine_math);
    engine_rhi.addImport("engine-core", engine_core);
    addSharedImports(engine_assets_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_assets_impl.addImport("engine-core", engine_core);
    engine_assets_impl.addImport("engine-rhi", engine_rhi);
    engine_assets.addImport("engine-assets-impl", engine_assets_impl);
    addSharedImports(engine_camera_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_camera_impl.addImport("engine-core", engine_core);
    engine_camera_impl.addImport("engine-input", engine_input);
    engine_camera_impl.addImport("engine-math", engine_math);
    engine_camera.addImport("engine-camera-impl", engine_camera_impl);
    addSharedImports(engine_clouds_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_clouds_impl.addImport("engine-math", engine_math);
    engine_clouds_impl.addImport("engine-rhi", engine_rhi);
    engine_clouds.addImport("engine-clouds-impl", engine_clouds_impl);
    addSharedImports(engine_atmosphere_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_atmosphere_impl.addImport("engine-core", engine_core);
    engine_atmosphere_impl.addImport("engine-math", engine_math);
    engine_atmosphere_impl.addImport("engine-rhi", engine_rhi);
    engine_atmosphere.addImport("engine-atmosphere-impl", engine_atmosphere_impl);
    addSharedImports(engine_shadows_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_shadows_impl.addImport("engine-core", engine_core);
    engine_shadows_impl.addImport("engine-math", engine_math);
    engine_shadows_impl.addImport("engine-rhi", engine_rhi);
    engine_shadows.addImport("engine-shadows-impl", engine_shadows_impl);
    engine_shadows.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_lighting_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_lighting_impl.addImport("engine-core", engine_core);
    engine_lighting_impl.addImport("engine-math", engine_math);
    engine_lighting_impl.addImport("engine-rhi", engine_rhi);
    engine_lighting.addImport("engine-lighting-impl", engine_lighting_impl);
    engine_lighting.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_graphics, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_graphics.addImport("engine-assets", engine_assets);
    engine_graphics.addImport("engine-atmosphere", engine_atmosphere);
    engine_graphics.addImport("engine-camera", engine_camera);
    engine_graphics.addImport("engine-clouds", engine_clouds);
    engine_graphics.addImport("engine-lighting", engine_lighting);
    engine_graphics.addImport("engine-math", engine_math);
    engine_graphics.addImport("engine-core", engine_core);
    engine_graphics.addImport("engine-input", engine_input);
    engine_graphics.addImport("engine-rhi", engine_rhi);
    engine_graphics.addImport("engine-shadows", engine_shadows);
    engine_graphics.addOptions("engine_graphics_options", engine_graphics_options);
    engine_graphics.linkSystemLibrary("sdl3", .{});
    engine_graphics.linkSystemLibrary("vulkan", .{});
    addSharedImports(engine_ui, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_ui.addImport("engine-math", engine_math);
    engine_ui.addImport("engine-core", engine_core);
    engine_ui.addImport("engine-rhi", engine_rhi);
    engine_ui.addImport("world-core", world_core);
    engine_ui.addOptions("engine_ui_options", engine_ui_options);
    engine_ui.linkSystemLibrary("sdl3", .{});
    engine_ui.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) {
        engine_graphics.linkSystemLibrary("cimgui", .{ .use_pkg_config = .force });
        engine_graphics.link_libcpp = true;
        engine_ui.linkSystemLibrary("cimgui", .{ .use_pkg_config = .force });
        engine_ui.link_libcpp = true;
    }
    if (enable_rmlui) {
        engine_ui.linkSystemLibrary("zigcraft-rmlui-bridge", .{ .use_pkg_config = .force });
        engine_ui.link_libcpp = true;
    }
    addSharedImports(world_core, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_core.addImport("engine-core", engine_core);
    world_core.addImport("engine-math", engine_math);
    addSharedImports(worldgen_api, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_api.addImport("world-core", world_core);
    addSharedImports(worldgen_common, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_common.addImport("world-core", world_core);
    const worldgen_overworld_options = opts.worldgen_overworld_options;
    addSharedImports(worldgen_overworld, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_overworld.addImport("engine-core", engine_core);
    worldgen_overworld.addImport("engine-rhi", engine_rhi);
    worldgen_overworld.addImport("world-core", world_core);
    worldgen_overworld.addImport("worldgen-api", worldgen_api);
    worldgen_overworld.addImport("worldgen-common", worldgen_common);
    worldgen_overworld.addOptions("worldgen_overworld_options", worldgen_overworld_options);
    addSharedImports(worldgen_overworld_v2, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_overworld_v2.addImport("world-core", world_core);
    worldgen_overworld_v2.addImport("worldgen-api", worldgen_api);
    worldgen_overworld_v2.addImport("worldgen-common", worldgen_common);
    addSharedImports(worldgen_flat, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_flat.addImport("world-core", world_core);
    worldgen_flat.addImport("worldgen-api", worldgen_api);
    worldgen_flat.addImport("worldgen-common", worldgen_common);
    const worldgen_test_options = b.addOptions();
    worldgen_test_options.addOption([]const u8, "shadow_test_variant", shadow_test_variant);
    addSharedImports(worldgen_test, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    worldgen_test.addImport("world-core", world_core);
    worldgen_test.addImport("worldgen-api", worldgen_api);
    worldgen_test.addImport("worldgen-common", worldgen_common);
    worldgen_test.addOptions("worldgen_test_options", worldgen_test_options);
    addSharedImports(world_worldgen, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(world_meshing, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_meshing.addImport("engine-core", engine_core);
    world_meshing.addImport("engine-assets", engine_assets);
    world_meshing.addImport("engine-rhi", engine_rhi);
    world_meshing.addImport("world-core", world_core);
    addSharedImports(world_persistence, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_persistence.addImport("engine-core", engine_core);
    world_persistence.addImport("world-core", world_core);
    world_worldgen.addImport("engine-core", engine_core);
    world_worldgen.addImport("world-core", world_core);
    world_worldgen.addImport("worldgen-api", worldgen_api);
    world_worldgen.addImport("worldgen-common", worldgen_common);
    world_worldgen.addImport("worldgen-overworld", worldgen_overworld);
    world_worldgen.addImport("worldgen-overworld-v2", worldgen_overworld_v2);
    world_worldgen.addImport("worldgen-flat", worldgen_flat);
    world_worldgen.addImport("worldgen-test", worldgen_test);

    addSharedImports(world_runtime, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_runtime.addImport("engine-core", engine_core);
    world_runtime.addImport("engine-assets", engine_assets);
    world_runtime.addImport("engine-lighting", engine_lighting);
    world_runtime.addImport("engine-shadows", engine_shadows);
    world_runtime.addImport("engine-graphics", engine_graphics);
    world_runtime.addImport("engine-math", engine_math);
    world_runtime.addImport("engine-physics", engine_physics);
    world_runtime.addImport("engine-rhi", engine_rhi);
    world_runtime.addImport("engine-ui", engine_ui);
    world_runtime.addImport("world-core", world_core);
    world_runtime.addImport("world-meshing", world_meshing);
    world_runtime.addImport("world-persistence", world_persistence);
    world_runtime.addImport("world-worldgen", world_worldgen);
    world_runtime.addOptions("world_runtime_options", world_runtime_options);

    addSharedImportsNoOptions(game_core, zig_math, zig_noise, fs_module, sync_module, c_module);
    addProjectModuleImports(game_core, modules);

    addSharedImportsNoOptions(game_ui, zig_math, zig_noise, fs_module, sync_module, c_module);
    addProjectModuleImports(game_ui, modules);
    game_ui.addImport("game-core", game_core);

    return modules;
}

fn defineBuildSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: BuildOptions,
    modules: BuildModules,
) void {
    const options = opts.options;
    const enable_debug_shadows = opts.enable_debug_shadows;
    const enable_imgui = opts.enable_imgui;
    const enable_rmlui = opts.enable_rmlui;
    const monitor_index = opts.monitor_index;
    const monitor_name = opts.monitor_name;
    const window_video_driver = opts.window_video_driver;
    const window_no_focus = opts.window_no_focus;
    const benchmark_preset = opts.benchmark_preset;
    const benchmark_scenario = opts.benchmark_scenario;
    const benchmark_duration = opts.benchmark_duration;
    const benchmark_output = opts.benchmark_output;
    const benchmark_world = opts.benchmark_world;
    const sanitize_c = opts.sanitize_c;
    const zig_math = modules.zig_math;
    const zig_noise = modules.zig_noise;
    const fs_module = modules.fs_module;
    const sync_module = modules.sync_module;
    const c_module = modules.c_module;
    const engine_core = modules.engine_core;
    const engine_graphics = modules.engine_graphics;
    const world_core = modules.world_core;
    const world_worldgen = modules.world_worldgen;
    const game_core = modules.game_core;
    const game_ui = modules.game_ui;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    root_module.addImport("zig-math", zig_math);
    root_module.addImport("zig-noise", zig_noise);
    root_module.addImport("fs", fs_module);
    root_module.addImport("sync", sync_module);
    root_module.addImport("c", c_module);
    addProjectModuleImports(root_module, modules);
    root_module.addImport("game-core", game_core);
    root_module.addImport("game-ui", game_ui);
    root_module.addOptions("build_options", options);
    root_module.addIncludePath(b.path("libs/stb"));

    const exe = b.addExecutable(.{
        .name = "zigcraft",
        .root_module = root_module,
    });

    exe.root_module.link_libc = true;

    exe.root_module.linkSystemLibrary("sdl3", .{});
    exe.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, exe);
    if (enable_rmlui) addRmlUi(exe);

    b.installArtifact(exe);

    // Ordinary builds/tests only validate tracked runtime artifacts. Updating
    // them is explicit, so a test can never repair stale SPIR-V before checking.
    const shader_checks = defineShaderValidation(b);
    const shader_cmd = b.addSystemCommand(&.{ "sh", "-eu", "-c", "for f in assets/shaders/vulkan/*.vert assets/shaders/vulkan/*.frag assets/shaders/vulkan/*.comp; do glslangValidator -V \"$f\" -o \"$f.spv\"; done" });
    shader_cmd.setCwd(b.path("."));
    const shaders_step = b.step("shaders", "Explicitly regenerate tracked runtime SPIR-V (fail fast)");
    shaders_step.dependOn(&shader_cmd.step);
    b.getInstallStep().dependOn(shader_checks);

    const run_cmd = addRunArtifact(b, exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(shader_checks);
    run_cmd.setCwd(b.path("."));

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const benchmark_options = b.addOptions();
    benchmark_options.addOption(bool, "debug_shadows", enable_debug_shadows);
    benchmark_options.addOption(bool, "imgui", enable_imgui);
    benchmark_options.addOption(bool, "rmlui", enable_rmlui);
    benchmark_options.addOption(bool, "smoke_test", false);
    benchmark_options.addOption(bool, "chunk_debug_mode", false);
    benchmark_options.addOption([]const u8, "chunk_debug_enable", "");
    benchmark_options.addOption([]const u8, "auto_world", benchmark_world);
    benchmark_options.addOption([]const u8, "auto_preset", benchmark_preset);
    benchmark_options.addOption(u32, "startup_diagnostic_seconds", 0);
    benchmark_options.addOption(i32, "monitor_index", monitor_index);
    benchmark_options.addOption([]const u8, "monitor_name", monitor_name);
    benchmark_options.addOption([]const u8, "window_video_driver", window_video_driver);
    benchmark_options.addOption(bool, "window_no_focus", window_no_focus);
    benchmark_options.addOption(bool, "skip_present", true);
    benchmark_options.addOption([]const u8, "screenshot_path", "");
    benchmark_options.addOption(u32, "screenshot_frame", 120);
    benchmark_options.addOption(u32, "screenshot_delay_seconds", 0);
    benchmark_options.addOption(bool, "shadow_test_scene", false);
    benchmark_options.addOption([]const u8, "shadow_test_variant", "dug-cave");
    benchmark_options.addOption(bool, "benchmark", true);
    benchmark_options.addOption([]const u8, "benchmark_preset", benchmark_preset);
    benchmark_options.addOption([]const u8, "benchmark_scenario", benchmark_scenario);
    benchmark_options.addOption(u32, "benchmark_duration", benchmark_duration);
    benchmark_options.addOption([]const u8, "benchmark_output", benchmark_output);
    benchmark_options.addOption(i32, "benchmark_render_distance", opts.benchmark_render_distance);
    benchmark_options.addOption([]const u8, "benchmark_world", benchmark_world);
    benchmark_options.addOption([]const u8, "benchmark_build_mode", @tagName(optimize));

    // The backend reads its own module options, not the executable's options.
    // Reusing the normal graph here silently presents the hidden benchmark window.
    const benchmark_graphics_options = b.addOptions();
    benchmark_graphics_options.addOption(bool, "debug_shadows", enable_debug_shadows);
    benchmark_graphics_options.addOption(bool, "chunk_debug_mode", false);
    benchmark_graphics_options.addOption([]const u8, "chunk_debug_enable", "");
    benchmark_graphics_options.addOption(bool, "skip_present", true);
    benchmark_graphics_options.addOption(bool, "imgui", enable_imgui);
    benchmark_graphics_options.addOption(bool, "rmlui", enable_rmlui);
    var benchmark_opts = opts;
    benchmark_opts.options = benchmark_options;
    benchmark_opts.engine_graphics_options = benchmark_graphics_options;
    benchmark_opts.skip_present = true;
    const benchmark_modules = defineModules(b, target, optimize, benchmark_opts);

    const benchmark_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    benchmark_root_module.addImport("zig-math", benchmark_modules.zig_math);
    benchmark_root_module.addImport("zig-noise", benchmark_modules.zig_noise);
    benchmark_root_module.addImport("fs", benchmark_modules.fs_module);
    benchmark_root_module.addImport("sync", benchmark_modules.sync_module);
    benchmark_root_module.addImport("c", benchmark_modules.c_module);
    addProjectModuleImports(benchmark_root_module, benchmark_modules);
    benchmark_root_module.addImport("game-core", benchmark_modules.game_core);
    benchmark_root_module.addImport("game-ui", benchmark_modules.game_ui);
    benchmark_root_module.addOptions("build_options", benchmark_options);
    benchmark_root_module.addIncludePath(b.path("libs/stb"));

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_root_module,
    });

    benchmark_exe.root_module.link_libc = true;

    benchmark_exe.root_module.linkSystemLibrary("sdl3", .{});
    benchmark_exe.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, benchmark_exe);
    if (enable_rmlui) addRmlUi(benchmark_exe);

    b.installArtifact(benchmark_exe);

    const benchmark_run_cmd = addRunArtifact(b, benchmark_exe);
    benchmark_run_cmd.step.dependOn(b.getInstallStep());
    benchmark_run_cmd.step.dependOn(shader_checks);
    benchmark_run_cmd.setCwd(b.path("."));
    // Benchmark presets must scale large persistent world buffers coherently,
    // not only shader quality. This keeps their documented VRAM SLO meaningful
    // on high-VRAM devices where runtime defaults otherwise reserve maximum
    // pools regardless of the selected preset.
    if (std.mem.eql(u8, benchmark_preset, "low")) {
        benchmark_run_cmd.setEnvironmentVariable("ZIGCRAFT_VERTEX_CAPACITY_MB", "96");
        benchmark_run_cmd.setEnvironmentVariable("ZIGCRAFT_GPU_BLOCK_BUDGET_MB", "96");
    } else if (std.mem.eql(u8, benchmark_preset, "medium")) {
        benchmark_run_cmd.setEnvironmentVariable("ZIGCRAFT_VERTEX_CAPACITY_MB", "96");
        benchmark_run_cmd.setEnvironmentVariable("ZIGCRAFT_GPU_BLOCK_BUDGET_MB", "96");
    }

    const benchmark_step = b.step("benchmark", "Run benchmark harness");
    benchmark_step.dependOn(&benchmark_run_cmd.step);

    const worldgen_report_root_module = b.createModule(.{
        .root_source_file = b.path("src/worldgen_report_main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    worldgen_report_root_module.addImport("world-core", world_core);
    worldgen_report_root_module.addImport("world-worldgen", world_worldgen);

    const worldgen_report_exe = b.addExecutable(.{
        .name = "worldgen-report",
        .root_module = worldgen_report_root_module,
    });
    if (enable_rmlui) addRmlUi(worldgen_report_exe);

    const worldgen_report_run_cmd = addRunArtifact(b, worldgen_report_exe);
    const worldgen_report_step = b.step("worldgen-report", "Print deterministic worldgen baseline report");
    worldgen_report_step.dependOn(&worldgen_report_run_cmd.step);

    const worldgen_climate_snapshot_root_module = b.createModule(.{
        .root_source_file = b.path("src/worldgen_climate_snapshot_main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    worldgen_climate_snapshot_root_module.addImport("fs", fs_module);
    worldgen_climate_snapshot_root_module.addImport("world-core", world_core);
    worldgen_climate_snapshot_root_module.addImport("world-worldgen", world_worldgen);

    const worldgen_climate_snapshot_exe = b.addExecutable(.{
        .name = "worldgen-climate-snapshot",
        .root_module = worldgen_climate_snapshot_root_module,
    });
    if (enable_rmlui) addRmlUi(worldgen_climate_snapshot_exe);

    const worldgen_climate_snapshot_run_cmd = addRunArtifact(b, worldgen_climate_snapshot_exe);
    if (b.args) |args| {
        worldgen_climate_snapshot_run_cmd.addArgs(args);
    }
    const worldgen_climate_snapshot_step = b.step("worldgen-climate-snapshot", "Write deterministic worldgen climate snapshot JSON or heatmap");
    worldgen_climate_snapshot_step.dependOn(&worldgen_climate_snapshot_run_cmd.step);

    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    test_root_module.addImport("zig-math", zig_math);
    test_root_module.addImport("zig-noise", zig_noise);
    test_root_module.addImport("fs", fs_module);
    test_root_module.addImport("sync", sync_module);
    test_root_module.addImport("c", c_module);
    addProjectModuleImports(test_root_module, modules);
    test_root_module.addImport("game-core", game_core);
    test_root_module.addImport("game-ui", game_ui);
    test_root_module.addOptions("build_options", options);

    const test_llvm = b.option(bool, "test-llvm", "Use LLVM for direct unit test executables (coverage-compatible DWARF)");
    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only run unit tests whose name contains this filter")) |filter|
        &.{filter}
    else if (b.args) |args|
        if (args.len >= 2 and std.mem.eql(u8, args[0], "--test-filter")) &.{args[1]} else &.{}
    else
        &.{};
    const test_step = b.step("test", "Run all direct unit/fuzz roots and shader checks; reject empty discovery");
    test_step.dependOn(shader_checks);
    const discovery = TestDiscovery.create(b, false);
    const inventory = TestDiscovery.create(b, true);
    test_step.dependOn(&discovery.step);
    b.step("test-discovery", "Run unit tests and print the compiler-discovered named-test inventory").dependOn(&inventory.step);

    // Each production module is a direct test root exactly once. Its local
    // test_root.zig imports sources by filename, never by a named dependency.
    // In particular, facade exports do not own their implementation's tests.
    inline for (.{
        .{ "app", test_root_module },
        .{ "engine-math", modules.engine_math },
        .{ "engine-audio", modules.engine_audio },
        .{ "engine-core", modules.engine_core },
        .{ "engine-core-fs", modules.fs_module },
        .{ "engine-core-sync", modules.sync_module },
        .{ "engine-ecs", modules.engine_ecs },
        .{ "engine-input", modules.engine_input },
        .{ "engine-physics", modules.engine_physics },
        .{ "engine-rhi", modules.engine_rhi },
        .{ "engine-graphics", modules.engine_graphics },
        .{ "engine-assets", modules.engine_assets_impl },
        .{ "engine-atmosphere", modules.engine_atmosphere_impl },
        .{ "engine-camera", modules.engine_camera_impl },
        .{ "engine-clouds", modules.engine_clouds_impl },
        .{ "engine-lighting", modules.engine_lighting_impl },
        .{ "engine-shadows", modules.engine_shadows_impl },
        .{ "engine-ui", modules.engine_ui },
        .{ "world-core", modules.world_core },
        .{ "worldgen-api", modules.worldgen_api },
        .{ "worldgen-common", modules.worldgen_common },
        .{ "worldgen-overworld", modules.worldgen_overworld },
        .{ "worldgen-overworld-v2", modules.worldgen_overworld_v2 },
        .{ "worldgen-flat", modules.worldgen_flat },
        .{ "worldgen-test", modules.worldgen_test },
        .{ "world-worldgen", modules.world_worldgen },
        .{ "world-meshing", modules.world_meshing },
        .{ "world-runtime", modules.world_runtime },
        .{ "world-persistence", modules.world_persistence },
        .{ "game-core", modules.game_core },
        .{ "game-ui", modules.game_ui },
    }) |entry| {
        const tests = b.addTest(.{
            .name = entry[0] ++ "-tests",
            .root_module = entry[1],
            .filters = test_filters,
            .use_llvm = test_llvm,
        });
        const run = addRunArtifact(b, tests);
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("ZIGCRAFT_LOG_LEVEL", "fatal");
        // Discovery must have fresh IPC metadata, not an exit-code-only cache hit.
        run.has_side_effects = true;
        discovery.add(run);
        inventory.add(run);
        const family_discovery = TestDiscovery.create(b, false);
        family_discovery.add(run);
        b.step("test-" ++ entry[0], "Run direct " ++ entry[0] ++ " tests; reject empty filters").dependOn(&family_discovery.step);
    }

    const integration_root_module = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_c = sanitize_c,
    });
    integration_root_module.addImport("zig-math", zig_math);
    integration_root_module.addImport("zig-noise", zig_noise);
    integration_root_module.addImport("fs", fs_module);
    integration_root_module.addImport("sync", sync_module);
    integration_root_module.addImport("c", c_module);
    addProjectModuleImports(integration_root_module, modules);
    integration_root_module.addImport("game-core", game_core);
    integration_root_module.addImport("game-ui", game_ui);
    integration_root_module.addOptions("build_options", options);
    integration_root_module.addIncludePath(b.path("libs/stb"));

    const exe_integration_tests = b.addTest(.{
        .root_module = integration_root_module,
    });
    exe_integration_tests.root_module.link_libc = true;
    exe_integration_tests.root_module.linkSystemLibrary("sdl3", .{});
    exe_integration_tests.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, exe_integration_tests);
    if (enable_rmlui) addRmlUi(exe_integration_tests);

    const test_integration_step = b.step("test-integration", "Run integration smoke test");
    const run_integration_tests = addRunArtifact(b, exe_integration_tests);
    run_integration_tests.stdio_limit = .unlimited;
    run_integration_tests.step.dependOn(shader_checks);
    test_integration_step.dependOn(&run_integration_tests.step);

    // Robust Vulkan demo executable
    const robust_demo = b.addExecutable(.{
        .name = "robust-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/robust_demo.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        }),
    });
    robust_demo.root_module.addOptions("build_options", options);
    robust_demo.root_module.addImport("fs", fs_module);
    robust_demo.root_module.addImport("sync", sync_module);
    robust_demo.root_module.addImport("c", c_module);
    robust_demo.root_module.addImport("engine-core", engine_core);
    robust_demo.root_module.addImport("engine-graphics", engine_graphics);

    robust_demo.root_module.link_libc = true;
    robust_demo.root_module.linkSystemLibrary("sdl3", .{});
    robust_demo.root_module.linkSystemLibrary("vulkan", .{});
    robust_demo.root_module.addIncludePath(b.path("libs/stb"));
    if (enable_rmlui) addRmlUi(robust_demo);

    b.installArtifact(robust_demo);

    const integration_robustness = b.addExecutable(.{
        .name = "test-robustness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test_robustness.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_c = sanitize_c,
        }),
    });
    integration_robustness.root_module.addOptions("build_options", options);
    integration_robustness.root_module.addImport("fs", fs_module);
    integration_robustness.root_module.addImport("sync", sync_module);
    integration_robustness.root_module.addImport("c", c_module);
    integration_robustness.root_module.addImport("engine-core", engine_core);
    integration_robustness.root_module.link_libc = true;
    integration_robustness.root_module.linkSystemLibrary("sdl3", .{}); // Needed for C imports if any
    if (enable_rmlui) addRmlUi(integration_robustness);

    const test_robustness_run = addRunArtifact(b, integration_robustness);
    test_robustness_run.addArtifactArg(robust_demo);
    // Ensure robust-demo is built first
    test_robustness_run.step.dependOn(&b.addInstallArtifact(robust_demo, .{}).step);

    const test_robustness_step = b.step("test-robustness", "Verify guarded transfer submission and readback");
    test_robustness_step.dependOn(&test_robustness_run.step);

    const run_robust_cmd = addRunArtifact(b, robust_demo);
    run_robust_cmd.step.dependOn(b.getInstallStep());

    const run_robust_step = b.step("run-robust", "Run the guarded transfer/readback smoke");
    run_robust_step.dependOn(&run_robust_cmd.step);
}

fn addRunArtifact(b: *std.Build, artifact: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    const dynamic_linker = b.graph.environ_map.get("ZIGCRAFT_DYNAMIC_LINKER") orelse
        return run;
    if (dynamic_linker.len == 0) return run;

    // Keep .zig_test stdio and --listen=- when inserting the runtime loader.
    // A system command loses test metadata, leak reporting, and fuzz support.
    run.argv.insert(b.allocator, 0, .{ .bytes = b.dupe(dynamic_linker) }) catch @panic("OOM");
    if (b.graph.environ_map.get("ZIGCRAFT_RUNTIME_LIBRARY_PATH")) |library_path| {
        if (library_path.len > 0) run.setEnvironmentVariable("LD_LIBRARY_PATH", library_path);
    }
    return run;
}

pub fn defineBuildOptions(b: *std.Build, optimize: std.builtin.OptimizeMode) BuildOptions {
    const options = b.addOptions();
    const enable_debug_shadows = b.option(bool, "debug_shadows", "Enable debug shadow visualization resources") orelse false;
    options.addOption(bool, "debug_shadows", enable_debug_shadows);

    const enable_imgui = b.option(bool, "imgui", "Enable Dear ImGui debug UI integration") orelse true;
    options.addOption(bool, "imgui", enable_imgui);

    const enable_rmlui = b.option(bool, "rmlui", "Enable the RmlUi 6.2 C ABI bridge") orelse false;
    options.addOption(bool, "rmlui", enable_rmlui);

    const engine_ui_options = b.addOptions();
    engine_ui_options.addOption(bool, "imgui", enable_imgui);
    engine_ui_options.addOption(bool, "rmlui", enable_rmlui);

    const smoke_test = b.option(bool, "smoke-test", "Enable automated smoke test mode (auto-loads world and exits)") orelse false;
    options.addOption(bool, "smoke_test", smoke_test);

    const chunk_debug_mode = b.option(bool, "chunk-debug-mode", "Disable water, caves, and decorations for chunk-only debugging") orelse false;
    options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);

    const chunk_debug_enable = b.option([]const u8, "chunk-debug-enable", "Re-enable one subsystem in chunk-debug-mode (water, caves, decorations)") orelse "";
    options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);
    const auto_world = b.option([]const u8, "auto-world", "Auto-open a world generator directly by id or alias (normal, overworld, overworld-v2, flat, test)") orelse "";
    options.addOption([]const u8, "auto_world", auto_world);

    const auto_preset = b.option([]const u8, "auto-preset", "Graphics preset to apply for auto-world launches (low, medium, high, ultra, extreme)") orelse "";
    options.addOption([]const u8, "auto_preset", auto_preset);

    const startup_diagnostic_seconds = b.option(u32, "startup-diagnostic-seconds", "Wait N seconds after auto-world startup, log chunk counts, and exit") orelse 0;
    options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);
    const world_runtime_options = b.addOptions();
    world_runtime_options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);
    world_runtime_options.addOption(bool, "world_runtime_module", true);

    const worldgen_overworld_options = b.addOptions();
    worldgen_overworld_options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);
    worldgen_overworld_options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);

    const skip_present = b.option(bool, "skip-present", "Skip presentation (headless mode) to avoid driver crashes") orelse false;
    options.addOption(bool, "skip_present", skip_present);

    const monitor_index = b.option(i32, "monitor-index", "Open the game window on a specific SDL display index (0-based, -1 = default)") orelse -1;
    options.addOption(i32, "monitor_index", monitor_index);

    const monitor_name = b.option([]const u8, "monitor-name", "Move the game window to a named Hyprland monitor (e.g. DP-2)") orelse "";
    options.addOption([]const u8, "monitor_name", monitor_name);

    const window_video_driver = b.option([]const u8, "window-video-driver", "SDL video driver override for the game window (x11, wayland, or empty)") orelse "";
    options.addOption([]const u8, "window_video_driver", window_video_driver);

    const window_no_focus = b.option(bool, "window-no-focus", "Create the game window without taking keyboard focus") orelse false;
    options.addOption(bool, "window_no_focus", window_no_focus);

    const engine_graphics_options = b.addOptions();
    engine_graphics_options.addOption(bool, "debug_shadows", enable_debug_shadows);
    engine_graphics_options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);
    engine_graphics_options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);
    engine_graphics_options.addOption(bool, "skip_present", skip_present);
    engine_graphics_options.addOption(bool, "imgui", enable_imgui);
    engine_graphics_options.addOption(bool, "rmlui", enable_rmlui);

    const screenshot_path = b.option([]const u8, "screenshot-path", "Capture a PNG screenshot after N frames and exit") orelse "";
    options.addOption([]const u8, "screenshot_path", screenshot_path);

    const screenshot_frame = b.option(u32, "screenshot-frame", "Frame number to capture when screenshot-path is set") orelse 120;
    options.addOption(u32, "screenshot_frame", screenshot_frame);

    const screenshot_delay_seconds = b.option(u32, "screenshot-delay-seconds", "Seconds to wait after screenshot target is ready before capture") orelse 0;
    options.addOption(u32, "screenshot_delay_seconds", screenshot_delay_seconds);

    const shadow_test_scene = b.option(bool, "shadow-test-scene", "Launch the deterministic shadow/cave lighting test scene") orelse false;
    options.addOption(bool, "shadow_test_scene", shadow_test_scene);

    const shadow_test_variant = b.option([]const u8, "shadow-test-variant", "Lighting baseline scene (noon, low-sun, cave-entrance, sealed-cave, rgb-emitter, foliage-cutout, water, cross-chunk-corridor)") orelse "cave-entrance";
    options.addOption([]const u8, "shadow_test_variant", shadow_test_variant);

    const benchmark = b.option(bool, "benchmark", "Enable benchmark mode") orelse false;
    options.addOption(bool, "benchmark", benchmark);

    const benchmark_preset = b.option([]const u8, "benchmark-preset", "Graphics preset to benchmark (low, medium, high, ultra, extreme)") orelse "medium";
    options.addOption([]const u8, "benchmark_preset", benchmark_preset);

    const benchmark_scenario = b.option([]const u8, "benchmark-scenario", "Benchmark pose scenario (stationary, traversal, rapid-turn, teleport-eviction)") orelse "traversal";
    if (!isBenchmarkScenario(benchmark_scenario)) {
        std.log.err("unsupported -Dbenchmark-scenario value '{s}' (expected stationary, traversal, rapid-turn, or teleport-eviction)", .{benchmark_scenario});
        b.invalid_user_input = true;
    }
    options.addOption([]const u8, "benchmark_scenario", benchmark_scenario);

    const benchmark_duration = b.option(u32, "benchmark-duration", "Benchmark duration in seconds") orelse 60;
    options.addOption(u32, "benchmark_duration", benchmark_duration);

    const benchmark_output = b.option([]const u8, "benchmark-output", "Benchmark JSON output path") orelse "benchmark_results.json";
    options.addOption([]const u8, "benchmark_output", benchmark_output);

    const benchmark_render_distance = b.option(i32, "benchmark-render-distance", "Override benchmark render distance; 0 uses selected preset") orelse 0;
    options.addOption(i32, "benchmark_render_distance", benchmark_render_distance);
    const benchmark_world = b.option([]const u8, "benchmark-world", "Benchmark auto-world generator (normal, overworld, overworld-v2, flat, test)") orelse "normal";
    options.addOption([]const u8, "benchmark_world", benchmark_world);
    options.addOption([]const u8, "benchmark_build_mode", @tagName(optimize));

    const sanitize = b.option([]const u8, "sanitize", "C undefined-behavior sanitizer (none, c, off); does not enable AddressSanitizer") orelse "none";
    const sanitize_c = resolveSanitizeC(b, sanitize);

    return .{
        .options = options,
        .engine_ui_options = engine_ui_options,
        .worldgen_overworld_options = worldgen_overworld_options,
        .world_runtime_options = world_runtime_options,
        .engine_graphics_options = engine_graphics_options,
        .enable_debug_shadows = enable_debug_shadows,
        .enable_imgui = enable_imgui,
        .enable_rmlui = enable_rmlui,
        .chunk_debug_mode = chunk_debug_mode,
        .chunk_debug_enable = chunk_debug_enable,
        .startup_diagnostic_seconds = startup_diagnostic_seconds,
        .skip_present = skip_present,
        .monitor_index = monitor_index,
        .monitor_name = monitor_name,
        .window_video_driver = window_video_driver,
        .window_no_focus = window_no_focus,
        .shadow_test_variant = shadow_test_variant,
        .benchmark_preset = benchmark_preset,
        .benchmark_scenario = benchmark_scenario,
        .benchmark_duration = benchmark_duration,
        .benchmark_output = benchmark_output,
        .benchmark_render_distance = benchmark_render_distance,
        .benchmark_world = benchmark_world,
        .sanitize_c = sanitize_c,
    };
}

fn isBenchmarkScenario(scenario: []const u8) bool {
    return std.mem.eql(u8, scenario, "stationary") or
        std.mem.eql(u8, scenario, "traversal") or
        std.mem.eql(u8, scenario, "rapid-turn") or
        std.mem.eql(u8, scenario, "teleport-eviction");
}

fn resolveSanitizeC(b: *std.Build, sanitize: []const u8) ?std.zig.SanitizeC {
    if (std.mem.eql(u8, sanitize, "none")) return null;
    if (std.mem.eql(u8, sanitize, "c")) return .full;
    // These values shipped in the CLI. Preserve their actual behavior, while
    // making it impossible to mistake the legacy profile for ASan coverage.
    if (std.mem.eql(u8, sanitize, "address")) {
        std.log.warn("-Dsanitize=address is deprecated: it enables C UBSan, NOT AddressSanitizer; use -Dsanitize=c", .{});
        return .full;
    }
    if (std.mem.eql(u8, sanitize, "off")) return .off;

    std.log.err("unsupported -Dsanitize value '{s}' (expected none, c, or off; deprecated alias: address)", .{sanitize});
    b.invalid_user_input = true;
    return null;
}

fn applySanitizeC(sanitize_c: ?std.zig.SanitizeC, modules: []const *std.Build.Module) void {
    if (sanitize_c) |mode| {
        for (modules) |module| {
            module.sanitize_c = mode;
        }
    }
}

fn defineShaderValidation(b: *std.Build) *std.Build.Step {
    const validate = b.addSystemCommand(&.{ "bash", "scripts/check_spirv_sizes.sh", "docs/shaders/spirv-sizes.json" });
    const validate_shadow_abi = b.addSystemCommand(&.{ "bash", "scripts/check_shadow_abi.sh" });
    validate.setCwd(b.path("."));
    validate.setEnvironmentVariable("SPIRV_UPDATE_BASELINE", "0");
    validate_shadow_abi.setCwd(b.path("."));
    validate_shadow_abi.step.dependOn(&validate.step);
    const step = b.step("test-shaders", "Validate tracked SPIR-V freshness, sizes, and shadow ABI without overwriting artifacts");
    step.dependOn(&validate_shadow_abi.step);
    return step;
}

const TestDiscovery = struct {
    step: std.Build.Step,
    runs: std.ArrayList(*std.Build.Step.Run) = .empty,
    list_names: bool,

    fn create(b: *std.Build, list_names: bool) *TestDiscovery {
        const self = b.allocator.create(TestDiscovery) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{ .id = .custom, .name = "check named test discovery", .owner = b, .makeFn = make }),
            .list_names = list_names,
        };
        return self;
    }

    fn add(self: *TestDiscovery, run: *std.Build.Step.Run) void {
        self.runs.append(self.step.owner.allocator, run) catch @panic("OOM");
        self.step.dependOn(&run.step);
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *TestDiscovery = @fieldParentPtr("step", step);
        var total: usize = 0;
        for (self.runs.items) |run| {
            const metadata = run.cached_test_metadata orelse
                return step.fail("{s}: no compiler test metadata; discovery cannot be verified on this runner", .{run.step.name});
            var count: usize = 0;
            for (metadata.names, 0..) |_, index| {
                const name = metadata.testName(@intCast(index));
                // Anonymous import-only tests (test_0, etc.) are not evidence
                // that a named filter selected any behavioral tests.
                if (std.mem.indexOf(u8, name, ".test.") == null) continue;
                count += 1;
                if (self.list_names) std.debug.print("{s}: {s}\n", .{ run.producer.?.name, name });
            }
            total += count;
            std.debug.print("Test discovery: {s}: {d} named tests\n", .{ run.producer.?.name, count });
        }
        if (total == 0) return step.fail("no named tests discovered; check the filter and file-relative test-root imports", .{});
        std.debug.print("Test discovery total: {d} named tests across {d} roots\n", .{ total, self.runs.items.len });
    }
};

fn addCimgui(_: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.linkSystemLibrary("cimgui", .{ .use_pkg_config = .force });
    compile.root_module.link_libcpp = true;
}

fn addRmlUi(compile: *std.Build.Step.Compile) void {
    compile.root_module.linkSystemLibrary("zigcraft-rmlui-bridge", .{ .use_pkg_config = .force });
    compile.root_module.link_libcpp = true;
}

fn addSharedImports(module: *std.Build.Module, zig_math: *std.Build.Module, zig_noise: *std.Build.Module, fs_module: *std.Build.Module, sync_module: *std.Build.Module, c_module: *std.Build.Module, options: *std.Build.Step.Options) void {
    addSharedImportsNoOptions(module, zig_math, zig_noise, fs_module, sync_module, c_module);
    module.addOptions("build_options", options);
}

fn addSharedImportsNoOptions(module: *std.Build.Module, zig_math: *std.Build.Module, zig_noise: *std.Build.Module, fs_module: *std.Build.Module, sync_module: *std.Build.Module, c_module: *std.Build.Module) void {
    module.addImport("zig-math", zig_math);
    module.addImport("zig-noise", zig_noise);
    module.addImport("fs", fs_module);
    module.addImport("sync", sync_module);
    module.addImport("c", c_module);
}

fn addProjectModuleImports(
    module: *std.Build.Module,
    modules: BuildModules,
) void {
    module.addImport("engine-math", modules.engine_math);
    module.addImport("engine-audio", modules.engine_audio);
    module.addImport("engine-core", modules.engine_core);
    module.addImport("engine-ecs", modules.engine_ecs);
    module.addImport("engine-input", modules.engine_input);
    module.addImport("engine-physics", modules.engine_physics);
    module.addImport("engine-rhi", modules.engine_rhi);
    module.addImport("engine-graphics", modules.engine_graphics);
    module.addImport("engine-assets", modules.engine_assets);
    module.addImport("engine-camera", modules.engine_camera);
    module.addImport("engine-clouds", modules.engine_clouds);
    module.addImport("engine-atmosphere", modules.engine_atmosphere);
    module.addImport("engine-shadows", modules.engine_shadows);
    module.addImport("engine-lighting", modules.engine_lighting);
    module.addImport("engine-ui", modules.engine_ui);
    module.addImport("world-core", modules.world_core);
    module.addImport("world-worldgen", modules.world_worldgen);
    module.addImport("world-meshing", modules.world_meshing);
    module.addImport("world-runtime", modules.world_runtime);
    module.addImport("world-persistence", modules.world_persistence);
}
