const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Utils = @import("utils.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const resource_manager_pkg = @import("resource_manager.zig");
const VulkanBuffer = resource_manager_pkg.VulkanBuffer;

const shader_registry = @import("shader_registry.zig");

pub const KERNEL_SIZE = 64;
pub const NOISE_SIZE = 4;
pub const DEFAULT_RADIUS = 0.5;
pub const DEFAULT_BIAS = 0.025;

pub const SSAOParams = extern struct {
    projection: Mat4,
    invProjection: Mat4,
    samples: [KERNEL_SIZE][4]f32,
    radius: f32 = DEFAULT_RADIUS,
    bias: f32 = DEFAULT_BIAS,
    _padding: [2]f32 = undefined,
};

pub const SSAOSystem = struct {
    pipeline: c.VkPipeline = null,
    pipeline_layout: c.VkPipelineLayout = null,
    render_pass: c.VkRenderPass = null,
    framebuffer: c.VkFramebuffer = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,

    // Output image (AO)
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    handle: rhi.TextureHandle = 0,

    // Blur Pass
    blur_pipeline: c.VkPipeline = null,
    blur_pipeline_layout: c.VkPipelineLayout = null,
    blur_render_pass: c.VkRenderPass = null,
    blur_framebuffer: c.VkFramebuffer = null,
    blur_descriptor_set_layout: c.VkDescriptorSetLayout = null,
    blur_descriptor_sets: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,

    blur_image: c.VkImage = null,
    blur_memory: c.VkDeviceMemory = null,
    blur_view: c.VkImageView = null,
    blur_handle: rhi.TextureHandle = 0,

    // Resources
    noise_image: c.VkImage = null,
    noise_memory: c.VkDeviceMemory = null,
    noise_view: c.VkImageView = null,
    noise_handle: rhi.TextureHandle = 0,

    kernel_ubo: VulkanBuffer = .{},
    params: SSAOParams = undefined,
    sampler: c.VkSampler = null,

    pub fn init(self: *SSAOSystem, device: *VulkanDevice, allocator: Allocator, descriptor_pool: c.VkDescriptorPool, upload_cmd_pool: c.VkCommandPool, width: u32, height: u32, g_normal_view: c.VkImageView, g_depth_view: c.VkImageView) !void {
        const vk = device.vk_device;
        const ao_format = c.VK_FORMAT_R8_UNORM;

        // Initialize params with default values
        self.params = std.mem.zeroes(SSAOParams);
        self.params.radius = DEFAULT_RADIUS;
        self.params.bias = DEFAULT_BIAS;

        try self.initRenderPasses(vk, ao_format);
        errdefer self.deinit(vk, allocator);

        try self.initImages(device, width, height, ao_format);
        try self.initFramebuffers(vk, width, height);
        try self.initNoiseTexture(device, upload_cmd_pool);
        try self.initKernelUBO(device);
        try self.initSampler(vk);
        try self.initDescriptorLayouts(vk);
        try self.initPipelines(vk, allocator);
        try self.initDescriptorSets(vk, descriptor_pool, g_normal_view, g_depth_view);
    }

    fn initRenderPasses(self: *SSAOSystem, vk: c.VkDevice, ao_format: c.VkFormat) !void {
        var ao_attachment = std.mem.zeroes(c.VkAttachmentDescription);
        ao_attachment.format = ao_format;
        ao_attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        ao_attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        ao_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        ao_attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        ao_attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        ao_attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        ao_attachment.finalLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        var color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;

        var dependencies = [_]c.VkSubpassDependency{
            .{
                .srcSubpass = c.VK_SUBPASS_EXTERNAL,
                .dstSubpass = 0,
                .srcStageMask = c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT,
                .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
            .{
                .srcSubpass = 0,
                .dstSubpass = c.VK_SUBPASS_EXTERNAL,
                .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
            },
        };

        var rp_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        rp_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp_info.attachmentCount = 1;
        rp_info.pAttachments = &ao_attachment;
        rp_info.subpassCount = 1;
        rp_info.pSubpasses = &subpass;
        rp_info.dependencyCount = 2;
        rp_info.pDependencies = &dependencies[0];

        try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &self.render_pass));
        try Utils.checkVk(c.vkCreateRenderPass(vk, &rp_info, null, &self.blur_render_pass));
    }

    fn initImages(self: *SSAOSystem, device: *VulkanDevice, width: u32, height: u32, ao_format: c.VkFormat) !void {
        const vk = device.vk_device;
        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = width, .height = height, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = ao_format;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        // SSAO Image
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &self.image));
        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, self.image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, self.image, self.memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = ao_format;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.view));

        // Blur Image
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &self.blur_image));
        c.vkGetImageMemoryRequirements(vk, self.blur_image, &mem_reqs);
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.blur_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, self.blur_image, self.blur_memory, 0));

        view_info.image = self.blur_image;
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.blur_view));
    }

    fn initFramebuffers(self: *SSAOSystem, vk: c.VkDevice, width: u32, height: u32) !void {
        var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb_info.renderPass = self.render_pass;
        fb_info.attachmentCount = 1;
        fb_info.pAttachments = &self.view;
        fb_info.width = width;
        fb_info.height = height;
        fb_info.layers = 1;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &self.framebuffer));

        fb_info.renderPass = self.blur_render_pass;
        fb_info.pAttachments = &self.blur_view;
        try Utils.checkVk(c.vkCreateFramebuffer(vk, &fb_info, null, &self.blur_framebuffer));
    }

    pub fn generateNoiseData(rng: *std.Random.DefaultPrng) [NOISE_SIZE * NOISE_SIZE * 4]u8 {
        var noise_data: [NOISE_SIZE * NOISE_SIZE * 4]u8 = undefined;
        const random = rng.random();
        for (0..NOISE_SIZE * NOISE_SIZE) |i| {
            const x = random.float(f32) * 2.0 - 1.0;
            const y = random.float(f32) * 2.0 - 1.0;
            noise_data[i * 4 + 0] = @intFromFloat((x * 0.5 + 0.5) * 255.0);
            noise_data[i * 4 + 1] = @intFromFloat((y * 0.5 + 0.5) * 255.0);
            noise_data[i * 4 + 2] = 0;
            noise_data[i * 4 + 3] = 255;
        }
        return noise_data;
    }

    fn initNoiseTexture(self: *SSAOSystem, device: *VulkanDevice, upload_cmd_pool: c.VkCommandPool) !void {
        const vk = device.vk_device;
        var rng = std.Random.DefaultPrng.init(12345);
        const noise_data = generateNoiseData(&rng);

        var img_info = std.mem.zeroes(c.VkImageCreateInfo);
        img_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        img_info.imageType = c.VK_IMAGE_TYPE_2D;
        img_info.extent = .{ .width = NOISE_SIZE, .height = NOISE_SIZE, .depth = 1 };
        img_info.mipLevels = 1;
        img_info.arrayLayers = 1;
        img_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        img_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        img_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        img_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        img_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        img_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try Utils.checkVk(c.vkCreateImage(vk, &img_info, null, &self.noise_image));

        var mem_reqs: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(vk, self.noise_image, &mem_reqs);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = mem_reqs.size;
        alloc_info.memoryTypeIndex = try device.findMemoryType(mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try Utils.checkVk(c.vkAllocateMemory(vk, &alloc_info, null, &self.noise_memory));
        try Utils.checkVk(c.vkBindImageMemory(vk, self.noise_image, self.noise_memory, 0));

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = self.noise_image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try Utils.checkVk(c.vkCreateImageView(vk, &view_info, null, &self.noise_view));

        const staging = try Utils.createVulkanBuffer(device, NOISE_SIZE * NOISE_SIZE * 4, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        defer {
            c.vkDestroyBuffer(vk, staging.buffer, null);
            c.vkFreeMemory(vk, staging.memory, null);
        }

        if (staging.mapped_ptr) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0 .. NOISE_SIZE * NOISE_SIZE * 4], &noise_data);
        } else {
            return error.VulkanMemoryMappingFailed;
        }

        var cmd_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        cmd_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cmd_info.commandPool = upload_cmd_pool;
        cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_info.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        try Utils.checkVk(c.vkAllocateCommandBuffers(vk, &cmd_info, &cmd));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try Utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin_info));

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = self.noise_image;
        barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = NOISE_SIZE, .height = NOISE_SIZE, .depth = 1 };
        c.vkCmdCopyBufferToImage(cmd, staging.buffer, self.noise_image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

        try Utils.checkVk(c.vkEndCommandBuffer(cmd));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cmd;
        try device.submitGuarded(submit_info, null);
        _ = c.vkQueueWaitIdle(device.queue);
        c.vkFreeCommandBuffers(vk, upload_cmd_pool, 1, &cmd);
    }

    pub fn generateKernelSamples(rng: *std.Random.DefaultPrng) [KERNEL_SIZE][4]f32 {
        var samples: [KERNEL_SIZE][4]f32 = undefined;
        const random = rng.random();
        for (0..KERNEL_SIZE) |i| {
            var sample: [3]f32 = .{
                random.float(f32) * 2.0 - 1.0,
                random.float(f32) * 2.0 - 1.0,
                random.float(f32),
            };
            const len = @sqrt(sample[0] * sample[0] + sample[1] * sample[1] + sample[2] * sample[2]);
            if (len > 0.0001) {
                sample[0] /= len;
                sample[1] /= len;
                sample[2] /= len;
            }

            var scale: f32 = @as(f32, @floatFromInt(i)) / KERNEL_SIZE;
            scale = 0.1 + scale * scale * 0.9;
            sample[0] *= scale;
            sample[1] *= scale;
            sample[2] *= scale;

            samples[i] = .{ sample[0], sample[1], sample[2], 0.0 };
        }
        return samples;
    }

    fn initKernelUBO(self: *SSAOSystem, device: *const VulkanDevice) !void {
        self.kernel_ubo = try Utils.createVulkanBuffer(device, @sizeOf(SSAOParams), c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        var rng = std.Random.DefaultPrng.init(67890);
        self.params.samples = generateKernelSamples(&rng);
        self.params.radius = DEFAULT_RADIUS;
        self.params.bias = DEFAULT_BIAS;
    }

    fn initSampler(self: *SSAOSystem, vk: c.VkDevice) !void {
        var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
        sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        sampler_info.magFilter = c.VK_FILTER_NEAREST;
        sampler_info.minFilter = c.VK_FILTER_NEAREST;
        sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler_info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        sampler_info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        try Utils.checkVk(c.vkCreateSampler(vk, &sampler_info, null, &self.sampler));
    }

    fn initDescriptorLayouts(self: *SSAOSystem, vk: c.VkDevice) !void {
        var bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 4;
        layout_info.pBindings = &bindings[0];
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        var blur_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        layout_info.bindingCount = 1;
        layout_info.pBindings = &blur_bindings[0];
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.blur_descriptor_set_layout));
    }

    fn initPipelines(self: *SSAOSystem, vk: c.VkDevice, allocator: Allocator) !void {
        var layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layout_info.setLayoutCount = 1;
        layout_info.pSetLayouts = &self.descriptor_set_layout;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &layout_info, null, &self.pipeline_layout));

        layout_info.pSetLayouts = &self.blur_descriptor_set_layout;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &layout_info, null, &self.blur_pipeline_layout));

        const vert_code = try std.fs.cwd().readFileAlloc(shader_registry.SSAO_VERT, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(vert_code);
        const frag_code = try std.fs.cwd().readFileAlloc(shader_registry.SSAO_FRAG, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(frag_code);
        const blur_frag_code = try std.fs.cwd().readFileAlloc(shader_registry.SSAO_BLUR_FRAG, allocator, @enumFromInt(1024 * 1024));
        defer allocator.free(blur_frag_code);

        const vert_module = try Utils.createShaderModule(vk, vert_code);
        defer c.vkDestroyShaderModule(vk, vert_module, null);
        const frag_module = try Utils.createShaderModule(vk, frag_code);
        defer c.vkDestroyShaderModule(vk, frag_module, null);
        const blur_frag_module = try Utils.createShaderModule(vk, blur_frag_code);
        defer c.vkDestroyShaderModule(vk, blur_frag_module, null);

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };

        var vi_info = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vi_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        var ia_info = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        ia_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia_info.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        var vp_info = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        vp_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp_info.viewportCount = 1;
        vp_info.scissorCount = 1;
        var rs_info = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        rs_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs_info.polygonMode = c.VK_POLYGON_MODE_FILL;
        rs_info.lineWidth = 1.0;
        rs_info.cullMode = c.VK_CULL_MODE_NONE;
        var ms_info = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        ms_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms_info.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var ds_info = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        ds_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds_info.depthTestEnable = c.VK_FALSE;
        ds_info.depthWriteEnable = c.VK_FALSE;
        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT;
        var cb_info = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        cb_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb_info.attachmentCount = 1;
        cb_info.pAttachments = &blend_attachment;
        var dyn_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dyn_info = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dyn_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dyn_info.dynamicStateCount = 2;
        dyn_info.pDynamicStates = &dyn_states[0];

        var pipe_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipe_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipe_info.stageCount = 2;
        pipe_info.pStages = &stages[0];
        pipe_info.pVertexInputState = &vi_info;
        pipe_info.pInputAssemblyState = &ia_info;
        pipe_info.pViewportState = &vp_info;
        pipe_info.pRasterizationState = &rs_info;
        pipe_info.pMultisampleState = &ms_info;
        pipe_info.pDepthStencilState = &ds_info;
        pipe_info.pColorBlendState = &cb_info;
        pipe_info.pDynamicState = &dyn_info;
        pipe_info.layout = self.pipeline_layout;
        pipe_info.renderPass = self.render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.pipeline));

        stages[1].module = blur_frag_module;
        pipe_info.layout = self.blur_pipeline_layout;
        pipe_info.renderPass = self.blur_render_pass;
        try Utils.checkVk(c.vkCreateGraphicsPipelines(vk, null, 1, &pipe_info, null, &self.blur_pipeline));
    }

    fn initDescriptorSets(self: *SSAOSystem, vk: c.VkDevice, descriptor_pool: c.VkDescriptorPool, g_normal_view: c.VkImageView, g_depth_view: c.VkImageView) !void {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            var ds_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
            ds_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
            ds_alloc.descriptorPool = descriptor_pool;
            ds_alloc.descriptorSetCount = 1;
            ds_alloc.pSetLayouts = &self.descriptor_set_layout;
            try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &ds_alloc, &self.descriptor_sets[i]));

            ds_alloc.pSetLayouts = &self.blur_descriptor_set_layout;
            try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &ds_alloc, &self.blur_descriptor_sets[i]));

            var depth_info = c.VkDescriptorImageInfo{ .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .imageView = g_depth_view, .sampler = self.sampler };
            var norm_info = c.VkDescriptorImageInfo{ .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .imageView = g_normal_view, .sampler = self.sampler };
            var noise_info = c.VkDescriptorImageInfo{ .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .imageView = self.noise_view, .sampler = self.sampler };
            var buffer_info_ds = c.VkDescriptorBufferInfo{ .buffer = self.kernel_ubo.buffer, .offset = 0, .range = @sizeOf(SSAOParams) };

            var writes = [_]c.VkWriteDescriptorSet{
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &depth_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &norm_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &noise_info },
                .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.descriptor_sets[i], .dstBinding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .pBufferInfo = &buffer_info_ds },
            };
            c.vkUpdateDescriptorSets(vk, 4, &writes[0], 0, null);

            var ssao_info = c.VkDescriptorImageInfo{ .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, .imageView = self.view, .sampler = self.sampler };
            var blur_write = c.VkWriteDescriptorSet{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.blur_descriptor_sets[i], .dstBinding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .pImageInfo = &ssao_info };
            c.vkUpdateDescriptorSets(vk, 1, &blur_write, 0, null);
        }
    }

    pub fn deinit(self: *SSAOSystem, vk: c.VkDevice, allocator: Allocator) void {
        _ = allocator;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.blur_pipeline != null) c.vkDestroyPipeline(vk, self.blur_pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.blur_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.blur_pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.blur_descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.blur_descriptor_set_layout, null);
        if (self.framebuffer != null) c.vkDestroyFramebuffer(vk, self.framebuffer, null);
        if (self.blur_framebuffer != null) c.vkDestroyFramebuffer(vk, self.blur_framebuffer, null);
        if (self.render_pass != null) c.vkDestroyRenderPass(vk, self.render_pass, null);
        if (self.blur_render_pass != null) c.vkDestroyRenderPass(vk, self.blur_render_pass, null);
        if (self.view != null) c.vkDestroyImageView(vk, self.view, null);
        if (self.image != null) c.vkDestroyImage(vk, self.image, null);
        if (self.memory != null) c.vkFreeMemory(vk, self.memory, null);
        if (self.blur_view != null) c.vkDestroyImageView(vk, self.blur_view, null);
        if (self.blur_image != null) c.vkDestroyImage(vk, self.blur_image, null);
        if (self.blur_memory != null) c.vkFreeMemory(vk, self.blur_memory, null);
        if (self.noise_view != null) c.vkDestroyImageView(vk, self.noise_view, null);
        if (self.noise_image != null) c.vkDestroyImage(vk, self.noise_image, null);
        if (self.noise_memory != null) c.vkFreeMemory(vk, self.noise_memory, null);
        if (self.kernel_ubo.buffer != null) c.vkDestroyBuffer(vk, self.kernel_ubo.buffer, null);
        if (self.kernel_ubo.memory != null) c.vkFreeMemory(vk, self.kernel_ubo.memory, null);
        if (self.sampler != null) c.vkDestroySampler(vk, self.sampler, null);
        self.* = std.mem.zeroes(SSAOSystem);
    }

    pub fn compute(self: *SSAOSystem, vk: c.VkDevice, cmd: c.VkCommandBuffer, frame_index: usize, extent: c.VkExtent2D, proj: Mat4, inv_proj: Mat4) void {
        _ = vk;
        self.params.projection = proj;
        self.params.invProjection = inv_proj;
        if (self.kernel_ubo.mapped_ptr) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(SSAOParams)], std.mem.asBytes(&self.params));
        }

        // SSAO Pass
        {
            var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
            render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            render_pass_info.renderPass = self.render_pass;
            render_pass_info.framebuffer = self.framebuffer;
            render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
            render_pass_info.renderArea.extent = extent;
            var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
            render_pass_info.clearValueCount = 1;
            render_pass_info.pClearValues = &clear_value;
            c.vkCmdBeginRenderPass(cmd, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
            const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .minDepth = 0, .maxDepth = 1 };
            c.vkCmdSetViewport(cmd, 0, 1, &viewport);
            const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
            c.vkCmdSetScissor(cmd, 0, 1, &scissor);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &self.descriptor_sets[frame_index], 0, null);
            c.vkCmdDraw(cmd, 3, 1, 0, 0);
            c.vkCmdEndRenderPass(cmd);
        }

        // Blur Pass
        {
            var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
            render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            render_pass_info.renderPass = self.blur_render_pass;
            render_pass_info.framebuffer = self.blur_framebuffer;
            render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
            render_pass_info.renderArea.extent = extent;
            var clear_value = c.VkClearValue{ .color = .{ .float32 = .{ 1, 1, 1, 1 } } };
            render_pass_info.clearValueCount = 1;
            render_pass_info.pClearValues = &clear_value;
            c.vkCmdBeginRenderPass(cmd, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.blur_pipeline);
            const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .minDepth = 0, .maxDepth = 1 };
            c.vkCmdSetViewport(cmd, 0, 1, &viewport);
            const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
            c.vkCmdSetScissor(cmd, 0, 1, &scissor);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.blur_pipeline_layout, 0, 1, &self.blur_descriptor_sets[frame_index], 0, null);
            c.vkCmdDraw(cmd, 3, 1, 0, 0);
            c.vkCmdEndRenderPass(cmd);
        }
    }
};

test "SSAOSystem noise generation" {
    var rng = std.Random.DefaultPrng.init(12345);
    const data1 = SSAOSystem.generateNoiseData(&rng);
    rng = std.Random.DefaultPrng.init(12345);
    const data2 = SSAOSystem.generateNoiseData(&rng);

    try std.testing.expectEqual(data1, data2);

    // Verify some properties
    for (0..NOISE_SIZE * NOISE_SIZE) |i| {
        // Red and Green should be random but in 0-255 range (always true for u8)
        // Blue should be 0
        try std.testing.expectEqual(@as(u8, 0), data1[i * 4 + 2]);
        // Alpha should be 255
        try std.testing.expectEqual(@as(u8, 255), data1[i * 4 + 3]);
    }
}

test "SSAOSystem kernel generation" {
    var rng = std.Random.DefaultPrng.init(67890);
    const samples1 = SSAOSystem.generateKernelSamples(&rng);
    rng = std.Random.DefaultPrng.init(67890);
    const samples2 = SSAOSystem.generateKernelSamples(&rng);

    for (0..KERNEL_SIZE) |i| {
        try std.testing.expectEqual(samples1[i][0], samples2[i][0]);
        try std.testing.expectEqual(samples1[i][1], samples2[i][1]);
        try std.testing.expectEqual(samples1[i][2], samples2[i][2]);
        try std.testing.expectEqual(samples1[i][3], samples2[i][3]);

        // Hemisphere check: z must be >= 0
        try std.testing.expect(samples1[i][2] >= 0.0);
        // Length check: should be <= 1.0 (scaled by falloff)
        const len = @sqrt(samples1[i][0] * samples1[i][0] + samples1[i][1] * samples1[i][1] + samples1[i][2] * samples1[i][2]);
        try std.testing.expect(len <= 1.0);
    }
}
