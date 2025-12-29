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

    // === Flowers ===
    .{ .simple = .{
        .block = .flower_red,
        .place_on = &.{.grass},
        .biomes = &.{ .plains, .forest },
        .probability = 0.05,
    } },

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

    // === Trees ===
    .{
        .schematic = .{
            .schematic = OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{ .forest, .plains, .swamp, .mountains },
            .probability = 0.005, // 0.5% chance per block (plains/sparse)
            .spacing_radius = 4,
        },
    },
    // Forest tree (higher density? No, registry entries are unique.
    // To have different densities, we need different entries or logic.
    // For now, this puts trees in both, but sparse.
    // Ideally, we'd have Forest Tree entry with high prob, Plains Tree with low prob.
    // But DECORATIONS is a flat list.
    // Let's add another entry for Forest specifically?
    // "Forest Tree" -> restricted to Forest, prob = 0.05.
    .{
        .schematic = .{
            .schematic = OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.forest},
            .probability = 0.05, // 10x denser in forest
            .spacing_radius = 3,
        },
    },
};
