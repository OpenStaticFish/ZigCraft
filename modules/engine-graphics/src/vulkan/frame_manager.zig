const std = @import("std");
const c = @import("c").c;
const build_options = @import("engine_graphics_options");
const log = @import("engine-core").log;
const rhi = @import("engine-rhi").rhi;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");

pub const DRY_RUN_ACTIVE = if (@hasDecl(build_options, "skip_present")) build_options.skip_present else false;

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
    terminal_failure: bool = false,
    dry_run: bool = false,
    wait_for_fences_fn: *const fn (c.VkDevice, u32, [*c]const c.VkFence, c.VkBool32, u64) callconv(.c) c.VkResult = c.vkWaitForFences,
    reset_fences_fn: *const fn (c.VkDevice, u32, [*c]const c.VkFence) callconv(.c) c.VkResult = c.vkResetFences,
    reset_command_pool_fn: *const fn (c.VkDevice, c.VkCommandPool, c.VkCommandPoolResetFlags) callconv(.c) c.VkResult = c.vkResetCommandPool,
    begin_command_buffer_fn: *const fn (c.VkCommandBuffer, [*c]const c.VkCommandBufferBeginInfo) callconv(.c) c.VkResult = c.vkBeginCommandBuffer,
    end_command_buffer_fn: *const fn (c.VkCommandBuffer) callconv(.c) c.VkResult = c.vkEndCommandBuffer,

    pub fn init(vulkan_device: *VulkanDevice) !FrameManager {
        var self = FrameManager{
            .vulkan_device = vulkan_device,
            .command_pool = null,
            .frame_command_pools = [_]c.VkCommandPool{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
            .command_buffers = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
            .image_available_semaphores = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
            .render_finished_semaphores = .{null} ** rhi.MAX_SWAPCHAIN_IMAGES,
            .in_flight_fences = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
            .dry_run = DRY_RUN_ACTIVE,
        };
        errdefer self.deinit();

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

    pub fn beginFrame(self: *FrameManager, swapchain: anytype) !bool {
        if (self.terminal_failure) return error.GpuLost;
        if (self.frame_in_progress) return error.InvalidState;
        errdefer self.failFrame();

        const device = self.vulkan_device.vk_device;

        // Wait for previous frame before reusing the command buffer.
        try Utils.checkVk(self.wait_for_fences_fn(device, 1, &self.in_flight_fences[self.current_frame], c.VK_TRUE, std.math.maxInt(u64)));

        // Acquire image
        if (self.dry_run) {
            // In dry-run/headless mode, we skip image acquisition to avoid WSI/driver crashes.
            // We just use image 0 as our target.
            self.current_image_index = 0;
        } else {
            const result = swapchain.acquireNextImage(self.image_available_semaphores[self.current_frame]);
            if (result) |index| {
                self.current_image_index = index;
            } else |err| {
                if (err == error.OutOfDate) {
                    swapchain.framebuffer_resized = true;
                    // No image was acquired and the fence is still signaled.
                    // Return a skipped frame, not a quarantined/reset slot.
                    return false;
                } else if (err == error.ValidationFailed) {
                    log.log.err("beginFrame: validation failure while acquiring swapchain image", .{});
                    return err;
                }
                return err;
            }
        }

        // Reset fence before submitting the next frame.
        try Utils.checkVk(self.reset_fences_fn(device, 1, &self.in_flight_fences[self.current_frame]));

        // Reset the per-frame pool after its fence signals. This lets the driver
        // recycle all transient command-buffer storage for the frame at once.
        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(self.reset_command_pool_fn(device, self.frame_command_pools[self.current_frame], 0));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        try Utils.checkVk(self.begin_command_buffer_fn(cb, &begin_info));

        self.frame_in_progress = true;
        return true;
    }

    pub fn endFrame(self: *FrameManager, swapchain: anytype, transfer_cb: ?c.VkCommandBuffer, transfer_semaphore: ?c.VkSemaphore) !void {
        if (self.terminal_failure) return error.GpuLost;
        if (!self.frame_in_progress) return error.InvalidState;
        errdefer self.failFrame();

        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(self.end_command_buffer_fn(cb));

        // Shared-queue uploads are submitted with graphics, so this CB is ended here.
        // Dedicated-queue uploads are ended in submitTransfer() before the separate submit.
        if (transfer_semaphore == null) {
            if (transfer_cb) |tcb| {
                try Utils.checkVk(self.end_command_buffer_fn(tcb));
            }
        }

        var wait_semaphores: [2]c.VkSemaphore = .{ null, null };
        var wait_stages: [2]c.VkPipelineStageFlags = .{
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        };
        var wait_count: u32 = 0;

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;

        if (!swapchain.skip_present) {
            wait_semaphores[wait_count] = self.image_available_semaphores[self.current_frame];
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

        try self.vulkan_device.submitGuarded(submit_info, self.in_flight_fences[self.current_frame]);

        if (!swapchain.skip_present) {
            swapchain.present(self.render_finished_semaphores[self.current_image_index], self.current_image_index) catch |err| {
                if (err == error.OutOfDate) {
                    swapchain.framebuffer_resized = true;
                } else if (err == error.ValidationFailed) {
                    log.log.err("endFrame: validation failure while presenting swapchain image", .{});
                    return err;
                } else {
                    return err;
                }
            };
        }

        self.frame_in_progress = false;
        self.current_frame = (self.current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    }

    /// Failed starts can leave an unsignaled fence; failed submits/presents can
    /// leave pending work. Quarantine the slot without touching its GPU state.
    pub fn failFrame(self: *FrameManager) void {
        self.terminal_failure = true;
        self.frame_in_progress = false;
    }

    pub fn abortFrame(self: *FrameManager) void {
        if (self.terminal_failure or !self.frame_in_progress) return;
        const frame = self.current_frame;
        const device = self.vulkan_device.vk_device;

        // Discard every recorded reference before world/session teardown can
        // release its buffers. This command pool belongs exclusively to the
        // current frame slot, whose fence was waited before beginFrame.
        const reset_result = self.reset_command_pool_fn(device, self.frame_command_pools[frame], 0);
        if (reset_result != c.VK_SUCCESS) {
            log.log.err("Failed to reset aborted graphics command pool: {d}", .{reset_result});
            self.failFrame();
            return;
        }

        // beginFrame reset this fence, but an aborted frame has no graphics
        // submission to signal it. Queue an empty submission so this slot can
        // be reused without destroying/recreating synchronization objects.
        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        self.vulkan_device.submitGuarded(submit_info, self.in_flight_fences[frame]) catch |err| {
            log.log.errWithTrace("Failed to retire aborted frame slot: {}", .{err});
            self.failFrame();
            return;
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
