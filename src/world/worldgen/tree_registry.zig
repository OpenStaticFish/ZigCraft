const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const TreeType = @import("biome.zig").TreeType;
const schematics = @import("schematics.zig");
const Schematic = @import("decoration_types.zig").Schematic;

pub const TreeDefinition = struct {
    schematic: Schematic,
    place_on: []const BlockType = &.{ .grass, .dirt },
    spacing_radius: i32 = 3,
};

pub const TreeRegistry = struct {
    pub fn getTree(tree_type: TreeType) !TreeDefinition {
        return switch (tree_type) {
            .oak => .{ .schematic = schematics.OAK_TREE },
            .birch => .{ .schematic = schematics.BIRCH_TREE },
            .spruce => .{ .schematic = schematics.SPRUCE_TREE, .place_on = &.{ .grass, .dirt, .snow_block }, .spacing_radius = 4 },
            .swamp_oak => .{ .schematic = schematics.SWAMP_OAK, .spacing_radius = 4 },
            .mangrove => .{ .schematic = schematics.MANGROVE_TREE, .place_on = &.{ .mud, .grass } },
            .jungle => .{ .schematic = schematics.JUNGLE_TREE, .spacing_radius = 2 },
            .acacia => .{ .schematic = schematics.ACACIA_TREE, .spacing_radius = 5 },
            .huge_red_mushroom => .{ .schematic = schematics.HUGE_RED_MUSHROOM, .place_on = &.{.mycelium}, .spacing_radius = 4 },
            .huge_brown_mushroom => .{ .schematic = schematics.HUGE_BROWN_MUSHROOM, .place_on = &.{.mycelium}, .spacing_radius = 4 },
            .none => error.InvalidTreeType,
        };
    }
};
