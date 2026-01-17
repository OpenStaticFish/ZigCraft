pub const data = @import("settings/data.zig");
pub const persistence = @import("settings/persistence.zig");
pub const ui_helpers = @import("settings/ui_helpers.zig");
pub const apply_logic = @import("settings/apply.zig");

// JSON presets support (replacing static presets)
pub const json_presets = @import("settings/json_presets.zig");
pub const initPresets = json_presets.initPresets;
pub const deinitPresets = json_presets.deinitPresets;

// Re-export core types for convenience
pub const Settings = data.Settings;
pub const ShadowQuality = data.ShadowQuality;
pub const SHADOW_QUALITIES = data.SHADOW_QUALITIES;
pub const Resolution = data.Resolution;
pub const RESOLUTIONS = data.RESOLUTIONS;
pub const PresetConfig = json_presets.PresetConfig;

// Data-driven settings support
pub const SettingMetadata = data.SettingMetadata;
