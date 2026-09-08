pub const collision = @import("collision.zig");

test {
    _ = @import("test_root.zig");
}
pub const VoxelCollisionWorld = collision.VoxelCollisionWorld;
pub const CollisionResult = collision.CollisionResult;
pub const CollisionConfig = collision.CollisionConfig;
pub const moveAndCollide = collision.moveAndCollide;
pub const collidesWithWorld = collision.collidesWithWorld;
pub const isOnGround = collision.isOnGround;
pub const getGroundLevel = collision.getGroundLevel;
