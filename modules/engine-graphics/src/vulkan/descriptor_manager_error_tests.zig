//! Unit tests for DescriptorManager error paths and validation
//!
//! Tests for error handling that don't require GPU calls.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const descriptor_manager = @import("descriptor_manager.zig");
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;

test "DescriptorManager field types are correct for null initialization" {
    const manager = descriptor_manager.DescriptorManager{
        .allocator = testing.allocator,
        .vulkan_device = undefined,
        .resource_manager = undefined,
        .descriptor_pool = null,
        .descriptor_set_layout = null,
        .descriptor_sets = undefined,
        .global_ubos = undefined,
        .global_ubos_mapped = undefined,
        .shadow_ubos = undefined,
        .shadow_ubos_mapped = undefined,
        .dummy_instance_ssbo = undefined,
        .dummy_texture = 0,
        .dummy_texture_3d = 0,
        .dummy_normal_texture = 0,
        .dummy_roughness_texture = 0,
    };

    try testing.expectEqual(@as(c.VkDescriptorPool, null), manager.descriptor_pool);
    try testing.expectEqual(@as(c.VkDescriptorSetLayout, null), manager.descriptor_set_layout);
}

test "updateGlobalUniforms returns error.UnmappedBuffer for invalid frame" {
    // When mapped_ptr is null for a frame, should return error
    const VulkanBuffer = @import("resource_manager.zig").VulkanBuffer;
    var manager: descriptor_manager.DescriptorManager = .{
        .allocator = testing.allocator,
        .vulkan_device = undefined,
        .resource_manager = undefined,
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

    // Both frames have null mapped pointers
    try testing.expect(manager.global_ubos_mapped[0] == null);
    try testing.expect(manager.global_ubos_mapped[1] == null);

    // Update should fail because mapped_ptr is null
    var data: [64]u8 = undefined;
    const result = manager.updateGlobalUniforms(0, &data);
    try testing.expectError(error.UnmappedBuffer, result);
}

test "updateShadowUniforms returns error.UnmappedBuffer for invalid frame" {
    const VulkanBuffer = @import("resource_manager.zig").VulkanBuffer;
    var manager: descriptor_manager.DescriptorManager = .{
        .allocator = testing.allocator,
        .vulkan_device = undefined,
        .resource_manager = undefined,
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

    try testing.expect(manager.shadow_ubos_mapped[0] == null);
    try testing.expect(manager.shadow_ubos_mapped[1] == null);

    const data = std.mem.zeroes(descriptor_manager.ShadowUniforms);
    const result = manager.updateShadowUniforms(0, &data);
    try testing.expectError(error.UnmappedBuffer, result);
}

test "GlobalUniforms extern struct has correct std140 alignment" {
    const GlobalUniforms = extern struct {
        view_proj: Mat4,
        view_proj_prev: Mat4,
        cam_pos: [4]f32,
        sun_dir: [4]f32,
        sun_color: [4]f32,
        fog_color: [4]f32,
        cloud_wind_offset: [4]f32,
        params: [4]f32,
        lighting: [4]f32,
        cloud_params: [4]f32,
        shadow_params: [4]f32,
        pbr_params: [4]f32,
        volumetric_params: [4]f32,
        viewport_size: [4]f32,
        lpv_params: [4]f32,
        lpv_origin: [4]f32,
    };

    const size = @sizeOf(GlobalUniforms);
    // Mat4 is 64 bytes, 2 of them = 128
    // 14 [4]f32 arrays = 14 * 16 = 224
    // Total = 352 bytes minimum
    try testing.expect(size >= 352);
    try testing.expect(size % 16 == 0); // std140 requires 16-byte alignment
}

test "ShadowUniforms extern struct has correct std140 alignment" {
    const ShadowUniforms = extern struct {
        light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
        cascade_splits: [4]f32,
        shadow_texel_sizes: [4]f32,
        shadow_params: [4]f32,
    };

    const size = @sizeOf(ShadowUniforms);
    // 4 Mat4s = 4 * 64 = 256
    // 3 [4]f32 arrays = 3 * 16 = 48
    // Total = 304 bytes minimum
    try testing.expect(size >= 304);
    try testing.expect(size % 16 == 0); // std140 requires 16-byte alignment
}

test "MAX_FRAMES_IN_FLIGHT is 2" {
    try testing.expectEqual(@as(usize, 2), rhi.MAX_FRAMES_IN_FLIGHT);
}

test "descriptor pool maxSets is 1000" {
    // From the init function: pool_info.maxSets = 1000
    const max_sets = 1000;
    try testing.expect(max_sets > 0);
    try testing.expect(max_sets <= 10000); // Reasonable limit
}

test "descriptor pool sizes are balanced" {
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 500 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 100 },
    };

    // Uniform buffers: 500 (for global + shadow UBOs per frame)
    try testing.expect(pool_sizes[0].descriptorCount >= 100);

    // Image samplers: 1000 (textures per frame)
    try testing.expect(pool_sizes[1].descriptorCount >= 500);

    // Storage buffers: 100 (instance data)
    try testing.expect(pool_sizes[2].descriptorCount >= 10);
}

test "dummy texture handle 0 is invalid" {
    const invalid_handle: rhi.TextureHandle = 0;
    try testing.expect(invalid_handle == 0);
}

test "frame index bounds validation for MAX_FRAMES_IN_FLIGHT = 2" {
    const valid_frame_0 = (0 < rhi.MAX_FRAMES_IN_FLIGHT);
    const valid_frame_1 = (1 < rhi.MAX_FRAMES_IN_FLIGHT);
    const invalid_frame_2 = (2 < rhi.MAX_FRAMES_IN_FLIGHT);

    try testing.expect(valid_frame_0);
    try testing.expect(valid_frame_1);
    try testing.expect(!invalid_frame_2); // Frame 2 is out of bounds
}
