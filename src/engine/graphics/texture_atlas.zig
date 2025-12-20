//! Texture Atlas for block textures.
//! Generates a procedural texture atlas with all block types.

const std = @import("std");
const c = @import("../../c.zig").c;

const Texture = @import("texture.zig").Texture;
const FilterMode = @import("texture.zig").FilterMode;
const log = @import("../core/log.zig");

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

    pub fn init(allocator: std.mem.Allocator) TextureAtlas {
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

        // Create OpenGL texture
        const texture = Texture.init(ATLAS_SIZE, ATLAS_SIZE, pixels.ptr, .rgba, .{
            .min_filter = .nearest_mipmap_linear,
            .mag_filter = .nearest, // Pixelated look for voxels
            .wrap_s = .repeat,
            .wrap_t = .repeat,
            .generate_mipmaps = true,
        });

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
                pixels[idx + 3] = if (pattern == .glass) 200 else 255;
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
