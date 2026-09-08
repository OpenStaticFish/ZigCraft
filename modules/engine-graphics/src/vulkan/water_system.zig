const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Utils = @import("utils.zig");
const pipeline_specialized = @import("pipeline_specialized.zig");
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;

// Match the engine's standard depth format and use an sRGB reflection target
// because the sampled result is composited directly in the water shader.
const DEPTH_FORMAT = c.VK_FORMAT_D32_SFLOAT;
const COLOR_FORMAT = c.VK_FORMAT_R16G16B16A16_SFLOAT;
const PUSH_CONSTANT_SIZE_WATER: u32 = 256;

pub const WATER_LEVEL: f32 = 64.0;

pub fn waterMultisampling(msaa_samples: u8) c.VkPipelineMultisampleStateCreateInfo {
    var state = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    state.rasterizationSamples = @import("render_pass_manager.zig").getMSAASampleCountFlag(msaa_samples);
    return state;
}

pub const WaterSystem = struct {
    allocator: std.mem.Allocator = undefined,

    reflection_image: c.VkImage = null,
    reflection_memory: c.VkDeviceMemory = null,
    reflection_view: c.VkImageView = null,

    depth_image: c.VkImage = null,
    depth_memory: c.VkDeviceMemory = null,
    depth_view: c.VkImageView = null,

    reflection_sampler: c.VkSampler = null,
    reflection_render_pass: c.VkRenderPass = null,
    reflection_framebuffer: c.VkFramebuffer = null,
    reflection_terrain_pipeline: c.VkPipeline = null,
    reflection_wireframe_pipeline: c.VkPipeline = null,
    reflection_selection_pipeline: c.VkPipeline = null,
    reflection_line_pipeline: c.VkPipeline = null,

    water_pipeline: c.VkPipeline = null,
    water_pipeline_layout: c.VkPipelineLayout = null,

    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    pass_active: bool = false,
    initialized: bool = false,
    reflection_texture_handle: rhi.TextureHandle = 0,

    pub fn init(allocator: std.mem.Allocator) WaterSystem {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WaterSystem, device: c.VkDevice) void {
        self.destroyResources(device);
    }

    pub fn destroyResources(self: *WaterSystem, device: c.VkDevice) void {
        if (self.water_pipeline) |p| c.vkDestroyPipeline(device, p, null);
        if (self.reflection_terrain_pipeline) |p| c.vkDestroyPipeline(device, p, null);
        if (self.reflection_wireframe_pipeline) |p| c.vkDestroyPipeline(device, p, null);
        if (self.reflection_selection_pipeline) |p| c.vkDestroyPipeline(device, p, null);
        if (self.reflection_line_pipeline) |p| c.vkDestroyPipeline(device, p, null);
        if (self.water_pipeline_layout) |l| c.vkDestroyPipelineLayout(device, l, null);
        if (self.reflection_framebuffer) |fb| c.vkDestroyFramebuffer(device, fb, null);
        if (self.reflection_render_pass) |rp| c.vkDestroyRenderPass(device, rp, null);
        if (self.reflection_sampler) |s| c.vkDestroySampler(device, s, null);
        if (self.reflection_view) |v| c.vkDestroyImageView(device, v, null);
        if (self.reflection_image) |i| c.vkDestroyImage(device, i, null);
        if (self.reflection_memory) |m| c.vkFreeMemory(device, m, null);
        if (self.depth_view) |v| c.vkDestroyImageView(device, v, null);
        if (self.depth_image) |i| c.vkDestroyImage(device, i, null);
        if (self.depth_memory) |m| c.vkFreeMemory(device, m, null);

        self.water_pipeline = null;
        self.water_pipeline_layout = null;
        self.reflection_terrain_pipeline = null;
        self.reflection_wireframe_pipeline = null;
        self.reflection_selection_pipeline = null;
        self.reflection_line_pipeline = null;
        self.reflection_framebuffer = null;
        self.reflection_render_pass = null;
        self.reflection_sampler = null;
        self.reflection_view = null;
        self.reflection_image = null;
        self.reflection_memory = null;
        self.depth_view = null;
        self.depth_image = null;
        self.depth_memory = null;
        self.initialized = false;
    }

    pub fn ensureResources(
        self: *WaterSystem,
        device: c.VkDevice,
        physical_device: c.VkPhysicalDevice,
        screen_width: u32,
        screen_height: u32,
        descriptor_set_layout: c.VkDescriptorSetLayout,
    ) !void {
        const half_w = screen_width / 2;
        const half_h = screen_height / 2;
        if (half_w == 0 or half_h == 0) return;

        if (self.initialized and self.extent.width == half_w and self.extent.height == half_h) return;

        self.destroyResources(device);
        errdefer self.destroyResources(device);
        self.extent = .{ .width = half_w, .height = half_h };

        var color_desc = std.mem.zeroes(c.VkAttachmentDescription);
        color_desc.format = COLOR_FORMAT;
        color_desc.samples = c.VK_SAMPLE_COUNT_1_BIT;
        color_desc.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        color_desc.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        color_desc.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        color_desc.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var depth_desc = std.mem.zeroes(c.VkAttachmentDescription);
        depth_desc.format = DEPTH_FORMAT;
        depth_desc.samples = c.VK_SAMPLE_COUNT_1_BIT;
        depth_desc.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        depth_desc.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        depth_desc.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        depth_desc.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var depth_ref = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;
        subpass.pDepthStencilAttachment = &depth_ref;

        var attachments = [_]c.VkAttachmentDescription{ color_desc, depth_desc };

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = attachments.len;
        rp_info.pAttachments = &attachments;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;

        var dependencies = [_]c.VkSubpassDependency{
            .{
                .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = 0,
                .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
            .{
                .srcSubpass = 0,
                .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
        };
        rp_info.dependencyCount = dependencies.len;
        rp_info.pDependencies = &dependencies;

        try Utils.checkVk(c.vkCreateRenderPass(device, &rp_info, null, &self.reflection_render_pass));

        {
            var img_info = std.mem.zeroes(c.VkImageCreateInfo);
            img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            img_info.imageType = c.VK_IMAGE_TYPE_2D;
            img_info.extent = .{ .width = half_w, .height = half_h, .depth = 1 };
            img_info.mipLevels = 1;
            img_info.arrayLayers = 1;
            img_info.format = COLOR_FORMAT;
            img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
            img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
            img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
            img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            try Utils.checkVk(c.vkCreateImage(device, &img_info, null, &self.reflection_image));

            var mem_reqs: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(device, self.reflection_image, &mem_reqs);
            var alloc_info = c.VkMemoryAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mem_reqs.size,
                .memoryTypeIndex = try Utils.findMemoryType(physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            };
            try Utils.checkVk(c.vkAllocateMemory(device, &alloc_info, null, &self.reflection_memory));
            try Utils.checkVk(c.vkBindImageMemory(device, self.reflection_image, self.reflection_memory, 0));

            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = self.reflection_image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = COLOR_FORMAT;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try Utils.checkVk(c.vkCreateImageView(device, &view_info, null, &self.reflection_view));
        }

        {
            var img_info = std.mem.zeroes(c.VkImageCreateInfo);
            img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            img_info.imageType = c.VK_IMAGE_TYPE_2D;
            img_info.extent = .{ .width = half_w, .height = half_h, .depth = 1 };
            img_info.mipLevels = 1;
            img_info.arrayLayers = 1;
            img_info.format = DEPTH_FORMAT;
            img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
            img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
            img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
            img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
            try Utils.checkVk(c.vkCreateImage(device, &img_info, null, &self.depth_image));

            var mem_reqs: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(device, self.depth_image, &mem_reqs);
            var alloc_info = c.VkMemoryAllocateInfo{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = mem_reqs.size,
                .memoryTypeIndex = try Utils.findMemoryType(physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            };
            try Utils.checkVk(c.vkAllocateMemory(device, &alloc_info, null, &self.depth_memory));
            try Utils.checkVk(c.vkBindImageMemory(device, self.depth_image, self.depth_memory, 0));

            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = self.depth_image;
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = DEPTH_FORMAT;
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try Utils.checkVk(c.vkCreateImageView(device, &view_info, null, &self.depth_view));
        }

        {
            var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
            sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            sampler_info.magFilter = c.VK_FILTER_LINEAR;
            sampler_info.minFilter = c.VK_FILTER_LINEAR;
            sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sampler_info.anisotropyEnable = c.VK_FALSE;
            sampler_info.maxAnisotropy = 1.0;
            sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
            sampler_info.compareEnable = c.VK_FALSE;
            try Utils.checkVk(c.vkCreateSampler(device, &sampler_info, null, &self.reflection_sampler));
        }

        {
            var fb_attachments = [_]c.VkImageView{ self.reflection_view, self.depth_view };
            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.reflection_render_pass;
            fb_info.attachmentCount = fb_attachments.len;
            fb_info.pAttachments = &fb_attachments;
            fb_info.width = half_w;
            fb_info.height = half_h;
            fb_info.layers = 1;
            try Utils.checkVk(c.vkCreateFramebuffer(device, &fb_info, null, &self.reflection_framebuffer));
        }

        {
            var push_constant = std.mem.zeroes(c.VkPushConstantRange);
            push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
            push_constant.size = PUSH_CONSTANT_SIZE_WATER;

            var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
            layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
            layout_info.setLayoutCount = 1;
            layout_info.pSetLayouts = &descriptor_set_layout;
            layout_info.pushConstantRangeCount = 1;
            layout_info.pPushConstantRanges = &push_constant;
            try Utils.checkVk(c.vkCreatePipelineLayout(device, &layout_info, null, &self.water_pipeline_layout));
        }

        self.initialized = true;
        log.log.info("WaterSystem: reflection target created ({}x{})", .{ half_w, half_h });
    }

    pub fn createWaterPipeline(self: *WaterSystem, allocator: std.mem.Allocator, device: c.VkDevice, main_render_pass: c.VkRenderPass, msaa_samples: u8) !void {
        if (self.water_pipeline_layout == null) return;
        if (main_render_pass == null) return error.InvalidRenderPass;

        const shader_registry = @import("shader_registry.zig");

        const vert_code = fs.cwd().readFileAlloc(shader_registry.WATER_VERT, allocator, 1024 * 1024) catch |err| {
            log.log.err("Failed to load water vertex shader: {s} - {}", .{ shader_registry.WATER_VERT, err });
            return err;
        };
        defer allocator.free(vert_code);
        const frag_code = fs.cwd().readFileAlloc(shader_registry.WATER_FRAG, allocator, 1024 * 1024) catch |err| {
            log.log.err("Failed to load water fragment shader: {s} - {}", .{ shader_registry.WATER_FRAG, err });
            return err;
        };
        defer allocator.free(frag_code);

        const vert_module = try Utils.createShaderModule(device, vert_code);
        defer c.vkDestroyShaderModule(device, vert_module, null);
        const frag_module = try Utils.createShaderModule(device, frag_code);
        defer c.vkDestroyShaderModule(device, frag_module, null);

        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };

        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };

        var attribute_descriptions: [6]c.VkVertexInputAttributeDescription = undefined;
        attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
        attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32_UINT, .offset = 12 };
        attribute_descriptions[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32_UINT, .offset = 16 };
        attribute_descriptions[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R16G16_SFLOAT, .offset = 20 };
        attribute_descriptions[4] = .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32_UINT, .offset = 24 };
        attribute_descriptions[5] = .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32_UINT, .offset = 28 };

        var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input.vertexBindingDescriptionCount = 1;
        vertex_input.pVertexBindingDescriptions = &binding_description;
        vertex_input.vertexAttributeDescriptionCount = 6;
        vertex_input.pVertexAttributeDescriptions = &attribute_descriptions;

        var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        rasterizer.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

        const multisampling = waterMultisampling(msaa_samples);

        var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depth_stencil.depthTestEnable = c.VK_TRUE;
        depth_stencil.depthWriteEnable = c.VK_FALSE;
        depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

        var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        color_blend_attachment.blendEnable = c.VK_TRUE;
        color_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        color_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        color_blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        color_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        color_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
        color_blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
        color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;

        var color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blending.attachmentCount = 1;
        color_blending.pAttachments = &color_blend_attachment;

        var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = 2;
        dynamic_state.pDynamicStates = &dynamic_states;

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
        pipeline_info.pColorBlendState = &color_blending;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = self.water_pipeline_layout;
        pipeline_info.renderPass = main_render_pass;
        pipeline_info.subpass = 0;

        var pipeline: c.VkPipeline = null;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline));
        errdefer c.vkDestroyPipeline(device, pipeline, null);
        if (self.water_pipeline != null) {
            try Utils.checkVk(c.vkDeviceWaitIdle(device));
            c.vkDestroyPipeline(device, self.water_pipeline, null);
        }
        self.water_pipeline = pipeline;
        log.log.info("WaterSystem: water pipeline created", .{});
    }

    pub fn createReflectionTerrainPipelines(
        self: *WaterSystem,
        allocator: std.mem.Allocator,
        device: c.VkDevice,
        main_pipeline_layout: c.VkPipelineLayout,
    ) !void {
        if (self.reflection_render_pass == null) return error.InvalidRenderPass;
        if (main_pipeline_layout == null) return error.InvalidPipelineLayout;

        const Owner = struct {
            pipeline_layout: c.VkPipelineLayout,
            terrain_pipeline: c.VkPipeline = null,
            wireframe_pipeline: c.VkPipeline = null,
            selection_pipeline: c.VkPipeline = null,
            line_pipeline: c.VkPipeline = null,
            g_pipeline: c.VkPipeline = null,
        };

        var owner = Owner{ .pipeline_layout = main_pipeline_layout };
        var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = 2;
        dynamic_state.pDynamicStates = &dynamic_states;

        var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        var rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rasterizer.lineWidth = 1.0;
        rasterizer.cullMode = c.VK_CULL_MODE_NONE;
        rasterizer.frontFace = c.VK_FRONT_FACE_CLOCKWISE;

        var multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

        var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depth_stencil.depthTestEnable = c.VK_TRUE;
        depth_stencil.depthWriteEnable = c.VK_TRUE;
        depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

        var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;

        var color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blending.attachmentCount = 1;
        color_blending.pAttachments = &color_blend_attachment;

        try pipeline_specialized.createTerrainPipeline(
            &owner,
            allocator,
            device,
            self.reflection_render_pass,
            &viewport_state,
            &dynamic_state,
            &input_assembly,
            &rasterizer,
            &multisampling,
            &depth_stencil,
            &color_blending,
            c.VK_SAMPLE_COUNT_1_BIT,
            null,
        );

        self.reflection_terrain_pipeline = owner.terrain_pipeline;
        self.reflection_wireframe_pipeline = owner.wireframe_pipeline;
        self.reflection_selection_pipeline = owner.selection_pipeline;
        self.reflection_line_pipeline = owner.line_pipeline;
    }

    pub fn beginReflectionPass(self: *WaterSystem, command_buffer: c.VkCommandBuffer) void {
        if (command_buffer == null or self.extent.width == 0 or self.extent.height == 0) return;
        if (self.reflection_render_pass == null or self.reflection_framebuffer == null) return;

        self.pass_active = true;

        var clear_values = [_]c.VkClearValue{ undefined, undefined };
        @memset(std.mem.asBytes(&clear_values[0]), 0);
        clear_values[0].color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } };
        @memset(std.mem.asBytes(&clear_values[1]), 0);
        clear_values[1].depthStencil = .{ .depth = 0.0, .stencil = 0 };

        var rp_info: c.VkRenderPassBeginInfo = undefined;
        @memset(std.mem.asBytes(&rp_info), 0);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rp_info.renderPass = self.reflection_render_pass;
        rp_info.framebuffer = self.reflection_framebuffer;
        rp_info.renderArea.offset = .{ .x = 0, .y = 0 };
        rp_info.renderArea.extent = self.extent;
        rp_info.clearValueCount = clear_values.len;
        rp_info.pClearValues = &clear_values;

        c.vkCmdBeginRenderPass(command_buffer, &rp_info, c.VK_SUBPASS_CONTENTS_INLINE);

        var viewport: c.VkViewport = undefined;
        @memset(std.mem.asBytes(&viewport), 0);
        viewport.x = 0.0;
        viewport.y = 0.0;
        viewport.width = @floatFromInt(self.extent.width);
        viewport.height = @floatFromInt(self.extent.height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        var scissor: c.VkRect2D = undefined;
        @memset(std.mem.asBytes(&scissor), 0);
        scissor.offset = .{ .x = 0, .y = 0 };
        scissor.extent = self.extent;
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    }

    pub fn endReflectionPass(self: *WaterSystem, command_buffer: c.VkCommandBuffer) void {
        if (!self.pass_active) return;
        c.vkCmdEndRenderPass(command_buffer);
        self.pass_active = false;
    }

    pub fn getReflectionTextureHandle(self: *WaterSystem) rhi.TextureHandle {
        return self.reflection_texture_handle;
    }

    pub fn computeReflectedViewProj(_: *WaterSystem, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        const reflected_offset_y = 2.0 * (WATER_LEVEL - camera_pos.y);
        const reflect_matrix = Mat4.translate(Vec3.init(0.0, reflected_offset_y, 0.0)).multiply(Mat4.scale(Vec3.init(1.0, -1.0, 1.0)));
        const reflected_view = view.multiply(reflect_matrix);
        return proj.multiply(reflected_view);
    }
};
