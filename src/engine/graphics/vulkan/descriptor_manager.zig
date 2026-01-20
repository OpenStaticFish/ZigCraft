const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const rhi_types = @import("../rhi_types.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const ResourceManager = @import("resource_manager.zig").ResourceManager;
const VulkanBuffer = @import("resource_manager.zig").VulkanBuffer;
const Mat4 = @import("../../math/mat4.zig").Mat4;
const Utils = @import("utils.zig");

const GlobalUniforms = extern struct {
    view_proj: Mat4,
    cam_pos: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    fog_color: [4]f32,
    cloud_wind_offset: [4]f32,
    params: [4]f32,
    lighting: [4]f32,
    cloud_params: [4]f32,
    pbr_params: [4]f32,
    volumetric_params: [4]f32,
    viewport_size: [4]f32,
};

const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32,
    shadow_texel_sizes: [4]f32,
};

pub const DescriptorManager = struct {
    allocator: std.mem.Allocator,
    vulkan_device: *const VulkanDevice,
    resource_manager: *ResourceManager,

    descriptor_pool: c.VkDescriptorPool,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    lod_descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,

    global_ubos: [rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    global_ubos_mapped: [rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    shadow_ubos: [rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer,
    shadow_ubos_mapped: [rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque,

    // Dummy textures
    dummy_texture: rhi.TextureHandle,
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
            .lod_descriptor_sets = undefined,
            .global_ubos = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer),
            .global_ubos_mapped = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque),
            .shadow_ubos = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]VulkanBuffer),
            .shadow_ubos_mapped = std.mem.zeroes([rhi.MAX_FRAMES_IN_FLIGHT]?*anyopaque),
            .dummy_texture = 0,
            .dummy_normal_texture = 0,
            .dummy_roughness_texture = 0,
        };
        errdefer self.deinit();

        // Create UBOs
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            self.global_ubos[i] = try Utils.createVulkanBuffer(vulkan_device, @sizeOf(GlobalUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            try Utils.checkVk(c.vkMapMemory(vulkan_device.vk_device, self.global_ubos[i].memory, 0, @sizeOf(GlobalUniforms), 0, &self.global_ubos_mapped[i]));

            self.shadow_ubos[i] = try Utils.createVulkanBuffer(vulkan_device, @sizeOf(ShadowUniforms), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            try Utils.checkVk(c.vkMapMemory(vulkan_device.vk_device, self.shadow_ubos[i].memory, 0, @sizeOf(ShadowUniforms), 0, &self.shadow_ubos_mapped[i]));
        }

        // Create dummy textures at frame index 1 to isolate from frame 0's lifecycle.
        resource_manager.setCurrentFrame(1);

        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        self.dummy_texture = try resource_manager.createTexture(1, 1, .rgba, .{}, &white_pixel);

        const normal_neutral = [_]u8{ 128, 128, 255, 0 };
        self.dummy_normal_texture = try resource_manager.createTexture(1, 1, .rgba, .{}, &normal_neutral);

        const roughness_neutral = [_]u8{ 255, 0, 0, 255 };
        self.dummy_roughness_texture = try resource_manager.createTexture(1, 1, .rgba, .{}, &roughness_neutral);

        try resource_manager.flushTransfer();

        // Create Descriptor Pool
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 100 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 100 },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes[0];
        pool_info.maxSets = 100;
        pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;

        try Utils.checkVk(c.vkCreateDescriptorPool(vulkan_device.vk_device, &pool_info, null, &self.descriptor_pool));

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
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings[0];

        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vulkan_device.vk_device, &layout_info, null, &self.descriptor_set_layout));

        // Allocate Descriptor Sets
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            alloc_info.descriptorPool = self.descriptor_pool;
            alloc_info.descriptorSetCount = 1;
            alloc_info.pSetLayouts = &self.descriptor_set_layout;

            try Utils.checkVk(c.vkAllocateDescriptorSets(vulkan_device.vk_device, &alloc_info, &self.descriptor_sets[i]));
            try Utils.checkVk(c.vkAllocateDescriptorSets(vulkan_device.vk_device, &alloc_info, &self.lod_descriptor_sets[i]));

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
                    .dstSet = self.lod_descriptor_sets[i],
                    .dstBinding = 0,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .descriptorCount = 1,
                    .pBufferInfo = &buffer_info_global,
                },
                .{
                    .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .dstSet = self.lod_descriptor_sets[i],
                    .dstBinding = 2,
                    .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    .descriptorCount = 1,
                    .pBufferInfo = &buffer_info_shadow,
                },
            };
            c.vkUpdateDescriptorSets(vulkan_device.vk_device, writes.len, &writes[0], 0, null);
        }

        return self;
    }

    pub fn deinit(self: *DescriptorManager) void {
        const device = self.vulkan_device.vk_device;

        // Unmap and destroy UBOs
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.global_ubos_mapped[i] != null) c.vkUnmapMemory(device, self.global_ubos[i].memory);
            c.vkDestroyBuffer(device, self.global_ubos[i].buffer, null);
            c.vkFreeMemory(device, self.global_ubos[i].memory, null);

            if (self.shadow_ubos_mapped[i] != null) c.vkUnmapMemory(device, self.shadow_ubos[i].memory);
            c.vkDestroyBuffer(device, self.shadow_ubos[i].buffer, null);
            c.vkFreeMemory(device, self.shadow_ubos[i].memory, null);
        }

        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(device, self.descriptor_pool, null);
    }

    pub fn updateGlobalUniforms(self: *DescriptorManager, frame_index: usize, data: *const anyopaque) void {
        const dest = self.global_ubos_mapped[frame_index] orelse return;
        const src = @as([*]const u8, @ptrCast(data));
        @memcpy(@as([*]u8, @ptrCast(dest))[0..@sizeOf(GlobalUniforms)], src[0..@sizeOf(GlobalUniforms)]);
    }

    pub fn updateShadowUniforms(self: *DescriptorManager, frame_index: usize, data: *const anyopaque) void {
        const dest = self.shadow_ubos_mapped[frame_index] orelse return;
        const src = @as([*]const u8, @ptrCast(data));
        @memcpy(@as([*]u8, @ptrCast(dest))[0..@sizeOf(ShadowUniforms)], src[0..@sizeOf(ShadowUniforms)]);
    }

    // Additional methods for binding textures would go here
    // For now, we assume VulkanContext handles the complexity of gathering textures and calling a mass update
};
