const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const resource_manager_pkg = @import("resource_manager.zig");

const TAAPushConstants = extern struct {
    jitter_offset: [2]f32,
    feedback_min: f32,
    feedback_max: f32,
};

pub const TAASystem = struct {
    pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    render_pass: c.VkRenderPass = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    // descriptor_sets[frame][0] -> Reads History A (Writes History B)
    // descriptor_sets[frame][1] -> Reads History B (Writes History A)
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT][2]c.VkDescriptorSet = .{.{ null, null }} ** rhi.MAX_FRAMES_IN_FLIGHT,

    // Ping-pong history buffers
    history_images: [2]c.VkImage = .{ null, null },
    history_memories: [2]c.VkDeviceMemory = .{ null, null },
    history_views: [2]c.VkImageView = .{ null, null },

    // Framebuffers for each history target
    framebuffers: [2]c.VkFramebuffer = .{ null, null },

    current_history_index: u8 = 0, // The one containing valid history (READ from here)

    sampler: c.VkSampler = null,

    // Track if history is valid (invalidated on resize/teleport)
    history_valid: bool = false,
    needs_descriptor_update: bool = true,
    mutex: std.Thread.Mutex = .{},

    /// //! SAFETY: Must be called from the main thread during initialization.
    pub fn init(self: *TAASystem, device: *VulkanDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool, width: u32, height: u32, global_layout: c.VkDescriptorSetLayout) !void {
        const vk = device.vk_device;
        const format = c.VK_FORMAT_B10G11R11_UFLOAT_PACK32; // Efficient HDR format

        try self.initRenderPass(vk, format);
        errdefer self.deinit(vk, allocator, descriptor_pool);

        try self.initImages(device, width, height, format);
        try self.initFramebuffers(vk, width, height);
        try self.initSampler(vk);
        try self.initDescriptorLayout(vk);
        try self.initPipeline(vk, allocator, global_layout);
        try self.initDescriptorSets(vk, descriptor_pool);

        self.needs_descriptor_update = true;
    }

    /// //! SAFETY: Must be called when the GPU is idle (e.g. during deinit).
    pub fn deinit(self: *TAASystem, vk: c.VkDevice, _: Allocator, descriptor_pool: c.VkDescriptorPool) void {
        const vkDestroyFramebuffer = c.vkDestroyFramebuffer; // Fix macro issue

        if (descriptor_pool != null) {
            for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
                for (0..2) |h_idx| {
                    if (self.descriptor_sets[i][h_idx] != null) {
                        var set = self.descriptor_sets[i][h_idx];
                        _ = c.vkFreeDescriptorSets(vk, descriptor_pool, 1, &set);
                        self.descriptor_sets[i][h_idx] = null;
                    }
                }
            }
        }

        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.render_pass != null) c.vkDestroyRenderPass(vk, self.render_pass, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.sampler != null) c.vkDestroySampler(vk, self.sampler, null);

        for (self.framebuffers) |fb| {
            if (fb != null) vkDestroyFramebuffer(vk, fb, null);
        }

        for (0..2) |i| {
            if (self.history_views[i] != null) {
                c.vkDestroyImageView(vk, self.history_views[i], null);
                self.history_views[i] = null;
            }
            if (self.history_images[i] != null) {
                c.vkDestroyImage(vk, self.history_images[i], null);
                self.history_images[i] = null;
            }
            if (self.history_memories[i] != null) {
                c.vkFreeMemory(vk, self.history_memories[i], null);
                self.history_memories[i] = null;
            }
        }
    }

    /// //! SAFETY: Must be called from the main thread during window resize.
    /// Thread-safe via internal mutex.
    pub fn resize(self: *TAASystem, device: *VulkanDevice, width: u32, height: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const vk = device.vk_device;
        // Destroy size-dependent resources
        const vkDestroyFramebuffer = c.vkDestroyFramebuffer;
        for (self.framebuffers) |fb| {
            if (fb != null) vkDestroyFramebuffer(vk, fb, null);
        }
        for (0..2) |i| {
            if (self.history_views[i] != null) {
                c.vkDestroyImageView(vk, self.history_views[i], null);
                self.history_views[i] = null;
            }
            if (self.history_images[i] != null) {
                c.vkDestroyImage(vk, self.history_images[i], null);
                self.history_images[i] = null;
            }
            if (self.history_memories[i] != null) {
                c.vkFreeMemory(vk, self.history_memories[i], null);
                self.history_memories[i] = null;
            }
        }

        // Recreate
        const format = c.VK_FORMAT_B10G11R11_UFLOAT_PACK32;
        try self.initImages(device, width, height, format);
        try self.initFramebuffers(vk, width, height);

        self.history_valid = false;
        self.needs_descriptor_update = true;
    }

    /// //! SAFETY: Thread-safe. Invalidates history to prevent ghosting on teleport/chunk edits.
    pub fn invalidateHistory(self: *TAASystem) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.history_valid = false;
    }

    fn initRenderPass(self: *TAASystem, vk: c.VkDevice, format: c.VkFormat) !void {
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = format;
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        // Dependencies
        var deps: [2]c.VkSubpassDependency = undefined;

        // Incoming dependency
        deps[0] = std.mem.zeroes(c.VkSubpassDependency);
        deps[0].srcSubpass = c.VK_SUBPASS_EXTERNAL;
        deps[0].dstSubpass = 0;
        deps[0].srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[0].dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[0].srcAccessMask = 0;
        deps[0].dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        // Outgoing dependency
        deps[1] = std.mem.zeroes(c.VkSubpassDependency);
        deps[1].srcSubpass = 0;
        deps[1].dstSubpass = c.VK_SUBPASS_EXTERNAL;
        deps[1].srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        deps[1].dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        deps[1].srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        deps[1].dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = &attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 2;
        rp_info.pDependencies = &deps;

        if (c.vkCreateRenderPass(vk, &rp_info, null, &self.render_pass) != c.VK_SUCCESS) {
            return error.VulkanError;
        }
    }

    fn initImages(self: *TAASystem, device: *VulkanDevice, width: u32, height: u32, format: c.VkFormat) !void {
        for (0..2) |i| {
            try Utils.createImage(
                device.vk_device,
                device.physical_device,
                width,
                height,
                format,
                c.VK_IMAGE_TILING_OPTIMAL,
                c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                &self.history_images[i],
                &self.history_memories[i],
            );
            self.history_views[i] = try Utils.createImageView(device.vk_device, self.history_images[i], format, c.VK_IMAGE_ASPECT_COLOR_BIT);
        }
    }

    fn initFramebuffers(self: *TAASystem, vk: c.VkDevice, width: u32, height: u32) !void {
        for (0..2) |i| {
            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &self.history_views[i];
            fb_info.width = width;
            fb_info.height = height;
            fb_info.layers = 1;

            if (c.vkCreateFramebuffer(vk, &fb_info, null, &self.framebuffers[i]) != c.VK_SUCCESS) {
                return error.VulkanError;
            }
        }
    }

    fn initSampler(self: *TAASystem, vk: c.VkDevice) !void {
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.anisotropyEnable = c.VK_FALSE;
        sampler_info.maxAnisotropy = 1.0;
        sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE; // unused
        sampler_info.unnormalizedCoordinates = c.VK_FALSE;
        sampler_info.compareEnable = c.VK_FALSE;
        sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

        if (c.vkCreateSampler(vk, &sampler_info, null, &self.sampler) != c.VK_SUCCESS) {
            return error.VulkanError;
        }
    }

    fn initDescriptorLayout(self: *TAASystem, vk: c.VkDevice) !void {
        var bindings = [_]c.VkDescriptorSetLayoutBinding{ .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        }, .{
            .binding = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        }, .{
            .binding = 2,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        } };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;

        if (c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout) != c.VK_SUCCESS) {
            return error.VulkanError;
        }
    }

    fn initDescriptorSets(self: *TAASystem, vk: c.VkDevice, pool: c.VkDescriptorPool) !void {
        var layouts = [_]c.VkDescriptorSetLayout{self.descriptor_set_layout} ** (rhi.MAX_FRAMES_IN_FLIGHT * 2);

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = pool;
        alloc_info.descriptorSetCount = rhi.MAX_FRAMES_IN_FLIGHT * 2;
        alloc_info.pSetLayouts = &layouts;

        var flat_sets: [rhi.MAX_FRAMES_IN_FLIGHT * 2]c.VkDescriptorSet = undefined;
        if (c.vkAllocateDescriptorSets(vk, &alloc_info, &flat_sets) != c.VK_SUCCESS) {
            return error.VulkanError;
        }

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.descriptor_sets[i][0] = flat_sets[i * 2];
            self.descriptor_sets[i][1] = flat_sets[i * 2 + 1];
        }
    }

    fn initPipeline(self: *TAASystem, vk: c.VkDevice, allocator: Allocator, global_layout: c.VkDescriptorSetLayout) !void {
        const vert_code = try Utils.readFile(allocator, "assets/shaders/vulkan/taa.vert.spv");
        defer allocator.free(vert_code);
        const frag_code = try Utils.readFile(allocator, "assets/shaders/vulkan/taa.frag.spv");
        defer allocator.free(frag_code);

        const vert_module = try Utils.createShaderModule(vk, vert_code);
        defer c.vkDestroyShaderModule(vk, vert_module, null);
        const frag_module = try Utils.createShaderModule(vk, frag_code);
        defer c.vkDestroyShaderModule(vk, frag_module, null);

        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            Utils.pipelineShaderStageCreateInfo(c.VK_SHADER_STAGE_VERTEX_BIT, vert_module, "main"),
            Utils.pipelineShaderStageCreateInfo(c.VK_SHADER_STAGE_FRAGMENT_BIT, frag_module, "main"),
        };

        var push_constant_range = c.VkPushConstantRange{
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = @sizeOf(TAAPushConstants),
        };

        var layouts = [_]c.VkDescriptorSetLayout{ global_layout, self.descriptor_set_layout };

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = layouts.len;
        pipeline_layout_info.pSetLayouts = &layouts;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &push_constant_range;

        if (c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout) != c.VK_SUCCESS) {
            return error.VulkanError;
        }

        var dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = dynamic_states.len;
        dynamic_state.pDynamicStates = &dynamic_states;

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
        rasterizer.polygonMode = c.VK_POLYGON_MODE_FILL;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;

        var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depth_stencil.depthTestEnable = c.VK_FALSE;

        var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        color_blend_attachment.blendEnable = c.VK_FALSE;

        var color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blend.attachmentCount = 1;
        color_blend.pAttachments = &color_blend_attachment;

        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages;
        pipeline_info.pVertexInputState = &vertex_input;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &rasterizer;
        pipeline_info.pMultisampleState = &multisampling;
        pipeline_info.pDepthStencilState = &depth_stencil;
        pipeline_info.pColorBlendState = &color_blend;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = self.pipeline_layout;
        pipeline_info.renderPass = self.render_pass;
        pipeline_info.subpass = 0;

        if (c.vkCreateGraphicsPipelines(vk, null, 1, &pipeline_info, null, &self.pipeline) != c.VK_SUCCESS) {
            return error.VulkanError;
        }
    }

    /// //! SAFETY: Thread-safe. Updates all descriptor sets if needed.
    /// Called when input views change (e.g. on resize).
    pub fn updateAllDescriptors(self: *TAASystem, vk: c.VkDevice, input_color_view: c.VkImageView, velocity_view: c.VkImageView) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.needs_descriptor_update) return;

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            for (0..2) |h_idx| {
                const set = self.descriptor_sets[i][h_idx];
                const history_view = self.history_views[h_idx];

                var image_infos = [_]c.VkDescriptorImageInfo{
                    .{ .sampler = self.sampler, .imageView = input_color_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
                    .{ .sampler = self.sampler, .imageView = history_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
                    .{ .sampler = self.sampler, .imageView = velocity_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
                };

                var writes = [_]c.VkWriteDescriptorSet{
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = set,
                        .dstBinding = 0,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_infos[0],
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = set,
                        .dstBinding = 1,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_infos[1],
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = set,
                        .dstBinding = 2,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &image_infos[2],
                    },
                };

                c.vkUpdateDescriptorSets(vk, writes.len, &writes, 0, null);
            }
        }

        self.needs_descriptor_update = false;
    }

    /// //! SAFETY: This must be called from the render thread (guarded by RHI mutex).
    /// Thread-safe via internal mutex.
    pub fn resolve(self: *TAASystem, cmd: c.VkCommandBuffer, frame_index: usize, width: u32, height: u32, jitter: [2]f32, feedback_min: f32, feedback_max: f32, global_descriptor_set: c.VkDescriptorSet) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const write_index = 1 - self.current_history_index;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = self.render_pass;
        render_pass_info.framebuffer = self.framebuffers[write_index];
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = .{ .width = width, .height = height };
        render_pass_info.clearValueCount = 0;

        c.vkCmdBeginRenderPass(cmd, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

        var viewport = c.VkViewport{ .x = 0.0, .y = 0.0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0.0, .maxDepth = 1.0 };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);

        var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);

        const read_index = self.current_history_index;
        var sets = [_]c.VkDescriptorSet{ global_descriptor_set, self.descriptor_sets[frame_index][read_index] };
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 2, &sets, 0, null);

        const pc_data = TAAPushConstants{
            .jitter_offset = jitter,
            .feedback_min = if (self.history_valid) feedback_min else 0.0,
            .feedback_max = if (self.history_valid) feedback_max else 0.0,
        };
        c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(TAAPushConstants), &pc_data);

        c.vkCmdDraw(cmd, 3, 1, 0, 0);
        c.vkCmdEndRenderPass(cmd);

        self.history_valid = true;
        self.current_history_index = write_index;
    }

    pub fn getResultView(self: *TAASystem) c.VkImageView {
        return self.history_views[self.current_history_index];
    }
};
