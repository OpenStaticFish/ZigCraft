//! Biome color lookup for maps.

const BiomeId = @import("biome_registry.zig").BiomeId;

/// Get a packed RGB biome color.
/// Colors adjusted to match textured output (grass/surface colors)
pub fn getBiomeColor(biome_id: BiomeId) u32 {
    return switch (biome_id) {
        .deep_ocean => 0x1A3380, // Darker blue
        .frozen_ocean => 0x9FCBE0, // Ice-covered ocean
        .cold_ocean => 0x295C99, // Cold blue ocean
        .ocean => 0x3366CC, // Standard ocean blue
        .warm_ocean => 0x1F8FCC, // Brighter warm ocean
        .tropical => 0x2BBF9A, // Tropical shallows
        .beach => 0xDDBB88, // Sand color
        .stony_shore => 0x7A7D78, // Rocky coast
        .snowy_beach => 0xE5EEF2, // Snow over sand
        .plains => 0x4D8033, // Darker grass green
        .forest => 0x2D591A, // Darker forest green
        .birch_forest => 0x3DA62E, // Bright birch canopy
        .dark_forest => 0x1F3D17, // Dense dark forest
        .flower_forest => 0x55A83D, // Flower meadow forest
        .taiga => 0x476647, // Muted taiga green
        .snowy_taiga => 0x9AB8AA, // Snowy evergreen
        .old_growth_taiga => 0x33593D, // Ancient spruce green
        .desert => 0xD4B36A, // Warm desert sand
        .snow_tundra => 0xDDEEFF, // Snow
        .mountains => 0x888888, // Stone grey
        .snowy_mountains => 0xCCDDEE, // Snowy stone
        .meadow => 0x66AA44, // Alpine meadow
        .grove => 0x345C38, // High spruce grove
        .snowy_slopes => 0xD6E6F2, // Snowy slope
        .jagged_peaks => 0x8F8F8A, // Exposed stone peak
        .frozen_peaks => 0xB8DFF5, // Ice peak
        .stony_peaks => 0x9C9278, // Warm stony peak
        .river => 0x4488CC, // River blue
        .frozen_river => 0xA8D2E8, // Frozen river ice
        .swamp => 0x334D33, // Dark swamp green
        .mangrove_swamp => 0x264026, // Muted mangrove
        .jungle => 0x1A661A,
        .bamboo_jungle => 0x248C1A,
        .sparse_jungle => 0x2D7A24,
        .savanna => 0x8C8C4D,
        .savanna_plateau => 0x948E4D,
        .windswept_savanna => 0x7A7A40,
        .badlands => 0xAA6633,
        .wooded_badlands => 0x996630,
        .eroded_badlands => 0xBB5522,
        .mushroom_fields => 0x995577, // Mycelium purple
        .foothills => 0x597340, // Transitional green
        .marsh => 0x405933, // Transitional wetland
        .dry_plains => 0x8C8047, // Transitional dry plains
        .coastal_plains => 0x598047, // Transitional coastal
    };
}
