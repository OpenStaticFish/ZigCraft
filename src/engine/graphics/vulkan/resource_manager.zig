const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");

/// Vulkan buffer with backing memory.
pub const VulkanBuffer = Utils.VulkanBuffer;

/// Vulkan texture with image, view, and sampler.
pub const TextureResource = struct {
    image: ?c.VkImage,
    memory: ?c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    width: u32,
    height: u32,
    format: rhi.TextureFormat,
    config: rhi.TextureConfig,
    is_owned: bool = true,
};

const ZombieBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
};

const ZombieImage = struct {
    image: ?c.VkImage,
    memory: ?c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    is_owned: bool,
};

/// Per-frame linear staging buffer for async uploads.
const StagingBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,
    current_offset: u64,
    mapped_ptr: ?*anyopaque,

    fn init(device: *const VulkanDevice, size: u64) !StagingBuffer {
        const buf = try Utils.createVulkanBuffer(device, size, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (buf.buffer == null) return error.VulkanError;

        var mapped: ?*anyopaque = null;
        try Utils.checkVk(c.vkMapMemory(device.vk_device, buf.memory, 0, size, 0, &mapped));

        return StagingBuffer{
            .buffer = buf.buffer,
            .memory = buf.memory,
            .size = size,
            .current_offset = 0,
            .mapped_ptr = mapped,
        };
    }

    fn deinit(self: *StagingBuffer, device: c.VkDevice) void {
        if (self.mapped_ptr != null) {
            c.vkUnmapMemory(device, self.memory);
        }
        c.vkDestroyBuffer(device, self.buffer, null);
        c.vkFreeMemory(device, self.memory, null);
    }

    fn reset(self: *StagingBuffer) void {
        self.current_offset = 0;
    }

    /// Allocates space in the staging buffer. Returns offset if successful, null if full.
    /// Aligns allocation to 256 bytes (common minUniformBufferOffsetAlignment/optimal copy offset).
    fn allocate(self: *StagingBuffer, size: u64) ?u64 {
        const alignment = 256; // Safe alignment for most GPU copy operations
        const aligned_offset = std.mem.alignForward(u64, self.current_offset, alignment);

        if (aligned_offset + size > self.size) return null;

        if (self.mapped_ptr == null) return null;

        self.current_offset = aligned_offset + size;
        return aligned_offset;
    }
};

pub const ResourceManager = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *VulkanDevice,

    // Resource tracking
    buffers: std.AutoHashMap(rhi.BufferHandle, VulkanBuffer),
    next_buffer_handle: rhi.BufferHandle,

    textures: std.AutoHashMap(rhi.TextureHandle, TextureResource),
    next_texture_handle: rhi.TextureHandle,

    // Deletion queues
    buffer_deletion_queue: [rhi.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(ZombieBuffer),
    image_deletion_queue: [rhi.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(ZombieImage),

    // Staging
    staging_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]StagingBuffer,
    transfer_command_pool: c.VkCommandPool,
    transfer_command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
    transfer_fence: c.VkFence,
    transfer_ready: bool = false,
    current_frame_index: usize = 0,
    textures_enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator, vulkan_device: *VulkanDevice) !ResourceManager {
        var self = ResourceManager{
            .allocator = allocator,
            .vulkan_device = vulkan_device,
            .buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(allocator),
            .next_buffer_handle = 1,
            .textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(allocator),
            .next_texture_handle = 1,
            .buffer_deletion_queue = undefined,
            .image_deletion_queue = undefined,
            .staging_buffers = undefined,
            .transfer_command_pool = null,
            .transfer_command_buffers = undefined,
            .transfer_fence = null,
        };

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.buffer_deletion_queue[i] = .{};
            self.image_deletion_queue[i] = .{};
            self.staging_buffers[i] = try StagingBuffer.init(vulkan_device, 64 * 1024 * 1024); // 64MB staging buffer
        }

        // Create transfer command pool
        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = vulkan_device.graphics_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try Utils.checkVk(c.vkCreateCommandPool(vulkan_device.vk_device, &pool_info, null, &self.transfer_command_pool));

        // Allocate transfer command buffers
        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.transfer_command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = rhi.MAX_FRAMES_IN_FLIGHT;
        try Utils.checkVk(c.vkAllocateCommandBuffers(vulkan_device.vk_device, &alloc_info, &self.transfer_command_buffers));

        // Create transfer fence
        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = 0; // Not signaled initially
        Utils.checkVk(c.vkCreateFence(vulkan_device.vk_device, &fence_info, null, &self.transfer_fence)) catch |err| {
            std.log.err("Failed to create transfer fence: {}", .{err});
            // Cleanup command pool and buffers before returning to avoid leaks
            if (self.transfer_command_pool != null) {
                c.vkDestroyCommandPool(vulkan_device.vk_device, self.transfer_command_pool, null);
            }
            return err;
        };

        return self;
    }

    pub fn deinit(self: *ResourceManager) void {
        const device = self.vulkan_device.vk_device;
        _ = c.vkDeviceWaitIdle(device);

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.staging_buffers[i].deinit(device);
            for (self.buffer_deletion_queue[i].items) |b| {
                c.vkDestroyBuffer(device, b.buffer, null);
                c.vkFreeMemory(device, b.memory, null);
            }
            self.buffer_deletion_queue[i].deinit(self.allocator);

            for (self.image_deletion_queue[i].items) |img| {
                if (img.is_owned) {
                    c.vkDestroyImageView(device, img.view, null);
                    if (img.image) |image| c.vkDestroyImage(device, image, null);
                    if (img.memory) |memory| c.vkFreeMemory(device, memory, null);
                    c.vkDestroySampler(device, img.sampler, null);
                }
            }
            self.image_deletion_queue[i].deinit(self.allocator);
        }

        var buf_it = self.buffers.valueIterator();
        while (buf_it.next()) |buf| {
            c.vkDestroyBuffer(device, buf.buffer, null);
            c.vkFreeMemory(device, buf.memory, null);
        }
        self.buffers.deinit();

        var tex_it = self.textures.valueIterator();
        while (tex_it.next()) |tex| {
            if (tex.is_owned) {
                c.vkDestroyImageView(device, tex.view, null);
                if (tex.image) |image| c.vkDestroyImage(device, image, null);
                if (tex.memory) |memory| c.vkFreeMemory(device, memory, null);
                c.vkDestroySampler(device, tex.sampler, null);
            }
        }
        self.textures.deinit();

        if (self.transfer_command_pool != null) {
            c.vkDestroyCommandPool(device, self.transfer_command_pool, null);
        }
        if (self.transfer_fence != null) {
            c.vkDestroyFence(device, self.transfer_fence, null);
        }
    }

    /// Flushes any pending transfer commands for the current frame.
    /// This is useful for initialization-time resource uploads that must complete before rendering begins.
    pub fn flushTransfer(self: *ResourceManager) !void {
        if (!self.transfer_ready) return;

        const cb = self.transfer_command_buffers[self.current_frame_index];
        try Utils.checkVk(c.vkEndCommandBuffer(cb));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cb;

        // Use the transfer fence to wait
        try Utils.checkVk(c.vkResetFences(self.vulkan_device.vk_device, 1, &self.transfer_fence));

        self.vulkan_device.mutex.lock();
        const result = c.vkQueueSubmit(self.vulkan_device.queue, 1, &submit_info, self.transfer_fence);
        self.vulkan_device.mutex.unlock();

        if (result != c.VK_SUCCESS) return error.VulkanError;

        try Utils.checkVk(c.vkWaitForFences(self.vulkan_device.vk_device, 1, &self.transfer_fence, c.VK_TRUE, std.math.maxInt(u64)));

        self.transfer_ready = false;

        // Note: We do NOT reset the staging buffer here because other systems might still rely on it
        // being valid until the next frame. However, for init-time flush, we can reset it.
        // Let's reset it to be safe for next usage.
        self.staging_buffers[self.current_frame_index].reset();
    }

    pub fn setCurrentFrame(self: *ResourceManager, frame_index: usize) void {
        self.current_frame_index = frame_index;
        self.transfer_ready = false; // Reset for new frame
        self.staging_buffers[frame_index].reset();

        // Process deletion queue for this frame
        const device = self.vulkan_device.vk_device;
        for (self.buffer_deletion_queue[frame_index].items) |b| {
            c.vkDestroyBuffer(device, b.buffer, null);
            c.vkFreeMemory(device, b.memory, null);
        }
        self.buffer_deletion_queue[frame_index].clearRetainingCapacity();

        for (self.image_deletion_queue[frame_index].items) |img| {
            if (img.is_owned) {
                c.vkDestroyImageView(device, img.view, null);
                if (img.image) |image| c.vkDestroyImage(device, image, null);
                if (img.memory) |memory| c.vkFreeMemory(device, memory, null);
                c.vkDestroySampler(device, img.sampler, null);
            }
        }
        self.image_deletion_queue[frame_index].clearRetainingCapacity();
    }

    pub fn resetTransferState(self: *ResourceManager) void {
        self.transfer_ready = false;
    }

    fn prepareTransfer(self: *ResourceManager) !c.VkCommandBuffer {
        if (self.transfer_ready) return self.transfer_command_buffers[self.current_frame_index];

        const cb = self.transfer_command_buffers[self.current_frame_index];
        try Utils.checkVk(c.vkResetCommandBuffer(cb, 0));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try Utils.checkVk(c.vkBeginCommandBuffer(cb, &begin_info));

        self.transfer_ready = true;
        return cb;
    }

    pub fn getTransferCommandBuffer(self: *ResourceManager) ?c.VkCommandBuffer {
        if (!self.transfer_ready) return null;
        return self.transfer_command_buffers[self.current_frame_index];
    }

    pub fn createBuffer(self: *ResourceManager, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
        const vk_usage: c.VkBufferUsageFlags = switch (usage) {
            .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .index => c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .indirect => c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .storage => c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        };

        const properties = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const buf = try Utils.createVulkanBuffer(self.vulkan_device, size, vk_usage, properties);

        const handle = self.next_buffer_handle;
        self.next_buffer_handle += 1;
        try self.buffers.put(handle, buf);

        return handle;
    }

    pub fn destroyBuffer(self: *ResourceManager, handle: rhi.BufferHandle) void {
        const buf = self.buffers.get(handle) orelse {
            std.debug.assert(handle != rhi.InvalidBufferHandle);
            return;
        };
        _ = self.buffers.remove(handle);
        self.buffer_deletion_queue[self.current_frame_index].append(self.allocator, .{ .buffer = buf.buffer, .memory = buf.memory }) catch |err| {
            std.log.err("Failed to queue buffer deletion: {}", .{err});
        };
    }

    pub fn uploadBuffer(self: *ResourceManager, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
        return self.updateBuffer(handle, 0, data);
    }

    pub fn updateBuffer(self: *ResourceManager, handle: rhi.BufferHandle, offset: usize, data: []const u8) rhi.RhiError!void {
        const buf = self.buffers.get(handle) orelse return;

        const staging = &self.staging_buffers[self.current_frame_index];
        const staging_offset = staging.allocate(data.len) orelse {
            std.log.err("Staging buffer overflow in updateBuffer! Data dropped.", .{});
            return error.OutOfMemory;
        };

        if (staging.mapped_ptr == null) return error.OutOfMemory;
        const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + staging_offset;
        @memcpy(dest[0..data.len], data);

        const cmd = try self.prepareTransfer();

        var region = std.mem.zeroes(c.VkBufferCopy);
        region.srcOffset = staging_offset;
        region.dstOffset = offset;
        region.size = data.len;

        c.vkCmdCopyBuffer(cmd, staging.buffer, buf.buffer, 1, &region);

        // Ensure visibility for subsequent stages
        var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.buffer = buf.buffer;
        barrier.offset = offset;
        barrier.size = data.len;

        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT, 0, 0, null, 1, &barrier, 0, null);
    }

    pub fn mapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
        const buf = self.buffers.get(handle) orelse return null;
        if (!buf.is_host_visible) return null;

        var ptr: ?*anyopaque = null;
        try Utils.checkVk(c.vkMapMemory(self.vulkan_device.vk_device, buf.memory, 0, buf.size, 0, &ptr));
        return ptr;
    }

    pub fn unmapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) void {
        const buf = self.buffers.get(handle) orelse return;
        if (buf.is_host_visible) {
            c.vkUnmapMemory(self.vulkan_device.vk_device, buf.memory);
        }
    }

    pub fn createTexture(self: *ResourceManager, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        const vk_format: c.VkFormat = switch (format) {
            .rgba => c.VK_FORMAT_R8G8B8A8_UNORM,
            .rgba_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
            .rgb => c.VK_FORMAT_R8G8B8_UNORM,
            .red => c.VK_FORMAT_R8_UNORM,
            .depth => c.VK_FORMAT_D32_SFLOAT,
            .rgba32f => c.VK_FORMAT_R32G32B32A32_SFLOAT,
        };

        const mip_levels: u32 = if (config.generate_mipmaps and format != .depth)
            @as(u32, @intFromFloat(@floor(std.math.log2(@as(f32, @floatFromInt(@max(width, height))))))) + 1
        else
            1;

        const aspect_mask: c.VkImageAspectFlags = if (format == .depth)
            c.VK_IMAGE_ASPECT_DEPTH_BIT
        else
            c.VK_IMAGE_ASPECT_COLOR_BIT;

        var usage_flags: c.VkImageUsageFlags = if (format == .depth)
            c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT
        else
            c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;

        if (mip_levels > 1) {
            usage_flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        }

        if (config.is_render_target) {
            usage_flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }

        var staging_offset: u64 = 0;
        var staging_ptr: ?*StagingBuffer = null;
        if (data_opt) |data| {
            const staging = &self.staging_buffers[self.current_frame_index];
            const offset = staging.allocate(data.len) orelse return error.OutOfMemory;
            if (staging.mapped_ptr == null) return error.OutOfMemory;
            staging_offset = offset;
            staging_ptr = staging;
        }

        const device = self.vulkan_device.vk_device;

        var image: c.VkImage = null;
        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.extent.width = width;
        image_info.extent.height = height;
        image_info.extent.depth = 1;
        image_info.mipLevels = mip_levels;
        image_info.arrayLayers = 1;
        image_info.format = vk_format;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        image_info.usage = usage_flags;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        try Utils.checkVk(c.vkCreateImage(device, &image_info, null, &image));
        errdefer c.vkDestroyImage(device, image, null);

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(device, image, &mem_reqs);

        var memory: c.VkDeviceMemory = null;
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try Utils.findMemoryType(self.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        try Utils.checkVk(c.vkAllocateMemory(device, &alloc_info, null, &memory));
        errdefer c.vkFreeMemory(device, memory, null);

        try Utils.checkVk(c.vkBindImageMemory(device, image, memory, 0));

        // Upload data if present
        if (data_opt) |data| {
            const staging = staging_ptr orelse return error.OutOfMemory;
            std.debug.assert(staging.mapped_ptr != null);
            const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + staging_offset;
            @memcpy(dest[0..data.len], data);

            const transfer_cb = try self.prepareTransfer();

            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = image;
            barrier.subresourceRange.aspectMask = aspect_mask;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = mip_levels;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

            var region = std.mem.zeroes(c.VkBufferImageCopy);
            region.bufferOffset = staging_offset;
            region.imageSubresource.aspectMask = aspect_mask;
            region.imageSubresource.layerCount = 1;
            region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

            c.vkCmdCopyBufferToImage(transfer_cb, staging.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            if (mip_levels > 1) {
                // Generate mipmaps (simplified blit loop)
                var mip_width: i32 = @intCast(width);
                var mip_height: i32 = @intCast(height);

                for (1..mip_levels) |i| {
                    barrier.subresourceRange.baseMipLevel = @intCast(i - 1);
                    barrier.subresourceRange.levelCount = 1;
                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;

                    c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    var blit = std.mem.zeroes(c.VkImageBlit);
                    blit.srcOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.srcOffsets[1] = .{ .x = mip_width, .y = mip_height, .z = 1 };
                    blit.srcSubresource.aspectMask = aspect_mask;
                    blit.srcSubresource.mipLevel = @intCast(i - 1);
                    blit.srcSubresource.baseArrayLayer = 0;
                    blit.srcSubresource.layerCount = 1;

                    const next_width = if (mip_width > 1) @divFloor(mip_width, 2) else 1;
                    const next_height = if (mip_height > 1) @divFloor(mip_height, 2) else 1;

                    blit.dstOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                    blit.dstOffsets[1] = .{ .x = next_width, .y = next_height, .z = 1 };
                    blit.dstSubresource.aspectMask = aspect_mask;
                    blit.dstSubresource.mipLevel = @intCast(i);
                    blit.dstSubresource.baseArrayLayer = 0;
                    blit.dstSubresource.layerCount = 1;

                    c.vkCmdBlitImage(transfer_cb, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, c.VK_FILTER_LINEAR);

                    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                    barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
                    barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                    c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

                    if (mip_width > 1) mip_width = @divFloor(mip_width, 2);
                    if (mip_height > 1) mip_height = @divFloor(mip_height, 2);
                }

                // Transition last mip level
                barrier.subresourceRange.baseMipLevel = @intCast(mip_levels - 1);
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            } else {
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            }
        } else {
            // No data - transition to SHADER_READ_ONLY_OPTIMAL
            const transfer_cb = try self.prepareTransfer();

            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = image;
            barrier.subresourceRange.aspectMask = aspect_mask;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = mip_levels;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        var view: c.VkImageView = null;
        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = vk_format;
        view_info.subresourceRange.aspectMask = aspect_mask;
        view_info.subresourceRange.baseMipLevel = 0;
        view_info.subresourceRange.levelCount = mip_levels;
        view_info.subresourceRange.baseArrayLayer = 0;
        view_info.subresourceRange.layerCount = 1;

        const sampler = try Utils.createSampler(self.vulkan_device, config, mip_levels, self.vulkan_device.max_anisotropy);
        errdefer c.vkDestroySampler(device, sampler, null);

        try Utils.checkVk(c.vkCreateImageView(device, &view_info, null, &view));
        errdefer c.vkDestroyImageView(device, view, null);

        const handle = self.next_texture_handle;
        self.next_texture_handle += 1;
        try self.textures.put(handle, .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
            .format = format,
            .config = config,
            .is_owned = true,
        });

        return handle;
    }

    pub fn destroyTexture(self: *ResourceManager, handle: rhi.TextureHandle) void {
        const tex = self.textures.get(handle) orelse return;
        _ = self.textures.remove(handle);
        self.image_deletion_queue[self.current_frame_index].append(self.allocator, .{
            .image = tex.image,
            .memory = tex.memory,
            .view = tex.view,
            .sampler = tex.sampler,
            .is_owned = tex.is_owned,
        }) catch |err| {
            std.log.err("Failed to queue texture deletion: {}", .{err});
        };
    }

    /// Registers an externally-owned texture for use in debug overlays.
    /// Errors: InvalidImageView if view or sampler is null.
    pub fn registerExternalTexture(self: *ResourceManager, width: u32, height: u32, format: rhi.TextureFormat, view: c.VkImageView, sampler: c.VkSampler) rhi.RhiError!rhi.TextureHandle {
        if (view == null or sampler == null) return error.InvalidImageView;
        const handle = self.next_texture_handle;
        self.next_texture_handle += 1;
        try self.textures.put(handle, .{
            .image = null,
            .memory = null,
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
            .format = format,
            .config = .{},
            .is_owned = false,
        });
        return handle;
    }

    pub fn updateTexture(self: *ResourceManager, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
        const tex = self.textures.get(handle) orelse return;

        const staging = &self.staging_buffers[self.current_frame_index];
        if (staging.allocate(data.len)) |offset| {
            if (staging.mapped_ptr == null) return error.OutOfMemory;
            // Async Path
            const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + offset;
            @memcpy(dest[0..data.len], data);

            const transfer_cb = try self.prepareTransfer();

            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = tex.image orelse return error.ExtensionNotPresent;
            barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            barrier.subresourceRange.baseMipLevel = 0;
            barrier.subresourceRange.levelCount = 1;
            barrier.subresourceRange.baseArrayLayer = 0;
            barrier.subresourceRange.layerCount = 1;
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

            var region = std.mem.zeroes(c.VkBufferImageCopy);
            region.bufferOffset = offset;
            region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
            region.imageSubresource.layerCount = 1;
            region.imageExtent = .{ .width = tex.width, .height = tex.height, .depth = 1 };

            c.vkCmdCopyBufferToImage(transfer_cb, staging.buffer, tex.image.?, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

            barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        } else {
            // Buffer full, drop update for now (or implement fallback)
            std.log.err("Staging buffer full during updateTexture! Update dropped.", .{});
            return error.OutOfMemory;
        }
    }

    pub fn createShader(self: *ResourceManager, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
        _ = self;
        _ = vertex_src;
        _ = fragment_src;
        // TODO: Implement actual shader creation when ready.
        // For now, return error to avoid silent failure.
        // NOTE: If engine code calls this, it will now fail loudly, which is better than silent failure.
        return error.ExtensionNotPresent; // Or proper NotImpl error
    }

    pub fn destroyShader(self: *ResourceManager, handle: rhi.ShaderHandle) void {
        _ = self;
        _ = handle;
    }
};
