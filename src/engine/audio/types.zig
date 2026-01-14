//! Core audio types shared across the system.

const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const SoundHandle = u32;
pub const InvalidSoundHandle: SoundHandle = 0;

pub const VoiceHandle = struct {
    id: u32,
    generation: u64,
};

pub const AudioFormat = enum {
    unsigned8,
    signed16,
    float32,
};

pub const SoundCategory = enum {
    master,
    music,
    sfx,
    ambient,
};

pub const SoundData = struct {
    buffer: []u8,
    frequency: u32,
    channels: u8,
    format: AudioFormat,
    length_samples: u32,
};

pub const PlayConfig = struct {
    volume: f32 = 1.0,
    pitch: f32 = 1.0,
    loop: bool = false,
    category: SoundCategory = .sfx,

    // Spatial properties
    is_spatial: bool = false,
    position: Vec3 = Vec3.zero,
    min_distance: f32 = 1.0,
    max_distance: f32 = 50.0,
};
