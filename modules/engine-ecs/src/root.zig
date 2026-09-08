pub const components = @import("components.zig");

test {
    _ = @import("test_root.zig");
}
pub const ecs_tests = @import("ecs_tests.zig");
pub const entity = @import("entity.zig");
pub const manager = @import("manager.zig");
pub const storage = @import("storage.zig");
pub const systems = struct {
    pub const physics = @import("systems/physics.zig");
    pub const render = @import("systems/render.zig");
};

pub const ComponentStorage = storage.ComponentStorage;
pub const EntityId = entity.EntityId;
pub const Mesh = components.Mesh;
pub const Physics = components.Physics;
pub const PhysicsSystem = systems.physics.PhysicsSystem;
pub const Registry = manager.Registry;
pub const RenderSystem = systems.render.RenderSystem;
pub const Transform = components.Transform;
