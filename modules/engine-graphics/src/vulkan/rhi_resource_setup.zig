const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Utils = @import("utils.zig");
const shader_registry = @import("shader_registry.zig");
const build_options = @import("engine_graphics_options");
const bindings = @import("descriptor_bindings.zig");
const lifecycle = @import("rhi_resource_lifecycle.zig");
const final_composition = @import("final_composition.zig");

const DEPTH_FORMAT = c.VK_FORMAT_D32_SFLOAT;
const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;

pub fn createSwapchainUIResources(ctx: anytype) !void {
    const vk = ctx.vulkan_device.vk_device;

    lifecycle.destroySwapchainUIResources(ctx);
    errdefer lifecycle.destroySwapchainUIResources(ctx);

    try ctx.render_pass_manager.createUISwapchainRenderPass(vk, ctx.swapchain.getImageFormat(), final_composition.displayLayout(ctx.swapchain.skip_present));
    try ctx.render_pass_manager.createUISwapchainFramebuffers(vk, ctx.allocator, ctx.swapchain.getExtent(), ctx.swapchain.getImageViews());
}

pub fn createShadowResources(ctx: anytype) !void {
    const vk = ctx.vulkan_device.vk_device;
    errdefer {
        for (&ctx.shadow_runtime.shadow_map_handles) |*handle| {
            if (handle.* != 0) ctx.resources.destroyTexture(handle.*);
            handle.* = 0;
        }
        ctx.shadow_system.deinit(vk);
    }
    const shadow_res = ctx.shadow_runtime.shadow_resolution;
    var shadow_depth_desc = std.mem.zeroes(c.VkAttachmentDescription);
    shadow_depth_desc.format = DEPTH_FORMAT;
    shadow_depth_desc.samples = c.VK_SAMPLE_COUNT_1_BIT;
    shadow_depth_desc.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    shadow_depth_desc.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    shadow_depth_desc.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    shadow_depth_desc.finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
    var shadow_depth_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    var shadow_subpass = std.mem.zeroes(c.VkSubpassDescription);
    shadow_subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    shadow_subpass.pDepthStencilAttachment = &shadow_depth_ref;
    var shadow_rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
    shadow_rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    shadow_rp_info.attachmentCount = 1;
    shadow_rp_info.pAttachments = &shadow_depth_desc;
    shadow_rp_info.subpassCount = 1;
    shadow_rp_info.pSubpasses = &shadow_subpass;

    var shadow_dependencies = [_]c.VkSubpassDependency{
        .{ .srcSubpass = c.VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT, .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT, .dstAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT, .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT },
        .{ .srcSubpass = 0, .dstSubpass = c.VK_SUBPASS_EXTERNAL, .srcStageMask = c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, .srcAccessMask = c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT, .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT },
    };
    shadow_rp_info.dependencyCount = 2;
    shadow_rp_info.pDependencies = &shadow_dependencies;

    try Utils.checkVk(c.vkCreateRenderPass(ctx.vulkan_device.vk_device, &shadow_rp_info, null, &ctx.shadow_system.shadow_render_pass));

    ctx.shadow_system.shadow_extent = .{ .width = shadow_res, .height = shadow_res };

    var shadow_img_info = std.mem.zeroes(c.VkImageCreateInfo);
    shadow_img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    shadow_img_info.imageType = c.VK_IMAGE_TYPE_2D;
    shadow_img_info.extent = .{ .width = shadow_res, .height = shadow_res, .depth = 1 };
    shadow_img_info.mipLevels = 1;
    shadow_img_info.arrayLayers = rhi.SHADOW_CASCADE_COUNT;
    shadow_img_info.format = DEPTH_FORMAT;
    shadow_img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    shadow_img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    shadow_img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &shadow_img_info, null, &ctx.shadow_system.shadow_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(vk, ctx.shadow_system.shadow_image, &mem_reqs);
    var alloc_info = c.VkMemoryAllocateInfo{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mem_reqs.size, .memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.shadow_system.shadow_image_memory));
    try Utils.checkVk(c.vkBindImageMemory(vk, ctx.shadow_system.shadow_image, ctx.shadow_system.shadow_image_memory, 0));

    var array_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    array_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    array_view_info.image = ctx.shadow_system.shadow_image;
    array_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    array_view_info.format = DEPTH_FORMAT;
    array_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = rhi.SHADOW_CASCADE_COUNT };
    try Utils.checkVk(c.vkCreateImageView(vk, &array_view_info, null, &ctx.shadow_system.shadow_image_view));

    {
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        sampler_info.anisotropyEnable = c.VK_FALSE;
        sampler_info.maxAnisotropy = 1.0;
        sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
        sampler_info.compareEnable = c.VK_TRUE;
        sampler_info.compareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &ctx.shadow_system.shadow_sampler));

        var regular_sampler_info = sampler_info;
        regular_sampler_info.compareEnable = c.VK_FALSE;
        regular_sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
        try Utils.checkVk(c.vkCreateSampler(vk, &regular_sampler_info, null, &ctx.shadow_system.shadow_sampler_regular));
    }

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        var layer_view: c.VkImageView = null;
        var layer_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        layer_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        layer_view_info.image = ctx.shadow_system.shadow_image;
        layer_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        layer_view_info.format = DEPTH_FORMAT;
        layer_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = @intCast(si), .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &layer_view_info, null, &layer_view));
        ctx.shadow_system.shadow_image_views[si] = layer_view;

        ctx.shadow_runtime.shadow_map_handles[si] = try ctx.resources.registerExternalTexture(shadow_res, shadow_res, .depth, layer_view, ctx.shadow_system.shadow_sampler_regular);

        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = ctx.shadow_system.shadow_render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &ctx.shadow_system.shadow_image_views[si];
        fb_info.width = shadow_res;
        fb_info.height = shadow_res;
        fb_info.layers = 1;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &ctx.shadow_system.shadow_framebuffers[si]));
        ctx.shadow_system.shadow_image_layouts[si] = c.VK_IMAGE_LAYOUT_UNDEFINED;
    }

    const shadow_vert = try fs.cwd().readFileAlloc(shader_registry.SHADOW_VERT, ctx.allocator, 1024 * 1024);
    defer ctx.allocator.free(shadow_vert);
    const shadow_frag = try fs.cwd().readFileAlloc(shader_registry.SHADOW_FRAG, ctx.allocator, 1024 * 1024);
    defer ctx.allocator.free(shadow_frag);

    const shadow_vert_module = try Utils.createShaderModule(vk, shadow_vert);
    defer c.vkDestroyShaderModule(vk, shadow_vert_module, null);
    const shadow_frag_module = try Utils.createShaderModule(vk, shadow_frag);
    defer c.vkDestroyShaderModule(vk, shadow_frag_module, null);

    var shadow_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = shadow_vert_module, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = shadow_frag_module, .pName = "main" },
    };

    const shadow_binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    var shadow_attrs: [4]c.VkVertexInputAttributeDescription = undefined;
    shadow_attrs[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = 0 };
    shadow_attrs[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32_UINT, .offset = 16 };
    shadow_attrs[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R16G16_SFLOAT, .offset = 20 };
    shadow_attrs[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R32_UINT, .offset = 24 };

    var shadow_vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    shadow_vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    shadow_vertex_input.vertexBindingDescriptionCount = 1;
    shadow_vertex_input.pVertexBindingDescriptions = &shadow_binding;
    shadow_vertex_input.vertexAttributeDescriptionCount = 4;
    shadow_vertex_input.pVertexAttributeDescriptions = &shadow_attrs[0];

    var shadow_input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    shadow_input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    shadow_input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    var shadow_rasterizer = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    shadow_rasterizer.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    shadow_rasterizer.lineWidth = 1.0;
    shadow_rasterizer.cullMode = c.VK_CULL_MODE_NONE;
    shadow_rasterizer.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
    shadow_rasterizer.depthBiasEnable = c.VK_TRUE;

    var shadow_multisampling = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    shadow_multisampling.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    shadow_multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var shadow_depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
    shadow_depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    shadow_depth_stencil.depthTestEnable = c.VK_TRUE;
    shadow_depth_stencil.depthWriteEnable = c.VK_TRUE;
    shadow_depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

    var shadow_color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    shadow_color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    shadow_color_blend.attachmentCount = 0;
    shadow_color_blend.pAttachments = null;

    const shadow_dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR, c.VK_DYNAMIC_STATE_DEPTH_BIAS };
    var shadow_dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    shadow_dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    shadow_dynamic_state.dynamicStateCount = shadow_dynamic_states.len;
    shadow_dynamic_state.pDynamicStates = &shadow_dynamic_states;

    var shadow_viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    shadow_viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    shadow_viewport_state.viewportCount = 1;
    shadow_viewport_state.scissorCount = 1;

    var shadow_pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    shadow_pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    shadow_pipeline_info.stageCount = shadow_stages.len;
    shadow_pipeline_info.pStages = &shadow_stages[0];
    shadow_pipeline_info.pVertexInputState = &shadow_vertex_input;
    shadow_pipeline_info.pInputAssemblyState = &shadow_input_assembly;
    shadow_pipeline_info.pViewportState = &shadow_viewport_state;
    shadow_pipeline_info.pRasterizationState = &shadow_rasterizer;
    shadow_pipeline_info.pMultisampleState = &shadow_multisampling;
    shadow_pipeline_info.pDepthStencilState = &shadow_depth_stencil;
    shadow_pipeline_info.pColorBlendState = &shadow_color_blend;
    shadow_pipeline_info.pDynamicState = &shadow_dynamic_state;
    shadow_pipeline_info.layout = ctx.pipeline_manager.pipeline_layout;
    shadow_pipeline_info.renderPass = ctx.shadow_system.shadow_render_pass;
    shadow_pipeline_info.subpass = 0;

    var new_pipeline: c.VkPipeline = null;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &shadow_pipeline_info, null, &new_pipeline));

    if (ctx.shadow_system.shadow_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.shadow_system.shadow_pipeline, null);
    }
    ctx.shadow_system.shadow_pipeline = new_pipeline;
}

pub fn createGPassResources(ctx: anytype) !void {
    lifecycle.destroyGPassResources(ctx);
    errdefer lifecycle.destroyGPassResources(ctx);
    const normal_format = c.VK_FORMAT_R8G8B8A8_UNORM;
    const velocity_format = c.VK_FORMAT_R16G16_SFLOAT;

    try ctx.render_pass_manager.createGPassRenderPass(ctx.vulkan_device.vk_device);

    const vk = ctx.vulkan_device.vk_device;
    const extent = ctx.swapchain.getExtent();

    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = normal_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.gpass.g_normal_image));
        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.gpass.g_normal_image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.gpass.g_normal_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.gpass.g_normal_image, ctx.gpass.g_normal_memory, 0));
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.gpass.g_normal_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = normal_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.gpass.g_normal_view));
    }

    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = velocity_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.velocity.velocity_image));
        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.velocity.velocity_image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.velocity.velocity_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.velocity.velocity_image, ctx.velocity.velocity_memory, 0));
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.velocity.velocity_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = velocity_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.velocity.velocity_view));
    }

    {
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = DEPTH_FORMAT;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &ctx.gpass.g_depth_image));
        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, ctx.gpass.g_depth_image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &ctx.gpass.g_depth_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, ctx.gpass.g_depth_image, ctx.gpass.g_depth_memory, 0));
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = ctx.gpass.g_depth_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = DEPTH_FORMAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &ctx.gpass.g_depth_view));
    }

    try ctx.render_pass_manager.createGPassFramebuffer(vk, extent, ctx.gpass.g_normal_view, ctx.velocity.velocity_view, ctx.gpass.g_depth_view);

    const g_images = [_]c.VkImage{ ctx.gpass.g_normal_image, ctx.velocity.velocity_image };
    try lifecycle.transitionImagesToShaderRead(ctx, &g_images, false, 1);
    var depth_sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    depth_sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    depth_sampler_info.magFilter = c.VK_FILTER_NEAREST;
    depth_sampler_info.minFilter = c.VK_FILTER_NEAREST;
    depth_sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
    depth_sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    depth_sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    depth_sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    depth_sampler_info.borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK;
    depth_sampler_info.compareEnable = c.VK_FALSE;
    var depth_sampler: c.VkSampler = null;
    try Utils.checkVk(c.vkCreateSampler(vk, &depth_sampler_info, null, &depth_sampler));
    ctx.gpass.g_depth_sampler = depth_sampler;

    ctx.gpass.g_depth_handle = try ctx.resources.registerExternalTexture(
        extent.width,
        extent.height,
        .depth,
        ctx.gpass.g_depth_view,
        depth_sampler,
    );

    ctx.gpass.g_pass_extent = extent;

    // Depth pyramid samples the G-Pass depth view, so keep it in sync here.
    if (ctx.gpass.g_depth_view != null) {
        ctx.depth_pyramid.init(
            &ctx.vulkan_device,
            ctx.allocator,
            ctx.gpass.g_depth_view,
            extent.width,
            extent.height,
        ) catch |err| {
            log.log.warn("DepthPyramidSystem init failed (non-fatal): {}", .{err});
        };
    }

    log.log.debug("G-Pass resources created ({}x{}) with velocity buffer", .{ extent.width, extent.height });
}

pub fn createSSAOResources(ctx: anytype) !void {
    const extent = ctx.swapchain.getExtent();
    try ctx.ssao_system.init(
        &ctx.vulkan_device,
        ctx.allocator,
        ctx.descriptors.descriptor_pool,
        ctx.frames.command_pool,
        extent.width,
        extent.height,
        ctx.gpass.g_normal_view,
        ctx.gpass.g_depth_view,
        ctx.runtime.recovering,
    );

    ctx.draw.bound_ssao_handle = try ctx.resources.registerNativeTexture(
        ctx.ssao_system.blur_image,
        ctx.ssao_system.blur_view,
        ctx.ssao_system.sampler,
        extent.width,
        extent.height,
        .red,
    );

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        var main_ssao_info = c.VkDescriptorImageInfo{
            .sampler = ctx.ssao_system.sampler,
            .imageView = ctx.ssao_system.blur_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        var main_ssao_write = std.mem.zeroes(c.VkWriteDescriptorSet);
        main_ssao_write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        main_ssao_write.dstSet = ctx.descriptors.descriptor_sets[i];
        main_ssao_write.dstBinding = bindings.SSAO_TEXTURE;
        main_ssao_write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        main_ssao_write.descriptorCount = 1;
        main_ssao_write.pImageInfo = &main_ssao_info;
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &main_ssao_write, 0, null);
    }

    const ssao_images = [_]c.VkImage{ ctx.ssao_system.image, ctx.ssao_system.blur_image };
    try lifecycle.transitionImagesToShaderRead(ctx, &ssao_images, false, 1);
}

pub fn createTAAResources(ctx: anytype) !void {
    try ctx.taa.ensureResources(
        ctx.vulkan_device.vk_device,
        ctx.allocator,
        ctx.descriptors.descriptor_pool,
        &ctx.resources,
        ctx.swapchain.getExtent(),
    );
}

pub fn createWaterResources(ctx: anytype) !void {
    const extent = ctx.swapchain.getExtent();
    if (extent.width < 2 or extent.height < 2) return error.InvalidExtent;

    if (ctx.water_system.reflection_texture_handle != 0) {
        ctx.resources.destroyTexture(ctx.water_system.reflection_texture_handle);
        ctx.water_system.reflection_texture_handle = 0;
    }
    ctx.water_system.destroyResources(ctx.vulkan_device.vk_device);
    errdefer ctx.water_system.destroyResources(ctx.vulkan_device.vk_device);
    try ctx.water_system.ensureResources(
        ctx.vulkan_device.vk_device,
        ctx.vulkan_device.physical_device,
        extent.width,
        extent.height,
        ctx.descriptors.descriptor_set_layout,
    );

    ctx.water_system.reflection_texture_handle = try ctx.resources.registerExternalTexture(
        ctx.water_system.extent.width,
        ctx.water_system.extent.height,
        .rgba,
        ctx.water_system.reflection_view,
        ctx.water_system.reflection_sampler,
    );
}

pub fn createPostProcessResources(ctx: anytype) !void {
    const vk = ctx.vulkan_device.vk_device;

    try ctx.render_pass_manager.createPostProcessRenderPass(vk, ctx.swapchain.getImageFormat(), final_composition.displayLayout(ctx.swapchain.skip_present));

    const global_uniform_size: usize = @intCast(ctx.descriptors.global_ubos[0].size);
    try ctx.post_process.init(
        vk,
        ctx.allocator,
        ctx.descriptors.descriptor_pool,
        ctx.render_pass_manager.post_process_render_pass,
        ctx.hdr.hdr_view,
        ctx.descriptors.global_ubos,
        global_uniform_size,
    );

    if (ctx.post_process.lut_texture == 0) {
        ctx.post_process.lut_texture = try createNeutralLUT3D(ctx);
    }
    updatePostProcessLUTDescriptor(ctx);

    try ctx.render_pass_manager.createPostProcessFramebuffers(vk, ctx.allocator, ctx.swapchain.getExtent(), ctx.swapchain.getImageViews());
}

pub fn createUpscaleResources(ctx: anytype) !void {
    const vk = ctx.vulkan_device.vk_device;
    const extent = ctx.swapchain.getExtent();
    if (extent.width == 0 or extent.height == 0) return;

    lifecycle.destroyUpscaleResources(ctx);

    const format = c.VK_FORMAT_R32G32B32A32_SFLOAT;
    const dr = &ctx.dynamic_resolution;

    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    try Utils.checkVk(c.vkCreateImage(vk, &image_info, null, &dr.upscale_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(vk, dr.upscale_image, &mem_reqs);
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &dr.upscale_memory));
    try Utils.checkVk(c.vkBindImageMemory(vk, dr.upscale_image, dr.upscale_memory, 0));

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = dr.upscale_image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = format;
    view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &dr.upscale_view));

    dr.upscale_extent = extent;

    const images = [_]c.VkImage{dr.upscale_image};
    try lifecycle.transitionImagesToShaderRead(ctx, &images, false, 1);
}

/// Generate a 32x32x32 identity LUT where each texel maps to itself: color(r,g,b) = (r,g,b).
fn createNeutralLUT3D(ctx: anytype) !rhi.TextureHandle {
    const LUT_SIZE: u32 = 32;
    const total = LUT_SIZE * LUT_SIZE * LUT_SIZE;
    var data = try ctx.allocator.alloc(u8, total * 4);
    defer ctx.allocator.free(data);

    var i: u32 = 0;
    var z: u32 = 0;
    while (z < LUT_SIZE) : (z += 1) {
        var y: u32 = 0;
        while (y < LUT_SIZE) : (y += 1) {
            var x: u32 = 0;
            while (x < LUT_SIZE) : (x += 1) {
                data[i + 0] = @intCast((x * 255 + (LUT_SIZE - 1) / 2) / (LUT_SIZE - 1));
                data[i + 1] = @intCast((y * 255 + (LUT_SIZE - 1) / 2) / (LUT_SIZE - 1));
                data[i + 2] = @intCast((z * 255 + (LUT_SIZE - 1) / 2) / (LUT_SIZE - 1));
                data[i + 3] = 255;
                i += 4;
            }
        }
    }

    const handle = try ctx.resources.createTexture3D(LUT_SIZE, LUT_SIZE, LUT_SIZE, .rgba, .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
        .generate_mipmaps = false,
        .is_render_target = false,
    }, data);
    return handle;
}

fn updatePostProcessLUTDescriptor(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.post_process.lut_texture == 0) return;
    const tex = ctx.resources.textures.get(ctx.post_process.lut_texture) orelse return;
    ctx.post_process.updateLUTDescriptor(vk, tex.view, tex.sampler);
}

pub fn updatePostProcessDescriptorsWithBloom(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    const bloom_view = if (ctx.bloom.mip_views[0] != null) ctx.bloom.mip_views[0] else return;
    const sampler = if (ctx.bloom.sampler != null) ctx.bloom.sampler else ctx.post_process.sampler;
    ctx.post_process.updateBloomDescriptors(vk, bloom_view, sampler);
}

pub fn createMainFramebuffers(ctx: anytype) !void {
    if (ctx.render_pass_manager.hdr_render_pass == null) return error.RenderPassNotInitialized;

    try ctx.render_pass_manager.createMainFramebuffer(
        ctx.vulkan_device.vk_device,
        ctx.swapchain.getExtent(),
        ctx.hdr.hdr_view,
        ctx.hdr.hdr_msaa_view,
        ctx.swapchain.swapchain.depth_image_view,
        ctx.options.msaa_samples,
    );
}

pub fn destroyMainRenderPassAndPipelines(ctx: anytype) void {
    if (ctx.vulkan_device.vk_device == null) return;
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    if (ctx.render_pass_manager.main_framebuffer != null) {
        c.vkDestroyFramebuffer(ctx.vulkan_device.vk_device, ctx.render_pass_manager.main_framebuffer, null);
        ctx.render_pass_manager.main_framebuffer = null;
    }

    if (ctx.pipeline_manager.terrain_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.terrain_pipeline, null);
        ctx.pipeline_manager.terrain_pipeline = null;
    }
    if (ctx.pipeline_manager.wireframe_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.wireframe_pipeline, null);
        ctx.pipeline_manager.wireframe_pipeline = null;
    }
    if (ctx.pipeline_manager.selection_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.selection_pipeline, null);
        ctx.pipeline_manager.selection_pipeline = null;
    }
    if (ctx.pipeline_manager.line_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.line_pipeline, null);
        ctx.pipeline_manager.line_pipeline = null;
    }
    if (ctx.pipeline_manager.sky_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.sky_pipeline, null);
        ctx.pipeline_manager.sky_pipeline = null;
    }
    if (ctx.pipeline_manager.ui_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.ui_pipeline, null);
        ctx.pipeline_manager.ui_pipeline = null;
    }
    if (ctx.pipeline_manager.ui_tex_pipeline != null) {
        c.vkDestroyPipeline(ctx.vulkan_device.vk_device, ctx.pipeline_manager.ui_tex_pipeline, null);
        ctx.pipeline_manager.ui_tex_pipeline = null;
    }
    if (comptime build_options.debug_shadows) {
        if (ctx.debug_shadow.pipeline) |pipeline| c.vkDestroyPipeline(ctx.vulkan_device.vk_device, pipeline, null);
        ctx.debug_shadow.pipeline = null;
    }

    if (ctx.render_pass_manager.hdr_render_pass != null) {
        c.vkDestroyRenderPass(ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, null);
        ctx.render_pass_manager.hdr_render_pass = null;
    }
}
