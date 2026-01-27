//! Player controller with physics, collision, and block interaction.
//!
//! Replaces the free-cam with a physical player that has gravity, collision,
//! and supports both walking and creative flight modes.

const std = @import("std");
const math = @import("zig-math");
const Vec3 = math.Vec3;
const AABB = math.AABB;

const Camera = @import("../engine/graphics/camera.zig").Camera;
const Input = @import("../engine/input/input.zig").Input;
const IRawInputProvider = @import("../engine/input/interfaces.zig").IRawInputProvider;
const Key = @import("../engine/core/interfaces.zig").Key;
const MouseButton = @import("../engine/core/interfaces.zig").MouseButton;
const World = @import("../world/world.zig").World;
const collision = @import("../engine/physics/collision.zig");
const ray = @import("../engine/math/ray.zig");
const block = @import("../world/block.zig");
const block_registry = @import("../world/block_registry.zig");
const BlockType = block.BlockType;
const Face = block.Face;
const input_mapper = @import("input_mapper.zig");
const InputMapper = input_mapper.InputMapper;
const GameAction = input_mapper.GameAction;

/// Player controller with physics and block interaction.
pub const Player = struct {
    // ========================================================================
    // Position and Physics State
    // ========================================================================

    /// Player position (feet position, bottom-center of the collision box)
    position: Vec3,

    /// Player velocity in blocks per second
    velocity: Vec3,

    /// Whether the player is standing on solid ground
    is_grounded: bool,

    // ========================================================================
    // Mode Flags
    // ========================================================================

    /// Creative flight mode (no gravity, free movement)
    fly_mode: bool,

    /// Whether player is allowed to fly (e.g. creative mode)
    can_fly: bool,

    /// Noclip mode (pass through blocks)
    noclip: bool,

    // ========================================================================
    // Camera
    // ========================================================================

    /// Camera for view/projection (owned by player)
    camera: Camera,

    // ========================================================================
    // Block Targeting
    // ========================================================================

    /// Currently targeted block (if any)
    target_block: ?BlockTarget,

    // ========================================================================
    // Double-tap Detection
    // ========================================================================

    /// Time of last space press for double-tap fly toggle
    last_space_time: f32,

    /// Whether space was released since last press
    space_released: bool,

    // ========================================================================
    // Constants
    // ========================================================================

    /// Player collision box width (must fit through 1x1 hole)
    pub const WIDTH: f32 = 0.6;

    /// Player collision box height
    pub const HEIGHT: f32 = 1.8;

    /// Eye height above feet position
    pub const EYE_HEIGHT: f32 = 1.62;

    /// Walking speed in blocks per second
    pub const WALK_SPEED: f32 = 4.317;

    /// Flying speed in blocks per second
    pub const FLY_SPEED: f32 = 10.0;

    /// Gravity acceleration in blocks per second squared
    pub const GRAVITY: f32 = 32.0;

    /// Initial jump velocity (tuned for ~1.25 block jump height)
    pub const JUMP_VELOCITY: f32 = 8.5;

    /// Maximum falling speed
    pub const TERMINAL_VELOCITY: f32 = 78.4;

    /// Time window for double-tap detection (seconds)
    pub const DOUBLE_TAP_THRESHOLD: f32 = 0.3;

    /// Maximum distance for block targeting (blocks)
    pub const REACH_DISTANCE: f32 = 5.0;

    /// Block target information
    pub const BlockTarget = struct {
        x: i32,
        y: i32,
        z: i32,
        face: Face,
        distance: f32,
    };

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize a new player at the given spawn position.
    /// If creative is true, starts in fly mode.
    pub fn init(spawn_pos: Vec3, creative: bool) Player {
        const camera = Camera.init(.{
            .position = spawn_pos.add(Vec3.init(0, EYE_HEIGHT, 0)),
            .move_speed = WALK_SPEED,
        });

        return Player{
            .position = spawn_pos,
            .velocity = Vec3.zero,
            .is_grounded = false,
            .fly_mode = creative,
            .can_fly = creative,
            .noclip = false,
            .camera = camera,
            .target_block = null,
            .last_space_time = 0,
            .space_released = true,
        };
    }

    // ========================================================================
    // Update
    // ========================================================================

    /// Update player physics and input. Call once per frame.
    pub fn update(
        self: *Player,
        input: IRawInputProvider,
        mapper: *const InputMapper,
        world: *World,
        delta_time: f32,
        current_time: f32,
    ) void {
        // Handle mouse look
        self.handleMouseLook(input);

        // Handle double-tap space for fly toggle
        self.handleFlyToggle(input, mapper, current_time);

        // Calculate movement
        const move_dir = self.getMovementDirection(input, mapper);

        if (self.fly_mode) {
            self.updateFlying(input, mapper, move_dir, delta_time);
        } else {
            self.updateWalking(input, mapper, move_dir, world, delta_time);
        }

        // Sync camera to eye position
        self.syncCamera();

        // Update block targeting
        self.updateTargetBlock(world);
    }

    /// Handle mouse look (yaw/pitch)
    fn handleMouseLook(self: *Player, input: IRawInputProvider) void {
        if (!input.isMouseCaptured()) return;

        const mouse_delta = input.getMouseDelta();
        self.camera.yaw += @as(f32, @floatFromInt(mouse_delta.x)) * self.camera.sensitivity;
        self.camera.pitch -= @as(f32, @floatFromInt(mouse_delta.y)) * self.camera.sensitivity;

        // Clamp pitch to prevent flipping
        const max_pitch = std.math.degreesToRadians(89.0);
        self.camera.pitch = std.math.clamp(self.camera.pitch, -max_pitch, max_pitch);

        // Update camera direction vectors
        self.camera.forward = Vec3.init(
            std.math.cos(self.camera.yaw) * std.math.cos(self.camera.pitch),
            std.math.sin(self.camera.pitch),
            std.math.sin(self.camera.yaw) * std.math.cos(self.camera.pitch),
        ).normalize();
        self.camera.right = self.camera.forward.cross(Vec3.up).normalize();
        self.camera.up = self.camera.right.cross(self.camera.forward).normalize();
    }

    /// Handle double-tap space for fly mode toggle (creative only)
    fn handleFlyToggle(self: *Player, input: IRawInputProvider, mapper: *const InputMapper, current_time: f32) void {
        if (!self.can_fly) return;

        if (mapper.isActionReleased(input, .jump)) {
            self.space_released = true;
        }

        if (mapper.isActionPressed(input, .jump) and self.space_released) {
            const time_since_last = current_time - self.last_space_time;

            if (time_since_last < DOUBLE_TAP_THRESHOLD) {
                // Double-tap detected - toggle fly mode
                self.fly_mode = !self.fly_mode;
                self.velocity = Vec3.zero;
            }

            self.last_space_time = current_time;
            self.space_released = false;
        }
    }

    /// Get horizontal movement direction from WASD input
    fn getMovementDirection(self: *Player, input: IRawInputProvider, mapper: *const InputMapper) Vec3 {
        var move_dir = Vec3.zero;

        // Get horizontal forward (ignore pitch for ground movement)
        const forward_flat = Vec3.init(
            std.math.cos(self.camera.yaw),
            0,
            std.math.sin(self.camera.yaw),
        ).normalize();

        const right_flat = Vec3.init(
            std.math.cos(self.camera.yaw + std.math.pi / 2.0),
            0,
            std.math.sin(self.camera.yaw + std.math.pi / 2.0),
        ).normalize();

        const move_vec = mapper.getMovementVector(input);
        if (move_vec.z > 0) move_dir = move_dir.add(forward_flat);
        if (move_vec.z < 0) move_dir = move_dir.sub(forward_flat);
        if (move_vec.x < 0) move_dir = move_dir.sub(right_flat);
        if (move_vec.x > 0) move_dir = move_dir.add(right_flat);

        // Normalize if moving
        if (move_dir.lengthSquared() > 0) {
            move_dir = move_dir.normalize();
        }

        return move_dir;
    }

    /// Update player when flying (creative mode)
    fn updateFlying(self: *Player, input: IRawInputProvider, mapper: *const InputMapper, move_dir: Vec3, delta_time: f32) void {
        var vel = move_dir.scale(FLY_SPEED);

        // Vertical movement
        if (mapper.isActionActive(input, .jump)) {
            vel.y = FLY_SPEED;
        } else if (mapper.isActionActive(input, .crouch)) {
            vel.y = -FLY_SPEED;
        }

        self.velocity = vel;

        // Apply movement directly (noclip is implied in fly mode for now)
        self.position = self.position.add(vel.scale(delta_time));
        self.is_grounded = false;
    }

    /// Update player when walking (normal physics)
    fn updateWalking(
        self: *Player,
        input: IRawInputProvider,
        mapper: *const InputMapper,
        move_dir: Vec3,
        world: *World,
        delta_time: f32,
    ) void {
        // Apply gravity
        self.velocity.y -= GRAVITY * delta_time;

        // Clamp to terminal velocity
        if (self.velocity.y < -TERMINAL_VELOCITY) {
            self.velocity.y = -TERMINAL_VELOCITY;
        }

        // Jump if grounded and space pressed
        if (self.is_grounded and mapper.isActionActive(input, .jump)) {
            self.velocity.y = JUMP_VELOCITY;
            self.is_grounded = false;
        }

        // Apply horizontal movement
        self.velocity.x = move_dir.x * WALK_SPEED;
        self.velocity.z = move_dir.z * WALK_SPEED;

        // Resolve collisions
        if (self.noclip) {
            self.position = self.position.add(self.velocity.scale(delta_time));
        } else {
            const aabb = self.getAABB();
            const result = collision.moveAndCollide(
                world,
                aabb,
                self.velocity,
                delta_time,
                .{},
            );

            self.position = result.position.sub(Vec3.init(0, HEIGHT / 2.0, 0));
            self.velocity = result.velocity;
            self.is_grounded = result.grounded;
        }
    }

    /// Sync camera position to player eye height
    fn syncCamera(self: *Player) void {
        self.camera.position = self.position.add(Vec3.init(0, EYE_HEIGHT, 0));
    }

    /// Update the currently targeted block via raycast
    fn updateTargetBlock(self: *Player, world: *World) void {
        const eye_pos = self.getEyePosition();
        const direction = self.camera.forward;

        // Context for the raycast callback
        const Context = struct {
            world: *World,

            pub fn isSolid(ctx: @This(), x: i32, y: i32, z: i32) bool {
                const blk = ctx.world.getBlock(x, y, z);
                return block_registry.getBlockDefinition(blk).is_solid;
            }
        };

        const result = ray.castThroughVoxels(
            eye_pos,
            direction,
            REACH_DISTANCE,
            Context,
            Context{ .world = world },
            Context.isSolid,
        );

        if (result) |hit| {
            self.target_block = BlockTarget{
                .x = hit.x,
                .y = hit.y,
                .z = hit.z,
                .face = hit.face,
                .distance = hit.distance,
            };
        } else {
            self.target_block = null;
        }
    }

    // ========================================================================
    // Block Interaction
    // ========================================================================

    /// Break the currently targeted block (set to air)
    pub fn breakTargetBlock(self: *Player, world: *World) void {
        if (self.target_block) |target| {
            world.setBlock(target.x, target.y, target.z, .air) catch {};
        }
    }

    /// Place a block at the face of the targeted block
    pub fn placeBlock(self: *Player, world: *World, block_type: BlockType) void {
        if (self.target_block) |target| {
            const offset = target.face.getOffset();
            const px = target.x + offset.x;
            const py = target.y + offset.y;
            const pz = target.z + offset.z;

            // Don't place inside the player
            const place_aabb = AABB.init(
                Vec3.init(@floatFromInt(px), @floatFromInt(py), @floatFromInt(pz)),
                Vec3.init(@floatFromInt(px + 1), @floatFromInt(py + 1), @floatFromInt(pz + 1)),
            );

            if (!self.getAABB().intersects(place_aabb)) {
                world.setBlock(px, py, pz, block_type) catch {};
            }
        }
    }

    // ========================================================================
    // Utility Methods
    // ========================================================================

    /// Get the player's collision AABB (centered on position at mid-height)
    pub fn getAABB(self: Player) AABB {
        const half_width = WIDTH / 2.0;
        return AABB.init(
            Vec3.init(
                self.position.x - half_width,
                self.position.y,
                self.position.z - half_width,
            ),
            Vec3.init(
                self.position.x + half_width,
                self.position.y + HEIGHT,
                self.position.z + half_width,
            ),
        );
    }

    /// Get the player's eye position (for raycasting, camera)
    pub fn getEyePosition(self: Player) Vec3 {
        return self.position.add(Vec3.init(0, EYE_HEIGHT, 0));
    }

    /// Toggle creative/survival mode
    pub fn setCreativeMode(self: *Player, creative: bool) void {
        self.can_fly = creative;
        if (creative) {
            self.fly_mode = true;
        } else {
            self.fly_mode = false;
            self.noclip = false;
        }
    }

    /// Toggle noclip (only in creative)
    pub fn toggleNoclip(self: *Player) void {
        if (self.fly_mode) {
            self.noclip = !self.noclip;
        }
    }
};
