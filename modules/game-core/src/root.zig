pub const block_texture_definitions = @import("block_texture_definitions.zig");

test {
    _ = @import("test_root.zig");
}
pub const block_outline = @import("block_outline.zig");
pub const benchmark = @import("benchmark.zig");
pub const hand_renderer = @import("hand_renderer.zig");
pub const input_mapper = @import("input_mapper.zig");
pub const input_settings = @import("input_settings.zig");
pub const inventory = @import("inventory.zig");
pub const map_controller = @import("map_controller.zig");
pub const player = @import("player.zig");
pub const seed = @import("seed.zig");
pub const session = @import("session.zig");
pub const settings = @import("settings.zig");
pub const settings_manager = @import("settings_manager.zig");
pub const text_input = @import("text_input.zig");

pub const hotbar = @import("ui/hotbar.zig");
pub const inventory_ui = @import("ui/inventory_ui.zig");
pub const session_hud = @import("ui/session_hud.zig");

pub const BLOCK_TEXTURE_DEFINITIONS = block_texture_definitions.BLOCK_TEXTURE_DEFINITIONS;
pub const BenchmarkRunner = benchmark.BenchmarkRunner;
pub const BENCHMARK_WORLD_SEED = benchmark.BENCHMARK_WORLD_SEED;
pub const BuildConfig = session.BuildConfig;
pub const GameSession = session.GameSession;
pub const InputMapper = input_mapper.InputMapper;
pub const InputSettings = input_settings.InputSettings;
pub const Inventory = inventory.Inventory;
pub const Player = player.Player;
pub const Settings = settings.Settings;
pub const SettingsManager = settings_manager.SettingsManager;

pub const settings_tests = @import("settings/tests.zig");
pub const settings_persistence_tests = @import("settings/persistence_tests.zig");
