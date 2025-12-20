//! Time management for the game loop.
//! Provides delta time, fixed timestep support, and FPS tracking.

const std = @import("std");
const c = @import("../../c.zig").c;

pub const Time = struct {
    /// Time since last frame in seconds
    delta_time: f32 = 0,

    /// Fixed timestep for physics (default 60 Hz)
    fixed_delta_time: f32 = 1.0 / 60.0,

    /// Accumulated time for fixed update
    accumulator: f32 = 0,

    /// Total elapsed time in seconds
    elapsed: f32 = 0,

    /// Frame count
    frame_count: u64 = 0,

    /// Current FPS (updated every second)
    fps: f32 = 0,

    // Internal tracking
    last_tick: u64 = 0,
    fps_timer: f32 = 0,
    fps_frame_count: u32 = 0,

    pub fn init() Time {
        return .{
            .last_tick = c.SDL_GetPerformanceCounter(),
        };
    }

    /// Call at the start of each frame
    pub fn update(self: *Time) void {
        const now = c.SDL_GetPerformanceCounter();
        const freq = c.SDL_GetPerformanceFrequency();

        self.delta_time = @as(f32, @floatFromInt(now - self.last_tick)) / @as(f32, @floatFromInt(freq));
        self.last_tick = now;

        // Clamp delta time to prevent spiral of death
        if (self.delta_time > 0.25) {
            self.delta_time = 0.25;
        }

        self.elapsed += self.delta_time;
        self.accumulator += self.delta_time;
        self.frame_count += 1;

        // FPS calculation
        self.fps_timer += self.delta_time;
        self.fps_frame_count += 1;
        if (self.fps_timer >= 1.0) {
            self.fps = @as(f32, @floatFromInt(self.fps_frame_count)) / self.fps_timer;
            self.fps_timer = 0;
            self.fps_frame_count = 0;
        }
    }

    /// Returns true if a fixed update should run, decrements accumulator
    pub fn shouldFixedUpdate(self: *Time) bool {
        if (self.accumulator >= self.fixed_delta_time) {
            self.accumulator -= self.fixed_delta_time;
            return true;
        }
        return false;
    }

    /// Get interpolation alpha for rendering between physics steps
    pub fn getAlpha(self: Time) f32 {
        return self.accumulator / self.fixed_delta_time;
    }
};
