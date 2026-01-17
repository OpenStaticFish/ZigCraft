//! Vulkan Logical Device and Queue Management
//!
//! This module handles:
//! - Physical device selection and feature discovery
//! - Logical device creation with robustness extensions
//! - Guarded command submission with device loss detection
//! - Device fault reporting via VK_EXT_device_fault
//!
//! ## Robustness Layer
//! The engine enables `VK_EXT_robustness2` to prevent GPU hangs from out-of-bounds
//! buffer or image accesses. Shader accesses are clamped or return zero instead
//! of triggering a TDR or system freeze.
//!
//! ## Thread Safety
//! `VulkanDevice` uses an internal mutex for `submitGuarded` to ensure queue
//! submissions are synchronized. However, most RHI operations are still restricted
//! to the main thread by engine convention.

const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");

pub const VulkanDevice = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    vk_device: c.VkDevice = null,
    queue: c.VkQueue = null,
    graphics_family: u32 = 0,
    supports_device_fault: bool = false,
    mutex: std.Thread.Mutex = .{},

    // Extension function pointers
    vkGetDeviceFaultInfoEXT: ?*const fn (
        device: c.VkDevice,
        pFaultInfo: *c.VkDeviceFaultInfoEXT,
    ) callconv(.c) c.VkResult = null,

    fault_count: u32 = 0,

    // Limits and capabilities
    max_anisotropy: f32 = 0.0,
    max_msaa_samples: u8 = 1,
    multi_draw_indirect: bool = false,
    draw_indirect_first_instance: bool = false,

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window) !VulkanDevice {
        var self = VulkanDevice{ .allocator = allocator };

        // 1. Create Instance
        var count: u32 = 0;
        const extensions_ptr = c.SDL_Vulkan_GetInstanceExtensions(&count);
        if (extensions_ptr == null) return error.VulkanExtensionsFailed;

        const props2_name: [*:0]const u8 = @ptrCast(c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
        const props2_name_slice = std.mem.span(props2_name);

        var instance_ext_count: u32 = 0;
        _ = c.vkEnumerateInstanceExtensionProperties(null, &instance_ext_count, null);
        const instance_ext_props = try allocator.alloc(c.VkExtensionProperties, instance_ext_count);
        defer allocator.free(instance_ext_props);
        _ = c.vkEnumerateInstanceExtensionProperties(null, &instance_ext_count, instance_ext_props.ptr);

        var props2_supported = false;
        for (instance_ext_props) |prop| {
            const name: [*:0]const u8 = @ptrCast(&prop.extensionName);
            if (std.mem.eql(u8, std.mem.span(name), props2_name_slice)) {
                props2_supported = true;
                break;
            }
        }

        const sdl_extension_count: usize = @intCast(count);
        const sdl_extensions = extensions_ptr[0..sdl_extension_count];
        var props2_in_sdl = false;
        for (sdl_extensions) |ext| {
            if (std.mem.eql(u8, std.mem.span(ext), props2_name_slice)) {
                props2_in_sdl = true;
                break;
            }
        }

        const enable_props2 = props2_supported and !props2_in_sdl;
        const instance_extension_count: usize = sdl_extension_count + @intFromBool(enable_props2);
        const instance_extensions = try allocator.alloc([*c]const u8, instance_extension_count);
        defer allocator.free(instance_extensions);
        for (sdl_extensions, 0..) |ext, i| instance_extensions[i] = ext;
        if (enable_props2) {
            instance_extensions[sdl_extension_count] = c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME;
        }

        const props2_enabled = props2_supported and (props2_in_sdl or enable_props2);
        if (props2_supported and enable_props2) {
            std.log.info("Enabling VK_KHR_get_physical_device_properties2", .{});
        } else if (!props2_supported) {
            std.log.warn("VK_KHR_get_physical_device_properties2 not supported by instance", .{});
        }

        var app_info = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "ZigCraft";
        app_info.apiVersion = c.VK_API_VERSION_1_0;

        const enable_validation = std.debug.runtime_safety;
        const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};

        var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = @intCast(instance_extensions.len);
        create_info.ppEnabledExtensionNames = instance_extensions.ptr;

        if (enable_validation) {
            var layer_count: u32 = 0;
            _ = c.vkEnumerateInstanceLayerProperties(&layer_count, null);
            if (layer_count > 0) {
                const layer_props = allocator.alloc(c.VkLayerProperties, layer_count) catch null;
                if (layer_props) |props| {
                    defer allocator.free(props);
                    _ = c.vkEnumerateInstanceLayerProperties(&layer_count, props.ptr);
                    var found = false;
                    for (props) |layer| {
                        const layer_name: [*:0]const u8 = @ptrCast(&layer.layerName);
                        if (std.mem.eql(u8, std.mem.span(layer_name), "VK_LAYER_KHRONOS_validation")) {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        create_info.enabledLayerCount = 1;
                        create_info.ppEnabledLayerNames = &validation_layers;
                        std.log.info("Vulkan validation layers enabled", .{});
                    }
                }
            }
        }
        try checkVk(c.vkCreateInstance(&create_info, null, &self.instance));

        // 2. Create Surface
        if (!c.SDL_Vulkan_CreateSurface(window, self.instance, null, &self.surface)) return error.VulkanSurfaceFailed;

        // 3. Pick Physical Device
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;
        const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
        defer allocator.free(devices);
        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr);
        self.physical_device = devices[0];

        // 4. Create Logical Device
        var supported_features: c.VkPhysicalDeviceFeatures = undefined;
        c.vkGetPhysicalDeviceFeatures(self.physical_device, &supported_features);

        var device_properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(self.physical_device, &device_properties);
        self.max_anisotropy = device_properties.limits.maxSamplerAnisotropy;

        const color_samples = device_properties.limits.framebufferColorSampleCounts;
        const depth_samples = device_properties.limits.framebufferDepthSampleCounts;
        const sample_counts = color_samples & depth_samples;
        if ((sample_counts & c.VK_SAMPLE_COUNT_8_BIT) != 0) {
            self.max_msaa_samples = 8;
        } else if ((sample_counts & c.VK_SAMPLE_COUNT_4_BIT) != 0) {
            self.max_msaa_samples = 4;
        } else if ((sample_counts & c.VK_SAMPLE_COUNT_2_BIT) != 0) {
            self.max_msaa_samples = 2;
        } else {
            self.max_msaa_samples = 1;
        }

        var device_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
        if (supported_features.fillModeNonSolid == c.VK_TRUE) device_features.fillModeNonSolid = c.VK_TRUE;
        if (supported_features.samplerAnisotropy == c.VK_TRUE) device_features.samplerAnisotropy = c.VK_TRUE;
        if (supported_features.multiDrawIndirect == c.VK_TRUE) device_features.multiDrawIndirect = c.VK_TRUE;
        if (supported_features.drawIndirectFirstInstance == c.VK_TRUE) device_features.drawIndirectFirstInstance = c.VK_TRUE;
        if (supported_features.robustBufferAccess == c.VK_TRUE) device_features.robustBufferAccess = c.VK_TRUE;
        self.multi_draw_indirect = supported_features.multiDrawIndirect == c.VK_TRUE;
        self.draw_indirect_first_instance = supported_features.drawIndirectFirstInstance == c.VK_TRUE;

        var queue_family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physical_device, &queue_family_count, null);
        const queue_families = try allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physical_device, &queue_family_count, queue_families.ptr);

        var graphics_family: ?u32 = null;
        for (queue_families, 0..) |qf, i| {
            if ((qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
                graphics_family = @intCast(i);
                break;
            }
        }
        if (graphics_family == null) return error.NoGraphicsQueue;
        self.graphics_family = graphics_family.?;

        const queue_priority: f32 = 1.0;
        var queue_create_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_create_info.queueFamilyIndex = self.graphics_family;
        queue_create_info.queueCount = 1;
        queue_create_info.pQueuePriorities = &queue_priority;

        var ext_count: u32 = 0;
        _ = c.vkEnumerateDeviceExtensionProperties(self.physical_device, null, &ext_count, null);
        const ext_props = try allocator.alloc(c.VkExtensionProperties, ext_count);
        defer allocator.free(ext_props);
        _ = c.vkEnumerateDeviceExtensionProperties(self.physical_device, null, &ext_count, ext_props.ptr);

        const robustness2_name: [*:0]const u8 = @ptrCast(c.VK_EXT_ROBUSTNESS_2_EXTENSION_NAME);
        const device_fault_name: [*:0]const u8 = @ptrCast(c.VK_EXT_DEVICE_FAULT_EXTENSION_NAME);
        const robustness2_name_slice = std.mem.span(robustness2_name);
        const device_fault_name_slice = std.mem.span(device_fault_name);

        var supports_robustness2 = false;
        var supports_device_fault = false;
        for (ext_props) |prop| {
            const name: [*:0]const u8 = @ptrCast(&prop.extensionName);
            const name_slice = std.mem.span(name);
            if (std.mem.eql(u8, name_slice, robustness2_name_slice)) supports_robustness2 = true;
            if (std.mem.eql(u8, name_slice, device_fault_name_slice)) supports_device_fault = true;
        }

        if (supports_robustness2) std.log.info("VK_EXT_robustness2 supported", .{});
        if (supports_device_fault) std.log.info("VK_EXT_device_fault supported", .{});
        self.supports_device_fault = supports_device_fault;

        const allow_robustness2 = supports_robustness2 and props2_enabled;
        const allow_device_fault = supports_device_fault and props2_enabled;
        if (!props2_enabled and (supports_robustness2 or supports_device_fault)) {
            std.log.warn("VK_KHR_get_physical_device_properties2 not enabled; skipping robustness/device fault", .{});
        }

        var robustness2_features = std.mem.zeroes(c.VkPhysicalDeviceRobustness2FeaturesEXT);
        robustness2_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT;
        if (allow_robustness2) {
            robustness2_features.robustBufferAccess2 = c.VK_TRUE;
            robustness2_features.robustImageAccess2 = c.VK_TRUE;
            robustness2_features.nullDescriptor = c.VK_TRUE;
        }

        var fault_features = std.mem.zeroes(c.VkPhysicalDeviceFaultFeaturesEXT);
        fault_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT;
        if (allow_device_fault) {
            fault_features.deviceFault = c.VK_TRUE;
            fault_features.deviceFaultVendorBinary = c.VK_FALSE;
        }

        if (allow_robustness2) {
            robustness2_features.pNext = if (allow_device_fault) @ptrCast(&fault_features) else null;
        }

        var enabled_extensions: [3][*c]const u8 = undefined;
        var enabled_extension_count: u32 = 0;
        enabled_extensions[enabled_extension_count] = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
        enabled_extension_count += 1;
        if (allow_robustness2) {
            enabled_extensions[enabled_extension_count] = c.VK_EXT_ROBUSTNESS_2_EXTENSION_NAME;
            enabled_extension_count += 1;
        }
        if (allow_device_fault) {
            enabled_extensions[enabled_extension_count] = c.VK_EXT_DEVICE_FAULT_EXTENSION_NAME;
            enabled_extension_count += 1;
        }

        var device_create_info = std.mem.zeroes(c.VkDeviceCreateInfo);
        device_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_create_info.queueCreateInfoCount = 1;
        device_create_info.pQueueCreateInfos = &queue_create_info;
        device_create_info.pEnabledFeatures = &device_features;
        if (allow_robustness2) {
            device_create_info.pNext = @ptrCast(&robustness2_features);
        } else if (allow_device_fault) {
            device_create_info.pNext = @ptrCast(&fault_features);
        }
        device_create_info.enabledExtensionCount = enabled_extension_count;
        device_create_info.ppEnabledExtensionNames = &enabled_extensions;

        var create_result = c.vkCreateDevice(self.physical_device, &device_create_info, null, &self.vk_device);
        if ((allow_robustness2 or allow_device_fault) and
            (create_result == c.VK_ERROR_FEATURE_NOT_PRESENT or create_result == c.VK_ERROR_EXTENSION_NOT_PRESENT))
        {
            std.log.warn("Robustness/device fault features not available, falling back to basic device", .{});
            device_create_info.pNext = null;
            enabled_extensions[0] = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
            enabled_extension_count = 1;
            device_create_info.enabledExtensionCount = enabled_extension_count;
            device_create_info.ppEnabledExtensionNames = &enabled_extensions;
            create_result = c.vkCreateDevice(self.physical_device, &device_create_info, null, &self.vk_device);
        }

        try checkVk(create_result);
        c.vkGetDeviceQueue(self.vk_device, self.graphics_family, 0, &self.queue);

        if (self.supports_device_fault) {
            const proc = c.vkGetDeviceProcAddr(self.vk_device, "vkGetDeviceFaultInfoEXT");
            if (proc != null) {
                self.vkGetDeviceFaultInfoEXT = @ptrCast(proc);
            } else {
                self.supports_device_fault = false;
            }
        }

        return self;
    }

    pub fn deinit(self: *VulkanDevice) void {
        c.vkDestroyDevice(self.vk_device, null);
        c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        c.vkDestroyInstance(self.instance, null);
    }

    pub fn findMemoryType(self: VulkanDevice, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

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

    /// Submits command buffers to the graphics queue with device loss protection.
    /// Thread-safe via internal mutex.
    pub fn submitGuarded(self: *VulkanDevice, submit_info: c.VkSubmitInfo, fence: c.VkFence) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = c.vkQueueSubmit(self.queue, 1, &submit_info, fence);

        if (result == c.VK_ERROR_DEVICE_LOST) {
            self.fault_count += 1;
            std.log.err("GPU reset triggered voluntarily (VK_ERROR_DEVICE_LOST). Total faults: {d}", .{self.fault_count});
            self.logDeviceFaults();
            return error.GpuLost;
        }

        try checkVk(result);
    }

    /// Logs detailed fault information if VK_EXT_device_fault is enabled and supported.
    pub fn logDeviceFaults(self: VulkanDevice) void {
        const func = self.vkGetDeviceFaultInfoEXT orelse {
            std.log.warn("VK_EXT_device_fault not available; review system logs (dmesg) for GPU errors.", .{});
            return;
        };

        std.log.info("Querying VK_EXT_device_fault for detailed hang info...", .{});

        var fault_info = std.mem.zeroes(c.VkDeviceFaultInfoEXT);
        fault_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT;

        const result = func(self.vk_device, &fault_info);
        if (result == c.VK_SUCCESS) {
            const desc: [*:0]const u8 = @ptrCast(&fault_info.description);
            std.log.err("GPU Fault Detected: {s}", .{desc});
        } else {
            std.log.warn("Failed to retrieve device fault info: {d}", .{result});
        }
        std.log.warn("Review system logs (dmesg/journalctl) for kernel-level GPU driver errors.", .{});
    }
};

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

test "VulkanDevice.submitGuarded initialization state" {
    const testing = @import("std").testing;

    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expectEqual(@as(u32, 0), device.fault_count);
    try testing.expect(!device.supports_device_fault);
}

test "VulkanDevice checkVk mapping" {
    const testing = @import("std").testing;

    try testing.expectError(error.GpuLost, checkVk(c.VK_ERROR_DEVICE_LOST));
    try testing.expectError(error.OutOfMemory, checkVk(c.VK_ERROR_OUT_OF_HOST_MEMORY));
    try testing.expectError(error.OutOfMemory, checkVk(c.VK_ERROR_OUT_OF_DEVICE_MEMORY));
    try testing.expectError(error.SurfaceLost, checkVk(c.VK_ERROR_SURFACE_LOST_KHR));
    try testing.expectError(error.InitializationFailed, checkVk(c.VK_ERROR_INITIALIZATION_FAILED));
    try testing.expectError(error.ExtensionNotPresent, checkVk(c.VK_ERROR_EXTENSION_NOT_PRESENT));
    try testing.expectError(error.FeatureNotPresent, checkVk(c.VK_ERROR_FEATURE_NOT_PRESENT));
    try testing.expectError(error.TooManyObjects, checkVk(c.VK_ERROR_TOO_MANY_OBJECTS));
    try testing.expectError(error.FormatNotSupported, checkVk(c.VK_ERROR_FORMAT_NOT_SUPPORTED));
    try testing.expectError(error.FragmentedPool, checkVk(c.VK_ERROR_FRAGMENTED_POOL));
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_UNKNOWN));
    try checkVk(c.VK_SUCCESS);
}
