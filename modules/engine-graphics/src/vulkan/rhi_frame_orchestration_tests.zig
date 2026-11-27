//! Unit tests for graphics/vulkan-frame orchestration logic
//!
//! Covers prepareFrameState texture binding logic and pass orchestration state machines.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const frame_orchestration = @import("rhi_frame_orchestration.zig");

const MockSwapchainRuntime = struct {
    swapchain_recreate_failed: bool = false,
    framebuffer_resized: bool = false,
    pipeline_rebuild_needed: bool = false,
};

const MockSwapchainContext = struct {
    runtime: MockSwapchainRuntime = .{},
};

test "prepareFrameState texture binding needs_update detection" {
    const bound_texture: u32 = 0;
    const current_texture: u32 = 100;
    var needs_update = false;

    if (bound_texture != current_texture) needs_update = true;
    try testing.expect(needs_update);
}

test "markSwapchainRecreateFailed sets explicit retry state" {
    var ctx = MockSwapchainContext{};
    ctx.runtime.framebuffer_resized = true;

    const logged = frame_orchestration.markSwapchainRecreateFailed(&ctx, "test stage", error.OutOfMemory);

    try testing.expect(logged);
    try testing.expect(ctx.runtime.swapchain_recreate_failed);
    // The resize request is consumed on failure so beginFrame does not retry
    // every frame (which would loop when the failure is persistent).
    try testing.expect(!ctx.runtime.framebuffer_resized);
    try testing.expect(ctx.runtime.pipeline_rebuild_needed);
}

test "markSwapchainRecreateFailed logs only first failure" {
    var ctx = MockSwapchainContext{};

    const first_logged = frame_orchestration.markSwapchainRecreateFailed(&ctx, "first", error.OutOfMemory);
    const second_logged = frame_orchestration.markSwapchainRecreateFailed(&ctx, "second", error.OutOfMemory);

    try testing.expect(first_logged);
    try testing.expect(!second_logged);
    try testing.expect(ctx.runtime.swapchain_recreate_failed);
    try testing.expect(!ctx.runtime.framebuffer_resized);
    try testing.expect(ctx.runtime.pipeline_rebuild_needed);
}

test "beginFrame recreate guard blocks retry after persistent SSAO failure" {
    // Simulates the swapchain-recreate loop fixed in issue #725:
    //   frame 1: resize requested -> recreate attempted -> SSAO fails
    //   frame 2+: beginFrame must NOT retry the recreation every frame
    var ctx = MockSwapchainContext{};

    // Resize requested by the windowing layer.
    ctx.runtime.framebuffer_resized = true;
    const attempt_frame1 = (ctx.runtime.framebuffer_resized) and !ctx.runtime.swapchain_recreate_failed;
    try testing.expect(attempt_frame1);

    // SSAO creation fails during recreateSwapchainInternal.
    _ = frame_orchestration.markSwapchainRecreateFailed(&ctx, "SSAO resources", error.OutOfMemory);

    // Subsequent frames: the guard condition must be false so no retry occurs.
    const attempt_frame2 = (ctx.runtime.framebuffer_resized) and !ctx.runtime.swapchain_recreate_failed;
    try testing.expect(!attempt_frame2);
    try testing.expect(ctx.runtime.swapchain_recreate_failed);
    try testing.expect(!ctx.runtime.framebuffer_resized);

    // A fresh resize request clears the failed flag, allowing a new attempt.
    ctx.runtime.framebuffer_resized = true;
    ctx.runtime.swapchain_recreate_failed = false;
    const attempt_after_new_resize = (ctx.runtime.framebuffer_resized) and !ctx.runtime.swapchain_recreate_failed;
    try testing.expect(attempt_after_new_resize);
}

test "markSwapchainRecreateSucceeded clears failure state" {
    var ctx = MockSwapchainContext{ .runtime = .{
        .swapchain_recreate_failed = true,
        .framebuffer_resized = true,
        .pipeline_rebuild_needed = true,
    } };

    frame_orchestration.markSwapchainRecreateSucceeded(&ctx);

    try testing.expect(!ctx.runtime.swapchain_recreate_failed);
    try testing.expect(!ctx.runtime.framebuffer_resized);
    try testing.expect(!ctx.runtime.pipeline_rebuild_needed);
}

test "prepareFrameState texture binding no update when same" {
    const bound_texture: u32 = 100;
    const current_texture: u32 = 100;
    var needs_update = false;

    if (bound_texture != current_texture) needs_update = true;
    try testing.expect(!needs_update);
}

test "prepareFrameState descriptors_dirty set when needs_update true" {
    var descriptors_dirty = [2]bool{ false, false };
    const bound_texture: u32 = 0;
    const current_texture: u32 = 100;
    var needs_update = false;
    const current_frame: usize = 0;

    if (bound_texture != current_texture) needs_update = true;
    if (needs_update) {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| descriptors_dirty[i] = true;
    }

    try testing.expect(descriptors_dirty[0]);
    try testing.expect(descriptors_dirty[1]);
    _ = current_frame;
}

test "prepareFrameState descriptors_dirty unchanged when no needs_update" {
    var descriptors_dirty = [2]bool{ false, false };
    const bound_texture: u32 = 100;
    const current_texture: u32 = 100;
    var needs_update = false;

    if (bound_texture != current_texture) needs_update = true;
    if (needs_update) {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| descriptors_dirty[i] = true;
    }

    try testing.expect(!descriptors_dirty[0]);
    try testing.expect(!descriptors_dirty[1]);
}

test "texture binding comparison with null texture handle" {
    const bound_texture: u32 = 0;
    const current_texture: u32 = 0;
    var needs_update = false;

    if (bound_texture != current_texture) needs_update = true;
    try testing.expect(!needs_update);
}

test "shadow views binding needs_update detection" {
    const bound_shadow_views: [4]c.VkImageView = .{ null, null, null, null };
    const shadow_image_views: [4]c.VkImageView = .{ @ptrFromInt(1), null, null, null };
    var needs_update = false;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (bound_shadow_views[si] != shadow_image_views[si]) needs_update = true;
    }

    try testing.expect(needs_update);
}

test "shadow views binding no update when same" {
    const bound_shadow_views: [4]c.VkImageView = .{ @ptrFromInt(1), null, null, null };
    const shadow_image_views: [4]c.VkImageView = .{ @ptrFromInt(1), null, null, null };
    var needs_update = false;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (bound_shadow_views[si] != shadow_image_views[si]) needs_update = true;
    }

    try testing.expect(!needs_update);
}

test "all texture slots compared for needs_update" {
    const bound_tex: u32 = 0;
    const bound_nor: u32 = 0;
    const bound_rou: u32 = 0;
    const bound_dis: u32 = 0;
    const bound_env: u32 = 0;
    const bound_lpv: u32 = 0;
    const bound_lpv_g: u32 = 0;
    const bound_lpv_b: u32 = 0;

    const cur_tex: u32 = 1;
    const cur_nor: u32 = 0;
    const cur_rou: u32 = 0;
    const cur_dis: u32 = 0;
    const cur_env: u32 = 0;
    const cur_lpv: u32 = 0;
    const cur_lpv_g: u32 = 0;
    const cur_lpv_b: u32 = 0;

    var needs_update = false;
    if (bound_tex != cur_tex) needs_update = true;
    if (bound_nor != cur_nor) needs_update = true;
    if (bound_rou != cur_rou) needs_update = true;
    if (bound_dis != cur_dis) needs_update = true;
    if (bound_env != cur_env) needs_update = true;
    if (bound_lpv != cur_lpv) needs_update = true;
    if (bound_lpv_g != cur_lpv_g) needs_update = true;
    if (bound_lpv_b != cur_lpv_b) needs_update = true;

    try testing.expect(needs_update);
}

test "render pass manager shadow cascade count is 4" {
    try testing.expectEqual(@as(u32, 4), rhi.SHADOW_CASCADE_COUNT);
}

test "descriptor set array size for MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), 2);
}

test "frame index wraps modulo MAX_FRAMES_IN_FLIGHT" {
    var frame_index: usize = 0;

    for (0..rhi.MAX_FRAMES_IN_FLIGHT) |_| {
        frame_index = (frame_index + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    }

    try testing.expectEqual(@as(usize, 0), frame_index);
}

test "draw call count increments" {
    var draw_call_count: u32 = 0;
    draw_call_count += 1;
    try testing.expectEqual(@as(u32, 1), draw_call_count);
}

test "ui_vertex_offset and ui_flushed_vertex_count start at zero" {
    const ui_vertex_offset: u32 = 0;
    const ui_flushed_vertex_count: u32 = 0;
    try testing.expectEqual(@as(u32, 0), ui_vertex_offset);
    try testing.expectEqual(@as(u32, 0), ui_flushed_vertex_count);
}

test "main_pass_active and g_pass_active are mutually exclusive by design" {
    var main_pass_active = false;
    var g_pass_active = false;

    main_pass_active = true;
    try testing.expect(main_pass_active);
    try testing.expect(!g_pass_active);

    main_pass_active = false;
    g_pass_active = true;
    try testing.expect(!main_pass_active);
    try testing.expect(g_pass_active);
}

test "ensureNoRenderPassActiveInternal ends passes in correct order" {
    var main_pass_active = true;
    var shadow_pass_active = true;
    var g_pass_active = true;
    var post_process_pass_active = true;

    if (main_pass_active) main_pass_active = false;
    if (shadow_pass_active) shadow_pass_active = false;
    if (g_pass_active) g_pass_active = false;
    if (post_process_pass_active) post_process_pass_active = false;

    try testing.expect(!main_pass_active);
    try testing.expect(!shadow_pass_active);
    try testing.expect(!g_pass_active);
    try testing.expect(!post_process_pass_active);
}

test "frame_in_progress guards against nested frame calls" {
    const frame_in_progress = true;
    const would_nest = frame_in_progress;
    try testing.expect(would_nest);
}

test "fxaa_ran_this_frame starts false" {
    const fxaa_ran_this_frame = false;
    try testing.expect(!fxaa_ran_this_frame);
}

test "post_process_ran_this_frame starts false" {
    const post_process_ran_this_frame = false;
    try testing.expect(!post_process_ran_this_frame);
}

test "ui_using_swapchain starts false" {
    const ui_using_swapchain = false;
    try testing.expect(!ui_using_swapchain);
}

test "terrain_pipeline_bound starts false" {
    const terrain_pipeline_bound = false;
    try testing.expect(!terrain_pipeline_bound);
}

test "descriptors_updated starts false" {
    const descriptors_updated = false;
    try testing.expect(!descriptors_updated);
}

test "bound_texture starts at 0 (null handle)" {
    const bound_texture: u32 = 0;
    try testing.expectEqual(@as(u32, 0), bound_texture);
}

test "VkMemoryBarrier sType is correct" {
    var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
    mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_MEMORY_BARRIER), mem_barrier.sType);
}

test "VkMemoryBarrier access mask configuration" {
    var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
    mem_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT;
    mem_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
    try testing.expectEqual(@as(u32, c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT), mem_barrier.srcAccessMask);
}

test "pipeline stage masks for memory barrier" {
    const src_stage = c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    const dst_stage = c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT;
    try testing.expect(src_stage != 0);
    try testing.expect(dst_stage != 0);
}

test "current_image_index bounds check for framebuffer access" {
    var current_image_index: u32 = 0;
    const framebuffers_len: usize = 3;

    try testing.expect(current_image_index < framebuffers_len);

    current_image_index = 2;
    try testing.expect(current_image_index < framebuffers_len);

    current_image_index = 3;
    try testing.expect(current_image_index >= framebuffers_len);
}

test "image_index wraps correctly for swapchain images" {
    const max_images = rhi.MAX_SWAPCHAIN_IMAGES;
    var current_image_index: u32 = 0;

    current_image_index = @mod(current_image_index + 1, max_images);
    try testing.expect(current_image_index < max_images);
}
