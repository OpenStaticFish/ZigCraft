const impl = @import("engine-shadows-impl");

pub const csm = impl.csm;
pub const shadow_scene = impl.shadow_scene;
pub const shadow_system = impl.shadow_system;
pub const shadow_cascade_tests = impl.shadow_cascade_tests;
pub const shadow_system_tests = impl.shadow_system_tests;

pub const IShadowScene = @import("engine-rhi").IShadowScene;
pub const CASCADE_COUNT = csm.CASCADE_COUNT;
pub const ShadowCascades = csm.ShadowCascades;
pub const ShadowSystem = shadow_system.ShadowSystem;
pub const computeCascades = csm.computeCascades;
pub const computeCascadesWithCamera = csm.computeCascadesWithCamera;
pub const practicalSplit = csm.practicalSplit;
pub const validateCascades = csm.validateCascades;
