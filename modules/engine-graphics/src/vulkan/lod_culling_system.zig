//! Dedicated same-frame compute culling and MDI compaction for distant terrain.
const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi");
const culling = rhi.culling;
const log = @import("engine-core").log;
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
const Utils = @import("utils.zig");

pub const SHADER_PATH = "assets/shaders/vulkan/lod_culling.comp.spv";
pub const WORKGROUP_SIZE: u32 = 64;
pub const MAX_LOD_LEVELS: usize = 5;
const FRAME_COUNT = rhi.MAX_FRAMES_IN_FLIGHT;

/// Fixed readback sections used only by the opt-in GPU culling validator.
/// Keeping the command and instance payloads beside the existing counters/IDs
/// lets validation distinguish a visibility error from a bad indirect ABI.
const ValidationLayout = struct {
    counters_offset: usize = 0,
    ids_offset: usize,
    terrain_commands_offset: usize,
    water_commands_offset: usize,
    compact_terrain_commands_offset: usize,
    compact_water_commands_offset: usize,
    terrain_instances_offset: usize,
    water_instances_offset: usize,
    compact_terrain_instances_offset: usize,
    compact_water_instances_offset: usize,
    total_bytes: usize,

    fn init(capacity: usize) ValidationLayout {
        const counters_bytes = MAX_LOD_LEVELS * 4 * @sizeOf(u32);
        const ids_bytes = capacity * MAX_LOD_LEVELS * 4 * @sizeOf(u32);
        const command_bytes = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndirectCommand);
        const compact_command_bytes = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndexedIndirectCommand);
        const instance_bytes = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.InstanceData);
        const compact_instance_bytes = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.CompactLODInstance);
        const ids_offset = counters_bytes;
        const terrain_commands_offset = ids_offset + ids_bytes;
        const water_commands_offset = terrain_commands_offset + command_bytes;
        const compact_terrain_commands_offset = water_commands_offset + command_bytes;
        const compact_water_commands_offset = compact_terrain_commands_offset + compact_command_bytes;
        const terrain_instances_offset = compact_water_commands_offset + compact_command_bytes;
        const water_instances_offset = terrain_instances_offset + instance_bytes;
        const compact_terrain_instances_offset = water_instances_offset + instance_bytes;
        const compact_water_instances_offset = compact_terrain_instances_offset + compact_instance_bytes;
        return .{
            .ids_offset = ids_offset,
            .terrain_commands_offset = terrain_commands_offset,
            .water_commands_offset = water_commands_offset,
            .compact_terrain_commands_offset = compact_terrain_commands_offset,
            .compact_water_commands_offset = compact_water_commands_offset,
            .terrain_instances_offset = terrain_instances_offset,
            .water_instances_offset = water_instances_offset,
            .compact_terrain_instances_offset = compact_terrain_instances_offset,
            .compact_water_instances_offset = compact_water_instances_offset,
            .total_bytes = compact_water_instances_offset + compact_instance_bytes,
        };
    }
};

const LODCullingSystem = struct {
    allocator: std.mem.Allocator,
    ctx: *VulkanContext,
    capacity: usize,
    candidates: [FRAME_COUNT]Utils.VulkanBuffer,
    counters: [FRAME_COUNT]rhi.BufferHandle,
    terrain_instances: [FRAME_COUNT]rhi.BufferHandle,
    water_instances: [FRAME_COUNT]rhi.BufferHandle,
    terrain_indirect: [FRAME_COUNT]rhi.BufferHandle,
    water_indirect: [FRAME_COUNT]rhi.BufferHandle,
    compact_terrain_instances: [FRAME_COUNT]rhi.BufferHandle,
    compact_water_instances: [FRAME_COUNT]rhi.BufferHandle,
    compact_terrain_indirect: [FRAME_COUNT]rhi.BufferHandle,
    compact_water_indirect: [FRAME_COUNT]rhi.BufferHandle,
    visible_ids: [FRAME_COUNT]rhi.BufferHandle,
    validation_readback: [FRAME_COUNT]Utils.VulkanBuffer,
    validation_expected: [FRAME_COUNT][MAX_LOD_LEVELS * 4]u32 = [_][MAX_LOD_LEVELS * 4]u32{[_]u32{0} ** (MAX_LOD_LEVELS * 4)} ** FRAME_COUNT,
    validation_expected_ids: [FRAME_COUNT][]u32,
    validation_expected_candidates: [FRAME_COUNT][]culling.LODCullCandidate,
    validation_candidate_count: [FRAME_COUNT]usize = [_]usize{0} ** FRAME_COUNT,
    validation_layout: ValidationLayout,
    validation_pending: [FRAME_COUNT]bool = [_]bool{false} ** FRAME_COUNT,
    validation_pending_generation: [FRAME_COUNT]u64 = [_]u64{0} ** FRAME_COUNT,
    validation_enabled: bool,
    diagnostics_state: culling.LODCullDiagnostics = .{},
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [FRAME_COUNT]c.VkDescriptorSet = std.mem.zeroes([FRAME_COUNT]c.VkDescriptorSet),
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    fn init(allocator: std.mem.Allocator, ctx: *VulkanContext, requested_capacity: usize) !*LODCullingSystem {
        const self = try allocator.create(LODCullingSystem);
        errdefer allocator.destroy(self);
        const capacity = std.math.clamp(requested_capacity, 1, 2048);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .capacity = capacity,
            .candidates = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .counters = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .terrain_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .water_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .terrain_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .water_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .compact_terrain_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .compact_water_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .compact_terrain_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .compact_water_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .visible_ids = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .validation_readback = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .validation_expected_ids = undefined,
            .validation_expected_candidates = undefined,
            .validation_layout = ValidationLayout.init(capacity),
            .validation_enabled = envFlag("ZIGCRAFT_LOD_GPU_CULLING_VALIDATE"),
        };
        for (&self.validation_expected_ids, &self.validation_expected_candidates) |*ids, *candidates| {
            ids.* = &.{};
            candidates.* = &.{};
        }
        errdefer self.deinit();

        const candidate_bytes = capacity * @sizeOf(culling.LODCullCandidate);
        const stream_instances = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.InstanceData);
        const compact_stream_instances = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.CompactLODInstance);
        const stream_commands = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndirectCommand);
        const compact_stream_commands = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndexedIndirectCommand);
        const visible_id_count = capacity * MAX_LOD_LEVELS * 4;
        for (0..FRAME_COUNT) |i| {
            self.candidates[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, candidate_bytes, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            self.counters[i] = try ctx.resources.createBuffer(MAX_LOD_LEVELS * 4 * @sizeOf(u32), .indirect);
            self.terrain_instances[i] = try ctx.resources.createBuffer(stream_instances, .storage);
            self.water_instances[i] = try ctx.resources.createBuffer(stream_instances, .storage);
            self.terrain_indirect[i] = try ctx.resources.createBuffer(stream_commands, .indirect);
            self.water_indirect[i] = try ctx.resources.createBuffer(stream_commands, .indirect);
            self.compact_terrain_instances[i] = try ctx.resources.createBuffer(compact_stream_instances, .storage);
            self.compact_water_instances[i] = try ctx.resources.createBuffer(compact_stream_instances, .storage);
            self.compact_terrain_indirect[i] = try ctx.resources.createBuffer(compact_stream_commands, .indirect);
            self.compact_water_indirect[i] = try ctx.resources.createBuffer(compact_stream_commands, .indirect);
            self.visible_ids[i] = try ctx.resources.createBuffer(visible_id_count * @sizeOf(u32), .storage);
            if (self.validation_enabled) {
                self.validation_expected_ids[i] = try allocator.alloc(u32, visible_id_count);
                self.validation_expected_candidates[i] = try allocator.alloc(culling.LODCullCandidate, capacity);
                self.validation_readback[i] = try Utils.createVulkanBuffer(
                    &ctx.vulkan_device,
                    self.validation_layout.total_bytes,
                    c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                    c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                );
            }
        }
        try self.initPipeline();
        return self;
    }

    fn deinit(self: *LODCullingSystem) void {
        self.drainPendingValidation();
        self.destroyPipeline();
        const device = self.ctx.vulkan_device.vk_device;
        for (0..FRAME_COUNT) |i| {
            destroyNative(device, &self.candidates[i]);
            if (self.counters[i] != 0) self.ctx.resources.destroyBuffer(self.counters[i]);
            if (self.terrain_instances[i] != 0) self.ctx.resources.destroyBuffer(self.terrain_instances[i]);
            if (self.water_instances[i] != 0) self.ctx.resources.destroyBuffer(self.water_instances[i]);
            if (self.terrain_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.terrain_indirect[i]);
            if (self.water_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.water_indirect[i]);
            if (self.compact_terrain_instances[i] != 0) self.ctx.resources.destroyBuffer(self.compact_terrain_instances[i]);
            if (self.compact_water_instances[i] != 0) self.ctx.resources.destroyBuffer(self.compact_water_instances[i]);
            if (self.compact_terrain_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.compact_terrain_indirect[i]);
            if (self.compact_water_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.compact_water_indirect[i]);
            if (self.visible_ids[i] != 0) self.ctx.resources.destroyBuffer(self.visible_ids[i]);
            destroyNative(device, &self.validation_readback[i]);
            if (self.validation_expected_ids[i].len != 0) self.allocator.free(self.validation_expected_ids[i]);
            if (self.validation_expected_candidates[i].len != 0) self.allocator.free(self.validation_expected_candidates[i]);
        }
        self.allocator.destroy(self);
    }

    /// Validation readbacks normally complete when a frame slot is reused. On
    /// teardown there may be no next dispatch, so wait once and account every
    /// pending generation before releasing its mapped storage.
    fn drainPendingValidation(self: *LODCullingSystem) void {
        if (!self.validation_enabled) return;
        var pending = false;
        for (self.validation_pending) |slot_pending| pending = pending or slot_pending;
        if (!pending) return;
        if (c.vkDeviceWaitIdle(self.ctx.vulkan_device.vk_device) != c.VK_SUCCESS) {
            log.log.warn("LOD GPU validation could not drain pending generations during teardown", .{});
            return;
        }
        for (0..FRAME_COUNT) |frame_index| self.validateCompletedFrame(frame_index);
    }

    fn dispatch(self: *LODCullingSystem, frame_index: usize, input: []const culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
        if (frame_index >= FRAME_COUNT or input.len > self.capacity or input.len == 0) return false;
        self.validateCompletedFrame(frame_index);
        const command_buffer = self.ctx.frames.command_buffers[frame_index];
        if (command_buffer == null or self.candidates[frame_index].mapped_ptr == null) return false;
        @memcpy(@as([*]u8, @ptrCast(self.candidates[frame_index].mapped_ptr.?))[0 .. input.len * @sizeOf(culling.LODCullCandidate)], std.mem.sliceAsBytes(input));

        _ = self.lookup(self.terrain_instances[frame_index]) orelse return false;
        _ = self.lookup(self.water_instances[frame_index]) orelse return false;
        const terrain_indirect = self.lookup(self.terrain_indirect[frame_index]) orelse return false;
        const water_indirect = self.lookup(self.water_indirect[frame_index]) orelse return false;
        const cmd = command_buffer;
        const counter_bytes = MAX_LOD_LEVELS * 4 * @sizeOf(u32);
        const stream_command_bytes = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndirectCommand);
        const compact_stream_command_bytes = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndexedIndirectCommand);
        const counters = self.lookup(self.counters[frame_index]) orelse return false;
        const visible_ids = self.lookup(self.visible_ids[frame_index]) orelse return false;
        c.vkCmdFillBuffer(cmd, counters.buffer, 0, counter_bytes, 0);
        c.vkCmdFillBuffer(cmd, terrain_indirect.buffer, 0, stream_command_bytes, 0);
        c.vkCmdFillBuffer(cmd, water_indirect.buffer, 0, stream_command_bytes, 0);
        const compact_terrain_indirect = self.lookup(self.compact_terrain_indirect[frame_index]) orelse return false;
        const compact_water_indirect = self.lookup(self.compact_water_indirect[frame_index]) orelse return false;
        c.vkCmdFillBuffer(cmd, compact_terrain_indirect.buffer, 0, compact_stream_command_bytes, 0);
        c.vkCmdFillBuffer(cmd, compact_water_indirect.buffer, 0, compact_stream_command_bytes, 0);
        var transfer_to_compute = std.mem.zeroes(c.VkMemoryBarrier);
        transfer_to_compute.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        transfer_to_compute.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT;
        transfer_to_compute.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &transfer_to_compute, 0, null, 0, null);

        var push = config;
        push.candidate_count = @intCast(input.len);
        push.max_commands_per_lod = @intCast(self.capacity);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[frame_index], 0, null);
        c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(culling.LODCullDispatch), &push);
        c.vkCmdDispatch(cmd, @divFloor(@as(u32, @intCast(input.len)) + WORKGROUP_SIZE - 1, WORKGROUP_SIZE), 1, 1);

        if (self.validation_enabled) {
            var compute_to_copy = std.mem.zeroes(c.VkMemoryBarrier);
            compute_to_copy.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            compute_to_copy.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            compute_to_copy.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &compute_to_copy, 0, null, 0, null);
            const copy = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = self.validation_layout.counters_offset, .size = counter_bytes };
            c.vkCmdCopyBuffer(cmd, counters.buffer, self.validation_readback[frame_index].buffer, 1, &copy);
            const id_bytes = self.capacity * MAX_LOD_LEVELS * 4 * @sizeOf(u32);
            const id_copy = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = self.validation_layout.ids_offset, .size = id_bytes };
            c.vkCmdCopyBuffer(cmd, visible_ids.buffer, self.validation_readback[frame_index].buffer, 1, &id_copy);
            const copies = [_]struct { source: c.VkBuffer, destination_offset: usize, size: usize }{
                .{ .source = terrain_indirect.buffer, .destination_offset = self.validation_layout.terrain_commands_offset, .size = stream_command_bytes },
                .{ .source = water_indirect.buffer, .destination_offset = self.validation_layout.water_commands_offset, .size = stream_command_bytes },
                .{ .source = compact_terrain_indirect.buffer, .destination_offset = self.validation_layout.compact_terrain_commands_offset, .size = compact_stream_command_bytes },
                .{ .source = compact_water_indirect.buffer, .destination_offset = self.validation_layout.compact_water_commands_offset, .size = compact_stream_command_bytes },
                .{ .source = self.lookup(self.terrain_instances[frame_index]).?.buffer, .destination_offset = self.validation_layout.terrain_instances_offset, .size = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.InstanceData) },
                .{ .source = self.lookup(self.water_instances[frame_index]).?.buffer, .destination_offset = self.validation_layout.water_instances_offset, .size = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.InstanceData) },
                .{ .source = self.lookup(self.compact_terrain_instances[frame_index]).?.buffer, .destination_offset = self.validation_layout.compact_terrain_instances_offset, .size = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.CompactLODInstance) },
                .{ .source = self.lookup(self.compact_water_instances[frame_index]).?.buffer, .destination_offset = self.validation_layout.compact_water_instances_offset, .size = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.CompactLODInstance) },
            };
            for (copies) |entry| {
                const payload_copy = c.VkBufferCopy{ .srcOffset = 0, .dstOffset = @intCast(entry.destination_offset), .size = @intCast(entry.size) };
                c.vkCmdCopyBuffer(cmd, entry.source, self.validation_readback[frame_index].buffer, 1, &payload_copy);
            }
            var copy_to_host = std.mem.zeroes(c.VkMemoryBarrier);
            copy_to_host.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            copy_to_host.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            copy_to_host.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &copy_to_host, 0, null, 0, null);
            self.validation_expected[frame_index] = cpuExpectedCounts(input, push);
            fillExpectedIds(self.validation_expected_ids[frame_index], input, push, self.capacity);
            @memcpy(self.validation_expected_candidates[frame_index][0..input.len], input);
            self.validation_candidate_count[frame_index] = input.len;
            self.diagnostics_state.validation_generation +|= 1;
            self.validation_pending_generation[frame_index] = self.diagnostics_state.validation_generation;
            self.validation_pending[frame_index] = true;
        }

        var compute_to_draw = std.mem.zeroes(c.VkMemoryBarrier);
        compute_to_draw.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_to_draw.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_to_draw.dstAccessMask = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, 0, 1, &compute_to_draw, 0, null, 0, null);
        return true;
    }

    fn validateCompletedFrame(self: *LODCullingSystem, frame_index: usize) void {
        if (!self.validation_enabled or !self.validation_pending[frame_index]) return;
        // A frame slot is dispatched only after its fence has completed, so
        // coherent transfer results are safe to read here without a stall.
        const mapped = self.validation_readback[frame_index].mapped_ptr orelse return;
        const bytes: [*]const u8 = @ptrCast(mapped);
        const actual: *const [MAX_LOD_LEVELS * 4]u32 = @ptrCast(@alignCast(bytes + self.validation_layout.counters_offset));
        var mismatch = !std.mem.eql(u32, actual, &self.validation_expected[frame_index]);
        const actual_ids: [*]u32 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(mapped)) + self.validation_layout.ids_offset));
        for (0..MAX_LOD_LEVELS * 4) |stream| {
            const count = @min(actual[stream], @as(u32, @intCast(self.capacity)));
            const start = stream * self.capacity;
            for (0..count) |slot| {
                const candidate_index = actual_ids[start + slot];
                if (candidate_index >= self.validation_candidate_count[frame_index]) {
                    mismatch = true;
                    continue;
                }
                const candidate = self.validation_expected_candidates[frame_index][candidate_index];
                if (!matchesPayload(self, bytes, stream, slot, candidate)) mismatch = true;
            }
            const gpu_slice = actual_ids[start .. start + count];
            const cpu_slice = self.validation_expected_ids[frame_index][start .. start + count];
            std.mem.sort(u32, gpu_slice, {}, std.sort.asc(u32));
            std.mem.sort(u32, cpu_slice, {}, std.sort.asc(u32));
            if (!std.mem.eql(u32, gpu_slice, cpu_slice)) mismatch = true;
        }
        if (mismatch) {
            self.diagnostics_state.validation_mismatch_count +|= 1;
        }
        self.diagnostics_state.validation_completed_generation = self.validation_pending_generation[frame_index];
        self.diagnostics_state.validation_completed_count +|= 1;
        self.validation_pending[frame_index] = false;
    }

    fn matchesPayload(self: *const LODCullingSystem, bytes: [*]const u8, stream: usize, slot: usize, candidate: culling.LODCullCandidate) bool {
        const lod = @min(candidate.lod_and_padding[0], MAX_LOD_LEVELS - 1);
        const output_index = lod * self.capacity + slot;
        const compact = stream >= MAX_LOD_LEVELS * 2;
        const water = stream % (MAX_LOD_LEVELS * 2) >= MAX_LOD_LEVELS;
        const command = if (water) candidate.water_command else candidate.terrain_command;
        var expected_model = candidate.model;
        if (!water) expected_model.data[3][1] -= 0.05;
        if (!compact) {
            const command_offset = (if (water) self.validation_layout.water_commands_offset else self.validation_layout.terrain_commands_offset) + output_index * @sizeOf(rhi.DrawIndirectCommand);
            const actual_command: *const rhi.DrawIndirectCommand = @ptrCast(@alignCast(bytes + command_offset));
            const expected_command = rhi.DrawIndirectCommand{
                .vertexCount = command.count,
                .instanceCount = command.instance_count,
                .firstVertex = command.first,
                .firstInstance = @intCast(output_index),
            };
            if (!std.mem.eql(u8, std.mem.asBytes(actual_command), std.mem.asBytes(&expected_command))) return false;
            const instance_offset = (if (water) self.validation_layout.water_instances_offset else self.validation_layout.terrain_instances_offset) + output_index * @sizeOf(rhi.InstanceData);
            const actual_instance: *const rhi.InstanceData = @ptrCast(@alignCast(bytes + instance_offset));
            const expected_instance = rhi.InstanceData{
                .model = expected_model,
                .mask_radius = candidate.instance_params[0],
                .lod_fade = candidate.instance_params[1],
                .padding = .{ candidate.instance_params[2], candidate.instance_params[3] },
                .ownership_bounds = candidate.ownership_bounds,
            };
            return std.mem.eql(u8, std.mem.asBytes(actual_instance), std.mem.asBytes(&expected_instance));
        }
        const command_offset = (if (water) self.validation_layout.compact_water_commands_offset else self.validation_layout.compact_terrain_commands_offset) + output_index * @sizeOf(rhi.DrawIndexedIndirectCommand);
        const actual_command: *const rhi.DrawIndexedIndirectCommand = @ptrCast(@alignCast(bytes + command_offset));
        const expected_command = rhi.DrawIndexedIndirectCommand{
            .indexCount = command.count,
            .instanceCount = command.instance_count,
            .firstIndex = command.first,
            .vertexOffset = command.vertex_offset,
            .firstInstance = @intCast(output_index),
        };
        if (!std.mem.eql(u8, std.mem.asBytes(actual_command), std.mem.asBytes(&expected_command))) return false;
        const instance_offset = (if (water) self.validation_layout.compact_water_instances_offset else self.validation_layout.compact_terrain_instances_offset) + output_index * @sizeOf(rhi.CompactLODInstance);
        const actual_instance: *const rhi.CompactLODInstance = @ptrCast(@alignCast(bytes + instance_offset));
        const expected_instance = rhi.CompactLODInstance{
            .model = expected_model,
            .params = candidate.instance_params,
            .words = candidate.compact_words,
            .ownership_bounds = candidate.ownership_bounds,
        };
        return std.mem.eql(u8, std.mem.asBytes(actual_instance), std.mem.asBytes(&expected_instance));
    }

    fn lookup(self: *LODCullingSystem, handle: rhi.BufferHandle) ?Utils.VulkanBuffer {
        return self.ctx.resources.buffers.get(handle);
    }

    fn initPipeline(self: *LODCullingSystem) !void {
        const vk = self.ctx.vulkan_device.vk_device;
        var pool_sizes = [_]c.VkDescriptorPoolSize{.{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 11 * FRAME_COUNT }};
        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = FRAME_COUNT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));
        var bindings: [11]c.VkDescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*binding, i| binding.* = .{ .binding = @intCast(i), .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_layout));
        var layouts = [_]c.VkDescriptorSetLayout{self.descriptor_layout} ** FRAME_COUNT;
        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = FRAME_COUNT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));
        self.updateDescriptors();
        var range = std.mem.zeroes(c.VkPushConstantRange);
        range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        range.size = @sizeOf(culling.LODCullDispatch);
        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));
        const module = try loadShader(vk, self.allocator);
        defer c.vkDestroyShaderModule(vk, module, null);
        var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        stage.module = module;
        stage.pName = "main";
        var info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        info.stage = stage;
        info.layout = self.pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &info, null, &self.pipeline));
    }

    fn updateDescriptors(self: *LODCullingSystem) void {
        var writes: [11 * FRAME_COUNT]c.VkWriteDescriptorSet = undefined;
        var infos: [11 * FRAME_COUNT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;
        for (0..FRAME_COUNT) |fi| {
            const buffers = [_]c.VkBuffer{
                self.candidates[fi].buffer,
                self.lookup(self.terrain_instances[fi]).?.buffer,
                self.lookup(self.water_instances[fi]).?.buffer,
                self.lookup(self.terrain_indirect[fi]).?.buffer,
                self.lookup(self.water_indirect[fi]).?.buffer,
                self.lookup(self.compact_terrain_instances[fi]).?.buffer,
                self.lookup(self.compact_water_instances[fi]).?.buffer,
                self.lookup(self.compact_terrain_indirect[fi]).?.buffer,
                self.lookup(self.compact_water_indirect[fi]).?.buffer,
                self.lookup(self.counters[fi]).?.buffer,
                self.lookup(self.visible_ids[fi]).?.buffer,
            };
            for (buffers, 0..) |buffer, binding| {
                infos[n] = .{ .buffer = buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
                writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[n].dstSet = self.descriptor_sets[fi];
                writes[n].dstBinding = @intCast(binding);
                writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                writes[n].descriptorCount = 1;
                writes[n].pBufferInfo = &infos[n];
                n += 1;
            }
        }
        c.vkUpdateDescriptorSets(self.ctx.vulkan_device.vk_device, @intCast(n), &writes, 0, null);
    }

    fn destroyPipeline(self: *LODCullingSystem) void {
        const vk = self.ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);
    }
};

const VTABLE = culling.ILODCullingSystem.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            (@as(*LODCullingSystem, @ptrCast(@alignCast(ptr)))).deinit();
        }
    }.call,
    .dispatch = struct {
        fn call(ptr: *anyopaque, frame: usize, candidates: []const culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
            return (@as(*LODCullingSystem, @ptrCast(@alignCast(ptr)))).dispatch(frame, candidates, config);
        }
    }.call,
    .instanceBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize, fluid: bool, compact: bool) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            if (compact) return if (fluid) self.compact_water_instances[frame] else self.compact_terrain_instances[frame];
            return if (fluid) self.water_instances[frame] else self.terrain_instances[frame];
        }
    }.call,
    .indirectBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize, fluid: bool, compact: bool) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            if (compact) return if (fluid) self.compact_water_indirect[frame] else self.compact_terrain_indirect[frame];
            return if (fluid) self.water_indirect[frame] else self.terrain_indirect[frame];
        }
    }.call,
    .countBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return self.counters[frame];
        }
    }.call,
    .diagnostics = struct {
        fn call(ptr: *anyopaque) culling.LODCullDiagnostics {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return self.diagnostics_state;
        }
    }.call,
};

pub fn create(allocator: std.mem.Allocator, ctx: *VulkanContext, capacity: usize) !rhi.ILODCullingSystem {
    const system = try LODCullingSystem.init(allocator, ctx, capacity);
    return .{ .ptr = system, .vtable = &VTABLE };
}

fn destroyNative(device: c.VkDevice, buffer: *Utils.VulkanBuffer) void {
    if (buffer.mapped_ptr != null) c.vkUnmapMemory(device, buffer.memory);
    if (buffer.buffer != null) c.vkDestroyBuffer(device, buffer.buffer, null);
    if (buffer.memory != null) c.vkFreeMemory(device, buffer.memory, null);
    buffer.* = .{};
}

fn loadShader(device: c.VkDevice, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try fs.cwd().readFileAlloc(SHADER_PATH, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;
    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));
    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(device, &info, null, &module));
    return module;
}

fn envFlag(name: [*:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    const bytes = std.mem.span(value);
    return !(std.mem.eql(u8, bytes, "0") or std.ascii.eqlIgnoreCase(bytes, "false"));
}

fn cpuExpectedCounts(input: []const culling.LODCullCandidate, config: culling.LODCullDispatch) [MAX_LOD_LEVELS * 4]u32 {
    var counts = [_]u32{0} ** (MAX_LOD_LEVELS * 4);
    for (input) |candidate| {
        if (!cpuVisible(candidate, config)) continue;
        const lod = @min(candidate.lod_and_padding[0], MAX_LOD_LEVELS - 1);
        const base: usize = if (candidate.lod_and_padding[1] != 0) MAX_LOD_LEVELS * 2 else 0;
        if (candidate.terrain_command.count != 0 and counts[base + lod] < config.max_commands_per_lod) counts[base + lod] += 1;
        const water_index = base + MAX_LOD_LEVELS + lod;
        if (candidate.water_command.count != 0 and counts[water_index] < config.max_commands_per_lod) counts[water_index] += 1;
    }
    return counts;
}

fn fillExpectedIds(output: []u32, input: []const culling.LODCullCandidate, config: culling.LODCullDispatch, capacity: usize) void {
    @memset(output, std.math.maxInt(u32));
    var counts = [_]u32{0} ** (MAX_LOD_LEVELS * 4);
    for (input, 0..) |candidate, candidate_index| {
        if (!cpuVisible(candidate, config)) continue;
        const lod = @min(candidate.lod_and_padding[0], MAX_LOD_LEVELS - 1);
        const base: usize = if (candidate.lod_and_padding[1] != 0) MAX_LOD_LEVELS * 2 else 0;
        const streams = [_]struct { index: usize, count: u32 }{
            .{ .index = base + lod, .count = candidate.terrain_command.count },
            .{ .index = base + MAX_LOD_LEVELS + lod, .count = candidate.water_command.count },
        };
        for (streams) |stream| {
            if (stream.count == 0 or counts[stream.index] >= config.max_commands_per_lod) continue;
            output[stream.index * capacity + counts[stream.index]] = @intCast(candidate_index);
            counts[stream.index] += 1;
        }
    }
}

fn cpuVisible(candidate: culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
    for (config.planes) |plane| {
        const x = if (plane[0] >= 0) candidate.max_point[0] else candidate.min_point[0];
        const y = if (plane[1] >= 0) candidate.max_point[1] else candidate.min_point[1];
        const z = if (plane[2] >= 0) candidate.max_point[2] else candidate.min_point[2];
        if (plane[0] * x + plane[1] * y + plane[2] * z + plane[3] < 0) return false;
    }
    if (config.max_distance_blocks <= 0) return true;
    const dx: f32 = if (candidate.min_point[0] > 0) candidate.min_point[0] else if (candidate.max_point[0] < 0) candidate.max_point[0] else 0;
    const dz: f32 = if (candidate.min_point[2] > 0) candidate.min_point[2] else if (candidate.max_point[2] < 0) candidate.max_point[2] else 0;
    return dx * dx + dz * dz <= config.max_distance_blocks * config.max_distance_blocks;
}

test "LOD culling CPU partitioning separates compact indexed streams" {
    var candidate = std.mem.zeroes(culling.LODCullCandidate);
    candidate.min_point = .{ -1, -1, -1, 0 };
    candidate.max_point = .{ 1, 1, 1, 0 };
    candidate.terrain_command.count = 3;
    candidate.water_command.count = 6;
    candidate.lod_and_padding[0] = 2;
    const planes = [_][4]f32{.{ 0, 0, 0, 1 }} ** 6;
    const counts = cpuExpectedCounts(&.{candidate}, .{ .planes = planes, .candidate_count = 1, .max_distance_blocks = 10, .max_commands_per_lod = 4 });
    try std.testing.expectEqual(@as(u32, 1), counts[2]);
    try std.testing.expectEqual(@as(u32, 1), counts[MAX_LOD_LEVELS + 2]);
    candidate.lod_and_padding[1] = 1;
    const compact_counts = cpuExpectedCounts(&.{candidate}, .{ .planes = planes, .candidate_count = 1, .max_distance_blocks = 10, .max_commands_per_lod = 4 });
    try std.testing.expectEqual(@as(u32, 1), compact_counts[MAX_LOD_LEVELS * 2 + 2]);
    try std.testing.expectEqual(@as(u32, 1), compact_counts[MAX_LOD_LEVELS * 3 + 2]);
}

test "cleared fixed-capacity indirect entries are draw no-ops" {
    // GPU culling submits a fixed-capacity MDI stream because RADV's indirect
    // count path corrupts otherwise validated output. vkCmdFillBuffer writes
    // this exact all-zero representation before each dispatch; Vulkan defines
    // zero vertex/index counts as no-op draws.
    const direct = std.mem.zeroes(rhi.DrawIndirectCommand);
    try std.testing.expectEqual(@as(u32, 0), direct.vertexCount);
    try std.testing.expectEqual(@as(u32, 0), direct.instanceCount);
    const indexed = std.mem.zeroes(rhi.DrawIndexedIndirectCommand);
    try std.testing.expectEqual(@as(u32, 0), indexed.indexCount);
    try std.testing.expectEqual(@as(u32, 0), indexed.instanceCount);
}
