//! Texture Atlas for block textures.
//! Generates a procedural texture atlas with all block types.

const std = @import("std");
const c = @import("../../c.zig").c;

const Texture = @import("texture.zig").Texture;
const FilterMode = @import("texture.zig").FilterMode;
const log = @import("../core/log.zig");

const rhi = @import("rhi.zig");

/// Tile size in pixels (each block face texture)
pub const TILE_SIZE: u32 = 16;

/// Number of tiles per row in the atlas
pub const TILES_PER_ROW: u32 = 16;

/// Atlas dimensions
pub const ATLAS_SIZE: u32 = TILE_SIZE * TILES_PER_ROW;

/// Texture atlas for blocks
pub const TextureAtlas = struct {
    texture: Texture,
    allocator: std.mem.Allocator,

    /// Tile indices for block faces [top, bottom, side]
    /// Each block type maps to 3 tile indices
    pub const BlockTiles = struct {
        top: u8,
        bottom: u8,
        side: u8,

        pub fn uniform(tile: u8) BlockTiles {
            return .{ .top = tile, .bottom = tile, .side = tile };
        }
    };

    // Tile indices (row * TILES_PER_ROW + col)
    pub const TILE_STONE: u8 = 0;
    pub const TILE_DIRT: u8 = 1;
    pub const TILE_GRASS_TOP: u8 = 2;
    pub const TILE_GRASS_SIDE: u8 = 3;
    pub const TILE_SAND: u8 = 4;
    pub const TILE_COBBLESTONE: u8 = 5;
    pub const TILE_BEDROCK: u8 = 6;
    pub const TILE_GRAVEL: u8 = 7;
    pub const TILE_WOOD_SIDE: u8 = 8;
    pub const TILE_WOOD_TOP: u8 = 9;
    pub const TILE_LEAVES: u8 = 10;
    pub const TILE_WATER: u8 = 11;
    pub const TILE_GLASS: u8 = 12;
    pub const TILE_GLOWSTONE: u8 = 13;
    pub const TILE_MUD: u8 = 14;
    pub const TILE_MANGROVE_LOG_SIDE: u8 = 15;
    pub const TILE_MANGROVE_LOG_TOP: u8 = 16;
    pub const TILE_MANGROVE_LEAVES: u8 = 17;
    pub const TILE_MANGROVE_ROOTS: u8 = 18;
    pub const TILE_JUNGLE_LOG_SIDE: u8 = 19;
    pub const TILE_JUNGLE_LOG_TOP: u8 = 20;
    pub const TILE_JUNGLE_LEAVES: u8 = 21;
    pub const TILE_MELON_SIDE: u8 = 22;
    pub const TILE_MELON_TOP: u8 = 23;
    pub const TILE_BAMBOO: u8 = 24;
    pub const TILE_ACACIA_LOG_SIDE: u8 = 25;
    pub const TILE_ACACIA_LOG_TOP: u8 = 26;
    pub const TILE_ACACIA_LEAVES: u8 = 27;
    pub const TILE_ACACIA_SAPLING: u8 = 28;
    pub const TILE_TERRACOTTA: u8 = 29;
    pub const TILE_RED_SAND: u8 = 30;
    pub const TILE_MYCELIUM_TOP: u8 = 31;
    pub const TILE_MYCELIUM_SIDE: u8 = 32;
    pub const TILE_MUSHROOM_STEM: u8 = 33;
    pub const TILE_RED_MUSHROOM: u8 = 34;
    pub const TILE_BROWN_MUSHROOM: u8 = 35;

    /// Block type to tile mapping
    pub fn getTilesForBlock(block_id: u8) BlockTiles {
        return switch (block_id) {
            0 => BlockTiles.uniform(0), // Air (won't be rendered)
            1 => BlockTiles.uniform(TILE_STONE), // Stone
            2 => BlockTiles.uniform(TILE_DIRT), // Dirt
            3 => .{ .top = TILE_GRASS_TOP, .bottom = TILE_DIRT, .side = TILE_GRASS_SIDE }, // Grass
            4 => BlockTiles.uniform(TILE_SAND), // Sand
            5 => BlockTiles.uniform(TILE_WATER), // Water
            6 => .{ .top = TILE_WOOD_TOP, .bottom = TILE_WOOD_TOP, .side = TILE_WOOD_SIDE }, // Wood
            7 => BlockTiles.uniform(TILE_LEAVES), // Leaves
            8 => BlockTiles.uniform(TILE_COBBLESTONE), // Cobblestone
            9 => BlockTiles.uniform(TILE_BEDROCK), // Bedrock
            10 => BlockTiles.uniform(TILE_GRAVEL), // Gravel
            11 => BlockTiles.uniform(TILE_GLASS), // Glass
            18 => BlockTiles.uniform(TILE_GLOWSTONE), // Glowstone
            19 => BlockTiles.uniform(TILE_MUD), // Mud
            20 => .{ .top = TILE_MANGROVE_LOG_TOP, .bottom = TILE_MANGROVE_LOG_TOP, .side = TILE_MANGROVE_LOG_SIDE }, // Mangrove Log
            21 => BlockTiles.uniform(TILE_MANGROVE_LEAVES), // Mangrove Leaves
            22 => BlockTiles.uniform(TILE_MANGROVE_ROOTS), // Mangrove Roots
            23 => .{ .top = TILE_JUNGLE_LOG_TOP, .bottom = TILE_JUNGLE_LOG_TOP, .side = TILE_JUNGLE_LOG_SIDE }, // Jungle Log
            24 => BlockTiles.uniform(TILE_JUNGLE_LEAVES), // Jungle Leaves
            25 => .{ .top = TILE_MELON_TOP, .bottom = TILE_MELON_TOP, .side = TILE_MELON_SIDE }, // Melon
            26 => BlockTiles.uniform(TILE_BAMBOO), // Bamboo
            27 => .{ .top = TILE_ACACIA_LOG_TOP, .bottom = TILE_ACACIA_LOG_TOP, .side = TILE_ACACIA_LOG_SIDE }, // Acacia Log
            28 => BlockTiles.uniform(TILE_ACACIA_LEAVES), // Acacia Leaves
            29 => BlockTiles.uniform(TILE_ACACIA_SAPLING), // Acacia Sapling
            30 => BlockTiles.uniform(TILE_TERRACOTTA), // Terracotta
            31 => BlockTiles.uniform(TILE_RED_SAND), // Red Sand
            32 => .{ .top = TILE_MYCELIUM_TOP, .bottom = TILE_DIRT, .side = TILE_MYCELIUM_SIDE }, // Mycelium
            33 => BlockTiles.uniform(TILE_MUSHROOM_STEM), // Mushroom Stem
            34 => BlockTiles.uniform(TILE_RED_MUSHROOM), // Red Mushroom Block
            35 => BlockTiles.uniform(TILE_BROWN_MUSHROOM), // Brown Mushroom Block
            else => BlockTiles.uniform(0),
        };
    }

    /// Get UV coordinates for a tile (returns min_u, min_v, max_u, max_v)
    pub fn getTileUV(tile_index: u8) [4]f32 {
        const tiles_f: f32 = @floatFromInt(TILES_PER_ROW);
        const col: f32 = @floatFromInt(tile_index % TILES_PER_ROW);
        const row: f32 = @floatFromInt(tile_index / TILES_PER_ROW);

        const tile_size = 1.0 / tiles_f;
        // Small inset to prevent texture bleeding
        const inset: f32 = 0.001;

        return .{
            col * tile_size + inset, // min_u
            row * tile_size + inset, // min_v
            (col + 1) * tile_size - inset, // max_u
            (row + 1) * tile_size - inset, // max_v
        };
    }

    pub fn init(allocator: std.mem.Allocator, rhi_instance: rhi.RHI) TextureAtlas {
        // Allocate pixel data for the atlas (RGBA)
        const pixel_count = ATLAS_SIZE * ATLAS_SIZE * 4;
        var pixels = allocator.alloc(u8, pixel_count) catch @panic("Failed to allocate atlas");
        defer allocator.free(pixels);

        // Clear to magenta (missing texture indicator)
        for (0..ATLAS_SIZE * ATLAS_SIZE) |i| {
            pixels[i * 4 + 0] = 255; // R
            pixels[i * 4 + 1] = 0; // G
            pixels[i * 4 + 2] = 255; // B
            pixels[i * 4 + 3] = 255; // A
        }

        // Generate each tile
        generateTile(pixels, TILE_STONE, .{ 128, 128, 128 }, .stone);
        generateTile(pixels, TILE_DIRT, .{ 140, 90, 50 }, .noise);
        generateTile(pixels, TILE_GRASS_TOP, .{ 76, 165, 50 }, .grass);
        generateTile(pixels, TILE_GRASS_SIDE, .{ 140, 90, 50 }, .grass_side);
        generateTile(pixels, TILE_SAND, .{ 230, 215, 150 }, .noise);
        generateTile(pixels, TILE_COBBLESTONE, .{ 100, 100, 100 }, .cobble);
        generateTile(pixels, TILE_BEDROCK, .{ 40, 40, 40 }, .noise);
        generateTile(pixels, TILE_GRAVEL, .{ 115, 108, 100 }, .gravel);
        generateTile(pixels, TILE_WOOD_SIDE, .{ 140, 90, 40 }, .wood_side);
        generateTile(pixels, TILE_WOOD_TOP, .{ 160, 130, 70 }, .wood_top);
        generateTile(pixels, TILE_LEAVES, .{ 50, 128, 38 }, .leaves);
        generateTile(pixels, TILE_WATER, .{ 50, 100, 200 }, .water);
        generateTile(pixels, TILE_GLASS, .{ 200, 230, 240 }, .glass);
        generateTile(pixels, TILE_GLOWSTONE, .{ 255, 220, 100 }, .glowstone);
        generateTile(pixels, TILE_MUD, .{ 90, 75, 75 }, .noise);
        generateTile(pixels, TILE_MANGROVE_LOG_SIDE, .{ 85, 55, 55 }, .wood_side);
        generateTile(pixels, TILE_MANGROVE_LOG_TOP, .{ 110, 70, 70 }, .wood_top);
        generateTile(pixels, TILE_MANGROVE_LEAVES, .{ 50, 130, 40 }, .leaves);
        generateTile(pixels, TILE_MANGROVE_ROOTS, .{ 100, 70, 50 }, .roots);
        generateTile(pixels, TILE_JUNGLE_LOG_SIDE, .{ 100, 80, 40 }, .wood_side);
        generateTile(pixels, TILE_JUNGLE_LOG_TOP, .{ 120, 100, 60 }, .wood_top);
        generateTile(pixels, TILE_JUNGLE_LEAVES, .{ 40, 160, 40 }, .leaves);
        generateTile(pixels, TILE_MELON_SIDE, .{ 130, 180, 50 }, .melon_side);
        generateTile(pixels, TILE_MELON_TOP, .{ 120, 170, 40 }, .melon_top);
        generateTile(pixels, TILE_BAMBOO, .{ 80, 180, 60 }, .bamboo);
        generateTile(pixels, TILE_ACACIA_LOG_SIDE, .{ 130, 120, 110 }, .wood_side);
        generateTile(pixels, TILE_ACACIA_LOG_TOP, .{ 150, 140, 130 }, .wood_top);
        generateTile(pixels, TILE_ACACIA_LEAVES, .{ 80, 140, 40 }, .leaves);
        generateTile(pixels, TILE_ACACIA_SAPLING, .{ 100, 160, 60 }, .sapling);
        generateTile(pixels, TILE_TERRACOTTA, .{ 180, 110, 90 }, .noise);
        generateTile(pixels, TILE_RED_SAND, .{ 200, 100, 40 }, .noise);
        generateTile(pixels, TILE_MYCELIUM_TOP, .{ 110, 90, 110 }, .mushroom_pore);
        generateTile(pixels, TILE_MYCELIUM_SIDE, .{ 140, 90, 50 }, .grass_side); // Reusing grass_side (green top) for now, acceptable placeholder
        generateTile(pixels, TILE_MUSHROOM_STEM, .{ 200, 200, 195 }, .mushroom_pore);
        generateTile(pixels, TILE_RED_MUSHROOM, .{ 200, 50, 50 }, .mushroom_cap);
        generateTile(pixels, TILE_BROWN_MUSHROOM, .{ 150, 100, 70 }, .mushroom_cap);

        // Create texture using RHI
        const texture = Texture.init(rhi_instance, ATLAS_SIZE, ATLAS_SIZE, .rgba, .{}, pixels);

        log.log.info("Texture atlas created: {}x{} ({} tiles)", .{ ATLAS_SIZE, ATLAS_SIZE, TILES_PER_ROW * TILES_PER_ROW });

        return .{
            .texture = texture,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextureAtlas) void {
        var tex = self.texture;
        tex.deinit();
    }

    pub fn bind(self: *const TextureAtlas, slot: u32) void {
        self.texture.bind(slot);
    }

    const TilePattern = enum {
        solid,
        noise,
        stone,
        grass,
        grass_side,
        cobble,
        gravel,
        wood_side,
        wood_top,
        leaves,
        water,
        glass,
        glowstone,
        roots,
        melon_side,
        melon_top,
        bamboo,
        sapling,
        mushroom_pore,
        mushroom_cap,
    };

    fn generateTile(pixels: []u8, tile_index: u8, base_color: [3]u8, pattern: TilePattern) void {
        const tile_col = tile_index % TILES_PER_ROW;
        const tile_row = tile_index / TILES_PER_ROW;
        const start_x = tile_col * TILE_SIZE;
        const start_y = tile_row * TILE_SIZE;

        var py: u32 = 0;
        while (py < TILE_SIZE) : (py += 1) {
            var px: u32 = 0;
            while (px < TILE_SIZE) : (px += 1) {
                const x = start_x + px;
                const y = start_y + py;
                const idx = (y * ATLAS_SIZE + x) * 4;

                const color = getPatternColor(px, py, base_color, pattern);
                pixels[idx + 0] = color[0];
                pixels[idx + 1] = color[1];
                pixels[idx + 2] = color[2];
                if (pattern == .glass) {
                    pixels[idx + 3] = 200;
                } else if ((pattern == .sapling or pattern == .roots) and color[0] == 0 and color[1] == 0 and color[2] == 0) {
                    pixels[idx + 3] = 0;
                } else {
                    pixels[idx + 3] = 255;
                }
            }
        }
    }

    fn getPatternColor(px: u32, py: u32, base: [3]u8, pattern: TilePattern) [3]u8 {
        const x = @as(i32, @intCast(px));
        const y = @as(i32, @intCast(py));

        return switch (pattern) {
            .solid => base,

            .noise => blk: {
                const noise = simpleHash(x, y) % 30;
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 15);
            },

            .stone => blk: {
                const noise = simpleHash(x * 3, y * 3) % 40;
                const crack = if (@rem(x + y, 8) == 0) @as(i8, -30) else @as(i8, 0);
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 20 + crack);
            },

            .grass => blk: {
                const noise = simpleHash(x * 2, y * 2) % 40;
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 20);
            },

            .grass_side => blk: {
                if (py < 4) {
                    // Grass top portion
                    const noise = simpleHash(x * 2, y) % 30;
                    const grass_color = [3]u8{ 76, 165, 50 };
                    break :blk adjustBrightness(grass_color, @as(i8, @intCast(noise)) - 15);
                } else {
                    // Dirt portion
                    const noise = simpleHash(x, y) % 30;
                    break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 15);
                }
            },

            .cobble => blk: {
                const cell_x = @divFloor(x, 4);
                const cell_y = @divFloor(y, 4);
                const cell_noise = simpleHash(cell_x, cell_y) % 50;
                const edge = if (@rem(x, 4) == 0 or @rem(y, 4) == 0) @as(i8, -20) else @as(i8, 0);
                break :blk adjustBrightness(base, @as(i8, @intCast(cell_noise)) - 25 + edge);
            },

            .gravel => blk: {
                const noise1 = simpleHash(x, y) % 40;
                const noise2 = simpleHash(x * 7, y * 7) % 20;
                break :blk adjustBrightness(base, @as(i8, @intCast(noise1 + noise2)) - 30);
            },

            .wood_side => blk: {
                // Vertical wood grain
                const hash_val = simpleHash(0, y) % 2;
                const grain = @rem(@as(u32, @intCast(@abs(x * 3 + @as(i32, @intCast(hash_val))))), 4);
                const noise = simpleHash(x, y * 5) % 20;
                const dark: i8 = if (grain == 0) -30 else 0;
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 10 + dark);
            },

            .wood_top => blk: {
                // Concentric rings
                const cx = @as(i32, TILE_SIZE / 2);
                const cy = @as(i32, TILE_SIZE / 2);
                const dx = x - cx;
                const dy = y - cy;
                const dist = @as(u32, @intCast(@abs(dx * dx + dy * dy)));
                const ring = (dist / 8) % 2;
                const adjust: i8 = if (ring == 0) -20 else 10;
                break :blk adjustBrightness(base, adjust);
            },

            .leaves => blk: {
                const noise = simpleHash(x * 5, y * 5) % 60;
                if (noise > 45) {
                    // Dark spots (gaps in leaves)
                    break :blk adjustBrightness(base, -40);
                } else {
                    break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 30);
                }
            },

            .water => blk: {
                const wave = @rem(@as(u32, @intCast(@abs(x + y))), 8);
                const adjust: i8 = if (wave < 2) 20 else 0;
                break :blk adjustBrightness(base, adjust);
            },

            .glass => blk: {
                // Border highlight
                if (px == 0 or py == 0 or px == TILE_SIZE - 1 or py == TILE_SIZE - 1) {
                    break :blk .{ 255, 255, 255 };
                }
                break :blk base;
            },

            .glowstone => blk: {
                // Bright center, darker edges, noisy
                const dist_x = @abs(@as(i32, @intCast(px)) - 8);
                const dist_y = @abs(@as(i32, @intCast(py)) - 8);
                const dist = dist_x * dist_x + dist_y * dist_y;
                const noise = simpleHash(x * 4, y * 4) % 40;

                // Brighter in center
                const center_boost: i8 = if (dist < 16) 20 else -10;

                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 20 + center_boost);
            },

            .roots => blk: {
                const noise = simpleHash(x * 4, y * 4) % 60;
                if (noise > 45) break :blk .{ 0, 0, 0 }; // Gap
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 30);
            },

            .melon_side => blk: {
                const stripe = @divTrunc(x, 2);
                const noise = simpleHash(x, y) % 20;
                if (@rem(stripe, 2) == 0) break :blk adjustBrightness(base, 20);
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 10);
            },

            .melon_top => blk: {
                const cx = @as(i32, TILE_SIZE / 2);
                const cy = @as(i32, TILE_SIZE / 2);
                const dist = (x - cx) * (x - cx) + (y - cy) * (y - cy);
                break :blk adjustBrightness(base, if (@rem(dist, 20) < 10) 10 else -10);
            },

            .bamboo => blk: {
                if (x < 6 or x > 9) break :blk adjustBrightness(base, -20);
                if (@rem(y, 4) == 0) break :blk adjustBrightness(base, -30);
                break :blk base;
            },

            .sapling => blk: {
                const cx = 8;
                const dx = @abs(@as(i32, @intCast(px)) - cx);
                if (y > 8 and dx < 2) break :blk .{ 100, 60, 40 };
                if (y <= 8 and dx < 5 - @divTrunc(y, 2)) break :blk base;
                break :blk .{ 0, 0, 0 };
            },

            .mushroom_pore => blk: {
                const noise = simpleHash(x * 5, y * 5) % 30;
                break :blk adjustBrightness(base, @as(i8, @intCast(noise)) - 15);
            },

            .mushroom_cap => blk: {
                const spot = simpleHash(@divTrunc(x, 4), @divTrunc(y, 4)) % 5;
                if (spot == 0) break :blk .{ 220, 200, 180 };
                break :blk base;
            },
        };
    }

    fn simpleHash(x: i32, y: i32) u32 {
        var h: u32 = @bitCast(x *% 374761393 +% y *% 668265263);
        h = (h ^ (h >> 13)) *% 1274126177;
        return h ^ (h >> 16);
    }

    fn adjustBrightness(color: [3]u8, adjust: i8) [3]u8 {
        return .{
            @intCast(std.math.clamp(@as(i16, color[0]) + adjust, 0, 255)),
            @intCast(std.math.clamp(@as(i16, color[1]) + adjust, 0, 255)),
            @intCast(std.math.clamp(@as(i16, color[2]) + adjust, 0, 255)),
        };
    }
};
