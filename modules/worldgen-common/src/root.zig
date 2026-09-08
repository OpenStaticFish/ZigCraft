pub const lighting_computer = @import("lighting_computer.zig");

test {
    _ = @import("test_root.zig");
}
pub const lighting_interface = @import("lighting_interface.zig");

pub const ILightingSystem = lighting_interface.ILightingSystem;
pub const LightingComputer = lighting_computer.LightingComputer;
