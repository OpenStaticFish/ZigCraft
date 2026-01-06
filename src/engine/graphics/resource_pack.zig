//! Resource Pack Manager for loading texture packs.
//! Supports loading textures from TGA files with fallback to solid colors.

const std = @import("std");
const log = @import("../core/log.zig");

/// Texture name to file mapping for blocks
pub const TextureMapping = struct {
    name: []const u8,
    /// File names to try (in order of preference)
    files: []const []const u8,
};

/// Standard block texture mappings
pub const BLOCK_TEXTURES = [_]TextureMapping{
    .{ .name = "stone", .files = &.{ "stone.tga", "stone.png" } },
    .{ .name = "dirt", .files = &.{ "dirt.tga", "dirt.png" } },
    .{ .name = "grass_top", .files = &.{ "grass_top.tga", "grass_carried.tga", "grass_block_top.tga", "grass_top.png", "grass_carried.png" } },
    .{ .name = "grass_side", .files = &.{ "grass_side.tga", "grass_side_carried.tga", "grass_block_side.tga", "grass_side.png", "grass_side_carried.png" } },
    .{ .name = "sand", .files = &.{ "sand.tga", "sand.png" } },
    .{ .name = "cobblestone", .files = &.{ "cobblestone.tga", "cobblestone.png" } },
    .{ .name = "bedrock", .files = &.{ "bedrock.tga", "bedrock.png" } },
    .{ .name = "gravel", .files = &.{ "gravel.tga", "gravel.png" } },
    .{ .name = "wood_side", .files = &.{ "wood_side.tga", "oak_log.tga", "log_oak.tga", "wood_side.png" } },
    .{ .name = "wood_top", .files = &.{ "wood_top.tga", "oak_log_top.tga", "log_oak_top.tga", "wood_top.png" } },
    .{ .name = "leaves", .files = &.{ "leaves.tga", "oak_leaves.tga", "leaves_oak.tga", "leaves.png" } },
    .{ .name = "water", .files = &.{ "water.tga", "water_still.tga", "water.png" } },
    .{ .name = "glass", .files = &.{ "glass.tga", "glass.png" } },
    .{ .name = "glowstone", .files = &.{ "glowstone.tga", "glowstone.png" } },
    .{ .name = "mud", .files = &.{ "mud.tga", "mud.png" } },
    .{ .name = "snow_block", .files = &.{ "snow_block.tga", "snow.tga", "snow_block.png" } },
    .{ .name = "cactus_side", .files = &.{ "cactus_side.tga", "cactus_side.png" } },
    .{ .name = "cactus_top", .files = &.{ "cactus_top.tga", "cactus_top.png" } },
    .{ .name = "coal_ore", .files = &.{ "coal_ore.tga", "coal_ore.png" } },
    .{ .name = "iron_ore", .files = &.{ "iron_ore.tga", "iron_ore.png" } },
    .{ .name = "gold_ore", .files = &.{ "gold_ore.tga", "gold_ore.png" } },
    .{ .name = "clay", .files = &.{ "clay.tga", "clay.png" } },
    .{ .name = "mangrove_log_side", .files = &.{ "mangrove_log_side.tga", "mangrove_log_side.png" } },
    .{ .name = "mangrove_log_top", .files = &.{ "mangrove_log_top.tga", "mangrove_log_top.png" } },
    .{ .name = "mangrove_leaves", .files = &.{ "mangrove_leaves.tga", "mangrove_leaves.png" } },
    .{ .name = "mangrove_roots", .files = &.{ "mangrove_roots.tga", "mangrove_roots.png" } },
    .{ .name = "jungle_log_side", .files = &.{ "jungle_log_side.tga", "log_jungle.tga", "jungle_log_side.png" } },
    .{ .name = "jungle_log_top", .files = &.{ "jungle_log_top.tga", "log_jungle_top.tga", "jungle_log_top.png" } },
    .{ .name = "jungle_leaves", .files = &.{ "jungle_leaves.tga", "jungle_leaves.png" } },
    .{ .name = "melon_side", .files = &.{ "melon_side.tga", "melon_side.png" } },
    .{ .name = "melon_top", .files = &.{ "melon_top.tga", "melon_top.png" } },
    .{ .name = "bamboo", .files = &.{ "bamboo.tga", "bamboo_stem.tga", "bamboo.png" } },
    .{ .name = "acacia_log_side", .files = &.{ "acacia_log_side.tga", "log_acacia.tga", "acacia_log_side.png" } },
    .{ .name = "acacia_log_top", .files = &.{ "acacia_log_top.tga", "log_acacia_top.tga", "acacia_log_top.png" } },
    .{ .name = "acacia_leaves", .files = &.{ "acacia_leaves.tga", "acacia_leaves.png" } },
    .{ .name = "acacia_sapling", .files = &.{ "acacia_sapling.tga", "sapling_acacia.tga", "acacia_sapling.png" } },
    .{ .name = "terracotta", .files = &.{ "terracotta.tga", "hardened_clay.tga", "terracotta.png" } },
    .{ .name = "red_sand", .files = &.{ "red_sand.tga", "red_sand.png" } },
    .{ .name = "mycelium_top", .files = &.{ "mycelium_top.tga", "mycelium_top.png" } },
    .{ .name = "mycelium_side", .files = &.{ "mycelium_side.tga", "mycelium_side.png" } },
    .{ .name = "mushroom_stem", .files = &.{ "mushroom_stem.tga", "mushroom_block_skin_stem.tga", "mushroom_stem.png" } },
    .{ .name = "red_mushroom_block", .files = &.{ "red_mushroom_block.tga", "mushroom_block_skin_red.tga", "red_mushroom_block.png" } },
    .{ .name = "brown_mushroom_block", .files = &.{ "brown_mushroom_block.tga", "mushroom_block_skin_brown.tga", "brown_mushroom_block.png" } },
    .{ .name = "tall_grass", .files = &.{ "tall_grass.tga", "tallgrass.tga", "tall_grass.png" } },
    .{ .name = "flower_red", .files = &.{ "flower_red.tga", "flower_rose.tga", "poppy.tga", "flower_red.png" } },
    .{ .name = "flower_yellow", .files = &.{ "flower_yellow.tga", "flower_dandelion.tga", "dandelion.tga", "flower_yellow.png" } },
    .{ .name = "dead_bush", .files = &.{ "dead_bush.tga", "deadbush.tga", "dead_bush.png" } },
};

pub const LoadedTexture = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    pub fn deinit(self: *LoadedTexture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
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

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .base_path = "assets/textures",
            .available_packs = .{},
            .active_pack = null,
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
    }

    pub fn getActivePackPath(self: *const Self) ?[]const u8 {
        if (self.active_pack) |pack_name| {
            for (self.available_packs.items) |pack| if (std.mem.eql(u8, pack.name, pack_name)) return pack.path;
        }
        return null;
    }

    pub fn loadTexture(self: *Self, texture_name: []const u8) ?LoadedTexture {
        const pack_path = self.getActivePackPath() orelse return null;
        for (BLOCK_TEXTURES) |mapping| {
            if (std.mem.eql(u8, mapping.name, texture_name)) {
                for (mapping.files) |file_name| {
                    const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pack_path, file_name }) catch continue;
                    defer self.allocator.free(full_path);
                    if (std.mem.endsWith(u8, file_name, ".tga")) if (self.loadTgaFile(full_path)) |texture| return texture;
                }
                break;
            }
        }
        return null;
    }

    fn loadTgaFile(self: *Self, path: []const u8) ?LoadedTexture {
        const buffer = std.fs.cwd().readFileAlloc(path, self.allocator, @enumFromInt(10 * 1024 * 1024)) catch return null;
        defer self.allocator.free(buffer);
        if (buffer.len < 18) return null;
        const id_length = buffer[0];
        const image_type = buffer[2];
        const width = @as(u32, buffer[12]) | (@as(u32, buffer[13]) << 8);
        const height = @as(u32, buffer[14]) | (@as(u32, buffer[15]) << 8);
        const pixel_depth = buffer[16];
        const descriptor = buffer[17];
        if (image_type != 2 and image_type != 3) return null;
        const bytes_per_pixel = pixel_depth / 8;
        if (bytes_per_pixel == 0) return null;
        const pixel_data_start = 18 + id_length;
        if (buffer.len < pixel_data_start + width * height * bytes_per_pixel) return null;
        const pixels = self.allocator.alloc(u8, width * height * 4) catch return null;
        const top_down = (descriptor & 0x20) != 0;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const src_y = if (top_down) y else (height - 1 - y);
                const src_idx = pixel_data_start + (src_y * width + x) * bytes_per_pixel;
                const dest_idx = (y * width + x) * 4;
                if (image_type == 3) {
                    const val = buffer[src_idx];
                    pixels[dest_idx + 0] = val;
                    pixels[dest_idx + 1] = val;
                    pixels[dest_idx + 2] = val;
                    pixels[dest_idx + 3] = if (bytes_per_pixel >= 2) buffer[src_idx + 1] else 255;
                } else {
                    pixels[dest_idx + 0] = buffer[src_idx + 2];
                    pixels[dest_idx + 1] = buffer[src_idx + 1];
                    pixels[dest_idx + 2] = buffer[src_idx + 0];
                    pixels[dest_idx + 3] = if (bytes_per_pixel >= 4) buffer[src_idx + 3] else 255;
                }
            }
        }
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn packExists(self: *const Self, name: []const u8) bool {
        for (self.available_packs.items) |pack| if (std.mem.eql(u8, pack.name, name)) return true;
        return false;
    }

    pub fn getPackNames(self: *const Self) []const PackInfo {
        return self.available_packs.items;
    }
};
