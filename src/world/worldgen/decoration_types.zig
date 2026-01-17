//! Decoration types and data structures for world generation.
//! Defines SimpleDecoration, Schematic, SchematicBlock, and Decoration union.
//!
//! This module separates type definitions from data (schematics) and configuration (registry)
//! to adhere to the Single Responsibility Principle.

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
