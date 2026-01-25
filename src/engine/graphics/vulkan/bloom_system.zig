const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const shader_registry = @import("shader_registry.zig");

const BLOOM_MIP_COUNT = rhi.BLOOM_MIP_COUNT;

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

    pub fn init(self: *BloomSystem, device: *const VulkanDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool, hdr_image_view: c.VkImageView, hdr_width: u32, hdr_height: u32, format: c.VkFormat) !void {
        self.deinit(device.vk_device, allocator, descriptor_pool);
        const vk = device.vk_device;

        errdefer self.deinit(vk, allocator, descriptor_pool);

        // 1. Render Pass
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
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

        // 2. Sampler
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.sampler));

        // 3. Mips
        for (0..BLOOM_MIP_COUNT) |i| {
            var image_info = std.mem.zeroes(c.VkImageCreateInfo);
            image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            image_info.imageType = c.VK_IMAGE_TYPE_2D;
            image_info.format = format;

            // Calculate mip size (downscale by 2 each level)
            const div = @as(u32, 1) << @intCast(i + 1); // 2, 4, 8...
            self.mip_widths[i] = @divFloor(hdr_width, div);
            self.mip_heights[i] = @divFloor(hdr_height, div);
            // Ensure at least 1x1
            if (self.mip_widths[i] == 0) self.mip_widths[i] = 1;
            if (self.mip_heights[i] == 0) self.mip_heights[i] = 1;

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
            view_info.format = format;
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

        // 4. Descriptor Set Layout
        var dsl_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 2;
        layout_info.pBindings = &dsl_bindings[0];
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

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

        // 6. Pipelines
        const vert_code = try std.fs.cwd().readFileAlloc(shader_registry.BLOOM_DOWNSAMPLE_VERT, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(vert_code);
        const down_frag_code = try std.fs.cwd().readFileAlloc(shader_registry.BLOOM_DOWNSAMPLE_FRAG, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(down_frag_code);
        const up_frag_code = try std.fs.cwd().readFileAlloc(shader_registry.BLOOM_UPSAMPLE_FRAG, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(up_frag_code);

        const vert_module = try Utils.createShaderModule(vk, vert_code);
        defer c.vkDestroyShaderModule(vk, vert_module, null);
        const down_frag_module = try Utils.createShaderModule(vk, down_frag_code);
        defer c.vkDestroyShaderModule(vk, down_frag_module, null);
        const up_frag_module = try Utils.createShaderModule(vk, up_frag_code);
        defer c.vkDestroyShaderModule(vk, up_frag_module, null);

        var down_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = down_frag_module, .pName = "main" },
        };

        var up_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = up_frag_module, .pName = "main" },
        };

        var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        rasterizer.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

        var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        // Blending for Downsample (Overwriting)
        var blend_attachment_down = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment_down.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        blend_attachment_down.blendEnable = c.VK_FALSE;

        var blending_down = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        blending_down.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blending_down.attachmentCount = 1;
        blending_down.pAttachments = &blend_attachment_down;

        // Blending for Upsample (Additive)
        var blend_attachment_up = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment_up.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        blend_attachment_up.blendEnable = c.VK_TRUE;
        blend_attachment_up.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment_up.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment_up.colorBlendOp = c.VK_BLEND_OP_ADD;
        blend_attachment_up.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment_up.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment_up.alphaBlendOp = c.VK_BLEND_OP_ADD;

        var blending_up = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        blending_up.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blending_up.attachmentCount = 1;
        blending_up.pAttachments = &blend_attachment_up;

        var dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = 2;
        dynamic_state.pDynamicStates = &dynamic_states;

        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pVertexInputState = &vertex_input;
        pipe_info.pInputAssemblyState = &input_assembly;
        pipe_info.pViewportState = &viewport_state;
        pipe_info.pRasterizationState = &rasterizer;
        pipe_info.pMultisampleState = &multisampling;
        pipe_info.pDynamicState = &dynamic_state;
        pipe_info.layout = self.pipeline_layout;
        pipe_info.renderPass = self.render_pass;
        pipe_info.subpass = 0;

        // Create Downsample Pipeline
        pipe_info.pStages = &down_stages[0];
        pipe_info.pColorBlendState = &blending_down;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.downsample_pipeline));

        // Create Upsample Pipeline
        pipe_info.pStages = &up_stages[0];
        pipe_info.pColorBlendState = &blending_up;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.upsample_pipeline));

        // 7. Descriptor Sets
        // We need BLOOM_MIP_COUNT sets per frame for downsampling + BLOOM_MIP_COUNT sets for upsampling
        // Actually, logic is:
        // Downsample: Source is Previous Mip (or HDR for first).
        // Upsample: Source is Next Mip.
        // We pre-allocate all sets.
        const total_sets = BLOOM_MIP_COUNT * 2;
        var layouts: [rhi.MAX_FRAMES_IN_FLIGHT * total_sets]c.VkDescriptorSetLayout = undefined;
        for (0..layouts.len) |i| layouts[i] = self.descriptor_set_layout;

        var alloc_info_ds = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info_ds.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info_ds.descriptorPool = descriptor_pool;
        alloc_info_ds.descriptorSetCount = total_sets * rhi.MAX_FRAMES_IN_FLIGHT;
        alloc_info_ds.pSetLayouts = &layouts[0];

        // Flatten descriptor sets array for allocation
        var flat_sets: [rhi.MAX_FRAMES_IN_FLIGHT * total_sets]c.VkDescriptorSet = undefined;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info_ds, &flat_sets[0]));

        // Distribute back to structured array
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |frame| {
            for (0..total_sets) |i| {
                self.descriptor_sets[frame][i] = flat_sets[frame * total_sets + i];
            }
        }

        // Update Descriptor Sets
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |frame| {
            // Downsample Sets (0 to BLOOM_MIP_COUNT-1)
            for (0..BLOOM_MIP_COUNT) |i| {
                var image_info_src = c.VkDescriptorImageInfo{
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .imageView = if (i == 0) hdr_image_view else self.mip_views[i - 1],
                    .sampler = self.sampler,
                };

                // Add a dummy info for binding 1 (previous mip).
                // Rationale: The descriptor set layout includes binding 1 (used by the upsample pass),
                // but the downsample shader does not use it. We bind the HDR view as a safe placeholder
                // to satisfy Vulkan validation without needing a separate layout.
                var image_info_dummy = c.VkDescriptorImageInfo{
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .imageView = if (i == 0) hdr_image_view else self.mip_views[i - 1],
                    .sampler = self.sampler,
                };

                var writes = [_]c.VkWriteDescriptorSet{
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][i],
                        .dstBinding = 0,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_info_src,
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][i],
                        .dstBinding = 1,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_info_dummy,
                    },
                };

                c.vkUpdateDescriptorSets(vk, 2, &writes[0], 0, null);
            }

            // Upsample Sets (BLOOM_MIP_COUNT to 2*BLOOM_MIP_COUNT-1)
            for (0..BLOOM_MIP_COUNT - 1) |pass| {
                const target_mip = (BLOOM_MIP_COUNT - 2) - pass;
                const src_mip = target_mip + 1;

                var image_info_src = c.VkDescriptorImageInfo{
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .imageView = self.mip_views[src_mip],
                    .sampler = self.sampler,
                };

                var image_info_prev = c.VkDescriptorImageInfo{
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .imageView = self.mip_views[target_mip],
                    .sampler = self.sampler,
                };

                var writes = [_]c.VkWriteDescriptorSet{
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][BLOOM_MIP_COUNT + pass],
                        .dstBinding = 0,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_info_src,
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][BLOOM_MIP_COUNT + pass],
                        .dstBinding = 1,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_info_prev,
                    },
                };

                c.vkUpdateDescriptorSets(vk, 2, &writes[0], 0, null);
            }
        }
    }

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
