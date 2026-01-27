const std = @import("std");
const core_interfaces = @import("../core/interfaces.zig");
const Key = core_interfaces.Key;
const MouseButton = core_interfaces.MouseButton;

pub const MousePosition = struct { x: i32, y: i32 };
pub const ScrollDelta = struct { x: f32, y: f32 };

pub const IRawInputProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isKeyDown: *const fn (ptr: *anyopaque, key: Key) bool,
        isKeyPressed: *const fn (ptr: *anyopaque, key: Key) bool,
        isKeyReleased: *const fn (ptr: *anyopaque, key: Key) bool,
        isMouseButtonDown: *const fn (ptr: *anyopaque, button: MouseButton) bool,
        isMouseButtonPressed: *const fn (ptr: *anyopaque, button: MouseButton) bool,
        getMouseDelta: *const fn (ptr: *anyopaque) MousePosition,
        getMousePosition: *const fn (ptr: *anyopaque) MousePosition,
        getScrollDelta: *const fn (ptr: *anyopaque) ScrollDelta,
        isMouseCaptured: *const fn (ptr: *anyopaque) bool,
        setMouseCapture: *const fn (ptr: *anyopaque, window: ?*anyopaque, captured: bool) void,
    };

    pub fn isKeyDown(self: IRawInputProvider, key: Key) bool {
        return self.vtable.isKeyDown(self.ptr, key);
    }

    pub fn isKeyPressed(self: IRawInputProvider, key: Key) bool {
        return self.vtable.isKeyPressed(self.ptr, key);
    }

    pub fn isKeyReleased(self: IRawInputProvider, key: Key) bool {
        return self.vtable.isKeyReleased(self.ptr, key);
    }

    pub fn isMouseButtonDown(self: IRawInputProvider, button: MouseButton) bool {
        return self.vtable.isMouseButtonDown(self.ptr, button);
    }

    pub fn isMouseButtonPressed(self: IRawInputProvider, button: MouseButton) bool {
        return self.vtable.isMouseButtonPressed(self.ptr, button);
    }

    pub fn getMouseDelta(self: IRawInputProvider) MousePosition {
        return self.vtable.getMouseDelta(self.ptr);
    }

    pub fn getMousePosition(self: IRawInputProvider) MousePosition {
        return self.vtable.getMousePosition(self.ptr);
    }

    pub fn getScrollDelta(self: IRawInputProvider) ScrollDelta {
        return self.vtable.getScrollDelta(self.ptr);
    }

    pub fn isMouseCaptured(self: IRawInputProvider) bool {
        return self.vtable.isMouseCaptured(self.ptr);
    }

    pub fn setMouseCapture(self: IRawInputProvider, window: ?*anyopaque, captured: bool) void {
        self.vtable.setMouseCapture(self.ptr, window, captured);
    }
};
