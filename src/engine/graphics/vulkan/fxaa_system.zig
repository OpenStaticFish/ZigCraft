const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");

pub const FXAAPushConstants = extern struct {
    texel_size: [2]f32,
    fxaa_span_max: f32,
    fxaa_reduce_mul: f32,
};

pub const FXAASystem = struct {
    enabled: bool = true,
    pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
    render_pass: c.VkRenderPass = null,
    framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,

    // Intermediate texture for FXAA input
    input_image: c.VkImage = null,
    input_memory: c.VkDeviceMemory = null,
    input_view: c.VkImageView = null,
    pass_active: bool = false,

    // Render pass for post-process when outputting to FXAA input
    post_process_to_fxaa_render_pass: c.VkRenderPass = null,
    post_process_to_fxaa_framebuffer: c.VkFramebuffer = null,

    pub fn deinit(self: *FXAASystem, device: c.VkDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool) void {
        if (self.pipeline != null) c.vkDestroyPipeline(device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(device, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);

        if (descriptor_pool != null) {
            for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
                if (self.descriptor_sets[i] != null) {
                    _ = c.vkFreeDescriptorSets(device, descriptor_pool, 1, &self.descriptor_sets[i]);
                }
            }
        }

        for (self.framebuffers.items) |fb| {
            c.vkDestroyFramebuffer(device, fb, null);
        }
        self.framebuffers.deinit(allocator);

        if (self.render_pass != null) c.vkDestroyRenderPass(device, self.render_pass, null);
        if (self.post_process_to_fxaa_render_pass != null) c.vkDestroyRenderPass(device, self.post_process_to_fxaa_render_pass, null);
        if (self.post_process_to_fxaa_framebuffer != null) c.vkDestroyFramebuffer(device, self.post_process_to_fxaa_framebuffer, null);

        if (self.input_view != null) c.vkDestroyImageView(device, self.input_view, null);
        if (self.input_image != null) c.vkDestroyImage(device, self.input_image, null);
        if (self.input_memory != null) c.vkFreeMemory(device, self.input_memory, null);

        self.* = std.mem.zeroes(FXAASystem);
    }
};
