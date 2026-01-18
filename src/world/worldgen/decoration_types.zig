//! Decoration types and data structures for world generation.
//! Defines SimpleDecoration, Schematic, SchematicBlock, and Decoration union.
//!
//! This module separates type definitions from data (schematics) and configuration (registry)
//! to adhere to the Single Responsibility Principle.

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;
// Import schematics to get the Schematic type definition
pub const schematics = @import("schematics.zig");
pub const Schematic = schematics.Schematic;
pub const SchematicBlock = schematics.SchematicBlock;

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

    pub fn isAllowed(self: SimpleDecoration, biome: BiomeId, surface_block: BlockType) bool {
        if (!isBiomeAllowed(self.biomes, biome)) return false;
        if (!isBlockAllowed(self.place_on, surface_block)) return false;
        return true;
    }
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

    pub fn isAllowed(self: SchematicDecoration, biome: BiomeId, surface_block: BlockType) bool {
        if (!isBiomeAllowed(self.biomes, biome)) return false;
        if (!isBlockAllowed(self.place_on, surface_block)) return false;
        return true;
    }
};

pub const Decoration = union(enum) {
    simple: SimpleDecoration,
    schematic: SchematicDecoration,
};

fn isBiomeAllowed(allowed: []const BiomeId, current: BiomeId) bool {
    if (allowed.len == 0) return true;
    for (allowed) |b| {
        if (b == current) return true;
    }
    return false;
}

fn isBlockAllowed(allowed: []const BlockType, current: BlockType) bool {
    for (allowed) |b| {
        if (b == current) return true;
    }
    return false;
}
