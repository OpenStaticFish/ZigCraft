const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;

/// Vulkan buffer with backing memory.
pub const VulkanBuffer = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    size: c.VkDeviceSize = 0,
    is_host_visible: bool = false,
};

/// Vulkan texture with image, view, and sampler.
pub const TextureResource = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
    width: u32,
    height: u32,
    format: rhi.TextureFormat,
    config: rhi.TextureConfig,
};

const ZombieBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
};

const ZombieImage = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sampler: c.VkSampler,
};

/// Per-frame linear staging buffer for async uploads.
const StagingBuffer = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: u64,
    current_offset: u64,
    mapped_ptr: ?*anyopaque,

    fn init(device: *const VulkanDevice, size: u64) !StagingBuffer {
        const buf = try createVulkanBuffer(device, size, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (buf.buffer == null) return error.VulkanError;

        var mapped: ?*anyopaque = null;
        try checkVk(c.vkMapMemory(device.vk_device, buf.memory, 0, size, 0, &mapped));

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

        self.current_offset = aligned_offset + size;
        return aligned_offset;
    }
};

pub const ResourceManager = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *const VulkanDevice,

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

    pub fn init(allocator: std.mem.Allocator, vulkan_device: *const VulkanDevice) !ResourceManager {
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
        try checkVk(c.vkCreateCommandPool(vulkan_device.vk_device, &pool_info, null, &self.transfer_command_pool));

        // Allocate transfer command buffers
        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.transfer_command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = rhi.MAX_FRAMES_IN_FLIGHT;
        try checkVk(c.vkAllocateCommandBuffers(vulkan_device.vk_device, &alloc_info, &self.transfer_command_buffers));

        // Create transfer fence
        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = 0; // Not signaled initially
        try checkVk(c.vkCreateFence(vulkan_device.vk_device, &fence_info, null, &self.transfer_fence));

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
                c.vkDestroyImageView(device, img.view, null);
                c.vkDestroyImage(device, img.image, null);
                c.vkFreeMemory(device, img.memory, null);
                c.vkDestroySampler(device, img.sampler, null);
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
            c.vkDestroyImageView(device, tex.view, null);
            c.vkDestroyImage(device, tex.image, null);
            c.vkFreeMemory(device, tex.memory, null);
            c.vkDestroySampler(device, tex.sampler, null);
        }
        self.textures.deinit();

        if (self.transfer_command_pool != null) {
            c.vkDestroyCommandPool(device, self.transfer_command_pool, null);
        }
        if (self.transfer_fence != null) {
            c.vkDestroyFence(device, self.transfer_fence, null);
        }
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
            c.vkDestroyImageView(device, img.view, null);
            c.vkDestroyImage(device, img.image, null);
            c.vkFreeMemory(device, img.memory, null);
            c.vkDestroySampler(device, img.sampler, null);
        }
        self.image_deletion_queue[frame_index].clearRetainingCapacity();
    }

    fn prepareTransfer(self: *ResourceManager) !c.VkCommandBuffer {
        if (self.transfer_ready) return self.transfer_command_buffers[self.current_frame_index];

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try checkVk(c.vkBeginCommandBuffer(self.transfer_command_buffers[self.current_frame_index], &begin_info));

        self.transfer_ready = true;
        return self.transfer_command_buffers[self.current_frame_index];
    }

    pub fn getTransferCommandBuffer(self: *ResourceManager) ?c.VkCommandBuffer {
        if (!self.transfer_ready) return null;
        return self.transfer_command_buffers[self.current_frame_index];
    }

    pub fn createBuffer(self: *ResourceManager, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
        const vk_usage: c.VkBufferUsageFlags = switch (usage) {
            .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .index => c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .indirect => c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .storage => c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        };

        const properties = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const buf = createVulkanBuffer(self.vulkan_device, size, vk_usage, properties) catch {
            return rhi.InvalidBufferHandle;
        };

        const handle = self.next_buffer_handle;
        self.next_buffer_handle += 1;
        self.buffers.put(handle, buf) catch return rhi.InvalidBufferHandle;

        return handle;
    }

    pub fn destroyBuffer(self: *ResourceManager, handle: rhi.BufferHandle) void {
        const buf = self.buffers.get(handle) orelse return;
        _ = self.buffers.remove(handle);
        self.buffer_deletion_queue[self.current_frame_index].append(self.allocator, .{ .buffer = buf.buffer, .memory = buf.memory }) catch {};
    }

    pub fn uploadBuffer(self: *ResourceManager, handle: rhi.BufferHandle, data: []const u8) void {
        self.updateBuffer(handle, 0, data);
    }

    pub fn updateBuffer(self: *ResourceManager, handle: rhi.BufferHandle, offset: usize, data: []const u8) void {
        const buf = self.buffers.get(handle) orelse return;

        const staging = &self.staging_buffers[self.current_frame_index];
        const staging_offset = staging.allocate(data.len) orelse return;

        const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + staging_offset;
        @memcpy(dest[0..data.len], data);

        const cmd = self.prepareTransfer() catch return;

        var region = std.mem.zeroes(c.VkBufferCopy);
        region.srcOffset = staging_offset;
        region.dstOffset = offset;
        region.size = data.len;

        c.vkCmdCopyBuffer(cmd, staging.buffer, buf.buffer, 1, &region);
    }

    pub fn mapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) ?*anyopaque {
        const buf = self.buffers.get(handle) orelse return null;
        if (!buf.is_host_visible) return null;

        var ptr: ?*anyopaque = null;
        checkVk(c.vkMapMemory(self.vulkan_device.vk_device, buf.memory, 0, buf.size, 0, &ptr)) catch return null;
        return ptr;
    }

    pub fn unmapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) void {
        const buf = self.buffers.get(handle) orelse return;
        if (buf.is_host_visible) {
            c.vkUnmapMemory(self.vulkan_device.vk_device, buf.memory);
        }
    }

    pub fn createTexture(self: *ResourceManager, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.TextureHandle {
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

        if (c.vkCreateImage(self.vulkan_device.vk_device, &image_info, null, &image) != c.VK_SUCCESS) return rhi.InvalidTextureHandle;

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.vulkan_device.vk_device, image, &mem_reqs);

        var memory: c.VkDeviceMemory = null;
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = findMemoryType(self.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) catch {
            c.vkDestroyImage(self.vulkan_device.vk_device, image, null);
            return rhi.InvalidTextureHandle;
        };

        if (c.vkAllocateMemory(self.vulkan_device.vk_device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
            c.vkDestroyImage(self.vulkan_device.vk_device, image, null);
            return rhi.InvalidTextureHandle;
        }
        if (c.vkBindImageMemory(self.vulkan_device.vk_device, image, memory, 0) != c.VK_SUCCESS) {
            c.vkFreeMemory(self.vulkan_device.vk_device, memory, null);
            c.vkDestroyImage(self.vulkan_device.vk_device, image, null);
            return rhi.InvalidTextureHandle;
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

        if (c.vkCreateImageView(self.vulkan_device.vk_device, &view_info, null, &view) != c.VK_SUCCESS) {
            c.vkFreeMemory(self.vulkan_device.vk_device, memory, null);
            c.vkDestroyImage(self.vulkan_device.vk_device, image, null);
            return rhi.InvalidTextureHandle;
        }

        const sampler = createSampler(self.vulkan_device, config, mip_levels, self.vulkan_device.max_anisotropy);

        // Upload data if present
        if (data_opt) |data| {
            const staging = &self.staging_buffers[self.current_frame_index];
            const offset = staging.allocate(data.len);

            if (offset) |off| {
                const dest = @as([*]u8, @ptrCast(staging.mapped_ptr.?)) + off;
                @memcpy(dest[0..data.len], data);

                const transfer_cb = self.prepareTransfer() catch {
                    // Cleanup and fail
                    c.vkDestroySampler(self.vulkan_device.vk_device, sampler, null);
                    c.vkDestroyImageView(self.vulkan_device.vk_device, view, null);
                    c.vkFreeMemory(self.vulkan_device.vk_device, memory, null);
                    c.vkDestroyImage(self.vulkan_device.vk_device, image, null);
                    return rhi.InvalidTextureHandle;
                };

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
                region.bufferOffset = off;
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
            }
        } else {
            // No data - transition to SHADER_READ_ONLY_OPTIMAL
            const transfer_cb = self.prepareTransfer() catch return rhi.InvalidTextureHandle; // Should ideally handle error

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

        const handle = self.next_texture_handle;
        self.next_texture_handle += 1;
        self.textures.put(handle, .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
            .format = format,
            .config = config,
        }) catch return rhi.InvalidTextureHandle;

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
        }) catch {};
    }

    pub fn updateTexture(self: *ResourceManager, handle: rhi.TextureHandle, data: []const u8) void {
        _ = self;
        _ = handle;
        _ = data;
        // TODO: Implement texture updates (rarely used in current engine)
    }

    pub fn createShader(self: *ResourceManager, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
        _ = self;
        _ = vertex_src;
        _ = fragment_src;
        // TODO: Implement shader creation.
        // Current engine uses hardcoded pipelines or pre-compiled SPV.
        // If RHI expects runtime compilation/loading, we need a way to store shader modules.
        // For now, returning InvalidShaderHandle as placeholder.
        return rhi.InvalidShaderHandle;
    }

    pub fn destroyShader(self: *ResourceManager, handle: rhi.ShaderHandle) void {
        _ = self;
        _ = handle;
    }
};

// Helper functions

fn checkVk(result: c.VkResult) !void {
    switch (result) {
        c.VK_SUCCESS => return,
        c.VK_ERROR_DEVICE_LOST => return error.GpuLost,
        c.VK_ERROR_OUT_OF_HOST_MEMORY, c.VK_ERROR_OUT_OF_DEVICE_MEMORY => return error.OutOfMemory,
        c.VK_ERROR_SURFACE_LOST_KHR => return error.SurfaceLost,
        c.VK_ERROR_INITIALIZATION_FAILED => return error.InitializationFailed,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => return error.ExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => return error.FeatureNotPresent,
        c.VK_ERROR_TOO_MANY_OBJECTS => return error.TooManyObjects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => return error.FormatNotSupported,
        c.VK_ERROR_FRAGMENTED_POOL => return error.FragmentedPool,
        else => return error.Unknown,
    }
}

fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    var i: u32 = 0;
    while (i < mem_properties.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
        {
            return i;
        }
    }
    return error.NoMatchingMemoryType;
}

fn createVulkanBuffer(device: *const VulkanDevice, size: usize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) !VulkanBuffer {
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = @intCast(size);
    buffer_info.usage = usage;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var buffer: c.VkBuffer = null;
    try checkVk(c.vkCreateBuffer(device.vk_device, &buffer_info, null, &buffer));

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device.vk_device, buffer, &mem_reqs);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try findMemoryType(device.physical_device, mem_reqs.memoryTypeBits, properties);

    var memory: c.VkDeviceMemory = null;
    try checkVk(c.vkAllocateMemory(device.vk_device, &alloc_info, null, &memory));
    try checkVk(c.vkBindBufferMemory(device.vk_device, buffer, memory, 0));

    return .{
        .buffer = buffer,
        .memory = memory,
        .size = mem_reqs.size,
        .is_host_visible = (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0,
    };
}

fn createSampler(device: *const VulkanDevice, config: rhi.TextureConfig, mip_levels: u32, max_anisotropy: f32) c.VkSampler {
    const vk_mag_filter: c.VkFilter = if (config.mag_filter == .nearest) c.VK_FILTER_NEAREST else c.VK_FILTER_LINEAR;
    const vk_min_filter: c.VkFilter = if (config.min_filter == .nearest or config.min_filter == .nearest_mipmap_nearest or config.min_filter == .nearest_mipmap_linear)
        c.VK_FILTER_NEAREST
    else
        c.VK_FILTER_LINEAR;

    const vk_mipmap_mode: c.VkSamplerMipmapMode = if (config.min_filter == .nearest_mipmap_nearest or config.min_filter == .linear_mipmap_nearest)
        c.VK_SAMPLER_MIPMAP_MODE_NEAREST
    else
        c.VK_SAMPLER_MIPMAP_MODE_LINEAR;

    const vk_wrap_s: c.VkSamplerAddressMode = switch (config.wrap_s) {
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirrored_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .clamp_to_border => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    };
    const vk_wrap_t: c.VkSamplerAddressMode = switch (config.wrap_t) {
        .repeat => c.VK_SAMPLER_ADDRESS_MODE_REPEAT,
        .mirrored_repeat => c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        .clamp_to_edge => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .clamp_to_border => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    };

    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = vk_mag_filter;
    sampler_info.minFilter = vk_min_filter;
    sampler_info.addressModeU = vk_wrap_s;
    sampler_info.addressModeV = vk_wrap_t;
    sampler_info.addressModeW = vk_wrap_s;
    // Anisotropy logic: enable if mip_levels > 1 and global setting > 1
    // We don't have access to global 'anisotropic_filtering' level here,
    // passing max_anisotropy as a proxy for "enabled if > 1".
    sampler_info.anisotropyEnable = if (max_anisotropy > 1.0 and mip_levels > 1) c.VK_TRUE else c.VK_FALSE;
    sampler_info.maxAnisotropy = max_anisotropy;
    sampler_info.borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK;
    sampler_info.unnormalizedCoordinates = c.VK_FALSE;
    sampler_info.compareEnable = c.VK_FALSE;
    sampler_info.compareOp = c.VK_COMPARE_OP_ALWAYS;
    sampler_info.mipmapMode = vk_mipmap_mode;
    sampler_info.mipLodBias = 0.0;
    sampler_info.minLod = 0.0;
    sampler_info.maxLod = @floatFromInt(mip_levels);

    var sampler: c.VkSampler = null;
    _ = c.vkCreateSampler(device.vk_device, &sampler_info, null, &sampler);
    return sampler;
}
