const std = @import("std");
const build_options = @import("engine_graphics_options");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Utils = @import("utils.zig");
const shader_registry = @import("shader_registry.zig");

pub fn terrainRasterizer(base: c.VkPipelineRasterizationStateCreateInfo, variant: enum { solid, wireframe, selection, line }) c.VkPipelineRasterizationStateCreateInfo {
    var result = base;
    result.polygonMode = if (variant == .wireframe) c.VK_POLYGON_MODE_LINE else c.VK_POLYGON_MODE_FILL;
    if (variant != .solid) result.cullMode = c.VK_CULL_MODE_NONE;
    return result;
}

fn loadShaderModule(
    allocator: std.mem.Allocator,
    vk_device: c.VkDevice,
    path: []const u8,
) !c.VkShaderModule {
    const code = try fs.cwd().readFileAlloc(path, allocator, 1024 * 1024);
    defer allocator.free(code);
    return try Utils.createShaderModule(vk_device, code);
}

fn loadShaderPair(
    allocator: std.mem.Allocator,
    vk_device: c.VkDevice,
    vert_path: []const u8,
    frag_path: []const u8,
) !struct { vert: c.VkShaderModule, frag: c.VkShaderModule } {
    const vert = try loadShaderModule(allocator, vk_device, vert_path);
    errdefer c.vkDestroyShaderModule(vk_device, vert, null);
    const frag = try loadShaderModule(allocator, vk_device, frag_path);
    return .{ .vert = vert, .frag = frag };
}

pub fn createTerrainPipeline(
    self: anytype,
    allocator: std.mem.Allocator,
    vk_device: c.VkDevice,
    hdr_render_pass: c.VkRenderPass,
    viewport_state: *const c.VkPipelineViewportStateCreateInfo,
    dynamic_state: *const c.VkPipelineDynamicStateCreateInfo,
    input_assembly: *const c.VkPipelineInputAssemblyStateCreateInfo,
    rasterizer: *const c.VkPipelineRasterizationStateCreateInfo,
    multisampling: *const c.VkPipelineMultisampleStateCreateInfo,
    depth_stencil: *const c.VkPipelineDepthStencilStateCreateInfo,
    color_blending: *const c.VkPipelineColorBlendStateCreateInfo,
    _sample_count: c.VkSampleCountFlagBits,
    g_render_pass: c.VkRenderPass,
) !void {
    _ = _sample_count;
    const vert_module = try loadShaderModule(allocator, vk_device, shader_registry.TERRAIN_VERT);
    defer c.vkDestroyShaderModule(vk_device, vert_module, null);
    const frag_module = try loadShaderModule(allocator, vk_device, shader_registry.TERRAIN_FRAG);
    defer c.vkDestroyShaderModule(vk_device, frag_module, null);

    var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
    };

    const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };

    var attribute_descriptions: [6]c.VkVertexInputAttributeDescription = undefined;
    attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(rhi.Vertex, "pos") };
    attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(rhi.Vertex, "color") };
    attribute_descriptions[2] = .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(rhi.Vertex, "normal") };
    attribute_descriptions[3] = .{ .binding = 0, .location = 3, .format = c.VK_FORMAT_R16G16_SFLOAT, .offset = @offsetOf(rhi.Vertex, "uv") };
    attribute_descriptions[4] = .{ .binding = 0, .location = 4, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(rhi.Vertex, "packed_meta") };
    attribute_descriptions[5] = .{ .binding = 0, .location = 5, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(rhi.Vertex, "blocklight") };

    var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input_info.vertexBindingDescriptionCount = 1;
    vertex_input_info.pVertexBindingDescriptions = &binding_description;
    vertex_input_info.vertexAttributeDescriptionCount = 6;
    vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];

    var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = 2;
    pipeline_info.pStages = &shader_stages[0];
    pipeline_info.pVertexInputState = &vertex_input_info;
    pipeline_info.pInputAssemblyState = input_assembly;
    pipeline_info.pViewportState = viewport_state;
    pipeline_info.pRasterizationState = rasterizer;
    pipeline_info.pMultisampleState = multisampling;
    pipeline_info.pDepthStencilState = depth_stencil;
    pipeline_info.pColorBlendState = color_blending;
    pipeline_info.pDynamicState = dynamic_state;
    pipeline_info.layout = self.pipeline_layout;
    pipeline_info.renderPass = hdr_render_pass;
    pipeline_info.subpass = 0;

    errdefer {
        inline for (.{ "terrain_pipeline", "wireframe_pipeline", "selection_pipeline", "line_pipeline", "g_pipeline" }) |name| {
            if (@field(self, name) != null) c.vkDestroyPipeline(vk_device, @field(self, name), null);
            @field(self, name) = null;
        }
    }
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.terrain_pipeline));

    const wireframe_rasterizer = terrainRasterizer(rasterizer.*, .wireframe);
    var wireframe_pipeline_info = pipeline_info;
    wireframe_pipeline_info.pRasterizationState = &wireframe_rasterizer;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &wireframe_pipeline_info, null, &self.wireframe_pipeline));

    const selection_rasterizer = terrainRasterizer(rasterizer.*, .selection);
    var selection_pipeline_info = pipeline_info;
    selection_pipeline_info.pRasterizationState = &selection_rasterizer;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &selection_pipeline_info, null, &self.selection_pipeline));

    var line_input_assembly = input_assembly.*;
    line_input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
    const line_rasterizer = terrainRasterizer(rasterizer.*, .line);
    var line_pipeline_info = pipeline_info;
    line_pipeline_info.pInputAssemblyState = &line_input_assembly;
    line_pipeline_info.pRasterizationState = &line_rasterizer;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &line_pipeline_info, null, &self.line_pipeline));

    if (g_render_pass != null) {
        const g_frag_module = try loadShaderModule(allocator, vk_device, shader_registry.G_PASS_FRAG);
        defer c.vkDestroyShaderModule(vk_device, g_frag_module, null);

        var g_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = g_frag_module, .pName = "main" },
        };

        var g_color_blend_attachments = [_]c.VkPipelineColorBlendAttachmentState{
            std.mem.zeroes(c.VkPipelineColorBlendAttachmentState),
            std.mem.zeroes(c.VkPipelineColorBlendAttachmentState),
        };
        g_color_blend_attachments[0].colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        g_color_blend_attachments[1].colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;

        var g_color_blending = color_blending.*;
        g_color_blending.attachmentCount = 2;
        g_color_blending.pAttachments = &g_color_blend_attachments[0];

        var g_multisampling = multisampling.*;
        g_multisampling.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        g_multisampling.alphaToCoverageEnable = c.VK_FALSE;

        const g_rasterizer = terrainRasterizer(rasterizer.*, .solid);
        var g_pipeline_info = pipeline_info;
        g_pipeline_info.pRasterizationState = &g_rasterizer;
        g_pipeline_info.stageCount = 2;
        g_pipeline_info.pStages = &g_shader_stages[0];
        g_pipeline_info.pMultisampleState = &g_multisampling;
        g_pipeline_info.pColorBlendState = &g_color_blending;
        g_pipeline_info.renderPass = g_render_pass;
        g_pipeline_info.subpass = 0;

        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &g_pipeline_info, null, &self.g_pipeline));
    }
}

pub fn createSwapchainUIPipelines(
    self: anytype,
    allocator: std.mem.Allocator,
    vk_device: c.VkDevice,
    ui_swapchain_render_pass: c.VkRenderPass,
) !void {
    if (ui_swapchain_render_pass == null) return error.InitializationFailed;

    if (self.ui_swapchain_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
    if (self.ui_swapchain_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
    if (self.rml_ui_swapchain_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
    if (self.rml_ui_swapchain_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
    self.ui_swapchain_pipeline = null;
    self.ui_swapchain_tex_pipeline = null;
    self.rml_ui_swapchain_pipeline = null;
    self.rml_ui_swapchain_tex_pipeline = null;

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
    depth_stencil.depthTestEnable = c.VK_FALSE;
    depth_stencil.depthWriteEnable = c.VK_FALSE;

    var ui_color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    ui_color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    ui_color_blend_attachment.blendEnable = c.VK_TRUE;
    ui_color_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
    ui_color_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    ui_color_blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    ui_color_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    ui_color_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
    ui_color_blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;

    var ui_color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    ui_color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    ui_color_blending.attachmentCount = 1;
    ui_color_blending.pAttachments = &ui_color_blend_attachment;

    const swapchain_ui_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_VERT, shader_registry.UI_FRAG);
    defer c.vkDestroyShaderModule(vk_device, swapchain_ui_shaders.vert, null);
    defer c.vkDestroyShaderModule(vk_device, swapchain_ui_shaders.frag, null);

    var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = swapchain_ui_shaders.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = swapchain_ui_shaders.frag, .pName = "main" },
    };

    const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 6 * @sizeOf(f32), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };

    var attribute_descriptions: [2]c.VkVertexInputAttributeDescription = undefined;
    attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 };
    attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 2 * 4 };

    var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input_info.vertexBindingDescriptionCount = 1;
    vertex_input_info.pVertexBindingDescriptions = &binding_description;
    vertex_input_info.vertexAttributeDescriptionCount = 2;
    vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];

    var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = 2;
    pipeline_info.pStages = &shader_stages[0];
    pipeline_info.pVertexInputState = &vertex_input_info;
    pipeline_info.pInputAssemblyState = &input_assembly;
    pipeline_info.pViewportState = &viewport_state;
    pipeline_info.pRasterizationState = &rasterizer;
    pipeline_info.pMultisampleState = &multisampling;
    pipeline_info.pDepthStencilState = &depth_stencil;
    pipeline_info.pColorBlendState = &ui_color_blending;
    pipeline_info.pDynamicState = &dynamic_state;
    pipeline_info.layout = self.ui_pipeline_layout;
    pipeline_info.renderPass = ui_swapchain_render_pass;
    pipeline_info.subpass = 0;

    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.ui_swapchain_pipeline));

    const tex_swapchain_ui_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_TEX_VERT, shader_registry.UI_TEX_FRAG);
    defer c.vkDestroyShaderModule(vk_device, tex_swapchain_ui_shaders.vert, null);
    defer c.vkDestroyShaderModule(vk_device, tex_swapchain_ui_shaders.frag, null);

    var tex_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = tex_swapchain_ui_shaders.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = tex_swapchain_ui_shaders.frag, .pName = "main" },
    };

    pipeline_info.pStages = &tex_shader_stages[0];
    pipeline_info.layout = self.ui_tex_pipeline_layout;
    pipeline_info.renderPass = ui_swapchain_render_pass;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.ui_swapchain_tex_pipeline));

    if (comptime !build_options.rmlui) return;

    // RmlUi 6.2 produces premultiplied vertex/texture colors. Keep this
    // equation distinct from legacy immediate UI's straight-alpha blending.
    var rml_blend_attachment = ui_color_blend_attachment;
    rml_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
    rml_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    rml_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    rml_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    var rml_color_blending = ui_color_blending;
    rml_color_blending.pAttachments = &rml_blend_attachment;

    const rml_binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.UiVertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    const rml_attributes = [_]c.VkVertexInputAttributeDescription{
        .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(rhi.UiVertex, "position") },
        .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(rhi.UiVertex, "color") },
        .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(rhi.UiVertex, "uv") },
    };
    var rml_vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    rml_vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    rml_vertex_input.vertexBindingDescriptionCount = 1;
    rml_vertex_input.pVertexBindingDescriptions = &rml_binding;
    rml_vertex_input.vertexAttributeDescriptionCount = rml_attributes.len;
    rml_vertex_input.pVertexAttributeDescriptions = &rml_attributes[0];

    const rml_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_RML_VERT, shader_registry.UI_RML_FRAG);
    defer c.vkDestroyShaderModule(vk_device, rml_shaders.vert, null);
    defer c.vkDestroyShaderModule(vk_device, rml_shaders.frag, null);
    const rml_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = rml_shaders.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = rml_shaders.frag, .pName = "main" },
    };

    pipeline_info.pStages = &rml_stages[0];
    pipeline_info.pVertexInputState = &rml_vertex_input;
    pipeline_info.pColorBlendState = &rml_color_blending;
    pipeline_info.layout = self.ui_pipeline_layout;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.rml_ui_swapchain_pipeline));

    const rml_textured_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_RML_VERT, shader_registry.UI_RML_TEX_FRAG);
    defer c.vkDestroyShaderModule(vk_device, rml_textured_shaders.vert, null);
    defer c.vkDestroyShaderModule(vk_device, rml_textured_shaders.frag, null);
    const rml_textured_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = rml_textured_shaders.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = rml_textured_shaders.frag, .pName = "main" },
    };
    pipeline_info.pStages = &rml_textured_stages[0];
    pipeline_info.layout = self.ui_tex_pipeline_layout;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.rml_ui_swapchain_tex_pipeline));
}

pub fn createDebugShadowPipeline(
    self: anytype,
    allocator: std.mem.Allocator,
    vk_device: c.VkDevice,
    hdr_render_pass: c.VkRenderPass,
    viewport_state: *const c.VkPipelineViewportStateCreateInfo,
    dynamic_state: *const c.VkPipelineDynamicStateCreateInfo,
    input_assembly: *const c.VkPipelineInputAssemblyStateCreateInfo,
    rasterizer: *const c.VkPipelineRasterizationStateCreateInfo,
    multisampling: *const c.VkPipelineMultisampleStateCreateInfo,
    depth_stencil: *const c.VkPipelineDepthStencilStateCreateInfo,
    color_blending: *const c.VkPipelineColorBlendStateCreateInfo,
) !void {
    const debug_shadow_shaders = try loadShaderPair(allocator, vk_device, shader_registry.DEBUG_SHADOW_VERT, shader_registry.DEBUG_SHADOW_FRAG);
    defer c.vkDestroyShaderModule(vk_device, debug_shadow_shaders.vert, null);
    defer c.vkDestroyShaderModule(vk_device, debug_shadow_shaders.frag, null);

    var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = debug_shadow_shaders.vert, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = debug_shadow_shaders.frag, .pName = "main" },
    };

    const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = 4 * @sizeOf(f32), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };

    var attribute_descriptions: [2]c.VkVertexInputAttributeDescription = undefined;
    attribute_descriptions[0] = .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 0 };
    attribute_descriptions[1] = .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = 2 * 4 };

    var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input_info.vertexBindingDescriptionCount = 1;
    vertex_input_info.pVertexBindingDescriptions = &binding_description;
    vertex_input_info.vertexAttributeDescriptionCount = 2;
    vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];

    var ui_depth_stencil = depth_stencil.*;
    ui_depth_stencil.depthTestEnable = c.VK_FALSE;
    ui_depth_stencil.depthWriteEnable = c.VK_FALSE;

    const layout = self.debug_shadow_pipeline_layout orelse return error.MissingPipelineLayout;

    var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = 2;
    pipeline_info.pStages = &shader_stages[0];
    pipeline_info.pVertexInputState = &vertex_input_info;
    pipeline_info.pInputAssemblyState = input_assembly;
    pipeline_info.pViewportState = viewport_state;
    pipeline_info.pRasterizationState = rasterizer;
    pipeline_info.pMultisampleState = multisampling;
    pipeline_info.pDepthStencilState = &ui_depth_stencil;
    pipeline_info.pColorBlendState = color_blending;
    pipeline_info.pDynamicState = dynamic_state;
    pipeline_info.layout = layout;
    pipeline_info.renderPass = hdr_render_pass;
    pipeline_info.subpass = 0;

    var pipeline: c.VkPipeline = null;
    try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &pipeline));
    self.debug_shadow_pipeline = pipeline;
}
