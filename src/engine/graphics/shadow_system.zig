const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const ShadowSystem = struct {
    allocator: Allocator,

    // Resources
    shadow_image: c.VkImage = null,
    shadow_image_memory: c.VkDeviceMemory = null,
    shadow_image_view: c.VkImageView = null,
    shadow_image_views: [rhi.SHADOW_CASCADE_COUNT]c.VkImageView = .{null} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_image_layouts: [rhi.SHADOW_CASCADE_COUNT]c.VkImageLayout = .{c.VK_IMAGE_LAYOUT_UNDEFINED} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_framebuffers: [rhi.SHADOW_CASCADE_COUNT]c.VkFramebuffer = .{null} ** rhi.SHADOW_CASCADE_COUNT,
    shadow_sampler: c.VkSampler = null,
    shadow_render_pass: c.VkRenderPass = null,
    shadow_pipeline: c.VkPipeline = null,
    shadow_extent: c.VkExtent2D,

    // State
    pass_active: bool = false,
    pass_index: u32 = 0,
    pass_matrix: Mat4 = Mat4.identity,
    pipeline_bound: bool = false,

    pub fn init(allocator: Allocator, resolution: u32) ShadowSystem {
        return .{
            .allocator = allocator,
            .shadow_extent = .{ .width = resolution, .height = resolution },
        };
    }

    pub fn deinit(self: *ShadowSystem, device: c.VkDevice) void {
        if (self.shadow_pipeline != null) c.vkDestroyPipeline(device, self.shadow_pipeline, null);
        if (self.shadow_render_pass != null) c.vkDestroyRenderPass(device, self.shadow_render_pass, null);
        if (self.shadow_sampler != null) c.vkDestroySampler(device, self.shadow_sampler, null);

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            if (self.shadow_framebuffers[i] != null) c.vkDestroyFramebuffer(device, self.shadow_framebuffers[i], null);
            if (self.shadow_image_views[i] != null) c.vkDestroyImageView(device, self.shadow_image_views[i], null);
        }

        if (self.shadow_image_view != null) c.vkDestroyImageView(device, self.shadow_image_view, null);
        if (self.shadow_image != null) c.vkDestroyImage(device, self.shadow_image, null);
        if (self.shadow_image_memory != null) c.vkFreeMemory(device, self.shadow_image_memory, null);

        self.* = undefined;
    }

    pub fn beginPass(self: *ShadowSystem, command_buffer: c.VkCommandBuffer, cascade_index: u32, light_space_matrix: Mat4) void {
        // Safety: Ensure shadow resources are available
        if (self.shadow_render_pass == null) return;
        if (self.shadow_framebuffers[cascade_index] == null) return;

        self.pass_active = true;
        self.pass_index = cascade_index;
        self.pass_matrix = light_space_matrix;
        self.pipeline_bound = false;

        // Render pass handles transition from UNDEFINED to DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        self.shadow_image_layouts[cascade_index] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = self.shadow_render_pass;
        render_pass_info.framebuffer = self.shadow_framebuffers[cascade_index];
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = self.shadow_extent;

        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.depthStencil = .{ .depth = 0.0, .stencil = 0 }; // Reverse-Z: clear to 0.0 (far plane)
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

        // Set depth bias for shadow mapping to prevent shadow acne
        // Constants from original implementation: constantFactor=1.25, clamp=0.0, slopeFactor=1.75
        c.vkCmdSetDepthBias(command_buffer, 1.25, 0.0, 1.75);

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.x = 0.0;
        viewport.y = 0.0;
        viewport.width = @floatFromInt(self.shadow_extent.width);
        viewport.height = @floatFromInt(self.shadow_extent.height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.offset = .{ .x = 0, .y = 0 };
        scissor.extent = self.shadow_extent;
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    }

    pub fn endPass(self: *ShadowSystem, command_buffer: c.VkCommandBuffer) void {
        if (!self.pass_active) return;

        c.vkCmdEndRenderPass(command_buffer);
        const cascade_index = self.pass_index;
        self.pass_active = false;

        // Render pass handles transition to SHADER_READ_ONLY_OPTIMAL
        self.shadow_image_layouts[cascade_index] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }
};
