const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zig-math", zig_math);
    root_module.addImport("zig-noise", zig_noise);
    root_module.addIncludePath(b.path("libs/stb"));

    const exe = b.addExecutable(.{
        .name = "zigcraft",
        .root_module = root_module,
    });

    exe.linkLibC();
    exe.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    exe.linkSystemLibrary("sdl3");
    exe.linkSystemLibrary("vulkan");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setCwd(b.path("."));

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root_module.addImport("zig-math", zig_math);
    test_root_module.addImport("zig-noise", zig_noise);

    const exe_tests = b.addTest(.{
        .root_module = test_root_module,
    });
    exe_tests.linkLibC();
    exe_tests.linkSystemLibrary("sdl3");
    exe_tests.linkSystemLibrary("vulkan");
    exe_tests.addIncludePath(b.path("libs/stb"));

    const test_step = b.step("test", "Run unit tests");
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    const integration_root_module = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_root_module.addImport("zig-math", zig_math);
    integration_root_module.addImport("zig-noise", zig_noise);
    integration_root_module.addIncludePath(b.path("libs/stb"));

    const exe_integration_tests = b.addTest(.{
        .root_module = integration_root_module,
    });
    exe_integration_tests.linkLibC();
    exe_integration_tests.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    exe_integration_tests.linkSystemLibrary("sdl3");
    exe_integration_tests.linkSystemLibrary("vulkan");

    const test_integration_step = b.step("test-integration", "Run integration smoke test");
    const run_integration_tests = b.addRunArtifact(exe_integration_tests);
    test_integration_step.dependOn(&run_integration_tests.step);

    // Robust Vulkan demo executable
    const robust_demo = b.addExecutable(.{
        .name = "robust-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/robust_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    robust_demo.linkLibC();
    robust_demo.linkSystemLibrary("sdl3");
    robust_demo.linkSystemLibrary("vulkan");
    robust_demo.addIncludePath(b.path("libs/stb"));

    b.installArtifact(robust_demo);

    const integration_robustness = b.addExecutable(.{
        .name = "test-robustness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test_robustness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_robustness.linkLibC();
    integration_robustness.linkSystemLibrary("sdl3"); // Needed for C imports if any

    const test_robustness_run = b.addRunArtifact(integration_robustness);
    // Ensure robust-demo is built first
    test_robustness_run.step.dependOn(&b.addInstallArtifact(robust_demo, .{}).step);

    const test_robustness_step = b.step("test-robustness", "Run robustness integration test");
    test_robustness_step.dependOn(&test_robustness_run.step);

    const run_robust_cmd = b.addRunArtifact(robust_demo);
    run_robust_cmd.step.dependOn(b.getInstallStep());

    const run_robust_step = b.step("run-robust", "Run the GPU robustness demo");
    run_robust_step.dependOn(&run_robust_cmd.step);

    const validate_vulkan_terrain_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/terrain.vert" });
    const validate_vulkan_terrain_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/terrain.frag" });
    const validate_vulkan_shadow_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/shadow.vert" });
    const validate_vulkan_shadow_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/shadow.frag" });
    const validate_vulkan_sky_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/sky.vert" });
    const validate_vulkan_sky_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/sky.frag" });
    const validate_vulkan_ui_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui.vert" });
    const validate_vulkan_ui_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui.frag" });
    const validate_vulkan_ui_tex_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui_tex.vert" });
    const validate_vulkan_ui_tex_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui_tex.frag" });
    const validate_vulkan_cloud_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/cloud.vert" });
    const validate_vulkan_cloud_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/cloud.frag" });
    const validate_vulkan_debug_shadow_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/debug_shadow.vert" });
    const validate_vulkan_debug_shadow_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/debug_shadow.frag" });
    const validate_vulkan_ssao_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao.vert" });
    const validate_vulkan_ssao_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao.frag" });
    const validate_vulkan_ssao_blur_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao_blur.frag" });
    const validate_vulkan_g_pass_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/g_pass.frag" });

    test_step.dependOn(&validate_vulkan_terrain_vert.step);
    test_step.dependOn(&validate_vulkan_terrain_frag.step);
    test_step.dependOn(&validate_vulkan_shadow_vert.step);
    test_step.dependOn(&validate_vulkan_shadow_frag.step);
    test_step.dependOn(&validate_vulkan_sky_vert.step);
    test_step.dependOn(&validate_vulkan_sky_frag.step);
    test_step.dependOn(&validate_vulkan_ui_vert.step);
    test_step.dependOn(&validate_vulkan_ui_frag.step);
    test_step.dependOn(&validate_vulkan_ui_tex_vert.step);
    test_step.dependOn(&validate_vulkan_ui_tex_frag.step);
    test_step.dependOn(&validate_vulkan_cloud_vert.step);
    test_step.dependOn(&validate_vulkan_cloud_frag.step);
    test_step.dependOn(&validate_vulkan_debug_shadow_vert.step);
    test_step.dependOn(&validate_vulkan_debug_shadow_frag.step);
    test_step.dependOn(&validate_vulkan_ssao_vert.step);
    test_step.dependOn(&validate_vulkan_ssao_frag.step);
    test_step.dependOn(&validate_vulkan_ssao_blur_frag.step);
    test_step.dependOn(&validate_vulkan_g_pass_frag.step);
}
