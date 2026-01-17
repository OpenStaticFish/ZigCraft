//! GPU-Proof Vulkan Layer Demo
//!
//! Demonstrates the robustness layer by performing an intentional out-of-bounds
//! buffer access and verifying that the system remains responsive.

const std = @import("std");
const c = @import("c.zig").c;
const VulkanDevice = @import("engine/graphics/vulkan_device.zig").VulkanDevice;

pub fn main() !void {
    std.debug.print("\n=== GPU Robustness Demo ===\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize SDL for Vulkan (minimal)
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("Robustness Demo", 128, 128, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIDDEN);
    if (window == null) return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    // 2. Create Robust Vulkan Device
    std.log.info("Initializing robust Vulkan device...", .{});
    var device = try VulkanDevice.init(allocator, window.?);
    defer device.deinit();

    // 3. Create command pool
    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = device.graphics_family;
    var command_pool: c.VkCommandPool = null;
    _ = c.vkCreateCommandPool(device.vk_device, &pool_info, null, &command_pool);
    defer c.vkDestroyCommandPool(device.vk_device, command_pool, null);

    // 4. Allocate command buffer
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandPool = command_pool;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;
    var cmd: c.VkCommandBuffer = null;
    _ = c.vkAllocateCommandBuffers(device.vk_device, &alloc_info, &cmd);

    // 5. Create a small test buffer (64 bytes)
    const buffer_size: u64 = 64;
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = buffer_size;
    buffer_info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    var buffer: c.VkBuffer = null;
    _ = c.vkCreateBuffer(device.vk_device, &buffer_info, null, &buffer);
    defer c.vkDestroyBuffer(device.vk_device, buffer, null);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device.vk_device, buffer, &mem_reqs);
    const mem_type = try device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    var mem_alloc = std.mem.zeroes(c.VkMemoryAllocateInfo);
    mem_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mem_alloc.allocationSize = mem_reqs.size;
    mem_alloc.memoryTypeIndex = mem_type;
    var memory: c.VkDeviceMemory = null;
    _ = c.vkAllocateMemory(device.vk_device, &mem_alloc, null, &memory);
    defer c.vkFreeMemory(device.vk_device, memory, null);
    _ = c.vkBindBufferMemory(device.vk_device, buffer, memory, 0);

    // 6. Record OOB access
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    _ = c.vkBeginCommandBuffer(cmd, &begin_info);

    const oob_offset: u64 = 1024;
    std.debug.print("Buffer size: {d} bytes, attempting fill at offset {d} (OOB!)\n", .{ buffer_size, oob_offset });
    std.debug.print("Note: With VK_EXT_robustness2, this should be SILENTLY CLAMPED by the driver\n", .{});
    std.debug.print("and should NOT trigger a device loss or system freeze.\n", .{});
    c.vkCmdFillBuffer(cmd, buffer, oob_offset, 64, 0xDEADBEEF);

    _ = c.vkEndCommandBuffer(cmd);

    // 7. Submit via guarded path
    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;

    std.log.info("Submitting via device.submitGuarded()...", .{});
    device.submitGuarded(submit_info, null) catch |err| {
        if (err == error.GpuLost) {
            std.debug.print("\n[EXPECTED] GPU was lost but system is stable.\n", .{});
            return;
        }
        return err;
    };

    _ = c.vkDeviceWaitIdle(device.vk_device);

    if (device.fault_count != 0) {
        std.debug.print("\n[UNEXPECTED] Device was lost! Robustness2 failed to prevent it. Fault count: {d}\n", .{device.fault_count});
        // This is technically a "success" for the safety layer (it caught the crash), but a failure for robustness2.
        // For this demo, we want to prove robustness2 works.
    } else {
        std.debug.print("\n[SUCCESS] Command completed successfully. Robustness2 prevented device loss.\n", .{});
    }
}
