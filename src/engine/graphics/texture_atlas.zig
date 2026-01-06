//! Texture Atlas for block textures.
//! Loads textures from resource packs with solid color fallback.

const std = @import("std");
const c = @import("../../c.zig").c;

const Texture = @import("texture.zig").Texture;
const FilterMode = @import("texture.zig").FilterMode;
const log = @import("../core/log.zig");
const resource_pack = @import("resource_pack.zig");
const BlockType = @import("../../world/block.zig").BlockType;

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
    pack_manager: ?*resource_pack.ResourcePackManager,

    /// Tile indices for block faces [top, bottom, side]
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
    pub const TILE_COAL_ORE: u8 = 36;
    pub const TILE_IRON_ORE: u8 = 37;
    pub const TILE_GOLD_ORE: u8 = 38;
    pub const TILE_CLAY: u8 = 39;
    pub const TILE_SNOW_BLOCK: u8 = 40;
    pub const TILE_CACTUS_SIDE: u8 = 41;
    pub const TILE_CACTUS_TOP: u8 = 42;
    pub const TILE_TALL_GRASS: u8 = 43;
    pub const TILE_FLOWER_RED: u8 = 44;
    pub const TILE_FLOWER_YELLOW: u8 = 45;
    pub const TILE_DEAD_BUSH: u8 = 46;

    /// Block type to tile mapping
    pub fn getTilesForBlock(block_id: u8) BlockTiles {
        return switch (block_id) {
            0 => BlockTiles.uniform(0),
            1 => BlockTiles.uniform(TILE_STONE),
            2 => BlockTiles.uniform(TILE_DIRT),
            3 => .{ .top = TILE_GRASS_TOP, .bottom = TILE_DIRT, .side = TILE_GRASS_SIDE },
            4 => BlockTiles.uniform(TILE_SAND),
            5 => BlockTiles.uniform(TILE_WATER),
            6 => .{ .top = TILE_WOOD_TOP, .bottom = TILE_WOOD_TOP, .side = TILE_WOOD_SIDE },
            7 => BlockTiles.uniform(TILE_LEAVES),
            8 => BlockTiles.uniform(TILE_COBBLESTONE),
            9 => BlockTiles.uniform(TILE_BEDROCK),
            10 => BlockTiles.uniform(TILE_GRAVEL),
            11 => BlockTiles.uniform(TILE_GLASS),
            12 => BlockTiles.uniform(TILE_SNOW_BLOCK),
            13 => .{ .top = TILE_CACTUS_TOP, .bottom = TILE_CACTUS_TOP, .side = TILE_CACTUS_SIDE },
            14 => BlockTiles.uniform(TILE_COAL_ORE),
            15 => BlockTiles.uniform(TILE_IRON_ORE),
            16 => BlockTiles.uniform(TILE_GOLD_ORE),
            17 => BlockTiles.uniform(TILE_CLAY),
            18 => BlockTiles.uniform(TILE_GLOWSTONE),
            19 => BlockTiles.uniform(TILE_MUD),
            20 => .{ .top = TILE_MANGROVE_LOG_TOP, .bottom = TILE_MANGROVE_LOG_TOP, .side = TILE_MANGROVE_LOG_SIDE },
            21 => BlockTiles.uniform(TILE_MANGROVE_LEAVES),
            22 => BlockTiles.uniform(TILE_MANGROVE_ROOTS),
            23 => .{ .top = TILE_JUNGLE_LOG_TOP, .bottom = TILE_JUNGLE_LOG_TOP, .side = TILE_JUNGLE_LOG_SIDE },
            24 => BlockTiles.uniform(TILE_JUNGLE_LEAVES),
            25 => .{ .top = TILE_MELON_TOP, .bottom = TILE_MELON_TOP, .side = TILE_MELON_SIDE },
            26 => BlockTiles.uniform(TILE_BAMBOO),
            27 => .{ .top = TILE_ACACIA_LOG_TOP, .bottom = TILE_ACACIA_LOG_TOP, .side = TILE_ACACIA_LOG_SIDE },
            28 => BlockTiles.uniform(TILE_ACACIA_LEAVES),
            29 => BlockTiles.uniform(TILE_ACACIA_SAPLING),
            30 => BlockTiles.uniform(TILE_TERRACOTTA),
            31 => BlockTiles.uniform(TILE_RED_SAND),
            32 => .{ .top = TILE_MYCELIUM_TOP, .bottom = TILE_DIRT, .side = TILE_MYCELIUM_SIDE },
            33 => BlockTiles.uniform(TILE_MUSHROOM_STEM),
            34 => BlockTiles.uniform(TILE_RED_MUSHROOM),
            35 => BlockTiles.uniform(TILE_BROWN_MUSHROOM),
            36 => BlockTiles.uniform(TILE_TALL_GRASS),
            37 => BlockTiles.uniform(TILE_FLOWER_RED),
            38 => BlockTiles.uniform(TILE_FLOWER_YELLOW),
            39 => BlockTiles.uniform(TILE_DEAD_BUSH),
            else => BlockTiles.uniform(0),
        };
    }

    pub fn init(allocator: std.mem.Allocator, rhi_instance: rhi.RHI, pack_manager: ?*resource_pack.ResourcePackManager) !TextureAtlas {
        const pixel_count = ATLAS_SIZE * ATLAS_SIZE * 4;
        const pixels = try allocator.alloc(u8, pixel_count);
        defer allocator.free(pixels);

        // Pre-fill everything with white
        @memset(pixels, 255);

        const TileConfig = struct { index: u8, name: []const u8, block: BlockType };
        const tile_configs = [_]TileConfig{
            .{ .index = TILE_STONE, .name = "stone", .block = .stone },
            .{ .index = TILE_DIRT, .name = "dirt", .block = .dirt },
            .{ .index = TILE_GRASS_TOP, .name = "grass_top", .block = .grass },
            .{ .index = TILE_GRASS_SIDE, .name = "grass_side", .block = .grass },
            .{ .index = TILE_SAND, .name = "sand", .block = .sand },
            .{ .index = TILE_COBBLESTONE, .name = "cobblestone", .block = .cobblestone },
            .{ .index = TILE_BEDROCK, .name = "bedrock", .block = .bedrock },
            .{ .index = TILE_GRAVEL, .name = "gravel", .block = .gravel },
            .{ .index = TILE_WOOD_SIDE, .name = "wood_side", .block = .wood },
            .{ .index = TILE_WOOD_TOP, .name = "wood_top", .block = .wood },
            .{ .index = TILE_LEAVES, .name = "leaves", .block = .leaves },
            .{ .index = TILE_WATER, .name = "water", .block = .water },
            .{ .index = TILE_GLASS, .name = "glass", .block = .glass },
            .{ .index = TILE_GLOWSTONE, .name = "glowstone", .block = .glowstone },
            .{ .index = TILE_MUD, .name = "mud", .block = .mud },
            .{ .index = TILE_MANGROVE_LOG_SIDE, .name = "mangrove_log_side", .block = .mangrove_log },
            .{ .index = TILE_MANGROVE_LOG_TOP, .name = "mangrove_log_top", .block = .mangrove_log },
            .{ .index = TILE_MANGROVE_LEAVES, .name = "mangrove_leaves", .block = .mangrove_leaves },
            .{ .index = TILE_MANGROVE_ROOTS, .name = "mangrove_roots", .block = .mangrove_roots },
            .{ .index = TILE_JUNGLE_LOG_SIDE, .name = "jungle_log_side", .block = .jungle_log },
            .{ .index = TILE_JUNGLE_LOG_TOP, .name = "jungle_log_top", .block = .jungle_log },
            .{ .index = TILE_JUNGLE_LEAVES, .name = "jungle_leaves", .block = .jungle_leaves },
            .{ .index = TILE_MELON_SIDE, .name = "melon_side", .block = .melon },
            .{ .index = TILE_MELON_TOP, .name = "melon_top", .block = .melon },
            .{ .index = TILE_BAMBOO, .name = "bamboo", .block = .bamboo },
            .{ .index = TILE_ACACIA_LOG_SIDE, .name = "acacia_log_side", .block = .acacia_log },
            .{ .index = TILE_ACACIA_LOG_TOP, .name = "acacia_log_top", .block = .acacia_log },
            .{ .index = TILE_ACACIA_LEAVES, .name = "acacia_leaves", .block = .acacia_leaves },
            .{ .index = TILE_ACACIA_SAPLING, .name = "acacia_sapling", .block = .acacia_sapling },
            .{ .index = TILE_TERRACOTTA, .name = "terracotta", .block = .terracotta },
            .{ .index = TILE_RED_SAND, .name = "red_sand", .block = .red_sand },
            .{ .index = TILE_MYCELIUM_TOP, .name = "mycelium_top", .block = .mycelium },
            .{ .index = TILE_MYCELIUM_SIDE, .name = "mycelium_side", .block = .mycelium },
            .{ .index = TILE_MUSHROOM_STEM, .name = "mushroom_stem", .block = .mushroom_stem },
            .{ .index = TILE_RED_MUSHROOM, .name = "red_mushroom_block", .block = .red_mushroom_block },
            .{ .index = TILE_BROWN_MUSHROOM, .name = "brown_mushroom_block", .block = .brown_mushroom_block },
            .{ .index = TILE_COAL_ORE, .name = "coal_ore", .block = .coal_ore },
            .{ .index = TILE_IRON_ORE, .name = "iron_ore", .block = .iron_ore },
            .{ .index = TILE_GOLD_ORE, .name = "gold_ore", .block = .gold_ore },
            .{ .index = TILE_CLAY, .name = "clay", .block = .clay },
            .{ .index = TILE_SNOW_BLOCK, .name = "snow_block", .block = .snow_block },
            .{ .index = TILE_CACTUS_SIDE, .name = "cactus_side", .block = .cactus },
            .{ .index = TILE_CACTUS_TOP, .name = "cactus_top", .block = .cactus },
            .{ .index = TILE_TALL_GRASS, .name = "tall_grass", .block = .tall_grass },
            .{ .index = TILE_FLOWER_RED, .name = "flower_red", .block = .flower_red },
            .{ .index = TILE_FLOWER_YELLOW, .name = "flower_yellow", .block = .flower_yellow },
            .{ .index = TILE_DEAD_BUSH, .name = "dead_bush", .block = .dead_bush },
        };

        var loaded_count: u32 = 0;
        for (tile_configs) |config| {
            var loaded = false;
            if (pack_manager) |pm| {
                if (pm.loadTexture(config.name)) |loaded_tex| {
                    defer {
                        var tex = loaded_tex;
                        tex.deinit(allocator);
                    }
                    copyTextureToTile(pixels, config.index, loaded_tex.pixels, loaded_tex.width, loaded_tex.height);
                    loaded = true;
                    loaded_count += 1;
                }
            }

            if (!loaded) {
                // Use solid block color as fallback in the atlas
                const base_f32 = config.block.getColor();
                const base_u8 = [3]u8{
                    @intFromFloat(@min(base_f32[0] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[1] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[2] * 255.0, 255.0)),
                };
                fillTileWithColor(pixels, config.index, base_u8);
            }
        }

        // Create texture using RHI with NEAREST filtering for sharp pixel art
        const texture = Texture.init(rhi_instance, ATLAS_SIZE, ATLAS_SIZE, .rgba, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
        }, pixels);
        log.log.info("Texture atlas created: {}x{} - Loaded {} textures from pack", .{ ATLAS_SIZE, ATLAS_SIZE, loaded_count });

        return .{
            .texture = texture,
            .allocator = allocator,
            .pack_manager = pack_manager,
        };
    }

    fn copyTextureToTile(atlas_pixels: []u8, tile_index: u8, src_pixels: []const u8, src_width: u32, src_height: u32) void {
        const tile_col = tile_index % TILES_PER_ROW;
        const tile_row = tile_index / TILES_PER_ROW;
        const start_x = tile_col * TILE_SIZE;
        const start_y = tile_row * TILE_SIZE;

        var py: u32 = 0;
        while (py < TILE_SIZE) : (py += 1) {
            var px: u32 = 0;
            while (px < TILE_SIZE) : (px += 1) {
                const src_x = (px * src_width) / TILE_SIZE;
                const src_y = (py * src_height) / TILE_SIZE;
                const src_idx = (src_y * src_width + src_x) * 4;

                const dest_x = start_x + px;
                const dest_y = start_y + py;
                const dest_idx = (dest_y * ATLAS_SIZE + dest_x) * 4;

                if (src_idx + 3 < src_pixels.len and dest_idx + 3 < atlas_pixels.len) {
                    atlas_pixels[dest_idx + 0] = src_pixels[src_idx + 0];
                    atlas_pixels[dest_idx + 1] = src_pixels[src_idx + 1];
                    atlas_pixels[dest_idx + 2] = src_pixels[src_idx + 2];
                    atlas_pixels[dest_idx + 3] = src_pixels[src_idx + 3];
                }
            }
        }
    }

    fn fillTileWithColor(atlas_pixels: []u8, tile_index: u8, color: [3]u8) void {
        const tile_col = tile_index % TILES_PER_ROW;
        const tile_row = tile_index / TILES_PER_ROW;
        const start_x = tile_col * TILE_SIZE;
        const start_y = tile_row * TILE_SIZE;

        var py: u32 = 0;
        while (py < TILE_SIZE) : (py += 1) {
            var px: u32 = 0;
            while (px < TILE_SIZE) : (px += 1) {
                const dest_x = start_x + px;
                const dest_y = start_y + py;
                const dest_idx = (dest_y * ATLAS_SIZE + dest_x) * 4;

                atlas_pixels[dest_idx + 0] = color[0];
                atlas_pixels[dest_idx + 1] = color[1];
                atlas_pixels[dest_idx + 2] = color[2];
                atlas_pixels[dest_idx + 3] = 255;
            }
        }
    }

    pub fn deinit(self: *TextureAtlas) void {
        var tex = self.texture;
        tex.deinit();
    }

    pub fn bind(self: *const TextureAtlas, slot: u32) void {
        self.texture.bind(slot);
    }
};
