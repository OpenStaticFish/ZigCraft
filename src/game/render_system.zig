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
    debug_shader: ?Shader,
    debug_quad_vao: c.GLuint,
    debug_quad_vbo: c.GLuint,
    atlas: TextureAtlas,
    atmosphere: ?Atmosphere,
    clouds: ?Clouds,
    shadow_map: ?ShadowMap,

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window, is_vulkan: bool, settings: *const Settings) !RenderSystem {
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
            if (c.glewInit() != c.GLEW_OK) {
                return error.GLEWInitFailed;
            }
            break :blk RhiResult{ .rhi = try rhi_opengl.createRHI(allocator), .is_vulkan = false };
        };

        const rhi = rhi_and_type.rhi;
        const actual_is_vulkan = rhi_and_type.is_vulkan;

        try rhi.init(allocator);

        const shader: ?Shader = if (!actual_is_vulkan) try Shader.initFromFile(allocator, "assets/shaders/terrain.vert", "assets/shaders/terrain.frag") else null;

        var debug_shader: ?Shader = null;
        var debug_quad_vao: c.GLuint = 0;
        var debug_quad_vbo: c.GLuint = 0;

        if (!actual_is_vulkan) {
            const debug_vs = "#version 330 core\nlayout (location = 0) in vec2 aPos;layout (location = 1) in vec2 aTexCoord;out vec2 vTexCoord;void main() {gl_Position = vec4(aPos, 0.0, 1.0);vTexCoord = aTexCoord;}";
            const debug_fs = "#version 330 core\nout vec4 FragColor;in vec2 vTexCoord;uniform sampler2D uDepthMap;void main() {float depth = texture(uDepthMap, vTexCoord).r;FragColor = vec4(vec3(depth), 1.0);}";
            debug_shader = try Shader.initSimple(debug_vs, debug_fs);
            const quad_vertices = [_]f32{ -1.0, 1.0, 0.0, 1.0, -1.0, -1.0, 0.0, 0.0, 1.0, -1.0, 1.0, 0.0, -1.0, 1.0, 0.0, 1.0, 1.0, -1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0 };
            c.glGenVertexArrays().?(1, &debug_quad_vao);
            c.glGenBuffers().?(1, &debug_quad_vbo);
            c.glBindVertexArray().?(debug_quad_vao);
            c.glBindBuffer().?(c.GL_ARRAY_BUFFER, debug_quad_vbo);
            c.glBufferData().?(c.GL_ARRAY_BUFFER, quad_vertices.len * @sizeOf(f32), &quad_vertices, c.GL_STATIC_DRAW);
            c.glEnableVertexAttribArray().?(0);
            c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
            c.glEnableVertexAttribArray().?(1);
            c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        }

        const atlas = TextureAtlas.init(allocator, rhi);
        const atmosphere = if (actual_is_vulkan) Atmosphere.initNoGL() else Atmosphere.init();
        const clouds = if (actual_is_vulkan) Clouds.initNoGL() else try Clouds.init();
        const shadow_map = if (!actual_is_vulkan) ShadowMap.init(rhi, settings.shadow_resolution) catch null else null;

        return RenderSystem{
            .allocator = allocator,
            .rhi = rhi,
            .is_vulkan = actual_is_vulkan,
            .shader = shader,
            .debug_shader = debug_shader,
            .debug_quad_vao = debug_quad_vao,
            .debug_quad_vbo = debug_quad_vbo,
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
        if (self.debug_shader) |*s| s.deinit();
        if (!self.is_vulkan) {
            if (self.debug_quad_vao != 0) c.glDeleteVertexArrays().?(1, &self.debug_quad_vao);
            if (self.debug_quad_vbo != 0) c.glDeleteBuffers().?(1, &self.debug_quad_vbo);
        }
        if (self.shader) |*s| s.deinit();
        self.rhi.deinit();
    }
};
