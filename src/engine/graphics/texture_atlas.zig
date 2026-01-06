//! Texture Atlas for block textures.
//! Loads textures from resource packs with solid color fallback.
//! Supports HD texture packs (16x16 to 512x512) and PBR maps.

const std = @import("std");
const c = @import("../../c.zig").c;

const Texture = @import("texture.zig").Texture;
const FilterMode = @import("texture.zig").FilterMode;
const log = @import("../core/log.zig");
const resource_pack = @import("resource_pack.zig");
const BlockType = @import("../../world/block.zig").BlockType;
const PBRMapType = resource_pack.PBRMapType;

const rhi = @import("rhi.zig");

/// Default tile size in pixels (each block face texture)
pub const DEFAULT_TILE_SIZE: u32 = 16;

/// Number of tiles per row in the atlas
pub const TILES_PER_ROW: u32 = 16;

/// Supported tile sizes for HD texture packs
pub const SUPPORTED_TILE_SIZES = [_]u32{ 16, 32, 64, 128, 256, 512 };

/// Texture atlas for blocks with PBR support
pub const TextureAtlas = struct {
    /// Diffuse/albedo texture atlas
    texture: Texture,
    /// Normal map atlas (optional)
    normal_texture: ?Texture,
    /// Roughness map atlas (optional)
    roughness_texture: ?Texture,
    /// Displacement map atlas (optional)
    displacement_texture: ?Texture,

    allocator: std.mem.Allocator,
    pack_manager: ?*resource_pack.ResourcePackManager,
    tile_size: u32,
    atlas_size: u32,
    /// Whether PBR textures are available
    has_pbr: bool,

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

    /// Detect tile size from the first valid texture in the pack
    fn detectTileSize(pack_manager: ?*resource_pack.ResourcePackManager, allocator: std.mem.Allocator) u32 {
        if (pack_manager) |pm| {
            // Try to load a common texture to detect size
            const probe_textures = [_][]const u8{ "stone", "dirt", "grass_top", "cobblestone" };
            for (probe_textures) |name| {
                if (pm.loadTexture(name)) |loaded_tex| {
                    defer {
                        var tex = loaded_tex;
                        tex.deinit(allocator);
                    }
                    // Use the larger dimension and snap to nearest supported size
                    const size = @max(loaded_tex.width, loaded_tex.height);
                    return snapToSupportedSize(size);
                }
            }
        }
        return DEFAULT_TILE_SIZE;
    }

    /// Snap a size to the nearest supported tile size
    fn snapToSupportedSize(size: u32) u32 {
        for (SUPPORTED_TILE_SIZES) |supported| {
            if (size <= supported) {
                return supported;
            }
        }
        // Cap at maximum supported size
        return SUPPORTED_TILE_SIZES[SUPPORTED_TILE_SIZES.len - 1];
    }

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

    pub fn init(allocator: std.mem.Allocator, rhi_instance: rhi.RHI, pack_manager: ?*resource_pack.ResourcePackManager) !TextureAtlas {
        // Detect tile size from pack textures
        const tile_size = detectTileSize(pack_manager, allocator);
        const atlas_size = tile_size * TILES_PER_ROW;

        log.log.info("Texture atlas tile size: {}x{} (atlas: {}x{})", .{ tile_size, tile_size, atlas_size, atlas_size });

        const pixel_count = atlas_size * atlas_size * 4;

        // Allocate pixel buffers for all atlas types
        const diffuse_pixels = try allocator.alloc(u8, pixel_count);
        defer allocator.free(diffuse_pixels);
        @memset(diffuse_pixels, 255); // White default

        // Check if pack has PBR support
        const has_pbr = if (pack_manager) |pm| pm.hasPBRSupport() else false;

        var normal_pixels: ?[]u8 = null;
        var roughness_pixels: ?[]u8 = null;
        var displacement_pixels: ?[]u8 = null;

        if (has_pbr) {
            normal_pixels = try allocator.alloc(u8, pixel_count);
            // Default normal: (128, 128, 255, 255) = flat surface pointing up in OpenGL normal map format
            var i: usize = 0;
            while (i < pixel_count) : (i += 4) {
                normal_pixels.?[i + 0] = 128; // R
                normal_pixels.?[i + 1] = 128; // G
                normal_pixels.?[i + 2] = 255; // B (pointing up)
                normal_pixels.?[i + 3] = 255; // A
            }

            roughness_pixels = try allocator.alloc(u8, pixel_count);
            // Default roughness: 0.5 (medium roughness)
            i = 0;
            while (i < pixel_count) : (i += 4) {
                roughness_pixels.?[i + 0] = 128;
                roughness_pixels.?[i + 1] = 128;
                roughness_pixels.?[i + 2] = 128;
                roughness_pixels.?[i + 3] = 255;
            }

            displacement_pixels = try allocator.alloc(u8, pixel_count);
            // Default displacement: 0 (flat)
            @memset(displacement_pixels.?, 0);
            i = 0;
            while (i < pixel_count) : (i += 4) {
                displacement_pixels.?[i + 3] = 255; // Alpha = 1
            }

            log.log.info("PBR texture pack detected - creating normal, roughness, and displacement atlases", .{});
        }

        defer {
            if (normal_pixels) |p| allocator.free(p);
            if (roughness_pixels) |p| allocator.free(p);
            if (displacement_pixels) |p| allocator.free(p);
        }

        var loaded_count: u32 = 0;
        var pbr_count: u32 = 0;

        for (tile_configs) |config| {
            var loaded = false;
            if (pack_manager) |pm| {
                if (has_pbr) {
                    // Load full PBR texture set
                    var pbr_set = pm.loadPBRTextureSet(config.name);
                    defer pbr_set.deinit(allocator);

                    if (pbr_set.diffuse) |diffuse| {
                        log.log.debug("Loaded texture: {s} ({}x{})", .{ config.name, diffuse.width, diffuse.height });
                        copyTextureToTile(diffuse_pixels, config.index, diffuse.pixels, diffuse.width, diffuse.height, tile_size, atlas_size);
                        loaded = true;
                        loaded_count += 1;
                    }

                    if (pbr_set.normal) |normal| {
                        copyTextureToTile(normal_pixels.?, config.index, normal.pixels, normal.width, normal.height, tile_size, atlas_size);
                        pbr_count += 1;
                    }
                    if (pbr_set.roughness) |roughness| {
                        copyTextureToTile(roughness_pixels.?, config.index, roughness.pixels, roughness.width, roughness.height, tile_size, atlas_size);
                    }
                    if (pbr_set.displacement) |displacement| {
                        copyTextureToTile(displacement_pixels.?, config.index, displacement.pixels, displacement.width, displacement.height, tile_size, atlas_size);
                    }
                } else {
                    // Legacy: load just diffuse
                    if (pm.loadTexture(config.name)) |loaded_tex| {
                        defer {
                            var tex = loaded_tex;
                            tex.deinit(allocator);
                        }
                        log.log.debug("Loaded texture: {s} ({}x{})", .{ config.name, loaded_tex.width, loaded_tex.height });
                        copyTextureToTile(diffuse_pixels, config.index, loaded_tex.pixels, loaded_tex.width, loaded_tex.height, tile_size, atlas_size);
                        loaded = true;
                        loaded_count += 1;
                    }
                }
            }

            if (!loaded) {
                log.log.warn("Failed to load texture: {s}, using fallback color", .{config.name});
                // Use solid block color as fallback in the atlas
                const base_f32 = config.block.getColor();
                const base_u8 = [3]u8{
                    @intFromFloat(@min(base_f32[0] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[1] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[2] * 255.0, 255.0)),
                };
                fillTileWithColor(diffuse_pixels, config.index, base_u8, tile_size, atlas_size);
            }
        }

        // Create textures using RHI with NEAREST filtering for sharp pixel art
        const diffuse_texture = Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
        }, diffuse_pixels);

        var normal_texture: ?Texture = null;
        var roughness_texture: ?Texture = null;
        var displacement_texture: ?Texture = null;

        if (has_pbr) {
            normal_texture = Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .generate_mipmaps = false,
            }, normal_pixels.?);

            roughness_texture = Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .generate_mipmaps = false,
            }, roughness_pixels.?);

            displacement_texture = Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .generate_mipmaps = false,
            }, displacement_pixels.?);

            log.log.info("PBR atlases created: {} textures with {} normal maps", .{ loaded_count, pbr_count });
        }

        log.log.info("Texture atlas created: {}x{} - Loaded {} textures from pack", .{ atlas_size, atlas_size, loaded_count });

        return .{
            .texture = diffuse_texture,
            .normal_texture = normal_texture,
            .roughness_texture = roughness_texture,
            .displacement_texture = displacement_texture,
            .allocator = allocator,
            .pack_manager = pack_manager,
            .tile_size = tile_size,
            .atlas_size = atlas_size,
            .has_pbr = has_pbr,
        };
    }

    fn copyTextureToTile(atlas_pixels: []u8, tile_index: u8, src_pixels: []const u8, src_width: u32, src_height: u32, tile_size: u32, atlas_size: u32) void {
        const tile_col = tile_index % TILES_PER_ROW;
        const tile_row = tile_index / TILES_PER_ROW;
        const start_x = tile_col * tile_size;
        const start_y = tile_row * tile_size;

        var py: u32 = 0;
        while (py < tile_size) : (py += 1) {
            var px: u32 = 0;
            while (px < tile_size) : (px += 1) {
                const src_x = (px * src_width) / tile_size;
                const src_y = (py * src_height) / tile_size;
                const src_idx = (src_y * src_width + src_x) * 4;

                const dest_x = start_x + px;
                const dest_y = start_y + py;
                const dest_idx = (dest_y * atlas_size + dest_x) * 4;

                if (src_idx + 3 < src_pixels.len and dest_idx + 3 < atlas_pixels.len) {
                    atlas_pixels[dest_idx + 0] = src_pixels[src_idx + 0];
                    atlas_pixels[dest_idx + 1] = src_pixels[src_idx + 1];
                    atlas_pixels[dest_idx + 2] = src_pixels[src_idx + 2];
                    atlas_pixels[dest_idx + 3] = src_pixels[src_idx + 3];
                }
            }
        }
    }

    fn fillTileWithColor(atlas_pixels: []u8, tile_index: u8, color: [3]u8, tile_size: u32, atlas_size: u32) void {
        const tile_col = tile_index % TILES_PER_ROW;
        const tile_row = tile_index / TILES_PER_ROW;
        const start_x = tile_col * tile_size;
        const start_y = tile_row * tile_size;

        var py: u32 = 0;
        while (py < tile_size) : (py += 1) {
            var px: u32 = 0;
            while (px < tile_size) : (px += 1) {
                const dest_x = start_x + px;
                const dest_y = start_y + py;
                const dest_idx = (dest_y * atlas_size + dest_x) * 4;

                if (dest_idx + 3 < atlas_pixels.len) {
                    atlas_pixels[dest_idx + 0] = color[0];
                    atlas_pixels[dest_idx + 1] = color[1];
                    atlas_pixels[dest_idx + 2] = color[2];
                    atlas_pixels[dest_idx + 3] = 255;
                }
            }
        }
    }

    pub fn deinit(self: *TextureAtlas) void {
        var tex = self.texture;
        tex.deinit();

        if (self.normal_texture) |*t| {
            var nt = t.*;
            nt.deinit();
        }
        if (self.roughness_texture) |*t| {
            var rt = t.*;
            rt.deinit();
        }
        if (self.displacement_texture) |*t| {
            var dt = t.*;
            dt.deinit();
        }
    }

    /// Bind diffuse texture
    pub fn bind(self: *const TextureAtlas, slot: u32) void {
        self.texture.bind(slot);
    }

    /// Bind normal map texture (if available)
    pub fn bindNormal(self: *const TextureAtlas, slot: u32) void {
        if (self.normal_texture) |*t| {
            t.bind(slot);
        }
    }

    /// Bind roughness texture (if available)
    pub fn bindRoughness(self: *const TextureAtlas, slot: u32) void {
        if (self.roughness_texture) |*t| {
            t.bind(slot);
        }
    }

    /// Bind displacement texture (if available)
    pub fn bindDisplacement(self: *const TextureAtlas, slot: u32) void {
        if (self.displacement_texture) |*t| {
            t.bind(slot);
        }
    }

    /// Check if PBR textures are available
    pub fn hasPBR(self: *const TextureAtlas) bool {
        return self.has_pbr;
    }
};

// Legacy constants for backward compatibility
pub const TILE_SIZE: u32 = DEFAULT_TILE_SIZE;
pub const ATLAS_SIZE: u32 = DEFAULT_TILE_SIZE * TILES_PER_ROW;
