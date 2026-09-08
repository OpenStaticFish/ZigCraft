//! Vulkan Logical Device and Queue Management
//!
//! This module handles:
//! - Physical device selection and feature discovery
//! - Logical device creation with robustness extensions
//! - Guarded command submission with device loss detection
//! - Device fault reporting via VK_EXT_device_fault
//!
//! ## Robustness Layer
//! Supported robustness features constrain shader memory accesses. They do not
//! make invalid Vulkan commands legal or guarantee protection from GPU hangs.
//!
//! ## Thread Safety
//! `VulkanDevice` uses an internal mutex for `submitGuarded` to ensure queue
//! submissions are synchronized. However, most RHI operations are still restricted
//! to the main thread by engine convention.

const std = @import("std");
const sync = @import("sync");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;

fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    _: c.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    if (user_data) |ptr| {
        const device: *VulkanDevice = @ptrCast(@alignCast(ptr));
        if ((severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0) {
            _ = device.validation_error_count.fetchAdd(1, .monotonic);
            if (callback_data) |data| {
                if (data.pMessage != null) {
                    const message = std.mem.span(data.pMessage);
                    log.log.err("Vulkan validation error: {s}", .{message});
                }
            }
        }
    }
    return c.VK_FALSE;
}

pub const VulkanDevice = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical_device: c.VkPhysicalDevice = null,
    vk_device: c.VkDevice = null,
    queue: c.VkQueue = null,
    graphics_family: u32 = 0,
    transfer_family: u32 = 0,
    has_dedicated_transfer_queue: bool = false,
    supports_device_fault: bool = false,
    robust_buffer_access2_enabled: bool = false,
    mutex: sync.Mutex = .{},

    debug_messenger: c.VkDebugUtilsMessengerEXT = null,
    validation_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    debug_utils_enabled: bool = false,
    validation_layers_enabled: bool = false,

    // Extension function pointers
    vkGetDeviceFaultInfoEXT: ?*const fn (
        device: c.VkDevice,
        pFaultCounts: *c.VkDeviceFaultCountsEXT,
        pFaultInfo: ?*c.VkDeviceFaultInfoEXT,
    ) callconv(.c) c.VkResult = null,

    // Injectable dispatch boundary; tests exercise the same guarded path as the renderer.
    queue_submit_fn: *const fn (c.VkQueue, u32, [*c]const c.VkSubmitInfo, c.VkFence) callconv(.c) c.VkResult = c.vkQueueSubmit,

    fault_count: u32 = 0,
    recovery_count: u32 = 0,
    recovery_success_count: u32 = 0,
    recovery_fail_count: u32 = 0,
    max_recovery_attempts: u32 = 5,

    // Limits and capabilities
    max_anisotropy: f32 = 0.0,
    max_msaa_samples: u8 = 1,
    multi_draw_indirect: bool = false,
    draw_indirect_first_instance: bool = false,
    draw_indirect_count: bool = false,
    vkCmdDrawIndirectCountKHR: ?*const fn (c.VkCommandBuffer, c.VkBuffer, c.VkDeviceSize, c.VkBuffer, c.VkDeviceSize, u32, u32) callconv(.c) void = null,
    vkCmdDrawIndexedIndirectCountKHR: ?*const fn (c.VkCommandBuffer, c.VkBuffer, c.VkDeviceSize, c.VkBuffer, c.VkDeviceSize, u32, u32) callconv(.c) void = null,
    timestamp_period: f32 = 1.0,

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window) !VulkanDevice {
        var self = VulkanDevice{ .allocator = allocator };
        errdefer self.deinit();

        // 1. Create Instance
        var count: u32 = 0;
        const extensions_ptr = c.SDL_Vulkan_GetInstanceExtensions(&count);
        if (extensions_ptr == null) return error.VulkanExtensionsFailed;

        const enable_validation = std.debug.runtime_safety;

        const props2_name: [*:0]const u8 = @ptrCast(c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
        const props2_name_slice = std.mem.span(props2_name);

        const debug_utils_name: [*:0]const u8 = @ptrCast(c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
        const debug_utils_name_slice = std.mem.span(debug_utils_name);

        var instance_ext_count: u32 = 0;
        try checkVk(c.vkEnumerateInstanceExtensionProperties(null, &instance_ext_count, null));
        const instance_ext_props = try allocator.alloc(c.VkExtensionProperties, instance_ext_count);
        defer allocator.free(instance_ext_props);
        try checkVk(c.vkEnumerateInstanceExtensionProperties(null, &instance_ext_count, instance_ext_props.ptr));

        var props2_supported = false;
        var debug_utils_supported = false;
        for (instance_ext_props[0..instance_ext_count]) |prop| {
            const name: [*:0]const u8 = @ptrCast(&prop.extensionName);
            if (std.mem.eql(u8, std.mem.span(name), props2_name_slice)) {
                props2_supported = true;
            }
            if (std.mem.eql(u8, std.mem.span(name), debug_utils_name_slice)) {
                debug_utils_supported = true;
            }
        }

        const sdl_extension_count: usize = @intCast(count);
        const sdl_extensions = extensions_ptr[0..sdl_extension_count];
        var props2_in_sdl = false;
        var debug_utils_in_sdl = false;
        for (sdl_extensions) |ext| {
            if (std.mem.eql(u8, std.mem.span(ext), props2_name_slice)) {
                props2_in_sdl = true;
            }
            if (std.mem.eql(u8, std.mem.span(ext), debug_utils_name_slice)) {
                debug_utils_in_sdl = true;
            }
        }

        const enable_props2 = props2_supported and !props2_in_sdl;
        const enable_debug_utils = enable_validation and debug_utils_supported and !debug_utils_in_sdl;
        const instance_extension_count: usize = sdl_extension_count + @intFromBool(enable_props2) + @intFromBool(enable_debug_utils);
        const instance_extensions = try allocator.alloc([*c]const u8, instance_extension_count);
        defer allocator.free(instance_extensions);
        for (sdl_extensions, 0..) |ext, i| instance_extensions[i] = ext;
        if (enable_props2) {
            instance_extensions[sdl_extension_count] = c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME;
        }
        if (enable_debug_utils) {
            const offset = sdl_extension_count + @intFromBool(enable_props2);
            instance_extensions[offset] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        }

        const props2_enabled = props2_supported and (props2_in_sdl or enable_props2);
        const debug_utils_enabled = enable_validation and debug_utils_supported and (debug_utils_in_sdl or enable_debug_utils);
        self.debug_utils_enabled = debug_utils_enabled;
        if (props2_supported and enable_props2) {
            log.log.info("Enabling VK_KHR_get_physical_device_properties2", .{});
        } else if (!props2_supported) {
            log.log.warn("VK_KHR_get_physical_device_properties2 not supported by instance", .{});
        }
        if (enable_validation and !debug_utils_enabled) {
            log.log.warn("VK_EXT_debug_utils not available; validation errors will not be counted", .{});
        }

        var app_info = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "ZigCraft";
        app_info.apiVersion = c.VK_API_VERSION_1_0;

        const validation_layers = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};

        var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = @intCast(instance_extensions.len);
        create_info.ppEnabledExtensionNames = instance_extensions.ptr;

        if (enable_validation) {
            var layer_count: u32 = 0;
            try checkVk(c.vkEnumerateInstanceLayerProperties(&layer_count, null));
            if (layer_count > 0) {
                const layer_props = allocator.alloc(c.VkLayerProperties, layer_count) catch null;
                if (layer_props) |props| {
                    defer allocator.free(props);
                    try checkVk(c.vkEnumerateInstanceLayerProperties(&layer_count, props.ptr));
                    var found = false;
                    for (props[0..layer_count]) |layer| {
                        const layer_name: [*:0]const u8 = @ptrCast(&layer.layerName);
                        if (std.mem.eql(u8, std.mem.span(layer_name), "VK_LAYER_KHRONOS_validation")) {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        create_info.enabledLayerCount = 1;
                        create_info.ppEnabledLayerNames = &validation_layers;
                        self.validation_layers_enabled = true;
                        log.log.info("Vulkan validation layers enabled", .{});
                    }
                }
            }
        }
        // Failed Vulkan creation calls may leave undefined output handles.
        // Publish only successful handles so rollback never destroys garbage.
        var instance: c.VkInstance = null;
        try checkVk(c.vkCreateInstance(&create_info, null, &instance));
        self.instance = instance;

        // 2. Create Surface
        var surface: c.VkSurfaceKHR = null;
        if (!c.SDL_Vulkan_CreateSurface(window, self.instance, null, &surface)) return error.VulkanSurfaceFailed;
        self.surface = surface;

        // 3. Pick Physical Device
        var device_count: u32 = 0;
        try checkVk(c.vkEnumeratePhysicalDevices(self.instance, &device_count, null));
        if (device_count == 0) return error.NoVulkanDevice;
        const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
        defer allocator.free(devices);
        try checkVk(c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr));
        if (device_count == 0) return error.NoVulkanDevice;
        self.physical_device = devices[0];

        // 4. Create Logical Device
        var supported_features: c.VkPhysicalDeviceFeatures = undefined;
        c.vkGetPhysicalDeviceFeatures(self.physical_device, &supported_features);

        var device_properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(self.physical_device, &device_properties);
        self.max_anisotropy = device_properties.limits.maxSamplerAnisotropy;
        self.timestamp_period = device_properties.limits.timestampPeriod;

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
        var dedicated_transfer_family: ?u32 = null;
        for (queue_families[0..queue_family_count], 0..) |qf, i| {
            if (qf.queueCount == 0) continue;
            const idx: u32 = @intCast(i);
            if (graphics_family == null and (qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
                graphics_family = idx;
            }
            if (dedicated_transfer_family == null and
                (qf.queueFlags & c.VK_QUEUE_TRANSFER_BIT) != 0 and
                (qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) == 0 and
                (qf.queueFlags & c.VK_QUEUE_COMPUTE_BIT) == 0)
            {
                dedicated_transfer_family = idx;
            }
        }
        if (graphics_family == null) return error.NoGraphicsQueue;
        self.graphics_family = graphics_family.?;

        if (dedicated_transfer_family) |tf| {
            self.transfer_family = tf;
            self.has_dedicated_transfer_queue = true;
            log.log.info("Dedicated transfer queue family found: {}", .{tf});
        } else {
            self.transfer_family = self.graphics_family;
            self.has_dedicated_transfer_queue = false;
            log.log.info("No dedicated transfer queue — sharing graphics queue family {}", .{self.graphics_family});
        }

        const queue_priority: f32 = 1.0;
        var queue_create_infos: [2]c.VkDeviceQueueCreateInfo = .{std.mem.zeroes(c.VkDeviceQueueCreateInfo)} ** 2;
        var queue_create_count: u32 = 1;

        queue_create_infos[0].sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_create_infos[0].queueFamilyIndex = self.graphics_family;
        queue_create_infos[0].queueCount = 1;
        queue_create_infos[0].pQueuePriorities = &queue_priority;

        if (self.has_dedicated_transfer_queue) {
            queue_create_infos[1].sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queue_create_infos[1].queueFamilyIndex = self.transfer_family;
            queue_create_infos[1].queueCount = 1;
            queue_create_infos[1].pQueuePriorities = &queue_priority;
            queue_create_count = 2;
        }

        var ext_count: u32 = 0;
        try checkVk(c.vkEnumerateDeviceExtensionProperties(self.physical_device, null, &ext_count, null));
        const ext_props = try allocator.alloc(c.VkExtensionProperties, ext_count);
        defer allocator.free(ext_props);
        try checkVk(c.vkEnumerateDeviceExtensionProperties(self.physical_device, null, &ext_count, ext_props.ptr));

        const robustness2_name: [*:0]const u8 = @ptrCast(c.VK_EXT_ROBUSTNESS_2_EXTENSION_NAME);
        const device_fault_name: [*:0]const u8 = @ptrCast(c.VK_EXT_DEVICE_FAULT_EXTENSION_NAME);
        const indirect_count_name: [*:0]const u8 = @ptrCast(c.VK_KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME);
        const robustness2_name_slice = std.mem.span(robustness2_name);
        const device_fault_name_slice = std.mem.span(device_fault_name);
        const indirect_count_name_slice = std.mem.span(indirect_count_name);

        var supports_robustness2 = false;
        var supports_device_fault = false;
        var supports_indirect_count = false;
        for (ext_props[0..ext_count]) |prop| {
            const name: [*:0]const u8 = @ptrCast(&prop.extensionName);
            const name_slice = std.mem.span(name);
            if (std.mem.eql(u8, name_slice, robustness2_name_slice)) supports_robustness2 = true;
            if (std.mem.eql(u8, name_slice, device_fault_name_slice)) supports_device_fault = true;
            if (std.mem.eql(u8, name_slice, indirect_count_name_slice)) supports_indirect_count = true;
        }

        if (supports_robustness2) log.log.info("VK_EXT_robustness2 supported", .{});
        if (supports_device_fault) log.log.info("VK_EXT_device_fault supported", .{});
        var allow_robustness2 = supports_robustness2 and props2_enabled;
        var allow_device_fault = supports_device_fault and props2_enabled;
        if (!props2_enabled and (supports_robustness2 or supports_device_fault)) {
            log.log.warn("VK_KHR_get_physical_device_properties2 not enabled; skipping robustness/device fault", .{});
        }

        var robustness2_features = std.mem.zeroes(c.VkPhysicalDeviceRobustness2FeaturesEXT);
        robustness2_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT;
        var fault_features = std.mem.zeroes(c.VkPhysicalDeviceFaultFeaturesEXT);
        fault_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT;

        if (allow_robustness2 or allow_device_fault) {
            const proc = c.vkGetInstanceProcAddr(self.instance, "vkGetPhysicalDeviceFeatures2KHR");
            if (proc) |function| {
                const get_features: *const fn (c.VkPhysicalDevice, *c.VkPhysicalDeviceFeatures2KHR) callconv(.c) void = @ptrCast(function);
                var features2 = std.mem.zeroes(c.VkPhysicalDeviceFeatures2KHR);
                features2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2_KHR;
                if (allow_robustness2) {
                    robustness2_features.pNext = if (allow_device_fault) @ptrCast(&fault_features) else null;
                    features2.pNext = @ptrCast(&robustness2_features);
                } else {
                    features2.pNext = @ptrCast(&fault_features);
                }
                get_features(self.physical_device, &features2);
                if (device_features.robustBufferAccess != c.VK_TRUE) robustness2_features.robustBufferAccess2 = c.VK_FALSE;
                allow_device_fault = allow_device_fault and fault_features.deviceFault == c.VK_TRUE;
                fault_features.deviceFaultVendorBinary = c.VK_FALSE;
            } else {
                log.log.warn("Feature query unavailable; skipping robustness/device fault features", .{});
                allow_robustness2 = false;
                allow_device_fault = false;
            }
        }

        if (allow_robustness2) {
            robustness2_features.pNext = if (allow_device_fault) @ptrCast(&fault_features) else null;
        }

        var enabled_extensions: [4][*c]const u8 = undefined;
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
        if (supports_indirect_count) {
            enabled_extensions[enabled_extension_count] = c.VK_KHR_DRAW_INDIRECT_COUNT_EXTENSION_NAME;
            enabled_extension_count += 1;
        }

        var device_create_info = std.mem.zeroes(c.VkDeviceCreateInfo);
        device_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        device_create_info.queueCreateInfoCount = queue_create_count;
        device_create_info.pQueueCreateInfos = &queue_create_infos[0];
        device_create_info.pEnabledFeatures = &device_features;
        if (allow_robustness2) {
            device_create_info.pNext = @ptrCast(&robustness2_features);
        } else if (allow_device_fault) {
            device_create_info.pNext = @ptrCast(&fault_features);
        }
        device_create_info.enabledExtensionCount = enabled_extension_count;
        device_create_info.ppEnabledExtensionNames = &enabled_extensions;

        var vk_device: c.VkDevice = null;
        var create_result = c.vkCreateDevice(self.physical_device, &device_create_info, null, &vk_device);
        if ((allow_robustness2 or allow_device_fault) and
            (create_result == c.VK_ERROR_FEATURE_NOT_PRESENT or create_result == c.VK_ERROR_EXTENSION_NOT_PRESENT))
        {
            log.log.warn("Robustness/device fault features not available, falling back to basic device", .{});
            device_create_info.pNext = null;
            allow_robustness2 = false;
            allow_device_fault = false;
            enabled_extensions[0] = c.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
            enabled_extension_count = 1;
            supports_indirect_count = false;
            device_create_info.enabledExtensionCount = enabled_extension_count;
            device_create_info.ppEnabledExtensionNames = &enabled_extensions;
            queue_create_count = 1;
            device_create_info.queueCreateInfoCount = queue_create_count;
            self.has_dedicated_transfer_queue = false;
            self.transfer_family = self.graphics_family;
            vk_device = null;
            create_result = c.vkCreateDevice(self.physical_device, &device_create_info, null, &vk_device);
        }

        try checkVk(create_result);
        self.vk_device = vk_device;
        self.supports_device_fault = allow_device_fault;
        self.robust_buffer_access2_enabled = if (allow_robustness2) robustness2_features.robustBufferAccess2 == c.VK_TRUE else false;
        c.vkGetDeviceQueue(self.vk_device, self.graphics_family, 0, &self.queue);

        if (self.supports_device_fault and self.vk_device != null) {
            std.debug.assert(self.vk_device != null);
            const proc = c.vkGetDeviceProcAddr(self.vk_device, "vkGetDeviceFaultInfoEXT");
            if (proc != null) {
                self.vkGetDeviceFaultInfoEXT = @ptrCast(proc);
            } else {
                self.supports_device_fault = false;
            }
        }
        if (supports_indirect_count and self.vk_device != null) {
            const proc = c.vkGetDeviceProcAddr(self.vk_device, "vkCmdDrawIndirectCountKHR");
            if (proc) |function| {
                self.vkCmdDrawIndirectCountKHR = @ptrCast(function);
                const indexed_proc = c.vkGetDeviceProcAddr(self.vk_device, "vkCmdDrawIndexedIndirectCountKHR");
                if (indexed_proc) |indexed_function| {
                    self.vkCmdDrawIndexedIndirectCountKHR = @ptrCast(indexed_function);
                    self.draw_indirect_count = true;
                }
            }
        }

        return self;
    }

    pub fn initDebugMessenger(self: *VulkanDevice) void {
        if (self.instance == null) return;
        if (!self.debug_utils_enabled) return;
        if (self.debug_messenger != null) return;

        const create_proc = c.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT");
        if (create_proc) |proc| {
            const create_fn: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(proc);
            if (create_fn) |func| {
                var debug_info = std.mem.zeroes(c.VkDebugUtilsMessengerCreateInfoEXT);
                debug_info.sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
                debug_info.messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
                debug_info.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
                debug_info.pfnUserCallback = debugCallback;
                debug_info.pUserData = self;
                var messenger: c.VkDebugUtilsMessengerEXT = null;
                if (func(self.instance, &debug_info, null, &messenger) != c.VK_SUCCESS) {
                    log.log.warn("Failed to create debug utils messenger", .{});
                } else {
                    self.debug_messenger = messenger;
                }
            } else {
                log.log.warn("vkCreateDebugUtilsMessengerEXT not available", .{});
            }
        } else {
            log.log.warn("vkCreateDebugUtilsMessengerEXT not found; validation errors will not be counted", .{});
        }
    }

    pub fn deinit(self: *VulkanDevice) void {
        // The caller must retire GPU work and destroy device children first.
        // Keep the messenger alive while destroying the device and surface.
        if (self.vk_device != null) {
            c.vkDestroyDevice(self.vk_device, null);
            self.vk_device = null;
        }
        if (self.instance != null and self.surface != null) {
            c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        }
        self.surface = null;
        if (self.instance != null and self.debug_messenger != null) {
            const destroy_proc = c.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT");
            if (destroy_proc) |proc| {
                const destroy_fn: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(proc);
                if (destroy_fn) |func| {
                    func(self.instance, self.debug_messenger, null);
                }
            }
        }
        self.debug_messenger = null;
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.instance = null;
        self.physical_device = null;
        self.queue = null;
        self.vkGetDeviceFaultInfoEXT = null;
        self.vkCmdDrawIndirectCountKHR = null;
        self.vkCmdDrawIndexedIndirectCountKHR = null;
        self.supports_device_fault = false;
        self.robust_buffer_access2_enabled = false;
        self.draw_indirect_count = false;
        self.has_dedicated_transfer_queue = false;
        self.debug_utils_enabled = false;
        self.validation_layers_enabled = false;
    }

    pub fn getDeviceLocalVramBytes(self: VulkanDevice) u64 {
        var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

        var max_heap: u64 = 0;
        for (0..mem_properties.memoryHeapCount) |i| {
            if ((mem_properties.memoryHeaps[i].flags & c.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                max_heap = @max(max_heap, mem_properties.memoryHeaps[i].size);
            }
        }
        return max_heap;
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

    /// Submits command buffers to the graphics queue and reports submission errors.
    /// This does not prevent device loss or recover a lost device.
    /// Thread-safe via internal mutex.
    pub fn submitGuarded(self: *VulkanDevice, submit_info: c.VkSubmitInfo, fence: c.VkFence) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.queue_submit_fn(self.queue, 1, &submit_info, fence);

        if (result == c.VK_ERROR_DEVICE_LOST) {
            self.fault_count += 1;
            log.log.err("Vulkan reported VK_ERROR_DEVICE_LOST during queue submission. Total faults: {d}", .{self.fault_count});
            self.logDeviceFaults();
            return error.GpuLost;
        }

        try checkVk(result);
    }

    /// Logs detailed fault information if VK_EXT_device_fault is enabled and supported.
    pub fn logDeviceFaults(self: VulkanDevice) void {
        const func = self.vkGetDeviceFaultInfoEXT orelse {
            log.log.warn("VK_EXT_device_fault not available; review system logs (dmesg) for GPU errors.", .{});
            return;
        };

        log.log.info("Querying VK_EXT_device_fault for detailed hang info...", .{});

        var fault_counts = std.mem.zeroes(c.VkDeviceFaultCountsEXT);
        fault_counts.sType = c.VK_STRUCTURE_TYPE_DEVICE_FAULT_COUNTS_EXT;
        const count_result = func(self.vk_device, &fault_counts, null);
        if (count_result != c.VK_SUCCESS) {
            log.log.warn("Failed to query device fault record counts: {d}", .{count_result});
            return;
        }

        const address_infos = self.allocator.alloc(c.VkDeviceFaultAddressInfoEXT, fault_counts.addressInfoCount) catch {
            log.log.warn("Failed to allocate device fault address records.", .{});
            return;
        };
        defer self.allocator.free(address_infos);
        const vendor_infos = self.allocator.alloc(c.VkDeviceFaultVendorInfoEXT, fault_counts.vendorInfoCount) catch {
            log.log.warn("Failed to allocate device fault vendor records.", .{});
            return;
        };
        defer self.allocator.free(vendor_infos);

        // Vendor binaries can be arbitrarily large and are intended for
        // external crash-dump tooling. Keep runtime fault reporting bounded.
        fault_counts.vendorBinarySize = 0;
        var fault_info = std.mem.zeroes(c.VkDeviceFaultInfoEXT);
        fault_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_FAULT_INFO_EXT;
        fault_info.pAddressInfos = if (address_infos.len == 0) null else address_infos.ptr;
        fault_info.pVendorInfos = if (vendor_infos.len == 0) null else vendor_infos.ptr;

        const result = func(self.vk_device, &fault_counts, &fault_info);
        if (result == c.VK_SUCCESS or result == c.VK_INCOMPLETE) {
            const desc: [*:0]const u8 = @ptrCast(&fault_info.description);
            log.log.err("GPU Fault Detected: {s} (addresses: {d}, vendor records: {d})", .{ desc, fault_counts.addressInfoCount, fault_counts.vendorInfoCount });
        } else {
            log.log.warn("Failed to retrieve device fault info: {d}", .{result});
        }
        log.log.warn("Review system logs (dmesg/journalctl) for kernel-level GPU driver errors.", .{});
    }
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

test "VulkanDevice.deinit is safe and repeatable before initialization" {
    const testing = @import("std").testing;

    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    device.deinit();
    device.deinit();
    try testing.expect(device.instance == null);
    try testing.expect(device.surface == null);
    try testing.expect(device.vk_device == null);
    try testing.expect(device.queue == null);
    try testing.expect(device.debug_messenger == null);
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
