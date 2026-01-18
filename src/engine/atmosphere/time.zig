const std = @import("std");

pub const TICKS_PER_DAY: u64 = 24000;
pub const TICKS_PER_SECOND: f32 = 20.0;

pub const TimeSystem = struct {
    world_ticks: u64 = 6000,
    tick_accumulator: f32 = 0.0,
    time_scale: f32 = 1.0,
    time_of_day: f32 = 0.25,

    pub fn update(self: *TimeSystem, delta_time: f32) void {
        self.tick_accumulator += delta_time * TICKS_PER_SECOND * self.time_scale;
        if (self.tick_accumulator >= 1.0) {
            const ticks_delta: u64 = @intFromFloat(self.tick_accumulator);
            self.world_ticks +%= ticks_delta;
            self.tick_accumulator -= @floatFromInt(ticks_delta);
        }

        const day_ticks = self.world_ticks % TICKS_PER_DAY;
        self.time_of_day = @as(f32, @floatFromInt(day_ticks)) / @as(f32, @floatFromInt(TICKS_PER_DAY));
    }

    pub fn setTimeOfDay(self: *TimeSystem, time: f32) void {
        self.world_ticks = @intFromFloat(time * @as(f32, @floatFromInt(TICKS_PER_DAY)));
        self.time_of_day = time;
        self.tick_accumulator = 0;
    }

    pub fn getHours(self: *const TimeSystem) f32 {
        return self.time_of_day * 24.0;
    }
};
