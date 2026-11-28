const std = @import("std");
const fs = @import("fs");
const Allocator = std.mem.Allocator;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Utils = @import("utils.zig");
const VulkanDevice = @import("device.zig").VulkanDevice;

pub const DEPTH_PYRAMID_SHADER_PATH = "assets/shaders/vulkan/depth_pyramid.comp.spv";
pub const DEPTH_PYRAMID_WORKGROUP_SIZE: u32 = 8;
const MAX_MIP_LEVELS: u32 = 16;
// Descriptor set arrays sized by MAX_FRAMES_IN_FLIGHT; must match RHI frame count.
const MAX_FRAMES_IN_FLIGHT = rhi.MAX_FRAMES_IN_FLIGHT;

const PushConstants = extern struct {
    mip_level: u32,
    _padding: u32 = 0,
    inv_src_size: [2]f32,
};

pub const DepthPyramidSystem = struct {
    pyramid_image: c.VkImage = null,
    pyramid_memory: c.VkDeviceMemory = null,
    pyramid_view: c.VkImageView = null,
    pyramid_sampler: c.VkSampler = null,
    pyramid_layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    recorded: bool = false,
    mip_count: u32 = 0,
    mip_widths: [MAX_MIP_LEVELS]u32 = .{0} ** MAX_MIP_LEVELS,
    mip_heights: [MAX_MIP_LEVELS]u32 = .{0} ** MAX_MIP_LEVELS,

    per_mip_views: [MAX_MIP_LEVELS]c.VkImageView = .{null} ** MAX_MIP_LEVELS,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT][MAX_MIP_LEVELS]c.VkDescriptorSet = .{.{null} ** MAX_MIP_LEVELS} ** MAX_FRAMES_IN_FLIGHT,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    width: u32 = 0,
    height: u32 = 0,

    pub fn getPyramidImageView(self: *const DepthPyramidSystem) c.VkImageView {
        return self.pyramid_view;
    }

    pub fn getPyramidSampler(self: *const DepthPyramidSystem) c.VkSampler {
        return self.pyramid_sampler;
    }

    pub fn isValid(self: *const DepthPyramidSystem) bool {
        return self.pipeline != null and self.pyramid_view != null;
    }

    pub fn init(
        self: *DepthPyramidSystem,
        device: *const VulkanDevice,
        allocator: Allocator,
        depth_view: c.VkImageView,
        width: u32,
        height: u32,
    ) !void {
        self.deinit(device.vk_device);
        const vk = device.vk_device;

        errdefer self.deinit(vk);

        self.width = width;
        self.height = height;
        self.pyramid_layout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        const max_dim = @max(width, height);
        self.mip_count = if (max_dim > 0) std.math.log2_int(u32, max_dim) + 1 else 1;
        if (self.mip_count > MAX_MIP_LEVELS) self.mip_count = MAX_MIP_LEVELS;

        for (0..self.mip_count) |i| {
            const div = @as(u32, 1) << @intCast(i);
            self.mip_widths[i] = @max(1, @divFloor(width, div));
            self.mip_heights[i] = @max(1, @divFloor(height, div));
        }

        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.format = c.VK_FORMAT_R32_SFLOAT;
        img_info.extent = .{ .width = width, .height = height, .depth = 1 };
        img_info.mipLevels = self.mip_count;
        img_info.arrayLayers = 1;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &self.pyramid_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, self.pyramid_image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.pyramid_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, self.pyramid_image, self.pyramid_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.pyramid_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R32_SFLOAT;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = self.mip_count, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.pyramid_view));

        for (0..self.mip_count) |i| {
            var mip_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            mip_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            mip_view_info.image = self.pyramid_image;
            mip_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            mip_view_info.format = c.VK_FORMAT_R32_SFLOAT;
            mip_view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = @intCast(i), .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try Utils.checkVk(c.vkCreateImageView(vk, &mip_view_info, null, &self.per_mip_views[i]));
        }

        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_NEAREST;
        sampler_info.minFilter = c.VK_FILTER_NEAREST;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler_info.anisotropyEnable = c.VK_FALSE;
        sampler_info.maxAnisotropy = 1.0;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.pyramid_sampler));

        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = self.mip_count * MAX_FRAMES_IN_FLIGHT },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = self.mip_count * MAX_FRAMES_IN_FLIGHT },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = self.mip_count * MAX_FRAMES_IN_FLIGHT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        const total_sets = self.mip_count * MAX_FRAMES_IN_FLIGHT;
        var layouts: [MAX_MIP_LEVELS * MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout = undefined;
        for (0..total_sets) |i| layouts[i] = self.descriptor_set_layout;

        var ds_alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        ds_alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ds_alloc_info.descriptorPool = self.descriptor_pool;
        ds_alloc_info.descriptorSetCount = total_sets;
        ds_alloc_info.pSetLayouts = &layouts;

        var flat_sets: [MAX_MIP_LEVELS * MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = undefined;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &ds_alloc_info, &flat_sets));

        for (0..MAX_FRAMES_IN_FLIGHT) |frame| {
            for (0..self.mip_count) |mip| {
                self.descriptor_sets[frame][mip] = flat_sets[frame * self.mip_count + mip];
            }
        }

        self.updateDescriptorSets(vk, depth_view);

        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(PushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, DEPTH_PYRAMID_SHADER_PATH, allocator);
        defer c.vkDestroyShaderModule(vk, shader_module, null);

        var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        stage.module = shader_module;
        stage.pName = "main";

        var pipeline_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipeline_info.stage = stage;
        pipeline_info.layout = self.pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &pipeline_info, null, &self.pipeline));

        log.log.info("DepthPyramidSystem initialized: {}x{}, {} mip levels", .{ width, height, self.mip_count });
    }

    fn updateDescriptorSets(self: *DepthPyramidSystem, vk: c.VkDevice, depth_view: c.VkImageView) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |frame| {
            {
                var src_info = c.VkDescriptorImageInfo{
                    .sampler = self.pyramid_sampler,
                    .imageView = depth_view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
                };
                var dst_info = c.VkDescriptorImageInfo{
                    .sampler = null,
                    .imageView = self.per_mip_views[0],
                    .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                };
                var writes = [_]c.VkWriteDescriptorSet{
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][0],
                        .dstBinding = 0,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &src_info,
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][0],
                        .dstBinding = 1,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                        .descriptorCount = 1,
                        .pImageInfo = &dst_info,
                    },
                };
                c.vkUpdateDescriptorSets(vk, writes.len, &writes[0], 0, null);
            }

            for (1..self.mip_count) |mip| {
                var src_info = c.VkDescriptorImageInfo{
                    .sampler = self.pyramid_sampler,
                    .imageView = self.pyramid_view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                };
                var dst_info = c.VkDescriptorImageInfo{
                    .sampler = null,
                    .imageView = self.per_mip_views[mip],
                    .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                };
                var writes = [_]c.VkWriteDescriptorSet{
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][mip],
                        .dstBinding = 0,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        .descriptorCount = 1,
                        .pImageInfo = &src_info,
                    },
                    .{
                        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                        .dstSet = self.descriptor_sets[frame][mip],
                        .dstBinding = 1,
                        .dstArrayElement = 0,
                        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                        .descriptorCount = 1,
                        .pImageInfo = &dst_info,
                    },
                };
                c.vkUpdateDescriptorSets(vk, writes.len, &writes[0], 0, null);
            }
        }
    }

    pub fn compute(
        self: *DepthPyramidSystem,
        command_buffer: c.VkCommandBuffer,
        frame: usize,
        _depth_image: c.VkImage,
        depth_width: u32,
        depth_height: u32,
    ) void {
        if (self.pipeline == null) return;
        if (self.mip_count == 0) return;
        if (command_buffer == null) return;
        _ = _depth_image;

        {
            var pyramid_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            pyramid_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            pyramid_barrier.oldLayout = if (self.recorded) c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else self.pyramid_layout;
            if (pyramid_barrier.oldLayout != c.VK_IMAGE_LAYOUT_UNDEFINED) {
                pyramid_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            }
            pyramid_barrier.dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            pyramid_barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
            pyramid_barrier.image = self.pyramid_image;
            pyramid_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            pyramid_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            pyramid_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = self.mip_count, .baseArrayLayer = 0, .layerCount = 1 };
            c.vkCmdPipelineBarrier(
                command_buffer,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &pyramid_barrier,
            );
        }

        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);

        for (0..self.mip_count) |mip| {
            const mip_w = self.mip_widths[mip];
            const mip_h = self.mip_heights[mip];

            c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[frame][mip], 0, null);

            const src_w: f32 = if (mip == 0) @floatFromInt(depth_width) else @floatFromInt(self.mip_widths[mip - 1]);
            const src_h: f32 = if (mip == 0) @floatFromInt(depth_height) else @floatFromInt(self.mip_heights[mip - 1]);

            const push = PushConstants{
                .mip_level = @intCast(mip),
                .inv_src_size = .{ 1.0 / src_w, 1.0 / src_h },
            };
            c.vkCmdPushConstants(command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &push);

            const groups_x = divCeil(mip_w, DEPTH_PYRAMID_WORKGROUP_SIZE);
            const groups_y = divCeil(mip_h, DEPTH_PYRAMID_WORKGROUP_SIZE);
            c.vkCmdDispatch(command_buffer, groups_x, groups_y, 1);

            if (mip < self.mip_count - 1) {
                var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
                barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
                barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_GENERAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
                barrier.image = self.pyramid_image;
                barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = @intCast(mip), .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
                c.vkCmdPipelineBarrier(
                    command_buffer,
                    c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    0,
                    0,
                    null,
                    0,
                    null,
                    1,
                    &barrier,
                );
            }
        }

        {
            var final_barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            final_barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            final_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            final_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            final_barrier.oldLayout = c.VK_IMAGE_LAYOUT_GENERAL;
            final_barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            final_barrier.image = self.pyramid_image;
            final_barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            final_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            final_barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = self.mip_count, .baseArrayLayer = 0, .layerCount = 1 };
            c.vkCmdPipelineBarrier(
                command_buffer,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                1,
                &final_barrier,
            );

            self.recorded = true;
        }
    }

    pub fn deinit(self: *DepthPyramidSystem, device: c.VkDevice) void {
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
        if (self.descriptor_pool != null) {
            c.vkDestroyDescriptorPool(device, self.descriptor_pool, null);
            self.descriptor_pool = null;
        }
        self.descriptor_sets = .{.{null} ** MAX_MIP_LEVELS} ** MAX_FRAMES_IN_FLIGHT;

        for (&self.per_mip_views) |*view| {
            if (view.* != null) {
                c.vkDestroyImageView(device, view.*, null);
                view.* = null;
            }
        }

        if (self.pyramid_sampler != null) {
            c.vkDestroySampler(device, self.pyramid_sampler, null);
            self.pyramid_sampler = null;
        }
        if (self.pyramid_view != null) {
            c.vkDestroyImageView(device, self.pyramid_view, null);
            self.pyramid_view = null;
        }
        if (self.pyramid_image != null) {
            c.vkDestroyImage(device, self.pyramid_image, null);
            self.pyramid_image = null;
        }
        if (self.pyramid_memory != null) {
            c.vkFreeMemory(device, self.pyramid_memory, null);
            self.pyramid_memory = null;
        }

        self.pyramid_layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        self.recorded = false;
        self.mip_count = 0;
        self.width = 0;
        self.height = 0;
    }
};

fn loadShaderModule(vk: c.VkDevice, path: []const u8, allocator: Allocator) !c.VkShaderModule {
    const bytes = try fs.cwd().readFileAlloc(path, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));

    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(vk, &info, null, &module));
    return module;
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}
