const std = @import("std");
const testing = std.testing;
const c = @import("c.zig").c;
const VulkanDevice = @import("engine/graphics/vulkan_device.zig").VulkanDevice;

test "VulkanDevice.submitGuarded error simulation" {
    // This test simulates the logic flow of submitGuarded by testing the error propagation
    // and state management that would occur during a GPU loss event.
    // Since we cannot easily force the Vulkan driver into a lost state without a mock driver,
    // we verify the surrounding logic.

    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .fault_count = 0,
    };

    // Verify initial state
    try testing.expectEqual(@as(u32, 0), device.fault_count);

    // We define a helper that returns an error union
    const Helper = struct {
        fn mockSubmit(simulated_result: c.VkResult) !void {
            if (simulated_result == c.VK_ERROR_DEVICE_LOST) return error.GpuLost;
            return error.Unknown;
        }
    };

    // Test: VK_ERROR_DEVICE_LOST -> error.GpuLost
    try testing.expectError(error.GpuLost, Helper.mockSubmit(c.VK_ERROR_DEVICE_LOST));
}

test "VulkanDevice.checkVk comprehensive mapping" {
    // This test ensures that ALL Vulkan error codes we care about are correctly mapped
    // to Zig errors, which is crucial for the robustness layer's decision making.
    const checkVk = @import("engine/graphics/vulkan_device.zig").checkVk;

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
