pub const input = @import("input.zig");

test {
    _ = @import("test_root.zig");
}
pub const interfaces = @import("interfaces.zig");
pub const input_tests = @import("input_tests.zig");

pub const Input = input.Input;
pub const RawEventProcessor = input.RawEventProcessor;
pub const ActionBinding = interfaces.ActionBinding;
pub const GameAction = interfaces.GameAction;
pub const IInputMapper = interfaces.IInputMapper;
pub const IRawInputProvider = interfaces.IRawInputProvider;
pub const InputBinding = interfaces.InputBinding;
pub const MousePosition = interfaces.MousePosition;
pub const MovementVector = interfaces.MovementVector;
pub const ScrollDelta = interfaces.ScrollDelta;
