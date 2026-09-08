const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const RenderDeviceStats = @import("engine-rhi").Stats;
const log = @import("engine-core").log;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");
const resource_texture_ops = @import("resource_texture_ops.zig");
const transfer_queue = @import("transfer_queue.zig");
const StagingRing = transfer_queue.StagingRing;
const StagingSlice = transfer_queue.StagingSlice;
const TransferQueue = transfer_queue.TransferQueue;

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
    depth: u32,
    format: rhi.TextureFormat,
    config: rhi.TextureConfig,
    allocation_size: usize = 0,
    is_3d: bool = false,
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

    // Staging ring buffer (replaces per-frame StagingBuffer)
    staging_ring: StagingRing,

    // Transfer queue (dedicated or shared with graphics)
    transfer: TransferQueue,

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
            .staging_ring = undefined,
            .transfer = undefined,
        };

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.buffer_deletion_queue[i] = .empty;
            self.image_deletion_queue[i] = .empty;
        }

        self.staging_ring = try StagingRing.init(vulkan_device, transfer_queue.DEFAULT_STAGING_CAPACITY);
        errdefer self.staging_ring.deinit(vulkan_device.vk_device);
        log.log.info("Staging ring initialized: {}MB", .{transfer_queue.DEFAULT_STAGING_CAPACITY / (1024 * 1024)});

        // Buffer resources use exclusive sharing and are consumed by graphics.
        // Until queue-family release/acquire ownership transfers are modeled,
        // record uploads on the graphics family. A semaphore alone does not
        // transfer exclusive buffer ownership from a transfer-only queue.
        const tx_family = vulkan_device.graphics_family;
        const is_dedicated = false;
        self.transfer = try TransferQueue.init(vulkan_device, tx_family, is_dedicated);
        if (is_dedicated) {
            log.log.info("Transfer queue: DEDICATED (family {})", .{tx_family});
        } else {
            log.log.info("Transfer queue: SHARED with graphics (family {})", .{tx_family});
        }

        return self;
    }

    pub fn deinit(self: *ResourceManager) void {
        const device = self.vulkan_device.vk_device;
        _ = c.vkDeviceWaitIdle(device);

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
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

        self.transfer.deinit(device);
        self.staging_ring.deinit(device);
    }

    pub fn flushTransfer(self: *ResourceManager) !void {
        try self.transfer.flushSync(self.vulkan_device.vk_device, &self.vulkan_device.mutex);
    }

    pub fn setCurrentFrame(self: *ResourceManager, frame_index: usize) void {
        self.current_frame_index = frame_index;
        self.transfer.setCurrentFrame(frame_index);

        if (self.transfer.is_dedicated) {
            self.transfer.waitForFrameFence(self.vulkan_device.vk_device, frame_index);
        }
        self.staging_ring.reclaimFrame(frame_index);
        self.staging_ring.beginFrame(frame_index);
        self.transfer.beginFrame(frame_index, self.staging_ring.buffer);

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

    pub fn stats(self: *const ResourceManager) RenderDeviceStats {
        var result = RenderDeviceStats{
            .buffer_count = @intCast(self.buffers.count()),
            .texture_count = @intCast(self.textures.count()),
            .shader_count = 0,
            .total_buffer_memory = 0,
            .total_texture_memory = 0,
        };

        var buf_it = self.buffers.valueIterator();
        while (buf_it.next()) |buf| {
            result.total_buffer_memory += @intCast(buf.size);
        }

        var tex_it = self.textures.valueIterator();
        while (tex_it.next()) |tex| {
            result.total_texture_memory += tex.allocation_size;
        }

        return result;
    }

    pub fn resetTransferState(self: *ResourceManager) void {
        self.transfer.resetTransferState();
    }

    pub fn abortCurrentFrame(self: *ResourceManager) void {
        self.transfer.abortCurrentFrame(self.vulkan_device.vk_device);
    }

    pub fn prepareTransfer(self: *ResourceManager) !c.VkCommandBuffer {
        return self.transfer.prepareTransfer();
    }

    pub fn getTransferCommandBuffer(self: *ResourceManager) ?c.VkCommandBuffer {
        return self.transfer.getTransferCommandBuffer();
    }

    pub fn endTransferCommandBuffer(self: *ResourceManager) !void {
        try self.transfer.endTransferCommandBuffer();
    }

    pub fn getTransferSemaphore(self: *ResourceManager) ?c.VkSemaphore {
        if (!self.transfer.is_dedicated) return null;
        if (!self.transfer.transfer_submitted[self.transfer.current_frame]) return null;
        return self.transfer.transfer_semaphores[self.transfer.current_frame];
    }

    pub fn submitTransfer(self: *ResourceManager) !void {
        if (!self.transfer.is_dedicated) return;
        if (!self.transfer.transfer_ready[self.transfer.current_frame]) return;
        if (!self.transfer.hasPendingCopies()) return;

        const cb = self.transfer.command_buffers[self.transfer.current_frame];

        self.transfer.recordPendingCopies(cb);

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = self.transfer.getPendingDstAccessMask();

        c.vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);

        try self.transfer.endTransferCommandBuffer();
        try Utils.checkVk(c.vkResetFences(self.vulkan_device.vk_device, 1, &self.transfer.frame_fences[self.transfer.current_frame]));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cb;

        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = &self.transfer.transfer_semaphores[self.transfer.current_frame];

        self.vulkan_device.mutex.lock();
        const result = c.vkQueueSubmit(self.transfer.queue, 1, &submit_info, self.transfer.frame_fences[self.transfer.current_frame]);
        self.vulkan_device.mutex.unlock();

        if (result != c.VK_SUCCESS) return error.BackendError;

        self.transfer.transfer_ready[self.transfer.current_frame] = false;
        self.transfer.transfer_submitted[self.transfer.current_frame] = true;
    }

    pub fn createBuffer(self: *ResourceManager, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
        const vk_usage: c.VkBufferUsageFlags = switch (usage) {
            .vertex => c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .index => c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .uniform => c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .indirect => c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .storage => c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        };

        const properties = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

        const buf = try Utils.createVulkanBuffer(self.vulkan_device, size, vk_usage, properties);
        errdefer {
            if (buf.mapped_ptr != null) c.vkUnmapMemory(self.vulkan_device.vk_device, buf.memory);
            c.vkDestroyBuffer(self.vulkan_device.vk_device, buf.buffer, null);
            c.vkFreeMemory(self.vulkan_device.vk_device, buf.memory, null);
        }

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
            log.log.err("Failed to queue buffer deletion: {}", .{err});
        };
    }

    pub fn uploadBuffer(self: *ResourceManager, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
        return self.updateBuffer(handle, 0, data);
    }

    pub fn updateBuffer(self: *ResourceManager, handle: rhi.BufferHandle, offset: usize, data: []const u8) rhi.RhiError!void {
        const buf = self.buffers.get(handle) orelse return;
        const end = std.math.add(usize, offset, data.len) catch return error.InvalidState;
        if (@as(u64, @intCast(end)) > buf.size) return error.InvalidState;

        const slice = self.staging_ring.allocate(data.len, self.current_frame_index) orelse {
            log.log.err("Staging ring overflow in updateBuffer: request={} used={} head={} tail={} frame={} frame_used={any}", .{ data.len, self.staging_ring.used_total, self.staging_ring.head, self.staging_ring.tail, self.current_frame_index, self.staging_ring.frame_used });
            return error.OutOfMemory;
        };

        @memcpy(slice.ptr[0..data.len], data);

        _ = try self.prepareTransfer();

        const copy = transfer_queue.PendingCopy{
            .src_offset = slice.buffer_offset,
            .dst_buffer = buf.buffer,
            .dst_offset = offset,
            .size = data.len,
        };
        if (!self.transfer.addPendingCopy(copy)) {
            log.log.warn("Transfer queue pending copy overflow! Data not uploaded.", .{});
            return error.PendingCopyOverflow;
        }
        self.transfer.addPendingDstAccess(c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
    }

    pub fn mapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
        const buf = self.buffers.get(handle) orelse return null;
        return buf.mapped_ptr;
    }

    pub fn unmapBuffer(self: *ResourceManager, handle: rhi.BufferHandle) void {
        _ = self;
        _ = handle;
    }

    pub fn createTexture(self: *ResourceManager, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        return resource_texture_ops.createTexture(self, width, height, format, config, data_opt);
    }

    pub fn createTexture3D(self: *ResourceManager, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        return resource_texture_ops.createTexture3D(self, width, height, depth, format, config, data_opt);
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
            log.log.err("Failed to queue texture deletion: {}", .{err});
        };
    }

    pub fn registerNativeTexture(self: *ResourceManager, image: c.VkImage, view: c.VkImageView, sampler: c.VkSampler, width: u32, height: u32, format: rhi.TextureFormat) rhi.RhiError!rhi.TextureHandle {
        const handle = self.next_texture_handle;
        self.next_texture_handle += 1;

        try self.textures.put(handle, .{
            .image = image,
            .memory = null, // External ownership
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
            .depth = 1,
            .format = format,
            .config = .{}, // Default config
            .allocation_size = 0,
            .is_3d = false,
            .is_owned = false,
        });

        return handle;
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
            .depth = 1,
            .format = format,
            .config = .{},
            .allocation_size = 0,
            .is_3d = false,
            .is_owned = false,
        });
        return handle;
    }

    pub fn updateTexture(self: *ResourceManager, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
        const tex = self.textures.get(handle) orelse return;

        const slice = self.staging_ring.allocate(data.len, self.current_frame_index) orelse {
            log.log.err("Staging ring full during updateTexture! Update dropped.", .{});
            return error.OutOfMemory;
        };

        @memcpy(slice.ptr[0..data.len], data);

        const transfer_cb = try self.prepareTransfer();

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        if (self.transfer.is_dedicated) {
            barrier.srcQueueFamilyIndex = self.vulkan_device.graphics_family;
            barrier.dstQueueFamilyIndex = self.transfer.family_index;
        } else {
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        }
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
        region.bufferOffset = slice.buffer_offset;
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = tex.width, .height = tex.height, .depth = tex.depth };

        c.vkCmdCopyBufferToImage(transfer_cb, self.staging_ring.buffer, tex.image.?, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        if (self.transfer.is_dedicated) {
            barrier.srcQueueFamilyIndex = self.transfer.family_index;
            barrier.dstQueueFamilyIndex = self.vulkan_device.graphics_family;
        } else {
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        }

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    pub fn createShader(self: *ResourceManager, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
        _ = self;
        _ = vertex_src;
        _ = fragment_src;
        return error.ShaderCreationNotSupported;
    }

    pub fn destroyShader(self: *ResourceManager, handle: rhi.ShaderHandle) void {
        _ = self;
        _ = handle;
    }
};
