//! Dedicated Vulkan transfer queue with ring-buffered staging allocator.
//!
//! Provides async GPU uploads that can overlap with rendering when a dedicated
//! transfer queue family is available. Falls back to sharing the graphics queue
//! otherwise — the staging ring still works but without parallelism.
//!
//! ## Ring Buffer Lifecycle
//! Each frame's allocations occupy a contiguous region of the ring. When that
//! frame's fence completes, the region is reclaimed. With `MAX_FRAMES_IN_FLIGHT=2`
//! the ring needs at most 2× the per-frame upload budget.

const std = @import("std");
const sync = @import("sync");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");

pub const DEFAULT_STAGING_CAPACITY: u64 = 256 * 1024 * 1024;
const ALIGNMENT: u64 = 256;

pub const StagingRing = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,
    is_mapped: bool = false,
    capacity: u64 = 0,
    head: u64 = 0,
    tail: u64 = 0,
    used_total: u64 = 0,
    frame_used: [rhi.MAX_FRAMES_IN_FLIGHT]u64,

    pub fn init(device: *const VulkanDevice, capacity: u64) !StagingRing {
        const buf = try Utils.createVulkanBuffer(
            device,
            capacity,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer {
            if (buf.mapped_ptr != null and buf.memory != null) c.vkUnmapMemory(device.vk_device, buf.memory);
            if (buf.buffer != null) c.vkDestroyBuffer(device.vk_device, buf.buffer, null);
            if (buf.memory != null) c.vkFreeMemory(device.vk_device, buf.memory, null);
        }
        if (buf.buffer == null or buf.memory == null or buf.mapped_ptr == null or buf.size < capacity) return error.BackendError;

        var ring = StagingRing{
            .buffer = buf.buffer,
            .memory = buf.memory,
            .mapped = @ptrCast(buf.mapped_ptr.?),
            .is_mapped = true,
            .capacity = capacity,
            .head = 0,
            .tail = 0,
            .used_total = 0,
            .frame_used = undefined,
        };
        @memset(&ring.frame_used, 0);
        return ring;
    }

    pub fn deinit(self: *StagingRing, vk_device: c.VkDevice) void {
        if (self.is_mapped and self.memory != null) {
            c.vkUnmapMemory(vk_device, self.memory);
        }
        if (self.buffer != null) c.vkDestroyBuffer(vk_device, self.buffer, null);
        if (self.memory != null) c.vkFreeMemory(vk_device, self.memory, null);
        self.buffer = null;
        self.memory = null;
        self.is_mapped = false;
        self.capacity = 0;
        self.head = 0;
        self.tail = 0;
        self.used_total = 0;
        @memset(&self.frame_used, 0);
    }

    pub fn beginFrame(self: *StagingRing, frame_index: usize) void {
        self.frame_used[frame_index] = 0;
    }

    pub fn reclaimFrame(self: *StagingRing, frame_index: usize) void {
        const reclaimed = @min(self.frame_used[frame_index], self.used_total);
        self.tail = (self.tail + reclaimed) % self.capacity;
        self.used_total -= reclaimed;
        self.frame_used[frame_index] = 0;
    }

    pub fn allocated(self: *StagingRing) u64 {
        return self.used_total;
    }

    pub fn available(self: *StagingRing) u64 {
        return self.capacity - self.allocated();
    }

    pub fn allocate(self: *StagingRing, size: u64, frame_index: usize) ?StagingSlice {
        if (size == 0) return null;

        const aligned_head = std.mem.alignForward(u64, self.head, ALIGNMENT);
        const alignment_padding = aligned_head - self.head;
        var padded_to_end: u64 = 0;

        const try_offset = blk: {
            if (aligned_head + size <= self.capacity) {
                if (alignment_padding + size > self.available()) return null;
                break :blk aligned_head;
            }
            padded_to_end = self.capacity - self.head;
            const wrap = std.mem.alignForward(u64, 0, ALIGNMENT);
            if (wrap + size > self.capacity) return null;
            const avail = self.available();
            if (size + padded_to_end > avail) return null;
            break :blk wrap;
        };

        const slice = StagingSlice{
            .ptr = self.mapped + try_offset,
            .buffer_offset = try_offset,
            .size = size,
        };

        const new_head = try_offset + size;
        self.head = if (new_head >= self.capacity) 0 else new_head;
        const consumed = size + padded_to_end + if (padded_to_end == 0) alignment_padding else 0;
        self.frame_used[frame_index] += consumed;
        self.used_total += consumed;

        return slice;
    }
};

pub const StagingSlice = struct {
    ptr: [*]u8,
    buffer_offset: u64,
    size: u64,
};

pub const PendingCopy = struct {
    src_offset: u64,
    dst_buffer: c.VkBuffer,
    dst_offset: u64,
    size: u64,
};

pub const MAX_PENDING_COPIES = 2048;

pub const TransferQueue = struct {
    queue: c.VkQueue = null,
    family_index: u32 = 0,
    is_dedicated: bool = false,
    command_pool: c.VkCommandPool = null,
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer = undefined,
    fence: c.VkFence = null,
    frame_fences: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
    transfer_semaphores: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
    transfer_ready: [rhi.MAX_FRAMES_IN_FLIGHT]bool = undefined,
    transfer_submitted: [rhi.MAX_FRAMES_IN_FLIGHT]bool = undefined,
    current_frame: usize = 0,

    pending_copies: [rhi.MAX_FRAMES_IN_FLIGHT][MAX_PENDING_COPIES]PendingCopy = undefined,
    pending_copy_count: [rhi.MAX_FRAMES_IN_FLIGHT]usize = undefined,
    pending_staging_buffer: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkBuffer = undefined,
    pending_dst_access_mask: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkAccessFlags = undefined,

    pub fn init(device: *const VulkanDevice, transfer_family: u32, is_dedicated: bool) !TransferQueue {
        var self = TransferQueue{
            .family_index = transfer_family,
            .is_dedicated = is_dedicated,
        };
        errdefer self.deinit(device.vk_device);
        @memset(&self.transfer_ready, false);
        @memset(&self.transfer_submitted, false);
        @memset(&self.pending_copy_count, 0);
        @memset(&self.pending_staging_buffer, null);
        @memset(&self.pending_dst_access_mask, 0);

        c.vkGetDeviceQueue(device.vk_device, transfer_family, 0, &self.queue);

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = transfer_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try Utils.checkVk(c.vkCreateCommandPool(device.vk_device, &pool_info, null, &self.command_pool));

        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = rhi.MAX_FRAMES_IN_FLIGHT;
        try Utils.checkVk(c.vkAllocateCommandBuffers(device.vk_device, &alloc_info, &self.command_buffers));

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        try Utils.checkVk(c.vkCreateFence(device.vk_device, &fence_info, null, &self.fence));

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try Utils.checkVk(c.vkCreateFence(device.vk_device, &fence_info, null, &self.frame_fences[i]));
        }

        var sem_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try Utils.checkVk(c.vkCreateSemaphore(device.vk_device, &sem_info, null, &self.transfer_semaphores[i]));
        }

        return self;
    }

    pub fn beginFrame(self: *TransferQueue, frame_index: usize, staging_buffer: c.VkBuffer) void {
        self.current_frame = frame_index;
        self.pending_copy_count[frame_index] = 0;
        self.pending_staging_buffer[frame_index] = staging_buffer;
        self.pending_dst_access_mask[frame_index] = 0;
    }

    pub fn addPendingCopy(self: *TransferQueue, copy: PendingCopy) bool {
        const idx = self.current_frame;
        if (self.pending_copy_count[idx] < MAX_PENDING_COPIES) {
            self.pending_copies[idx][self.pending_copy_count[idx]] = copy;
            self.pending_copy_count[idx] += 1;
            return true;
        }
        return false;
    }

    pub fn pendingCopyCount(self: *const TransferQueue) usize {
        return self.pending_copy_count[self.current_frame];
    }

    pub fn recordPendingCopies(self: *TransferQueue, cmd: c.VkCommandBuffer) void {
        const idx = self.current_frame;
        const staging = self.pending_staging_buffer[idx];
        if (staging == null or self.pending_copy_count[idx] == 0) return;

        for (0..self.pending_copy_count[idx]) |i| {
            const pc = self.pending_copies[idx][i];
            var region = std.mem.zeroes(c.VkBufferCopy);
            region.srcOffset = pc.src_offset;
            region.dstOffset = pc.dst_offset;
            region.size = pc.size;
            c.vkCmdCopyBuffer(cmd, staging, pc.dst_buffer, 1, &region);
        }
    }

    pub fn getPendingDstAccessMask(self: *TransferQueue) c.VkAccessFlags {
        return self.pending_dst_access_mask[self.current_frame];
    }

    pub fn addPendingDstAccess(self: *TransferQueue, mask: c.VkAccessFlags) void {
        self.pending_dst_access_mask[self.current_frame] |= mask;
    }

    pub fn hasPendingCopies(self: *TransferQueue) bool {
        return self.pending_copy_count[self.current_frame] > 0;
    }

    pub fn deinit(self: *TransferQueue, vk_device: c.VkDevice) void {
        if (vk_device == null) return;
        _ = c.vkDeviceWaitIdle(vk_device);

        if (self.command_pool != null) {
            c.vkDestroyCommandPool(vk_device, self.command_pool, null);
            self.command_pool = null;
        }
        if (self.fence != null) {
            c.vkDestroyFence(vk_device, self.fence, null);
            self.fence = null;
        }
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.frame_fences[i] != null) {
                c.vkDestroyFence(vk_device, self.frame_fences[i], null);
                self.frame_fences[i] = null;
            }
        }
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.transfer_semaphores[i] != null) {
                c.vkDestroySemaphore(vk_device, self.transfer_semaphores[i], null);
                self.transfer_semaphores[i] = null;
            }
        }
    }

    pub fn setCurrentFrame(self: *TransferQueue, frame_index: usize) void {
        self.current_frame = frame_index;
    }

    pub fn prepareTransfer(self: *TransferQueue) !c.VkCommandBuffer {
        if (self.transfer_ready[self.current_frame]) return self.command_buffers[self.current_frame];

        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkResetCommandBuffer(cb, 0));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try Utils.checkVk(c.vkBeginCommandBuffer(cb, &begin_info));

        self.transfer_ready[self.current_frame] = true;
        self.transfer_submitted[self.current_frame] = false;
        return cb;
    }

    pub fn getTransferCommandBuffer(self: *TransferQueue) ?c.VkCommandBuffer {
        if (!self.transfer_ready[self.current_frame]) return null;
        return self.command_buffers[self.current_frame];
    }

    pub fn resetTransferState(self: *TransferQueue) void {
        self.transfer_ready[self.current_frame] = false;
        self.transfer_submitted[self.current_frame] = false;
    }

    fn discardPendingState(self: *TransferQueue, frame_index: usize) void {
        self.pending_copy_count[frame_index] = 0;
        self.pending_staging_buffer[frame_index] = null;
        self.pending_dst_access_mask[frame_index] = 0;
        self.transfer_ready[frame_index] = false;
        self.transfer_submitted[frame_index] = false;
    }

    /// Discards transfer commands recorded for a graphics frame that will not
    /// be submitted. The staging allocation remains owned by the frame slot and
    /// is reclaimed normally when that slot's fence boundary is reused.
    pub fn abortCurrentFrame(self: *TransferQueue, vk_device: c.VkDevice) void {
        const frame_index = self.current_frame;
        if (self.transfer_submitted[frame_index] and self.is_dedicated) {
            self.waitForFrameFence(vk_device, frame_index);
        }
        if (self.transfer_ready[frame_index]) {
            const result = c.vkResetCommandBuffer(self.command_buffers[frame_index], 0);
            if (result != c.VK_SUCCESS) {
                log.log.err("Failed to reset aborted transfer command buffer: {d}", .{result});
            }
        }
        self.discardPendingState(frame_index);
    }

    pub fn endTransferCommandBuffer(self: *TransferQueue) !void {
        if (!self.transfer_ready[self.current_frame]) return;
        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkEndCommandBuffer(cb));
    }

    pub fn waitForFrameFence(self: *TransferQueue, vk_device: c.VkDevice, frame_index: usize) void {
        if (self.frame_fences[frame_index] == null) return;
        _ = c.vkWaitForFences(vk_device, 1, &self.frame_fences[frame_index], c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(vk_device, 1, &self.frame_fences[frame_index]);
    }

    pub fn submitAndWait(self: *TransferQueue, vk_device: c.VkDevice, queue_mutex: *sync.Mutex) !void {
        if (!self.transfer_ready[self.current_frame]) return;

        const cb = self.command_buffers[self.current_frame];
        const end_result = c.vkEndCommandBuffer(cb);
        if (end_result != c.VK_SUCCESS) {
            self.transfer_ready[self.current_frame] = false;
            if (end_result == c.VK_ERROR_DEVICE_LOST) return error.GpuLost;
            return error.BackendError;
        }

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cb;

        try Utils.checkVk(c.vkResetFences(vk_device, 1, &self.fence));

        queue_mutex.lock();
        const result = c.vkQueueSubmit(self.queue, 1, &submit_info, self.fence);
        queue_mutex.unlock();

        if (result == c.VK_ERROR_DEVICE_LOST) return error.GpuLost;
        if (result != c.VK_SUCCESS) return error.BackendError;

        const wait_result = c.vkWaitForFences(vk_device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64));
        if (wait_result == c.VK_ERROR_DEVICE_LOST) return error.GpuLost;
        try Utils.checkVk(wait_result);

        self.transfer_ready[self.current_frame] = false;
    }

    pub fn flushSync(self: *TransferQueue, vk_device: c.VkDevice, queue_mutex: *sync.Mutex) !void {
        if (!self.transfer_ready[self.current_frame]) return;
        try self.submitAndWait(vk_device, queue_mutex);
    }
};

test "staging ring distinguishes full from empty" {
    var memory: [1024]u8 = undefined;
    var ring = StagingRing{
        .mapped = &memory,
        .capacity = memory.len,
        .frame_used = [_]u64{0} ** rhi.MAX_FRAMES_IN_FLIGHT,
    };
    ring.beginFrame(0);
    try std.testing.expect(ring.allocate(512, 0) != null);
    try std.testing.expect(ring.allocate(512, 0) != null);
    try std.testing.expectEqual(@as(u64, memory.len), ring.allocated());
    try std.testing.expect(ring.allocate(1, 0) == null);
    ring.reclaimFrame(0);
    try std.testing.expectEqual(@as(u64, 0), ring.allocated());
}

test "aborted transfer state drops pending copies without reclaiming staging ownership" {
    var transfer = std.mem.zeroes(TransferQueue);
    transfer.current_frame = 1;
    transfer.pending_copy_count[1] = 7;
    transfer.pending_staging_buffer[1] = @ptrFromInt(1);
    transfer.pending_dst_access_mask[1] = c.VK_ACCESS_INDEX_READ_BIT;
    transfer.transfer_ready[1] = true;
    transfer.transfer_submitted[1] = true;

    transfer.discardPendingState(1);

    try std.testing.expectEqual(@as(usize, 0), transfer.pending_copy_count[1]);
    try std.testing.expect(transfer.pending_staging_buffer[1] == null);
    try std.testing.expectEqual(@as(c.VkAccessFlags, 0), transfer.pending_dst_access_mask[1]);
    try std.testing.expect(!transfer.transfer_ready[1]);
    try std.testing.expect(!transfer.transfer_submitted[1]);
}

test "staging ring reclaims wrapped frame regions" {
    var memory: [1024]u8 = undefined;
    var ring = StagingRing{
        .mapped = &memory,
        .capacity = memory.len,
        .frame_used = [_]u64{0} ** rhi.MAX_FRAMES_IN_FLIGHT,
    };
    ring.beginFrame(0);
    try std.testing.expect(ring.allocate(400, 0) != null);
    ring.beginFrame(1);
    try std.testing.expect(ring.allocate(400, 1) != null);
    ring.reclaimFrame(0);
    ring.beginFrame(0);
    try std.testing.expect(ring.allocate(400, 0) != null);
    try std.testing.expectEqual(@as(u64, 1024), ring.allocated());
    ring.reclaimFrame(1);
    ring.reclaimFrame(0);
    try std.testing.expectEqual(@as(u64, 0), ring.allocated());
    try std.testing.expectEqual(ring.head, ring.tail);
}
