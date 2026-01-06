//! Core engine interfaces following SOLID principles.
//! These abstractions allow for dependency inversion and extensibility.

const std = @import("std");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

/// Interface for anything that updates each frame
pub const IUpdatable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, delta_time: f32) void,
    };

    pub fn update(self: IUpdatable, delta_time: f32) void {
        self.vtable.update(self.ptr, delta_time);
    }
};

/// Interface for anything that can be rendered
pub const IRenderable = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, view_proj: Mat4) void,
    };

    pub fn render(self: IRenderable, view_proj: Mat4) void {
        self.vtable.render(self.ptr, view_proj);
    }
};

/// Interface for anything that handles input events
pub const IInputHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handleInput: *const fn (ptr: *anyopaque, event: InputEvent) bool,
    };

    pub fn handleInput(self: IInputHandler, event: InputEvent) bool {
        return self.vtable.handleInput(self.ptr, event);
    }
};

/// Interface for UI widgets
pub const IWidget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        draw: *const fn (ptr: *anyopaque) void,
        handleInput: *const fn (ptr: *anyopaque, event: InputEvent) bool,
        getBounds: *const fn (ptr: *anyopaque) Rect,
    };

    pub fn draw(self: IWidget) void {
        self.vtable.draw(self.ptr);
    }

    pub fn handleInput(self: IWidget, event: InputEvent) bool {
        return self.vtable.handleInput(self.ptr, event);
    }

    pub fn getBounds(self: IWidget) Rect {
        return self.vtable.getBounds(self.ptr);
    }
};

/// Interface for chunk data providers (world generation abstraction)
pub const IChunkProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        generateChunk: *const fn (ptr: *anyopaque, chunk_x: i32, chunk_z: i32, out_blocks: []u8) void,
    };

    pub fn generateChunk(self: IChunkProvider, chunk_x: i32, chunk_z: i32, out_blocks: []u8) void {
        self.vtable.generateChunk(self.ptr, chunk_x, chunk_z, out_blocks);
    }
};

/// Interface for mesh generation strategies (greedy, naive, etc.)
pub const IMeshBuilder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        buildMesh: *const fn (ptr: *anyopaque, blocks: []const u8, out_vertices: *std.ArrayList(f32), out_indices: *std.ArrayList(u32)) void,
    };

    pub fn buildMesh(self: IMeshBuilder, blocks: []const u8, out_vertices: *std.ArrayList(f32), out_indices: *std.ArrayList(u32)) void {
        self.vtable.buildMesh(self.ptr, blocks, out_vertices, out_indices);
    }
};

// ============================================================================
// Common Types
// ============================================================================

pub const InputEvent = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    mouse_motion: MouseMotionEvent,
    mouse_button_down: MouseButtonEvent,
    mouse_button_up: MouseButtonEvent,
    mouse_scroll: MouseScrollEvent,
    window_resize: WindowResizeEvent,
    quit: void,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const MouseMotionEvent = struct {
    x: i32,
    y: i32,
    dx: i32,
    dy: i32,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    x: i32,
    y: i32,
};

pub const MouseScrollEvent = struct {
    dx: f32,
    dy: f32,
};

pub const WindowResizeEvent = struct {
    width: u32,
    height: u32,
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    _,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    _padding: u5 = 0,
};

pub const Key = enum(u32) {
    unknown = 0,

    // Letters
    a = 'a',
    b = 'b',
    c = 'c',
    d = 'd',
    e = 'e',
    f = 'f',
    g = 'g',
    h = 'h',
    i = 'i',
    j = 'j',
    k = 'k',
    l = 'l',
    m = 'm',
    n = 'n',
    o = 'o',
    p = 'p',
    q = 'q',
    r = 'r',
    s = 's',
    t = 't',
    u = 'u',
    v = 'v',
    w = 'w',
    x = 'x',
    y = 'y',
    z = 'z',

    // Numbers
    @"0" = '0',
    @"1" = '1',
    @"2" = '2',
    @"3" = '3',
    @"4" = '4',
    @"5" = '5',
    @"6" = '6',
    @"7" = '7',
    @"8" = '8',
    @"9" = '9',

    // Special keys
    space = ' ',
    escape = 27,
    enter = 13,
    tab = 9,
    backspace = 8,
    plus = '=',
    minus = '-',
    kp_plus = 0x40000057,
    kp_minus = 0x40000056,

    // Arrow keys (using SDL scancodes offset)
    up = 0x40000052,
    down = 0x40000051,
    left_arrow = 0x40000050,
    right_arrow = 0x4000004F,

    // Modifiers
    left_shift = 0x400000E1,
    right_shift = 0x400000E5,
    left_ctrl = 0x400000E0,
    right_ctrl = 0x400000E4,

    // Function keys
    f1 = 0x4000003a,
    f2 = 0x4000003b,
    f3 = 0x4000003c,
    f4 = 0x4000003d,
    f5 = 0x4000003e,
    f6 = 0x4000003f,
    f7 = 0x40000040,
    f8 = 0x40000041,
    f9 = 0x40000042,
    f10 = 0x40000043,
    f11 = 0x40000044,
    f12 = 0x40000045,

    _,

    pub fn fromSDL(sdl_key: u32) Key {
        return @enumFromInt(sdl_key);
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};
