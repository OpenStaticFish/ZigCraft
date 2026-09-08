pub const backend = @import("backend.zig");

test {
    _ = @import("test_root.zig");
}
pub const manager = @import("manager.zig");
pub const sdl_audio = @import("backends/sdl_audio.zig");
pub const system = @import("system.zig");
pub const types = @import("types.zig");

pub const AudioFormat = types.AudioFormat;
pub const AudioSystem = system.AudioSystem;
pub const SDLAudioBackend = sdl_audio.SDLAudioBackend;
pub const InvalidSoundHandle = types.InvalidSoundHandle;
pub const PlayConfig = types.PlayConfig;
pub const SoundCategory = types.SoundCategory;
pub const SoundData = types.SoundData;
pub const SoundHandle = types.SoundHandle;
pub const VoiceHandle = types.VoiceHandle;
