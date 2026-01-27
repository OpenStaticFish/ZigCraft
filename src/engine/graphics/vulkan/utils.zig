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
    mapped_ptr: ?*anyopaque = null,
};

pub fn checkVk(result: c.VkResult) !void {
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

pub fn findMemoryType(physical_device: c.VkPhysicalDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) rhi.RhiError!u32 {
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

pub fn createVulkanBuffer(device: *const VulkanDevice, size: usize, usage: c.VkBufferUsageFlags, properties: c.VkMemoryPropertyFlags) rhi.RhiError!VulkanBuffer {
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

    const is_host_visible = (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0;
    var mapped_ptr: ?*anyopaque = null;
    if (is_host_visible) {
        try checkVk(c.vkMapMemory(device.vk_device, memory, 0, mem_reqs.size, 0, &mapped_ptr));
    }

    return .{
        .buffer = buffer,
        .memory = memory,
        .size = mem_reqs.size,
        .is_host_visible = is_host_visible,
        .mapped_ptr = mapped_ptr,
    };
}

pub fn createSampler(device: *const VulkanDevice, config: rhi.TextureConfig, mip_levels: u32, max_anisotropy: f32) !c.VkSampler {
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
    try checkVk(c.vkCreateSampler(device.vk_device, &sampler_info, null, &sampler));
    return sampler;
}

pub fn createShaderModule(device: c.VkDevice, code: []const u8) !c.VkShaderModule {
    var create_info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    create_info.codeSize = code.len;
    create_info.pCode = @ptrCast(@alignCast(code.ptr));

    var shader_module: c.VkShaderModule = null;
    try checkVk(c.vkCreateShaderModule(device, &create_info, null, &shader_module));
    return shader_module;
}

pub fn createImage(device: c.VkDevice, physical_device: c.VkPhysicalDevice, width: u32, height: u32, format: c.VkFormat, tiling: c.VkImageTiling, usage: c.VkImageUsageFlags, properties: c.VkMemoryPropertyFlags, image: *c.VkImage, image_memory: *c.VkDeviceMemory) !void {
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = format;
    image_info.tiling = tiling;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = usage;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    try checkVk(c.vkCreateImage(device, &image_info, null, image));

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device, image.*, &mem_requirements);

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = try findMemoryType(physical_device, mem_requirements.memoryTypeBits, properties);

    try checkVk(c.vkAllocateMemory(device, &alloc_info, null, image_memory));
    try checkVk(c.vkBindImageMemory(device, image.*, image_memory.*, 0));
}

pub fn createImageView(device: c.VkDevice, image: c.VkImage, format: c.VkFormat, aspect_flags: c.VkImageAspectFlags) !c.VkImageView {
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = format;
    view_info.subresourceRange.aspectMask = aspect_flags;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    var image_view: c.VkImageView = null;
    try checkVk(c.vkCreateImageView(device, &view_info, null, &image_view));
    return image_view;
}

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(1024 * 1024));
}

pub fn pipelineShaderStageCreateInfo(stage: c.VkShaderStageFlagBits, module: c.VkShaderModule, name: [*c]const u8) c.VkPipelineShaderStageCreateInfo {
    var create_info = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    create_info.stage = stage;
    create_info.module = module;
    create_info.pName = name;
    return create_info;
}
