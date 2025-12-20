//! Input system that polls SDL events and tracks keyboard/mouse state.

const std = @import("std");
const interfaces = @import("../core/interfaces.zig");
const InputEvent = interfaces.InputEvent;
const Key = interfaces.Key;
const MouseButton = interfaces.MouseButton;
const Modifiers = interfaces.Modifiers;

const c = @import("../../c.zig").c;

pub const Input = struct {
    /// Currently pressed keys
    keys_down: std.AutoHashMap(Key, void),

    /// Keys pressed this frame
    keys_pressed: std.AutoHashMap(Key, void),

    /// Keys released this frame
    keys_released: std.AutoHashMap(Key, void),

    /// Mouse button state
    mouse_buttons: [8]bool = .{false} ** 8,
    mouse_buttons_pressed: [8]bool = .{false} ** 8,
    mouse_buttons_released: [8]bool = .{false} ** 8,

    /// Mouse position
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_dx: i32 = 0,
    mouse_dy: i32 = 0,

    /// Mouse scroll
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    /// Window state
    window_width: u32 = 800,
    window_height: u32 = 600,
    should_quit: bool = false,

    /// Mouse capture state
    mouse_captured: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{
            .keys_down = std.AutoHashMap(Key, void).init(allocator),
            .keys_pressed = std.AutoHashMap(Key, void).init(allocator),
            .keys_released = std.AutoHashMap(Key, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Input) void {
        self.keys_down.deinit();
        self.keys_pressed.deinit();
        self.keys_released.deinit();
    }

    /// Call at the start of each frame to clear per-frame state
    pub fn beginFrame(self: *Input) void {
        self.keys_pressed.clearRetainingCapacity();
        self.keys_released.clearRetainingCapacity();
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.mouse_buttons_pressed = .{false} ** 8;
        self.mouse_buttons_released = .{false} ** 8;
    }

    /// Process all pending SDL events
    pub fn pollEvents(self: *Input) void {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            self.processEvent(event);
        }
    }

    fn processEvent(self: *Input, event: c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                self.should_quit = true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                if (!event.key.repeat) {
                    const key = Key.fromSDL(event.key.key);
                    self.keys_down.put(key, {}) catch {};
                    self.keys_pressed.put(key, {}) catch {};
                }
            },
            c.SDL_EVENT_KEY_UP => {
                const key = Key.fromSDL(event.key.key);
                _ = self.keys_down.remove(key);
                self.keys_released.put(key, {}) catch {};
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                self.mouse_x = @intFromFloat(event.motion.x);
                self.mouse_y = @intFromFloat(event.motion.y);
                self.mouse_dx += @intFromFloat(event.motion.xrel);
                self.mouse_dy += @intFromFloat(event.motion.yrel);
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const btn = event.button.button;
                if (btn < 8) {
                    self.mouse_buttons[btn] = true;
                    self.mouse_buttons_pressed[btn] = true;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                const btn = event.button.button;
                if (btn < 8) {
                    self.mouse_buttons[btn] = false;
                    self.mouse_buttons_released[btn] = true;
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                self.scroll_x = event.wheel.x;
                self.scroll_y = event.wheel.y;
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                self.window_width = @intCast(event.window.data1);
                self.window_height = @intCast(event.window.data2);
            },
            else => {},
        }
    }

    // ========================================================================
    // Query methods
    // ========================================================================

    pub fn isKeyDown(self: *const Input, key: Key) bool {
        return self.keys_down.contains(key);
    }

    pub fn isKeyPressed(self: *const Input, key: Key) bool {
        return self.keys_pressed.contains(key);
    }

    pub fn isKeyReleased(self: *const Input, key: Key) bool {
        return self.keys_released.contains(key);
    }

    pub fn isMouseButtonDown(self: *const Input, button: MouseButton) bool {
        const idx = @intFromEnum(button);
        return if (idx < 8) self.mouse_buttons[idx] else false;
    }

    pub fn isMouseButtonPressed(self: *const Input, button: MouseButton) bool {
        const idx = @intFromEnum(button);
        return if (idx < 8) self.mouse_buttons_pressed[idx] else false;
    }

    pub fn getMouseDelta(self: *const Input) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_dx, .y = self.mouse_dy };
    }

    pub fn getMousePosition(self: *const Input) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    /// Capture/release mouse for FPS-style controls
    pub fn setMouseCapture(self: *Input, window: anytype, captured: bool) void {
        self.mouse_captured = captured;
        _ = c.SDL_SetWindowRelativeMouseMode(window, captured);
    }
};
