//! Input system interfaces for hardware abstraction and decoupling.
//!
//! Following SOLID principles (specifically DIP and ISP), these interfaces
//! allow gameplay systems to query input state without depending on
//! specific backends like SDL.

const core_interfaces = @import("engine-core").interfaces;
const Key = core_interfaces.Key;
const MouseButton = core_interfaces.MouseButton;

pub const MousePosition = struct { x: i32, y: i32 };
pub const ScrollDelta = struct { x: f32, y: f32 };

pub const MovementVector = struct { x: f32, z: f32 };

/// All logical game actions that can be triggered by input.
/// Gameplay code should query these actions instead of specific keys.
pub const GameAction = enum(u8) {
    move_forward,
    move_backward,
    move_left,
    move_right,
    jump,
    crouch,
    sprint,
    fly,
    interact_primary,
    interact_secondary,
    inventory,
    tab_menu,
    pause,
    slot_1,
    slot_2,
    slot_3,
    slot_4,
    slot_5,
    slot_6,
    slot_7,
    slot_8,
    slot_9,
    toggle_wireframe,
    toggle_textures,
    toggle_vsync,
    toggle_fps,
    toggle_block_info,
    toggle_shadows,
    cycle_cascade,
    toggle_time_scale,
    toggle_creative,
    toggle_debug_menu,
    toggle_map,
    map_zoom_in,
    map_zoom_out,
    map_center,
    ui_confirm,
    ui_back,
    toggle_shadow_debug_vis,
    toggle_timing_overlay,
    toggle_gpass_render,
    toggle_ssao,
    toggle_fog,
    toggle_lpv_overlay,
    toggle_frustum_debug,
    toggle_chunk_inspector,

    pub const count = @typeInfo(GameAction).@"enum".fields.len;
};

/// Represents a physical input that can be bound to an action.
pub const InputBinding = union(enum) {
    key: Key,
    mouse_button: MouseButton,
    key_alt: Key,
    none: void,

    pub fn eql(self: InputBinding, other: InputBinding) bool {
        return switch (self) {
            .key => |k| switch (other) {
                .key => |ok| k == ok,
                else => false,
            },
            .key_alt => |k| switch (other) {
                .key_alt => |ok| k == ok,
                else => false,
            },
            .mouse_button => |mb| switch (other) {
                .mouse_button => |omb| mb == omb,
                else => false,
            },
            .none => switch (other) {
                .none => true,
                else => false,
            },
        };
    }

    pub fn getName(self: InputBinding) []const u8 {
        return switch (self) {
            .key, .key_alt => |k| keyToString(k),
            .mouse_button => |mb| switch (mb) {
                .left => "Left Click",
                .middle => "Middle Click",
                .right => "Right Click",
                _ => "Mouse Button",
            },
            .none => "Unbound",
        };
    }

    fn keyToString(key: Key) []const u8 {
        return switch (key) {
            .a => "A",
            .b => "B",
            .c => "C",
            .d => "D",
            .e => "E",
            .f => "F",
            .g => "G",
            .h => "H",
            .i => "I",
            .j => "J",
            .k => "K",
            .l => "L",
            .m => "M",
            .n => "N",
            .o => "O",
            .p => "P",
            .q => "Q",
            .r => "R",
            .s => "S",
            .t => "T",
            .u => "U",
            .v => "V",
            .w => "W",
            .x => "X",
            .y => "Y",
            .z => "Z",
            .@"0" => "0",
            .@"1" => "1",
            .@"2" => "2",
            .@"3" => "3",
            .@"4" => "4",
            .@"5" => "5",
            .@"6" => "6",
            .@"7" => "7",
            .@"8" => "8",
            .@"9" => "9",
            .space => "Space",
            .escape => "Escape",
            .enter => "Enter",
            .tab => "Tab",
            .backspace => "Backspace",
            .plus => "+",
            .minus => "-",
            .kp_plus => "Numpad +",
            .kp_minus => "Numpad -",
            .up => "Up",
            .down => "Down",
            .left_arrow => "Left",
            .right_arrow => "Right",
            .left_shift => "Left Shift",
            .right_shift => "Right Shift",
            .left_ctrl => "Left Ctrl",
            .right_ctrl => "Right Ctrl",
            .f1 => "F1",
            .f2 => "F2",
            .f3 => "F3",
            .f4 => "F4",
            .f5 => "F5",
            .f6 => "F6",
            .f7 => "F7",
            .f8 => "F8",
            .f9 => "F9",
            .f10 => "F10",
            .f11 => "F11",
            .f12 => "F12",
            else => "Unknown",
        };
    }
};

pub const ActionBinding = struct {
    primary: InputBinding,
    alternate: InputBinding,

    pub fn init(primary: InputBinding) ActionBinding {
        return .{ .primary = primary, .alternate = .{ .none = {} } };
    }

    pub fn initWithAlt(primary: InputBinding, alternate: InputBinding) ActionBinding {
        return .{ .primary = primary, .alternate = alternate };
    }
};

pub const IRawInputProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isKeyDown: *const fn (ptr: *anyopaque, key: Key) bool,
        isKeyPressed: *const fn (ptr: *anyopaque, key: Key) bool,
        isKeyReleased: *const fn (ptr: *anyopaque, key: Key) bool,
        isMouseButtonDown: *const fn (ptr: *anyopaque, button: MouseButton) bool,
        isMouseButtonPressed: *const fn (ptr: *anyopaque, button: MouseButton) bool,
        isMouseButtonReleased: *const fn (ptr: *anyopaque, button: MouseButton) bool,
        getMouseDelta: *const fn (ptr: *anyopaque) MousePosition,
        getMousePosition: *const fn (ptr: *anyopaque) MousePosition,
        getScrollDelta: *const fn (ptr: *anyopaque) ScrollDelta,
        getWindowWidth: *const fn (ptr: *anyopaque) u32,
        getWindowHeight: *const fn (ptr: *anyopaque) u32,
        shouldQuit: *const fn (ptr: *anyopaque) bool,
        setShouldQuit: *const fn (ptr: *anyopaque, quit: bool) void,
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

    pub fn isMouseButtonReleased(self: IRawInputProvider, button: MouseButton) bool {
        return self.vtable.isMouseButtonReleased(self.ptr, button);
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

    pub fn getWindowWidth(self: IRawInputProvider) u32 {
        return self.vtable.getWindowWidth(self.ptr);
    }

    pub fn getWindowHeight(self: IRawInputProvider) u32 {
        return self.vtable.getWindowHeight(self.ptr);
    }

    pub fn shouldQuit(self: IRawInputProvider) bool {
        return self.vtable.shouldQuit(self.ptr);
    }

    pub fn setShouldQuit(self: IRawInputProvider, quit: bool) void {
        self.vtable.setShouldQuit(self.ptr, quit);
    }

    pub fn isMouseCaptured(self: IRawInputProvider) bool {
        return self.vtable.isMouseCaptured(self.ptr);
    }

    pub fn setMouseCapture(self: IRawInputProvider, window: ?*anyopaque, captured: bool) void {
        self.vtable.setMouseCapture(self.ptr, window, captured);
    }
};

pub const IInputMapper = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getBinding: *const fn (ptr: *const anyopaque, action: GameAction) ActionBinding,
        isActionActive: *const fn (ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool,
        isActionPressed: *const fn (ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool,
        isActionReleased: *const fn (ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool,
        getMovementVector: *const fn (ptr: *const anyopaque, input: IRawInputProvider) MovementVector,
    };

    pub fn getBinding(self: IInputMapper, action: GameAction) ActionBinding {
        return self.vtable.getBinding(self.ptr, action);
    }

    pub fn isActionActive(self: IInputMapper, input: IRawInputProvider, action: GameAction) bool {
        return self.vtable.isActionActive(self.ptr, input, action);
    }

    pub fn isActionPressed(self: IInputMapper, input: IRawInputProvider, action: GameAction) bool {
        return self.vtable.isActionPressed(self.ptr, input, action);
    }

    pub fn isActionReleased(self: IInputMapper, input: IRawInputProvider, action: GameAction) bool {
        return self.vtable.isActionReleased(self.ptr, input, action);
    }

    pub fn getMovementVector(self: IInputMapper, input: IRawInputProvider) MovementVector {
        return self.vtable.getMovementVector(self.ptr, input);
    }
};
