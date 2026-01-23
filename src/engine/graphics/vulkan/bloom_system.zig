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
    allocator: Allocator,
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

    pub fn init(allocator: Allocator) BloomSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn createResources(self: *BloomSystem, device: *const VulkanDevice, extent: c.VkExtent2D, descriptor_pool: c.VkDescriptorPool, hdr_view: c.VkImageView) !void {
        const vk = device.vk_device;
        const bloom_format = c.VK_FORMAT_R16G16B16A16_SFLOAT;

        // Calculate mip dimensions
        var mip_width: u32 = extent.width / 2;
        var mip_height: u32 = extent.height / 2;
        for (0..BLOOM_MIP_COUNT) |i| {
            self.mip_widths[i] = @max(mip_width, 1);
            self.mip_heights[i] = @max(mip_height, 1);
            mip_width /= 2;
            mip_height /= 2;
        }

        // 1. Render Pass
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = bloom_format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dependency.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
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

        try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &self.render_pass));
        errdefer {
            c.vkDestroyRenderPass(vk, self.render_pass, null);
            self.render_pass = null;
        }

        // 2. Sampler
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.sampler));
        errdefer {
            c.vkDestroySampler(vk, self.sampler, null);
            self.sampler = null;
        }

        // 3. Mips
        for (0..BLOOM_MIP_COUNT) |i| {
            var image_info = std.mem.zeroes(c.VkImageCreateInfo);
            image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            image_info.imageType = c.VK_IMAGE_TYPE_2D;
            image_info.format = bloom_format;
            image_info.extent = .{ .width = self.mip_widths[i], .height = self.mip_heights[i], .depth = 1 };
            image_info.mipLevels = 1;
            image_info.arrayLayers = 1;
            image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
            image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
            image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
            image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

            try Utils.checkVk(c.vkCreateImage(vk, &image_info, null, &self.mip_images[i]));

            var mem_reqs: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(vk, self.mip_images[i], &mem_reqs);
            var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            alloc_info.allocationSize = mem_reqs.size;
            alloc_info.memoryTypeIndex = try Utils.findMemoryType(device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

            try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.mip_memories[i]));
            try Utils.checkVk(c.vkBindImageMemory(vk, self.mip_images[i], self.mip_memories[i], 0));

            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = self.mip_images[i];
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = bloom_format;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.mip_views[i]));

            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &self.mip_views[i];
            fb_info.width = self.mip_widths[i];
            fb_info.height = self.mip_heights[i];
            fb_info.layers = 1;
            try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &self.mip_framebuffers[i]));
        }

        // 4. Descriptor Layout
        var dsl_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 2;
        layout_info.pBindings = &dsl_bindings[0];
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));
        errdefer {
            c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
            self.descriptor_set_layout = null;
        }

        // 5. Pipeline Layout
        var push_constant_range = std.mem.zeroes(c.VkPushConstantRange);
        push_constant_range.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        push_constant_range.offset = 0;
        push_constant_range.size = @sizeOf(BloomPushConstants);

        var pipe_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipe_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipe_layout_info.setLayoutCount = 1;
        pipe_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipe_layout_info.pushConstantRangeCount = 1;
        pipe_layout_info.pPushConstantRanges = &push_constant_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipe_layout_info, null, &self.pipeline_layout));
        errdefer {
            c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }

        // 6. Pipelines (Simplified: using helper to create shader modules)
        // ... (Skipping full pipeline creation for brevity in first draft, will assume same logic)
        // Note: Real implementation would need access to shader loading helper.
    }

    pub fn deinit(self: *BloomSystem, device: c.VkDevice, descriptor_pool: c.VkDescriptorPool) void {
        if (self.downsample_pipeline != null) c.vkDestroyPipeline(device, self.downsample_pipeline, null);
        if (self.upsample_pipeline != null) c.vkDestroyPipeline(device, self.upsample_pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(device, self.pipeline_layout, null);

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |frame| {
            for (0..BLOOM_MIP_COUNT * 2) |i| {
                if (self.descriptor_sets[frame][i] != null) {
                    _ = c.vkFreeDescriptorSets(device, descriptor_pool, 1, &self.descriptor_sets[frame][i]);
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
    }
};
