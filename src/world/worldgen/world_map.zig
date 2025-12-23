const std = @import("std");
const c = @import("../../c.zig").c;
const TerrainGenerator = @import("generator.zig").TerrainGenerator;
const BiomeId = @import("biome.zig").BiomeId;
const Texture = @import("../../engine/graphics/texture.zig").Texture;

const rhi = @import("../../engine/graphics/rhi.zig");

pub const WorldMap = struct {
    texture: Texture,
    width: u32,
    height: u32,

    pub fn init(rhi_instance: rhi.RHI, width: u32, height: u32, is_vulkan: bool) WorldMap {
        // Safety: ensure texture size is within typical hardware limits
        const safe_w = @min(width, 4096);
        const safe_h = @min(height, 4096);

        const texture = Texture.initEmpty(rhi_instance, safe_w, safe_h, .rgba, .{
            .min_filter = .linear,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        });

        // Fix for hardcoded RHI filter settings (which force mipmaps)
        // We need NEAREST filtering and NO mipmaps for the map to look crisp and be complete
        if (!is_vulkan) {
            texture.bind(0);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_BASE_LEVEL, 0);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAX_LEVEL, 0);
        }

        return .{
            .texture = texture,
            .width = safe_w,
            .height = safe_h,
        };
    }

    pub fn deinit(self: *WorldMap) void {
        self.texture.deinit();
    }

    pub fn update(self: *WorldMap, generator: *const TerrainGenerator, center_x: f32, center_z: f32, scale: f32) !void {
        const pixel_count = self.width * self.height;
        var pixels = try generator.allocator.alloc(u8, pixel_count * 4);
        defer generator.allocator.free(pixels);

        const hw = @as(f32, @floatFromInt(self.width)) * 0.5;
        const hh = @as(f32, @floatFromInt(self.height)) * 0.5;
        const start_x = center_x - (hw * scale);
        const start_z = center_z - (hh * scale);

        var py: u32 = 0;
        while (py < self.height) : (py += 1) {
            const wz = start_z + @as(f32, @floatFromInt(py)) * scale;
            var px: u32 = 0;
            while (px < self.width) : (px += 1) {
                const wx = start_x + @as(f32, @floatFromInt(px)) * scale;

                const info = generator.getColumnInfo(wx, wz);
                const color = getBiomeColor(info);

                const idx = (px + py * self.width) * 4;
                pixels[idx + 0] = @intFromFloat(color[0] * 255.0);
                pixels[idx + 1] = @intFromFloat(color[1] * 255.0);
                pixels[idx + 2] = @intFromFloat(color[2] * 255.0);
                pixels[idx + 3] = 255;
            }
        }

        self.texture.update(pixels);
    }

    fn getBiomeColor(info: TerrainGenerator.ColumnInfo) [3]f32 {
        if (info.is_ocean) {
            const depth = @as(f32, @floatFromInt(64 - info.height));
            const t = std.math.clamp(depth / 40.0, 0.0, 1.0);
            // Deep blue to light blue
            return .{
                std.math.lerp(0.2, 0.05, t),
                std.math.lerp(0.4, 0.1, t),
                std.math.lerp(0.8, 0.4, t),
            };
        }

        return switch (info.biome) {
            .beach => .{ 0.9, 0.85, 0.6 },
            .desert => .{ 0.8, 0.7, 0.4 },
            .badlands => .{ 0.7, 0.4, 0.2 },
            .snow_tundra, .snowy_mountains => .{ 0.9, 0.9, 1.0 },
            .mountains => .{ 0.5, 0.5, 0.5 },
            .forest, .jungle => .{ 0.1, 0.4, 0.1 },
            .taiga => .{ 0.2, 0.3, 0.2 },
            .savanna => .{ 0.6, 0.6, 0.3 },
            .swamp, .mangrove_swamp => .{ 0.2, 0.3, 0.2 },
            .river => .{ 0.2, 0.4, 0.8 },
            .mushroom_fields => .{ 0.5, 0.4, 0.5 },
            else => .{ 0.3, 0.6, 0.2 }, // Plains/Default green
        };
    }
};
