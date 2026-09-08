const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const RenderDevice = @import("engine-rhi").render_device.RenderDevice;
const VulkanDevice = @import("device.zig").VulkanDevice;
const ResourceManager = @import("resource_manager.zig").ResourceManager;
const FrameManager = @import("frame_manager.zig").FrameManager;
const SwapchainPresenter = @import("swapchain_presenter.zig").SwapchainPresenter;
const DescriptorManager = @import("descriptor_manager.zig").DescriptorManager;
const PipelineManager = @import("pipeline_manager.zig").PipelineManager;
const RenderPassManager = @import("render_pass_manager.zig").RenderPassManager;
const ShadowSystem = @import("engine-shadows").ShadowSystem;
const Utils = @import("utils.zig");
const lifecycle = @import("rhi_resource_lifecycle.zig");
const setup = @import("rhi_resource_setup.zig");
const rhi_timing = @import("rhi_timing.zig");
const screenshot = @import("screenshot.zig");
const final_composition = @import("final_composition.zig");
const runtime_env = @import("engine-core").runtime_env;
const build_options = @import("engine_graphics_options");

const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;
const TOTAL_QUERY_COUNT = rhi_timing.QUERY_COUNT_PER_FRAME * MAX_FRAMES_IN_FLIGHT;

pub const InitOwnership = struct {
    attempted: bool = false,
    vulkan_device: bool = false,
    resources: bool = false,
    frames: bool = false,
    swapchain: bool = false,
    descriptors: bool = false,
    render_resources: bool = false,
};

/// Constructors retain responsibility for their own partial allocations. Only
/// successfully returned managers transfer ownership to the context.
pub fn unwindManagers(ctx: anytype) void {
    inline for (.{ "descriptors", "swapchain", "frames", "resources", "vulkan_device" }) |name| {
        if (@field(ctx.init_ownership, name)) {
            @field(ctx, name).deinit();
            @field(ctx.init_ownership, name) = false;
        }
    }
}

pub fn initContext(ctx: anytype, allocator: std.mem.Allocator, render_device: ?*RenderDevice) !void {
    if (ctx.init_ownership.attempted) return error.InvalidState;
    ctx.init_ownership.attempted = true;
    ctx.allocator = allocator;
    ctx.render_device = render_device;
    errdefer cleanup(ctx);

    ctx.vulkan_device = try VulkanDevice.init(allocator, ctx.window);
    ctx.init_ownership.vulkan_device = true;
    ctx.vulkan_device.initDebugMessenger();
    ctx.resources = try ResourceManager.init(allocator, &ctx.vulkan_device);
    ctx.init_ownership.resources = true;
    ctx.frames = try FrameManager.init(&ctx.vulkan_device);
    ctx.init_ownership.frames = true;
    ctx.swapchain = try SwapchainPresenter.init(allocator, &ctx.vulkan_device, ctx.window, ctx.options.msaa_samples, ctx.options.present_mode);
    ctx.init_ownership.swapchain = true;
    ctx.dynamic_resolution.setSwapchainExtent(ctx.swapchain.getExtent());
    ctx.descriptors = try DescriptorManager.init(allocator, &ctx.vulkan_device, &ctx.resources);
    ctx.init_ownership.descriptors = true;

    ctx.init_ownership.render_resources = true;
    ctx.pipeline_manager = try PipelineManager.init(&ctx.vulkan_device, &ctx.descriptors, null);
    ctx.render_pass_manager = RenderPassManager.init(ctx.allocator);

    ctx.shadow_system = try ShadowSystem.init(allocator, ctx.shadow_runtime.shadow_resolution);

    ctx.legacy.dummy_shadow_image = null;
    ctx.legacy.dummy_shadow_memory = null;
    ctx.legacy.dummy_shadow_view = null;
    ctx.runtime.clear_color = .{ 0.07, 0.08, 0.1, 1.0 };
    ctx.frames.frame_in_progress = false;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.shadow_system.pass_index = 0;
    ctx.ui.ui_in_progress = false;
    ctx.ui.ui_mapped_ptr = null;
    ctx.ui.ui_vertex_offset = 0;

    ctx.draw.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;
    ctx.draw.bound_normal_texture = 0;
    ctx.draw.bound_roughness_texture = 0;
    ctx.draw.bound_displacement_texture = 0;
    ctx.draw.bound_env_texture = 0;
    ctx.draw.pending_instance_buffer = 0;

    ctx.options.wireframe_enabled = false;
    ctx.options.textures_enabled = true;
    ctx.options.vsync_enabled = true;
    ctx.options.present_mode = c.VK_PRESENT_MODE_FIFO_KHR;

    ctx.options.safe_mode = runtime_env.safeModeEnabled();
    if (ctx.options.safe_mode) {
        log.log.warn("ZIGCRAFT_SAFE_MODE enabled: throttling uploads and forcing GPU idle each frame", .{});
    }

    try setup.createShadowResources(ctx);
    try lifecycle.createHDRResources(ctx);
    try setup.createGPassResources(ctx);
    try setup.createSSAOResources(ctx);
    try setup.createTAAResources(ctx);

    try ctx.render_pass_manager.createMainRenderPass(
        ctx.vulkan_device.vk_device,
        ctx.swapchain.getExtent(),
        ctx.options.msaa_samples,
    );

    try ctx.pipeline_manager.createMainPipelines(
        ctx.allocator,
        ctx.vulkan_device.vk_device,
        ctx.render_pass_manager.hdr_render_pass,
        ctx.render_pass_manager.g_render_pass,
        ctx.options.msaa_samples,
    );

    try setup.createWaterResources(ctx);
    try ctx.water_system.createWaterPipeline(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, ctx.options.msaa_samples);
    try ctx.water_system.createReflectionTerrainPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.pipeline_manager.pipeline_layout);

    try setup.createPostProcessResources(ctx);
    try setup.createSwapchainUIResources(ctx);

    try ctx.fxaa.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.swapchain.getExtent(), ctx.swapchain.getImageFormat(), ctx.post_process.sampler, ctx.swapchain.getImageViews(), final_composition.displayLayout(ctx.swapchain.skip_present));
    try ctx.pipeline_manager.createSwapchainUIPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.ui_swapchain_render_pass);
    try ctx.bloom.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.hdr.hdr_view, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, c.VK_FORMAT_R16G16B16A16_SFLOAT);

    setup.updatePostProcessDescriptorsWithBloom(ctx);
    try lifecycle.initializePostProcessInputs(ctx);

    ctx.draw.dummy_texture = ctx.descriptors.dummy_texture;
    ctx.draw.dummy_texture_3d = ctx.descriptors.dummy_texture_3d;
    ctx.draw.dummy_normal_texture = ctx.descriptors.dummy_normal_texture;
    ctx.draw.dummy_roughness_texture = ctx.descriptors.dummy_roughness_texture;
    ctx.draw.current_texture = ctx.draw.dummy_texture;
    ctx.draw.current_normal_texture = ctx.draw.dummy_normal_texture;
    ctx.draw.current_roughness_texture = ctx.draw.dummy_roughness_texture;
    ctx.draw.current_displacement_texture = ctx.draw.dummy_roughness_texture;
    ctx.draw.current_env_texture = ctx.draw.dummy_texture;
    ctx.draw.current_water_reflection_texture = ctx.draw.dummy_texture;
    ctx.draw.current_scene_depth_texture = ctx.draw.dummy_texture;
    ctx.draw.current_lpv_texture = ctx.draw.dummy_texture_3d;
    ctx.draw.current_lpv_texture_g = ctx.draw.dummy_texture_3d;
    ctx.draw.current_lpv_texture_b = ctx.draw.dummy_texture_3d;

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.ui.ui_vbos[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, 1024 * 1024, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (comptime build_options.rmlui) {
            ctx.ui.rml_vbos[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, 1024 * 1024, c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            ctx.ui.rml_ibos[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, 1024 * 1024, c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        }
    }

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        ctx.draw.descriptors_dirty[i] = true;
        for (0..64) |j| {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = ctx.descriptors.descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &ctx.pipeline_manager.ui_tex_descriptor_set_layout;
            const result = c.vkAllocateDescriptorSets(ctx.vulkan_device.vk_device, &alloc_info, &ctx.ui.ui_tex_descriptor_pool[i][j]);
            if (result != c.VK_SUCCESS) {
                log.log.err("Failed to allocate UI texture descriptor set [{}][{}]: error {}. Pool state: maxSets={}, available may be exhausted by FXAA+Bloom+UI", .{ i, j, result, @as(u32, 1000) });
            }
        }
        ctx.ui.ui_tex_descriptor_next[i] = 0;
    }

    try ctx.resources.flushTransfer();
    ctx.resources.setCurrentFrame(0);

    if (ctx.shadow_system.shadow_image != null) {
        try lifecycle.transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true, rhi.SHADOW_CASCADE_COUNT);
        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
        }
    }

    if (!ctx.options.safe_mode) {
        var list: [32]c.VkImage = undefined;
        var count: usize = 0;
        const candidates = [_]c.VkImage{ ctx.gpass.g_normal_image, ctx.ssao_system.image, ctx.ssao_system.blur_image, ctx.ssao_system.noise_image, ctx.velocity.velocity_image };
        for (candidates) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }
        if (count > 0) {
            lifecycle.transitionImagesToShaderRead(ctx, list[0..count], false, 1) catch |err| log.log.err("Failed to transition images during init: {}", .{err});
        }
    }

    var query_pool_info = std.mem.zeroes(c.VkQueryPoolCreateInfo);
    query_pool_info.sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
    query_pool_info.queryType = c.VK_QUERY_TYPE_TIMESTAMP;
    query_pool_info.queryCount = TOTAL_QUERY_COUNT;
    try Utils.checkVk(c.vkCreateQueryPool(ctx.vulkan_device.vk_device, &query_pool_info, null, &ctx.timing.query_pool));
}

pub fn deinit(ctx: anytype) void {
    cleanup(ctx);
    ctx.allocator.destroy(ctx);
}

fn cleanup(ctx: anytype) void {
    if (!ctx.init_ownership.vulkan_device) return;
    const vk_device: c.VkDevice = ctx.vulkan_device.vk_device;
    _ = c.vkDeviceWaitIdle(vk_device);
    defer unwindManagers(ctx);

    if (ctx.init_ownership.render_resources) {
        ctx.init_ownership.render_resources = false;
        screenshot.discardCapture(ctx);

        var compute_pipeline_iter = ctx.compute_resources.pipelines.iterator();
        while (compute_pipeline_iter.next()) |entry| {
            const pipeline = entry.value_ptr.*;
            if (pipeline.pipeline != null) c.vkDestroyPipeline(vk_device, pipeline.pipeline, null);
            if (pipeline.layout != null) c.vkDestroyPipelineLayout(vk_device, pipeline.layout, null);
            if (pipeline.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk_device, pipeline.descriptor_set_layout, null);
            if (pipeline.descriptor_pool != null) c.vkDestroyDescriptorPool(vk_device, pipeline.descriptor_pool, null);
        }
        ctx.compute_resources.pipelines.deinit(ctx.allocator);

        var compute_buffer_iter = ctx.compute_resources.buffers.iterator();
        while (compute_buffer_iter.next()) |entry| {
            const buffer = entry.value_ptr.*;
            if (buffer.mapped_ptr != null) c.vkUnmapMemory(vk_device, buffer.memory);
            if (buffer.buffer != null) c.vkDestroyBuffer(vk_device, buffer.buffer, null);
            if (buffer.memory != null) c.vkFreeMemory(vk_device, buffer.memory, null);
        }
        ctx.compute_resources.buffers.deinit(ctx.allocator);

        if (ctx.render_pass_manager.main_framebuffer != null) {
            c.vkDestroyFramebuffer(vk_device, ctx.render_pass_manager.main_framebuffer, null);
            ctx.render_pass_manager.main_framebuffer = null;
        }

        ctx.pipeline_manager.deinit(vk_device);
        ctx.render_pass_manager.deinit(vk_device);

        lifecycle.destroyHDRResources(ctx);
        lifecycle.destroyFXAAResources(ctx);
        lifecycle.destroyTAAResources(ctx);
        lifecycle.destroyBloomResources(ctx);
        lifecycle.destroyUpscaleResources(ctx);
        lifecycle.destroyVelocityResources(ctx);
        lifecycle.destroyPostProcessResources(ctx);
        lifecycle.destroyGPassResources(ctx);
        if (ctx.water_system.reflection_texture_handle != 0) {
            ctx.resources.destroyTexture(ctx.water_system.reflection_texture_handle);
            ctx.water_system.reflection_texture_handle = 0;
        }
        ctx.water_system.deinit(ctx.vulkan_device.vk_device);

        const device = ctx.vulkan_device.vk_device;
        {
            if (ctx.legacy.model_ubo.buffer != null) c.vkDestroyBuffer(device, ctx.legacy.model_ubo.buffer, null);
            if (ctx.legacy.model_ubo.memory != null) c.vkFreeMemory(device, ctx.legacy.model_ubo.memory, null);

            if (ctx.legacy.dummy_instance_buffer.buffer != null) c.vkDestroyBuffer(device, ctx.legacy.dummy_instance_buffer.buffer, null);
            if (ctx.legacy.dummy_instance_buffer.memory != null) c.vkFreeMemory(device, ctx.legacy.dummy_instance_buffer.memory, null);

            for (ctx.ui.ui_vbos) |buf| {
                if (buf.mapped_ptr != null and buf.memory != null) c.vkUnmapMemory(device, buf.memory);
                if (buf.buffer != null) c.vkDestroyBuffer(device, buf.buffer, null);
                if (buf.memory != null) c.vkFreeMemory(device, buf.memory, null);
            }
            if (comptime build_options.rmlui) {
                for (ctx.ui.rml_vbos) |buf| {
                    if (buf.mapped_ptr != null and buf.memory != null) c.vkUnmapMemory(device, buf.memory);
                    if (buf.buffer != null) c.vkDestroyBuffer(device, buf.buffer, null);
                    if (buf.memory != null) c.vkFreeMemory(device, buf.memory, null);
                }
                for (ctx.ui.rml_ibos) |buf| {
                    if (buf.mapped_ptr != null and buf.memory != null) c.vkUnmapMemory(device, buf.memory);
                    if (buf.buffer != null) c.vkDestroyBuffer(device, buf.buffer, null);
                    if (buf.memory != null) c.vkFreeMemory(device, buf.memory, null);
                }
            }
        }

        if (comptime @import("engine_graphics_options").debug_shadows) {
            if (ctx.debug_shadow.vbo.buffer != null) c.vkDestroyBuffer(device, ctx.debug_shadow.vbo.buffer, null);
            if (ctx.debug_shadow.vbo.memory != null) c.vkFreeMemory(device, ctx.debug_shadow.vbo.memory, null);
        }

        ctx.resources.destroyTexture(ctx.draw.dummy_texture);
        ctx.resources.destroyTexture(ctx.draw.dummy_texture_3d);
        ctx.resources.destroyTexture(ctx.draw.dummy_normal_texture);
        ctx.resources.destroyTexture(ctx.draw.dummy_roughness_texture);
        if (ctx.legacy.dummy_shadow_view != null) c.vkDestroyImageView(ctx.vulkan_device.vk_device, ctx.legacy.dummy_shadow_view, null);
        if (ctx.legacy.dummy_shadow_image != null) c.vkDestroyImage(ctx.vulkan_device.vk_device, ctx.legacy.dummy_shadow_image, null);
        if (ctx.legacy.dummy_shadow_memory != null) c.vkFreeMemory(ctx.vulkan_device.vk_device, ctx.legacy.dummy_shadow_memory, null);

        ctx.shadow_system.deinit(ctx.vulkan_device.vk_device);

        if (ctx.timing.query_pool != null) {
            c.vkDestroyQueryPool(ctx.vulkan_device.vk_device, ctx.timing.query_pool, null);
            ctx.timing.query_pool = null;
        }
    }
}
