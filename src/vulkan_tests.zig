const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const VulkanDevice = @import("engine-graphics").VulkanDevice;

const SubmissionStub = struct {
    result: c.VkResult = c.VK_SUCCESS,
    calls: u32 = 0,
    fault_queries: u32 = 0,
    submit_count: u32 = 0,
    submit_info: c.VkSubmitInfo = std.mem.zeroes(c.VkSubmitInfo),
    fence: c.VkFence = null,

    fn submit(queue: c.VkQueue, count: u32, infos: [*c]const c.VkSubmitInfo, fence: c.VkFence) callconv(.c) c.VkResult {
        const self: *@This() = @ptrCast(@alignCast(queue.?));
        self.calls += 1;
        self.submit_count = count;
        if (count == 1) self.submit_info = infos[0];
        self.fence = fence;
        return self.result;
    }

    fn faultInfo(device: c.VkDevice, _: *c.VkDeviceFaultCountsEXT, _: ?*c.VkDeviceFaultInfoEXT) callconv(.c) c.VkResult {
        const self: *@This() = @ptrCast(@alignCast(device.?));
        self.fault_queries += 1;
        return c.VK_ERROR_UNKNOWN;
    }

    fn makeDevice(self: *@This()) VulkanDevice {
        return .{
            .allocator = testing.allocator,
            // These tokens go exclusively to the stubs, never the Vulkan loader.
            .queue = @ptrCast(self),
            .vk_device = @ptrCast(self),
            .queue_submit_fn = submit,
            .supports_device_fault = true,
            .vkGetDeviceFaultInfoEXT = faultInfo,
        };
    }
};

test "VulkanDevice.submitGuarded forwards the submission and fence to dispatch" {
    var stub = SubmissionStub{};
    var device = stub.makeDevice();
    var command_buffer: c.VkCommandBuffer = @ptrCast(&stub);
    const fence: c.VkFence = @ptrCast(&stub);
    var info = std.mem.zeroes(c.VkSubmitInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    info.commandBufferCount = 1;
    info.pCommandBuffers = &command_buffer;

    try device.submitGuarded(info, fence);

    try testing.expectEqual(@as(u32, 1), stub.calls);
    try testing.expectEqual(@as(u32, 1), stub.submit_count);
    try testing.expectEqual(info.sType, stub.submit_info.sType);
    try testing.expectEqual(info.commandBufferCount, stub.submit_info.commandBufferCount);
    try testing.expectEqual(info.pCommandBuffers, stub.submit_info.pCommandBuffers);
    try testing.expectEqual(fence, stub.fence);
    try testing.expectEqual(@as(u32, 0), stub.fault_queries);
    try testing.expectEqual(@as(u32, 0), device.fault_count);
    try testing.expect(device.mutex.tryLock());
    device.mutex.unlock();
}

test "VulkanDevice.submitGuarded counts injected device loss despite diagnostic failure" {
    var stub = SubmissionStub{ .result = c.VK_ERROR_DEVICE_LOST };
    var device = stub.makeDevice();
    const info = std.mem.zeroes(c.VkSubmitInfo);

    try testing.expectError(error.GpuLost, device.submitGuarded(info, null));
    try testing.expectEqual(@as(u32, 1), stub.calls);
    try testing.expectEqual(@as(u32, 1), stub.fault_queries);
    try testing.expectEqual(@as(u32, 1), device.fault_count);
    try testing.expect(device.mutex.tryLock());
    device.mutex.unlock();

    // The second failure also exercises unlocking on the error return path.
    try testing.expectError(error.GpuLost, device.submitGuarded(info, null));
    try testing.expectEqual(@as(u32, 2), stub.calls);
    try testing.expectEqual(@as(u32, 2), stub.fault_queries);
    try testing.expectEqual(@as(u32, 2), device.fault_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_success_count);

    device.vkGetDeviceFaultInfoEXT = null;
    device.supports_device_fault = false;
    try testing.expectError(error.GpuLost, device.submitGuarded(info, null));
    try testing.expectEqual(@as(u32, 3), stub.calls);
    try testing.expectEqual(@as(u32, 2), stub.fault_queries);
    try testing.expectEqual(@as(u32, 3), device.fault_count);
}

test "VulkanDevice.submitGuarded propagates injected non-device-loss errors without faults" {
    const cases = .{
        .{ c.VK_ERROR_OUT_OF_HOST_MEMORY, error.OutOfMemory },
        .{ c.VK_ERROR_OUT_OF_DEVICE_MEMORY, error.OutOfMemory },
        .{ c.VK_ERROR_INITIALIZATION_FAILED, error.InitializationFailed },
        .{ c.VK_ERROR_UNKNOWN, error.Unknown },
    };
    inline for (cases) |case| {
        var stub = SubmissionStub{ .result = case[0] };
        var device = stub.makeDevice();
        const info = std.mem.zeroes(c.VkSubmitInfo);

        try testing.expectError(case[1], device.submitGuarded(info, null));
        try testing.expectEqual(@as(u32, 1), stub.calls);
        try testing.expectEqual(@as(u32, 0), stub.fault_queries);
        try testing.expectEqual(@as(u32, 0), device.fault_count);
        try testing.expect(device.mutex.tryLock());
        device.mutex.unlock();

        stub.result = c.VK_SUCCESS;
        try device.submitGuarded(info, null);
        try testing.expectEqual(@as(u32, 2), stub.calls);
        try testing.expectEqual(@as(u32, 0), device.fault_count);
    }
}

test "guarded transfer readback rejects corruption in every payload and guard word" {
    const verify = @import("robust_demo.zig").verifyTransferReadback;
    const expected = [_]u32{0xA5A5A5A5} ** 4 ++ [_]u32{0xDEADBEEF} ** 8 ++ [_]u32{0xA5A5A5A5} ** 4;
    try verify(&expected);
    try testing.expectError(error.ReadbackSizeMismatch, verify(expected[0..15]));
    for (0..expected.len) |i| {
        var corrupted = expected;
        corrupted[i] ^= 1;
        try testing.expectError(error.ReadbackMismatch, verify(&corrupted));
    }
}

test "VulkanDevice.checkVk comprehensive mapping" {
    // This test ensures that ALL Vulkan error codes we care about are correctly mapped
    // to Zig errors, which is crucial for the robustness layer's decision making.
    const checkVk = @import("engine-graphics").vulkan_device.checkVk;

    try testing.expectError(error.GpuLost, checkVk(c.VK_ERROR_DEVICE_LOST));
    try testing.expectError(error.OutOfMemory, checkVk(c.VK_ERROR_OUT_OF_HOST_MEMORY));
    try testing.expectError(error.OutOfMemory, checkVk(c.VK_ERROR_OUT_OF_DEVICE_MEMORY));
    try testing.expectError(error.SurfaceLost, checkVk(c.VK_ERROR_SURFACE_LOST_KHR));
    try testing.expectError(error.InitializationFailed, checkVk(c.VK_ERROR_INITIALIZATION_FAILED));
    try testing.expectError(error.ExtensionNotPresent, checkVk(c.VK_ERROR_EXTENSION_NOT_PRESENT));
    try testing.expectError(error.FeatureNotPresent, checkVk(c.VK_ERROR_FEATURE_NOT_PRESENT));
    try testing.expectError(error.TooManyObjects, checkVk(c.VK_ERROR_TOO_MANY_OBJECTS));
    try testing.expectError(error.FormatNotSupported, checkVk(c.VK_ERROR_FORMAT_NOT_SUPPORTED));
    try testing.expectError(error.FragmentedPool, checkVk(c.VK_ERROR_FRAGMENTED_POOL));
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_UNKNOWN));
    try checkVk(c.VK_SUCCESS);
}
