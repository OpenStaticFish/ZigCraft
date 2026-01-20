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
        playSound: *const fn (ptr: *anyopaque, sound_data: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle,
        stopVoice: *const fn (ptr: *anyopaque, handle: types.VoiceHandle) void,
        stopAll: *const fn (ptr: *anyopaque) void,
        setMasterVolume: *const fn (ptr: *anyopaque, volume: f32) void,
        setCategoryVolume: *const fn (ptr: *anyopaque, category: types.SoundCategory, volume: f32) void,
    };

    pub fn update(self: IAudioBackend) void {
        self.vtable.update(self.ptr);
    }

    pub fn setListener(self: IAudioBackend, position: Vec3, forward: Vec3, up: Vec3) void {
        self.vtable.setListener(self.ptr, position, forward, up);
    }

    pub fn playSound(self: IAudioBackend, sound_data: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle {
        return self.vtable.playSound(self.ptr, sound_data, config);
    }

    pub fn stopVoice(self: IAudioBackend, handle: types.VoiceHandle) void {
        self.vtable.stopVoice(self.ptr, handle);
    }

    pub fn stopAll(self: IAudioBackend) void {
        self.vtable.stopAll(self.ptr);
    }

    pub fn setMasterVolume(self: IAudioBackend, volume: f32) void {
        self.vtable.setMasterVolume(self.ptr, volume);
    }

    pub fn setCategoryVolume(self: IAudioBackend, category: types.SoundCategory, volume: f32) void {
        self.vtable.setCategoryVolume(self.ptr, category, volume);
    }
};

pub const DummyAudioBackend = struct {
    backend: IAudioBackend,

    pub fn init() DummyAudioBackend {
        return .{
            .backend = .{
                .ptr = undefined,
                .vtable = &VTABLE,
            },
        };
    }

    fn update(_: *anyopaque) void {}
    fn setListener(_: *anyopaque, _: Vec3, _: Vec3, _: Vec3) void {}
    fn playSound(_: *anyopaque, _: *const types.SoundData, _: types.PlayConfig) types.VoiceHandle {
        return .{ .id = 0, .generation = 0 };
    }
    fn stopVoice(_: *anyopaque, _: types.VoiceHandle) void {}
    fn stopAll(_: *anyopaque) void {}
    fn setMasterVolume(_: *anyopaque, _: f32) void {}
    fn setCategoryVolume(_: *anyopaque, _: types.SoundCategory, _: f32) void {}

    const VTABLE = IAudioBackend.VTable{
        .update = update,
        .setListener = setListener,
        .playSound = playSound,
        .stopVoice = stopVoice,
        .stopAll = stopAll,
        .setMasterVolume = setMasterVolume,
        .setCategoryVolume = setCategoryVolume,
    };
};
