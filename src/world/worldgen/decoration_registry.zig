//! Registry of all available decorations and their placement rules.
//! Configures the specific decorations (both simple and schematic) that populate the world.
//! Re-exports decoration types for consumers like the generator.

const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;

// Import types and schematics
pub const types = @import("decoration_types.zig");
pub const schematics = @import("schematics.zig");

// Re-export types for consumers (like generator.zig)
pub const Rotation = types.Rotation;
pub const SimpleDecoration = types.SimpleDecoration;
pub const SchematicBlock = types.SchematicBlock;
pub const Schematic = types.Schematic;
pub const SchematicDecoration = types.SchematicDecoration;
pub const Decoration = types.Decoration;

pub const DECORATIONS = [_]Decoration{
    // === Grass ===
    .{ .simple = .{
        .block = .tall_grass,
        .place_on = &.{.grass},
        .biomes = &.{ .plains, .forest, .savanna, .swamp, .jungle, .taiga },
        .probability = 0.5,
    } },

    // === Flowers (Standard) ===
    .{
        .simple = .{
            .block = .flower_red,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .forest },
            .probability = 0.02,
            .variant_min = -0.6, // Normal distribution
        },
    },

    // === Flower Patches (Variant < -0.6) ===
    .{
        .simple = .{
            .block = .flower_yellow,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .forest },
            .probability = 0.4, // Dense!
            .variant_max = -0.6,
        },
    },

    // === Dead Bush ===
    .{ .simple = .{
        .block = .dead_bush,
        .place_on = &.{ .sand, .red_sand },
        .biomes = &.{ .desert, .badlands },
        .probability = 0.02,
    } },

    // === Cacti ===
    .{ .simple = .{
        .block = .cactus,
        .place_on = &.{.sand},
        .biomes = &.{.desert},
        .probability = 0.01,
    } },

    // === Boulders (Rocky Patches: Variant > 0.6) ===
    .{
        .simple = .{
            .block = .cobblestone,
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .mountains, .taiga },
            .probability = 0.05,
            .variant_min = 0.6,
        },
    },

    // === Trees: Sparse (Plains, Mountains) ===
    .{
        .schematic = .{
            .schematic = schematics.OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{ .plains, .mountains },
            .probability = 0.002, // Very sparse
            .spacing_radius = 4,
        },
    },

    // === Forest: Oak Trees (Standard) ===
    .{ .schematic = .{
        .schematic = schematics.OAK_TREE,
        .place_on = &.{ .grass, .dirt },
        .biomes = &.{.forest},
        .probability = 0.02,
        .spacing_radius = 3,
        .variant_min = -0.4,
        .variant_max = 0.4,
    } },

    // === Forest: Birch Trees (Standard) ===
    .{ .schematic = .{
        .schematic = schematics.BIRCH_TREE,
        .place_on = &.{ .grass, .dirt },
        .biomes = &.{.forest},
        .probability = 0.015,
        .spacing_radius = 3,
        .variant_min = 0.0,
        .variant_max = 0.6,
    } },

    // === Forest: Dense Oak (Variant > 0.4) ===
    .{
        .schematic = .{
            .schematic = schematics.OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.forest},
            .probability = 0.1,
            .spacing_radius = 2,
            .variant_min = 0.4,
        },
    },

    // === Taiga: Spruce Trees ===
    .{
        .schematic = .{
            .schematic = schematics.SPRUCE_TREE,
            .place_on = &.{ .grass, .dirt, .snow_block },
            .biomes = &.{ .taiga, .snow_tundra },
            .probability = 0.08,
            .spacing_radius = 3,
        },
    },

    // === Swamp: Swamp Oak ===
    .{
        .schematic = .{
            .schematic = schematics.SWAMP_OAK,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.swamp},
            .probability = 0.05,
            .spacing_radius = 4,
        },
    },

    // === Mangrove Swamp: Mangrove Trees ===
    .{
        .schematic = .{
            .schematic = schematics.MANGROVE_TREE,
            .place_on = &.{ .mud, .grass },
            .biomes = &.{.mangrove_swamp},
            .probability = 0.12,
            .spacing_radius = 3,
        },
    },

    // === Jungle: Jungle Trees ===
    .{
        .schematic = .{
            .schematic = schematics.JUNGLE_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.jungle},
            .probability = 0.15,
            .spacing_radius = 2,
        },
    },

    // === Savanna: Acacia Trees ===
    .{
        .schematic = .{
            .schematic = schematics.ACACIA_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.savanna},
            .probability = 0.015,
            .spacing_radius = 5,
        },
    },

    // === Mushroom Fields: Huge Mushrooms ===
    .{
        .schematic = .{
            .schematic = schematics.HUGE_RED_MUSHROOM,
            .place_on = &.{.mycelium},
            .biomes = &.{.mushroom_fields},
            .probability = 0.03,
            .spacing_radius = 4,
        },
    },
    .{
        .schematic = .{
            .schematic = schematics.HUGE_BROWN_MUSHROOM,
            .place_on = &.{.mycelium},
            .biomes = &.{.mushroom_fields},
            .probability = 0.03,
            .spacing_radius = 4,
        },
    },
};
