const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Utils = @import("utils.zig");

pub fn destroyHDRResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (ctx.hdr.hdr_view != null) {
        c.vkDestroyImageView(vk, ctx.hdr.hdr_view, null);
        ctx.hdr.hdr_view = null;
    }
    if (ctx.hdr.hdr_image != null) {
        c.vkDestroyImage(vk, ctx.hdr.hdr_image, null);
        ctx.hdr.hdr_image = null;
    }
    if (ctx.hdr.hdr_memory != null) {
        c.vkFreeMemory(vk, ctx.hdr.hdr_memory, null);
        ctx.hdr.hdr_memory = null;
    }
    if (ctx.hdr.hdr_msaa_view != null) {
        c.vkDestroyImageView(vk, ctx.hdr.hdr_msaa_view, null);
        ctx.hdr.hdr_msaa_view = null;
    }
    if (ctx.hdr.hdr_msaa_image != null) {
        c.vkDestroyImage(vk, ctx.hdr.hdr_msaa_image, null);
        ctx.hdr.hdr_msaa_image = null;
    }
    if (ctx.hdr.hdr_msaa_memory != null) {
        c.vkFreeMemory(vk, ctx.hdr.hdr_msaa_memory, null);
        ctx.hdr.hdr_msaa_memory = null;
    }
}

pub fn destroyUpscaleResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;
    const dr = &ctx.dynamic_resolution;
    if (dr.upscale_view != null) {
        c.vkDestroyImageView(vk, dr.upscale_view, null);
        dr.upscale_view = null;
    }
    if (dr.upscale_image != null) {
        c.vkDestroyImage(vk, dr.upscale_image, null);
        dr.upscale_image = null;
    }
    if (dr.upscale_memory != null) {
        c.vkFreeMemory(vk, dr.upscale_memory, null);
        dr.upscale_memory = null;
    }
    dr.upscale_extent = .{ .width = 0, .height = 0 };
}

pub fn destroyPostProcessResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;

    for (ctx.render_pass_manager.post_process_framebuffers.items) |fb| {
        c.vkDestroyFramebuffer(vk, fb, null);
    }
    ctx.render_pass_manager.post_process_framebuffers.deinit(ctx.allocator);
    ctx.render_pass_manager.post_process_framebuffers = .empty;

    ctx.post_process.deinit(vk, ctx.descriptors.descriptor_pool);

    if (ctx.render_pass_manager.post_process_render_pass != null) {
        c.vkDestroyRenderPass(vk, ctx.render_pass_manager.post_process_render_pass, null);
        ctx.render_pass_manager.post_process_render_pass = null;
    }

    destroySwapchainUIResources(ctx);
}

pub fn destroyGPassResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    ctx.depth_pyramid.deinit(vk);
    ctx.ssao_system.deinit(vk, ctx.allocator, ctx.descriptors.descriptor_pool);
    if (ctx.gpass.g_depth_handle != 0) {
        ctx.resources.destroyTexture(ctx.gpass.g_depth_handle);
        ctx.gpass.g_depth_handle = 0;
    }
    if (ctx.pipeline_manager.g_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.pipeline_manager.g_pipeline, null);
        ctx.pipeline_manager.g_pipeline = null;
    }
    if (ctx.render_pass_manager.g_framebuffer != null) {
        c.vkDestroyFramebuffer(vk, ctx.render_pass_manager.g_framebuffer, null);
        ctx.render_pass_manager.g_framebuffer = null;
    }
    destroyVelocityResources(ctx);
    if (ctx.render_pass_manager.g_render_pass != null) {
        c.vkDestroyRenderPass(vk, ctx.render_pass_manager.g_render_pass, null);
        ctx.render_pass_manager.g_render_pass = null;
    }
    if (ctx.gpass.g_normal_view != null) {
        c.vkDestroyImageView(vk, ctx.gpass.g_normal_view, null);
        ctx.gpass.g_normal_view = null;
    }
    if (ctx.gpass.g_normal_image != null) {
        c.vkDestroyImage(vk, ctx.gpass.g_normal_image, null);
        ctx.gpass.g_normal_image = null;
    }
    if (ctx.gpass.g_normal_memory != null) {
        c.vkFreeMemory(vk, ctx.gpass.g_normal_memory, null);
        ctx.gpass.g_normal_memory = null;
    }
    if (ctx.gpass.g_depth_view != null) {
        c.vkDestroyImageView(vk, ctx.gpass.g_depth_view, null);
        ctx.gpass.g_depth_view = null;
    }
    if (ctx.gpass.g_depth_image != null) {
        c.vkDestroyImage(vk, ctx.gpass.g_depth_image, null);
        ctx.gpass.g_depth_image = null;
    }
    if (ctx.gpass.g_depth_memory != null) {
        c.vkFreeMemory(vk, ctx.gpass.g_depth_memory, null);
        ctx.gpass.g_depth_memory = null;
    }
    if (ctx.gpass.g_depth_sampler != null) {
        c.vkDestroySampler(vk, ctx.gpass.g_depth_sampler, null);
        ctx.gpass.g_depth_sampler = null;
    }
}

pub fn destroySwapchainUIPipelines(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    if (ctx.pipeline_manager.ui_swapchain_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.pipeline_manager.ui_swapchain_pipeline, null);
        ctx.pipeline_manager.ui_swapchain_pipeline = null;
    }
    if (ctx.pipeline_manager.ui_swapchain_tex_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.pipeline_manager.ui_swapchain_tex_pipeline, null);
        ctx.pipeline_manager.ui_swapchain_tex_pipeline = null;
    }
    if (ctx.pipeline_manager.rml_ui_swapchain_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.pipeline_manager.rml_ui_swapchain_pipeline, null);
        ctx.pipeline_manager.rml_ui_swapchain_pipeline = null;
    }
    if (ctx.pipeline_manager.rml_ui_swapchain_tex_pipeline != null) {
        c.vkDestroyPipeline(vk, ctx.pipeline_manager.rml_ui_swapchain_tex_pipeline, null);
        ctx.pipeline_manager.rml_ui_swapchain_tex_pipeline = null;
    }
}

pub fn destroySwapchainUIResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    for (ctx.render_pass_manager.ui_swapchain_framebuffers.items) |fb| {
        c.vkDestroyFramebuffer(vk, fb, null);
    }
    ctx.render_pass_manager.ui_swapchain_framebuffers.deinit(ctx.allocator);
    ctx.render_pass_manager.ui_swapchain_framebuffers = .empty;

    if (ctx.render_pass_manager.ui_swapchain_render_pass) |rp| {
        c.vkDestroyRenderPass(vk, rp, null);
        ctx.render_pass_manager.ui_swapchain_render_pass = null;
    }
}

pub fn destroyFXAAResources(ctx: anytype) void {
    destroySwapchainUIPipelines(ctx);
    ctx.fxaa.deinit(ctx.vulkan_device.vk_device, ctx.allocator, ctx.descriptors.descriptor_pool);
}

pub fn destroyBloomResources(ctx: anytype) void {
    ctx.bloom.deinit(ctx.vulkan_device.vk_device, ctx.allocator, ctx.descriptors.descriptor_pool);
}

pub fn destroyTAAResources(ctx: anytype) void {
    ctx.taa.deinit(ctx.vulkan_device.vk_device, ctx.descriptors.descriptor_pool, &ctx.resources);
}

pub fn destroyVelocityResources(ctx: anytype) void {
    const vk = ctx.vulkan_device.vk_device;
    if (vk == null) return;

    if (ctx.velocity.velocity_view != null) {
        c.vkDestroyImageView(vk, ctx.velocity.velocity_view, null);
        ctx.velocity.velocity_view = null;
    }
    if (ctx.velocity.velocity_image != null) {
        c.vkDestroyImage(vk, ctx.velocity.velocity_image, null);
        ctx.velocity.velocity_image = null;
    }
    if (ctx.velocity.velocity_memory != null) {
        c.vkFreeMemory(vk, ctx.velocity.velocity_memory, null);
        ctx.velocity.velocity_memory = null;
    }
}

pub fn transitionImagesToShaderRead(ctx: anytype, images: []const c.VkImage, is_depth: bool, layer_count: u32) !void {
    if (ctx.runtime.recovering) return;

    const aspect_mask: c.VkImageAspectFlags = if (is_depth) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandPool = ctx.frames.command_pool;
    alloc_info.commandBufferCount = 1;

    var cmd: c.VkCommandBuffer = null;
    try Utils.checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &alloc_info, &cmd));
    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

    const count = images.len;
    var barriers: [16]c.VkImageMemoryBarrier = undefined;
    for (0..count) |i| {
        barriers[i] = std.mem.zeroes(c.VkImageMemoryBarrier);
        barriers[i].sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barriers[i].oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[i].newLayout = if (is_depth)
            c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
        else
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barriers[i].srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].image = images[i];
        barriers[i].subresourceRange = .{ .aspectMask = aspect_mask, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = layer_count };
        barriers[i].srcAccessMask = 0;
        barriers[i].dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
    }

    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, @intCast(count), &barriers[0]);

    try Utils.checkVk(c.vkEndCommandBuffer(cmd));

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;
    try ctx.vulkan_device.submitGuarded(submit_info, null);
    try Utils.checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));
    c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.frames.command_pool, 1, &cmd);
}

pub fn transitionImagesToPresent(ctx: anytype, images: []const c.VkImage) !void {
    return transitionImagesFromUndefined(ctx, images, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
}

/// Headless final-composition passes load and retain this layout between
/// frames, so the offscreen image needs an explicit first-use transition.
pub fn transitionImagesToColorAttachment(ctx: anytype, images: []const c.VkImage) !void {
    return transitionImagesFromUndefined(
        ctx,
        images,
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    );
}

fn transitionImagesFromUndefined(ctx: anytype, images: []const c.VkImage, layout: c.VkImageLayout, dst_stage: c.VkPipelineStageFlags, dst_access: c.VkAccessFlags) !void {
    if (ctx.runtime.recovering) return;

    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandPool = ctx.frames.command_pool;
    alloc_info.commandBufferCount = 1;

    var cmd: c.VkCommandBuffer = null;
    try Utils.checkVk(c.vkAllocateCommandBuffers(ctx.vulkan_device.vk_device, &alloc_info, &cmd));

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

    const count = images.len;
    var barriers: [16]c.VkImageMemoryBarrier = undefined;
    for (0..count) |i| {
        barriers[i] = std.mem.zeroes(c.VkImageMemoryBarrier);
        barriers[i].sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barriers[i].oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barriers[i].newLayout = layout;
        barriers[i].srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barriers[i].image = images[i];
        barriers[i].subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        barriers[i].srcAccessMask = 0;
        barriers[i].dstAccessMask = dst_access;
    }

    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, dst_stage, 0, 0, null, 0, null, @intCast(count), &barriers[0]);

    try Utils.checkVk(c.vkEndCommandBuffer(cmd));

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;
    try ctx.vulkan_device.submitGuarded(submit_info, null);
    try Utils.checkVk(c.vkQueueWaitIdle(ctx.vulkan_device.queue));
    c.vkFreeCommandBuffers(ctx.vulkan_device.vk_device, ctx.frames.command_pool, 1, &cmd);
}

pub fn createHDRResources(ctx: anytype) !void {
    const extent = ctx.swapchain.getExtent();
    if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
    errdefer destroyHDRResources(ctx);
    const format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    const sample_count: c_uint = @intCast(switch (ctx.options.msaa_samples) {
        1 => c.VK_SAMPLE_COUNT_1_BIT,
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    });

    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &image_info, null, &ctx.hdr.hdr_image));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.hdr.hdr_image, &mem_reqs);
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(ctx.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &alloc_info, null, &ctx.hdr.hdr_memory));
    try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.hdr.hdr_image, ctx.hdr.hdr_memory, 0));

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = ctx.hdr.hdr_image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = format;
    view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &view_info, null, &ctx.hdr.hdr_view));

    if (ctx.options.msaa_samples > 1) {
        var msaa_info = std.mem.zeroes(c.VkImageCreateInfo);
        msaa_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        msaa_info.imageType = c.VK_IMAGE_TYPE_2D;
        msaa_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        msaa_info.mipLevels = 1;
        msaa_info.arrayLayers = 1;
        msaa_info.format = format;
        msaa_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        msaa_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        msaa_info.usage = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        msaa_info.samples = sample_count;
        msaa_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(ctx.vulkan_device.vk_device, &msaa_info, null, &ctx.hdr.hdr_msaa_image));

        var msaa_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.vulkan_device.vk_device, ctx.hdr.hdr_msaa_image, &msaa_reqs);
        var msaa_alloc = std.mem.zeroes(c.VkMemoryAllocateInfo);
        msaa_alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        msaa_alloc.allocationSize = msaa_reqs.size;
        msaa_alloc.memoryTypeIndex = Utils.findMemoryType(ctx.vulkan_device.physical_device, msaa_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT | c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) catch
            try Utils.findMemoryType(ctx.vulkan_device.physical_device, msaa_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(ctx.vulkan_device.vk_device, &msaa_alloc, null, &ctx.hdr.hdr_msaa_memory));
        try Utils.checkVk(c.vkBindImageMemory(ctx.vulkan_device.vk_device, ctx.hdr.hdr_msaa_image, ctx.hdr.hdr_msaa_memory, 0));

        var msaa_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        msaa_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        msaa_view_info.image = ctx.hdr.hdr_msaa_image;
        msaa_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        msaa_view_info.format = format;
        msaa_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(ctx.vulkan_device.vk_device, &msaa_view_info, null, &ctx.hdr.hdr_msaa_view));
    }
}
