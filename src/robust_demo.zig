//! Bounded guarded-submission transfer/readback smoke test.
//! This uses only in-bounds transfers, not shader OOB accesses. It does not
//! verify robustness2 protection, GPU recovery, or immunity to driver hangs.

const std = @import("std");
const c = @import("c").c;
const VulkanDevice = @import("engine-graphics").VulkanDevice;
const checkVk = @import("engine-graphics").vulkan_device.checkVk;

const word_count = 16;
const guard_word: u32 = 0xA5A5A5A5;
const fill_word: u32 = 0xDEADBEEF;

pub fn main() !void {
    std.debug.print("\n=== Guarded Transfer/Readback Smoke ===\n", .{});
    std.debug.print("In-bounds transfer only; shader robustness2 protection is NOT tested.\n", .{});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("Guarded Transfer Smoke", 128, 128, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIDDEN);
    if (window == null) return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    var device = try VulkanDevice.init(allocator, window.?);
    defer device.deinit();
    device.initDebugMessenger();
    if (std.debug.runtime_safety and (!device.validation_layers_enabled or device.debug_messenger == null)) {
        return error.ValidationUnavailable;
    }
    std.debug.print("robustBufferAccess2 enabled: {}; validation active: {}\n", .{
        device.robust_buffer_access2_enabled,
        device.validation_layers_enabled and device.debug_messenger != null,
    });

    try verifyTransfer(&device);
    if (device.fault_count != 0) return error.GpuLost;
    // Include resource/device teardown in the validation check. deinit is idempotent.
    device.deinit();
    if (device.validation_error_count.load(.monotonic) != 0) return error.ValidationFailed;

    std.debug.print("[PASS] Guarded transfer completed; all 16 readback words and guard regions match.\n", .{});
}

fn verifyTransfer(device: *VulkanDevice) !void {
    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = device.graphics_family;
    var command_pool: c.VkCommandPool = null;
    try checkVk(c.vkCreateCommandPool(device.vk_device, &pool_info, null, &command_pool));
    defer c.vkDestroyCommandPool(device.vk_device, command_pool, null);

    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandPool = command_pool;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;
    var cmd: c.VkCommandBuffer = null;
    try checkVk(c.vkAllocateCommandBuffers(device.vk_device, &alloc_info, &cmd));

    const buffer_size: c.VkDeviceSize = word_count * @sizeOf(u32);
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = buffer_size;
    buffer_info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    var buffer: c.VkBuffer = null;
    try checkVk(c.vkCreateBuffer(device.vk_device, &buffer_info, null, &buffer));
    var memory: c.VkDeviceMemory = null;
    defer {
        c.vkDestroyBuffer(device.vk_device, buffer, null);
        if (memory != null) c.vkFreeMemory(device.vk_device, memory, null);
    }

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device.vk_device, buffer, &mem_reqs);
    const mem_type = try device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

    var mem_alloc = std.mem.zeroes(c.VkMemoryAllocateInfo);
    mem_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    mem_alloc.allocationSize = mem_reqs.size;
    mem_alloc.memoryTypeIndex = mem_type;
    var allocated_memory: c.VkDeviceMemory = null;
    try checkVk(c.vkAllocateMemory(device.vk_device, &mem_alloc, null, &allocated_memory));
    memory = allocated_memory;
    try checkVk(c.vkBindBufferMemory(device.vk_device, buffer, memory, 0));

    var mapped: ?*anyopaque = null;
    try checkVk(c.vkMapMemory(device.vk_device, memory, 0, buffer_size, 0, &mapped));
    defer c.vkUnmapMemory(device.vk_device, memory);
    const words: [*]u32 = @ptrCast(@alignCast(mapped orelse return error.MappingFailed));
    @memset(words[0..word_count], guard_word);

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

    // Fill the middle eight words, preserving four guard words at each end.
    c.vkCmdFillBuffer(cmd, buffer, 4 * @sizeOf(u32), 8 * @sizeOf(u32), fill_word);

    var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = buffer;
    barrier.size = buffer_size;
    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &barrier, 0, null);
    try checkVk(c.vkEndCommandBuffer(cmd));

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    var fence: c.VkFence = null;
    try checkVk(c.vkCreateFence(device.vk_device, &fence_info, null, &fence));
    defer c.vkDestroyFence(device.vk_device, fence, null);

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;

    device.submitGuarded(submit_info, fence) catch |err| {
        std.debug.print("[FAIL] Guarded submission failed: {s}\n", .{@errorName(err)});
        // Do not destroy potentially pending resources after submission failure.
        // This isolated test process exits nonzero; the OS reclaims its resources.
        std.process.exit(1);
    };

    const wait_result = c.vkWaitForFences(device.vk_device, 1, &fence, c.VK_TRUE, 5 * std.time.ns_per_s);
    if (wait_result != c.VK_SUCCESS) {
        std.debug.print("[FAIL] Fence did not complete within 5 seconds: VkResult={d}\n", .{wait_result});
        // A timeout does not retire GPU work. Bypass deferred Vulkan destruction
        // rather than freeing resources still in use or waiting indefinitely.
        std.process.exit(1);
    }
    try checkVk(c.vkGetFenceStatus(device.vk_device, fence));
    // HOST_COHERENT memory needs no invalidate after the barrier and fence wait.
    try verifyTransferReadback(words[0..word_count]);
}

pub fn verifyTransferReadback(words: []const u32) !void {
    if (words.len != word_count) return error.ReadbackSizeMismatch;
    for (words, 0..) |actual, i| {
        const expected = if (i >= 4 and i < 12) fill_word else guard_word;
        if (actual != expected) return error.ReadbackMismatch;
    }
}
