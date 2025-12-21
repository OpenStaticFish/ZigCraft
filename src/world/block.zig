//! Block types and their properties.

const std = @import("std");

/// Biome types for terrain generation
pub const Biome = enum(u8) {
    deep_ocean = 0,
    ocean = 1,
    beach = 2,
    plains = 3,
    forest = 4,
    taiga = 5, // cold forest
    desert = 6,
    snow_tundra = 7,
    mountains = 8,
    snowy_mountains = 9,
    river = 10,

    /// Get surface block for this biome
    pub fn getSurfaceBlock(self: Biome) BlockType {
        return switch (self) {
            .deep_ocean, .ocean => .gravel,
            .beach => .sand,
            .plains, .forest => .grass,
            .taiga => .grass, // Could use podzol if we add it
            .desert => .sand,
            .snow_tundra, .snowy_mountains => .snow_block,
            .mountains => .stone,
            .river => .sand,
        };
    }

    /// Get filler block (subsurface) for this biome
    pub fn getFillerBlock(self: Biome) BlockType {
        return switch (self) {
            .deep_ocean => .gravel,
            .ocean => .sand,
            .beach, .desert, .river => .sand,
            .plains, .forest, .taiga => .dirt,
            .snow_tundra => .dirt,
            .mountains, .snowy_mountains => .stone,
        };
    }

    /// Get ocean floor block for this biome
    pub fn getOceanFloorBlock(self: Biome, depth: f32) BlockType {
        _ = self;
        if (depth > 30) return .gravel; // Deep ocean floor
        if (depth > 15) return .clay; // Mid-depth
        return .sand; // Shallow
    }
};

pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    dirt = 2,
    grass = 3,
    sand = 4,
    water = 5,
    wood = 6,
    leaves = 7,
    cobblestone = 8,
    bedrock = 9,
    gravel = 10,
    glass = 11,
    snow_block = 12,
    cactus = 13,
    coal_ore = 14,
    iron_ore = 15,
    gold_ore = 16,
    clay = 17,
    glowstone = 18,

    _,

    pub fn isAir(self: BlockType) bool {
        return self == .air;
    }

    pub fn isSolid(self: BlockType) bool {
        return switch (self) {
            .air, .water => false,
            else => true,
        };
    }

    pub fn isTransparent(self: BlockType) bool {
        return switch (self) {
            .air, .water, .glass, .leaves => true,
            else => false,
        };
    }

    /// Returns true if block completely blocks light propagation
    pub fn isOpaque(self: BlockType) bool {
        return switch (self) {
            .air, .water, .glass, .leaves => false,
            else => true,
        };
    }

    pub fn occludes(self: BlockType, other: BlockType, face: Face) bool {
        _ = face;
        if (self.isAir()) return false;
        // Same transparent types occlude each other (no internal water/glass faces)
        if (self.isTransparent() and self == other) return true;
        // Non-transparent solid blocks occlude everything
        if (self.isSolid() and !self.isTransparent()) return true;
        return false;
    }

    /// Get block color (RGB, 0-1 range)
    pub fn getColor(self: BlockType) [3]f32 {
        return switch (self) {
            .air => .{ 0, 0, 0 },
            .stone => .{ 0.5, 0.5, 0.5 },
            .dirt => .{ 0.55, 0.35, 0.2 },
            .grass => .{ 0.3, 0.65, 0.2 },
            .sand => .{ 0.9, 0.85, 0.6 },
            .water => .{ 0.2, 0.4, 0.8 },
            .wood => .{ 0.55, 0.35, 0.15 },
            .leaves => .{ 0.2, 0.5, 0.15 },
            .cobblestone => .{ 0.4, 0.4, 0.4 },
            .bedrock => .{ 0.15, 0.15, 0.15 },
            .gravel => .{ 0.45, 0.42, 0.4 },
            .glass => .{ 0.8, 0.9, 0.95 },
            .snow_block => .{ 0.95, 0.95, 1.0 },
            .cactus => .{ 0.1, 0.6, 0.1 },
            .coal_ore => .{ 0.1, 0.1, 0.1 },
            .iron_ore => .{ 0.6, 0.5, 0.4 },
            .gold_ore => .{ 0.9, 0.8, 0.2 },
            .clay => .{ 0.6, 0.6, 0.7 },
            .glowstone => .{ 1.0, 0.9, 0.5 },
            _ => .{ 1, 0, 1 }, // Magenta for unknown
        };
    }

    /// Get light emission level (0-15)
    pub fn getLightEmission(self: BlockType) u4 {
        return switch (self) {
            .water => 0, // Water doesn't emit light
            .cactus => 0,
            .coal_ore => 0,
            .iron_ore => 0,
            .gold_ore => 0,
            .glowstone => 15,
            else => 0,
        };
    }

    /// Get face color with shading based on normal direction
    pub fn getFaceColor(self: BlockType, face: Face) [3]f32 {
        const base = self.getColor();
        const shade = face.getShade();
        return .{
            base[0] * shade,
            base[1] * shade,
            base[2] * shade,
        };
    }
};

pub const Face = enum(u3) {
    top = 0, // +Y
    bottom = 1, // -Y
    north = 2, // -Z
    south = 3, // +Z
    east = 4, // +X
    west = 5, // -X

    /// Get ambient occlusion-style shading multiplier
    pub fn getShade(self: Face) f32 {
        return switch (self) {
            .top => 1.0,
            .bottom => 0.5,
            .north, .south => 0.8,
            .east, .west => 0.7,
        };
    }

    /// Get normal vector for this face
    pub fn getNormal(self: Face) [3]i8 {
        return switch (self) {
            .top => .{ 0, 1, 0 },
            .bottom => .{ 0, -1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
            .east => .{ 1, 0, 0 },
            .west => .{ -1, 0, 0 },
        };
    }

    /// Get offset to neighboring block for this face
    pub fn getOffset(self: Face) struct { x: i32, y: i32, z: i32 } {
        const n = self.getNormal();
        return .{ .x = n[0], .y = n[1], .z = n[2] };
    }
};

/// All 6 faces for iteration
pub const ALL_FACES = [_]Face{ .top, .bottom, .north, .south, .east, .west };
