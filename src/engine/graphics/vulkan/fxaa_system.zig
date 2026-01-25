const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const shader_registry = @import("shader_registry.zig");

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

    pub fn init(self: *FXAASystem, device: *const VulkanDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool, extent: c.VkExtent2D, format: c.VkFormat, sampler: c.VkSampler, swapchain_views: []const c.VkImageView) !void {
        self.deinit(device.vk_device, allocator, descriptor_pool);
        const vk = device.vk_device;

        // Ensure we clean up if initialization fails halfway
        errdefer self.deinit(vk, allocator, descriptor_pool);

        // 1. Create intermediate LDR texture for FXAA input
        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = format;
        image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        try Utils.checkVk(c.vkCreateImage(vk, &image_info, null, &self.input_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, self.input_image, &mem_reqs);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.input_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, self.input_image, self.input_memory, 0));

        // 2. Render Pass
        var color_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        color_attachment.format = format;
        color_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
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

        // 2.2 Create image view for FXAA input
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.input_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };

        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.input_view));

        // 2.5. Post-process to FXAA pass
        {
            var pp_to_fxaa_attachment = color_attachment;
            pp_to_fxaa_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
            pp_to_fxaa_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            pp_to_fxaa_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            var pp_rp_info = rp_info;
            pp_rp_info.pAttachments = &pp_to_fxaa_attachment;

            try Utils.checkVk(c.vkCreateRenderPass(vk, &pp_rp_info, null, &self.post_process_to_fxaa_render_pass));

            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.post_process_to_fxaa_render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &self.input_view;
            fb_info.width = extent.width;
            fb_info.height = extent.height;
            fb_info.layers = 1;

            try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &self.post_process_to_fxaa_framebuffer));
        }

        // 3. Descriptor Set Layout
        var dsl_binding = c.VkDescriptorSetLayoutBinding{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 1;
        layout_info.pBindings = &dsl_binding;

        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        // 4. Pipeline Layout
        var push_constant_range = std.mem.zeroes(c.VkPushConstantRange);
        push_constant_range.stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        push_constant_range.offset = 0;
        push_constant_range.size = @sizeOf(FXAAPushConstants);

        var pipe_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipe_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipe_layout_info.setLayoutCount = 1;
        pipe_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipe_layout_info.pushConstantRangeCount = 1;
        pipe_layout_info.pPushConstantRanges = &push_constant_range;

        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipe_layout_info, null, &self.pipeline_layout));

        // 5. Shaders & Pipeline
        const vert_code = try std.fs.cwd().readFileAlloc(shader_registry.FXAA_VERT, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc(shader_registry.FXAA_FRAG, allocator, @enumFromInt(1024 * 1024));
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
        rasterizer.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

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
        dynamic_state.dynamicStateCount = 2;
        dynamic_state.pDynamicStates = &dynamic_states;

        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &stages[0];
        pipe_info.pVertexInputState = &vertex_input;
        pipe_info.pInputAssemblyState = &input_assembly;
        pipe_info.pViewportState = &viewport_state;
        pipe_info.pRasterizationState = &rasterizer;
        pipe_info.pMultisampleState = &multisampling;
        pipe_info.pColorBlendState = &color_blending;
        pipe_info.pDynamicState = &dynamic_state;
        pipe_info.layout = self.pipeline_layout;
        pipe_info.renderPass = self.render_pass;
        pipe_info.subpass = 0;

        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.pipeline));

        // 6. Framebuffers (for swapchain images)
        try self.framebuffers.resize(allocator, swapchain_views.len);
        for (0..swapchain_views.len) |i| {
            var fb_info_swap = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info_swap.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info_swap.renderPass = self.render_pass;
            fb_info_swap.attachmentCount = 1;
            fb_info_swap.pAttachments = &swapchain_views[i];
            fb_info_swap.width = extent.width;
            fb_info_swap.height = extent.height;
            fb_info_swap.layers = 1;

            try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info_swap, null, &self.framebuffers.items[i]));
        }

        // 7. Descriptor Sets
        var layouts: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout = undefined;
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| layouts[i] = self.descriptor_set_layout;

        var alloc_info_ds = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info_ds.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info_ds.descriptorPool = descriptor_pool;
        alloc_info_ds.descriptorSetCount = rhi.MAX_FRAMES_IN_FLIGHT;
        alloc_info_ds.pSetLayouts = &layouts[0];

        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info_ds, &self.descriptor_sets[0]));

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            var image_info_ds = c.VkDescriptorImageInfo{
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .imageView = self.input_view,
                .sampler = sampler,
            };

            var writes = [_]c.VkWriteDescriptorSet{
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 0,
                    .dstArrayElement = 0,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    .descriptorCount = 1,
                    .pImageInfo = &image_info_ds,
                },
            };
            c.vkUpdateDescriptorSets(vk, 1, &writes[0], 0, null);
        }
    }

    pub fn deinit(self: *FXAASystem, device: c.VkDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool) void {
        if (self.pipeline != null) {
            c.vkDestroyPipeline(device, self.pipeline, null);
            self.pipeline = null;
        }
        if (self.pipeline_layout != null) {
            c.vkDestroyPipelineLayout(device, self.pipeline_layout, null);
            self.pipeline_layout = null;
        }
        if (self.descriptor_set_layout != null) {
            c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
            self.descriptor_set_layout = null;
        }

        if (descriptor_pool != null) {
            for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
                if (self.descriptor_sets[i] != null) {
                    _ = c.vkFreeDescriptorSets(device, descriptor_pool, 1, &self.descriptor_sets[i]);
                    self.descriptor_sets[i] = null;
                }
            }
        }

        for (self.framebuffers.items) |fb| {
            if (fb != null) c.vkDestroyFramebuffer(device, fb, null);
        }
        self.framebuffers.deinit(allocator);
        self.framebuffers = .empty;

        if (self.render_pass != null) {
            c.vkDestroyRenderPass(device, self.render_pass, null);
            self.render_pass = null;
        }
        if (self.post_process_to_fxaa_render_pass != null) {
            c.vkDestroyRenderPass(device, self.post_process_to_fxaa_render_pass, null);
            self.post_process_to_fxaa_render_pass = null;
        }
        if (self.post_process_to_fxaa_framebuffer != null) {
            c.vkDestroyFramebuffer(device, self.post_process_to_fxaa_framebuffer, null);
            self.post_process_to_fxaa_framebuffer = null;
        }

        if (self.input_view != null) {
            c.vkDestroyImageView(device, self.input_view, null);
            self.input_view = null;
        }
        if (self.input_image != null) {
            c.vkDestroyImage(device, self.input_image, null);
            self.input_image = null;
        }
        if (self.input_memory != null) {
            c.vkFreeMemory(device, self.input_memory, null);
            self.input_memory = null;
        }

        self.pass_active = false;
        self.enabled = false;
    }
};
