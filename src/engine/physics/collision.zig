//! Voxel world collision detection and resolution.
//!
//! Provides AABB-based collision detection against the voxel world,
//! with separate axis resolution for smooth movement.

const std = @import("std");
const math = @import("zig-math");
const Vec3 = math.Vec3;
const AABB = math.AABB;
const World = @import("../../world/world.zig").World;
const BlockType = @import("../../world/block.zig").BlockType;

/// Result of collision detection and resolution.
pub const CollisionResult = struct {
    /// The resolved position after collision
    position: Vec3,
    /// The resolved velocity (components zeroed on collision)
    velocity: Vec3,
    /// Whether the entity is standing on solid ground
    grounded: bool,
    /// Whether the entity hit a ceiling
    hit_ceiling: bool,
    /// Whether the entity hit a wall (X or Z collision)
    hit_wall: bool,
};

/// Configuration for collision detection.
pub const CollisionConfig = struct {
    /// Small epsilon to prevent floating point issues at block boundaries
    epsilon: f32 = 0.001,
    /// Maximum number of iterations for collision resolution
    max_iterations: u32 = 4,
};

/// Move an AABB through the world, detecting and resolving collisions.
///
/// Uses the "separate axes" approach:
/// 1. Move along Y axis first (for proper ground detection)
/// 2. Then X axis
/// 3. Then Z axis
///
/// This prevents corner-cutting and provides stable collision resolution.
pub fn moveAndCollide(
    world: *World,
    aabb: AABB,
    velocity: Vec3,
    delta_time: f32,
    config: CollisionConfig,
) CollisionResult {
    var result = CollisionResult{
        .position = aabb.center(),
        .velocity = velocity,
        .grounded = false,
        .hit_ceiling = false,
        .hit_wall = false,
    };

    const half_size = aabb.size().scale(0.5);
    var pos = aabb.center();
    var vel = velocity;

    // Calculate movement this frame
    const move = vel.scale(delta_time);

    // Resolve Y axis first (gravity/jumping)
    if (@abs(move.y) > config.epsilon) {
        const new_y = pos.y + move.y;
        const test_aabb = AABB.fromCenterSize(
            Vec3.init(pos.x, new_y, pos.z),
            aabb.size(),
        );

        if (collidesWithWorld(world, test_aabb)) {
            // Find the exact collision point
            const resolved_y = resolveAxis(world, pos, half_size, move.y, 1, config.epsilon);
            pos.y = resolved_y;

            if (move.y < 0) {
                result.grounded = true;
            } else {
                result.hit_ceiling = true;
            }
            vel.y = 0;
        } else {
            pos.y = new_y;
        }
    }

    // Resolve X axis
    if (@abs(move.x) > config.epsilon) {
        const new_x = pos.x + move.x;
        const test_aabb = AABB.fromCenterSize(
            Vec3.init(new_x, pos.y, pos.z),
            aabb.size(),
        );

        if (collidesWithWorld(world, test_aabb)) {
            const resolved_x = resolveAxis(world, pos, half_size, move.x, 0, config.epsilon);
            pos.x = resolved_x;
            vel.x = 0;
            result.hit_wall = true;
        } else {
            pos.x = new_x;
        }
    }

    // Resolve Z axis
    if (@abs(move.z) > config.epsilon) {
        const new_z = pos.z + move.z;
        const test_aabb = AABB.fromCenterSize(
            Vec3.init(pos.x, pos.y, new_z),
            aabb.size(),
        );

        if (collidesWithWorld(world, test_aabb)) {
            const resolved_z = resolveAxis(world, pos, half_size, move.z, 2, config.epsilon);
            pos.z = resolved_z;
            vel.z = 0;
            result.hit_wall = true;
        } else {
            pos.z = new_z;
        }
    }

    result.position = pos;
    result.velocity = vel;

    return result;
}

/// Resolve collision along a single axis using binary search.
fn resolveAxis(
    world: *World,
    pos: Vec3,
    half_size: Vec3,
    movement: f32,
    axis: u2,
    epsilon: f32,
) f32 {
    var current = switch (axis) {
        0 => pos.x,
        1 => pos.y,
        2 => pos.z,
        else => unreachable,
    };
    var target = current + movement;
    const dir: f32 = if (movement > 0) 1.0 else -1.0;

    // Binary search to find the furthest valid position
    var iterations: u32 = 0;
    while (@abs(target - current) > epsilon and iterations < 16) : (iterations += 1) {
        const mid = (current + target) * 0.5;
        const test_pos = switch (axis) {
            0 => Vec3.init(mid, pos.y, pos.z),
            1 => Vec3.init(pos.x, mid, pos.z),
            2 => Vec3.init(pos.x, pos.y, mid),
            else => unreachable,
        };
        const test_aabb = AABB.fromCenterSize(test_pos, half_size.scale(2.0));

        if (collidesWithWorld(world, test_aabb)) {
            target = mid;
        } else {
            current = mid;
        }
    }

    // Push back slightly from the collision surface
    return current - dir * epsilon;
}

/// Check if an AABB collides with any solid blocks in the world.
pub fn collidesWithWorld(world: *World, aabb: AABB) bool {
    // Get block coordinate range that the AABB overlaps
    const min_x: i32 = @intFromFloat(@floor(aabb.min.x));
    const min_y: i32 = @intFromFloat(@floor(aabb.min.y));
    const min_z: i32 = @intFromFloat(@floor(aabb.min.z));
    const max_x: i32 = @intFromFloat(@floor(aabb.max.x));
    const max_y: i32 = @intFromFloat(@floor(aabb.max.y));
    const max_z: i32 = @intFromFloat(@floor(aabb.max.z));

    // Check all blocks in the range
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var z = min_z;
        while (z <= max_z) : (z += 1) {
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                const block = world.getBlock(x, y, z);
                if (block.isSolid()) {
                    // Create block AABB and test intersection
                    const block_aabb = AABB.init(
                        Vec3.init(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z)),
                        Vec3.init(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(z + 1)),
                    );
                    if (aabb.intersects(block_aabb)) {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

/// Check if the entity is standing on solid ground.
/// Tests a thin slab just below the AABB.
pub fn isOnGround(world: *World, aabb: AABB) bool {
    // Create a thin AABB just below the entity
    const ground_test = AABB.init(
        Vec3.init(aabb.min.x + 0.01, aabb.min.y - 0.05, aabb.min.z + 0.01),
        Vec3.init(aabb.max.x - 0.01, aabb.min.y, aabb.max.z - 0.01),
    );

    return collidesWithWorld(world, ground_test);
}

/// Get the highest solid Y coordinate at a world XZ position.
/// Useful for spawning the player.
pub fn getGroundLevel(world: *World, x: f32, z: f32) i32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));

    // Search from top down
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const block = world.getBlock(ix, y, iz);
        if (block.isSolid()) {
            return y + 1; // Return the position above the solid block
        }
    }

    return 0;
}

// ============================================================================
// Tests
// ============================================================================

// Note: Full collision tests require a World instance, which is complex to set up.
// These are basic unit tests for the helper functions.

test "AABB block overlap calculation" {
    const aabb = AABB.init(
        Vec3.init(0.5, 0.5, 0.5),
        Vec3.init(1.5, 1.5, 1.5),
    );

    // This AABB should overlap blocks at (0,0,0) and (1,1,1)
    const min_x: i32 = @intFromFloat(@floor(aabb.min.x));
    const max_x: i32 = @intFromFloat(@floor(aabb.max.x));

    try std.testing.expectEqual(@as(i32, 0), min_x);
    try std.testing.expectEqual(@as(i32, 1), max_x);
}
