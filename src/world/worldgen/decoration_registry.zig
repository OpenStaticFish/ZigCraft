//! Registry of all available decorations and their placement rules.
//! Configures the specific decorations (both simple and schematic) that populate the world.
//! Re-exports decoration types for consumers like the generator.

const std = @import("std");
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
pub const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;

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

    // === Trees: Sparse (Plains, Swamp, Mountains) ===
    .{
        .schematic = .{
            .schematic = schematics.OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{ .plains, .swamp, .mountains },
            .probability = 0.002, // Very sparse
            .spacing_radius = 4,
        },
    },

    // === Trees: Standard Forest (Variant -0.4 to 0.4) ===
    .{ .schematic = .{
        .schematic = schematics.OAK_TREE,
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
            .schematic = schematics.OAK_TREE,
            .place_on = &.{ .grass, .dirt },
            .biomes = &.{.forest},
            .probability = 0.15, // Dense!
            .spacing_radius = 2,
            .variant_min = 0.4,
        },
    },

    // Note: Forest with variant < -0.4 has NO trees (Clearing)
};

const Chunk = @import("../chunk.zig").Chunk;

pub const StandardDecorationProvider = struct {
    pub fn provider() DecorationProvider {
        return .{
            .ptr = undefined, // No state needed
            .vtable = &VTABLE,
        };
    }

    const VTABLE = DecorationProvider.VTable{
        .decorate = decorate,
    };

    fn decorate(
        ptr: *anyopaque,
        chunk: *Chunk,
        local_x: u32,
        local_z: u32,
        surface_y: i32,
        surface_block: BlockType,
        biome: BiomeId,
        variant: f32,
        allow_subbiomes: bool,
        veg_mult: f32,
        random: std.Random,
    ) void {
        _ = ptr;
        for (DECORATIONS) |deco| {
            switch (deco) {
                .simple => |s| {
                    if (!s.isAllowed(biome, surface_block)) continue;

                    if (!allow_subbiomes) {
                        if (s.variant_min != -1.0 or s.variant_max != 1.0) continue;
                    } else {
                        if (variant < s.variant_min or variant > s.variant_max) continue;
                    }

                    const prob = s.probability * veg_mult;
                    if (random.float(f32) >= prob) continue;

                    chunk.setBlock(local_x, @intCast(surface_y + 1), local_z, s.block);
                    break;
                },
                .schematic => |s| {
                    if (!s.isAllowed(biome, surface_block)) continue;

                    if (!allow_subbiomes) {
                        if (s.variant_min != -1.0 or s.variant_max != 1.0) continue;
                    } else {
                        if (variant < s.variant_min or variant > s.variant_max) continue;
                    }

                    const prob = s.probability * veg_mult;
                    if (random.float(f32) >= prob) continue;

                    s.schematic.place(chunk, local_x, @intCast(surface_y + 1), local_z, random);
                    break;
                },
            }
        }
    }
};
