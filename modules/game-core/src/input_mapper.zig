//! Input mapper - abstracts raw input into game actions with configurable bindings.
//!
//! This module provides a hardware-agnostic input abstraction layer that:
//! - Maps physical inputs (keys, mouse buttons) to logical game actions
//! - Supports runtime key rebinding
//! - Enables settings persistence for user-customized controls

const std = @import("std");
const input_interfaces = @import("engine-input");
const IRawInputProvider = input_interfaces.IRawInputProvider;

pub const ActionBinding = input_interfaces.ActionBinding;
pub const GameAction = input_interfaces.GameAction;
pub const IInputMapper = input_interfaces.IInputMapper;
pub const InputBinding = input_interfaces.InputBinding;
pub const MovementVector = input_interfaces.MovementVector;

/// Default bindings for all actions. Stored as a static array to avoid heap allocation.
pub const DEFAULT_BINDINGS = blk: {
    var bindings = [_]ActionBinding{ActionBinding.init(.{ .none = {} })} ** GameAction.count;

    // Movement
    bindings[@intFromEnum(GameAction.move_forward)] = ActionBinding.init(.{ .key = .w });
    bindings[@intFromEnum(GameAction.move_backward)] = ActionBinding.init(.{ .key = .s });
    bindings[@intFromEnum(GameAction.move_left)] = ActionBinding.init(.{ .key = .a });
    bindings[@intFromEnum(GameAction.move_right)] = ActionBinding.init(.{ .key = .d });
    bindings[@intFromEnum(GameAction.jump)] = ActionBinding.init(.{ .key = .space });
    bindings[@intFromEnum(GameAction.crouch)] = ActionBinding.init(.{ .key = .left_shift });
    bindings[@intFromEnum(GameAction.sprint)] = ActionBinding.init(.{ .key = .left_ctrl });
    bindings[@intFromEnum(GameAction.fly)] = ActionBinding.init(.{ .none = {} });

    // Interaction
    bindings[@intFromEnum(GameAction.interact_primary)] = ActionBinding.init(.{ .mouse_button = .left });
    bindings[@intFromEnum(GameAction.interact_secondary)] = ActionBinding.init(.{ .mouse_button = .right });

    // UI/Menu
    bindings[@intFromEnum(GameAction.inventory)] = ActionBinding.init(.{ .key = .i });
    bindings[@intFromEnum(GameAction.tab_menu)] = ActionBinding.init(.{ .key = .tab });
    bindings[@intFromEnum(GameAction.pause)] = ActionBinding.init(.{ .key = .escape });

    // Hotbar slots
    bindings[@intFromEnum(GameAction.slot_1)] = ActionBinding.init(.{ .key = .@"1" });
    bindings[@intFromEnum(GameAction.slot_2)] = ActionBinding.init(.{ .key = .@"2" });
    bindings[@intFromEnum(GameAction.slot_3)] = ActionBinding.init(.{ .key = .@"3" });
    bindings[@intFromEnum(GameAction.slot_4)] = ActionBinding.init(.{ .key = .@"4" });
    bindings[@intFromEnum(GameAction.slot_5)] = ActionBinding.init(.{ .key = .@"5" });
    bindings[@intFromEnum(GameAction.slot_6)] = ActionBinding.init(.{ .key = .@"6" });
    bindings[@intFromEnum(GameAction.slot_7)] = ActionBinding.init(.{ .key = .@"7" });
    bindings[@intFromEnum(GameAction.slot_8)] = ActionBinding.init(.{ .key = .@"8" });
    bindings[@intFromEnum(GameAction.slot_9)] = ActionBinding.init(.{ .key = .@"9" });

    // Debug toggles
    bindings[@intFromEnum(GameAction.toggle_wireframe)] = ActionBinding.init(.{ .key = .f });
    bindings[@intFromEnum(GameAction.toggle_textures)] = ActionBinding.init(.{ .key = .t });
    bindings[@intFromEnum(GameAction.toggle_vsync)] = ActionBinding.init(.{ .key = .v });
    bindings[@intFromEnum(GameAction.toggle_fps)] = ActionBinding.init(.{ .key = .f2 });
    bindings[@intFromEnum(GameAction.toggle_block_info)] = ActionBinding.init(.{ .key = .f5 });
    bindings[@intFromEnum(GameAction.toggle_shadows)] = ActionBinding.init(.{ .key = .u });
    bindings[@intFromEnum(GameAction.toggle_shadow_debug_vis)] = ActionBinding.init(.{ .key = .g });
    bindings[@intFromEnum(GameAction.cycle_cascade)] = ActionBinding.init(.{ .key = .k });
    bindings[@intFromEnum(GameAction.toggle_time_scale)] = ActionBinding.init(.{ .key = .n });
    bindings[@intFromEnum(GameAction.toggle_creative)] = ActionBinding.init(.{ .key = .f12 });
    bindings[@intFromEnum(GameAction.toggle_debug_menu)] = ActionBinding.init(.{ .key = .f3 });
    bindings[@intFromEnum(GameAction.toggle_timing_overlay)] = ActionBinding.init(.{ .key = .f4 });
    bindings[@intFromEnum(GameAction.toggle_gpass_render)] = ActionBinding.init(.{ .key = .f7 });
    bindings[@intFromEnum(GameAction.toggle_ssao)] = ActionBinding.init(.{ .key = .f8 });
    bindings[@intFromEnum(GameAction.toggle_fog)] = ActionBinding.init(.{ .key = .f10 });
    bindings[@intFromEnum(GameAction.toggle_lpv_overlay)] = ActionBinding.init(.{ .key = .f11 });
    bindings[@intFromEnum(GameAction.toggle_frustum_debug)] = ActionBinding.init(.{ .key = .h });
    bindings[@intFromEnum(GameAction.toggle_chunk_inspector)] = ActionBinding.init(.{ .key = .j });

    // Map controls
    bindings[@intFromEnum(GameAction.toggle_map)] = ActionBinding.init(.{ .key = .m });
    bindings[@intFromEnum(GameAction.map_zoom_in)] = ActionBinding.initWithAlt(.{ .key = .plus }, .{ .key_alt = .kp_plus });
    bindings[@intFromEnum(GameAction.map_zoom_out)] = ActionBinding.initWithAlt(.{ .key = .minus }, .{ .key_alt = .kp_minus });
    bindings[@intFromEnum(GameAction.map_center)] = ActionBinding.init(.{ .key = .space });

    // UI navigation
    bindings[@intFromEnum(GameAction.ui_confirm)] = ActionBinding.init(.{ .key = .enter });
    bindings[@intFromEnum(GameAction.ui_back)] = ActionBinding.init(.{ .key = .escape });

    break :blk bindings;
};

/// Input mapper that translates physical inputs to logical game actions.
pub const InputMapper = struct {
    /// Current bindings for all actions
    bindings: [GameAction.count]ActionBinding,

    /// Initialize a new InputMapper with default bindings.
    pub fn init() InputMapper {
        return .{
            .bindings = DEFAULT_BINDINGS,
        };
    }

    /// Reset all bindings to their default values.
    pub fn resetToDefaults(self: *InputMapper) void {
        self.bindings = DEFAULT_BINDINGS;
    }

    /// Reset an individual action to its default value.
    pub fn resetActionToDefault(self: *InputMapper, action: GameAction) void {
        self.bindings[@intFromEnum(action)] = DEFAULT_BINDINGS[@intFromEnum(action)];
    }

    /// Set a new binding for an action.
    pub fn setBinding(self: *InputMapper, action: GameAction, binding: InputBinding) void {
        self.bindings[@intFromEnum(action)].primary = binding;
    }

    /// Set an alternate binding for an action.
    pub fn setAlternateBinding(self: *InputMapper, action: GameAction, binding: InputBinding) void {
        self.bindings[@intFromEnum(action)].alternate = binding;
    }

    /// Get the current binding for an action.
    pub fn getBinding(self: *const InputMapper, action: GameAction) ActionBinding {
        return self.bindings[@intFromEnum(action)];
    }

    /// Check if a continuous/held action is currently active (e.g., movement).
    pub fn isActionActive(self: *const InputMapper, input: IRawInputProvider, action: GameAction) bool {
        const binding = self.bindings[@intFromEnum(action)];
        return self.isBindingStateActive(input, binding.primary) or self.isBindingStateActive(input, binding.alternate);
    }

    /// Check if a trigger action was pressed this frame (e.g., jump, toggle).
    pub fn isActionPressed(self: *const InputMapper, input: IRawInputProvider, action: GameAction) bool {
        const binding = self.bindings[@intFromEnum(action)];
        return self.isBindingStatePressed(input, binding.primary) or self.isBindingStatePressed(input, binding.alternate);
    }

    /// Check if an action was released this frame.
    pub fn isActionReleased(self: *const InputMapper, input: IRawInputProvider, action: GameAction) bool {
        const binding = self.bindings[@intFromEnum(action)];
        return self.isBindingStateReleased(input, binding.primary) or self.isBindingStateReleased(input, binding.alternate);
    }

    fn isBindingStateActive(self: *const InputMapper, input: IRawInputProvider, binding: InputBinding) bool {
        _ = self;
        return switch (binding) {
            .key, .key_alt => |k| input.isKeyDown(k),
            .mouse_button => |mb| input.isMouseButtonDown(mb),
            .none => false,
        };
    }

    fn isBindingStatePressed(self: *const InputMapper, input: IRawInputProvider, binding: InputBinding) bool {
        _ = self;
        return switch (binding) {
            .key, .key_alt => |k| input.isKeyPressed(k),
            .mouse_button => |mb| input.isMouseButtonPressed(mb),
            .none => false,
        };
    }

    fn isBindingStateReleased(self: *const InputMapper, input: IRawInputProvider, binding: InputBinding) bool {
        _ = self;
        return switch (binding) {
            .key, .key_alt => |k| input.isKeyReleased(k),
            .mouse_button => |mb| input.isMouseButtonReleased(mb),
            .none => false,
        };
    }

    /// Get movement vector based on current bindings.
    pub fn getMovementVector(self: *const InputMapper, input: IRawInputProvider) MovementVector {
        var x: f32 = 0;
        var z: f32 = 0;
        if (self.isActionActive(input, .move_forward)) z += 1;
        if (self.isActionActive(input, .move_backward)) z -= 1;
        if (self.isActionActive(input, .move_left)) x -= 1;
        if (self.isActionActive(input, .move_right)) x += 1;
        return .{ .x = x, .z = z };
    }

    // ========================================================================
    // Serialization
    // ========================================================================

    /// Serialize bindings to a JSON string.
    pub fn serialize(self: *const InputMapper, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buffer);
        defer aw.deinit();

        try std.json.Stringify.value(self.bindings, .{}, &aw.writer);
        return aw.toOwnedSlice();
    }

    /// Deserialize bindings from JSON data.
    pub fn deserialize(self: *InputMapper, allocator: std.mem.Allocator, data: []const u8) !void {
        var parsed = try std.json.parseFromSlice([GameAction.count]ActionBinding, allocator, data, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        @memcpy(&self.bindings, &parsed.value);
    }

    // ========================================================================
    // IInputMapper Implementation
    // ========================================================================

    pub fn interface(self: *const InputMapper) IInputMapper {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = IInputMapper.VTable{
        .getBinding = impl_getBinding,
        .isActionActive = impl_isActionActive,
        .isActionPressed = impl_isActionPressed,
        .isActionReleased = impl_isActionReleased,
        .getMovementVector = impl_getMovementVector,
    };

    fn impl_getBinding(ptr: *const anyopaque, action: GameAction) ActionBinding {
        const self: *const InputMapper = @ptrCast(@alignCast(ptr));
        return self.getBinding(action);
    }

    fn impl_isActionActive(ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool {
        const self: *const InputMapper = @ptrCast(@alignCast(ptr));
        return self.isActionActive(input, action);
    }

    fn impl_isActionPressed(ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool {
        const self: *const InputMapper = @ptrCast(@alignCast(ptr));
        return self.isActionPressed(input, action);
    }

    fn impl_isActionReleased(ptr: *const anyopaque, input: IRawInputProvider, action: GameAction) bool {
        const self: *const InputMapper = @ptrCast(@alignCast(ptr));
        return self.isActionReleased(input, action);
    }

    fn impl_getMovementVector(ptr: *const anyopaque, input: IRawInputProvider) MovementVector {
        const self: *const InputMapper = @ptrCast(@alignCast(ptr));
        return self.getMovementVector(input);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "InputMapper serialization" {
    const allocator = std.testing.allocator;
    var mapper = InputMapper.init();
    mapper.setBinding(.jump, .{ .key = .up });

    const json = try mapper.serialize(allocator);
    defer allocator.free(json);

    var restored = InputMapper.init();
    try restored.deserialize(allocator, json);

    try std.testing.expect(restored.getBinding(.jump).primary.key == .up);
}

test "InputBinding equality" {
    const b1 = InputBinding{ .key = .w };
    const b2 = InputBinding{ .key_alt = .w };
    const b3 = InputBinding{ .key = .s };
    const b4 = InputBinding{ .key_alt = .w };

    try std.testing.expect(!b1.eql(b2));
    try std.testing.expect(!b2.eql(b1));
    try std.testing.expect(!b1.eql(b3));
    try std.testing.expect(b2.eql(b4));
}

test "InputMapper resetActionToDefault" {
    var mapper = InputMapper.init();
    mapper.setBinding(.move_forward, .{ .key = .up });
    try std.testing.expect(mapper.getBinding(.move_forward).primary.key == .up);

    mapper.resetActionToDefault(.move_forward);
    try std.testing.expect(mapper.getBinding(.move_forward).primary.key == .w);
}

test "InputMapper binds the timing overlay to F4 by default" {
    const mapper = InputMapper.init();
    const binding = mapper.getBinding(.toggle_timing_overlay);

    try std.testing.expect(binding.primary == .key);
    try std.testing.expectEqual(.f4, binding.primary.key);
}
