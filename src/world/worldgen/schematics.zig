//! Tree and feature schematics.
//! Contains static definitions for multi-block structures like trees.
//! These schematics are referenced by the decoration registry.

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const chunk_mod = @import("../chunk.zig");
const Chunk = chunk_mod.Chunk;
const CHUNK_SIZE_X = chunk_mod.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = chunk_mod.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = chunk_mod.CHUNK_SIZE_Z;

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

    pub fn place(self: Schematic, chunk: *Chunk, x: u32, y: u32, z: u32, random: std.Random) void {
        const center_x = @as(i32, @intCast(x));
        const center_y = @as(i32, @intCast(y));
        const center_z = @as(i32, @intCast(z));

        for (self.blocks) |sb| {
            // Skip random check for blocks with 100% probability (optimization)
            if (sb.probability < 1.0) {
                if (random.float(f32) >= sb.probability) continue;
            }
            const bx = center_x + sb.offset[0] - self.center_x;
            const by = center_y + sb.offset[1];
            const bz = center_z + sb.offset[2] - self.center_z;

            if (bx >= 0 and bx < CHUNK_SIZE_X and bz >= 0 and bz < CHUNK_SIZE_Z and by >= 0 and by < CHUNK_SIZE_Y) {
                // Don't overwrite existing solid blocks to avoid trees deleting ground
                const existing = chunk.getBlock(@intCast(bx), @intCast(by), @intCast(bz));
                if (existing == .air or existing.isTransparent()) {
                    chunk.setBlock(@intCast(bx), @intCast(by), @intCast(bz), sb.block);
                }
            }
        }
    }
};

const OAK_LOG = BlockType.wood;
const OAK_LEAVES = BlockType.leaves;

const BIRCH_LOG = BlockType.birch_log;
const BIRCH_LEAVES = BlockType.birch_leaves;

const SPRUCE_LOG = BlockType.spruce_log;
const SPRUCE_LEAVES = BlockType.spruce_leaves;

const MANGROVE_LOG = BlockType.mangrove_log;
const MANGROVE_LEAVES = BlockType.mangrove_leaves;
const MANGROVE_ROOTS = BlockType.mangrove_roots;

const JUNGLE_LOG = BlockType.jungle_log;
const JUNGLE_LEAVES = BlockType.jungle_leaves;

const ACACIA_LOG = BlockType.acacia_log;
const ACACIA_LEAVES = BlockType.acacia_leaves;

const VINE = BlockType.vine;

const MUSHROOM_STEM = BlockType.mushroom_stem;
const RED_MUSHROOM_BLOCK = BlockType.red_mushroom_block;
const BROWN_MUSHROOM_BLOCK = BlockType.brown_mushroom_block;

pub const OAK_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk
        .{ .offset = .{ 0, 0, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = OAK_LOG },
        // Leaves Layer 1
        .{ .offset = .{ 1, 2, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 2, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 2, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 2, -1 }, .block = OAK_LEAVES },
        // Leaves Layer 2
        .{ .offset = .{ 1, 3, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 3, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 3, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, -1 }, .block = OAK_LEAVES },
        // Top
        .{ .offset = .{ 0, 4, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 4, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = OAK_LEAVES },
    },
    .size_x = 5,
    .size_y = 6,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const BIRCH_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk (5 blocks tall)
        .{ .offset = .{ 0, 0, 0 }, .block = BIRCH_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = BIRCH_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = BIRCH_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = BIRCH_LOG },
        .{ .offset = .{ 0, 4, 0 }, .block = BIRCH_LOG },
        // Leaves Layer 1
        .{ .offset = .{ 1, 3, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ -1, 3, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 3, 1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 3, -1 }, .block = BIRCH_LEAVES },
        // Leaves Layer 2
        .{ .offset = .{ 1, 4, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 1, 4, 1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ -1, 4, 1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 1, 4, -1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ -1, 4, -1 }, .block = BIRCH_LEAVES },
        // Top
        .{ .offset = .{ 0, 5, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 5, 1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 0, 5, -1 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ 1, 5, 0 }, .block = BIRCH_LEAVES },
        .{ .offset = .{ -1, 5, 0 }, .block = BIRCH_LEAVES },
    },
    .size_x = 5,
    .size_y = 7,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const SPRUCE_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk (6 blocks tall)
        .{ .offset = .{ 0, 0, 0 }, .block = SPRUCE_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = SPRUCE_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = SPRUCE_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = SPRUCE_LOG },
        .{ .offset = .{ 0, 4, 0 }, .block = SPRUCE_LOG },
        .{ .offset = .{ 0, 5, 0 }, .block = SPRUCE_LOG },
        // Bottom Conical Layer (Level 2)
        .{ .offset = .{ 1, 2, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 2, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 2, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 2, -1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 1, 2, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 2, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 1, 2, -1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 2, -1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 2, 2, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -2, 2, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 2, 2 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 2, -2 }, .block = SPRUCE_LEAVES },
        // Middle Conical Layer (Level 4)
        .{ .offset = .{ 1, 4, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 1, 4, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 4, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 1, 4, -1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 4, -1 }, .block = SPRUCE_LEAVES },
        // Top Conical Layer (Level 6)
        .{ .offset = .{ 0, 6, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 1, 5, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ -1, 5, 0 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 5, 1 }, .block = SPRUCE_LEAVES },
        .{ .offset = .{ 0, 5, -1 }, .block = SPRUCE_LEAVES },
    },
    .size_x = 5,
    .size_y = 8,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const SWAMP_OAK = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk
        .{ .offset = .{ 0, 0, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = OAK_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = OAK_LOG },
        // Leaves Layer 1
        .{ .offset = .{ 1, 2, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 2, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 2, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 2, -1 }, .block = OAK_LEAVES },
        // Leaves Layer 2
        .{ .offset = .{ 1, 3, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 3, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 3, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 3, -1 }, .block = OAK_LEAVES },
        // Top
        .{ .offset = .{ 0, 4, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = OAK_LEAVES },
        .{ .offset = .{ 1, 4, 0 }, .block = OAK_LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = OAK_LEAVES },
        // Vines
        .{ .offset = .{ 1, 1, 0 }, .block = VINE, .probability = 0.5 },
        .{ .offset = .{ -1, 1, 0 }, .block = VINE, .probability = 0.5 },
        .{ .offset = .{ 0, 1, 1 }, .block = VINE, .probability = 0.5 },
        .{ .offset = .{ 0, 1, -1 }, .block = VINE, .probability = 0.5 },
        .{ .offset = .{ 1, 2, 1 }, .block = VINE, .probability = 0.5 },
        .{ .offset = .{ -1, 2, 1 }, .block = VINE, .probability = 0.5 },
    },
    .size_x = 5,
    .size_y = 6,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const JUNGLE_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk (8 blocks tall)
        .{ .offset = .{ 0, 0, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 4, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 5, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 6, 0 }, .block = JUNGLE_LOG },
        .{ .offset = .{ 0, 7, 0 }, .block = JUNGLE_LOG },
        // Large Canopy Level 1 (y=6)
        .{ .offset = .{ 1, 6, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 6, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 6, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 6, -1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 1, 6, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 6, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 1, 6, -1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 6, -1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 2, 6, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -2, 6, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 6, 2 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 6, -2 }, .block = JUNGLE_LEAVES },
        // Large Canopy Level 2 (y=7)
        .{ .offset = .{ 1, 7, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 7, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 7, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 7, -1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 1, 7, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 7, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 1, 7, -1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 7, -1 }, .block = JUNGLE_LEAVES },
        // Top
        .{ .offset = .{ 0, 8, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 1, 8, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ -1, 8, 0 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 8, 1 }, .block = JUNGLE_LEAVES },
        .{ .offset = .{ 0, 8, -1 }, .block = JUNGLE_LEAVES },
        // Vines
        .{ .offset = .{ 1, 3, 0 }, .block = VINE, .probability = 0.7 },
        .{ .offset = .{ -1, 4, 0 }, .block = VINE, .probability = 0.7 },
        .{ .offset = .{ 0, 2, 1 }, .block = VINE, .probability = 0.7 },
        .{ .offset = .{ 0, 5, -1 }, .block = VINE, .probability = 0.7 },
    },
    .size_x = 5,
    .size_y = 10,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const ACACIA_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Trunk
        .{ .offset = .{ 0, 0, 0 }, .block = ACACIA_LOG },
        .{ .offset = .{ 0, 1, 0 }, .block = ACACIA_LOG },
        .{ .offset = .{ 1, 2, 0 }, .block = ACACIA_LOG },
        .{ .offset = .{ 2, 3, 0 }, .block = ACACIA_LOG },
        .{ .offset = .{ 2, 4, 0 }, .block = ACACIA_LOG },
        // Flat Canopy
        .{ .offset = .{ 2, 4, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 1, 4, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 3, 4, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 4, 1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 4, -1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 1, 4, 1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 1, 4, -1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 3, 4, 1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 3, 4, -1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 0, 4, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 4, 4, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 4, 2 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 4, -2 }, .block = ACACIA_LEAVES },
        // Top flat layer
        .{ .offset = .{ 2, 5, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 1, 5, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 3, 5, 0 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 5, 1 }, .block = ACACIA_LEAVES },
        .{ .offset = .{ 2, 5, -1 }, .block = ACACIA_LEAVES },
    },
    .size_x = 5,
    .size_y = 7,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const MANGROVE_TREE = Schematic{
    .blocks = &[_]SchematicBlock{
        // Prop Roots (Y starting below surface)
        .{ .offset = .{ 1, -1, 0 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ -1, -1, 0 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ 0, -1, 1 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ 0, -1, -1 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ 1, 0, 0 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ -1, 0, 0 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ 0, 0, 1 }, .block = MANGROVE_ROOTS },
        .{ .offset = .{ 0, 0, -1 }, .block = MANGROVE_ROOTS },
        // Trunk
        .{ .offset = .{ 0, 1, 0 }, .block = MANGROVE_LOG },
        .{ .offset = .{ 0, 2, 0 }, .block = MANGROVE_LOG },
        .{ .offset = .{ 0, 3, 0 }, .block = MANGROVE_LOG },
        .{ .offset = .{ 0, 4, 0 }, .block = MANGROVE_LOG },
        // Canopy
        .{ .offset = .{ 1, 3, 0 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ -1, 3, 0 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 0, 3, 1 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 0, 3, -1 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 1, 4, 0 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ -1, 4, 0 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 0, 4, 1 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 0, 4, -1 }, .block = MANGROVE_LEAVES },
        .{ .offset = .{ 0, 5, 0 }, .block = MANGROVE_LEAVES },
    },
    .size_x = 5,
    .size_y = 8,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const HUGE_RED_MUSHROOM = Schematic{
    .blocks = &[_]SchematicBlock{
        // Stem
        .{ .offset = .{ 0, 0, 0 }, .block = MUSHROOM_STEM },
        .{ .offset = .{ 0, 1, 0 }, .block = MUSHROOM_STEM },
        .{ .offset = .{ 0, 2, 0 }, .block = MUSHROOM_STEM },
        // Cap
        .{ .offset = .{ 0, 3, 0 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, 0 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, 0 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, 1 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, -1 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, 1 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, 1 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, -1 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, -1 }, .block = RED_MUSHROOM_BLOCK },
        // Cap edges (Level 2)
        .{ .offset = .{ 2, 2, 0 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ -2, 2, 0 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 2, 2 }, .block = RED_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 2, -2 }, .block = RED_MUSHROOM_BLOCK },
    },
    .size_x = 5,
    .size_y = 5,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

pub const HUGE_BROWN_MUSHROOM = Schematic{
    .blocks = &[_]SchematicBlock{
        // Stem
        .{ .offset = .{ 0, 0, 0 }, .block = MUSHROOM_STEM },
        .{ .offset = .{ 0, 1, 0 }, .block = MUSHROOM_STEM },
        .{ .offset = .{ 0, 2, 0 }, .block = MUSHROOM_STEM },
        // Flat Cap
        .{ .offset = .{ 0, 3, 0 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, 0 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, 0 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, 1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, -1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, 1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, 1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, -1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, -1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 2, 3, 0 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -2, 3, 0 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, 2 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 0, 3, -2 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 2, 3, 1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 2, 3, -1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -2, 3, 1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -2, 3, -1 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, 2 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, 2 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ 1, 3, -2 }, .block = BROWN_MUSHROOM_BLOCK },
        .{ .offset = .{ -1, 3, -2 }, .block = BROWN_MUSHROOM_BLOCK },
    },
    .size_x = 5,
    .size_y = 5,
    .size_z = 5,
    .center_x = 0,
    .center_z = 0,
};

test "OAK_TREE properties" {
    try std.testing.expectEqual(@as(i32, 5), OAK_TREE.size_x);
    try std.testing.expectEqual(@as(i32, 6), OAK_TREE.size_y);
    try std.testing.expectEqual(@as(i32, 5), OAK_TREE.size_z);
    try std.testing.expect(OAK_TREE.blocks.len == 21); // 4 logs + 17 leaves

    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (OAK_TREE.blocks) |b| {
        if (b.block == OAK_LOG) log_count += 1;
        if (b.block == OAK_LEAVES) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), log_count);
    try std.testing.expectEqual(@as(usize, 17), leaf_count);
}

test "BIRCH_TREE properties" {
    try std.testing.expectEqual(@as(i32, 5), BIRCH_TREE.size_x);
    try std.testing.expectEqual(@as(i32, 7), BIRCH_TREE.size_y);
    try std.testing.expectEqual(@as(i32, 5), BIRCH_TREE.size_z);

    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (BIRCH_TREE.blocks) |b| {
        if (b.block == BIRCH_LOG) log_count += 1;
        if (b.block == BIRCH_LEAVES) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), log_count);
    try std.testing.expect(leaf_count > 10);
}

test "SPRUCE_TREE properties" {
    try std.testing.expectEqual(@as(i32, 8), SPRUCE_TREE.size_y);

    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (SPRUCE_TREE.blocks) |b| {
        if (b.block == SPRUCE_LOG) log_count += 1;
        if (b.block == SPRUCE_LEAVES) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), log_count);
    try std.testing.expect(leaf_count > 15);
}

test "JUNGLE_TREE properties" {
    try std.testing.expectEqual(@as(i32, 10), JUNGLE_TREE.size_y);

    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (JUNGLE_TREE.blocks) |b| {
        if (b.block == JUNGLE_LOG) log_count += 1;
        if (b.block == JUNGLE_LEAVES) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), log_count);
}

test "HUGE_MUSHROOM properties" {
    try std.testing.expectEqual(@as(i32, 5), HUGE_RED_MUSHROOM.size_y);
    try std.testing.expectEqual(@as(i32, 5), HUGE_BROWN_MUSHROOM.size_y);

    var red_cap_count: usize = 0;
    for (HUGE_RED_MUSHROOM.blocks) |b| {
        if (b.block == RED_MUSHROOM_BLOCK) red_cap_count += 1;
    }
    try std.testing.expect(red_cap_count > 10);

    var brown_cap_count: usize = 0;
    for (HUGE_BROWN_MUSHROOM.blocks) |b| {
        if (b.block == BROWN_MUSHROOM_BLOCK) brown_cap_count += 1;
    }
    try std.testing.expect(brown_cap_count > 10);
}
