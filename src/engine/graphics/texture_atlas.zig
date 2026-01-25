//! Texture Atlas for block textures.
//! Loads textures from resource packs with solid color fallback.
//! Supports HD texture packs (16x16 to 512x512) and PBR maps.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../../c.zig").c;

const Texture = @import("texture.zig").Texture;
const FilterMode = @import("texture.zig").FilterMode;
const MAX_BLOCK_TYPES = @import("../../world/chunk.zig").MAX_BLOCK_TYPES;

const log = @import("../core/log.zig");
const resource_pack = @import("resource_pack.zig");
const BlockType = @import("../../world/block.zig").BlockType;
const block_registry = @import("../../world/block_registry.zig");
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

    tile_mappings: [MAX_BLOCK_TYPES]BlockTiles,

    /// Tile indices for block faces [top, bottom, side]
    pub const BlockTiles = struct {
        top: u16,
        bottom: u16,
        side: u16,

        pub fn uniform(tile: u16) BlockTiles {
            return .{ .top = tile, .bottom = tile, .side = tile };
        }
    };

    /// Block type to tile mapping
    pub fn getTilesForBlock(self: *const TextureAtlas, block_id: u8) BlockTiles {
        return self.tile_mappings[block_id];
    }

    pub fn init(allocator: std.mem.Allocator, rhi_instance: rhi.RHI, pack_manager: ?*resource_pack.ResourcePackManager, max_resolution: u32) !TextureAtlas {
        // 1. Detect tile size from pack textures
        const tile_size = detectTileSize(pack_manager, allocator, max_resolution);
        const atlas_size = tile_size * TILES_PER_ROW;

        log.log.info("Texture atlas: initializing {}x{} atlas (tile size: {}px)", .{ atlas_size, atlas_size, tile_size });

        // 2. Allocate and initialize pixel buffers
        const has_pbr = if (pack_manager) |pm| pm.hasPBRSupport() else false;
        var buffers = try allocateAtlasBuffers(allocator, atlas_size, has_pbr);
        defer buffers.deinit(allocator);

        // 3. Load block textures into atlas buffers
        var stats = LoadStats{};
        var tile_mappings = [_]BlockTiles{BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES;
        try loadBlockTextures(allocator, pack_manager, &buffers, &tile_mappings, tile_size, atlas_size, &stats);

        log.log.info("Texture atlas: loaded {} textures ({} with PBR) across {} blocks", .{ stats.loaded_count, stats.pbr_count, stats.block_count });
        if (stats.fallback_count > 0) {
            log.log.warn("Texture atlas: used solid color fallback for {} textures", .{stats.fallback_count});
        }

        // 4. Create GPU textures
        const atlas_textures = try createRhiTextures(rhi_instance, atlas_size, &buffers);

        return .{
            .texture = atlas_textures.diffuse,
            .normal_texture = atlas_textures.normal,
            .roughness_texture = atlas_textures.roughness,
            .displacement_texture = null,
            .allocator = allocator,
            .pack_manager = pack_manager,
            .tile_size = tile_size,
            .atlas_size = atlas_size,
            .has_pbr = has_pbr,
            .tile_mappings = tile_mappings,
        };
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

const AtlasBuffers = struct {
    diffuse: []u8,
    normal: ?[]u8,
    roughness: ?[]u8,

    fn deinit(self: *AtlasBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.diffuse);
        if (self.normal) |p| allocator.free(p);
        if (self.roughness) |p| allocator.free(p);
    }
};

const LoadStats = struct {
    loaded_count: u32 = 0,
    pbr_count: u32 = 0,
    fallback_count: u32 = 0,
    block_count: u32 = 0,
};

fn allocateAtlasBuffers(allocator: std.mem.Allocator, atlas_size: u32, has_pbr: bool) !AtlasBuffers {
    const pixel_count = atlas_size * atlas_size * 4;
    const diffuse = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(diffuse);
    @memset(diffuse, 255);

    var normal: ?[]u8 = null;
    var roughness: ?[]u8 = null;

    if (has_pbr) {
        normal = try allocator.alloc(u8, pixel_count);
        errdefer if (normal) |p| allocator.free(p);
        // Default normal: (128, 128, 255, 0) - Alpha 0 means no PBR
        var i: usize = 0;
        while (i < pixel_count) : (i += 4) {
            normal.?[i + 0] = 128;
            normal.?[i + 1] = 128;
            normal.?[i + 2] = 255;
            normal.?[i + 3] = 0;
        }

        roughness = try allocator.alloc(u8, pixel_count);
        errdefer if (roughness) |p| allocator.free(p);
        // Default roughness: 1.0 (Rough), displacement: 0.0
        @memset(roughness.?, 0);
        i = 0;
        while (i < pixel_count) : (i += 4) {
            roughness.?[i + 0] = 255; // Roughness
            roughness.?[i + 3] = 255; // Alpha
        }
    }

    return .{ .diffuse = diffuse, .normal = normal, .roughness = roughness };
}

fn loadBlockTextures(
    allocator: std.mem.Allocator,
    pack_manager: ?*resource_pack.ResourcePackManager,
    buffers: *AtlasBuffers,
    tile_mappings: *[MAX_BLOCK_TYPES]TextureAtlas.BlockTiles,
    tile_size: u32,
    atlas_size: u32,
    stats: *LoadStats,
) !void {
    var texture_indices = std.StringHashMap(u16).init(allocator);
    defer texture_indices.deinit();

    var next_tile_index: u16 = 1;

    for (&block_registry.BLOCK_REGISTRY) |*def| {
        if (std.mem.eql(u8, def.name, "unknown")) continue;
        if (def.id == .air) continue;

        stats.block_count += 1;
        const block_idx = @intFromEnum(def.id);
        const tex_names = [_][]const u8{ def.texture_top, def.texture_bottom, def.texture_side };
        var indices = [_]u16{0} ** 3;

        for (tex_names, 0..) |name, i| {
            if (texture_indices.get(name)) |idx| {
                indices[i] = idx;
                continue;
            }

            if (next_tile_index >= TILES_PER_ROW * TILES_PER_ROW) {
                log.log.err("Texture atlas: capacity exceeded (max {})", .{TILES_PER_ROW * TILES_PER_ROW});
                indices[i] = 0;
                continue;
            }

            const current_idx = next_tile_index;
            next_tile_index += 1;
            try texture_indices.put(name, current_idx);
            indices[i] = current_idx;

            if (try loadSingleTexture(allocator, pack_manager, name, current_idx, buffers, tile_size, atlas_size, stats)) |loaded_name| {
                _ = loaded_name;
            } else {
                const base_f32 = def.default_color;
                const base_u8 = [3]u8{
                    @intFromFloat(@min(base_f32[0] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[1] * 255.0, 255.0)),
                    @intFromFloat(@min(base_f32[2] * 255.0, 255.0)),
                };
                fillTileWithColor(buffers.diffuse, current_idx, base_u8, tile_size, atlas_size);
                stats.fallback_count += 1;
            }
        }

        tile_mappings[block_idx] = .{
            .top = indices[0],
            .bottom = indices[1],
            .side = indices[2],
        };
    }
}

fn loadSingleTexture(
    allocator: std.mem.Allocator,
    pack_manager: ?*resource_pack.ResourcePackManager,
    name: []const u8,
    tile_index: u16,
    buffers: *AtlasBuffers,
    tile_size: u32,
    atlas_size: u32,
    stats: *LoadStats,
) !?[]const u8 {
    const pm = pack_manager orelse return null;
    const has_pbr = buffers.normal != null;

    if (has_pbr) {
        var pbr_set = pm.loadPBRTextureSet(name);
        defer pbr_set.deinit(allocator);

        var loaded = false;
        if (pbr_set.diffuse) |diffuse| {
            copyTextureToTile(buffers.diffuse, tile_index, diffuse.pixels, diffuse.width, diffuse.height, tile_size, atlas_size);
            stats.loaded_count += 1;
            loaded = true;
        }

        if (pbr_set.normal) |normal| {
            copyTextureToTile(buffers.normal.?, tile_index, normal.pixels, normal.width, normal.height, tile_size, atlas_size);
            setTileAlpha(buffers.normal.?, tile_index, 255, tile_size, atlas_size);
            stats.pbr_count += 1;
        }

        if (pbr_set.roughness) |roughness| {
            copyTextureChannelToTile(buffers.roughness.?, tile_index, roughness.pixels, roughness.width, roughness.height, 0, 0, tile_size, atlas_size);
        }
        if (pbr_set.displacement) |displacement| {
            copyTextureChannelToTile(buffers.roughness.?, tile_index, displacement.pixels, displacement.width, displacement.height, 0, 1, tile_size, atlas_size);
        }

        return if (loaded) name else null;
    } else {
        if (pm.loadTexture(name)) |tex| {
            defer {
                var t = tex;
                t.deinit(allocator);
            }
            copyTextureToTile(buffers.diffuse, tile_index, tex.pixels, tex.width, tex.height, tile_size, atlas_size);
            stats.loaded_count += 1;
            return name;
        }
    }
    return null;
}

const AtlasTextures = struct {
    diffuse: Texture,
    normal: ?Texture,
    roughness: ?Texture,
};

fn createRhiTextures(rhi_instance: rhi.RHI, atlas_size: u32, buffers: *const AtlasBuffers) !AtlasTextures {
    // Disable mipmaps to prevent texture atlas bleeding between adjacent tiles
    // This is the only way to completely eliminate the "block outlines" (grid lines)
    const diffuse = try Texture.init(rhi_instance, atlas_size, atlas_size, .rgba_srgb, .{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .generate_mipmaps = false,
    }, buffers.diffuse);

    var normal: ?Texture = null;
    var roughness: ?Texture = null;

    if (buffers.normal) |np| {
        normal = try Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
        }, np);
    }

    if (buffers.roughness) |rp| {
        roughness = try Texture.init(rhi_instance, atlas_size, atlas_size, .rgba, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
        }, rp);
    }

    return .{ .diffuse = diffuse, .normal = normal, .roughness = roughness };
}

fn copyTextureChannelToTile(atlas_pixels: []u8, tile_index: u16, src_pixels: []const u8, src_width: u32, src_height: u32, src_channel: u8, dest_channel: u8, tile_size: u32, atlas_size: u32) void {
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

            if (src_idx + src_channel < src_pixels.len and dest_idx + dest_channel < atlas_pixels.len) {
                atlas_pixels[dest_idx + dest_channel] = src_pixels[src_idx + src_channel];
            } else {
                // Silently skip out-of-bounds, but only log in debug
                if (builtin.mode == .Debug) {
                    // Avoid spamming logs in tight loops
                }
            }
        }
    }
}

fn copyTextureToTile(atlas_pixels: []u8, tile_index: u16, src_pixels: []const u8, src_width: u32, src_height: u32, tile_size: u32, atlas_size: u32) void {
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

fn fillTileWithColor(atlas_pixels: []u8, tile_index: u16, color: [3]u8, tile_size: u32, atlas_size: u32) void {
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

fn setTileAlpha(atlas_pixels: []u8, tile_index: u16, alpha: u8, tile_size: u32, atlas_size: u32) void {
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
                atlas_pixels[dest_idx + 3] = alpha;
            }
        }
    }
}

/// Detect tile size from the first valid texture in the pack
fn detectTileSize(pack_manager: ?*resource_pack.ResourcePackManager, allocator: std.mem.Allocator, max_resolution: u32) u32 {
    if (pack_manager) |pm| {
        if (pm.getActivePackPath()) |pack_path| {
            const uses_pbr = pm.hasPBRSupport();

            for (block_registry.BLOCK_REGISTRY) |config| {
                if (std.mem.eql(u8, config.name, "unknown")) continue;

                const tex_names = [_][]const u8{ config.texture_top, config.texture_bottom, config.texture_side };
                for (tex_names) |name| {
                    var loaded_tex: ?resource_pack.LoadedTexture = null;

                    if (uses_pbr) {
                        loaded_tex = pm.loadPBRTexture(pack_path, name, .diffuse);
                    }

                    if (loaded_tex == null) {
                        loaded_tex = pm.loadFlatTexture(pack_path, name);
                    }

                    if (loaded_tex) |tex| {
                        const size = @max(tex.width, tex.height);
                        var t = tex;
                        t.deinit(allocator);
                        return @min(snapToSupportedSize(size), max_resolution);
                    }
                }
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
    return SUPPORTED_TILE_SIZES[SUPPORTED_TILE_SIZES.len - 1];
}

// Legacy constants for backward compatibility
pub const TILE_SIZE: u32 = DEFAULT_TILE_SIZE;
pub const ATLAS_SIZE: u32 = DEFAULT_TILE_SIZE * TILES_PER_ROW;
