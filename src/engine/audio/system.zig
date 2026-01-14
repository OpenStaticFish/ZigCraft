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

    pub fn deinit(self: *AudioSystem) void {
        self.stopAll();
        self.manager.deinit();
        self.backend.destroy();
        self.allocator.destroy(self);
    }

    pub fn update(self: *AudioSystem) void {
        if (!self.enabled) return;
        self.backend.backend.update();
    }

    pub fn setListener(self: *AudioSystem, listener_pos: Vec3, listener_fwd: Vec3, listener_up: Vec3) void {
        if (!self.enabled) return;
        self.backend.backend.setListener(listener_pos, listener_fwd, listener_up);
    }

    pub fn setMasterVolume(self: *AudioSystem, volume: f32) void {
        if (!self.enabled) return;
        self.backend.backend.setMasterVolume(volume);
    }

    pub fn setCategoryVolume(self: *AudioSystem, category: types.SoundCategory, volume: f32) void {
        if (!self.enabled) return;
        self.backend.backend.setCategoryVolume(category, volume);
    }

    pub fn play(self: *AudioSystem, name: []const u8) void {
        if (!self.enabled) return;

        const handle = self.manager.getSoundByName(name);
        if (handle == types.InvalidSoundHandle) {
            log.log.warn("Sound not found: {s}", .{name});
            return;
        }

        if (self.manager.getSound(handle)) |sound| {
            self.backend.backend.playSound(sound, .{});
        }
    }

    pub fn playSpatial(self: *AudioSystem, name: []const u8, pos: Vec3) void {
        if (!self.enabled) return;

        const handle = self.manager.getSoundByName(name);
        if (handle == types.InvalidSoundHandle) return;

        if (self.manager.getSound(handle)) |sound| {
            self.backend.backend.playSound(sound, .{
                .is_spatial = true,
                .position = pos,
            });
        }
    }

    pub fn stopAll(self: *AudioSystem) void {
        self.backend.stopAll();
    }
};
