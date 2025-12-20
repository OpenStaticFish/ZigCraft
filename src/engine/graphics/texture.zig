//! Texture loading and management.

const std = @import("std");
const c = @import("../../c.zig").c;

const log = @import("../core/log.zig");

/// Texture filtering modes
pub const FilterMode = enum {
    nearest,
    linear,
    nearest_mipmap_nearest,
    linear_mipmap_nearest,
    nearest_mipmap_linear,
    linear_mipmap_linear,
};

/// Texture wrap modes
pub const WrapMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
    clamp_to_border,
};

/// Texture format
pub const TextureFormat = enum {
    rgb,
    rgba,
    red,
    depth,
};

pub const Texture = struct {
    id: c.GLuint,
    width: u32,
    height: u32,
    format: TextureFormat,

    pub const Config = struct {
        min_filter: FilterMode = .linear_mipmap_linear,
        mag_filter: FilterMode = .linear,
        wrap_s: WrapMode = .repeat,
        wrap_t: WrapMode = .repeat,
        generate_mipmaps: bool = true,
    };

    /// Create texture from raw pixel data
    pub fn init(width: u32, height: u32, data: ?[*]const u8, format: TextureFormat, config: Config) Texture {
        var id: c.GLuint = undefined;
        c.glGenTextures(1, &id);
        c.glBindTexture(c.GL_TEXTURE_2D, id);

        // Set parameters
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrapModeToGL(config.wrap_s));
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrapModeToGL(config.wrap_t));
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filterModeToGL(config.min_filter));
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filterModeToGL(config.mag_filter));

        // Upload texture data
        const gl_format = formatToGL(format);
        const internal_format = formatToInternalGL(format);

        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            internal_format,
            @intCast(width),
            @intCast(height),
            0,
            gl_format,
            c.GL_UNSIGNED_BYTE,
            data,
        );

        if (config.generate_mipmaps and data != null) {
            c.glGenerateMipmap().?(c.GL_TEXTURE_2D);
        }

        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        log.log.debug("Texture created: {}x{} (ID: {})", .{ width, height, id });

        return .{
            .id = id,
            .width = width,
            .height = height,
            .format = format,
        };
    }

    /// Create empty texture (for render targets, etc.)
    pub fn initEmpty(width: u32, height: u32, format: TextureFormat, config: Config) Texture {
        return init(width, height, null, format, config);
    }

    /// Create a 1x1 solid color texture
    pub fn initSolidColor(r: u8, g: u8, b: u8, a: u8) Texture {
        const data = [_]u8{ r, g, b, a };
        return init(1, 1, &data, .rgba, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .generate_mipmaps = false,
        });
    }

    pub fn deinit(self: *Texture) void {
        c.glDeleteTextures(1, &self.id);
    }

    /// Bind texture to a specific slot
    pub fn bind(self: *const Texture, slot: u32) void {
        const texture_unit: c.GLenum = @intCast(c.GL_TEXTURE0 + @as(c.GLint, @intCast(slot)));
        c.glActiveTexture().?(texture_unit);
        c.glBindTexture(c.GL_TEXTURE_2D, self.id);
    }

    /// Unbind texture from slot
    pub fn unbind(slot: u32) void {
        const texture_unit: c.GLenum = @intCast(c.GL_TEXTURE0 + @as(c.GLint, @intCast(slot)));
        c.glActiveTexture().?(texture_unit);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    /// Update texture data (must match original dimensions)
    pub fn update(self: *Texture, data: [*]const u8) void {
        c.glBindTexture(c.GL_TEXTURE_2D, self.id);
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            formatToGL(self.format),
            c.GL_UNSIGNED_BYTE,
            data,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    fn wrapModeToGL(mode: WrapMode) c.GLint {
        return switch (mode) {
            .repeat => c.GL_REPEAT,
            .mirrored_repeat => c.GL_MIRRORED_REPEAT,
            .clamp_to_edge => c.GL_CLAMP_TO_EDGE,
            .clamp_to_border => c.GL_CLAMP_TO_BORDER,
        };
    }

    fn filterModeToGL(mode: FilterMode) c.GLint {
        return switch (mode) {
            .nearest => c.GL_NEAREST,
            .linear => c.GL_LINEAR,
            .nearest_mipmap_nearest => c.GL_NEAREST_MIPMAP_NEAREST,
            .linear_mipmap_nearest => c.GL_LINEAR_MIPMAP_NEAREST,
            .nearest_mipmap_linear => c.GL_NEAREST_MIPMAP_LINEAR,
            .linear_mipmap_linear => c.GL_LINEAR_MIPMAP_LINEAR,
        };
    }

    fn formatToGL(format: TextureFormat) c.GLenum {
        return switch (format) {
            .rgb => c.GL_RGB,
            .rgba => c.GL_RGBA,
            .red => c.GL_RED,
            .depth => c.GL_DEPTH_COMPONENT,
        };
    }

    fn formatToInternalGL(format: TextureFormat) c.GLint {
        return switch (format) {
            .rgb => c.GL_RGB8,
            .rgba => c.GL_RGBA8,
            .red => c.GL_R8,
            .depth => c.GL_DEPTH_COMPONENT24,
        };
    }
};

/// Texture slot manager to track which textures are bound where
pub const TextureSlots = struct {
    slots: [16]?c.GLuint = .{null} ** 16,
    active_slot: u32 = 0,

    pub fn bind(self: *TextureSlots, texture: *const Texture, slot: u32) void {
        if (slot >= 16) return;
        if (self.slots[slot] == texture.id) return; // Already bound

        texture.bind(slot);
        self.slots[slot] = texture.id;
        self.active_slot = slot;
    }

    pub fn unbind(self: *TextureSlots, slot: u32) void {
        if (slot >= 16) return;
        Texture.unbind(slot);
        self.slots[slot] = null;
    }

    pub fn clear(self: *TextureSlots) void {
        for (0..16) |i| {
            if (self.slots[i] != null) {
                Texture.unbind(@intCast(i));
                self.slots[i] = null;
            }
        }
    }
};
