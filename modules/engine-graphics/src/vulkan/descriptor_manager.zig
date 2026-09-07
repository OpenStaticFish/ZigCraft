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
        // Increased sizes to accommodate UI texture descriptor sets (128) + FXAA (2) + Bloom (20) + main (4)
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 500 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 32 },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes[0];
        pool_info.maxSets = 1000;
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
