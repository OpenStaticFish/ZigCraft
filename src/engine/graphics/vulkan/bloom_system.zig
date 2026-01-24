const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;

pub const BLOOM_MIP_COUNT = rhi.BLOOM_MIP_COUNT;

pub const BloomPushConstants = extern struct {
    texel_size: [2]f32,
    threshold_or_radius: f32, // Downsample: threshold, Upsample: filterRadius
    soft_threshold_or_intensity: f32, // Downsample: softThreshold, Upsample: bloomIntensity
    mip_level: i32, // Downsample: mipLevel, Upsample: unused
};

pub const BloomSystem = struct {
    enabled: bool = true,
    intensity: f32 = 0.5,
    threshold: f32 = 1.0,

    downsample_pipeline: c.VkPipeline = null,
    upsample_pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,

    mip_images: [BLOOM_MIP_COUNT]c.VkImage = .{null} ** BLOOM_MIP_COUNT,
    mip_memories: [BLOOM_MIP_COUNT]c.VkDeviceMemory = .{null} ** BLOOM_MIP_COUNT,
    mip_views: [BLOOM_MIP_COUNT]c.VkImageView = .{null} ** BLOOM_MIP_COUNT,
    mip_framebuffers: [BLOOM_MIP_COUNT]c.VkFramebuffer = .{null} ** BLOOM_MIP_COUNT,
    mip_widths: [BLOOM_MIP_COUNT]u32 = .{0} ** BLOOM_MIP_COUNT,
    mip_heights: [BLOOM_MIP_COUNT]u32 = .{0} ** BLOOM_MIP_COUNT,

    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT][BLOOM_MIP_COUNT * 2]c.VkDescriptorSet = .{.{null} ** (BLOOM_MIP_COUNT * 2)} ** rhi.MAX_FRAMES_IN_FLIGHT,
    render_pass: c.VkRenderPass = null,
    sampler: c.VkSampler = null,

    pub fn deinit(self: *BloomSystem, device: c.VkDevice, _: Allocator, descriptor_pool: c.VkDescriptorPool) void {
        if (self.downsample_pipeline != null) c.vkDestroyPipeline(device, self.downsample_pipeline, null);
        if (self.upsample_pipeline != null) c.vkDestroyPipeline(device, self.upsample_pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(device, self.pipeline_layout, null);

        if (descriptor_pool != null) {
            for (0..rhi.MAX_FRAMES_IN_FLIGHT) |frame| {
                for (0..BLOOM_MIP_COUNT * 2) |i| {
                    if (self.descriptor_sets[frame][i] != null) {
                        _ = c.vkFreeDescriptorSets(device, descriptor_pool, 1, &self.descriptor_sets[frame][i]);
                    }
                }
            }
        }

        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        if (self.render_pass != null) c.vkDestroyRenderPass(device, self.render_pass, null);
        if (self.sampler != null) c.vkDestroySampler(device, self.sampler, null);

        for (0..BLOOM_MIP_COUNT) |i| {
            if (self.mip_framebuffers[i] != null) c.vkDestroyFramebuffer(device, self.mip_framebuffers[i], null);
            if (self.mip_views[i] != null) c.vkDestroyImageView(device, self.mip_views[i], null);
            if (self.mip_images[i] != null) c.vkDestroyImage(device, self.mip_images[i], null);
            if (self.mip_memories[i] != null) c.vkFreeMemory(device, self.mip_memories[i], null);
        }

        self.* = std.mem.zeroes(BloomSystem);
        self.enabled = false; // Ensure it stays disabled after deinit
    }
};
