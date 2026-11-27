const std = @import("std");
const c = @import("c").c;
const rhi_pkg = @import("engine-rhi").rhi;
const rhi_vulkan = @import("rhi_vulkan.zig");

pub const BackendChoice = enum {
    vulkan,
};

pub const Config = struct {
    shadow_resolution: u32,
    msaa_samples: u8,
    anisotropic_filtering: u8,
    skip_present: bool = false,
};

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, backend: BackendChoice, config: Config) !rhi_pkg.RHI {
    return switch (backend) {
        .vulkan => rhi_vulkan.createRHI(allocator, window, null, config.shadow_resolution, config.msaa_samples, config.anisotropic_filtering, config.skip_present),
    };
}
