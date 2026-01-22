const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi_types = @import("../rhi_types.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const VulkanSwapchain = @import("../vulkan_swapchain.zig").VulkanSwapchain;
const Utils = @import("utils.zig");

pub const SwapchainPresenter = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *VulkanDevice,
    window: *c.SDL_Window,
    swapchain: VulkanSwapchain,

    // Configuration
    vsync_enabled: bool = true,
    msaa_samples: u8 = 1,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },

    // State
    framebuffer_resized: bool = false,

    // Dynamic function pointers for extensions
    fp_vkQueuePresentKHR: c.PFN_vkQueuePresentKHR = null,
    skip_present: bool = false,

    pub fn init(allocator: std.mem.Allocator, vulkan_device: *VulkanDevice, window: *c.SDL_Window, msaa_samples: u8) !SwapchainPresenter {
        const swapchain = try VulkanSwapchain.init(allocator, vulkan_device, window, msaa_samples);

        // Load vkQueuePresentKHR dynamically to avoid linking issues or NULL symbols
        const fp_present = c.vkGetDeviceProcAddr(vulkan_device.vk_device, "vkQueuePresentKHR");
        if (fp_present == null) {
            std.log.err("Failed to load vkQueuePresentKHR function pointer", .{});
            return error.ExtensionNotPresent;
        }

        const build_options = @import("build_options");
        const skip = if (@hasDecl(build_options, "skip_present"))
            (build_options.skip_present or build_options.smoke_test)
        else
            build_options.smoke_test;

        if (skip) std.log.warn("Headless/SmokeTest mode: Skipping vkQueuePresentKHR", .{});

        return SwapchainPresenter{
            .allocator = allocator,
            .vulkan_device = vulkan_device,
            .window = window,
            .swapchain = swapchain,
            .msaa_samples = msaa_samples,
            .fp_vkQueuePresentKHR = @ptrCast(fp_present),
            .skip_present = skip,
        };
    }

    pub fn deinit(self: *SwapchainPresenter) void {
        self.swapchain.deinit();
    }

    pub fn recreate(self: *SwapchainPresenter) !void {
        try self.swapchain.recreate(self.msaa_samples);
        self.framebuffer_resized = false;
    }

    pub fn setVSync(self: *SwapchainPresenter, enabled: bool) void {
        if (self.vsync_enabled != enabled) {
            self.vsync_enabled = enabled;
            // Trigger recreation on next frame via resize flag or immediate
            self.framebuffer_resized = true; // Simple way to force recreation
        }
    }

    pub fn setClearColor(self: *SwapchainPresenter, color: rhi_types.Vec3) void {
        self.clear_color = .{ color.x, color.y, color.z, 1.0 };
    }

    pub fn acquireNextImage(self: *SwapchainPresenter, semaphore: c.VkSemaphore) !u32 {
        var image_index: u32 = 0;
        // Timeout: 2 seconds
        const result = c.vkAcquireNextImageKHR(self.vulkan_device.vk_device, self.swapchain.handle, 2_000_000_000, semaphore, null, &image_index);

        if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            return error.OutOfDate;
        } else if (result == c.VK_TIMEOUT) {
            std.log.err("vkAcquireNextImageKHR timed out (2s). Swapchain exhaustion?", .{});
            return error.Timeout;
        } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            std.log.err("vkAcquireNextImageKHR failed with result: {d}", .{result});
            return error.VulkanError;
        }

        return image_index;
    }

    pub fn present(self: *SwapchainPresenter, wait_semaphore: c.VkSemaphore, image_index: u32) !void {
        if (self.skip_present) {
            std.log.debug("Skipping vkQueuePresentKHR (headless mode)", .{});
            return;
        }

        var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
        present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &wait_semaphore;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain.handle;
        present_info.pImageIndices = &image_index;

        self.vulkan_device.mutex.lock();
        // Use dynamically loaded function pointer
        const result = if (self.fp_vkQueuePresentKHR) |func|
            func(self.vulkan_device.queue, &present_info)
        else
            return error.ExtensionNotPresent;
        self.vulkan_device.mutex.unlock();

        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or self.framebuffer_resized) {
            return error.OutOfDate;
        } else if (result != c.VK_SUCCESS) {
            return error.VulkanError;
        }
    }

    pub fn getExtent(self: *SwapchainPresenter) c.VkExtent2D {
        return self.swapchain.extent;
    }

    pub fn getMainRenderPass(self: *SwapchainPresenter) c.VkRenderPass {
        return self.swapchain.main_render_pass;
    }

    pub fn getCurrentFramebuffer(self: *SwapchainPresenter, image_index: u32) c.VkFramebuffer {
        return self.swapchain.framebuffers.items[image_index];
    }
};
