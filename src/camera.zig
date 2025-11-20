const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Camera = struct {
    pos: Vec3,
    front: Vec3,
    up: Vec3,
    yaw: f32,
    pitch: f32,
    worldUp: Vec3,

    pub fn new(pos: Vec3, worldUp: Vec3, yaw: f32, pitch: f32) Camera {
        var cam = Camera{
            .pos = pos,
            .front = Vec3.new(0, 0, -1),
            .up = Vec3.new(0, 0, 0),
            .yaw = yaw,
            .pitch = pitch,
            .worldUp = worldUp,
        };
        cam.updateCameraVectors();
        return cam;
    }

    pub fn getViewMatrix(self: Camera) Mat4 {
        return Mat4.lookAt(self.pos, self.pos.add(self.front), self.up);
    }

    pub const Movement = enum { FORWARD, BACKWARD, LEFT, RIGHT };

    pub fn processKeyboard(self: *Camera, direction: Movement, deltaTime: f32) void {
        const velocity = 2.5 * deltaTime;
        if (direction == .FORWARD) {
            self.pos = self.pos.add(self.front.scale(velocity));
        }
        if (direction == .BACKWARD) {
            self.pos = self.pos.sub(self.front.scale(velocity));
        }
        if (direction == .LEFT) {
            self.pos = self.pos.sub(self.front.cross(self.up).normalize().scale(velocity));
        }
        if (direction == .RIGHT) {
            self.pos = self.pos.add(self.front.cross(self.up).normalize().scale(velocity));
        }
    }

    pub fn processMouseMovement(self: *Camera, xoffset: f32, yoffset: f32, constrainPitch: bool) void {
        const sensitivity = 0.1;
        self.yaw += xoffset * sensitivity;
        self.pitch -= yoffset * sensitivity;

        if (constrainPitch) {
            if (self.pitch > 89.0) self.pitch = 89.0;
            if (self.pitch < -89.0) self.pitch = -89.0;
        }

        self.updateCameraVectors();
    }

    fn updateCameraVectors(self: *Camera) void {
        const front = Vec3.new(std.math.cos(std.math.degreesToRadians(self.yaw)) * std.math.cos(std.math.degreesToRadians(self.pitch)), std.math.sin(std.math.degreesToRadians(self.pitch)), std.math.sin(std.math.degreesToRadians(self.yaw)) * std.math.cos(std.math.degreesToRadians(self.pitch)));
        self.front = front.normalize();
        // Re-calculate Right and Up vector
        // Normalize the vectors, because their length gets closer to 0 the more you look up or down which results in slower movement.
        const right = self.front.cross(self.worldUp).normalize();
        self.up = right.cross(self.front).normalize();
    }
};
