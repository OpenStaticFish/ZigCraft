//! UI System for rendering 2D interface elements.
//! Uses orthographic projection and immediate-mode style rendering.
//! Now abstracted through RHI for backend-agnostic rendering.

const std = @import("std");
const rhi = @import("../graphics/rhi.zig");

// Re-export Color and Rect from RHI for convenience
pub const Color = rhi.Color;
pub const Rect = rhi.Rect;

pub const UISystem = struct {
    renderer: rhi.RHI,
    screen_width: f32,
    screen_height: f32,

    pub fn init(renderer: rhi.RHI, width: u32, height: u32) !UISystem {
        return .{
            .renderer = renderer,
            .screen_width = @floatFromInt(width),
            .screen_height = @floatFromInt(height),
        };
    }

    pub fn deinit(self: *UISystem) void {
        _ = self;
        // RHI cleanup is handled by the RHI itself
    }

    pub fn resize(self: *UISystem, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    /// Begin UI rendering (call before drawing any UI elements)
    pub fn begin(self: *UISystem) void {
        self.renderer.begin2DPass(self.screen_width, self.screen_height);
    }

    /// End UI rendering (call after drawing all UI elements)
    pub fn end(self: *UISystem) void {
        self.renderer.end2DPass();
    }

    /// Draw a filled rectangle
    pub fn drawRect(self: *UISystem, rect: Rect, color: Color) void {
        self.renderer.drawRect2D(rect, color);
    }

    /// Draw a textured rectangle
    pub fn drawTexture(self: *UISystem, texture_id: rhi.TextureHandle, rect: Rect) void {
        self.renderer.drawTexture2D(texture_id, rect);
    }

    /// Draw a rectangle outline
    pub fn drawRectOutline(self: *UISystem, rect: Rect, color: Color, thickness: f32) void {
        // Top
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, color);
        // Bottom
        self.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - thickness, .width = rect.width, .height = thickness }, color);
        // Left
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, color);
        // Right
        self.drawRect(.{ .x = rect.x + rect.width - thickness, .y = rect.y, .width = thickness, .height = rect.height }, color);
    }
};

/// Base widget structure (implement interface pattern)
pub const Widget = struct {
    bounds: Rect,
    visible: bool = true,
    enabled: bool = true,

    // Virtual functions
    drawFn: *const fn (*Widget) void,
    handleInputFn: *const fn (*Widget, InputEvent) bool,

    pub fn draw(self: *Widget, widget: *Widget) void {
        if (self.visible) {
            self.drawFn(widget);
        }
    }

    pub fn handleInput(self: *Widget, widget: *Widget, event: InputEvent) bool {
        if (self.enabled) {
            return self.handleInputFn(widget, event);
        }
        return false;
    }
};

pub const InputEvent = @import("../core/interfaces.zig").InputEvent;
