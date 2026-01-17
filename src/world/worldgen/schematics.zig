//! Tree and feature schematics.
//! Contains static definitions for multi-block structures like trees.
//! These schematics are referenced by the decoration registry.

const BlockType = @import("../block.zig").BlockType;
const decoration_types = @import("decoration_types.zig");
const Schematic = decoration_types.Schematic;
const SchematicBlock = decoration_types.SchematicBlock;

const LOG = BlockType.wood;
const LEAVES = BlockType.leaves;

pub const OAK_TREE = Schematic{
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

test "OAK_TREE properties" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 5), OAK_TREE.size_x);
    try std.testing.expectEqual(@as(i32, 6), OAK_TREE.size_y);
    try std.testing.expectEqual(@as(i32, 5), OAK_TREE.size_z);
    try std.testing.expect(OAK_TREE.blocks.len == 21); // 4 logs + 17 leaves

    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (OAK_TREE.blocks) |b| {
        if (b.block == LOG) log_count += 1;
        if (b.block == LEAVES) leaf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), log_count);
    try std.testing.expectEqual(@as(usize, 17), leaf_count);
}
