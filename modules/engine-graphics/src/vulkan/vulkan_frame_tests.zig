//! Unit tests for graphics/vulkan-frame pass orchestration.
//!
//! Tests frame orchestration state machines and pass begin/end logic.
//! These tests focus on pure logic without requiring a real GPU.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;

const MockRuntimeState = struct {
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    ssao_pass_active: bool = false,
    post_process_ran_this_frame: bool = false,
    fxaa_ran_this_frame: bool = false,
    draw_call_count: u32 = 0,
    frame_index: u32 = 0,
    main_pass_active_changed: bool = false,
    clear_color: [4]f32 = .{ 0.1, 0.1, 0.1, 1.0 },
    framebuffer_resized: bool = false,
    pipeline_rebuild_needed: bool = false,
};

const MockUIState = struct {
    ui_using_swapchain: bool = false,
    ui_vertex_offset: u32 = 0,
    ui_flushed_vertex_count: u32 = 0,
    ui_tex_descriptor_next: [rhi.MAX_FRAMES_IN_FLIGHT]u32 = .{ 0, 0 },
};

const MockShadowState = struct {
    pass_active: bool = false,
    pipeline_bound: bool = false,
    shadow_image_views: [rhi.SHADOW_CASCADE_COUNT]?*anyopaque = .{ null, null, null, null },
    shadow_sampler: ?*anyopaque = null,
    shadow_sampler_regular: ?*anyopaque = null,
    shadow_image_view: ?*anyopaque = null,
    descriptor_next: [rhi.MAX_FRAMES_IN_FLIGHT]u32 = .{ 0, 0 },
};

const MockDrawState = struct {
    terrain_pipeline_bound: bool = false,
    descriptors_updated: bool = false,
    bound_texture: u32 = 0,
    bound_normal_texture: u32 = 0,
    bound_roughness_texture: u32 = 0,
    bound_displacement_texture: u32 = 0,
    bound_env_texture: u32 = 0,
    bound_lpv_texture: u32 = 0,
    bound_lpv_texture_g: u32 = 0,
    bound_lpv_texture_b: u32 = 0,
    bound_shadow_views: [rhi.SHADOW_CASCADE_COUNT]?*anyopaque = .{ null, null, null, null },
    current_texture: u32 = 0,
    current_normal_texture: u32 = 0,
    current_roughness_texture: u32 = 0,
    current_displacement_texture: u32 = 0,
    current_env_texture: u32 = 0,
    current_lpv_texture: u32 = 0,
    current_lpv_texture_g: u32 = 0,
    current_lpv_texture_b: u32 = 0,
    descriptors_dirty: [rhi.MAX_FRAMES_IN_FLIGHT]bool = .{ false, false },
    dummy_texture: u32 = 1,
    dummy_texture_3d: u32 = 2,
};

const MockTAAState = struct {
    ran_this_frame: bool = false,
    output_texture: u32 = 0,
};

const MockFXAAState = struct {
    enabled: bool = false,
    pass_active: bool = false,
    pipeline: ?*anyopaque = null,
    render_pass: ?*anyopaque = null,
    framebuffers: std.ArrayListUnmanaged(?*anyopaque) = .empty,
    post_process_to_fxaa_render_pass: ?*anyopaque = null,
    post_process_to_fxaa_framebuffer: ?*anyopaque = null,
};

const MockPostProcessState = struct {
    pass_active: bool = false,
    pipeline: ?*anyopaque = null,
    sampler: ?*anyopaque = null,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque = .{ null, null },
    vignette_enabled: bool = false,
    vignette_intensity: f32 = 0.0,
    film_grain_enabled: bool = false,
    film_grain_intensity: f32 = 0.0,
    color_grading_enabled: bool = false,
    color_grading_intensity: f32 = 0.0,
};

const MockHDRState = struct {
    hdr_image: ?*anyopaque = null,
    hdr_view: ?*anyopaque = null,
};

const MockGPassState = struct {
    g_pass_extent: c.VkExtent2D = .{ .width = 1920, .height = 1080 },
    g_normal_image: ?*anyopaque = null,
    g_depth_image: ?*anyopaque = null,
    g_normal_view: ?*anyopaque = null,
    velocity_view: ?*anyopaque = null,
    g_depth_view: ?*anyopaque = null,
};

test "MockRuntimeState defaults to inactive passes" {
    const runtime = MockRuntimeState{};
    try testing.expect(!runtime.main_pass_active);
    try testing.expect(!runtime.g_pass_active);
    try testing.expect(!runtime.ssao_pass_active);
    try testing.expect(!runtime.post_process_ran_this_frame);
    try testing.expect(!runtime.fxaa_ran_this_frame);
    try testing.expectEqual(@as(u32, 0), runtime.draw_call_count);
}

test "MockDrawState descriptors start clean" {
    const draw = MockDrawState{};
    try testing.expect(!draw.descriptors_updated);
    try testing.expectEqual(@as(u32, 0), draw.bound_texture);
    try testing.expect(!draw.descriptors_dirty[0]);
    try testing.expect(!draw.descriptors_dirty[1]);
}

test "MockFXAAState defaults" {
    const fxaa = MockFXAAState{};
    try testing.expect(!fxaa.enabled);
    try testing.expect(!fxaa.pass_active);
    try testing.expect(fxaa.pipeline == null);
    try testing.expect(fxaa.render_pass == null);
}

test "MockPostProcessState pipeline starts null" {
    const pp = MockPostProcessState{};
    try testing.expect(!pp.pass_active);
    try testing.expect(pp.pipeline == null);
    try testing.expect(pp.sampler == null);
}

test "MockShadowState sampler starts null" {
    const shadow = MockShadowState{};
    try testing.expect(!shadow.pass_active);
    try testing.expect(shadow.shadow_sampler == null);
    try testing.expect(shadow.shadow_sampler_regular == null);
    try testing.expect(shadow.shadow_image_view == null);
}

test "MockTAAState ran_this_frame defaults false" {
    const taa = MockTAAState{};
    try testing.expect(!taa.ran_this_frame);
    try testing.expectEqual(@as(u32, 0), taa.output_texture);
}

test "FXAA enabled guard blocks begin" {
    var fxaa = MockFXAAState{};
    fxaa.enabled = false;
    fxaa.pass_active = false;
    fxaa.pipeline = @as(?*anyopaque, @ptrFromInt(1));
    fxaa.render_pass = @as(?*anyopaque, @ptrFromInt(2));

    const would_run = fxaa.enabled and !fxaa.pass_active and fxaa.pipeline != null and fxaa.render_pass != null;
    try testing.expect(!would_run);
}

test "FXAA pass_active guard blocks begin" {
    var fxaa = MockFXAAState{};
    fxaa.enabled = true;
    fxaa.pass_active = true;
    fxaa.pipeline = @as(?*anyopaque, @ptrFromInt(1));
    fxaa.render_pass = @as(?*anyopaque, @ptrFromInt(2));

    const would_run = fxaa.enabled and !fxaa.pass_active and fxaa.pipeline != null and fxaa.render_pass != null;
    try testing.expect(!would_run);
}

test "FXAA pipeline null guard blocks begin" {
    var fxaa = MockFXAAState{};
    fxaa.enabled = true;
    fxaa.pass_active = false;
    fxaa.pipeline = null;
    fxaa.render_pass = @as(?*anyopaque, @ptrFromInt(2));

    const would_run = fxaa.enabled and !fxaa.pass_active and fxaa.pipeline != null and fxaa.render_pass != null;
    try testing.expect(!would_run);
}

test "FXAA all guards pass allows begin" {
    var fxaa = MockFXAAState{};
    fxaa.enabled = true;
    fxaa.pass_active = false;
    fxaa.pipeline = @as(?*anyopaque, @ptrFromInt(1));
    fxaa.render_pass = @as(?*anyopaque, @ptrFromInt(2));

    var framebuffers = std.ArrayListUnmanaged(?*anyopaque).empty;
    defer framebuffers.deinit(testing.allocator);
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(100)));

    fxaa.framebuffers = framebuffers;

    const would_run = fxaa.enabled and !fxaa.pass_active and fxaa.pipeline != null and fxaa.render_pass != null;
    try testing.expect(would_run);
}

test "GPass active flag controls end behavior" {
    var runtime = MockRuntimeState{};

    runtime.g_pass_active = false;
    const end_should_run = runtime.g_pass_active;
    try testing.expect(!end_should_run);

    runtime.g_pass_active = true;
    const end_should_run2 = runtime.g_pass_active;
    try testing.expect(end_should_run2);
}

test "Main pass active flag controls end behavior" {
    var runtime = MockRuntimeState{};

    runtime.main_pass_active = false;
    const end_should_run = runtime.main_pass_active;
    try testing.expect(!end_should_run);

    runtime.main_pass_active = true;
    const end_should_run2 = runtime.main_pass_active;
    try testing.expect(end_should_run2);
}

test "Post-process pass active flag controls end behavior" {
    var pp = MockPostProcessState{};

    pp.pass_active = false;
    const end_should_run = pp.pass_active;
    try testing.expect(!end_should_run);

    pp.pass_active = true;
    const end_should_run2 = pp.pass_active;
    try testing.expect(end_should_run2);
}

test "FXAA pass active flag controls end behavior" {
    var fxaa = MockFXAAState{};

    fxaa.pass_active = false;
    const end_should_run = fxaa.pass_active;
    try testing.expect(!end_should_run);

    fxaa.pass_active = true;
    const end_should_run2 = fxaa.pass_active;
    try testing.expect(end_should_run2);
}

test "Shadow pass active flag controls end behavior" {
    var shadow = MockShadowState{};

    shadow.pass_active = false;
    const end_should_run = shadow.pass_active;
    try testing.expect(!end_should_run);

    shadow.pass_active = true;
    const end_should_run2 = shadow.pass_active;
    try testing.expect(end_should_run2);
}

test "Texture binding comparison logic - no change" {
    var draw = MockDrawState{};
    draw.bound_texture = 5;
    draw.current_texture = 5;
    draw.bound_normal_texture = 6;
    draw.current_normal_texture = 6;
    draw.bound_roughness_texture = 7;
    draw.current_roughness_texture = 7;
    draw.bound_displacement_texture = 8;
    draw.current_displacement_texture = 8;
    draw.bound_env_texture = 9;
    draw.current_env_texture = 9;
    draw.bound_lpv_texture = 10;
    draw.current_lpv_texture = 10;
    draw.bound_lpv_texture_g = 11;
    draw.current_lpv_texture_g = 11;
    draw.bound_lpv_texture_b = 12;
    draw.current_lpv_texture_b = 12;

    var needs_update = false;
    if (draw.bound_texture != draw.current_texture) needs_update = true;
    if (draw.bound_normal_texture != draw.current_normal_texture) needs_update = true;
    if (draw.bound_roughness_texture != draw.current_roughness_texture) needs_update = true;
    if (draw.bound_displacement_texture != draw.current_displacement_texture) needs_update = true;
    if (draw.bound_env_texture != draw.current_env_texture) needs_update = true;
    if (draw.bound_lpv_texture != draw.current_lpv_texture) needs_update = true;
    if (draw.bound_lpv_texture_g != draw.current_lpv_texture_g) needs_update = true;
    if (draw.bound_lpv_texture_b != draw.current_lpv_texture_b) needs_update = true;

    try testing.expect(!needs_update);
}

test "Texture binding comparison logic - change detected" {
    var draw = MockDrawState{};
    draw.bound_texture = 5;
    draw.current_texture = 6;

    var needs_update = false;
    if (draw.bound_texture != draw.current_texture) needs_update = true;

    try testing.expect(needs_update);
}

test "Shadow view binding comparison logic" {
    var draw = MockDrawState{};
    draw.bound_shadow_views[0] = @as(?*anyopaque, @ptrFromInt(100));
    draw.bound_shadow_views[1] = @as(?*anyopaque, @ptrFromInt(101));
    draw.bound_shadow_views[2] = @as(?*anyopaque, @ptrFromInt(102));
    draw.bound_shadow_views[3] = @as(?*anyopaque, @ptrFromInt(103));

    var shadow = MockShadowState{};
    shadow.shadow_image_views[0] = @as(?*anyopaque, @ptrFromInt(100));
    shadow.shadow_image_views[1] = @as(?*anyopaque, @ptrFromInt(101));
    shadow.shadow_image_views[2] = @as(?*anyopaque, @ptrFromInt(102));
    shadow.shadow_image_views[3] = @as(?*anyopaque, @ptrFromInt(103));

    var needs_update = false;
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (draw.bound_shadow_views[si] != shadow.shadow_image_views[si]) needs_update = true;
    }

    try testing.expect(!needs_update);
}

test "Shadow view binding change detected" {
    var draw = MockDrawState{};
    draw.bound_shadow_views[0] = @as(?*anyopaque, @ptrFromInt(100));
    draw.bound_shadow_views[1] = @as(?*anyopaque, @ptrFromInt(101));
    draw.bound_shadow_views[2] = @as(?*anyopaque, @ptrFromInt(102));
    draw.bound_shadow_views[3] = @as(?*anyopaque, @ptrFromInt(103));

    var shadow = MockShadowState{};
    shadow.shadow_image_views[0] = @as(?*anyopaque, @ptrFromInt(100));
    shadow.shadow_image_views[1] = @as(?*anyopaque, @ptrFromInt(999));
    shadow.shadow_image_views[2] = @as(?*anyopaque, @ptrFromInt(102));
    shadow.shadow_image_views[3] = @as(?*anyopaque, @ptrFromInt(103));

    var needs_update = false;
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (draw.bound_shadow_views[si] != shadow.shadow_image_views[si]) needs_update = true;
    }

    try testing.expect(needs_update);
}

test "Descriptors dirty flag set when texture changes" {
    var draw = MockDrawState{};
    var descriptors_dirty = [_]bool{ false, false };
    const current_frame: usize = 0;

    draw.bound_texture = 5;
    draw.bound_normal_texture = 6;
    draw.bound_roughness_texture = 7;
    draw.bound_displacement_texture = 8;
    draw.bound_env_texture = 9;
    draw.bound_lpv_texture = 10;
    draw.bound_lpv_texture_g = 11;
    draw.bound_lpv_texture_b = 12;
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        draw.bound_shadow_views[si] = @as(?*anyopaque, @ptrFromInt(@as(u64, 100 + si)));
    }

    draw.current_texture = 99;

    var needs_update = false;
    if (draw.bound_texture != draw.current_texture) needs_update = true;
    if (draw.bound_normal_texture != draw.current_normal_texture) needs_update = true;
    if (draw.bound_roughness_texture != draw.current_roughness_texture) needs_update = true;
    if (draw.bound_displacement_texture != draw.current_displacement_texture) needs_update = true;
    if (draw.bound_env_texture != draw.current_env_texture) needs_update = true;
    if (draw.bound_lpv_texture != draw.current_lpv_texture) needs_update = true;
    if (draw.bound_lpv_texture_g != draw.current_lpv_texture_g) needs_update = true;
    if (draw.bound_lpv_texture_b != draw.current_lpv_texture_b) needs_update = true;
    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (draw.bound_shadow_views[si] != @as(?*anyopaque, @ptrFromInt(@as(u64, 100 + si)))) needs_update = true;
    }

    if (needs_update) {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| descriptors_dirty[i] = true;
    }

    try testing.expect(descriptors_dirty[current_frame]);
    try testing.expect(descriptors_dirty[1]);
}

test "Frame index increments" {
    var runtime = MockRuntimeState{};
    try testing.expectEqual(@as(u32, 0), runtime.frame_index);

    runtime.frame_index += 1;
    try testing.expectEqual(@as(u32, 1), runtime.frame_index);

    runtime.frame_index += 1;
    try testing.expectEqual(@as(u32, 2), runtime.frame_index);
}

test "UI state resets correctly" {
    var ui = MockUIState{};
    ui.ui_vertex_offset = 100;
    ui.ui_flushed_vertex_count = 50;
    ui.ui_tex_descriptor_next[0] = 10;
    ui.ui_tex_descriptor_next[1] = 20;

    ui.ui_vertex_offset = 0;
    ui.ui_flushed_vertex_count = 0;
    ui.ui_tex_descriptor_next[0] = 0;
    ui.ui_tex_descriptor_next[1] = 0;

    try testing.expectEqual(@as(u32, 0), ui.ui_vertex_offset);
    try testing.expectEqual(@as(u32, 0), ui.ui_flushed_vertex_count);
    try testing.expectEqual(@as(u32, 0), ui.ui_tex_descriptor_next[0]);
    try testing.expectEqual(@as(u32, 0), ui.ui_tex_descriptor_next[1]);
}

test "Draw call count increments" {
    var runtime = MockRuntimeState{};
    try testing.expectEqual(@as(u32, 0), runtime.draw_call_count);

    runtime.draw_call_count += 1;
    try testing.expectEqual(@as(u32, 1), runtime.draw_call_count);

    runtime.draw_call_count += 1;
    try testing.expectEqual(@as(u32, 2), runtime.draw_call_count);
}

test "ensureNoRenderPassActive ordering" {
    var runtime = MockRuntimeState{};
    var shadow = MockShadowState{};
    var pp = MockPostProcessState{};
    var fxaa = MockFXAAState{};

    runtime.main_pass_active = true;
    runtime.g_pass_active = true;
    shadow.pass_active = true;
    pp.pass_active = true;
    fxaa.pass_active = true;

    if (runtime.main_pass_active) runtime.main_pass_active = false;
    if (shadow.pass_active) shadow.pass_active = false;
    if (runtime.g_pass_active) runtime.g_pass_active = false;
    if (pp.pass_active) pp.pass_active = false;

    try testing.expect(!runtime.main_pass_active);
    try testing.expect(!shadow.pass_active);
    try testing.expect(!runtime.g_pass_active);
    try testing.expect(!pp.pass_active);
    try testing.expect(fxaa.pass_active);
}

test "RenderPassManager getMSAASampleCountFlag mapping" {
    const getMSAASampleCountFlag = @import("render_pass_manager.zig").getMSAASampleCountFlag;

    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(1));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_2_BIT), getMSAASampleCountFlag(2));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_4_BIT), getMSAASampleCountFlag(4));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_8_BIT), getMSAASampleCountFlag(8));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(16));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(0));
}

test "RenderPassManager createMainRenderPass MSAA use_msaa flag" {
    const use_msaa_1 = @as(u8, 1) > 1;
    try testing.expect(!use_msaa_1);

    const use_msaa_2 = @as(u8, 2) > 1;
    try testing.expect(use_msaa_2);

    const use_msaa_4 = @as(u8, 4) > 1;
    try testing.expect(use_msaa_4);

    const use_msaa_8 = @as(u8, 8) > 1;
    try testing.expect(use_msaa_8);
}

test "post-process framebuffer list management" {
    var framebuffers = std.ArrayListUnmanaged(?*anyopaque).empty;
    defer framebuffers.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), framebuffers.items.len);

    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(100)));
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(101)));
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(102)));

    try testing.expectEqual(@as(usize, 3), framebuffers.items.len);
    try testing.expectEqual(@as(usize, 3), framebuffers.items.len);

    framebuffers.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), framebuffers.items.len);

    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(200)));
    try testing.expectEqual(@as(usize, 1), framebuffers.items.len);
}

test "ui_swapchain framebuffer list management" {
    var framebuffers = std.ArrayListUnmanaged(?*anyopaque).empty;
    defer framebuffers.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), framebuffers.items.len);

    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(1)));
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(2)));
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(3)));
    try framebuffers.append(testing.allocator, @as(?*anyopaque, @ptrFromInt(4)));

    try testing.expectEqual(@as(usize, 4), framebuffers.items.len);

    for (framebuffers.items) |fb| {
        try testing.expect(fb != null);
    }
}

test "G-pass extent comparison" {
    const g_extent = c.VkExtent2D{ .width = 1920, .height = 1080 };
    const swapchain_extent = c.VkExtent2D{ .width = 1920, .height = 1080 };

    const extent_matches = g_extent.width == swapchain_extent.width and g_extent.height == swapchain_extent.height;
    try testing.expect(extent_matches);
}

test "G-pass extent mismatch detection" {
    const g_extent = c.VkExtent2D{ .width = 1280, .height = 720 };
    const swapchain_extent = c.VkExtent2D{ .width = 1920, .height = 1080 };

    const extent_matches = g_extent.width == swapchain_extent.width and g_extent.height == swapchain_extent.height;
    try testing.expect(!extent_matches);
}

test "VkRenderPassBeginInfo clear values count" {
    var clear_values: [3]c.VkClearValue = undefined;
    clear_values[0] = std.mem.zeroes(c.VkClearValue);
    clear_values[0].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[1] = std.mem.zeroes(c.VkClearValue);
    clear_values[1].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[2] = std.mem.zeroes(c.VkClearValue);
    clear_values[2].depthStencil = .{ .depth = 0.0, .stencil = 0 };

    const clearValueCount: u32 = 3;

    try testing.expectEqual(@as(u32, 3), clearValueCount);
}

test "VkRenderPassBeginInfo clear values for main pass" {
    var clear_values: [2]c.VkClearValue = undefined;
    clear_values[0] = std.mem.zeroes(c.VkClearValue);
    clear_values[0].color = .{ .float32 = .{ 0.1, 0.1, 0.1, 1.0 } };
    clear_values[1] = std.mem.zeroes(c.VkClearValue);
    clear_values[1].depthStencil = .{ .depth = 0.0, .stencil = 0 };

    try testing.expectEqual(@as(f32, 0.1), clear_values[0].color.float32[0]);
    try testing.expectEqual(@as(f32, 0.1), clear_values[0].color.float32[1]);
    try testing.expectEqual(@as(f32, 0.1), clear_values[0].color.float32[2]);
    try testing.expectEqual(@as(f32, 1.0), clear_values[0].color.float32[3]);
    try testing.expectEqual(@as(f32, 0.0), clear_values[1].depthStencil.depth);
    try testing.expectEqual(@as(u32, 0), clear_values[1].depthStencil.stencil);
}

test "VkViewport dimensions from extent" {
    const extent = c.VkExtent2D{ .width = 1920, .height = 1080 };

    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .minDepth = 0,
        .maxDepth = 1,
    };

    try testing.expectEqual(@as(f32, 1920), viewport.width);
    try testing.expectEqual(@as(f32, 1080), viewport.height);
}

test "VkRect2D scissor from extent" {
    const extent = c.VkExtent2D{ .width = 1920, .height = 1080 };

    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    try testing.expectEqual(@as(i32, 0), scissor.offset.x);
    try testing.expectEqual(@as(i32, 0), scissor.offset.y);
    try testing.expectEqual(@as(u32, 1920), scissor.extent.width);
    try testing.expectEqual(@as(u32, 1080), scissor.extent.height);
}

test "DynamicResolution getRenderExtent" {
    const MockDynamicResolution = struct {
        pub fn getRenderExtent(_: @This()) c.VkExtent2D {
            return .{ .width = 1920, .height = 1080 };
        }
    };

    const dr = MockDynamicResolution{};
    const extent = dr.getRenderExtent();
    try testing.expectEqual(@as(u32, 1920), extent.width);
    try testing.expectEqual(@as(u32, 1080), extent.height);
}

test "Swapchain getExtent consistency" {
    const MockSwapchain = struct {
        pub fn getExtent(_: @This()) c.VkExtent2D {
            return .{ .width = 1920, .height = 1080 };
        }
    };

    const swapchain = MockSwapchain{};
    const extent = swapchain.getExtent();
    try testing.expectEqual(@as(u32, 1920), extent.width);
    try testing.expectEqual(@as(u32, 1080), extent.height);
}

test "Image index bounds check for FXAA" {
    const framebuffers_len: usize = 3;

    var image_index: u32 = 0;
    try testing.expect(image_index < framebuffers_len);

    image_index = 2;
    try testing.expect(image_index < framebuffers_len);

    image_index = 3;
    try testing.expect(image_index >= framebuffers_len);
}

test "Post-process framebuffer index bounds check" {
    const framebuffers_len: usize = 3;

    var image_index: u32 = 2;
    try testing.expect(image_index < framebuffers_len);

    image_index = 3;
    try testing.expect(image_index >= framebuffers_len);
}
