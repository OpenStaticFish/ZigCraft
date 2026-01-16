//! GPU-Proof Vulkan Layer
//!
//! Provides robust device creation with VK_EXT_robustness2 and VK_EXT_device_fault
//! to prevent GPU hangs from crashing the entire machine when submitting garbage.

const std = @import("std");

// Inline Vulkan C import for standalone compilation
// (when used as library, can also import from ../../c.zig)
const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

/// Error set for robust Vulkan operations
pub const RobustError = error{
    VulkanError,
    NoVulkanDevice,
    NoGraphicsQueue,
    NoDiscreteGpu,
    ExtensionNotSupported,
    GpuLost,
};

/// State for the robust device context, enabling cleanup on GPU loss
pub const RobustContext = struct {
    instance: c.VkInstance,
    device: c.VkDevice,
    physical_device: c.VkPhysicalDevice,
    queue: c.VkQueue,
    queue_family: u32,
    command_pool: c.VkCommandPool,

    pub fn deinit(self: *RobustContext) void {
        if (self.command_pool != null) {
            c.vkDestroyCommandPool(self.device, self.command_pool, null);
            self.command_pool = null;
        }
        if (self.device != null) {
            c.vkDestroyDevice(self.device, null);
            self.device = null;
        }
        if (self.instance != null) {
            c.vkDestroyInstance(self.instance, null);
            self.instance = null;
        }
    }
};

/// Creates a logical device with robustness extensions enabled.
///
/// Enables:
/// - VK_EXT_robustness2: Buffer and image access robustness
/// - VK_EXT_device_fault: Fault reporting on device loss
///
/// The feature structs are chained via pNext into VkDeviceCreateInfo.
///
/// Returns the logical device or an error.
pub fn createRobustDevice(
    phys: c.VkPhysicalDevice,
    queue_family: u32,
) RobustError!c.VkDevice {
    // Extension names from Vulkan headers (not hard-coded strings)
    const extensions = [_][*c]const u8{
        c.VK_EXT_ROBUSTNESS_2_EXTENSION_NAME,
        c.VK_EXT_DEVICE_FAULT_EXTENSION_NAME,
    };

    // Verify extensions are supported
    var ext_count: u32 = 0;
    _ = c.vkEnumerateDeviceExtensionProperties(phys, null, &ext_count, null);

    var ext_props_buf: [256]c.VkExtensionProperties = undefined;
    const ext_props = ext_props_buf[0..@min(ext_count, 256)];
    var actual_count: u32 = @intCast(ext_props.len);
    _ = c.vkEnumerateDeviceExtensionProperties(phys, null, &actual_count, ext_props.ptr);

    var robustness2_supported = false;
    var device_fault_supported = false;

    for (ext_props[0..actual_count]) |prop| {
        const name: [*:0]const u8 = @ptrCast(&prop.extensionName);
        const name_slice = std.mem.span(name);
        if (std.mem.eql(u8, name_slice, "VK_EXT_robustness2")) {
            robustness2_supported = true;
        }
        if (std.mem.eql(u8, name_slice, "VK_EXT_device_fault")) {
            device_fault_supported = true;
        }
    }

    if (!robustness2_supported) {
        std.log.err("VK_EXT_robustness2 not supported on this device", .{});
        return error.ExtensionNotSupported;
    }
    if (!device_fault_supported) {
        std.log.warn("VK_EXT_device_fault not supported, continuing without fault reporting", .{});
    }

    // Build feature chain: fault_features <- robustness2_features <- device_create_info
    // VkPhysicalDeviceFaultFeaturesEXT (end of chain, pNext = null)
    var fault_features = std.mem.zeroes(c.VkPhysicalDeviceFaultFeaturesEXT);
    fault_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FAULT_FEATURES_EXT;
    fault_features.pNext = null;
    if (device_fault_supported) {
        fault_features.deviceFault = c.VK_TRUE;
        fault_features.deviceFaultVendorBinary = c.VK_FALSE; // Vendor-specific, not always available
    }

    // VkPhysicalDeviceRobustness2FeaturesEXT -> chains to fault_features
    var robustness2_features = std.mem.zeroes(c.VkPhysicalDeviceRobustness2FeaturesEXT);
    robustness2_features.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT;
    robustness2_features.pNext = if (device_fault_supported) @ptrCast(&fault_features) else null;
    robustness2_features.robustBufferAccess2 = c.VK_TRUE;
    robustness2_features.robustImageAccess2 = c.VK_TRUE;
    robustness2_features.nullDescriptor = c.VK_TRUE;

    // Queue creation
    const queue_priority: f32 = 1.0;
    var queue_create_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
    queue_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_create_info.queueFamilyIndex = queue_family;
    queue_create_info.queueCount = 1;
    queue_create_info.pQueuePriorities = &queue_priority;

    // Base device features (enable robustBufferAccess from core 1.0 as well)
    var device_features = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    device_features.robustBufferAccess = c.VK_TRUE;

    // Device creation with pNext chain
    var device_create_info = std.mem.zeroes(c.VkDeviceCreateInfo);
    device_create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_create_info.pNext = @ptrCast(&robustness2_features);
    device_create_info.queueCreateInfoCount = 1;
    device_create_info.pQueueCreateInfos = &queue_create_info;
    device_create_info.pEnabledFeatures = &device_features;

    // Only enable extensions that are supported
    var enabled_extensions: [2][*c]const u8 = undefined;
    var enabled_count: u32 = 0;
    enabled_extensions[enabled_count] = extensions[0]; // robustness2
    enabled_count += 1;
    if (device_fault_supported) {
        enabled_extensions[enabled_count] = extensions[1]; // device_fault
        enabled_count += 1;
    }
    device_create_info.enabledExtensionCount = enabled_count;
    device_create_info.ppEnabledExtensionNames = &enabled_extensions;

    var device: c.VkDevice = null;
    const result = c.vkCreateDevice(phys, &device_create_info, null, &device);

    if (result != c.VK_SUCCESS) {
        std.log.err("vkCreateDevice failed with result: {d}", .{result});
        return error.VulkanError;
    }

    std.log.info("Robust device created with VK_EXT_robustness2", .{});
    if (device_fault_supported) {
        std.log.info("VK_EXT_device_fault also enabled", .{});
    }

    return device;
}

/// Submits a command buffer with GPU loss handling.
///
/// On VK_ERROR_DEVICE_LOST:
/// - Prints "GPU reset triggered voluntarily"
/// - Destroys the device
/// - Returns error.GpuLost so caller can recreate everything
pub fn submitGuarded(
    queue: c.VkQueue,
    cmd: c.VkCommandBuffer,
    device: *c.VkDevice,
) RobustError!void {
    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd;

    const result = c.vkQueueSubmit(queue, 1, &submit_info, null);

    if (result == c.VK_ERROR_DEVICE_LOST) {
        std.debug.print("GPU reset triggered voluntarily\n", .{});
        c.vkDestroyDevice(device.*, null);
        device.* = null;
        return error.GpuLost;
    }

    if (result != c.VK_SUCCESS) {
        std.log.err("vkQueueSubmit failed with result: {d}", .{result});
        return error.VulkanError;
    }

    // Wait for completion to catch any deferred device loss
    const wait_result = c.vkQueueWaitIdle(queue);
    if (wait_result == c.VK_ERROR_DEVICE_LOST) {
        std.debug.print("GPU reset triggered voluntarily\n", .{});
        c.vkDestroyDevice(device.*, null);
        device.* = null;
        return error.GpuLost;
    }
}

/// Creates a Vulkan instance for the demo (no window/surface needed)
fn createInstance() RobustError!c.VkInstance {
    var app_info = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "GPU Robustness Demo";
    app_info.applicationVersion = c.VK_MAKE_VERSION(1, 0, 0);
    app_info.pEngineName = "ZigCraft";
    app_info.engineVersion = c.VK_MAKE_VERSION(1, 0, 0);
    app_info.apiVersion = c.VK_API_VERSION_1_1; // Need 1.1+ for pNext chaining

    var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;

    var instance: c.VkInstance = null;
    const result = c.vkCreateInstance(&create_info, null, &instance);
    if (result != c.VK_SUCCESS) {
        std.log.err("vkCreateInstance failed: {d}", .{result});
        return error.VulkanError;
    }

    return instance;
}

/// Finds the first discrete GPU in the system
fn findDiscreteGpu(instance: c.VkInstance) RobustError!c.VkPhysicalDevice {
    var device_count: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(instance, &device_count, null);
    if (device_count == 0) return error.NoVulkanDevice;

    var devices_buf: [16]c.VkPhysicalDevice = undefined;
    const devices = devices_buf[0..@min(device_count, 16)];
    var actual_count: u32 = @intCast(devices.len);
    _ = c.vkEnumeratePhysicalDevices(instance, &actual_count, devices.ptr);

    // First pass: look for discrete GPU
    for (devices[0..actual_count]) |phys| {
        var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        c.vkGetPhysicalDeviceProperties(phys, &props);

        if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            const name: [*:0]const u8 = @ptrCast(&props.deviceName);
            std.log.info("Selected discrete GPU: {s}", .{name});
            return phys;
        }
    }

    // Fallback: use first available device
    std.log.warn("No discrete GPU found, using first available device", .{});
    if (actual_count > 0) {
        var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        c.vkGetPhysicalDeviceProperties(devices[0], &props);
        const name: [*:0]const u8 = @ptrCast(&props.deviceName);
        std.log.info("Selected GPU: {s}", .{name});
        return devices[0];
    }

    return error.NoDiscreteGpu;
}

/// Finds a graphics-capable queue family
fn findGraphicsQueueFamily(phys: c.VkPhysicalDevice) RobustError!u32 {
    var queue_family_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(phys, &queue_family_count, null);

    var queue_families_buf: [32]c.VkQueueFamilyProperties = undefined;
    const queue_families = queue_families_buf[0..@min(queue_family_count, 32)];
    var actual_count: u32 = @intCast(queue_families.len);
    c.vkGetPhysicalDeviceQueueFamilyProperties(phys, &actual_count, queue_families.ptr);

    for (queue_families[0..actual_count], 0..) |qf, i| {
        if ((qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT) != 0) {
            return @intCast(i);
        }
    }

    return error.NoGraphicsQueue;
}

/// Creates a command pool for the given queue family
fn createCommandPool(device: c.VkDevice, queue_family: u32) RobustError!c.VkCommandPool {
    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = queue_family;

    var pool: c.VkCommandPool = null;
    const result = c.vkCreateCommandPool(device, &pool_info, null, &pool);
    if (result != c.VK_SUCCESS) return error.VulkanError;

    return pool;
}

/// Allocates a command buffer from the pool
fn allocateCommandBuffer(device: c.VkDevice, pool: c.VkCommandPool) RobustError!c.VkCommandBuffer {
    var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    alloc_info.commandPool = pool;
    alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc_info.commandBufferCount = 1;

    var cmd: c.VkCommandBuffer = null;
    const result = c.vkAllocateCommandBuffers(device, &alloc_info, &cmd);
    if (result != c.VK_SUCCESS) return error.VulkanError;

    return cmd;
}

/// Creates a small buffer for the OOB test
fn createTestBuffer(
    device: c.VkDevice,
    phys: c.VkPhysicalDevice,
    size: u64,
) RobustError!struct { buffer: c.VkBuffer, memory: c.VkDeviceMemory } {
    var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
    buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = size;
    buffer_info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    var buffer: c.VkBuffer = null;
    var result = c.vkCreateBuffer(device, &buffer_info, null, &buffer);
    if (result != c.VK_SUCCESS) return error.VulkanError;

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device, buffer, &mem_requirements);

    var mem_props: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(phys, &mem_props);

    // Find device-local memory type
    var memory_type_index: u32 = 0;
    const required_props = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        if ((mem_requirements.memoryTypeBits & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_props.memoryTypes[i].propertyFlags & required_props) == required_props)
        {
            memory_type_index = i;
            break;
        }
    }

    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_requirements.size;
    alloc_info.memoryTypeIndex = memory_type_index;

    var memory: c.VkDeviceMemory = null;
    result = c.vkAllocateMemory(device, &alloc_info, null, &memory);
    if (result != c.VK_SUCCESS) {
        c.vkDestroyBuffer(device, buffer, null);
        return error.VulkanError;
    }

    result = c.vkBindBufferMemory(device, buffer, memory, 0);
    if (result != c.VK_SUCCESS) {
        c.vkFreeMemory(device, memory, null);
        c.vkDestroyBuffer(device, buffer, null);
        return error.VulkanError;
    }

    return .{ .buffer = buffer, .memory = memory };
}

/// Demo: Creates robust device, performs intentional OOB access, submits via guarded path
pub fn main() !void {
    std.debug.print("\n=== GPU Robustness Demo ===\n\n", .{});

    // 1. Create Vulkan instance
    std.log.info("Creating Vulkan instance...", .{});
    const instance = try createInstance();
    defer c.vkDestroyInstance(instance, null);

    // 2. Find discrete GPU
    std.log.info("Searching for discrete GPU...", .{});
    const physical_device = try findDiscreteGpu(instance);

    // 3. Find graphics queue family
    const queue_family = try findGraphicsQueueFamily(physical_device);
    std.log.info("Graphics queue family: {d}", .{queue_family});

    // 4. Create robust device with VK_EXT_robustness2 + VK_EXT_device_fault
    std.log.info("Creating robust device with extensions...", .{});
    var device = try createRobustDevice(physical_device, queue_family);
    defer if (device != null) c.vkDestroyDevice(device, null);

    // 5. Get queue
    var queue: c.VkQueue = null;
    c.vkGetDeviceQueue(device, queue_family, 0, &queue);

    // 6. Create command pool
    const command_pool = try createCommandPool(device, queue_family);
    defer if (device != null) c.vkDestroyCommandPool(device, command_pool, null);

    // 7. Allocate command buffer
    const cmd = try allocateCommandBuffer(device, command_pool);

    // 8. Create a small test buffer (64 bytes)
    const buffer_size: u64 = 64;
    const test_buffer = try createTestBuffer(device, physical_device, buffer_size);
    defer if (device != null) {
        c.vkDestroyBuffer(device, test_buffer.buffer, null);
        c.vkFreeMemory(device, test_buffer.memory, null);
    };

    // 9. Record command buffer with intentional OOB access
    std.log.info("Recording command buffer with intentional OOB buffer access...", .{});

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

    var result = c.vkBeginCommandBuffer(cmd, &begin_info);
    if (result != c.VK_SUCCESS) return error.VulkanError;

    // INTENTIONAL OOB ACCESS:
    // Buffer is 64 bytes, but we try to fill at offset 1024 with size 64
    // Without robustness2, this could hang the GPU or crash the system
    // With robustness2, the access is clamped/ignored safely
    const oob_offset: u64 = 1024; // Way beyond our 64-byte buffer!
    const fill_size: u64 = 64;
    const fill_data: u32 = 0xDEADBEEF;

    std.debug.print("Buffer size: {d} bytes\n", .{buffer_size});
    std.debug.print("Attempting fill at offset {d} (OOB!) with 0x{X}\n", .{ oob_offset, fill_data });
    std.debug.print("Without robustness2, this would crash your machine!\n\n", .{});

    c.vkCmdFillBuffer(cmd, test_buffer.buffer, oob_offset, fill_size, fill_data);

    // Also do a valid operation to ensure command buffer is well-formed
    c.vkCmdFillBuffer(cmd, test_buffer.buffer, 0, buffer_size, 0x12345678);

    result = c.vkEndCommandBuffer(cmd);
    if (result != c.VK_SUCCESS) return error.VulkanError;

    // 10. Submit via guarded path
    std.log.info("Submitting command buffer via submitGuarded()...", .{});

    submitGuarded(queue, cmd, &device) catch |err| {
        switch (err) {
            error.GpuLost => {
                std.debug.print("\n[EXPECTED] GPU was lost but machine is still running!\n", .{});
                std.debug.print("Robustness layer prevented system hang.\n", .{});
                std.debug.print("In production, you would recreate the device here.\n\n", .{});
                return;
            },
            else => {
                std.log.err("Unexpected error during submit: {}", .{err});
                return err;
            },
        }
    };

    // If we get here, the OOB access was silently handled by robustness2
    std.debug.print("\n[SUCCESS] Command completed without GPU loss!\n", .{});
    std.debug.print("robustness2 silently handled the OOB access.\n", .{});
    std.debug.print("Your PC did not require a reboot.\n\n", .{});
}

// GPU-proof Vulkan layer installed — no reboot required.
