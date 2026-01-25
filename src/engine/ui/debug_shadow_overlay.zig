const std = @import("std");
const rhi = @import("../graphics/rhi.zig");
const IUIContext = rhi.IUIContext;
const IShadowContext = rhi.IShadowContext;

/// System for rendering debug shadow cascade overlays.
pub const DebugShadowOverlay = struct {
    /// Layout configuration for the debug overlay.
    pub const Config = struct {
        /// Default size of each shadow cascade thumbnail in pixels.
        size: f32 = 200.0,
        /// Default spacing between cascade thumbnails and screen edges in pixels.
        spacing: f32 = 10.0,
    };

    /// Draws the shadow cascade thumbnails to the screen.
    /// Requires an active UI context and a shadow context to retrieve handles.
    pub fn draw(ui: IUIContext, shadow: IShadowContext, screen_width: f32, screen_height: f32, config: Config) void {
        ui.beginPass(screen_width, screen_height);
        defer ui.endPass();

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            const handle = shadow.getShadowMapHandle(@intCast(i));
            if (handle == 0) continue;

            const x = config.spacing + @as(f32, @floatFromInt(i)) * (config.size + config.spacing);
            const y = config.spacing;

            ui.drawDepthTexture(handle, .{
                .x = x,
                .y = y,
                .width = config.size,
                .height = config.size,
            });
        }
    }
};
