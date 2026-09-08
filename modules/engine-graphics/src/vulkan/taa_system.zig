const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Utils = @import("utils.zig");
const shader_registry = @import("shader_registry.zig");

pub const TAAPushConstants = extern struct {
    blend_factor: f32,
    velocity_rejection: f32,
    reset_history: f32,
    _pad: f32,
};

const DESCRIPTOR_SETS_PER_FRAME: usize = 2;
const TAA_DESCRIPTOR_SET_COUNT: usize = rhi.MAX_FRAMES_IN_FLIGHT * DESCRIPTOR_SETS_PER_FRAME;

pub fn renderPassConfig() struct { attachment: c.VkAttachmentDescription, dependencies: [2]c.VkSubpassDependency } {
    return .{
        .attachment = .{
            .format = c.VK_FORMAT_R32G32B32A32_SFLOAT,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        .dependencies = .{
            .{
                .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = 0,
                .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT,
                .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            },
            .{
                .srcSubpass = 0,
                .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT,
            },
        },
    };
}

pub const TAASystem = struct {
    enabled: bool = true,
    pass_active: bool = false,
    ran_this_frame: bool = false,
    history_valid: bool = false,
    blend_factor: f32 = 0.9,
    velocity_rejection: f32 = 0.02,

    render_pass: c.VkRenderPass = null,
    pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [TAA_DESCRIPTOR_SET_COUNT]c.VkDescriptorSet = .{null} ** TAA_DESCRIPTOR_SET_COUNT,
    sampler: c.VkSampler = null,

    history_textures: [2]rhi.TextureHandle = .{ 0, 0 },
    output_texture: rhi.TextureHandle = 0,
    framebuffers: [2]c.VkFramebuffer = .{ null, null },
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    history_index: usize = 0,

    /// Called once at frame start. A graph without TAA must not preserve history
    /// across the gap or expose last frame's output as this frame's result.
    pub fn beginFrame(self: *TAASystem) void {
        if (!self.ran_this_frame) self.history_valid = false;
        self.ran_this_frame = false;
        self.pass_active = false;
    }

    pub fn ensureResources(
        self: *TAASystem,
        vk: c.VkDevice,
        allocator: std.mem.Allocator,
        descriptor_pool: c.VkDescriptorPool,
        resources: anytype,
        extent: c.VkExtent2D,
    ) !void {
        if (extent.width == 0 or extent.height == 0) return;

        if (self.extent.width == extent.width and self.extent.height == extent.height and self.history_textures[0] != 0 and self.history_textures[1] != 0) {
            return;
        }

        // Replacing history invalidates framebuffers referenced by older submissions.
        if (self.history_textures[0] != 0 or self.history_textures[1] != 0) try Utils.checkVk(c.vkDeviceWaitIdle(vk));
        errdefer self.deinit(vk, descriptor_pool, resources);
        try self.ensureRenderState(vk, allocator, descriptor_pool);
        self.destroyFramebuffers(vk);
        self.destroyHistoryTextures(resources);

        const config = rhi.TextureConfig{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = false,
            .is_render_target = true,
        };

        const history_textures = blk: {
            const history_0 = try resources.createTexture(extent.width, extent.height, .rgba32f, config, null);
            errdefer resources.destroyTexture(history_0);
            const history_1 = try resources.createTexture(extent.width, extent.height, .rgba32f, config, null);
            errdefer resources.destroyTexture(history_1);
            break :blk [2]rhi.TextureHandle{ history_0, history_1 };
        };

        self.history_textures = history_textures;
        errdefer self.destroyHistoryTextures(resources);

        try self.createFramebuffers(vk, resources, extent);

        self.extent = extent;
        self.history_index = 0;
        self.history_valid = false;
        self.output_texture = self.history_textures[0];
    }

    fn ensureRenderState(self: *TAASystem, vk: c.VkDevice, allocator: std.mem.Allocator, descriptor_pool: c.VkDescriptorPool) !void {
        if (self.render_pass == null) {
            // Post-process and history reads cannot rely on Bloom adding a barrier.
            const config = renderPassConfig();

            var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
            var subpass = std.mem.zeroes(c.VkSubpassDescription);
            subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
            subpass.colorAttachmentCount = 1;
            subpass.pColorAttachments = &color_ref;

            var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
            rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            rp_info.attachmentCount = 1;
            rp_info.pAttachments = &config.attachment;
            rp_info.subpassCount = 1;
            rp_info.pSubpasses = &subpass;
            rp_info.dependencyCount = config.dependencies.len;
            rp_info.pDependencies = &config.dependencies[0];

            try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &self.render_pass));
        }

        if (self.sampler == null) {
            var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
            sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            sampler_info.magFilter = c.VK_FILTER_LINEAR;
            sampler_info.minFilter = c.VK_FILTER_LINEAR;
            sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
            try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.sampler));
        }

        if (self.descriptor_set_layout == null) {
            var layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
                .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
                .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
                .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            };

            var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
            layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            layout_info.bindingCount = layout_bindings.len;
            layout_info.pBindings = &layout_bindings;
            try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));
        }

        if (self.pipeline_layout == null) {
            var push_constant = std.mem.zeroes(c.VkPushConstantRange);
            push_constant.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
            push_constant.offset = 0;
            push_constant.size = @sizeOf(TAAPushConstants);

            var pipe_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
            pipe_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            pipe_layout_info.setLayoutCount = 1;
            pipe_layout_info.pSetLayouts = &self.descriptor_set_layout;
            pipe_layout_info.pushConstantRangeCount = 1;
            pipe_layout_info.pPushConstantRanges = &push_constant;
            try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipe_layout_info, null, &self.pipeline_layout));
        }

        if (self.pipeline == null) {
            const vert_code = try fs.cwd().readFileAlloc(shader_registry.TAA_VERT, allocator, 1024 * 1024);
            defer allocator.free(vert_code);
            const frag_code = try fs.cwd().readFileAlloc(shader_registry.TAA_FRAG, allocator, 1024 * 1024);
            defer allocator.free(frag_code);

            const vert_module = try Utils.createShaderModule(vk, vert_code);
            defer c.vkDestroyShaderModule(vk, vert_module, null);
            const frag_module = try Utils.createShaderModule(vk, frag_code);
            defer c.vkDestroyShaderModule(vk, frag_module, null);

            var stages = [_]c.VkPipelineShaderStageCreateInfo{
                .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
                .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
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
            rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;

            var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
            multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
            multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

            var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
            color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
            color_blend_attachment.blendEnable = c.VK_FALSE;

            var color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
            color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
            color_blending.attachmentCount = 1;
            color_blending.pAttachments = &color_blend_attachment;

            var dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
            var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
            dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
            dynamic_state.dynamicStateCount = dynamic_states.len;
            dynamic_state.pDynamicStates = &dynamic_states;

            var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
            pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
            pipeline_info.stageCount = stages.len;
            pipeline_info.pStages = &stages[0];
            pipeline_info.pVertexInputState = &vertex_input;
            pipeline_info.pInputAssemblyState = &input_assembly;
            pipeline_info.pViewportState = &viewport_state;
            pipeline_info.pRasterizationState = &rasterizer;
            pipeline_info.pMultisampleState = &multisampling;
            pipeline_info.pColorBlendState = &color_blending;
            pipeline_info.pDynamicState = &dynamic_state;
            pipeline_info.layout = self.pipeline_layout;
            pipeline_info.renderPass = self.render_pass;
            pipeline_info.subpass = 0;

            try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipeline_info, null, &self.pipeline));
        }

        if (self.descriptor_sets[0] == null) {
            var layouts: [TAA_DESCRIPTOR_SET_COUNT]c.VkDescriptorSetLayout = undefined;
            for (0..TAA_DESCRIPTOR_SET_COUNT) |i| {
                layouts[i] = self.descriptor_set_layout;
            }

            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = descriptor_pool;
            alloc_info.descriptorSetCount = TAA_DESCRIPTOR_SET_COUNT;
            alloc_info.pSetLayouts = &layouts[0];
            try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets[0]));
        }
    }

    fn descriptorSetIndex(frame_index: usize, read_idx: usize) usize {
        return frame_index * DESCRIPTOR_SETS_PER_FRAME + read_idx;
    }

    fn createFramebuffers(self: *TAASystem, vk: c.VkDevice, resources: anytype, extent: c.VkExtent2D) !void {
        errdefer self.destroyFramebuffers(vk);

        for (0..2) |i| {
            const tex = resources.textures.get(self.history_textures[i]) orelse return error.InvalidTexture;

            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &tex.view;
            fb_info.width = extent.width;
            fb_info.height = extent.height;
            fb_info.layers = 1;
            try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &self.framebuffers[i]));
        }
    }

    fn destroyFramebuffers(self: *TAASystem, vk: c.VkDevice) void {
        for (0..2) |i| {
            if (self.framebuffers[i] != null) {
                c.vkDestroyFramebuffer(vk, self.framebuffers[i], null);
                self.framebuffers[i] = null;
            }
        }
    }

    fn destroyHistoryTextures(self: *TAASystem, resources: anytype) void {
        for (self.history_textures) |handle| {
            if (handle != 0) {
                resources.destroyTexture(handle);
            }
        }
        self.history_textures = .{ 0, 0 };
        self.output_texture = 0;
    }

    pub fn compute(
        self: *TAASystem,
        vk: c.VkDevice,
        command_buffer: c.VkCommandBuffer,
        frame_index: usize,
        resources: anytype,
        hdr_view: c.VkImageView,
        velocity_view: c.VkImageView,
        extent: c.VkExtent2D,
        draw_call_count: *u32,
    ) void {
        if (!self.enabled) return;
        if (command_buffer == null or frame_index >= rhi.MAX_FRAMES_IN_FLIGHT) return;
        if (extent.width == 0 or extent.height == 0 or extent.width > self.extent.width or extent.height > self.extent.height) return;
        if (self.pipeline == null or self.pipeline_layout == null or self.render_pass == null) return;
        if (hdr_view == null or velocity_view == null) return;
        if (self.history_textures[0] == 0 or self.history_textures[1] == 0) return;

        const write_idx = self.history_index;
        const read_idx = (self.history_index + 1) % 2;
        if (self.framebuffers[write_idx] == null) return;

        const history_tex = resources.textures.get(self.history_textures[read_idx]) orelse return;

        const set_index = descriptorSetIndex(frame_index, read_idx);
        const descriptor_set = self.descriptor_sets[set_index];
        if (descriptor_set == null) return;

        var image_infos = [_]c.VkDescriptorImageInfo{
            .{ .sampler = self.sampler, .imageView = hdr_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = self.sampler, .imageView = history_tex.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = self.sampler, .imageView = velocity_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };

        var writes = [_]c.VkWriteDescriptorSet{
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_infos[0] },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_infos[1] },
            .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &image_infos[2] },
        };
        c.vkUpdateDescriptorSets(vk, writes.len, &writes[0], 0, null);

        var clear = std.mem.zeroes(c.VkClearValue);
        clear.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

        var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
        rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rp_begin.renderPass = self.render_pass;
        rp_begin.framebuffer = self.framebuffers[write_idx];
        rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        rp_begin.clearValueCount = 1;
        rp_begin.pClearValues = &clear;

        c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);
        self.pass_active = true;

        const viewport = c.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &descriptor_set, 0, null);

        const push = TAAPushConstants{
            .blend_factor = self.blend_factor,
            .velocity_rejection = self.velocity_rejection,
            .reset_history = if (self.history_valid) 0.0 else 1.0,
            ._pad = 0.0,
        };
        c.vkCmdPushConstants(command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(TAAPushConstants), &push);

        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        draw_call_count.* += 1;

        c.vkCmdEndRenderPass(command_buffer);
        self.pass_active = false;

        self.output_texture = self.history_textures[write_idx];
        self.history_index = read_idx;
        self.history_valid = true;
        self.ran_this_frame = true;
    }

    pub fn deinit(self: *TAASystem, vk: c.VkDevice, descriptor_pool: c.VkDescriptorPool, resources: anytype) void {
        self.destroyFramebuffers(vk);
        self.destroyHistoryTextures(resources);

        if (descriptor_pool != null) {
            for (0..TAA_DESCRIPTOR_SET_COUNT) |i| {
                if (self.descriptor_sets[i] != null) {
                    _ = c.vkFreeDescriptorSets(vk, descriptor_pool, 1, &self.descriptor_sets[i]);
                    self.descriptor_sets[i] = null;
                }
            }
        }

        if (self.pipeline != null) {
            c.vkDestroyPipeline(vk, self.pipeline, null);
            self.pipeline = null;
        }
        if (self.pipeline_layout != null) {
            c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }
        if (self.descriptor_set_layout != null) {
            c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
            self.descriptor_set_layout = null;
        }
        if (self.sampler != null) {
            c.vkDestroySampler(vk, self.sampler, null);
            self.sampler = null;
        }
        if (self.render_pass != null) {
            c.vkDestroyRenderPass(vk, self.render_pass, null);
            self.render_pass = null;
        }

        self.extent = .{ .width = 0, .height = 0 };
        self.history_index = 0;
        self.history_valid = false;
        self.ran_this_frame = false;
        self.pass_active = false;
    }
};
