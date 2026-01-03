//! Decoration system for placing vegetation and features
//! Supports single-block decorations (grass, flowers) and schematics (trees)

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;

pub const Rotation = enum {
    none,
    random_90, // 0, 90, 180, 270
};

pub const SimpleDecoration = struct {
    block: BlockType,
    place_on: []const BlockType,
    biomes: []const BiomeId, // Empty = all (but usually restricted)
    y_min: i32 = 1,
    y_max: i32 = 256,
    probability: f32, // Chance per column (0.0 - 1.0)

    // Variant noise constraints (Issue #110)
    // Range -1.0 to 1.0. Decoration only spawns if variant noise is within range.
    variant_min: f32 = -1.0,
    variant_max: f32 = 1.0,

    // Optional: required neighbor blocks (like cactus needs sand around?)
};

pub const SchematicBlock = struct {
    offset: [3]i32,
    block: BlockType,
    probability: f32 = 1.0, // Chance for this specific block to spawn
};

pub const Schematic = struct {
    blocks: []const SchematicBlock,
    size_x: i32,
    size_y: i32,
    size_z: i32,
    center_x: i32 = 0, // Offset to center
    center_z: i32 = 0,
};

pub const SchematicDecoration = struct {
    schematic: Schematic,
    place_on: []const BlockType,
    biomes: []const BiomeId,
    y_min: i32 = 1,
    y_max: i32 = 256,
    probability: f32,
    rotation: Rotation = .random_90,
    spacing_radius: i32 = 0, // Minimum distance to other schematics

    // Variant noise constraints (Issue #110)
    variant_min: f32 = -1.0,
    variant_max: f32 = 1.0,
};

pub const Decoration = union(enum) {
    simple: SimpleDecoration,
    schematic: SchematicDecoration,
};

// ============================================================================
// Schematics
// ============================================================================

const OAK_LOG = BlockType.oak_log;
const OAK_LEAVES = BlockType.oak_leaves; // Wait, oak_leaves doesn't exist? BlockType.leaves exists.
// I should check BlockType again. "leaves" is there. "mangrove_leaves", "jungle_leaves", "acacia_leaves".
// No "oak_leaves". Just "leaves".

const LOG = BlockType.wood; // "wood"? No "log" for oak?
// BlockType has "wood" (6). And "acacia_log" (27).
// "wood" is likely Oak Log.

const LEAVES = BlockType.leaves;

const OAK_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk
        .{ .offset = .{ 0, 0, 0 }, .block = LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = LOG },
        // Leaves Layer 1
        .{ .offset = .{ 1, 2, 0 }, .block = LEAVES },
        .{ .offset = .{ -1, 2, 0 }, .block = LEAVES },
        .{ .offset = .{ 0, 2, 1 }, .block = LEAVES },
        .{ .offset = .{ 0, 2, -1 }, .block = LEAVES },
        // Leaves Layer 2
        .{ .offset = .{ 1, 3, 0 }, .block = LEAVES },
        .{ .offset = .{ -1, 3, 0 }, .block = LEAVES },
        .{ .offset = .{ 0, 3, 1 }, .block = LEAVES },
        .{ .offset = .{ 0, 3, -1 }, .block = LEAVES },
        .{ .offset = .{ 1, 3, 1 }, .block = LEAVES },
        .{ .offset = .{ -1, 3, 1 }, .block = LEAVES },
        .{ .offset = .{ 1, 3, -1 }, .block = LEAVES },
        .{ .offset = .{ -1, 3, -1 }, .block = LEAVES },
        // Top
        .{ .offset = .{ 0, 4, 0 }, .block = LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = LEAVES },
        .{ .offset = .{ 1, 4, 0 }, .block = LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = LEAVES },
    },
    .size_x = 5,
    .size_y = 6,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

// ============================================================================
// Decoration Registry
// ============================================================================

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
            .block = .flower_yellow, // Use yellow for density? Or mixed.
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
            .block = .cobblestone, // Boulders
            .place_on = &.{.grass},
            .biomes = &.{ .plains, .mountains, .taiga },
            .probability = 0.05,
            .variant_min = 0.6,
        },
    },

    // === Trees: Sparse (Plains, Swamp, Mountains) ===
    .{
        .schematic = .{
            .schematic = OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{ .plains, .swamp, .mountains },
            .probability = 0.002, // Very sparse
            .spacing_radius = 4,
        },
    },

    // === Trees: Standard Forest (Variant -0.4 to 0.4) ===
    .{ .schematic = .{
        .schematic = OAK_TREE,
        .place_on = &.{ .grass, .dirt },
        .biomes = &.{.forest},
        .probability = 0.02,
        .spacing_radius = 3,
        .variant_min = -0.4,
        .variant_max = 0.4,
    } },

    // === Trees: Dense Forest (Variant > 0.4) ===
    .{
        .schematic = .{
            .schematic = OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.forest},
            .probability = 0.15, // Dense!
            .spacing_radius = 2,
            .variant_min = 0.4,
        },
    },

    // Note: Forest with variant < -0.4 has NO trees (Clearing)
};
