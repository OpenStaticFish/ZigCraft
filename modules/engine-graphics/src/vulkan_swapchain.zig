const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const VulkanDevice = @import("vulkan_device.zig").VulkanDevice;
const log = @import("engine-core").log;

pub const VulkanSwapchain = struct {
    device: *const VulkanDevice,
    window: *c.SDL_Window,
    allocator: std.mem.Allocator,

    handle: c.VkSwapchainKHR = null,
    image_format: c.VkFormat = undefined,
    extent: c.VkExtent2D = undefined,
    images: std.ArrayListUnmanaged(c.VkImage) = .empty,
    image_views: std.ArrayListUnmanaged(c.VkImageView) = .empty,
    framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    main_render_pass: c.VkRenderPass = null,

    depth_image: c.VkImage = null,
    depth_image_memory: c.VkDeviceMemory = null,
    depth_image_view: c.VkImageView = null,

    // MSAA resources
    msaa_color_image: c.VkImage = null,
    msaa_color_memory: c.VkDeviceMemory = null,
    msaa_color_view: c.VkImageView = null,

    // Headless mode
    headless_mode: bool = false,
    headless_image: c.VkImage = null,
    headless_memory: c.VkDeviceMemory = null,
    screenshot_capture_supported: bool = false,

    // Resolution scaling
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    scale: f32 = 1.0,

    // Present mode requested by the app; honored at createSwapchain() time.
    // Defaults to FIFO (VSync ON) which is guaranteed by the Vulkan spec.
    present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR,

    pub fn init(allocator: std.mem.Allocator, device: *const VulkanDevice, window: *c.SDL_Window, msaa_samples: u8, present_mode: c.VkPresentModeKHR) !VulkanSwapchain {
        const build_options = @import("engine_graphics_options");
        const headless = if (@hasDecl(build_options, "skip_present")) build_options.skip_present else false;

        var self = VulkanSwapchain{
            .allocator = allocator,
            .device = device,
            .window = window,
            .headless_mode = headless,
            .present_mode = present_mode,
        };
        errdefer self.deinit();
        try self.create(msaa_samples);
        return self;
    }

    pub fn deinit(self: *VulkanSwapchain) void {
        self.cleanup();
        self.images.deinit(self.allocator);
        self.image_views.deinit(self.allocator);
        self.framebuffers.deinit(self.allocator);
    }

    fn cleanup(self: *VulkanSwapchain) void {
        const vk = self.device.vk_device;
        for (self.framebuffers.items) |fb| c.vkDestroyFramebuffer(vk, fb, null);
        self.framebuffers.clearRetainingCapacity();

        if (self.main_render_pass != null) {
            c.vkDestroyRenderPass(vk, self.main_render_pass, null);
            self.main_render_pass = null;
        }

        for (self.image_views.items) |iv| c.vkDestroyImageView(vk, iv, null);
        self.image_views.clearRetainingCapacity();

        if (self.handle != null) {
            c.vkDestroySwapchainKHR(vk, self.handle, null);
            self.handle = null;
        }

        if (self.depth_image_view != null) c.vkDestroyImageView(vk, self.depth_image_view, null);
        if (self.depth_image != null) c.vkDestroyImage(vk, self.depth_image, null);
        if (self.depth_image_memory != null) c.vkFreeMemory(vk, self.depth_image_memory, null);
        self.depth_image_view = null;
        self.depth_image = null;
        self.depth_image_memory = null;

        if (self.msaa_color_view != null) c.vkDestroyImageView(vk, self.msaa_color_view, null);
        if (self.msaa_color_image != null) c.vkDestroyImage(vk, self.msaa_color_image, null);
        if (self.msaa_color_memory != null) c.vkFreeMemory(vk, self.msaa_color_memory, null);
        self.msaa_color_view = null;
        self.msaa_color_image = null;
        self.msaa_color_memory = null;

        if (self.headless_image != null) c.vkDestroyImage(vk, self.headless_image, null);
        if (self.headless_memory != null) c.vkFreeMemory(vk, self.headless_memory, null);
        self.headless_image = null;
        self.headless_memory = null;

        // These are non-owning image handles. Keeping them after destroying a
        // headless image leaves index zero pointing at freed Vulkan memory on
        // the next recreate, while the freshly-created framebuffer points at
        // the newly appended image. In particular, readback must never select
        // an image from the previous swapchain generation.
        self.clearImageTrackingForRecreate();
    }

    pub fn recreate(self: *VulkanSwapchain, msaa_samples: u8) !void {
        _ = c.vkDeviceWaitIdle(self.device.vk_device);
        self.cleanup();
        try self.create(msaa_samples);
    }

    fn create(self: *VulkanSwapchain, msaa_samples: u8) !void {
        errdefer self.cleanup();
        try self.createSwapchain();
        try self.createDepthBuffer(msaa_samples);
        try self.createMSAAResources(msaa_samples);
        try self.createRenderPass(msaa_samples);
        try self.createFramebuffers(msaa_samples);
    }

    fn createSwapchain(self: *VulkanSwapchain) !void {
        var w: c_int = 0;
        var h: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(self.window, &w, &h)) return error.BackendError;
        var lw: c_int = 0;
        var lh: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &lw, &lh)) return error.BackendError;
        try self.setDrawableSize(w, h, lw, lh);

        if (self.headless_mode) {
            try self.images.ensureUnusedCapacity(self.allocator, 1);
            try self.image_views.ensureUnusedCapacity(self.allocator, 1);
            log.log.info("VulkanSwapchain: Initializing in HEADLESS mode (offscreen)", .{});
            self.image_format = c.VK_FORMAT_B8G8R8A8_UNORM;
            self.screenshot_capture_supported = true;
            log.log.info("VulkanSwapchain: offscreen drawable {}x{} (logical {}x{}, scale {d})", .{ self.extent.width, self.extent.height, self.logical_width, self.logical_height, self.scale });

            var image_info = std.mem.zeroes(c.VkImageCreateInfo);
            image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            image_info.imageType = c.VK_IMAGE_TYPE_2D;
            image_info.extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 };
            image_info.mipLevels = 1;
            image_info.arrayLayers = 1;
            image_info.format = self.image_format;
            image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
            image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
            image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
            image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

            try checkVk(c.vkCreateImage(self.device.vk_device, &image_info, null, &self.headless_image));

            var mem_reqs: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(self.device.vk_device, self.headless_image, &mem_reqs);
            var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            alloc_info.allocationSize = mem_reqs.size;
            alloc_info.memoryTypeIndex = try self.device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            try checkVk(c.vkAllocateMemory(self.device.vk_device, &alloc_info, null, &self.headless_memory));
            try checkVk(c.vkBindImageMemory(self.device.vk_device, self.headless_image, self.headless_memory, 0));

            self.images.appendAssumeCapacity(self.headless_image);

            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = self.headless_image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = self.image_format;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            var view: c.VkImageView = null;
            try checkVk(c.vkCreateImageView(self.device.vk_device, &view_info, null, &view));
            self.image_views.appendAssumeCapacity(view);
            return;
        }

        var cap: c.VkSurfaceCapabilitiesKHR = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.device.physical_device, self.device.surface, &cap);

        var format_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.device.physical_device, self.device.surface, &format_count, null);
        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.device.physical_device, self.device.surface, &format_count, formats.ptr);

        var surface_format = formats[0];
        for (formats) |f| {
            if (f.format == c.VK_FORMAT_B8G8R8A8_SRGB and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                surface_format = f;
                break;
            }
        }
        if (surface_format.format != c.VK_FORMAT_B8G8R8A8_SRGB) {
            for (formats) |f| {
                if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    surface_format = f;
                    break;
                }
            }
        }
        self.image_format = surface_format.format;

        if (cap.currentExtent.width != 0xFFFFFFFF) {
            self.extent = cap.currentExtent;
        } else {
            self.extent = .{ .width = @intCast(w), .height = @intCast(h) };
            self.extent.width = std.math.clamp(self.extent.width, cap.minImageExtent.width, cap.maxImageExtent.width);
            self.extent.height = std.math.clamp(self.extent.height, cap.minImageExtent.height, cap.maxImageExtent.height);
        }

        // Final validation - extent must be non-zero
        if (self.extent.width == 0 or self.extent.height == 0) {
            return error.BackendError;
        }

        var swapchain_info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        swapchain_info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        swapchain_info.surface = self.device.surface;
        swapchain_info.minImageCount = cap.minImageCount + 1;
        if (cap.maxImageCount > 0 and swapchain_info.minImageCount > cap.maxImageCount) swapchain_info.minImageCount = cap.maxImageCount;
        swapchain_info.imageFormat = self.image_format;
        swapchain_info.imageColorSpace = surface_format.colorSpace;
        swapchain_info.imageExtent = self.extent;
        swapchain_info.imageArrayLayers = 1;
        self.screenshot_capture_supported = (cap.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;
        swapchain_info.imageUsage = @as(u32, @intCast(c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)) |
            (if (self.screenshot_capture_supported) @as(u32, @intCast(c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT)) else 0);
        swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        swapchain_info.preTransform = cap.currentTransform;
        // Select a supported composite alpha mode (prefer opaque, but fall back if unsupported)
        swapchain_info.compositeAlpha = blk: {
            const preferred = [_]c.VkCompositeAlphaFlagBitsKHR{
                c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
                c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
                c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
                c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
            };
            for (preferred) |alpha| {
                if ((cap.supportedCompositeAlpha & alpha) != 0) {
                    break :blk alpha;
                }
            }
            // Fallback (shouldn't happen, but be safe)
            break :blk c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        };
        swapchain_info.presentMode = self.selectPresentMode();
        swapchain_info.clipped = c.VK_TRUE;
        try checkVk(c.vkCreateSwapchainKHR(self.device.vk_device, &swapchain_info, null, &self.handle));

        var image_count: u32 = 0;
        try checkVk(c.vkGetSwapchainImagesKHR(self.device.vk_device, self.handle, &image_count, null));
        try self.images.resize(self.allocator, image_count);
        try checkVk(c.vkGetSwapchainImagesKHR(self.device.vk_device, self.handle, &image_count, self.images.items.ptr));
        self.images.items.len = image_count;
        try self.image_views.ensureUnusedCapacity(self.allocator, self.images.items.len);

        for (self.images.items) |image| {
            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = self.image_format;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            var view: c.VkImageView = null;
            try checkVk(c.vkCreateImageView(self.device.vk_device, &view_info, null, &view));
            self.image_views.appendAssumeCapacity(view);
        }
    }

    fn clearImageTrackingForRecreate(self: *VulkanSwapchain) void {
        self.images.clearRetainingCapacity();
    }

    fn setDrawableSize(self: *VulkanSwapchain, w: c_int, h: c_int, lw: c_int, lh: c_int) !void {
        // Wayland transitions can temporarily report an unusable drawable.
        // Validate before signed-to-unsigned casts or allocating either target.
        if (w <= 0 or h <= 0 or lw <= 0 or lh <= 0) return error.BackendError;
        self.pixel_width = @intCast(w);
        self.pixel_height = @intCast(h);
        self.logical_width = @intCast(lw);
        self.logical_height = @intCast(lh);
        self.scale = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(lw));
        self.extent = .{ .width = self.pixel_width, .height = self.pixel_height };
    }

    fn createDepthBuffer(self: *VulkanSwapchain, msaa_samples: u8) !void {
        const depth_format = c.VK_FORMAT_D32_SFLOAT;
        var depth_image_info = std.mem.zeroes(c.VkImageCreateInfo);
        depth_image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        depth_image_info.imageType = c.VK_IMAGE_TYPE_2D;
        depth_image_info.extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 };
        depth_image_info.mipLevels = 1;
        depth_image_info.arrayLayers = 1;
        depth_image_info.format = depth_format;
        depth_image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        depth_image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_image_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        depth_image_info.samples = getMSAASampleCountFlag(msaa_samples);
        depth_image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try checkVk(c.vkCreateImage(self.device.vk_device, &depth_image_info, null, &self.depth_image));

        var depth_mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device.vk_device, self.depth_image, &depth_mem_reqs);
        var depth_alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        depth_alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        depth_alloc_info.allocationSize = depth_mem_reqs.size;
        depth_alloc_info.memoryTypeIndex = try self.device.findMemoryType(depth_mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try checkVk(c.vkAllocateMemory(self.device.vk_device, &depth_alloc_info, null, &self.depth_image_memory));
        try checkVk(c.vkBindImageMemory(self.device.vk_device, self.depth_image, self.depth_image_memory, 0));

        var depth_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        depth_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        depth_view_info.image = self.depth_image;
        depth_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        depth_view_info.format = depth_format;
        depth_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try checkVk(c.vkCreateImageView(self.device.vk_device, &depth_view_info, null, &self.depth_image_view));
    }

    fn createMSAAResources(self: *VulkanSwapchain, msaa_samples: u8) !void {
        if (msaa_samples <= 1) return;

        const sample_count = getMSAASampleCountFlag(msaa_samples);

        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.extent.width = self.extent.width;
        image_info.extent.height = self.extent.height;
        image_info.extent.depth = 1;
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.format = self.image_format;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        image_info.usage = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        image_info.samples = sample_count;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try checkVk(c.vkCreateImage(self.device.vk_device, &image_info, null, &self.msaa_color_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device.vk_device, self.msaa_color_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = self.device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT | c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) catch
            try self.device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try checkVk(c.vkAllocateMemory(self.device.vk_device, &alloc_info, null, &self.msaa_color_memory));
        try checkVk(c.vkBindImageMemory(self.device.vk_device, self.msaa_color_image, self.msaa_color_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.msaa_color_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = self.image_format;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.baseMipLevel = 0;
        view_info.subresourceRange.levelCount = 1;
        view_info.subresourceRange.baseArrayLayer = 0;
        view_info.subresourceRange.layerCount = 1;

        try checkVk(c.vkCreateImageView(self.device.vk_device, &view_info, null, &self.msaa_color_view));
    }

    fn createRenderPass(self: *VulkanSwapchain, msaa_samples: u8) !void {
        const sample_count = getMSAASampleCountFlag(msaa_samples);
        const use_msaa = msaa_samples > 1;
        const depth_format = c.VK_FORMAT_D32_SFLOAT;

        if (use_msaa) {
            var msaa_color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            msaa_color_attachment.format = self.image_format;
            msaa_color_attachment.samples = sample_count;
            msaa_color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            msaa_color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            msaa_color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            msaa_color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            depth_attachment.format = depth_format;
            depth_attachment.samples = sample_count;
            depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            var resolve_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            resolve_attachment.format = self.image_format;
            resolve_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            resolve_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            resolve_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            resolve_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            resolve_attachment.finalLayout = if (self.headless_mode) c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

            var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
            var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
            var resolve_ref = c.VkAttachmentReference{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

            var subpass = std.mem.zeroes(c.VkSubpassDescription);
            subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &color_ref;
            subpass.pDepthStencilAttachment = &depth_ref;
            subpass.pResolveAttachments = &resolve_ref;

            var dependency = std.mem.zeroes(c.VkSubpassDependency);
            dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
            dependency.dstSubpass = 0;
            dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
            dependency.srcAccessMask = 0;
            dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
            dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

            var attachments = [_]c.VkAttachmentDescription{ msaa_color_attachment, depth_attachment, resolve_attachment };
            var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
            rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            rp_info.attachmentCount = 3;
            rp_info.pAttachments = &attachments[0];
            rp_info.subpassCount = 1;
            rp_info.pSubpasses = &subpass;
            rp_info.dependencyCount = 1;
            rp_info.pDependencies = &dependency;

            try checkVk(c.vkCreateRenderPass(self.device.vk_device, &rp_info, null, &self.main_render_pass));
        } else {
            var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            color_attachment.format = self.image_format;
            color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            color_attachment.finalLayout = if (self.headless_mode) c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

            var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            depth_attachment.format = depth_format;
            depth_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
            var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

            var subpass = std.mem.zeroes(c.VkSubpassDescription);
            subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &color_ref;
            subpass.pDepthStencilAttachment = &depth_ref;

            var dependency = std.mem.zeroes(c.VkSubpassDependency);
            dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
            dependency.dstSubpass = 0;
            dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
            dependency.srcAccessMask = 0;
            dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
            dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

            var attachments = [_]c.VkAttachmentDescription{ color_attachment, depth_attachment };
            var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
            rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            rp_info.attachmentCount = 2;
            rp_info.pAttachments = &attachments[0];
            rp_info.subpassCount = 1;
            rp_info.pSubpasses = &subpass;
            rp_info.dependencyCount = 1;
            rp_info.pDependencies = &dependency;

            try checkVk(c.vkCreateRenderPass(self.device.vk_device, &rp_info, null, &self.main_render_pass));
        }
    }

    fn createFramebuffers(self: *VulkanSwapchain, msaa_samples: u8) !void {
        const use_msaa = msaa_samples > 1;
        try self.framebuffers.ensureUnusedCapacity(self.allocator, self.image_views.items.len);
        for (self.image_views.items) |iv| {
            var fb: c.VkFramebuffer = null;
            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.main_render_pass;
            fb_info.width = self.extent.width;
            fb_info.height = self.extent.height;
            fb_info.layers = 1;

            if (use_msaa and self.msaa_color_view != null) {
                const attachments = [_]c.VkImageView{ self.msaa_color_view, self.depth_image_view, iv };
                fb_info.attachmentCount = 3;
                fb_info.pAttachments = &attachments[0];
                try checkVk(c.vkCreateFramebuffer(self.device.vk_device, &fb_info, null, &fb));
            } else {
                const attachments = [_]c.VkImageView{ iv, self.depth_image_view };
                fb_info.attachmentCount = 2;
                fb_info.pAttachments = &attachments[0];
                try checkVk(c.vkCreateFramebuffer(self.device.vk_device, &fb_info, null, &fb));
            }
            self.framebuffers.appendAssumeCapacity(fb);
        }
    }

    /// Picks a Vulkan present mode for the current surface that matches the
    /// requested `present_mode` when supported, falling back to FIFO (which is
    /// mandated by the spec to always be available). In headless mode FIFO is
    /// used unconditionally because no surface exists.
    fn selectPresentMode(self: *VulkanSwapchain) c.VkPresentModeKHR {
        // FIFO is always supported per the Vulkan spec; skip the query when it
        // is what we want anyway.
        if (self.headless_mode) return c.VK_PRESENT_MODE_FIFO_KHR;
        if (self.present_mode == c.VK_PRESENT_MODE_FIFO_KHR) return c.VK_PRESENT_MODE_FIFO_KHR;

        const surface = self.device.surface;
        const physical_device = self.device.physical_device;

        var mode_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, null);
        if (mode_count == 0) {
            log.log.warn("Surface reports zero present modes; falling back to FIFO", .{});
            return c.VK_PRESENT_MODE_FIFO_KHR;
        }

        // Typical drivers expose <= 4 modes; cap at 8 to stay on the stack.
        var modes_buf: [8]c.VkPresentModeKHR = undefined;
        const count = @min(mode_count, modes_buf.len);
        var actual: u32 = count;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &actual, &modes_buf);
        const modes = modes_buf[0..@min(count, actual)];

        for (modes) |m| {
            if (m == self.present_mode) return self.present_mode;
        }

        const requested_name = presentModeName(self.present_mode);
        log.log.warn("Requested present mode {s} unsupported on this surface; falling back to FIFO", .{requested_name});
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }
};

fn presentModeName(mode: c.VkPresentModeKHR) []const u8 {
    return switch (mode) {
        c.VK_PRESENT_MODE_IMMEDIATE_KHR => "IMMEDIATE",
        c.VK_PRESENT_MODE_MAILBOX_KHR => "MAILBOX",
        c.VK_PRESENT_MODE_FIFO_KHR => "FIFO",
        c.VK_PRESENT_MODE_FIFO_RELAXED_KHR => "FIFO_RELAXED",
        else => "UNKNOWN",
    };
}

test "VulkanSwapchain drawable sizing honors offscreen size and HiDPI resize" {
    var swapchain: VulkanSwapchain = undefined;
    try swapchain.setDrawableSize(640, 360, 640, 360);
    try std.testing.expectEqual(@as(u32, 640), swapchain.extent.width);
    try std.testing.expectEqual(@as(u32, 360), swapchain.extent.height);
    try std.testing.expectEqual(@as(f32, 1), swapchain.scale);

    try swapchain.setDrawableSize(2560, 1440, 1280, 720);
    try std.testing.expectEqual(@as(u32, 2560), swapchain.extent.width);
    try std.testing.expectEqual(@as(u32, 1440), swapchain.extent.height);
    try std.testing.expectEqual(swapchain.extent.width, swapchain.pixel_width);
    try std.testing.expectEqual(swapchain.extent.height, swapchain.pixel_height);
    try std.testing.expectEqual(@as(u32, 1280), swapchain.logical_width);
    try std.testing.expectEqual(@as(u32, 720), swapchain.logical_height);
    try std.testing.expectEqual(@as(f32, 2), swapchain.scale);
}

test "VulkanSwapchain rejects invalid drawable sizes before casting" {
    var swapchain: VulkanSwapchain = undefined;
    const invalid = [_][4]c_int{
        .{ 0, 360, 640, 360 },
        .{ 640, 0, 640, 360 },
        .{ -1, 360, 640, 360 },
        .{ 640, -1, 640, 360 },
        .{ 640, 360, 0, 360 },
        .{ 640, 360, 640, 0 },
        .{ 640, 360, -1, 360 },
        .{ 640, 360, 640, -1 },
    };
    for (invalid) |size| {
        try std.testing.expectError(error.BackendError, swapchain.setDrawableSize(size[0], size[1], size[2], size[3]));
    }
}

test "VulkanSwapchain recreation discards prior image handles" {
    var swapchain: VulkanSwapchain = undefined;
    swapchain.images = .empty;
    defer swapchain.images.deinit(std.testing.allocator);

    try swapchain.images.append(std.testing.allocator, null);
    try swapchain.images.append(std.testing.allocator, null);
    swapchain.clearImageTrackingForRecreate();

    try std.testing.expectEqual(@as(usize, 0), swapchain.images.items.len);
}

fn checkVk(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.BackendError;
}

fn getMSAASampleCountFlag(samples: u8) c.VkSampleCountFlagBits {
    return switch (samples) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}
