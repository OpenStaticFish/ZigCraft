const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const RenderDevice = @import("engine-rhi").render_device.RenderDevice;
const runtime_env = @import("engine-core").runtime_env;
const ShadowSystem = @import("engine-shadows").ShadowSystem;

pub fn createRHI(
    comptime VulkanContext: type,
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    render_device: ?*RenderDevice,
    shadow_resolution: u32,
    msaa_samples: u8,
    anisotropic_filtering: u8,
    vtable: *const rhi.RHI.VTable,
) !rhi.RHI {
    const ctx = try allocator.create(VulkanContext);
    errdefer allocator.destroy(ctx);
    try initializeDefaults(ctx, allocator, window, render_device, shadow_resolution, msaa_samples, anisotropic_filtering);
    if (ctx.options.safe_mode) {
        log.log.warn("ZIGCRAFT_SAFE_MODE enabled: throttling uploads and forcing GPU idle each frame", .{});
    }

    return rhi.RHI{
        .ptr = ctx,
        .vtable = vtable,
        .device = render_device,
    };
}

pub fn initializeDefaults(ctx: anytype, allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !void {
    ctx.* = .{
        .allocator = allocator,
        .window = window,
        .render_device = render_device,
        .vulkan_device = .{ .allocator = allocator },
        // These managers own nonoptional pointers and are unreadable until their
        // constructors succeed. InitOwnership gates every rollback/teardown.
        .resources = undefined,
        .frames = undefined,
        .swapchain = undefined,
        .descriptors = undefined,
        .shadow_system = try ShadowSystem.init(allocator, shadow_resolution),
        .shadow_runtime = .{ .shadow_resolution = shadow_resolution },
        .draw = .{},
        .runtime = .{},
        .options = .{
            .msaa_samples = msaa_samples,
            .anisotropic_filtering = anisotropic_filtering,
            .safe_mode = runtime_env.safeModeEnabled(),
        },
    };
}
