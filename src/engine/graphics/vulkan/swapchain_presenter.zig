const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi_types = @import("../rhi_types.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const VulkanSwapchain = @import("../vulkan_swapchain.zig").VulkanSwapchain;

pub const SwapchainPresenter = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *const VulkanDevice,
    window: *c.SDL_Window,
    swapchain: VulkanSwapchain,

    // Configuration
    vsync_enabled: bool = true,
    msaa_samples: u8 = 1,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },

    // State
    framebuffer_resized: bool = false,

    pub fn init(allocator: std.mem.Allocator, vulkan_device: *const VulkanDevice, window: *c.SDL_Window, msaa_samples: u8) !SwapchainPresenter {
        const swapchain = try VulkanSwapchain.init(allocator, vulkan_device, window, msaa_samples);
        return SwapchainPresenter{
            .allocator = allocator,
            .vulkan_device = vulkan_device,
            .window = window,
            .swapchain = swapchain,
            .msaa_samples = msaa_samples,
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
        } else if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            return error.VulkanError;
        }

        return image_index;
    }

    pub fn present(self: *SwapchainPresenter, wait_semaphore: c.VkSemaphore, image_index: u32) !void {
        var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
        present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &wait_semaphore;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain.handle;
        present_info.pImageIndices = &image_index;

        const result = c.vkQueuePresentKHR(self.vulkan_device.queue, &present_info);

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
