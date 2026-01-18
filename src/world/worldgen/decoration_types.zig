//! Decoration types and data structures for world generation.
//! Defines SimpleDecoration, Schematic, SchematicBlock, and Decoration union.
//!
//! This module separates type definitions from data (schematics) and configuration (registry)
//! to adhere to the Single Responsibility Principle.

const std = @import("std");
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;
const chunk_mod = @import("../chunk.zig");
const Chunk = chunk_mod.Chunk;
const CHUNK_SIZE_X = chunk_mod.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = chunk_mod.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = chunk_mod.CHUNK_SIZE_Z;

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
        _ = random;
        const center_x = @as(i32, @intCast(x));
        const center_y = @as(i32, @intCast(y));
        const center_z = @as(i32, @intCast(z));

        for (self.blocks) |sb| {
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
