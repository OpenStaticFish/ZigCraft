//! Registry of all available decorations and their placement rules.
//! Configures the specific decorations (both simple and schematic) that populate the world.
//! Re-exports decoration types for consumers like the generator.

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;
const biome_mod = @import("biome.zig");
const tree_registry = @import("tree_registry.zig");

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
};

const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;

pub const StandardDecorationProvider = struct {
    pub fn provider() DecorationProvider {
        return .{
            .ptr = null, // Stateless
            .vtable = &VTABLE,
        };
    }

    const VTABLE = DecorationProvider.VTable{
        .decorate = decorate,
    };

    /// Check if area around (x, z) is clear of obstructions (logs/leaves)
    fn isAreaClear(chunk: *Chunk, x: i32, y: i32, z: i32, radius: i32) bool {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;

                const check_x = x + dx;
                const check_z = z + dz;

                if (check_x >= 0 and check_x < CHUNK_SIZE_X and
                    check_z >= 0 and check_z < CHUNK_SIZE_Z)
                {
                    var dy: i32 = 1;
                    while (dy <= 3) : (dy += 1) {
                        const block = chunk.getBlockSafe(check_x, y + dy, check_z);
                        if (block == .wood or block == .leaves or
                            block == .birch_log or block == .birch_leaves or
                            block == .spruce_log or block == .spruce_leaves or
                            block == .jungle_log or block == .jungle_leaves or
                            block == .acacia_log or block == .acacia_leaves or
                            block == .mangrove_log or block == .mangrove_leaves)
                        {
                            return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    fn decorate(
        ptr: ?*anyopaque,
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

        // 1. Static decorations (flowers, grass)
        for (DECORATIONS) |deco| {
            switch (deco) {
                .simple => |s| {
                    if (!s.isAllowed(biome, surface_block)) continue;

                    if (!allow_subbiomes) {
                        if (s.variant_min != -1.0 or s.variant_max != 1.0) continue;
                    } else {
                        if (variant < s.variant_min or variant > s.variant_max) continue;
                    }

                    const prob = @min(1.0, s.probability * veg_mult);
                    if (random.float(f32) >= prob) continue;

                    chunk.setBlock(local_x, @intCast(surface_y + 1), local_z, s.block);
                    break;
                },
                .schematic => {},
            }
        }

        // 2. Dynamic Tree Registry (from Biome Definition)
        const biome_def = biome_mod.getBiomeDefinition(biome);
        const vegetation = biome_def.vegetation;

        if (vegetation.tree_types.len > 0) {
            for (vegetation.tree_types) |tree_type| {
                if (tree_registry.getTreeDefinition(tree_type)) |tree_def| {
                    // Check surface block
                    var valid_surface = false;
                    for (tree_def.place_on) |valid_block| {
                        if (surface_block == valid_block) {
                            valid_surface = true;
                            break;
                        }
                    }
                    if (!valid_surface) continue;

                    // Check variant noise
                    if (allow_subbiomes) {
                        if (variant < tree_def.variant_min or variant > tree_def.variant_max) continue;
                    } else {
                        if (tree_def.variant_min != -1.0 or tree_def.variant_max != 1.0) continue;
                    }

                    // Check probability
                    const prob = @min(1.0, tree_def.probability * veg_mult);
                    if (random.float(f32) >= prob) continue;

                    // Enforce spacing
                    if (tree_def.spacing_radius > 0) {
                        if (!isAreaClear(chunk, @intCast(local_x), surface_y, @intCast(local_z), tree_def.spacing_radius)) {
                            continue;
                        }
                    }

                    // Place tree
                    tree_def.schematic.place(chunk, local_x, @intCast(surface_y + 1), local_z, random);

                    // Break after placing a tree to avoid multiple trees spawning in the same block column
                    break;
                }
            }
        }
    }
};
