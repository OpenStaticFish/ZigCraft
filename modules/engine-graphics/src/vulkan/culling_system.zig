const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi_pkg = @import("engine-rhi").rhi;
const culling = @import("engine-rhi").culling;
const log = @import("engine-core").log;
const Mat4 = @import("engine-math").Mat4;
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
const Utils = @import("utils.zig");

pub const CULLING_SHADER_PATH = "assets/shaders/vulkan/culling.comp.spv";
pub const MAX_CULLABLE_CHUNKS: usize = 16384;
pub const WORKGROUP_SIZE: u32 = 64;
const MAX_FRAMES_IN_FLIGHT = rhi_pkg.MAX_FRAMES_IN_FLIGHT;

pub const ChunkCullData = culling.ChunkCullData;

const CullingPushConstants = extern struct {
    planes: [6][4]f32,
    chunk_count: u32,
};

pub const CullingSystem = struct {
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,

    aabb_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    visible_index_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_readback_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    cached_view_proj: Mat4 = Mat4.zero,
    cached_planes: CullingPushConstants = undefined,
    planes_cached: bool = false,

    max_chunks: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        vk_ctx: *VulkanContext,
        max_chunks: usize,
    ) !*CullingSystem {
        const self = try allocator.create(CullingSystem);
        errdefer allocator.destroy(self);

        const clamped_max = std.math.clamp(max_chunks, 1, MAX_CULLABLE_CHUNKS);

        self.* = .{
            .allocator = allocator,
            .vk_ctx = vk_ctx,
            .max_chunks = clamped_max,
            .aabb_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .visible_index_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet),
            .planes_cached = false,
        };

        errdefer self.destroyAllBuffers();
        const aabb_size = clamped_max * @sizeOf(ChunkCullData);
        const index_buffer_size = @sizeOf(u32) * 4 + clamped_max * @sizeOf(u32);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.aabb_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                aabb_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            self.visible_index_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                index_buffer_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );

            self.counter_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                @sizeOf(u32),
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            );

            self.counter_readback_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                @sizeOf(u32),
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }

        try ensureShaderFileExists(CULLING_SHADER_PATH);

        errdefer self.deinitComputeResources();
        try self.initComputeResources();

        return self;
    }

    pub fn deinit(self: *CullingSystem) void {
        self.deinitComputeResources();
        self.destroyAllBuffers();
        self.allocator.destroy(self);
    }

    pub fn interface(self: *CullingSystem) culling.ICullingSystem {
        return .{
            .ptr = self,
            .vtable = &interface_vtable,
        };
    }

    pub fn updateAABBData(self: *CullingSystem, frame_index: usize, chunks: []const ChunkCullData) void {
        const buf = &self.aabb_buffers[frame_index];
        if (buf.mapped_ptr == null) return;
        const copy_len = @min(chunks.len, self.max_chunks) * @sizeOf(ChunkCullData);
        if (copy_len == 0) return;
        @memcpy(
            @as([*]u8, @ptrCast(buf.mapped_ptr.?))[0..copy_len],
            @as([*]const u8, @ptrCast(chunks.ptr))[0..copy_len],
        );
    }

    pub fn dispatch(
        self: *CullingSystem,
        view_proj: Mat4,
        chunk_count: u32,
    ) void {
        if (chunk_count == 0) return;
        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi];
        if (cmd == null) return;

        var prev_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        prev_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        prev_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        prev_barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &prev_barrier,
            0,
            null,
            0,
            null,
        );

        self.resetCounter(cmd, fi);

        var host_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        host_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        host_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        host_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &host_barrier,
            0,
            null,
            0,
            null,
        );

        self.cached_planes.chunk_count = @min(chunk_count, @as(u32, @intCast(self.max_chunks)));

        if (!self.planes_cached or !mat4Equal(self.cached_view_proj, view_proj)) {
            self.cached_planes.planes = extractPlanes(view_proj);
            self.cached_view_proj = view_proj;
            self.planes_cached = true;
        }
        const push = self.cached_planes;

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[fi], 0, null);
        c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(CullingPushConstants), &push);

        const clamped_count = @min(chunk_count, @as(u32, @intCast(self.max_chunks)));
        const groups = divCeil(clamped_count, WORKGROUP_SIZE);
        c.vkCmdDispatch(cmd, groups, 1, 1);

        var compute_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        compute_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &compute_barrier,
            0,
            null,
            0,
            null,
        );

        self.copyCounterToReadback(cmd, fi);
    }

    pub fn readVisibleCount(self: *CullingSystem, frame_index: usize) u32 {
        const buf = &self.counter_readback_buffers[frame_index];
        if (buf.mapped_ptr == null) return 0;
        const ptr: *align(1) u32 = @ptrCast(@alignCast(buf.mapped_ptr.?));
        return ptr.*;
    }

    pub fn readVisibleIndices(self: *CullingSystem, frame_index: usize, count: u32, out: []u32) void {
        if (count == 0) return;
        const buf = &self.visible_index_buffers[frame_index];
        if (buf.mapped_ptr == null) return;
        const copy_count = @min(@as(usize, @intCast(count)), @min(out.len, self.max_chunks));
        if (copy_count == 0) return;
        const src: [*]const u32 = @ptrCast(@alignCast(buf.mapped_ptr.?));
        @memcpy(out[0..copy_count], src[4 .. 4 + copy_count]);
    }

    fn copyCounterToReadback(self: *CullingSystem, cmd: c.VkCommandBuffer, frame_index: usize) void {
        const src = self.counter_buffers[frame_index];
        const dst = self.counter_readback_buffers[frame_index];

        var copy_region = std.mem.zeroes(c.VkBufferCopy);
        copy_region.srcOffset = 0;
        copy_region.dstOffset = 0;
        copy_region.size = @sizeOf(u32);
        c.vkCmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &copy_region);

        var copy_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        copy_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        copy_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        copy_barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            1,
            &copy_barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn resetCounter(self: *CullingSystem, cmd: c.VkCommandBuffer, frame_index: usize) void {
        const zero: u32 = 0;
        c.vkCmdFillBuffer(cmd, self.counter_buffers[frame_index].buffer, 0, @sizeOf(u32), zero);

        var fill_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        fill_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        fill_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        fill_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &fill_barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn initComputeResources(self: *CullingSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 3 * MAX_FRAMES_IN_FLIGHT },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = MAX_FRAMES_IN_FLIGHT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        var layouts = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout);
        for (&layouts) |*l| l.* = self.descriptor_set_layout;

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = MAX_FRAMES_IN_FLIGHT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));

        self.updateAllDescriptorSets();

        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(CullingPushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, CULLING_SHADER_PATH, self.allocator);
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
    }

    fn updateAllDescriptorSets(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        const aabb_range = self.max_chunks * @sizeOf(ChunkCullData);

        var writes: [3 * MAX_FRAMES_IN_FLIGHT]c.VkWriteDescriptorSet = undefined;
        var aabb_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var index_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var counter_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            aabb_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.aabb_buffers[i].buffer,
                .offset = 0,
                .range = aabb_range,
            };
            index_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.visible_index_buffers[i].buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };
            counter_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.counter_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(u32),
            };

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 0;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &aabb_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 1;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &index_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 2;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &counter_infos[i];
            n += 1;
        }

        c.vkUpdateDescriptorSets(vk, @intCast(n), &writes[0], 0, null);
    }

    fn deinitComputeResources(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_set_layout = null;
        self.descriptor_pool = null;
        self.descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet);
    }

    fn destroyAllBuffers(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            unmapAndDestroy(vk, &self.aabb_buffers[i]);
            unmapAndDestroy(vk, &self.visible_index_buffers[i]);
            unmapAndDestroy(vk, &self.counter_buffers[i]);
            unmapAndDestroy(vk, &self.counter_readback_buffers[i]);
        }

        self.aabb_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.visible_index_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
    }
};

const interface_vtable = culling.ICullingSystem.VTable{
    .deinit = interfaceDeinit,
    .updateAABBData = interfaceUpdateAabbData,
    .readVisibleCount = interfaceReadVisibleCount,
    .readVisibleIndices = interfaceReadVisibleIndices,
    .dispatch = interfaceDispatch,
};

fn interfaceDeinit(ptr: *anyopaque) void {
    const self: *CullingSystem = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn interfaceUpdateAabbData(ptr: *anyopaque, frame_index: usize, chunks: []const ChunkCullData) void {
    const self: *CullingSystem = @ptrCast(@alignCast(ptr));
    self.updateAABBData(frame_index, chunks);
}

fn interfaceReadVisibleCount(ptr: *anyopaque, frame_index: usize) u32 {
    const self: *CullingSystem = @ptrCast(@alignCast(ptr));
    return self.readVisibleCount(frame_index);
}

fn interfaceReadVisibleIndices(ptr: *anyopaque, frame_index: usize, count: u32, out: []u32) void {
    const self: *CullingSystem = @ptrCast(@alignCast(ptr));
    self.readVisibleIndices(frame_index, count, out);
}

fn interfaceDispatch(ptr: *anyopaque, config: culling.DispatchConfig) void {
    const self: *CullingSystem = @ptrCast(@alignCast(ptr));
    self.dispatch(config.view_proj, config.chunk_count);
}

fn mat4Equal(a: Mat4, b: Mat4) bool {
    for (0..4) |col| {
        for (0..4) |row| {
            if (a.data[col][row] != b.data[col][row]) return false;
        }
    }
    return true;
}

fn unmapAndDestroy(vk: c.VkDevice, buf: *Utils.VulkanBuffer) void {
    if (buf.mapped_ptr != null) {
        c.vkUnmapMemory(vk, buf.memory);
        buf.mapped_ptr = null;
    }
    if (buf.buffer != null) c.vkDestroyBuffer(vk, buf.buffer, null);
    if (buf.memory != null) c.vkFreeMemory(vk, buf.memory, null);
    buf.* = .{};
}

fn extractPlanes(vp: Mat4) [6][4]f32 {
    const m = vp.data;
    var planes: [6][4]f32 = undefined;

    planes[0] = .{ m[3][0] + m[0][0], m[3][1] + m[0][1], m[3][2] + m[0][2], m[3][3] + m[0][3] };
    planes[1] = .{ m[3][0] - m[0][0], m[3][1] - m[0][1], m[3][2] - m[0][2], m[3][3] - m[0][3] };
    planes[2] = .{ m[3][0] - m[1][0], m[3][1] - m[1][1], m[3][2] - m[1][2], m[3][3] - m[1][3] };
    planes[3] = .{ m[3][0] + m[1][0], m[3][1] + m[1][1], m[3][2] + m[1][2], m[3][3] + m[1][3] };
    planes[4] = .{ m[3][0] + m[2][0], m[3][1] + m[2][1], m[3][2] + m[2][2], m[3][3] + m[2][3] };
    planes[5] = .{ m[3][0] - m[2][0], m[3][1] - m[2][1], m[3][2] - m[2][2], m[3][3] - m[2][3] };

    for (&planes) |*plane| {
        const len = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        if (len > 0.0001) {
            plane[0] /= len;
            plane[1] /= len;
            plane[2] /= len;
            plane[3] /= len;
        }
    }

    return planes;
}

fn loadShaderModule(vk: c.VkDevice, path: []const u8, allocator: std.mem.Allocator) !c.VkShaderModule {
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

fn ensureShaderFileExists(path: []const u8) !void {
    fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("Culling shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `devenv shell zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}
