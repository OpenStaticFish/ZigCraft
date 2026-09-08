const std = @import("std");
const AudioSystem = @import("engine-audio").AudioSystem;

pub const AudioSystemManager = struct {
    audio_system: *AudioSystem,

    pub fn init(allocator: std.mem.Allocator) !*AudioSystemManager {
        const self = try allocator.create(AudioSystemManager);
        errdefer allocator.destroy(self);

        self.* = .{
            .audio_system = try AudioSystem.init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *AudioSystemManager) void {
        const allocator = self.audio_system.allocator;
        self.audio_system.deinit();
        allocator.destroy(self);
    }

    pub fn update(self: *AudioSystemManager) void {
        self.audio_system.update();
    }
};

test "AudioSystemManager teardown preserves allocator ownership" {
    const allocator = std.testing.allocator;
    const audio = try allocator.create(AudioSystem);
    errdefer allocator.destroy(audio);
    audio.* = .{
        .allocator = allocator,
        .backend = undefined,
        .manager = @import("engine-audio").manager.SoundManager.init(allocator),
        .enabled = false,
    };
    const manager = try allocator.create(AudioSystemManager);
    manager.* = .{ .audio_system = audio };
    manager.deinit();
}
