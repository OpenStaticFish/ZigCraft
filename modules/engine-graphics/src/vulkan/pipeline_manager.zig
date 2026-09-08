//! Pipeline Manager - Handles all Vulkan pipeline creation and management
//!
//! Extracted from rhi_vulkan.zig to eliminate the god object anti-pattern.
//! This module is responsible for:
//! - Creating and destroying graphics pipelines
//! - Managing pipeline layouts
//! - Handling pipeline state for different rendering modes

const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const DescriptorManager = @import("descriptor_manager.zig").DescriptorManager;
const Utils = @import("utils.zig");
const shader_registry = @import("shader_registry.zig");
const pipeline_specialized = @import("pipeline_specialized.zig");
const build_options = @import("engine_graphics_options");
const Mat4 = @import("engine-math").Mat4;

/// Maximum number of frames in flight
const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;

/// Push constant sizes for different pipeline types
const PUSH_CONSTANT_SIZE_MODEL: u32 = 256; // mat4 model + vec3 color + float mask
const PUSH_CONSTANT_SIZE_SKY: u32 = 128; // mat4 view_proj + vec4 params
const PUSH_CONSTANT_SIZE_UI: u32 = @sizeOf(Mat4); // Orthographic projection matrix
const MAX_SHADER_MODULE_BYTES: usize = 4 * 1024 * 1024;

/// Pipeline manager handles all pipeline-related resources
pub const PipelineManager = struct {
    // Main pipelines
    terrain_pipeline: c.VkPipeline = null,
    wireframe_pipeline: c.VkPipeline = null,
    selection_pipeline: c.VkPipeline = null,
    line_pipeline: c.VkPipeline = null,
    g_pipeline: c.VkPipeline = null,
    sky_pipeline: c.VkPipeline = null,
    ui_pipeline: c.VkPipeline = null,
    ui_tex_pipeline: c.VkPipeline = null,
    rml_ui_pipeline: c.VkPipeline = null,
    rml_ui_tex_pipeline: c.VkPipeline = null,
    water_pipeline: c.VkPipeline = null,

    // Swapchain UI pipelines
    ui_swapchain_pipeline: c.VkPipeline = null,
    ui_swapchain_tex_pipeline: c.VkPipeline = null,
    rml_ui_swapchain_pipeline: c.VkPipeline = null,
    rml_ui_swapchain_tex_pipeline: c.VkPipeline = null,

    // Pipeline layouts
    pipeline_layout: c.VkPipelineLayout = null,
    sky_pipeline_layout: c.VkPipelineLayout = null,
    ui_pipeline_layout: c.VkPipelineLayout = null,
    ui_tex_pipeline_layout: c.VkPipelineLayout = null,
    ui_tex_descriptor_set_layout: c.VkDescriptorSetLayout = null,

    // Debug shadow pipeline (conditional)
    debug_shadow_pipeline: ?c.VkPipeline = null,
    debug_shadow_pipeline_layout: ?c.VkPipelineLayout = null,
    debug_shadow_descriptor_set_layout: ?c.VkDescriptorSetLayout = null, // Borrowed from the caller.

    /// Initialize the pipeline manager and create all pipeline layouts
    pub fn init(
        device: *const VulkanDevice,
        descriptor_manager: *const DescriptorManager,
        debug_shadow_layout: ?c.VkDescriptorSetLayout,
    ) !PipelineManager {
        var manager: PipelineManager = .{};
        errdefer manager.deinit(device.vk_device);

        try manager.createPipelineLayouts(device, descriptor_manager, debug_shadow_layout);

        return manager;
    }

    /// Deinitialize and destroy all pipelines and layouts
    pub fn deinit(self: *PipelineManager, vk_device: c.VkDevice) void {
        self.destroyPipelines(vk_device);
        self.destroyPipelineLayouts(vk_device);
    }

    /// Load shader from file and create shader module
    /// Caller must destroy the returned module with vkDestroyShaderModule
    fn loadShaderModule(
        allocator: std.mem.Allocator,
        vk_device: c.VkDevice,
        path: []const u8,
    ) !c.VkShaderModule {
        const code = try fs.cwd().readFileAlloc(path, allocator, MAX_SHADER_MODULE_BYTES);
        defer allocator.free(code);
        return try Utils.createShaderModule(vk_device, code);
    }

    /// Load vertex and fragment shader pair
    /// Returns both modules - caller must destroy both
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

    /// Create all pipeline layouts
    fn createPipelineLayouts(
        self: *PipelineManager,
        device: *const VulkanDevice,
        descriptor_manager: *const DescriptorManager,
        debug_shadow_layout: ?c.VkDescriptorSetLayout,
    ) !void {
        const vk_device = device.vk_device;

        // Main pipeline layout with model push constants
        var model_push_constant = std.mem.zeroes(c.VkPushConstantRange);
        model_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        model_push_constant.size = PUSH_CONSTANT_SIZE_MODEL;

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &descriptor_manager.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &model_push_constant;

        try Utils.checkVk(c.vkCreatePipelineLayout(vk_device, &pipeline_layout_info, null, &self.pipeline_layout));

        // Sky pipeline layout
        var sky_push_constant = std.mem.zeroes(c.VkPushConstantRange);
        sky_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        sky_push_constant.size = PUSH_CONSTANT_SIZE_SKY;

        var sky_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        sky_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        sky_layout_info.setLayoutCount = 1;
        sky_layout_info.pSetLayouts = &descriptor_manager.descriptor_set_layout;
        sky_layout_info.pushConstantRangeCount = 1;
        sky_layout_info.pPushConstantRanges = &sky_push_constant;

        try Utils.checkVk(c.vkCreatePipelineLayout(vk_device, &sky_layout_info, null, &self.sky_pipeline_layout));

        // UI pipeline layout
        var ui_push_constant = std.mem.zeroes(c.VkPushConstantRange);
        ui_push_constant.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        ui_push_constant.size = @sizeOf(Mat4) + @sizeOf([4]f32);

        var ui_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        ui_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        ui_layout_info.pushConstantRangeCount = 1;
        ui_layout_info.pPushConstantRanges = &ui_push_constant;

        try Utils.checkVk(c.vkCreatePipelineLayout(vk_device, &ui_layout_info, null, &self.ui_pipeline_layout));

        // UI texture descriptor set layout
        var ui_tex_layout_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };

        var ui_tex_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        ui_tex_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        ui_tex_layout_info.bindingCount = 1;
        ui_tex_layout_info.pBindings = &ui_tex_layout_bindings[0];

        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk_device, &ui_tex_layout_info, null, &self.ui_tex_descriptor_set_layout));

        // UI texture pipeline layout
        var ui_tex_layout_full_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        ui_tex_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        ui_tex_layout_full_info.setLayoutCount = 1;
        ui_tex_layout_full_info.pSetLayouts = &self.ui_tex_descriptor_set_layout;
        ui_tex_layout_full_info.pushConstantRangeCount = 1;
        ui_tex_layout_full_info.pPushConstantRanges = &ui_push_constant;

        try Utils.checkVk(c.vkCreatePipelineLayout(vk_device, &ui_tex_layout_full_info, null, &self.ui_tex_pipeline_layout));

        // Debug shadow pipeline layout
        if (comptime build_options.debug_shadows) {
            if (debug_shadow_layout) |layout| {
                self.debug_shadow_descriptor_set_layout = layout;

                var debug_shadow_layout_full_info: c.VkPipelineLayoutCreateInfo = undefined;
                @memset(std.mem.asBytes(&debug_shadow_layout_full_info), 0);
                debug_shadow_layout_full_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
                debug_shadow_layout_full_info.setLayoutCount = 1;
                debug_shadow_layout_full_info.pSetLayouts = &layout;
                debug_shadow_layout_full_info.pushConstantRangeCount = 1;
                debug_shadow_layout_full_info.pPushConstantRanges = &ui_push_constant;

                var pipeline_layout: c.VkPipelineLayout = null;
                try Utils.checkVk(c.vkCreatePipelineLayout(vk_device, &debug_shadow_layout_full_info, null, &pipeline_layout));
                self.debug_shadow_pipeline_layout = pipeline_layout;
            }
        }
    }

    /// Destroy all pipeline layouts
    fn destroyPipelineLayouts(self: *PipelineManager, vk_device: c.VkDevice) void {
        if (self.pipeline_layout) |layout| c.vkDestroyPipelineLayout(vk_device, layout, null);
        if (self.sky_pipeline_layout) |layout| c.vkDestroyPipelineLayout(vk_device, layout, null);
        if (self.ui_pipeline_layout) |layout| c.vkDestroyPipelineLayout(vk_device, layout, null);
        if (self.ui_tex_pipeline_layout) |layout| c.vkDestroyPipelineLayout(vk_device, layout, null);
        if (self.ui_tex_descriptor_set_layout) |layout| c.vkDestroyDescriptorSetLayout(vk_device, layout, null);
        if (comptime build_options.debug_shadows) {
            if (self.debug_shadow_pipeline_layout) |layout| c.vkDestroyPipelineLayout(vk_device, layout, null);
        }
        self.pipeline_layout = null;
        self.sky_pipeline_layout = null;
        self.ui_pipeline_layout = null;
        self.ui_tex_pipeline_layout = null;
        self.ui_tex_descriptor_set_layout = null;
        self.debug_shadow_pipeline_layout = null;
        self.debug_shadow_descriptor_set_layout = null;
    }

    /// Destroy all pipelines (but not layouts)
    pub fn destroyPipelines(self: *PipelineManager, vk_device: c.VkDevice) void {
        if (self.terrain_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.wireframe_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.selection_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.line_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.g_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.sky_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.ui_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.ui_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.rml_ui_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.rml_ui_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.water_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.ui_swapchain_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.ui_swapchain_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.rml_ui_swapchain_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        if (self.rml_ui_swapchain_tex_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);

        if (comptime build_options.debug_shadows) {
            if (self.debug_shadow_pipeline) |p| c.vkDestroyPipeline(vk_device, p, null);
        }

        self.terrain_pipeline = null;
        self.wireframe_pipeline = null;
        self.selection_pipeline = null;
        self.line_pipeline = null;
        self.g_pipeline = null;
        self.sky_pipeline = null;
        self.ui_pipeline = null;
        self.ui_tex_pipeline = null;
        self.rml_ui_pipeline = null;
        self.rml_ui_tex_pipeline = null;
        self.water_pipeline = null;
        self.ui_swapchain_pipeline = null;
        self.ui_swapchain_tex_pipeline = null;
        self.rml_ui_swapchain_pipeline = null;
        self.rml_ui_swapchain_tex_pipeline = null;
        self.debug_shadow_pipeline = null;
    }

    /// Create all main rendering pipelines
    pub fn createMainPipelines(
        self: *PipelineManager,
        allocator: std.mem.Allocator,
        vk_device: c.VkDevice,
        hdr_render_pass: c.VkRenderPass,
        g_render_pass: c.VkRenderPass,
        msaa_samples: u8,
    ) !void {
        // Validate required render passes
        if (hdr_render_pass == null) return error.InvalidRenderPass;

        // Destroy existing pipelines first
        self.destroyPipelines(vk_device);

        // Setup rollback on failure - destroy any created pipelines if we fail partway
        errdefer self.destroyPipelines(vk_device);

        const sample_count = getMSAASampleCountFlag(msaa_samples);

        // Common pipeline state
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
        multisampling.rasterizationSamples = sample_count;

        var terrain_multisampling = multisampling;
        terrain_multisampling.alphaToCoverageEnable = if (sample_count != c.VK_SAMPLE_COUNT_1_BIT) c.VK_TRUE else c.VK_FALSE;

        var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depth_stencil.depthTestEnable = c.VK_TRUE;
        depth_stencil.depthWriteEnable = c.VK_TRUE;
        depth_stencil.depthCompareOp = c.VK_COMPARE_OP_GREATER_OR_EQUAL;

        var color_blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        color_blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;

        var ui_color_blend_attachment = color_blend_attachment;
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

        // RmlUi 6.2 emits premultiplied vertex and texture color. Its blend
        // equation is deliberately separate from the legacy straight-alpha
        // immediate UI pipeline above.
        var rml_color_blend_attachment = ui_color_blend_attachment;
        rml_color_blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
        rml_color_blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        rml_color_blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        rml_color_blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        var rml_color_blending = ui_color_blending;
        rml_color_blending.pAttachments = &rml_color_blend_attachment;

        var terrain_color_blending = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        terrain_color_blending.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        terrain_color_blending.attachmentCount = 1;
        terrain_color_blending.pAttachments = &color_blend_attachment;

        // Terrain Pipeline
        try self.createTerrainPipeline(allocator, vk_device, hdr_render_pass, &viewport_state, &dynamic_state, &input_assembly, &rasterizer, &terrain_multisampling, &depth_stencil, &terrain_color_blending, sample_count, g_render_pass);

        // Sky Pipeline
        try self.createSkyPipeline(allocator, vk_device, hdr_render_pass, &viewport_state, &dynamic_state, &input_assembly, &rasterizer, &multisampling, &depth_stencil, &terrain_color_blending);

        // UI Pipelines
        try self.createUIPipelines(allocator, vk_device, hdr_render_pass, &viewport_state, &dynamic_state, &input_assembly, &rasterizer, &multisampling, &depth_stencil, &ui_color_blending);
        if (comptime build_options.rmlui) {
            try self.createRmlUIPipelines(allocator, vk_device, hdr_render_pass, &viewport_state, &dynamic_state, &input_assembly, &rasterizer, &multisampling, &depth_stencil, &rml_color_blending);
        }

        // Debug Shadow Pipeline
        if (comptime build_options.debug_shadows) {
            if (self.debug_shadow_pipeline_layout != null) {
                try self.createDebugShadowPipeline(allocator, vk_device, hdr_render_pass, &viewport_state, &dynamic_state, &input_assembly, &rasterizer, &multisampling, &depth_stencil, &ui_color_blending);
            }
        }
    }

    /// Create terrain pipeline and variants
    fn createTerrainPipeline(
        self: *PipelineManager,
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
        try pipeline_specialized.createTerrainPipeline(self, allocator, vk_device, hdr_render_pass, viewport_state, dynamic_state, input_assembly, rasterizer, multisampling, depth_stencil, color_blending, _sample_count, g_render_pass);
    }

    /// Create sky pipeline
    fn createSkyPipeline(
        self: *PipelineManager,
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
        var sky_rasterizer = rasterizer.*;
        sky_rasterizer.cullMode = c.VK_CULL_MODE_NONE;

        const shaders = try loadShaderPair(allocator, vk_device, shader_registry.SKY_VERT, shader_registry.SKY_FRAG);
        defer c.vkDestroyShaderModule(vk_device, shaders.vert, null);
        defer c.vkDestroyShaderModule(vk_device, shaders.frag, null);

        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = shaders.vert, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = shaders.frag, .pName = "main" },
        };

        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

        var sky_depth_stencil = depth_stencil.*;
        sky_depth_stencil.depthWriteEnable = c.VK_FALSE;

        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &shader_stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = input_assembly;
        pipeline_info.pViewportState = viewport_state;
        pipeline_info.pRasterizationState = &sky_rasterizer;
        pipeline_info.pMultisampleState = multisampling;
        pipeline_info.pDepthStencilState = &sky_depth_stencil;
        pipeline_info.pColorBlendState = color_blending;
        pipeline_info.pDynamicState = dynamic_state;
        pipeline_info.layout = self.sky_pipeline_layout;
        pipeline_info.renderPass = hdr_render_pass;
        pipeline_info.subpass = 0;

        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.sky_pipeline));
    }

    /// Create UI pipelines
    fn createUIPipelines(
        self: *PipelineManager,
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
        // UI vertex format: position (2 floats) + color (4 floats) = 6 floats per vertex
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

        var ui_depth_stencil = depth_stencil.*;
        ui_depth_stencil.depthTestEnable = c.VK_FALSE;
        ui_depth_stencil.depthWriteEnable = c.VK_FALSE;

        // Colored UI pipeline
        const ui_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_VERT, shader_registry.UI_FRAG);
        defer c.vkDestroyShaderModule(vk_device, ui_shaders.vert, null);
        defer c.vkDestroyShaderModule(vk_device, ui_shaders.frag, null);

        var shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = ui_shaders.vert, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = ui_shaders.frag, .pName = "main" },
        };

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
        pipeline_info.layout = self.ui_pipeline_layout;
        pipeline_info.renderPass = hdr_render_pass;
        pipeline_info.subpass = 0;

        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.ui_pipeline));

        // Textured UI pipeline
        const tex_ui_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_TEX_VERT, shader_registry.UI_TEX_FRAG);
        defer c.vkDestroyShaderModule(vk_device, tex_ui_shaders.vert, null);
        defer c.vkDestroyShaderModule(vk_device, tex_ui_shaders.frag, null);

        var tex_shader_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = tex_ui_shaders.vert, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = tex_ui_shaders.frag, .pName = "main" },
        };

        pipeline_info.pStages = &tex_shader_stages[0];
        pipeline_info.layout = self.ui_tex_pipeline_layout;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.ui_tex_pipeline));
    }

    /// Creates retained-geometry UI pipelines with RmlUi's RGBA8 vertex color
    /// and UV layout. They intentionally remain separate from the legacy UI
    /// pipelines, whose two six-float vertex layouts are incompatible.
    fn createRmlUIPipelines(
        self: *PipelineManager,
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
        const binding_description = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(rhi.UiVertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        const attribute_descriptions = [_]c.VkVertexInputAttributeDescription{
            .{ .binding = 0, .location = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(rhi.UiVertex, "position") },
            .{ .binding = 0, .location = 1, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(rhi.UiVertex, "color") },
            .{ .binding = 0, .location = 2, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(rhi.UiVertex, "uv") },
        };

        var vertex_input_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input_info.vertexBindingDescriptionCount = 1;
        vertex_input_info.pVertexBindingDescriptions = &binding_description;
        vertex_input_info.vertexAttributeDescriptionCount = attribute_descriptions.len;
        vertex_input_info.pVertexAttributeDescriptions = &attribute_descriptions[0];

        var ui_depth_stencil = depth_stencil.*;
        ui_depth_stencil.depthTestEnable = c.VK_FALSE;
        ui_depth_stencil.depthWriteEnable = c.VK_FALSE;

        const shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_RML_VERT, shader_registry.UI_RML_FRAG);
        defer c.vkDestroyShaderModule(vk_device, shaders.vert, null);
        defer c.vkDestroyShaderModule(vk_device, shaders.frag, null);
        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = shaders.vert, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = shaders.frag, .pName = "main" },
        };

        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = 2;
        pipeline_info.pStages = &stages[0];
        pipeline_info.pVertexInputState = &vertex_input_info;
        pipeline_info.pInputAssemblyState = input_assembly;
        pipeline_info.pViewportState = viewport_state;
        pipeline_info.pRasterizationState = rasterizer;
        pipeline_info.pMultisampleState = multisampling;
        pipeline_info.pDepthStencilState = &ui_depth_stencil;
        pipeline_info.pColorBlendState = color_blending;
        pipeline_info.pDynamicState = dynamic_state;
        pipeline_info.layout = self.ui_pipeline_layout;
        pipeline_info.renderPass = hdr_render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.rml_ui_pipeline));

        const textured_shaders = try loadShaderPair(allocator, vk_device, shader_registry.UI_RML_VERT, shader_registry.UI_RML_TEX_FRAG);
        defer c.vkDestroyShaderModule(vk_device, textured_shaders.vert, null);
        defer c.vkDestroyShaderModule(vk_device, textured_shaders.frag, null);
        const textured_stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = textured_shaders.vert, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = textured_shaders.frag, .pName = "main" },
        };
        pipeline_info.pStages = &textured_stages[0];
        pipeline_info.layout = self.ui_tex_pipeline_layout;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk_device, null, 1, &pipeline_info, null, &self.rml_ui_tex_pipeline));
    }

    /// Create swapchain UI pipelines
    pub fn createSwapchainUIPipelines(
        self: *PipelineManager,
        allocator: std.mem.Allocator,
        vk_device: c.VkDevice,
        ui_swapchain_render_pass: c.VkRenderPass,
    ) !void {
        try pipeline_specialized.createSwapchainUIPipelines(self, allocator, vk_device, ui_swapchain_render_pass);
    }

    /// Create debug shadow pipeline
    fn createDebugShadowPipeline(
        self: *PipelineManager,
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
        try pipeline_specialized.createDebugShadowPipeline(self, allocator, vk_device, hdr_render_pass, viewport_state, dynamic_state, input_assembly, rasterizer, multisampling, depth_stencil, color_blending);
    }
};

/// Converts MSAA sample count (1, 2, 4, 8) to Vulkan sample count flag.
/// Defaults to 1x for any invalid sample count.
pub fn getMSAASampleCountFlag(samples: u8) c.VkSampleCountFlagBits {
    return switch (samples) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}
