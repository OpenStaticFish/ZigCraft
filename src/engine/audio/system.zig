//! High-level Audio System.

const std = @import("std");
const types = @import("types.zig");
const backend_pkg = @import("backend.zig");
const manager_pkg = @import("manager.zig");
const sdl_backend = @import("backends/sdl_audio.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;
const log = @import("../core/log.zig");

pub const AudioSystem = struct {
    allocator: std.mem.Allocator,
    backend: *sdl_backend.SDLAudioBackend,
    manager: manager_pkg.SoundManager,

    // Config
    enabled: bool = true,

    /// Initialize the Audio System and the SDL backend.
    pub fn init(allocator: std.mem.Allocator) !*AudioSystem {
        log.log.info("Initializing Audio System...", .{});

        const backend_inst = try sdl_backend.SDLAudioBackend.create(allocator);

        const self = try allocator.create(AudioSystem);
        self.* = .{
            .allocator = allocator,
            .backend = backend_inst,
            .manager = manager_pkg.SoundManager.init(allocator),
        };

        // Create some default test sounds
        _ = try self.manager.createTestSound("test_tone");

        return self;
    }

    /// Shutdown the audio system and free resources.
    pub fn deinit(self: *AudioSystem) void {
        self.stopAll();
        self.manager.deinit();
        self.backend.destroy();
        self.allocator.destroy(self);
    }

    /// Update the audio backend. Should be called once per frame.
    pub fn update(self: *AudioSystem) void {
        if (!self.enabled) return;
        self.backend.backend.update();
    }

    /// Update the listener's 3D position and orientation.
    /// listener_pos: Position in world space.
    /// listener_fwd: Forward vector (normalized).
    /// listener_up: Up vector (normalized).
    pub fn setListener(self: *AudioSystem, listener_pos: Vec3, listener_fwd: Vec3, listener_up: Vec3) void {
        if (!self.enabled) return;
        self.backend.backend.setListener(listener_pos, listener_fwd, listener_up);
    }

    /// Set the master volume (applied to all sounds).
    /// volume: 0.0 to 1.0
    pub fn setMasterVolume(self: *AudioSystem, volume: f32) void {
        if (!self.enabled) return;
        const clamped = std.math.clamp(volume, 0.0, 1.0);
        self.backend.backend.setMasterVolume(clamped);
    }

    /// Set volume for a specific category (Music, SFX, Ambient).
    /// volume: 0.0 to 1.0
    pub fn setCategoryVolume(self: *AudioSystem, category: types.SoundCategory, volume: f32) void {
        if (!self.enabled) return;
        const clamped = std.math.clamp(volume, 0.0, 1.0);
        self.backend.backend.setCategoryVolume(category, clamped);
    }

    /// Play a sound by name (2D, no spatialization).
    pub fn play(self: *AudioSystem, name: []const u8) ?types.VoiceHandle {
        if (!self.enabled) return null;

        const handle = self.manager.getSoundByName(name);
        if (handle == types.InvalidSoundHandle) {
            log.log.warn("Sound not found: {s}", .{name});
            return null;
        }

        if (self.manager.getSound(handle)) |sound| {
            return self.backend.backend.playSound(sound, .{});
        }
        return null;
    }

    /// Play a 3D spatial sound at the given position.
    pub fn playSpatial(self: *AudioSystem, name: []const u8, pos: Vec3) ?types.VoiceHandle {
        if (!self.enabled) return null;

        const handle = self.manager.getSoundByName(name);
        if (handle == types.InvalidSoundHandle) return null;

        if (self.manager.getSound(handle)) |sound| {
            return self.backend.backend.playSound(sound, .{
                .is_spatial = true,
                .position = pos,
            });
        }
        return null;
    }

    /// Stop a specific voice handle.
    pub fn stop(self: *AudioSystem, handle: types.VoiceHandle) void {
        if (!self.enabled) return;
        self.backend.backend.stopVoice(handle);
    }

    /// Stop all currently playing sounds.
    pub fn stopAll(self: *AudioSystem) void {
        self.backend.stopAllVoices();
    }
};
