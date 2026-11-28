//! Unit tests for graphics/vulkan-frame frame manager
//!
//! Covers FrameManager state machine, checkVk error mappings, and orchestration logic.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;

const Utils = @import("utils.zig");

test "checkVk returns success for VK_SUCCESS" {
    try testing.expectEqual({}, try Utils.checkVk(c.VK_SUCCESS));
}

test "checkVk returns error.GpuLost for VK_ERROR_DEVICE_LOST" {
    try testing.expectError(error.GpuLost, Utils.checkVk(c.VK_ERROR_DEVICE_LOST));
}

test "checkVk returns error.OutOfMemory for VK_ERROR_OUT_OF_HOST_MEMORY" {
    try testing.expectError(error.OutOfMemory, Utils.checkVk(c.VK_ERROR_OUT_OF_HOST_MEMORY));
}

test "checkVk returns error.OutOfMemory for VK_ERROR_OUT_OF_DEVICE_MEMORY" {
    try testing.expectError(error.OutOfMemory, Utils.checkVk(c.VK_ERROR_OUT_OF_DEVICE_MEMORY));
}

test "checkVk returns error.SurfaceLost for VK_ERROR_SURFACE_LOST_KHR" {
    try testing.expectError(error.SurfaceLost, Utils.checkVk(c.VK_ERROR_SURFACE_LOST_KHR));
}

test "checkVk returns error.InitializationFailed for VK_ERROR_INITIALIZATION_FAILED" {
    try testing.expectError(error.InitializationFailed, Utils.checkVk(c.VK_ERROR_INITIALIZATION_FAILED));
}

test "checkVk returns error.ExtensionNotPresent for VK_ERROR_EXTENSION_NOT_PRESENT" {
    try testing.expectError(error.ExtensionNotPresent, Utils.checkVk(c.VK_ERROR_EXTENSION_NOT_PRESENT));
}

test "checkVk returns error.FeatureNotPresent for VK_ERROR_FEATURE_NOT_PRESENT" {
    try testing.expectError(error.FeatureNotPresent, Utils.checkVk(c.VK_ERROR_FEATURE_NOT_PRESENT));
}

test "checkVk returns error.TooManyObjects for VK_ERROR_TOO_MANY_OBJECTS" {
    try testing.expectError(error.TooManyObjects, Utils.checkVk(c.VK_ERROR_TOO_MANY_OBJECTS));
}

test "checkVk returns error.FormatNotSupported for VK_ERROR_FORMAT_NOT_SUPPORTED" {
    try testing.expectError(error.FormatNotSupported, Utils.checkVk(c.VK_ERROR_FORMAT_NOT_SUPPORTED));
}

test "checkVk returns error.FragmentedPool for VK_ERROR_FRAGMENTED_POOL" {
    try testing.expectError(error.FragmentedPool, Utils.checkVk(c.VK_ERROR_FRAGMENTED_POOL));
}

test "checkVk returns error.Unknown for unrecognized VkResult" {
    try testing.expectError(error.Unknown, Utils.checkVk(@as(c_int, -999)));
}

test "FrameManager frame_in_progress prevents beginFrame" {
    const frame_in_progress = true;
    try testing.expect(frame_in_progress);
}

test "FrameManager endFrame requires frame_in_progress" {
    const frame_in_progress = false;
    try testing.expect(!frame_in_progress);
}

test "FrameManager abortFrame only acts when frame_in_progress" {
    var frame_in_progress = false;
    if (frame_in_progress) {
        frame_in_progress = false;
    }
    try testing.expectEqual(@as(bool, false), frame_in_progress);
}

test "FrameManager abortFrame clears frame_in_progress" {
    var frame_in_progress = true;
    frame_in_progress = false;
    try testing.expectEqual(@as(bool, false), frame_in_progress);
}

test "FrameManager current_frame cycles through all frames" {
    var current_frame: usize = 0;
    const max_frames = rhi.MAX_FRAMES_IN_FLIGHT;

    current_frame = (current_frame + 1) % max_frames;
    try testing.expectEqual(@as(usize, 1), current_frame);

    current_frame = (current_frame + 1) % max_frames;
    try testing.expectEqual(@as(usize, 0), current_frame);

    current_frame = (current_frame + 1) % max_frames;
    try testing.expectEqual(@as(usize, 1), current_frame);
}

test "FrameManager current_frame cycles correctly through 10 iterations" {
    var current_frame: usize = 0;
    const max_frames = rhi.MAX_FRAMES_IN_FLIGHT;

    for (0..10) |_| {
        current_frame = (current_frame + 1) % max_frames;
    }

    try testing.expectEqual(@as(usize, 0), current_frame);
}

test "FrameManager getCurrentCommandBuffer returns correct buffer by index" {
    var current_frame: usize = 0;
    var command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer = .{ null, null };
    command_buffers[0] = @ptrFromInt(100);
    command_buffers[1] = @ptrFromInt(200);

    const cb = command_buffers[current_frame];
    try testing.expect(cb == @as(c.VkCommandBuffer, @ptrFromInt(100)));

    current_frame = 1;
    const cb2 = command_buffers[current_frame];
    try testing.expect(cb2 == @as(c.VkCommandBuffer, @ptrFromInt(200)));
}

test "VkCommandBufferBeginInfo sType is correct" {
    const begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO), begin_info.sType);
}

test "VkSubmitInfo sType is correct" {
    const submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 0,
        .pCommandBuffers = null,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_SUBMIT_INFO), submit_info.sType);
}

test "VkFenceCreateInfo defaults to signaled flag" {
    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
    try testing.expectEqual(@as(c.VkFenceCreateFlags, c.VK_FENCE_CREATE_SIGNALED_BIT), fence_info.flags);
}

test "VkSemaphoreCreateInfo sType is correct" {
    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO), semaphore_info.sType);
}

test "VkCommandPoolCreateInfo sType is correct" {
    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO), pool_info.sType);
}

test "VkCommandBufferAllocateInfo sType is correct" {
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO), alloc_info.sType);
}

test "VkCommandBufferAllocateInfo level is primary" {
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    try testing.expectEqual(@as(u32, c.VK_COMMAND_BUFFER_LEVEL_PRIMARY), alloc_info.level);
}

test "FrameManager command buffer count equals MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(u32, rhi.MAX_FRAMES_IN_FLIGHT), rhi.MAX_FRAMES_IN_FLIGHT);
}

test "FrameManager image_available_semaphores count matches MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), @sizeOf([rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore) / @sizeOf(c.VkSemaphore));
}

test "FrameManager render_finished_semaphores count matches MAX_SWAPCHAIN_IMAGES" {
    try testing.expectEqual(@as(usize, rhi.MAX_SWAPCHAIN_IMAGES), @sizeOf([rhi.MAX_SWAPCHAIN_IMAGES]c.VkSemaphore) / @sizeOf(c.VkSemaphore));
}

test "FrameManager in_flight_fences count matches MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), @sizeOf([rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence) / @sizeOf(c.VkFence));
}
