const std = @import("std");
const rhi = @import("../graphics/rhi.zig");
const RHI = rhi.RHI;

pub const DebugShadowOverlay = struct {
    pub fn draw(rhi_ctx: *const RHI, screen_width: f32, screen_height: f32) void {
        const debug_size: f32 = 200.0;
        const debug_spacing: f32 = 10.0;

        rhi_ctx.begin2DPass(screen_width, screen_height);
        defer rhi_ctx.end2DPass();

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            const handle = rhi_ctx.getShadowMapHandle(@intCast(i));
            if (handle == 0) continue;

            const x = debug_spacing + @as(f32, @floatFromInt(i)) * (debug_size + debug_spacing);
            const y = debug_spacing;

            rhi_ctx.drawDepthTexture2D(handle, .{
                .x = x,
                .y = y,
                .width = debug_size,
                .height = debug_size,
            });
        }
    }
};
