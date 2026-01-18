//! Data-driven block registry.
//!
//! Replaces the "God Enum" pattern in BlockType by separating data from the enum.
//! Block properties are stored in a static registry indexed by BlockType.

const std = @import("std");
const BlockType = @import("block.zig").BlockType;
const Face = @import("block.zig").Face;

/// Rendering pass for the block
pub const RenderPass = enum {
    /// Opaque blocks (e.g., stone, dirt).
    /// These are drawn first and obscure everything behind them.
    solid,

    /// Transparent blocks with alpha testing (e.g., leaves, grass, flowers).
    /// Pixels are either fully opaque or fully transparent.
    cutout,

    /// Translucent fluid blocks (e.g., water).
    /// Special handling for face culling between same-fluid blocks.
    fluid,

    /// Translucent blocks with alpha blending (e.g., glass).
    /// Drawn last, back-to-front sorted ideally.
    translucent,
};

pub const BlockDefinition = struct {
    id: BlockType,
    name: []const u8,
    is_solid: bool,
    is_transparent: bool,
    is_tintable: bool,
    is_fluid: bool,
    render_pass: RenderPass,
    light_emission: [3]u4, // RGB light emission
    default_color: [3]f32,

    /// Check if this block occludes another block on a given face
    pub fn occludes(self: BlockDefinition, other_def: BlockDefinition, face: Face) bool {
        _ = face;
        if (self.id == .air) return false;

        // Fluid culling: Same fluids don't draw faces between them
        if (self.is_fluid and self.id == other_def.id) return true;

        // Same transparent types occlude each other (no internal glass faces)
        if (self.is_transparent and self.id == other_def.id) return true;

        // Non-transparent solid blocks occlude everything
        if (self.is_solid and !self.is_transparent) return true;

        return false;
    }

    /// Get face color with shading based on normal direction
    pub fn getFaceColor(self: BlockDefinition, face: Face) [3]f32 {
        const shade = face.getShade();
        return .{
            self.default_color[0] * shade,
            self.default_color[1] * shade,
            self.default_color[2] * shade,
        };
    }

    /// Get maximum light emission level (0-15)
    pub fn getLightEmissionLevel(self: BlockDefinition) u4 {
        return @max(self.light_emission[0], @max(self.light_emission[1], self.light_emission[2]));
    }

    pub fn isOpaque(self: BlockDefinition) bool {
        return !self.is_transparent;
    }
};

/// Global static registry of block definitions
pub const BLOCK_REGISTRY = blk: {
    // Validate that BlockType is backed by u8 to ensure registry fits
    if (@typeInfo(BlockType).@"enum".tag_type != u8) {
        @compileError("BlockType must be backed by u8 for BLOCK_REGISTRY safety");
    }

    // Validate that all enum fields are covered by the registry size
    if (@typeInfo(BlockType).@"enum".fields.len > 256) {
        @compileError("BlockType has more fields than BLOCK_REGISTRY size (256)");
    }

    // Ensure we cover all fields (length check is a proxy, but good sanity check)
    // The iteration below covers them all by name.

    var definitions = [_]BlockDefinition{undefined} ** 256; // Max u8 blocks

    // Default "Air" definition for all slots first
    for (0..256) |i| {
        definitions[i] = .{
            .id = .air,
            .name = "unknown",
            .is_solid = false,
            .is_transparent = true,
            .is_tintable = false,
            .is_fluid = false,
            .render_pass = .solid, // Default, though air isn't drawn
            .light_emission = .{ 0, 0, 0 },
            .default_color = .{ 1, 0, 1 }, // Magenta for unknown
        };
    }

    // Populate known blocks
    // We construct this at compile time / comptime.

    // Helper to shorten the definition list
    const fields = @typeInfo(BlockType).@"enum".fields;
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "_")) continue;

        const id = @field(BlockType, field.name);
        const int_id = @intFromEnum(id);

        var def = BlockDefinition{
            .id = id,
            .name = field.name,
            .is_solid = true, // Default
            .is_transparent = false, // Default
            .is_tintable = false, // Default
            .is_fluid = false, // Default
            .render_pass = .solid, // Default
            .light_emission = .{ 0, 0, 0 }, // Default
            .default_color = .{ 1, 1, 1 }, // Default
        };

        // Apply specific properties based on the original switch statements

        // 1. Color
        def.default_color = switch (id) {
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
            .mud => .{ 0.35, 0.30, 0.30 },
            .mangrove_log => .{ 0.45, 0.25, 0.25 },
            .mangrove_leaves => .{ 0.2, 0.5, 0.15 },
            .mangrove_roots => .{ 0.4, 0.3, 0.2 },
            .jungle_log => .{ 0.5, 0.3, 0.1 },
            .jungle_leaves => .{ 0.2, 0.5, 0.15 },
            .melon => .{ 0.6, 0.8, 0.2 },
            .bamboo => .{ 0.4, 0.8, 0.2 },
            .acacia_log => .{ 0.6, 0.55, 0.5 },
            .acacia_leaves => .{ 0.2, 0.5, 0.15 },
            .acacia_sapling => .{ 0.3, 0.6, 0.2 },
            .terracotta => .{ 0.7, 0.4, 0.3 },
            .red_sand => .{ 0.8, 0.4, 0.1 },
            .mycelium => .{ 0.4, 0.3, 0.4 },
            .mushroom_stem => .{ 0.9, 0.9, 0.85 },
            .red_mushroom_block => .{ 0.8, 0.2, 0.2 },
            .brown_mushroom_block => .{ 0.6, 0.4, 0.3 },
            .tall_grass => .{ 0.3, 0.65, 0.2 },
            .flower_red => .{ 0.9, 0.1, 0.1 },
            .flower_yellow => .{ 0.9, 0.9, 0.1 },
            .dead_bush => .{ 0.4, 0.3, 0.1 },
            .birch_log => .{ 0.8, 0.8, 0.75 },
            .birch_leaves => .{ 0.3, 0.7, 0.2 },
            .spruce_log => .{ 0.35, 0.25, 0.15 },
            .spruce_leaves => .{ 0.15, 0.4, 0.15 },
            .vine => .{ 0.2, 0.5, 0.1 },
            else => .{ 1, 0, 1 },
        };

        // 2. Solid
        def.is_solid = switch (id) {
            .air, .water => false,
            else => true,
        };

        // 3. Transparent
        def.is_transparent = switch (id) {
            .air, .water, .glass, .leaves, .mangrove_leaves, .mangrove_roots, .jungle_leaves, .bamboo, .acacia_leaves, .acacia_sapling, .birch_leaves, .spruce_leaves, .vine, .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .melon => true,
            else => false,
        };

        // 4. Tintable
        def.is_tintable = switch (id) {
            .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .vine, .tall_grass, .water => true,
            else => false,
        };

        // 5. Is Fluid
        def.is_fluid = switch (id) {
            .water => true,
            else => false,
        };

        // 6. Render Pass
        def.render_pass = switch (id) {
            .water => .fluid,
            .glass => .translucent,
            .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .mangrove_roots, .bamboo, .acacia_sapling, .vine, .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .melon => .cutout,
            else => .solid,
        };

        // 7. Light Emission
        def.light_emission = switch (id) {
            .glowstone => .{ 15, 14, 10 },
            .water, .cactus, .coal_ore, .iron_ore, .gold_ore => .{ 0, 0, 0 },
            else => .{ 0, 0, 0 },
        };

        definitions[int_id] = def;
    }

    break :blk definitions;
};

/// Get the block definition for a given block type
pub fn getBlockDefinition(block: BlockType) *const BlockDefinition {
    const idx = @intFromEnum(block);
    // Bounds check is implicit for u8 indexing into [256] array,
    // and we validated BlockType is u8 backed at comptime.
    return &BLOCK_REGISTRY[idx];
}
