//! Audio backend interface definition.

const std = @import("std");
const types = @import("types.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const IAudioBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque) void,
        setListener: *const fn (ptr: *anyopaque, position: Vec3, forward: Vec3, up: Vec3) void,
        playSound: *const fn (ptr: *anyopaque, sound_data: *const types.SoundData, config: types.PlayConfig) void,
        setMasterVolume: *const fn (ptr: *anyopaque, volume: f32) void,
        setCategoryVolume: *const fn (ptr: *anyopaque, category: types.SoundCategory, volume: f32) void,
    };

    pub fn update(self: IAudioBackend) void {
        self.vtable.update(self.ptr);
    }

    pub fn setListener(self: IAudioBackend, position: Vec3, forward: Vec3, up: Vec3) void {
        self.vtable.setListener(self.ptr, position, forward, up);
    }

    pub fn playSound(self: IAudioBackend, sound_data: *const types.SoundData, config: types.PlayConfig) void {
        self.vtable.playSound(self.ptr, sound_data, config);
    }

    pub fn setMasterVolume(self: IAudioBackend, volume: f32) void {
        self.vtable.setMasterVolume(self.ptr, volume);
    }

    pub fn setCategoryVolume(self: IAudioBackend, category: types.SoundCategory, volume: f32) void {
        self.vtable.setCategoryVolume(self.ptr, category, volume);
    }
};
