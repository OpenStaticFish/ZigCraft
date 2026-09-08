pub const csm = @import("csm.zig");

test {
    _ = @import("shadows_test_root.zig");
}
pub const shadow_scene = @import("shadow_scene.zig");
pub const shadow_system = @import("shadow_system.zig");
pub const shadow_cascade_tests = @import("shadow_cascade_tests.zig");
pub const shadow_system_tests = @import("shadow_system_tests.zig");

pub const IShadowScene = @import("engine-rhi").IShadowScene;
pub const CASCADE_COUNT = csm.CASCADE_COUNT;
pub const ShadowCascades = csm.ShadowCascades;
pub const ShadowSystem = shadow_system.ShadowSystem;
pub const computeCascades = csm.computeCascades;
pub const computeCascadesWithCamera = csm.computeCascadesWithCamera;
pub const practicalSplit = csm.practicalSplit;
pub const validateCascades = csm.validateCascades;
