const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const SwapchainPresenter = @import("swapchain_presenter.zig").SwapchainPresenter;

pub const FrameManager = struct {
    vulkan_device: *VulkanDevice,

    command_pool: c.VkCommandPool,
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,

    image_available_semaphores: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    render_finished_semaphores: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    in_flight_fences: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence,

    current_frame: usize = 0,
    current_image_index: u32 = 0,
    frame_in_progress: bool = false,

    pub fn init(vulkan_device: *VulkanDevice) !FrameManager {
        var self = FrameManager{
            .vulkan_device = vulkan_device,
            .command_pool = null,
            .command_buffers = undefined,
            .image_available_semaphores = undefined,
            .render_finished_semaphores = undefined,
            .in_flight_fences = undefined,
        };

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = vulkan_device.graphics_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try checkVk(c.vkCreateCommandPool(vulkan_device.vk_device, &pool_info, null, &self.command_pool));

        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = rhi.MAX_FRAMES_IN_FLIGHT;
        try checkVk(c.vkAllocateCommandBuffers(vulkan_device.vk_device, &alloc_info, &self.command_buffers));

        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try checkVk(c.vkCreateSemaphore(vulkan_device.vk_device, &semaphore_info, null, &self.image_available_semaphores[i]));
            try checkVk(c.vkCreateSemaphore(vulkan_device.vk_device, &semaphore_info, null, &self.render_finished_semaphores[i]));
            try checkVk(c.vkCreateFence(vulkan_device.vk_device, &fence_info, null, &self.in_flight_fences[i]));
        }

        return self;
    }

    pub fn deinit(self: *FrameManager) void {
        const device = self.vulkan_device.vk_device;
        _ = c.vkDeviceWaitIdle(device);

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            c.vkDestroySemaphore(device, self.render_finished_semaphores[i], null);
            c.vkDestroySemaphore(device, self.image_available_semaphores[i], null);
            c.vkDestroyFence(device, self.in_flight_fences[i], null);
        }

        if (self.command_pool != null) {
            c.vkDestroyCommandPool(device, self.command_pool, null);
        }
    }

    pub fn beginFrame(self: *FrameManager, swapchain: *SwapchainPresenter) !bool {
        if (self.frame_in_progress) return error.InvalidState;

        const device = self.vulkan_device.vk_device;

        // Wait for previous frame
        _ = c.vkWaitForFences(device, 1, &self.in_flight_fences[self.current_frame], c.VK_TRUE, std.math.maxInt(u64));

        // Acquire image
        const result = swapchain.acquireNextImage(self.image_available_semaphores[self.current_frame]);
        if (result) |index| {
            self.current_image_index = index;
        } else |err| {
            if (err == error.OutOfDate) return false; // Needs recreate
            return err;
        }

        // Reset fence
        _ = c.vkResetFences(device, 1, &self.in_flight_fences[self.current_frame]);

        // Begin command buffer
        const cb = self.command_buffers[self.current_frame];
        try checkVk(c.vkResetCommandBuffer(cb, 0));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try checkVk(c.vkBeginCommandBuffer(cb, &begin_info));

        self.frame_in_progress = true;
        return true;
    }

    pub fn endFrame(self: *FrameManager, swapchain: *SwapchainPresenter, transfer_cb: ?c.VkCommandBuffer) !void {
        if (!self.frame_in_progress) return error.InvalidState;

        const cb = self.command_buffers[self.current_frame];
        try checkVk(c.vkEndCommandBuffer(cb));

        // End transfer command buffer if present
        if (transfer_cb) |tcb| {
            try checkVk(c.vkEndCommandBuffer(tcb));
        }

        var wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;

        submit_info.waitSemaphoreCount = 1;
        submit_info.pWaitSemaphores = &self.image_available_semaphores[self.current_frame];
        submit_info.pWaitDstStageMask = &wait_stages[0];

        // Submit transfer buffer first if needed?
        // Actually, if we submit them in the same batch, we can list multiple command buffers.
        // Or if we need strict ordering (transfer before graphics), we can submit twice or use barriers.
        // Since both are on graphics queue, single submit guarantees execution order.

        var command_buffers: [2]c.VkCommandBuffer = undefined;
        var cb_count: u32 = 0;

        if (transfer_cb) |tcb| {
            command_buffers[cb_count] = tcb;
            cb_count += 1;
        }
        command_buffers[cb_count] = cb;
        cb_count += 1;

        submit_info.commandBufferCount = cb_count;
        submit_info.pCommandBuffers = &command_buffers[0];

        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &self.render_finished_semaphores[self.current_frame];

        try self.vulkan_device.submitGuarded(submit_info, self.in_flight_fences[self.current_frame]);

        swapchain.present(self.render_finished_semaphores[self.current_frame], self.current_image_index) catch |err| {
            if (err == error.OutOfDate) {
                // Resize needed, handled by next frame
            } else {
                return err;
            }
        };

        self.current_frame = (self.current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
        self.frame_in_progress = false;
    }

    pub fn abortFrame(self: *FrameManager) void {
        if (!self.frame_in_progress) return;
        // Wait for fence to be safe? No, just reset state.
        // But we might have acquired an image.
        self.frame_in_progress = false;
    }

    pub fn getCurrentCommandBuffer(self: *FrameManager) c.VkCommandBuffer {
        return self.command_buffers[self.current_frame];
    }

    pub fn waitIdle(self: *FrameManager) void {
        _ = c.vkDeviceWaitIdle(self.vulkan_device.vk_device);
    }
};

fn checkVk(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.VulkanError;
}
