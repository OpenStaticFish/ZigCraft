//! Resource Pack Manager for loading texture packs.
//! Supports loading textures from PNG files using stb_image with fallback to solid colors.
//! Supports PBR texture maps: diffuse, normal, roughness, displacement.

const std = @import("std");
const log = @import("../core/log.zig");
const c = @import("../../c.zig").c;

/// PBR map types
pub const PBRMapType = enum {
    diffuse, // Base color / albedo (or legacy single texture)
    normal, // Normal map (OpenGL format)
    roughness, // Roughness map
    displacement, // Displacement/height map

    pub fn getSuffix(self: PBRMapType) []const u8 {
        return switch (self) {
            .diffuse => "_diff",
            .normal => "_nor_gl",
            .roughness => "_rough",
            .displacement => "_disp",
        };
    }

    pub fn getDefaultSuffix(self: PBRMapType) []const u8 {
        // Alternative suffixes for compatibility
        return switch (self) {
            .diffuse => "", // No suffix for diffuse (backward compat)
            .normal => "_normal",
            .roughness => "_roughness",
            .displacement => "_height",
        };
    }
};

/// Texture name to file mapping for blocks
pub const TextureMapping = struct {
    name: []const u8,
    /// File names to try (in order of preference)
    files: []const []const u8,
};

/// Standard block texture mappings (PNG preferred)
pub const BLOCK_TEXTURES = [_]TextureMapping{
    .{ .name = "stone", .files = &.{"stone.png"} },
    .{ .name = "dirt", .files = &.{"dirt.png"} },
    .{ .name = "grass_top", .files = &.{ "grass_top.png", "grass_carried.png", "grass_block_top.png" } },
    .{ .name = "grass_side", .files = &.{ "grass_side.png", "grass_side_carried.png", "grass_block_side.png" } },
    .{ .name = "sand", .files = &.{"sand.png"} },
    .{ .name = "cobblestone", .files = &.{"cobblestone.png"} },
    .{ .name = "bedrock", .files = &.{"bedrock.png"} },
    .{ .name = "gravel", .files = &.{"gravel.png"} },
    .{ .name = "wood_side", .files = &.{ "wood_side.png", "oak_log.png", "log_oak.png" } },
    .{ .name = "wood_top", .files = &.{ "wood_top.png", "oak_log_top.png", "log_oak_top.png" } },
    .{ .name = "leaves", .files = &.{ "leaves.png", "oak_leaves.png", "leaves_oak.png" } },
    .{ .name = "water", .files = &.{ "water.png", "water_still.png" } },
    .{ .name = "glass", .files = &.{"glass.png"} },
    .{ .name = "glowstone", .files = &.{"glowstone.png"} },
    .{ .name = "mud", .files = &.{"mud.png"} },
    .{ .name = "snow_block", .files = &.{ "snow_block.png", "snow.png" } },
    .{ .name = "cactus_side", .files = &.{"cactus_side.png"} },
    .{ .name = "cactus_top", .files = &.{"cactus_top.png"} },
    .{ .name = "coal_ore", .files = &.{"coal_ore.png"} },
    .{ .name = "iron_ore", .files = &.{"iron_ore.png"} },
    .{ .name = "gold_ore", .files = &.{"gold_ore.png"} },
    .{ .name = "clay", .files = &.{"clay.png"} },
    .{ .name = "mangrove_log_side", .files = &.{"mangrove_log_side.png"} },
    .{ .name = "mangrove_log_top", .files = &.{"mangrove_log_top.png"} },
    .{ .name = "mangrove_leaves", .files = &.{"mangrove_leaves.png"} },
    .{ .name = "mangrove_roots", .files = &.{"mangrove_roots.png"} },
    .{ .name = "jungle_log_side", .files = &.{ "jungle_log_side.png", "log_jungle.png" } },
    .{ .name = "jungle_log_top", .files = &.{ "jungle_log_top.png", "log_jungle_top.png" } },
    .{ .name = "jungle_leaves", .files = &.{"jungle_leaves.png"} },
    .{ .name = "melon_side", .files = &.{"melon_side.png"} },
    .{ .name = "melon_top", .files = &.{"melon_top.png"} },
    .{ .name = "bamboo", .files = &.{ "bamboo.png", "bamboo_stem.png" } },
    .{ .name = "acacia_log_side", .files = &.{ "acacia_log_side.png", "log_acacia.png" } },
    .{ .name = "acacia_log_top", .files = &.{ "acacia_log_top.png", "log_acacia_top.png" } },
    .{ .name = "acacia_leaves", .files = &.{"acacia_leaves.png"} },
    .{ .name = "acacia_sapling", .files = &.{ "acacia_sapling.png", "sapling_acacia.png" } },
    .{ .name = "terracotta", .files = &.{ "terracotta.png", "hardened_clay.png" } },
    .{ .name = "red_sand", .files = &.{"red_sand.png"} },
    .{ .name = "mycelium_top", .files = &.{"mycelium_top.png"} },
    .{ .name = "mycelium_side", .files = &.{"mycelium_side.png"} },
    .{ .name = "mushroom_stem", .files = &.{ "mushroom_stem.png", "mushroom_block_skin_stem.png" } },
    .{ .name = "red_mushroom_block", .files = &.{ "red_mushroom_block.png", "mushroom_block_skin_red.png" } },
    .{ .name = "brown_mushroom_block", .files = &.{ "brown_mushroom_block.png", "mushroom_block_skin_brown.png" } },
    .{ .name = "tall_grass", .files = &.{ "tall_grass.png", "tallgrass.png" } },
    .{ .name = "flower_red", .files = &.{ "flower_red.png", "flower_rose.png", "poppy.png" } },
    .{ .name = "flower_yellow", .files = &.{ "flower_yellow.png", "flower_dandelion.png", "dandelion.png" } },
    .{ .name = "dead_bush", .files = &.{ "dead_bush.png", "deadbush.png" } },
};

pub const LoadedTexture = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    pub fn deinit(self: *LoadedTexture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// PBR texture set for a single block texture
pub const PBRTextureSet = struct {
    diffuse: ?LoadedTexture,
    normal: ?LoadedTexture,
    roughness: ?LoadedTexture,
    displacement: ?LoadedTexture,

    pub fn hasPBR(self: *const PBRTextureSet) bool {
        return self.normal != null or self.roughness != null or self.displacement != null;
    }

    pub fn deinit(self: *PBRTextureSet, allocator: std.mem.Allocator) void {
        if (self.diffuse) |*tex| tex.deinit(allocator);
        if (self.normal) |*tex| tex.deinit(allocator);
        if (self.roughness) |*tex| tex.deinit(allocator);
        if (self.displacement) |*tex| tex.deinit(allocator);
    }
};

pub const PackInfo = struct {
    name: []const u8,
    path: []const u8,
    pub fn deinit(self: *PackInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const ResourcePackManager = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    available_packs: std.ArrayListUnmanaged(PackInfo),
    active_pack: ?[]const u8,
    /// Whether the active pack uses PBR folder structure
    uses_pbr_structure: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .base_path = "assets/textures",
            .available_packs = .{},
            .active_pack = null,
            .uses_pbr_structure = false,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.available_packs.items) |*pack| pack.deinit(self.allocator);
        self.available_packs.deinit(self.allocator);
        if (self.active_pack) |pack| self.allocator.free(pack);
    }

    pub fn scanPacks(self: *Self) !void {
        for (self.available_packs.items) |*pack| pack.deinit(self.allocator);
        self.available_packs.clearRetainingCapacity();

        var dir = std.fs.cwd().openDir(self.base_path, .{ .iterate = true }) catch |err| {
            log.log.warn("Could not open texture packs directory: {}", .{err});
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const name = try self.allocator.dupe(u8, entry.name);
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_path, entry.name });
                try self.available_packs.append(self.allocator, .{ .name = name, .path = path });
                log.log.info("Found texture pack: {s}", .{entry.name});
            }
        }
        log.log.info("Found {} texture pack(s)", .{self.available_packs.items.len});
    }

    pub fn setActivePack(self: *Self, pack_name: []const u8) !void {
        if (self.active_pack) |old| self.allocator.free(old);
        self.active_pack = try self.allocator.dupe(u8, pack_name);
        log.log.info("Active texture pack set to: {s}", .{pack_name});

        // Detect if this pack uses PBR folder structure
        self.uses_pbr_structure = self.detectPBRStructure();
        if (self.uses_pbr_structure) {
            log.log.info("Detected PBR folder structure in pack: {s}", .{pack_name});
        }
    }

    /// Detect if the pack uses PBR folder structure (e.g., stone/stone_diff.png)
    fn detectPBRStructure(self: *Self) bool {
        const pack_path = self.getActivePackPath() orelse return false;

        // Check if any block subfolder exists with PBR files
        const test_blocks = [_][]const u8{ "stone", "dirt", "cobblestone" };
        for (test_blocks) |block_name| {
            const subfolder_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pack_path, block_name }) catch continue;
            defer self.allocator.free(subfolder_path);

            var dir = std.fs.cwd().openDir(subfolder_path, .{}) catch continue;
            dir.close();

            // Subfolder exists, check for PBR files
            const diff_path = std.fmt.allocPrint(self.allocator, "{s}/{s}_diff.png", .{ subfolder_path, block_name }) catch continue;
            defer self.allocator.free(diff_path);

            if (std.fs.cwd().access(diff_path, .{})) |_| {
                return true;
            } else |_| {
                // Also check for just the block name (e.g., stone/stone.png)
                const base_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.png", .{ subfolder_path, block_name }) catch continue;
                defer self.allocator.free(base_path);
                if (std.fs.cwd().access(base_path, .{})) |_| {
                    return true;
                } else |_| {}
            }
        }
        return false;
    }

    pub fn getActivePackPath(self: *const Self) ?[]const u8 {
        if (self.active_pack) |pack_name| {
            for (self.available_packs.items) |pack| if (std.mem.eql(u8, pack.name, pack_name)) return pack.path;
        }
        return null;
    }

    /// Check if the active pack has PBR textures
    pub fn hasPBRSupport(self: *const Self) bool {
        return self.uses_pbr_structure;
    }

    /// Load a texture (backward compatible - returns diffuse/base color)
    pub fn loadTexture(self: *Self, texture_name: []const u8) ?LoadedTexture {
        const pack_path = self.getActivePackPath() orelse return null;

        // First, try PBR folder structure: pack/block_name/block_name_diff.png or pack/block_name/block_name.png
        if (self.uses_pbr_structure) {
            if (self.loadPBRTexture(pack_path, texture_name, .diffuse)) |tex| {
                return tex;
            }
        }

        // Fall back to flat structure: pack/block_name.png
        for (BLOCK_TEXTURES) |mapping| {
            if (std.mem.eql(u8, mapping.name, texture_name)) {
                for (mapping.files) |file_name| {
                    const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pack_path, file_name }) catch continue;
                    defer self.allocator.free(full_path);
                    if (self.loadImageFile(full_path)) |texture| return texture;
                }
                break;
            }
        }
        return null;
    }

    /// Load a specific PBR map type for a texture
    pub fn loadPBRMap(self: *Self, texture_name: []const u8, map_type: PBRMapType) ?LoadedTexture {
        const pack_path = self.getActivePackPath() orelse return null;

        if (!self.uses_pbr_structure) return null;

        return self.loadPBRTexture(pack_path, texture_name, map_type);
    }

    /// Load all PBR maps for a texture
    pub fn loadPBRTextureSet(self: *Self, texture_name: []const u8) PBRTextureSet {
        return .{
            .diffuse = self.loadPBRMap(texture_name, .diffuse) orelse self.loadTexture(texture_name),
            .normal = self.loadPBRMap(texture_name, .normal),
            .roughness = self.loadPBRMap(texture_name, .roughness),
            .displacement = self.loadPBRMap(texture_name, .displacement),
        };
    }

    /// Load a PBR texture from the folder structure
    fn loadPBRTexture(self: *Self, pack_path: []const u8, texture_name: []const u8, map_type: PBRMapType) ?LoadedTexture {
        // Try: pack/texture_name/texture_name_suffix.png
        const suffix = map_type.getSuffix();
        const alt_suffix = map_type.getDefaultSuffix();

        // Primary: stone/stone_diff.png
        const primary_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}{s}.png",
            .{ pack_path, texture_name, texture_name, suffix },
        ) catch return null;
        defer self.allocator.free(primary_path);

        if (self.loadImageFile(primary_path)) |tex| {
            log.log.debug("Loaded PBR {s}: {s}", .{ @tagName(map_type), primary_path });
            return tex;
        }

        // Alternative suffix: stone/stone_normal.png
        if (alt_suffix.len > 0) {
            const alt_path = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}/{s}{s}.png",
                .{ pack_path, texture_name, texture_name, alt_suffix },
            ) catch return null;
            defer self.allocator.free(alt_path);

            if (self.loadImageFile(alt_path)) |tex| {
                log.log.debug("Loaded PBR {s} (alt): {s}", .{ @tagName(map_type), alt_path });
                return tex;
            }
        }

        // For diffuse, also try just the base name: stone/stone.png
        if (map_type == .diffuse) {
            const base_path = std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}/{s}.png",
                .{ pack_path, texture_name, texture_name },
            ) catch return null;
            defer self.allocator.free(base_path);

            if (self.loadImageFile(base_path)) |tex| {
                log.log.debug("Loaded PBR diffuse (base): {s}", .{base_path});
                return tex;
            }
        }

        return null;
    }

    fn loadImageFile(self: *Self, path: []const u8) ?LoadedTexture {
        // Read file into memory
        const file_data = std.fs.cwd().readFileAlloc(path, self.allocator, @enumFromInt(10 * 1024 * 1024)) catch |err| {
            log.log.debug("Failed to read file {s}: {}", .{ path, err });
            return null;
        };
        defer self.allocator.free(file_data);

        log.log.debug("Read file {s}: {} bytes", .{ path, file_data.len });

        // Use stb_image to decode the image
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        const img_data = c.stbi_load_from_memory(
            file_data.ptr,
            @intCast(file_data.len),
            &width,
            &height,
            &channels,
            4, // Force RGBA
        );

        if (img_data == null) {
            log.log.warn("stbi_load_from_memory failed for {s}", .{path});
            return null;
        }
        defer c.stbi_image_free(img_data);

        log.log.debug("Decoded image {s}: {}x{} channels={}", .{ path, width, height, channels });

        // Copy to Zig-managed memory
        const size: usize = @intCast(@as(u32, @intCast(width)) * @as(u32, @intCast(height)) * 4);
        const pixels = self.allocator.alloc(u8, size) catch return null;
        @memcpy(pixels, img_data[0..size]);

        return .{
            .pixels = pixels,
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    pub fn packExists(self: *const Self, name: []const u8) bool {
        for (self.available_packs.items) |pack| if (std.mem.eql(u8, pack.name, name)) return true;
        return false;
    }

    pub fn getPackNames(self: *const Self) []const PackInfo {
        return self.available_packs.items;
    }
};
