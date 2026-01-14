//! SDL3 Audio Backend with Software 3D Mixer.

const std = @import("std");
const c = @import("../../../c.zig").c;
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const Vec3 = @import("../../math/vec3.zig").Vec3;
const log = @import("../../core/log.zig");

pub const AudioConfig = struct {
    max_voices: u32 = 64,
    mix_rate: u32 = 44100,
    mix_channels: u8 = 2,
};

// Hardcoded for now until dynamic allocation is refactored
pub const MAX_VOICES = 64;
pub const MIX_RATE = 44100;
pub const MIX_CHANNELS = 2; // Stereo
pub const MIX_FORMAT = c.SDL_AUDIO_S16;

const Voice = struct {
    active: bool = false,
    sound_data: ?*const types.SoundData = null,
    cursor: f32 = 0.0, // Sample index (float for pitch shifting)

    // Playback properties
    loop: bool = false,
    pitch: f32 = 1.0,
    base_volume: f32 = 1.0,
    category: types.SoundCategory = .sfx,

    // Spatial properties
    is_spatial: bool = false,
    position: Vec3 = Vec3.init(0, 0, 0),
    min_dist: f32 = 1.0,
    max_dist: f32 = 50.0,

    // Calculated per frame
    effective_volume_l: f32 = 1.0,
    effective_volume_r: f32 = 1.0,

    // Priority/Age for stealing
    start_time: i64 = 0, // Ticks when started
    id: u32 = 0,
    generation: u64 = 0,
};

const Mixer = struct {
    /// Mutex protecting all mixer state.
    /// Acquired by all public methods: play, stop, update, mix.
    /// Safe to call from any thread (Main or Audio Callback).
    mutex: std.Thread.Mutex = .{},
    voices: [MAX_VOICES]Voice = undefined,
    voice_generation_counter: u64 = 1,
    master_volume: f32 = 1.0,
    music_volume: f32 = 0.5,
    sfx_volume: f32 = 1.0,
    ambient_volume: f32 = 1.0,

    listener_pos: Vec3 = Vec3.zero,
    listener_fwd: Vec3 = Vec3.init(0, 0, 1),
    listener_up: Vec3 = Vec3.init(0, 1, 0),
    listener_right: Vec3 = Vec3.init(1, 0, 0),

    pub fn init() Mixer {
        return .{
            .voices = [_]Voice{.{}} ** MAX_VOICES,
        };
    }

    pub fn play(self: *Mixer, sound: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        var oldest_idx: usize = 0;
        var oldest_time: i64 = std.math.maxInt(i64);
        var found_slot = false;

        // Find free voice or oldest voice
        for (&self.voices, 0..) |*voice, i| {
            if (!voice.active) {
                oldest_idx = i;
                found_slot = true;
                break;
            }
            if (voice.start_time < oldest_time) {
                oldest_time = voice.start_time;
                oldest_idx = i;
            }
        }

        // Voice stealing if full (or just picking the free one found)
        const voice = &self.voices[oldest_idx];
        const gen = self.voice_generation_counter;
        self.voice_generation_counter += 1;

        voice.* = .{
            .active = true,
            .sound_data = sound,
            .cursor = 0.0,
            .loop = config.loop,
            .pitch = config.pitch,
            .base_volume = std.math.clamp(config.volume, 0.0, 1.0),
            .category = config.category,
            .is_spatial = config.is_spatial,
            .position = config.position,
            .min_dist = config.min_distance,
            .max_dist = config.max_distance,
            .start_time = @intCast(c.SDL_GetTicksNS()),
            .id = @intCast(oldest_idx),
            .generation = gen,
        };
        // Initial update to set volume
        self.updateVoiceSpatial(voice);

        return .{ .id = @intCast(oldest_idx), .generation = gen };
    }

    pub fn stopVoice(self: *Mixer, handle: types.VoiceHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (handle.id >= MAX_VOICES) return;
        const voice = &self.voices[handle.id];

        if (voice.active and voice.generation == handle.generation) {
            voice.active = false;
        }
    }

    fn updateVoiceSpatial(self: *Mixer, voice: *Voice) void {
        var vol = voice.base_volume * self.master_volume;

        // Apply category volume
        switch (voice.category) {
            .master => {}, // Already applied
            .music => vol *= self.music_volume,
            .sfx => vol *= self.sfx_volume,
            .ambient => vol *= self.ambient_volume,
        }

        if (voice.is_spatial) {
            const to_sound = voice.position.sub(self.listener_pos);
            const dist = to_sound.length();

            // Attenuation (Inverse Distance Clamped)
            var attenuation: f32 = 1.0;
            if (dist > voice.min_dist) {
                const range = @max(0.1, voice.max_dist - voice.min_dist);
                attenuation = 1.0 - std.math.clamp((dist - voice.min_dist) / range, 0.0, 1.0);
                // Square it for smoother falloff
                attenuation *= attenuation;
            }

            // Panning
            var pan: f32 = 0.0; // -1.0 left, 1.0 right
            if (dist > 0.001) {
                const dir = to_sound.normalize();
                if (dir.lengthSquared() > 0) {
                    pan = dir.dot(self.listener_right);
                }
            }

            // Stereo balance (Unity-style: Center=1.0, Hard Pan=1.0 on one side)
            var pan_l: f32 = 1.0;
            var pan_r: f32 = 1.0;

            if (pan > 0) {
                pan_l = 1.0 - pan;
            } else {
                pan_r = 1.0 + pan;
            }

            voice.effective_volume_l = vol * attenuation * pan_l;
            voice.effective_volume_r = vol * attenuation * pan_r;
        } else {
            voice.effective_volume_l = vol;
            voice.effective_volume_r = vol;
        }
    }

    pub fn update(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.listener_right = self.listener_fwd.cross(self.listener_up).normalize();

        for (&self.voices) |*voice| {
            if (voice.active) {
                self.updateVoiceSpatial(voice);
            }
        }
    }

    // Mix samples into the output buffer (S16 stereo)
    pub fn mix(self: *Mixer, stream: *c.SDL_AudioStream, _: c_int) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // We only mix if we need more data. SDL3 stream buffers for us.
        // But here we are just pushing data.

        // Let's create a temporary buffer on stack or heap to mix into
        const SAMPLES_TO_MIX = 1024; // Small chunks
        var mix_buf: [SAMPLES_TO_MIX * 2]i32 = [_]i32{0} ** (SAMPLES_TO_MIX * 2); // 32-bit accumulator to prevent clip

        // Check if any voice is active
        var any_active = false;
        for (self.voices) |v| {
            if (v.active) {
                any_active = true;
                break;
            }
        }

        if (!any_active) {
            // Push silence
            const silence = [_]i16{0} ** (SAMPLES_TO_MIX * 2);
            _ = c.SDL_PutAudioStreamData(stream, &silence, silence.len * 2);
            return;
        }

        // Mix
        for (&self.voices) |*voice| {
            if (!voice.active) continue;

            // Critical Issue 1: Null check
            if (voice.sound_data == null) {
                voice.active = false;
                continue;
            }

            const data = voice.sound_data.?;
            const u8_buf = data.buffer;

            // Assuming S16 format for now from Manager
            // TODO: Handle other formats

            var i: usize = 0;
            while (i < SAMPLES_TO_MIX) : (i += 1) {
                // Nearest-neighbor resampling
                const pos_idx = @as(usize, @intFromFloat(voice.cursor));

                // Critical Issue 2: Fix OOB check & Overflow
                // Check if pos_idx is so large that * 2 would overflow (usize max / 2)
                if (pos_idx > std.math.maxInt(usize) / 2) {
                    voice.active = false;
                    break;
                }

                // We need 2 bytes for a sample
                if (pos_idx * 2 + 2 > u8_buf.len) {
                    if (voice.loop) {
                        voice.cursor = 0.0;
                    } else {
                        voice.active = false;
                        break;
                    }
                }

                // Re-calculate pos after potential loop wrap
                const valid_pos_idx = @as(usize, @intFromFloat(voice.cursor));
                if (valid_pos_idx > std.math.maxInt(usize) / 2 or valid_pos_idx * 2 + 2 > u8_buf.len) {
                    // Double check in case pitch incremented past end exactly at loop point
                    voice.active = false;
                    break;
                }

                // Read sample (Mono S16)
                const lo = u8_buf[valid_pos_idx * 2];
                const hi = u8_buf[valid_pos_idx * 2 + 1];

                // Bug Risk 4: Endianness - Use SDL_AUDIO_S16 (Little Endian)
                // Use portable conversion instead of manual bit shifting
                const sample: i16 = std.mem.readInt(i16, &[2]u8{ lo, hi }, .little);

                // Mix stereo
                mix_buf[i * 2] += @intFromFloat(@as(f32, @floatFromInt(sample)) * voice.effective_volume_l);
                mix_buf[i * 2 + 1] += @intFromFloat(@as(f32, @floatFromInt(sample)) * voice.effective_volume_r);

                // Advance cursor by pitch
                voice.cursor += voice.pitch;
            }
        }

        // Clip and Convert to output
        var out_buf: [SAMPLES_TO_MIX * 2]i16 = undefined;
        var i: usize = 0;
        while (i < SAMPLES_TO_MIX * 2) : (i += 1) {
            out_buf[i] = @intCast(std.math.clamp(mix_buf[i], -32767, 32767));
        }

        _ = c.SDL_PutAudioStreamData(stream, &out_buf, out_buf.len * 2);
    }

    pub fn stopAll(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.voices) |*voice| {
            voice.active = false;
        }
    }
};

pub const SDLAudioError = error{
    SDLInitFailed,
    SDLStreamFailed,
};

pub const SDLAudioBackend = struct {
    backend: backend.IAudioBackend, // Interface wrapper
    allocator: std.mem.Allocator,
    stream: *c.SDL_AudioStream,
    mixer: *Mixer,

    pub const CreateError = std.mem.Allocator.Error || SDLAudioError;

    pub fn create(allocator: std.mem.Allocator, _: AudioConfig) CreateError!*SDLAudioBackend {
        // Init SDL Audio if not already
        if (c.SDL_WasInit(c.SDL_INIT_AUDIO) == 0) {
            if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
                log.log.err("Failed to init SDL Audio: {s}", .{c.SDL_GetError()});
                return SDLAudioError.SDLInitFailed;
            }
        }

        // Create Stream
        const spec = c.SDL_AudioSpec{
            .format = MIX_FORMAT,
            .channels = MIX_CHANNELS,
            .freq = MIX_RATE,
        };

        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
        if (stream == null) {
            log.log.err("Failed to open audio stream: {s}", .{c.SDL_GetError()});
            return SDLAudioError.SDLStreamFailed;
        }

        const mixer = try allocator.create(Mixer);
        mixer.* = Mixer.init();

        const self = try allocator.create(SDLAudioBackend);
        self.* = .{
            .backend = .{
                .ptr = self,
                .vtable = &vtable,
            },
            .allocator = allocator,
            .stream = stream.?,
            .mixer = mixer,
        };

        // Start playback
        _ = c.SDL_ResumeAudioDevice(c.SDL_GetAudioStreamDevice(stream));

        return self;
    }

    pub fn destroy(self: *SDLAudioBackend) void {
        _ = c.SDL_DestroyAudioStream(self.stream);
        self.allocator.destroy(self.mixer);
        self.allocator.destroy(self);
    }

    pub fn stopAllVoices(self: *SDLAudioBackend) void {
        self.mixer.stopAll();
    }

    // IAudioBackend impl

    /// Update logic, called from the main thread usually.
    fn update(ptr: *anyopaque) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.update();

        // Keep buffer fed
        // Check how much is queued
        const queued = c.SDL_GetAudioStreamQueued(self.stream);
        const MIN_QUEUED = MIX_RATE * MIX_CHANNELS * 2 / 10; // 100ms

        if (queued < MIN_QUEUED) {
            // mix() acquires the mutex internally
            self.mixer.mix(self.stream, 0);
        }
    }

    fn setListener(ptr: *anyopaque, pos: Vec3, fwd: Vec3, up: Vec3) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        self.mixer.listener_pos = pos;
        self.mixer.listener_fwd = fwd;
        self.mixer.listener_up = up;
    }

    fn playSound(ptr: *anyopaque, sound: *const types.SoundData, config: types.PlayConfig) types.VoiceHandle {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        return self.mixer.play(sound, config);
    }

    fn stopVoice(ptr: *anyopaque, handle: types.VoiceHandle) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.stopVoice(handle);
    }

    fn stopAll(ptr: *anyopaque) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.stopAll();
    }

    fn setMasterVolume(ptr: *anyopaque, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        self.mixer.master_volume = std.math.clamp(vol, 0.0, 1.0);
    }

    fn setCategoryVolume(ptr: *anyopaque, cat: types.SoundCategory, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.mutex.lock();
        defer self.mixer.mutex.unlock();
        const clamped = std.math.clamp(vol, 0.0, 1.0);

        switch (cat) {
            .master => self.mixer.master_volume = clamped,
            .music => self.mixer.music_volume = clamped,
            .sfx => self.mixer.sfx_volume = clamped,
            .ambient => self.mixer.ambient_volume = clamped,
        }
    }

    const vtable = backend.IAudioBackend.VTable{
        .update = update,
        .setListener = setListener,
        .playSound = playSound,
        .stopVoice = stopVoice,
        .stopAll = stopAll,
        .setMasterVolume = setMasterVolume,
        .setCategoryVolume = setCategoryVolume,
    };
};
