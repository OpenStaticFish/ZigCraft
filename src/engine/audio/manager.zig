//! Resource manager for audio data.

const std = @import("std");
const types = @import("types.zig");
const log = @import("../core/log.zig");
const c = @import("../../c.zig").c;

pub const SoundManager = struct {
    allocator: std.mem.Allocator,
    sounds: std.ArrayListUnmanaged(types.SoundData),
    sound_names: std.StringHashMapUnmanaged(types.SoundHandle),
    next_handle: types.SoundHandle = 1,

    pub fn init(allocator: std.mem.Allocator) SoundManager {
        return .{
            .allocator = allocator,
            .sounds = .{},
            .sound_names = .{},
        };
    }

    pub fn deinit(self: *SoundManager) void {
        for (self.sounds.items) |*sound| {
            if (sound.buffer.len > 0) {
                // Determine if we allocated this or if SDL did.
                // For now, assume SDL allocated loaded WAVs via SDL_LoadWAV (which uses SDL_malloc),
                // but generated sounds use our allocator.
                // However, to keep it simple and safe:
                // We will copy SDL loaded data into our own buffers so we own everything.
                self.allocator.free(sound.buffer);
            }
        }
        self.sounds.deinit(self.allocator);
        var it = self.sound_names.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.sound_names.deinit(self.allocator);
    }

    pub fn getSound(self: *const SoundManager, handle: types.SoundHandle) ?*const types.SoundData {
        if (handle == types.InvalidSoundHandle) return null;
        // Search linear for now, optimized later if needed or use a map for handles if non-contiguous
        // Actually, handle can be index + 1
        const index = handle - 1;
        if (index < self.sounds.items.len) {
            return &self.sounds.items[index];
        }
        return null;
    }

    pub fn getSoundByName(self: *const SoundManager, name: []const u8) types.SoundHandle {
        return self.sound_names.get(name) orelse types.InvalidSoundHandle;
    }

    pub fn createTestSound(self: *SoundManager, name: []const u8) !types.SoundHandle {
        if (self.sound_names.contains(name)) {
            return self.sound_names.get(name).?;
        }

        const frequency: u32 = 44100;
        const length_seconds: f32 = 1.0;
        const num_samples: u32 = @intFromFloat(@as(f32, @floatFromInt(frequency)) * length_seconds);
        const buffer = try self.allocator.alloc(u8, num_samples * 2); // 16-bit mono

        // Generate A440 sine wave
        var i: u32 = 0;
        while (i < num_samples) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frequency));
            const val = @sin(t * 440.0 * std.math.tau);
            const sample: i16 = @intFromFloat(val * 16000.0); // 50% volume

            const lo: u8 = @intCast(sample & 0xFF);
            const hi: u8 = @intCast((sample >> 8) & 0xFF);

            buffer[i * 2] = lo;
            buffer[i * 2 + 1] = hi;
        }

        const sound = types.SoundData{
            .buffer = buffer,
            .frequency = frequency,
            .channels = 1,
            .format = .signed16,
            .length_samples = num_samples,
        };

        try self.sounds.append(self.allocator, sound);

        const handle = self.next_handle;
        self.next_handle += 1;

        const name_copy = try self.allocator.dupe(u8, name);
        try self.sound_names.put(self.allocator, name_copy, handle);

        log.log.info("Created test sound '{s}' (Handle: {})", .{ name, handle });
        return handle;
    }

    // Future: loadWav using SDL_LoadWAV, converting to our managed format
};
