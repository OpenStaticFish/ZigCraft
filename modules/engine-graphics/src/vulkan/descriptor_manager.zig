const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const ResourceManager = @import("resource_manager.zig").ResourceManager;
const VulkanBuffer = @import("resource_manager.zig").VulkanBuffer;
const Mat4 = @import("engine-math").Mat4;
pub const ShadowUniforms = @import("shadow_uniforms.zig").ShadowUniforms;
const Utils = @import("utils.zig");

const MAX_DESCRIPTOR_SNAPSHOTS: usize = 128;

const DescriptorSnapshotSlots = struct {
    current: usize = 0,
    used: usize = 1,
    sealed: bool = false,

    fn seal(self: *DescriptorSnapshotSlots) void {
        self.sealed = true;
    }

    fn writableSlot(self: *DescriptorSnapshotSlots) !?usize {
        if (!self.sealed) return null;
        if (self.used == MAX_DESCRIPTOR_SNAPSHOTS) return error.DescriptorSnapshotCapacityExceeded;
        self.current = (self.current + 1) % MAX_DESCRIPTOR_SNAPSHOTS;
        self.used += 1;
        self.sealed = false;
        return self.current;
    }

    fn reset(self: *DescriptorSnapshotSlots) void {
        // Retain the latest descriptor contents, but retire all earlier binds.
        // Starting at slot zero instead could reuse the retained set mid-frame.
        self.used = 1;
        self.sealed = false;
    }
};

const GlobalUniforms = extern struct {
    view_proj: Mat4,
    view_proj_prev: Mat4,
    cam_pos: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    fog_color: [4]f32,
    reserved0: [4]f32,
    params: [4]f32,
    lighting: [4]f32,
    render_flags: [4]f32,
    shadow_params: [4]f32,
    pbr_params: [4]f32,
    volumetric_params: [4]f32,
    viewport_size: [4]f32,
    lpv_params: [4]f32,
    lpv_origin: [4]f32,
};

pub const DescriptorManager = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *const VulkanDevice,
    resource_manager: *ResourceManager,

    descriptor_pool: c.VkDescriptorPool,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    snapshot_sets: [rhi.MAX_FRAMES_IN_FLIGHT][MAX_DESCRIPTOR_SNAPSHOTS]c.VkDescriptorSet = .{.{null} ** MAX_DESCRIPTOR_SNAPSHOTS} ** rhi.MAX_FRAMES_IN_FLIGHT,
    snapshot_slots: [rhi.MAX_FRAMES_IN_FLIGHT]DescriptorSnapshotSlots = [_]DescriptorSnapshotSlots{.{}} ** rhi.MAX_FRAMES_IN_FLIGHT,
    snapshot_failed: [rhi.MAX_FRAMES_IN_FLIGHT]bool = .{false} ** rhi.MAX_FRAMES_IN_FLIGHT,
    update_descriptor_sets_fn: @TypeOf(&c.vkUpdateDescriptorSets) = c.vkUpdateDescriptorSets,

    global_ubos: [rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    global_ubos_mapped: [rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    shadow_ubos: [rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    shadow_ubos_mapped: [rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    dummy_instance_ssbo: VulkanBuffer,

    // Dummy textures
    dummy_texture: rhi.TextureHandle,
    dummy_texture_3d: rhi.TextureHandle,
    dummy_normal_texture: rhi.TextureHandle,
    dummy_roughness_texture: rhi.TextureHandle,

    pub fn init(allocator: std.mem.Allocator, vulkan_device: *const VulkanDevice, resource_manager: *ResourceManager) !DescriptorManager {
        var self = DescriptorManager{
            .allocator = allocator,
            .vulkan_device = vulkan_device,
            .resource_manager = resource_manager,
            .descriptor_pool = null,
            .descriptor_set_layout = null,
            .descriptor_sets = undefined,
            .global_ubos = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer),
            .global_ubos_mapped = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque),
            .shadow_ubos = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer),
            .shadow_ubos_mapped = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque),
            .dummy_instance_ssbo = std.mem.zeroes(VulkanBuffer),
            .dummy_texture = 0,
            .dummy_texture_3d = 0,
            .dummy_normal_texture = 0,
            .dummy_roughness_texture = 0,
        };

        // Create UBOs
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.global_ubos[i] = Utils.createVulkanBuffer(vulkan_device, @sizeOf(GlobalUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) catch |err| {
                self.deinit();
                return err;
            };
            self.global_ubos_mapped[i] = self.global_ubos[i].mapped_ptr;

            self.shadow_ubos[i] = Utils.createVulkanBuffer(vulkan_device, @sizeOf(ShadowUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) catch |err| {
                self.deinit();
                return err;
            };
            self.shadow_ubos_mapped[i] = self.shadow_ubos[i].mapped_ptr;
        }

        self.dummy_instance_ssbo = Utils.createVulkanBuffer(vulkan_device, 256, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) catch |err| {
            self.deinit();
            return err;
        };
        // Create dummy textures at frame index 1 to isolate from frame 0's lifecycle.
        resource_manager.setCurrentFrame(1);

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        self.dummy_texture = resource_manager.createTexture(1, 1, .rgba, .{}, &white_pixel) catch |err| {
            self.deinit();
            return err;
        };

        const normal_neutral = [_]u8{ 128, 128, 255, 0 };
        self.dummy_normal_texture = resource_manager.createTexture(1, 1, .rgba, .{}, &normal_neutral) catch |err| {
            self.deinit();
            return err;
        };

        const roughness_neutral = [_]u8{ 255, 0, 0, 255 };
        self.dummy_roughness_texture = resource_manager.createTexture(1, 1, .rgba, .{}, &roughness_neutral) catch |err| {
            self.deinit();
            return err;
        };

        // 1x1x1 3D dummy texture for sampler3D bindings (LPV).
        // Uses rgba32f to match LPV texture format, with zero data (no SH contribution).
        const zero_pixel = [_]u8{0} ** 16; // 4 x f32 = 16 bytes, all zero
        self.dummy_texture_3d = resource_manager.createTexture3D(1, 1, 1, .rgba32f, .{}, &zero_pixel) catch |err| {
            self.deinit();
            return err;
        };

        resource_manager.flushTransfer() catch |err| {
            self.deinit();
            return err;
        };

        // Create Descriptor Pool
        // Reserve a bounded set of frame-local main-layout snapshots in addition
        // to the existing UI/post-processing budget. Allocate snapshots on demand.
        const extra_sets: u32 = @intCast((MAX_DESCRIPTOR_SNAPSHOTS - 1) * rhi.MAX_FRAMES_IN_FLIGHT);
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 500 + 2 * extra_sets },
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 + 13 * extra_sets },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 32 + extra_sets },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes[0];
        pool_info.maxSets = 1000 + extra_sets;
        pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;

        Utils.checkVk(c.vkCreateDescriptorPool(vulkan_device.vk_device, &pool_info, null, &self.descriptor_pool)) catch |err| {
            self.deinit();
            return err;
        };

        // Create Descriptor Set Layout
        var bindings = [_]c.VkDescriptorSetLayoutBinding{
            // 0: Global Uniforms
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT },
            // 1: Main Texture Atlas
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 2: Shadow Uniforms
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 3: Shadow Map Array (Comparison)
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 4: Shadow Map Array (Regular)
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 5: Instance SSBO
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 6: Normal Map
            .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 7: Roughness Map
            .{ .binding = 7, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 8: Displacement Map
            .{ .binding = 8, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 9: Environment Map
            .{ .binding = 9, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 10: SSAO Map
            .{ .binding = 10, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 11: LPV SH Red channel (or scalar RGB when SH disabled)
            .{ .binding = 11, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 12: LPV SH Green channel
            .{ .binding = 12, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 13: LPV SH Blue channel
            .{ .binding = 13, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 14: Water reflection texture
            .{ .binding = 14, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            // 15: Scene depth texture (for water refraction)
            .{ .binding = 15, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings[0];

        Utils.checkVk(c.vkCreateDescriptorSetLayout(vulkan_device.vk_device, &layout_info, null, &self.descriptor_set_layout)) catch |err| {
            self.deinit();
            return err;
        };

        // Allocate Descriptor Sets
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = self.descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &self.descriptor_set_layout;

            Utils.checkVk(c.vkAllocateDescriptorSets(vulkan_device.vk_device, &alloc_info, &self.descriptor_sets[i])) catch |err| {
                self.deinit();
                return err;
            };
            self.snapshot_sets[i][0] = self.descriptor_sets[i];

            // Write UBO descriptors immediately (they don't change)
            var buffer_info_global = c.VkDescriptorBufferInfo{
                .buffer = self.global_ubos[i].buffer,
                .offset = 0,
                .range = @sizeOf(GlobalUniforms),
            };
            var buffer_info_shadow = c.VkDescriptorBufferInfo{
                .buffer = self.shadow_ubos[i].buffer,
                .offset = 0,
                .range = @sizeOf(ShadowUniforms),
            };
            var buffer_info_instance = c.VkDescriptorBufferInfo{
                .buffer = self.dummy_instance_ssbo.buffer,
                .offset = 0,
                .range = 256,
            };
            var writes = [_]c.VkWriteDescriptorSet{
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 0,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .descriptorCount = 1,
                    .pBufferInfo = &buffer_info_global,
                },
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 2,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .descriptorCount = 1,
                    .pBufferInfo = &buffer_info_shadow,
                },
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = 5,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .descriptorCount = 1,
                    .pBufferInfo = &buffer_info_instance,
                },
            };
            c.vkUpdateDescriptorSets(vulkan_device.vk_device, writes.len, &writes[0], 0, null);

            // Seed every sampled binding with a type-correct dummy before a
            // material supplies its first texture update.
            const dummy_2d = self.resource_manager.textures.get(self.dummy_texture).?;
            const dummy_3d = self.resource_manager.textures.get(self.dummy_texture_3d).?;
            var dummy_2d_info = c.VkDescriptorImageInfo{
                .sampler = dummy_2d.sampler,
                .imageView = dummy_2d.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            var dummy_3d_info = c.VkDescriptorImageInfo{
                .sampler = dummy_3d.sampler,
                .imageView = dummy_3d.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            var texture_writes: [13]c.VkWriteDescriptorSet = undefined;
            for ([_]u32{ 1, 3, 4, 6, 7, 8, 9, 10, 14, 15 }, 0..) |binding, write_index| {
                texture_writes[write_index] = .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = binding,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    .descriptorCount = 1,
                    .pImageInfo = &dummy_2d_info,
                };
            }
            for ([_]u32{ 11, 12, 13 }, 0..) |binding, offset| {
                texture_writes[10 + offset] = .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.descriptor_sets[i],
                    .dstBinding = binding,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    .descriptorCount = 1,
                    .pImageInfo = &dummy_3d_info,
                };
            }
            c.vkUpdateDescriptorSets(vulkan_device.vk_device, texture_writes.len, &texture_writes[0], 0, null);
        }

        return self;
    }

    pub fn deinit(self: *DescriptorManager) void {
        const device = self.vulkan_device.vk_device;

        // Destroy UBOs (Persistent mapping is unmapped in deinit via destruction)
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.global_ubos[i].buffer != null) {
                if (self.global_ubos[i].mapped_ptr != null) c.vkUnmapMemory(device, self.global_ubos[i].memory);
                c.vkDestroyBuffer(device, self.global_ubos[i].buffer, null);
                c.vkFreeMemory(device, self.global_ubos[i].memory, null);
            }

            if (self.shadow_ubos[i].buffer != null) {
                if (self.shadow_ubos[i].mapped_ptr != null) c.vkUnmapMemory(device, self.shadow_ubos[i].memory);
                c.vkDestroyBuffer(device, self.shadow_ubos[i].buffer, null);
                c.vkFreeMemory(device, self.shadow_ubos[i].memory, null);
            }
        }

        if (self.dummy_instance_ssbo.buffer != null) {
            if (self.dummy_instance_ssbo.mapped_ptr != null) c.vkUnmapMemory(device, self.dummy_instance_ssbo.memory);
            c.vkDestroyBuffer(device, self.dummy_instance_ssbo.buffer, null);
            c.vkFreeMemory(device, self.dummy_instance_ssbo.memory, null);
        }

        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(device, self.descriptor_pool, null);
    }

    /// Only call after this frame's fence has completed and its CB was reset.
    pub fn beginFrame(self: *DescriptorManager, frame_index: usize) void {
        self.snapshot_slots[frame_index].reset();
        self.snapshot_failed[frame_index] = false;
    }

    pub fn seal(self: *DescriptorManager, frame_index: usize) void {
        self.snapshot_slots[frame_index].seal();
    }

    pub fn writeDescriptors(self: *DescriptorManager, writes: []const c.VkWriteDescriptorSet) void {
        self.update_descriptor_sets_fn(self.vulkan_device.vk_device, @intCast(writes.len), writes.ptr, 0, null);
    }

    /// A bound ordinary descriptor set cannot be updated, even before submit.
    /// Copy every binding so material, LPV and instance updates preserve the rest.
    pub fn ensureWritable(self: *DescriptorManager, frame_index: usize) bool {
        if (self.snapshot_failed[frame_index]) return false;
        var slots = self.snapshot_slots[frame_index];
        const slot = (slots.writableSlot() catch |err| {
            log.log.err("Main descriptor snapshots exhausted for frame {}: {}; skipping affected draws", .{ frame_index, err });
            self.snapshot_failed[frame_index] = true;
            return false;
        }) orelse return true;

        const destination = &self.snapshot_sets[frame_index][slot];
        if (destination.* == null) {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = self.descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &self.descriptor_set_layout;
            Utils.checkVk(c.vkAllocateDescriptorSets(self.vulkan_device.vk_device, &alloc_info, destination)) catch |err| {
                log.log.err("Failed to allocate main descriptor snapshot for frame {}: {}; skipping affected draws", .{ frame_index, err });
                destination.* = null;
                self.snapshot_failed[frame_index] = true;
                return false;
            };
        }

        var copies: [16]c.VkCopyDescriptorSet = undefined;
        for (&copies, 0..) |*copy, binding| {
            copy.* = .{
                .sType = c.VK_STRUCTURE_TYPE_COPY_DESCRIPTOR_SET,
                .srcSet = self.descriptor_sets[frame_index],
                .srcBinding = @intCast(binding),
                .dstSet = destination.*,
                .dstBinding = @intCast(binding),
                .descriptorCount = 1,
            };
        }
        self.update_descriptor_sets_fn(self.vulkan_device.vk_device, 0, null, copies.len, &copies);
        self.descriptor_sets[frame_index] = destination.*;
        self.snapshot_slots[frame_index] = slots;
        return true;
    }

    pub fn updateGlobalUniforms(self: *DescriptorManager, frame_index: usize, data: *const anyopaque) !void {
        const dest = self.global_ubos_mapped[frame_index] orelse {
            log.log.err("Failed to update global uniforms: memory not mapped", .{});
            return error.UnmappedBuffer;
        };
        const src = @as([*]const u8, @ptrCast(data));
        @memcpy(@as([*]u8, @ptrCast(dest))[0..@sizeOf(GlobalUniforms)], src[0..@sizeOf(GlobalUniforms)]);
    }

    pub fn updateShadowUniforms(self: *DescriptorManager, frame_index: usize, data: *const ShadowUniforms) !void {
        const dest = self.shadow_ubos_mapped[frame_index] orelse {
            log.log.err("Failed to update shadow uniforms: memory not mapped", .{});
            return error.UnmappedBuffer;
        };
        @memcpy(@as([*]u8, @ptrCast(dest))[0..@sizeOf(ShadowUniforms)], std.mem.asBytes(data));
    }

    // Additional methods for binding textures would go here
    // For now, we assume VulkanContext handles the complexity of gathering textures and calling a mass update
};

test "Descriptor snapshots copy on first write after binding and coalesce unbound updates" {
    var slots = DescriptorSnapshotSlots{};
    try std.testing.expectEqual(@as(?usize, null), try slots.writableSlot());
    slots.seal();
    try std.testing.expectEqual(@as(?usize, 1), try slots.writableSlot());
    // Albedo, normal and LPV changes before the next bind share a writable set.
    try std.testing.expectEqual(@as(?usize, null), try slots.writableSlot());
    slots.seal();
    try std.testing.expectEqual(@as(?usize, 2), try slots.writableSlot());
}

test "Descriptor snapshots never recycle a bound slot on capacity exhaustion" {
    var slots = DescriptorSnapshotSlots{};
    for (1..MAX_DESCRIPTOR_SNAPSHOTS) |i| {
        slots.seal();
        try std.testing.expectEqual(@as(?usize, i), try slots.writableSlot());
    }
    slots.seal();
    try std.testing.expectError(error.DescriptorSnapshotCapacityExceeded, slots.writableSlot());
    try std.testing.expectError(error.DescriptorSnapshotCapacityExceeded, slots.writableSlot());
    try std.testing.expectEqual(MAX_DESCRIPTOR_SNAPSHOTS - 1, slots.current);
    try std.testing.expect(slots.sealed);
}

test "Descriptor snapshots reset the retired frame without reusing its retained set" {
    var frames = [_]DescriptorSnapshotSlots{.{}} ** rhi.MAX_FRAMES_IN_FLIGHT;
    frames[0].seal();
    _ = try frames[0].writableSlot();
    frames[0].seal();
    frames[1].seal();
    frames[0].reset();
    try std.testing.expectEqual(@as(?usize, null), try frames[0].writableSlot());
    for (0..MAX_DESCRIPTOR_SNAPSHOTS - 1) |_| {
        frames[0].seal();
        const next = (try frames[0].writableSlot()).?;
        try std.testing.expect(next != 1);
    }
    frames[0].seal();
    try std.testing.expectError(error.DescriptorSnapshotCapacityExceeded, frames[0].writableSlot());
    try std.testing.expectEqual(@as(?usize, 1), try frames[1].writableSlot());
}

test "Descriptor snapshots preserve instance bindings through material changes and quarantine" {
    const render_state = @import("rhi_render_state.zig");
    const frame_state = @import("rhi_frame_orchestration.zig");
    const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
    const TextureResource = @import("resource_manager.zig").TextureResource;
    const Capture = struct {
        bindings: [3][16]usize = .{.{0} ** 16} ** 3,
        calls: usize = 0,

        // Emulate Vulkan descriptor writes/copies, not the snapshot policy.
        fn update(device: c.VkDevice, write_count: u32, writes: [*c]const c.VkWriteDescriptorSet, copy_count: u32, copies: [*c]const c.VkCopyDescriptorSet) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(device.?));
            self.calls += 1;
            if (write_count > 0) {
                for (writes[0..write_count]) |write| {
                    const set = @intFromPtr(write.dstSet.?) - 1;
                    self.bindings[set][write.dstBinding] = if (write.descriptorType == c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)
                        @intFromPtr(write.pBufferInfo[0].buffer.?)
                    else
                        @intFromPtr(write.pImageInfo[0].imageView.?);
                }
            }
            if (copy_count > 0) {
                for (copies[0..copy_count]) |copy| {
                    self.bindings[@intFromPtr(copy.dstSet.?) - 1][copy.dstBinding] = self.bindings[@intFromPtr(copy.srcSet.?) - 1][copy.srcBinding];
                }
            }
        }
    };
    var capture = Capture{};
    var ctx: VulkanContext = undefined;
    ctx.vulkan_device.vk_device = @ptrCast(&capture);
    ctx.frames.frame_in_progress = true;
    ctx.frames.terminal_failure = false;
    ctx.frames.current_frame = 0;
    ctx.resources.buffers = std.AutoHashMap(rhi.BufferHandle, VulkanBuffer).init(std.testing.allocator);
    defer ctx.resources.buffers.deinit();
    for ([_]rhi.BufferHandle{ 11, 22 }) |handle| {
        try ctx.resources.buffers.put(handle, .{ .buffer = @ptrFromInt(handle), .size = 64 });
    }
    ctx.resources.textures = std.AutoHashMap(rhi.TextureHandle, TextureResource).init(std.testing.allocator);
    defer ctx.resources.textures.deinit();
    for ([_]rhi.TextureHandle{ 100, 101, 110, 111 }) |handle| {
        try ctx.resources.textures.put(handle, .{
            .image = null,
            .memory = null,
            .view = @ptrFromInt(handle),
            .sampler = @ptrFromInt(1),
            .width = 1,
            .height = 1,
            .depth = 1,
            .format = .rgba,
            .config = .{},
            .is_3d = handle >= 110,
        });
    }
    ctx.draw = .{ .current_texture = 100, .current_lpv_texture = 110, .dummy_texture = 100, .dummy_texture_3d = 110 };
    ctx.shadow_system.shadow_image_views = .{null} ** rhi.SHADOW_CASCADE_COUNT;
    ctx.shadow_system.shadow_image_view = null;
    ctx.shadow_system.shadow_sampler = null;
    ctx.descriptors = .{
        .allocator = std.testing.allocator,
        .vulkan_device = &ctx.vulkan_device,
        .resource_manager = &ctx.resources,
        .descriptor_pool = null,
        .descriptor_set_layout = null,
        .descriptor_sets = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
        .global_ubos = undefined,
        .global_ubos_mapped = undefined,
        .shadow_ubos = undefined,
        .shadow_ubos_mapped = undefined,
        .dummy_instance_ssbo = undefined,
        .dummy_texture = 100,
        .dummy_texture_3d = 110,
        .dummy_normal_texture = 100,
        .dummy_roughness_texture = 100,
        .update_descriptor_sets_fn = Capture.update,
    };
    for (0..3) |i| ctx.descriptors.snapshot_sets[0][i] = @ptrFromInt(i + 1);
    ctx.descriptors.descriptor_sets[0] = ctx.descriptors.snapshot_sets[0][0];

    render_state.setInstanceBuffer(&ctx, 11);
    try std.testing.expect(render_state.prepareDrawDescriptors(&ctx));
    const first_set = ctx.descriptors.descriptor_sets[0];
    render_state.setInstanceBuffer(&ctx, 22);
    try std.testing.expect(render_state.prepareDrawDescriptors(&ctx));
    const second_set = ctx.descriptors.descriptor_sets[0];

    ctx.draw.current_texture = 101;
    ctx.draw.current_lpv_texture = 111;
    frame_state.refreshTextureDescriptors(&ctx);
    try std.testing.expect(render_state.prepareDrawDescriptors(&ctx));
    const third_set = ctx.descriptors.descriptor_sets[0];
    try std.testing.expect(first_set != second_set and second_set != third_set and first_set != third_set);
    try std.testing.expectEqual(@as(usize, 11), capture.bindings[0][5]);
    try std.testing.expectEqual(@as(usize, 22), capture.bindings[1][5]);
    try std.testing.expectEqual(@as(usize, 22), capture.bindings[2][5]);
    try std.testing.expectEqual(@as(usize, 100), capture.bindings[0][1]);
    try std.testing.expectEqual(@as(usize, 100), capture.bindings[1][1]);
    try std.testing.expectEqual(@as(usize, 101), capture.bindings[2][1]);
    try std.testing.expectEqual(@as(usize, 110), capture.bindings[1][11]);
    try std.testing.expectEqual(@as(usize, 111), capture.bindings[2][11]);

    const calls = capture.calls;
    try std.testing.expect(render_state.prepareDrawDescriptors(&ctx));
    try std.testing.expectEqual(calls, capture.calls);
    ctx.frames.failFrame();
    ctx.draw.current_texture = 100;
    render_state.setInstanceBuffer(&ctx, 11);
    frame_state.refreshTextureDescriptors(&ctx);
    frame_state.prepareFrameState(&ctx);
    try std.testing.expect(!render_state.prepareDrawDescriptors(&ctx));
    try std.testing.expectEqual(calls, capture.calls);
    try std.testing.expectEqual(third_set, ctx.descriptors.descriptor_sets[0]);
    try std.testing.expectEqual(@as(usize, 3), ctx.descriptors.snapshot_slots[0].used);
    try std.testing.expect(ctx.descriptors.snapshot_slots[0].sealed);
}
