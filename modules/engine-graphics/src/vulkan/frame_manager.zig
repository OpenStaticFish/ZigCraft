const std = @import("std");
const c = @import("c").c;
const log = @import("engine-core").log;
const rhi = @import("engine-rhi").rhi;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const SwapchainPresenter = @import("swapchain_presenter.zig").SwapchainPresenter;
const Utils = @import("utils.zig");

pub const FrameManager = struct {
    vulkan_device: *VulkanDevice,

    command_pool: c.VkCommandPool,
    frame_command_pools: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandPool,
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,

    image_available_semaphores: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    render_finished_semaphores: [rhi.MAX_SWAPCHAIN_IMAGES]c.VkSemaphore,
    in_flight_fences: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence,

    current_frame: usize = 0,
    current_image_index: u32 = 0,
    frame_in_progress: bool = false,
    retirement_error: ?anyerror = null,
    submit_frame: *const fn (*VulkanDevice, c.VkSubmitInfo, c.VkFence) anyerror!void = &VulkanDevice.submitGuarded,

    pub fn init(vulkan_device: *VulkanDevice) !FrameManager {
        var self = FrameManager{
            .vulkan_device = vulkan_device,
            .command_pool = null,
            .frame_command_pools = [_]c.VkCommandPool{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
            .command_buffers = undefined,
            .image_available_semaphores = undefined,
            .render_finished_semaphores = undefined,
            .in_flight_fences = undefined,
        };

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = vulkan_device.graphics_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try Utils.checkVk(c.vkCreateCommandPool(vulkan_device.vk_device, &pool_info, null, &self.command_pool));

        var frame_pool_info = pool_info;
        frame_pool_info.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try Utils.checkVk(c.vkCreateCommandPool(vulkan_device.vk_device, &frame_pool_info, null, &self.frame_command_pools[i]));

            var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            alloc_info.commandPool = self.frame_command_pools[i];
            alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            alloc_info.commandBufferCount = 1;
            try Utils.checkVk(c.vkAllocateCommandBuffers(vulkan_device.vk_device, &alloc_info, &self.command_buffers[i]));
        }

        var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try Utils.checkVk(c.vkCreateSemaphore(vulkan_device.vk_device, &semaphore_info, null, &self.image_available_semaphores[i]));
            try Utils.checkVk(c.vkCreateFence(vulkan_device.vk_device, &fence_info, null, &self.in_flight_fences[i]));
        }

        for (0..rhi.MAX_SWAPCHAIN_IMAGES) |i| {
            try Utils.checkVk(c.vkCreateSemaphore(vulkan_device.vk_device, &semaphore_info, null, &self.render_finished_semaphores[i]));
        }

        return self;
    }

    pub fn deinit(self: *FrameManager) void {
        const device = self.vulkan_device.vk_device;
        _ = c.vkDeviceWaitIdle(device);

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            c.vkDestroySemaphore(device, self.image_available_semaphores[i], null);
            c.vkDestroyFence(device, self.in_flight_fences[i], null);
        }

        for (0..rhi.MAX_SWAPCHAIN_IMAGES) |i| {
            c.vkDestroySemaphore(device, self.render_finished_semaphores[i], null);
        }

        if (self.command_pool != null) {
            c.vkDestroyCommandPool(device, self.command_pool, null);
        }
        for (self.frame_command_pools) |pool| {
            if (pool != null) c.vkDestroyCommandPool(device, pool, null);
        }
    }

    pub fn beginFrame(self: *FrameManager, swapchain: *SwapchainPresenter) !bool {
        if (self.frame_in_progress) return error.InvalidState;

        const device = self.vulkan_device.vk_device;

        // Wait for previous frame before reusing the command buffer.
        try Utils.checkVk(c.vkWaitForFences(device, 1, &self.in_flight_fences[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));

        // Complete fallible command-buffer setup before acquiring a WSI
        // image. A failed setup must not leave an outstanding acquire signal.
        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkResetCommandPool(device, self.frame_command_pools[self.current_frame], 0));
        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try Utils.checkVk(c.vkBeginCommandBuffer(cb, &begin_info));

        // Acquire image
        if (swapchain.skip_present) {
            // The offscreen target is a regular Vulkan image and needs no acquisition.
            self.current_image_index = 0;
        } else {
            const result = swapchain.acquireNextImage(self.image_available_semaphores[self.current_frame]);
            if (result) |index| {
                self.current_image_index = index;
            } else |err| {
                if (err == error.OutOfDate) {
                    swapchain.framebuffer_resized = true;
                    return false;
                } else if (err == error.Timeout) {
                    // The frame slot is reusable even when no image arrived.
                    // Let the caller switch uploads to the slot we just waited on.
                    return false;
                } else if (err == error.ValidationFailed) {
                    log.log.err("beginFrame: validation failure while acquiring swapchain image", .{});
                    return err;
                }
                return err;
            }
        }

        swapchain.recordInitialLayout(cb, self.current_image_index);

        self.frame_in_progress = true;
        return true;
    }

    pub fn endFrame(self: *FrameManager, swapchain: *SwapchainPresenter, transfer_cb: ?c.VkCommandBuffer, transfer_semaphore: ?c.VkSemaphore) anyerror!void {
        if (!self.frame_in_progress) return error.InvalidState;
        defer self.frame_in_progress = false;
        const cb = self.command_buffers[self.current_frame];
        Utils.checkVk(c.vkEndCommandBuffer(cb)) catch |err| return self.failRetirement(err);

        // Shared-queue uploads are submitted with graphics, so this CB is ended here.
        // Dedicated-queue uploads are ended in submitTransfer() before the separate submit.
        if (transfer_semaphore == null) {
            if (transfer_cb) |tcb| {
                Utils.checkVk(c.vkEndCommandBuffer(tcb)) catch |err| return self.failRetirement(err);
            }
        }

        var wait_semaphores: [2]c.VkSemaphore = .{ null, null };
        var wait_stages: [2]c.VkPipelineStageFlags = undefined;
        var wait_count: u32 = 0;

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;

        if (!swapchain.skip_present) {
            wait_semaphores[wait_count] = self.image_available_semaphores[self.current_frame];
            wait_stages[wait_count] = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            wait_count += 1;
        }

        // For dedicated transfer queue, transfer runs on its own queue and signals a semaphore
        // that the graphics queue waits on. The transfer CB is NOT included in the graphics submit.
        // For shared queue, both CBs go in the same submit.
        var command_buffers: [2]c.VkCommandBuffer = undefined;
        var cb_count: u32 = 0;

        if (transfer_semaphore == null and transfer_cb != null) {
            command_buffers[cb_count] = transfer_cb.?;
            cb_count += 1;
        }

        command_buffers[cb_count] = cb;
        cb_count += 1;

        submit_info.commandBufferCount = cb_count;
        submit_info.pCommandBuffers = &command_buffers[0];

        if (transfer_semaphore) |sem| {
            wait_semaphores[wait_count] = sem;
            wait_stages[wait_count] = c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
            wait_count += 1;
        }

        if (wait_count > 0) {
            submit_info.waitSemaphoreCount = wait_count;
            submit_info.pWaitSemaphores = &wait_semaphores[0];
            submit_info.pWaitDstStageMask = &wait_stages[0];
        }

        if (!swapchain.skip_present) {
            submit_info.signalSemaphoreCount = 1;
            submit_info.pSignalSemaphores = &self.render_finished_semaphores[self.current_image_index];
        }

        self.submitFrame(submit_info) catch |err| return self.failRetirement(err);
        self.current_frame = (self.current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    }

    pub fn presentFrame(self: *FrameManager, swapchain: *SwapchainPresenter) !void {
        if (swapchain.skip_present) return;
        swapchain.initialized_images[self.current_image_index] = true;
        swapchain.present(self.render_finished_semaphores[self.current_image_index], self.current_image_index) catch |err| {
            swapchain.framebuffer_resized = true;
            if (err != error.OutOfDate) return err;
        };
    }

    fn failRetirement(self: *FrameManager, err: anyerror) anyerror!void {
        self.retirement_error = err;
        return err;
    }

    fn submitFrame(self: *FrameManager, info: c.VkSubmitInfo) !void {
        const fence = &self.in_flight_fences[self.current_frame];
        try Utils.checkVk(c.vkResetFences(self.vulkan_device.vk_device, 1, fence));
        try self.submit_frame(self.vulkan_device, info, fence.*);
    }

    pub fn abortFrame(self: *FrameManager, swapchain: *SwapchainPresenter) void {
        if (!self.frame_in_progress) return;
        const frame = self.current_frame;
        const device = self.vulkan_device.vk_device;

        // Discard every recorded reference before world/session teardown can
        // release its buffers. This command pool belongs exclusively to the
        // current frame slot, whose fence was waited before beginFrame.
        const reset_result = c.vkResetCommandPool(device, self.frame_command_pools[frame], 0);
        if (reset_result != c.VK_SUCCESS) {
            log.log.err("Failed to reset aborted graphics command pool: {d}", .{reset_result});
        }

        // Retire the frame slot and consume the acquire signal, if any.
        // Recreate the WSI swapchain before another acquire: the discarded
        // commands did not make the acquired image ready for presentation.
        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
        if (!swapchain.skip_present) {
            submit_info.waitSemaphoreCount = 1;
            submit_info.pWaitSemaphores = &self.image_available_semaphores[frame];
            submit_info.pWaitDstStageMask = &wait_stage;
            swapchain.framebuffer_resized = true;
        }
        self.submitFrame(submit_info) catch |err| {
            log.log.errWithTrace("Failed to retire aborted frame slot: {}", .{err});
            self.retirement_error = err;
        };
        self.frame_in_progress = false;
    }

    pub fn getCurrentCommandBuffer(self: *FrameManager) c.VkCommandBuffer {
        return self.command_buffers[self.current_frame];
    }

    pub fn waitIdle(self: *FrameManager) void {
        _ = c.vkDeviceWaitIdle(self.vulkan_device.vk_device);
    }
};
