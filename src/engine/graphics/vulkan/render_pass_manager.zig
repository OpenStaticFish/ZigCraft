//! Render Pass Manager - Handles all Vulkan render pass and framebuffer management
//!
//! Extracted from rhi_vulkan.zig to eliminate the god object anti-pattern.
//! This module is responsible for:
//! - Creating and destroying render passes
//! - Managing framebuffers for different rendering stages
//! - Handling HDR, G-Pass, post-process, and UI render passes

const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");

/// Depth format used throughout the renderer
const DEPTH_FORMAT = c.VK_FORMAT_D32_SFLOAT;

/// Render pass manager handles all render pass and framebuffer resources
pub const RenderPassManager = struct {
    // Main render pass (HDR with optional MSAA)
    hdr_render_pass: c.VkRenderPass = null,

    // G-Pass render pass (for SSAO prep)
    g_render_pass: c.VkRenderPass = null,

    // Post-process render pass
    post_process_render_pass: c.VkRenderPass = null,

    // UI render pass (for swapchain overlay)
    ui_swapchain_render_pass: c.VkRenderPass = null,

    // Framebuffers
    main_framebuffer: c.VkFramebuffer = null,
    g_framebuffer: c.VkFramebuffer = null,
    post_process_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    ui_swapchain_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,

    /// Initialize the render pass manager
    pub fn init(_allocator: std.mem.Allocator) RenderPassManager {
        _ = _allocator;
        return .{
            .post_process_framebuffers = .empty,
            .ui_swapchain_framebuffers = .empty,
        };
    }

    /// Deinitialize and destroy all render passes and framebuffers
    pub fn deinit(self: *RenderPassManager, vk_device: c.VkDevice, allocator: std.mem.Allocator) void {
        self.destroyFramebuffers(vk_device, allocator);
        self.destroyRenderPasses(vk_device);
    }

    /// Destroy all framebuffers
    pub fn destroyFramebuffers(self: *RenderPassManager, vk_device: c.VkDevice, allocator: std.mem.Allocator) void {
        if (self.main_framebuffer) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
            self.main_framebuffer = null;
        }

        if (self.g_framebuffer) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
            self.g_framebuffer = null;
        }

        for (self.post_process_framebuffers.items) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
        }
        self.post_process_framebuffers.deinit(allocator);
        self.post_process_framebuffers = .empty;

        for (self.ui_swapchain_framebuffers.items) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
        }
        self.ui_swapchain_framebuffers.deinit(allocator);
        self.ui_swapchain_framebuffers = .empty;
    }

    /// Destroy all render passes
    fn destroyRenderPasses(self: *RenderPassManager, vk_device: c.VkDevice) void {
        if (self.hdr_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.hdr_render_pass = null;
        }

        if (self.g_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.g_render_pass = null;
        }

        if (self.post_process_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.post_process_render_pass = null;
        }

        if (self.ui_swapchain_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.ui_swapchain_render_pass = null;
        }
    }

    /// Create the main HDR render pass (with optional MSAA)
    pub fn createMainRenderPass(
        self: *RenderPassManager,
        vk_device: c.VkDevice,
        _extent: c.VkExtent2D,
        msaa_samples: u8,
    ) !void {
        _ = _extent;
        // Destroy existing render pass
        if (self.hdr_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.hdr_render_pass = null;
        }

        const sample_count = getMSAASampleCountFlag(msaa_samples);
        const use_msaa = msaa_samples > 1;
        const hdr_format = c.VK_FORMAT_R16G16B16A16_SFLOAT;

        if (use_msaa) {
            // MSAA render pass: 3 attachments (MSAA color, MSAA depth, resolve)
            var msaa_color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            msaa_color_attachment.format = hdr_format;
            msaa_color_attachment.samples = sample_count;
            msaa_color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            msaa_color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            msaa_color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            msaa_color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            msaa_color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            msaa_color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            depth_attachment.format = DEPTH_FORMAT;
            depth_attachment.samples = sample_count;
            depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            var resolve_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            resolve_attachment.format = hdr_format;
            resolve_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            resolve_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            resolve_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            resolve_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            resolve_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            resolve_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            resolve_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
            var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
            var resolve_ref = c.VkAttachmentReference{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

            var subpass = std.mem.zeroes(c.VkSubpassDescription);
            subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &color_ref;
            subpass.pDepthStencilAttachment = &depth_ref;
            subpass.pResolveAttachments = &resolve_ref;

            var dependencies = [_]c.VkSubpassDependency{
                .{
                    .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                    .dstSubpass = 0,
                    .srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT,
                    .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                    .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
                },
                .{
                    .srcSubpass = 0,
                    .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                    .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                    .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                    .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                    .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
                },
            };

            var attachment_descs = [_]c.VkAttachmentDescription{ msaa_color_attachment, depth_attachment, resolve_attachment };
            var render_pass_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
            render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            render_pass_info.attachmentCount = 3;
            render_pass_info.pAttachments = &attachment_descs[0];
            render_pass_info.subpassCount = 1;
            render_pass_info.pSubpasses = &subpass;
            render_pass_info.dependencyCount = 2;
            render_pass_info.pDependencies = &dependencies[0];

            try Utils.checkVk(c.vkCreateRenderPass(vk_device, &render_pass_info, null, &self.hdr_render_pass));
            std.log.info("Created HDR MSAA {}x render pass", .{msaa_samples});
        } else {
            // Non-MSAA render pass: 2 attachments (color, depth)
            var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            color_attachment.format = hdr_format;
            color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            var depth_attachment = std.mem.zeroes(c.VkAttachmentDescription);
            depth_attachment.format = DEPTH_FORMAT;
            depth_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
            depth_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            depth_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
            depth_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            depth_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            depth_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            depth_attachment.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            var color_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
            color_attachment_ref.attachment = 0;
            color_attachment_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            var depth_attachment_ref = std.mem.zeroes(c.VkAttachmentReference);
            depth_attachment_ref.attachment = 1;
            depth_attachment_ref.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            var subpass = std.mem.zeroes(c.VkSubpassDescription);
            subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &color_attachment_ref;
            subpass.pDepthStencilAttachment = &depth_attachment_ref;

            var dependencies = [_]c.VkSubpassDependency{
                .{
                    .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                    .dstSubpass = 0,
                    .srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT,
                    .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                    .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
                },
                .{
                    .srcSubpass = 0,
                    .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                    .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                    .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                    .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                    .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
                },
            };

            var attachments = [_]c.VkAttachmentDescription{ color_attachment, depth_attachment };
            var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
            rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            rp_info.attachmentCount = 2;
            rp_info.pAttachments = &attachments[0];
            rp_info.subpassCount = 1;
            rp_info.pSubpasses = &subpass;
            rp_info.dependencyCount = 2;
            rp_info.pDependencies = &dependencies[0];

            try Utils.checkVk(c.vkCreateRenderPass(vk_device, &rp_info, null, &self.hdr_render_pass));
        }
    }

    /// Create the G-Pass render pass (for SSAO prep)
    pub fn createGPassRenderPass(self: *RenderPassManager, vk_device: c.VkDevice) !void {
        if (self.g_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.g_render_pass = null;
        }

        const normal_format = c.VK_FORMAT_R8G8B8A8_UNORM;
        const velocity_format = c.VK_FORMAT_R16G16_SFLOAT;

        var attachments: [3]c.VkAttachmentDescription = undefined;

        // Attachment 0: Normal buffer (color output)
        attachments[0] = std.mem.zeroes(c.VkAttachmentDescription);
        attachments[0].format = normal_format;
        attachments[0].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[0].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[0].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[0].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        // Attachment 1: Velocity buffer (color output for motion vectors)
        attachments[1] = std.mem.zeroes(c.VkAttachmentDescription);
        attachments[1].format = velocity_format;
        attachments[1].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[1].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[1].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[1].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[1].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[1].finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        // Attachment 2: Depth buffer
        attachments[2] = std.mem.zeroes(c.VkAttachmentDescription);
        attachments[2].format = DEPTH_FORMAT;
        attachments[2].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[2].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[2].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[2].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[2].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[2].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[2].finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_refs = [_]c.VkAttachmentReference{
            c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL },
            c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL },
        };
        var depth_ref = c.VkAttachmentReference{ .attachment = 2, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 2;
        subpass.pColorAttachments = &color_refs;
        subpass.pDepthStencilAttachment = &depth_ref;

        var deps: [2]c.VkSubpassDependency = undefined;
        deps[0] = std.mem.zeroes(c.VkSubpassDependency);
        deps[0].srcSubpass = c.VK_SUBPASS_EXTERNAL;
        deps[0].dstSubpass = 0;
        deps[0].srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        deps[0].dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        deps[0].srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT;
        deps[0].dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        deps[0].dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        deps[1] = std.mem.zeroes(c.VkSubpassDependency);
        deps[1].srcSubpass = 0;
        deps[1].dstSubpass = c.VK_SUBPASS_EXTERNAL;
        deps[1].srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        deps[1].dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        deps[1].srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        deps[1].dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        deps[1].dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 3;
        rp_info.pAttachments = &attachments;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 2;
        rp_info.pDependencies = &deps;

        try Utils.checkVk(c.vkCreateRenderPass(vk_device, &rp_info, null, &self.g_render_pass));
    }

    /// Create post-process render pass
    pub fn createPostProcessRenderPass(self: *RenderPassManager, vk_device: c.VkDevice, swapchain_format: c.VkFormat) !void {
        if (self.post_process_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.post_process_render_pass = null;
        }

        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = swapchain_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = &color_attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 1;
        rp_info.pDependencies = &dependency;

        try Utils.checkVk(c.vkCreateRenderPass(vk_device, &rp_info, null, &self.post_process_render_pass));
    }

    /// Create UI swapchain render pass
    pub fn createUISwapchainRenderPass(self: *RenderPassManager, vk_device: c.VkDevice, swapchain_format: c.VkFormat) !void {
        if (self.ui_swapchain_render_pass) |rp| {
            c.vkDestroyRenderPass(vk_device, rp, null);
            self.ui_swapchain_render_pass = null;
        }

        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = swapchain_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.srcAccessMask = 0;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
        dependency.dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = &color_attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 1;
        rp_info.pDependencies = &dependency;

        try Utils.checkVk(c.vkCreateRenderPass(vk_device, &rp_info, null, &self.ui_swapchain_render_pass));
    }

    /// Create main framebuffer
    pub fn createMainFramebuffer(
        self: *RenderPassManager,
        vk_device: c.VkDevice,
        extent: c.VkExtent2D,
        hdr_view: c.VkImageView,
        hdr_msaa_view: ?c.VkImageView,
        depth_view: c.VkImageView,
        msaa_samples: u8,
    ) !void {
        if (self.main_framebuffer) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
            self.main_framebuffer = null;
        }

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = self.hdr_render_pass;
        fb_info.width = extent.width;
        fb_info.height = extent.height;
        fb_info.layers = 1;

        const use_msaa = msaa_samples > 1;

        if (use_msaa and hdr_msaa_view != null) {
            // MSAA: [MSAA Color, MSAA Depth, Resolve HDR]
            const attachments = [_]c.VkImageView{ hdr_msaa_view.?, depth_view, hdr_view };
            fb_info.attachmentCount = 3;
            fb_info.pAttachments = &attachments[0];
        } else {
            // Non-MSAA: [HDR Color, Depth]
            const attachments = [_]c.VkImageView{ hdr_view, depth_view };
            fb_info.attachmentCount = 2;
            fb_info.pAttachments = &attachments[0];
        }

        try Utils.checkVk(c.vkCreateFramebuffer(vk_device, &fb_info, null, &self.main_framebuffer));
    }

    /// Create G-Pass framebuffer
    pub fn createGPassFramebuffer(
        self: *RenderPassManager,
        vk_device: c.VkDevice,
        extent: c.VkExtent2D,
        normal_view: c.VkImageView,
        velocity_view: c.VkImageView,
        depth_view: c.VkImageView,
    ) !void {
        if (self.g_framebuffer) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
            self.g_framebuffer = null;
        }

        const attachments = [_]c.VkImageView{ normal_view, velocity_view, depth_view };

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = self.g_render_pass;
        fb_info.attachmentCount = 3;
        fb_info.pAttachments = &attachments;
        fb_info.width = extent.width;
        fb_info.height = extent.height;
        fb_info.layers = 1;

        try Utils.checkVk(c.vkCreateFramebuffer(vk_device, &fb_info, null, &self.g_framebuffer));
    }

    /// Create post-process framebuffers (one per swapchain image)
    pub fn createPostProcessFramebuffers(
        self: *RenderPassManager,
        vk_device: c.VkDevice,
        allocator: std.mem.Allocator,
        extent: c.VkExtent2D,
        swapchain_image_views: []const c.VkImageView,
    ) !void {
        // Clear existing
        for (self.post_process_framebuffers.items) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
        }
        self.post_process_framebuffers.clearRetainingCapacity();

        for (swapchain_image_views) |view| {
            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.post_process_render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &view;
            fb_info.width = extent.width;
            fb_info.height = extent.height;
            fb_info.layers = 1;

            var fb: c.VkFramebuffer = null;
            try Utils.checkVk(c.vkCreateFramebuffer(vk_device, &fb_info, null, &fb));
            try self.post_process_framebuffers.append(allocator, fb);
        }
    }

    /// Create UI swapchain framebuffers
    pub fn createUISwapchainFramebuffers(
        self: *RenderPassManager,
        vk_device: c.VkDevice,
        allocator: std.mem.Allocator,
        extent: c.VkExtent2D,
        swapchain_image_views: []const c.VkImageView,
    ) !void {
        // Clear existing
        for (self.ui_swapchain_framebuffers.items) |fb| {
            c.vkDestroyFramebuffer(vk_device, fb, null);
        }
        self.ui_swapchain_framebuffers.clearRetainingCapacity();

        for (swapchain_image_views) |view| {
            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.ui_swapchain_render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &view;
            fb_info.width = extent.width;
            fb_info.height = extent.height;
            fb_info.layers = 1;

            var fb: c.VkFramebuffer = null;
            try Utils.checkVk(c.vkCreateFramebuffer(vk_device, &fb_info, null, &fb));
            try self.ui_swapchain_framebuffers.append(allocator, fb);
        }
    }
};

/// Converts MSAA sample count (1, 2, 4, 8) to Vulkan sample count flag.
fn getMSAASampleCountFlag(samples: u8) c.VkSampleCountFlagBits {
    return switch (samples) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}
