//! FPS-style camera with mouse look and WASD movement.

const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Input = @import("../input/input.zig").Input;
const Key = @import("../core/interfaces.zig").Key;

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
    pub fn update(self: *Camera, input: *const Input, delta_time: f32) void {
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

        if (input.isKeyDown(.w)) move_dir = move_dir.add(self.forward);
        if (input.isKeyDown(.s)) move_dir = move_dir.sub(self.forward);
        if (input.isKeyDown(.a)) move_dir = move_dir.sub(self.right);
        if (input.isKeyDown(.d)) move_dir = move_dir.add(self.right);
        if (input.isKeyDown(.space)) move_dir = move_dir.add(Vec3.up);
        if (input.isKeyDown(.left_shift)) move_dir = move_dir.sub(Vec3.up);

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

    /// Get projection matrix with reverse-Z for better depth precision
    pub fn getProjectionMatrix(self: *const Camera, aspect_ratio: f32) Mat4 {
        return Mat4.perspectiveReverseZ(self.fov, aspect_ratio, self.near, self.far);
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
