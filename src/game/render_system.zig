const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("../engine/core/log.zig");
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const rhi_opengl = @import("../engine/graphics/rhi_opengl.zig");
const rhi_vulkan = @import("../engine/graphics/rhi_vulkan.zig");
const Shader = @import("../engine/graphics/shader.zig").Shader;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const Atmosphere = @import("../engine/graphics/atmosphere.zig").Atmosphere;
const ShadowMap = @import("../engine/graphics/shadows.zig").ShadowMap;
const Clouds = @import("../engine/graphics/clouds.zig").Clouds;
const Settings = @import("state.zig").Settings;

pub const RenderSystem = struct {
    allocator: std.mem.Allocator,
    rhi: RHI,
    is_vulkan: bool,
    shader: ?Shader,
    atlas: TextureAtlas,
    atmosphere: ?Atmosphere,
    clouds: ?Clouds,
    shadow_map: ?ShadowMap,

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window, is_vulkan: bool, settings: *const Settings) !RenderSystem {
        if (!is_vulkan) {
            if (c.glewInit() != c.GLEW_OK) return error.GLEWInitFailed;
        }

        const RhiResult = struct {
            rhi: RHI,
            is_vulkan: bool,
        };

        const rhi_and_type = if (is_vulkan) blk: {
            log.log.info("Attempting to initialize Vulkan backend...", .{});
            const res = rhi_vulkan.createRHI(allocator, window);
            if (res) |v| {
                break :blk RhiResult{ .rhi = v, .is_vulkan = true };
            } else |err| {
                log.log.err("Failed to initialize Vulkan: {}. Falling back to OpenGL.", .{err});
                if (c.glewInit() != c.GLEW_OK) return error.GLEWInitFailed;
                break :blk RhiResult{ .rhi = try rhi_opengl.createRHI(allocator), .is_vulkan = false };
            }
        } else blk: {
            log.log.info("Initializing OpenGL backend...", .{});
            break :blk RhiResult{ .rhi = try rhi_opengl.createRHI(allocator), .is_vulkan = false };
        };

        const rhi = rhi_and_type.rhi;
        const actual_is_vulkan = rhi_and_type.is_vulkan;

        try rhi.init(allocator);

        const shader: ?Shader = if (!actual_is_vulkan) try Shader.initFromFile(allocator, "assets/shaders/terrain.vert", "assets/shaders/terrain.frag") else null;

        const atlas = try TextureAtlas.init(allocator, rhi);
        const atmosphere = if (actual_is_vulkan) Atmosphere.initNoGL() else Atmosphere.init();
        const clouds = if (actual_is_vulkan) Clouds.initNoGL() else try Clouds.init();
        const shadow_map = if (!actual_is_vulkan) blk: {
            const sm = ShadowMap.init(rhi, settings.shadow_resolution) catch |err| {
                log.log.warn("ShadowMap initialization failed: {}. Shadows disabled.", .{err});
                break :blk null;
            };
            break :blk sm;
        } else null;

        return RenderSystem{
            .allocator = allocator,
            .rhi = rhi,
            .is_vulkan = actual_is_vulkan,
            .shader = shader,
            .atlas = atlas,
            .atmosphere = atmosphere,
            .clouds = clouds,
            .shadow_map = shadow_map,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        if (self.shadow_map) |*sm| sm.deinit();
        if (self.clouds) |*cl| cl.deinit();
        if (self.atmosphere) |*a| a.deinit();
        self.atlas.deinit();
        if (self.shader) |*s| s.deinit();
        self.rhi.deinit();
    }
};
