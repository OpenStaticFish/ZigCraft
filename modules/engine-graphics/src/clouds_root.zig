pub const cloud_interface = @import("cloud_interface.zig");

test {
    _ = @import("clouds_test_root.zig");
}
pub const cloud_system = @import("cloud_system.zig");

pub const CloudConfig = cloud_system.CloudConfig;
pub const CloudSystem = cloud_system.CloudSystem;
pub const ICloudSystem = cloud_interface.ICloudSystem;
