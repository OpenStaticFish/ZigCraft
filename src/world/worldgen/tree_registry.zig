//! Tree Registry system (Issue #165)
//! Centralizes tree definitions to avoid modification of multiple files when adding new trees.
//! Maps TreeType enum to Schematic and placement rules.

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const schematics = @import("schematics.zig");
const Schematic = schematics.Schematic;

/// Tree types available for generation.
/// Note: The order of variants does not affect logic, but is preserved in registry iteration.
pub const TreeType = enum {
    oak,
    birch,
    spruce,
    swamp_oak,
    mangrove,
    jungle,
    acacia,
    huge_red_mushroom,
    huge_brown_mushroom,
    // Variants
    dense_oak,
    sparse_oak,
    /// Null-type used to represent no tree placement
    none,
};

/// Definition of a tree's placement rules and structure
pub const TreeDefinition = struct {
    /// Schematic containing the blocks to place
    schematic: Schematic,
    /// Blocks that this tree can be placed on
    place_on: []const BlockType = &.{ .grass, .dirt },
    /// Probability of this tree being selected when its biome is active
    probability: f32 = 0.05,
    /// Minimum distance in blocks between trees of this type
    spacing_radius: i32 = 3,
    /// Minimum variant noise value for this tree to spawn.
    /// Used to constrain trees to specific regions of a biome based on the variant noise field.
    variant_min: f32 = -1.0,
    /// Maximum variant noise value for this tree to spawn.
    /// Used to constrain trees to specific regions of a biome based on the variant noise field.
    variant_max: f32 = 1.0,
};

/// Get the definition for a given tree type
pub fn getTreeDefinition(tree_type: TreeType) ?TreeDefinition {
    return switch (tree_type) {
        .oak => .{
            .schematic = schematics.OAK_TREE,
            .probability = 0.02,
            .spacing_radius = 3,
            .variant_min = -0.4,
            .variant_max = 0.4,
        },
        .birch => .{
            .schematic = schematics.BIRCH_TREE,
            .probability = 0.015,
            .spacing_radius = 3,
            .variant_min = 0.0,
            .variant_max = 0.6,
        },
        .spruce => .{
            .schematic = schematics.SPRUCE_TREE,
            .place_on = &.{ .grass, .dirt, .snow_block },
            .probability = 0.08,
            .spacing_radius = 3,
        },
        .swamp_oak => .{
            .schematic = schematics.SWAMP_OAK,
            .probability = 0.05,
            .spacing_radius = 4,
        },
        .mangrove => .{
            .schematic = schematics.MANGROVE_TREE,
            .place_on = &.{ .mud, .grass },
            .probability = 0.12,
            .spacing_radius = 3,
        },
        .jungle => .{
            .schematic = schematics.JUNGLE_TREE,
            .probability = 0.15,
            .spacing_radius = 2,
        },
        .acacia => .{
            .schematic = schematics.ACACIA_TREE,
            .probability = 0.015,
            .spacing_radius = 5,
        },
        .huge_red_mushroom => .{
            .schematic = schematics.HUGE_RED_MUSHROOM,
            .place_on = &.{.mycelium},
            .probability = 0.03,
            .spacing_radius = 4,
        },
        .huge_brown_mushroom => .{
            .schematic = schematics.HUGE_BROWN_MUSHROOM,
            .place_on = &.{.mycelium},
            .probability = 0.03,
            .spacing_radius = 4,
        },
        .dense_oak => .{
            .schematic = schematics.OAK_TREE,
            .probability = 0.1,
            .spacing_radius = 2,
            .variant_min = 0.4,
        },
        .sparse_oak => .{
            .schematic = schematics.OAK_TREE,
            .probability = 0.002,
            .spacing_radius = 4,
        },
        .none => null,
    };
}

test "TreeRegistry completeness" {
    inline for (std.meta.fields(TreeType)) |field| {
        const t = @field(TreeType, field.name);
        if (t != .none) {
            const def = getTreeDefinition(t);
            try std.testing.expect(def != null);
        } else {
            try std.testing.expect(getTreeDefinition(t) == null);
        }
    }
}
