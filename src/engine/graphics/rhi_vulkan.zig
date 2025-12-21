const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");

const VulkanContext = struct {
    allocator: std.mem.Allocator,
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue: c.VkQueue,

    // For now we don't implement full buffer management
};

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;

    // Stub implementation
    std.log.info("Initializing Vulkan backend (Stub)...", .{});

    // Create Instance
    var app_info = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "Zig Voxel Engine";
    app_info.applicationVersion = c.VK_MAKE_VERSION(1, 0, 0);
    app_info.pEngineName = "Zig Voxel Engine";
    app_info.engineVersion = c.VK_MAKE_VERSION(1, 0, 0);
    app_info.apiVersion = c.VK_API_VERSION_1_0;

    var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;

    // TODO: Add extensions (Surface, etc.)

    var instance: c.VkInstance = null;
    const result = c.vkCreateInstance(&create_info, null, &instance);
    if (result != c.VK_SUCCESS) {
        std.log.err("Failed to create Vulkan instance: {}", .{result});
        return error.VulkanInitFailed;
    }

    ctx.instance = instance;
    std.log.info("Vulkan Instance created: {?}", .{instance});

    // Just a stub - we won't actually draw anything yet
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.instance != null) {
        c.vkDestroyInstance(ctx.instance, null);
    }
    ctx.allocator.destroy(ctx);
}

fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
    _ = ctx_ptr;
    _ = size;
    _ = usage;
    // Stub
    return 1;
}

fn uploadBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) void {
    _ = ctx_ptr;
    _ = handle;
    _ = data;
    // Stub
}

fn destroyBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    _ = ctx_ptr;
    _ = handle;
    // Stub
}

fn beginFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn endFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    _ = ctx_ptr;
    _ = handle;
    _ = count;
    _ = mode;
}

const vtable = rhi.RHI.VTable{
    .init = init,
    .deinit = deinit,
    .createBuffer = createBuffer,
    .uploadBuffer = uploadBuffer,
    .destroyBuffer = destroyBuffer,
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .draw = draw,
};

pub fn createRHI(allocator: std.mem.Allocator) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    // Use std.mem.zeroes with explicit type to ensure it initializes safely
    // Wait, pointers cannot be zeroed if they are not optional?
    // Let's manually initialize.
    ctx.* = VulkanContext{
        .allocator = allocator,
        .instance = null,
        .physical_device = null,
        .device = null,
        .queue = null,
    };

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &vtable,
    };
}
