//! SDL3 Audio Backend with Software 3D Mixer.

const std = @import("std");
const c = @import("../../../c.zig").c;
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const Vec3 = @import("../../math/vec3.zig").Vec3;
const log = @import("../../core/log.zig");

// Constants
const MAX_VOICES = 64;
const MIX_RATE = 44100;
const MIX_CHANNELS = 2; // Stereo
const MIX_FORMAT = c.SDL_AUDIO_S16;

const Voice = struct {
    active: bool = false,
    sound_data: ?*const types.SoundData = null,
    cursor: usize = 0, // Sample index

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
};

const Mixer = struct {
    voices: [MAX_VOICES]Voice = undefined,
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

    pub fn play(self: *Mixer, sound: *const types.SoundData, config: types.PlayConfig) void {
        // Find free voice
        for (&self.voices) |*voice| {
            if (!voice.active) {
                voice.* = .{
                    .active = true,
                    .sound_data = sound,
                    .cursor = 0,
                    .loop = config.loop,
                    .pitch = config.pitch,
                    .base_volume = config.volume,
                    .category = config.category,
                    .is_spatial = config.is_spatial,
                    .position = config.position,
                    .min_dist = config.min_distance,
                    .max_dist = config.max_distance,
                };
                // Initial update to set volume
                self.updateVoiceSpatial(voice);
                return;
            }
        }
        // Could implement voice stealing here (steal oldest or lowest priority)
    }

    fn updateVoiceSpatial(self: *Mixer, voice: *Voice) void {
        var vol = voice.base_volume * self.master_volume;

        // Apply category volume
        switch (voice.category) {
            .music => vol *= self.music_volume,
            .sfx => vol *= self.sfx_volume,
            .ambient => vol *= self.ambient_volume,
            else => {},
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
                pan = dir.dot(self.listener_right);
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
        self.listener_right = self.listener_fwd.cross(self.listener_up).normalize();

        for (&self.voices) |*voice| {
            if (voice.active) {
                self.updateVoiceSpatial(voice);
            }
        }
    }

    // Mix samples into the output buffer (S16 stereo)
    pub fn mix(self: *Mixer, stream: *c.SDL_AudioStream, _: c_int) void {
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

            const data = voice.sound_data.?;
            const u8_buf = data.buffer;

            // Assuming S16 format for now from Manager
            // TODO: Handle other formats

            var i: usize = 0;
            while (i < SAMPLES_TO_MIX) : (i += 1) {
                if (voice.cursor * 2 >= u8_buf.len) {
                    if (voice.loop) {
                        voice.cursor = 0;
                    } else {
                        voice.active = false;
                        break;
                    }
                }

                // Read sample (Mono S16)
                const lo = u8_buf[voice.cursor * 2];
                const hi = u8_buf[voice.cursor * 2 + 1];
                const sample: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));

                // Mix stereo
                mix_buf[i * 2] += @intFromFloat(@as(f32, @floatFromInt(sample)) * voice.effective_volume_l);
                mix_buf[i * 2 + 1] += @intFromFloat(@as(f32, @floatFromInt(sample)) * voice.effective_volume_r);

                voice.cursor += 1; // Basic playback rate (no pitch shifting yet)
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
};

pub const SDLAudioBackend = struct {
    backend: backend.IAudioBackend, // Interface wrapper
    allocator: std.mem.Allocator,
    stream: *c.SDL_AudioStream,
    mixer: *Mixer,

    pub fn create(allocator: std.mem.Allocator) !*SDLAudioBackend {
        // Init SDL Audio if not already
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            log.log.err("Failed to init SDL Audio: {s}", .{c.SDL_GetError()});
            return error.SDLInitFailed;
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
            return error.SDLStreamFailed;
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

    // IAudioBackend impl

    fn update(ptr: *anyopaque) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.update();

        // Keep buffer fed
        // Check how much is queued
        const queued = c.SDL_GetAudioStreamQueued(self.stream);
        const MIN_QUEUED = MIX_RATE * MIX_CHANNELS * 2 / 10; // 100ms

        if (queued < MIN_QUEUED) {
            self.mixer.mix(self.stream, 0);
        }
    }

    fn setListener(ptr: *anyopaque, pos: Vec3, fwd: Vec3, up: Vec3) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.listener_pos = pos;
        self.mixer.listener_fwd = fwd;
        self.mixer.listener_up = up;
    }

    fn playSound(ptr: *anyopaque, sound: *const types.SoundData, config: types.PlayConfig) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.play(sound, config);
    }

    fn setMasterVolume(ptr: *anyopaque, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        self.mixer.master_volume = vol;
    }

    fn setCategoryVolume(ptr: *anyopaque, cat: types.SoundCategory, vol: f32) void {
        const self: *SDLAudioBackend = @ptrCast(@alignCast(ptr));
        switch (cat) {
            .master => self.mixer.master_volume = vol,
            .music => self.mixer.music_volume = vol,
            .sfx => self.mixer.sfx_volume = vol,
            .ambient => self.mixer.ambient_volume = vol,
        }
    }

    const vtable = backend.IAudioBackend.VTable{
        .update = update,
        .setListener = setListener,
        .playSound = playSound,
        .setMasterVolume = setMasterVolume,
        .setCategoryVolume = setCategoryVolume,
    };
};
