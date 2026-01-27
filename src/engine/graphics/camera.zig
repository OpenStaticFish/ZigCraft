//! FPS-style camera with mouse look and WASD movement.

const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Input = @import("../input/input.zig").Input;
const Key = @import("../core/interfaces.zig").Key;

const InputMapper = @import("../../game/input_mapper.zig").InputMapper;

pub const Camera = struct {
    position: Vec3,

    /// Yaw in radians (rotation around Y axis)
    yaw: f32,

    /// Pitch in radians (rotation around X axis)
    pitch: f32,

    /// Field of view in radians
    fov: f32,

    /// Near clipping plane
    near: f32,

    /// Far clipping plane
    far: f32,

    /// Movement speed in units per second
    move_speed: f32,

    /// Mouse sensitivity
    sensitivity: f32,

    // Cached vectors (updated when rotation changes)
    forward: Vec3,
    right: Vec3,
    up: Vec3,

    pub const Config = struct {
        position: Vec3 = Vec3.init(0, 0, 3),
        yaw: f32 = -std.math.pi / 2.0, // Looking toward -Z
        pitch: f32 = 0,
        fov: f32 = std.math.degreesToRadians(70.0),
        near: f32 = 0.5, // Pushed out for better depth precision with reverse-Z
        far: f32 = 10000.0, // Increased for large render distances
        move_speed: f32 = 5.0,
        sensitivity: f32 = 0.002,
    };

    pub fn init(config: Config) Camera {
        var cam = Camera{
            .position = config.position,
            .yaw = config.yaw,
            .pitch = config.pitch,
            .fov = config.fov,
            .near = config.near,
            .far = config.far,
            .move_speed = config.move_speed,
            .sensitivity = config.sensitivity,
            .forward = Vec3.zero,
            .right = Vec3.zero,
            .up = Vec3.zero,
        };
        cam.updateVectors();
        return cam;
    }

    /// Update camera from input (call once per frame)
    pub fn update(self: *Camera, input: *const Input, mapper: *const InputMapper, delta_time: f32) void {
        // Mouse look
        const mouse_delta = input.getMouseDelta();
        if (input.mouse_captured) {
            self.yaw += @as(f32, @floatFromInt(mouse_delta.x)) * self.sensitivity;
            self.pitch -= @as(f32, @floatFromInt(mouse_delta.y)) * self.sensitivity;

            // Clamp pitch to prevent flipping
            const max_pitch = std.math.degreesToRadians(89.0);
            self.pitch = std.math.clamp(self.pitch, -max_pitch, max_pitch);

            self.updateVectors();
        }

        // Keyboard movement
        var move_dir = Vec3.zero;

        const move_vec = mapper.getMovementVector(input);
        if (move_vec.z > 0) move_dir = move_dir.add(self.forward);
        if (move_vec.z < 0) move_dir = move_dir.sub(self.forward);
        if (move_vec.x < 0) move_dir = move_dir.sub(self.right);
        if (move_vec.x > 0) move_dir = move_dir.add(self.right);
        if (mapper.isActionActive(input, .jump)) move_dir = move_dir.add(Vec3.up);
        if (mapper.isActionActive(input, .crouch)) move_dir = move_dir.sub(Vec3.up);

        // Normalize and apply speed
        if (move_dir.lengthSquared() > 0) {
            move_dir = move_dir.normalize();
            self.position = self.position.add(move_dir.scale(self.move_speed * delta_time));
        }
    }

    fn updateVectors(self: *Camera) void {
        // Calculate forward vector from yaw and pitch
        self.forward = Vec3.init(
            std.math.cos(self.yaw) * std.math.cos(self.pitch),
            std.math.sin(self.pitch),
            std.math.sin(self.yaw) * std.math.cos(self.pitch),
        ).normalize();

        // Right = forward cross world up
        self.right = self.forward.cross(Vec3.up).normalize();

        // Up = right cross forward
        self.up = self.right.cross(self.forward).normalize();
    }

    /// Get view matrix
    pub fn getViewMatrix(self: *const Camera) Mat4 {
        const target = self.position.add(self.forward);
        return Mat4.lookAt(self.position, target, Vec3.up);
    }

    /// Get projection matrix
    pub fn getProjectionMatrix(self: *const Camera, aspect_ratio: f32) Mat4 {
        // Standard perspective for compatibility
        return Mat4.perspective(self.fov, aspect_ratio, self.near, self.far);
    }

    /// Get projection matrix with subpixel jitter for TAA
    /// jitter_x, jitter_y: Normalized device coordinates offset (-1 to 1 range)
    pub fn getProjectionMatrixJittered(self: *const Camera, aspect_ratio: f32, jitter_x: f32, jitter_y: f32) Mat4 {
        var proj = self.getProjectionMatrix(aspect_ratio);
        // Apply jitter to projection matrix (columns 2,0 and 2,1 in 0-based indexing)
        // Mat4 is column-major? Let's check Mat4 implementation or assume standard OpenGL layout
        // usually proj[2][0] and proj[2][1] correspond to X and Y shear
        proj.data[2][0] += jitter_x;
        proj.data[2][1] += jitter_y;
        return proj;
    }

    /// Get projection matrix with subpixel jitter for TAA (Reverse Z)
    pub fn getProjectionMatrixReverseZJittered(self: *const Camera, aspect_ratio: f32, jitter_x: f32, jitter_y: f32) Mat4 {
        var proj = Mat4.perspectiveReverseZ(self.fov, aspect_ratio, self.near, self.far);
        proj.data[2][0] += jitter_x;
        proj.data[2][1] += jitter_y;
        return proj;
    }

    /// Get view matrix centered at origin (for floating origin rendering)
    /// Camera is conceptually at origin looking in the forward direction
    pub fn getViewMatrixOriginCentered(self: *const Camera) Mat4 {
        // View matrix with camera at origin - just rotation, no translation
        const target = self.forward;
        return Mat4.lookAt(Vec3.zero, target, Vec3.up);
    }

    /// Get combined view-projection matrix for floating origin rendering
    /// Use this with camera-relative chunk positions
    pub fn getViewProjectionMatrixOriginCentered(self: *const Camera, aspect_ratio: f32) Mat4 {
        return self.getProjectionMatrix(aspect_ratio).multiply(self.getViewMatrixOriginCentered());
    }

    /// Get inverse view-projection matrix for sky rendering
    /// Used to reconstruct world directions from clip space
    pub fn getInvViewProjectionMatrix(self: *const Camera, aspect_ratio: f32) Mat4 {
        const view_proj = self.getViewProjectionMatrixOriginCentered(aspect_ratio);
        return view_proj.inverse();
    }
};
