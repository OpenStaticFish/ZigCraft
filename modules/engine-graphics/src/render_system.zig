const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c").c;

const log = @import("engine-core").log;
const RenderDevice = @import("engine-rhi").RenderDevice;
const rhi_pkg = @import("engine-rhi").rhi;
const RHI = rhi_pkg.RHI;
const backend_dispatcher = @import("backend_dispatcher.zig");
const texture_atlas = @import("engine-assets").texture_atlas;
const TextureAtlas = texture_atlas.TextureAtlas;
const Texture = @import("engine-rhi").Texture;
const render_graph_pkg = @import("render_graph.zig");
const RenderGraph = render_graph_pkg.RenderGraph;
const ResourcePackManager = @import("engine-assets").ResourcePackManager;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const runtime_env = @import("engine-core").runtime_env;
const RenderFeatureFlags = @import("render_feature_flags.zig").RenderFeatureFlags;
const cloud_pkg = @import("engine-clouds").cloud_system;

pub const RenderSystem = struct {
    pub const Config = struct {
        shadow_resolution: u32,
        msaa_samples: u8,
        anisotropic_filtering: u8,
        texture_pack: []const u8,
        max_texture_resolution: u32,
        environment_map: []const u8,
        lpv_grid_size: u32,
        lpv_cell_size: f32,
        lpv_intensity: f32,
        lpv_propagation_iterations: u32,
        lpv_enabled: bool,
        clouds_enabled: bool,
        clouds_3d_enabled: bool,
        cloud_radius: u16,
        cloud_density: f32,
        cloud_height: f32,
        cloud_thickness: f32,
        cloud_speed_x: f32,
        cloud_speed_z: f32,
        taa_enabled: bool,
        bloom_enabled: bool,
        bloom_intensity: f32,
        fxaa_enabled: bool,
        block_textures: []const texture_atlas.BlockTextureDefinition,
        apply_to_rhi: ?*const fn (ctx: *const anyopaque, rhi: *RHI) void = null,
        apply_context: *const anyopaque,
    };

    allocator: Allocator,
    rhi: RHI,
    render_device: *RenderDevice,
    shader: rhi_pkg.ShaderHandle,
    resource_pack_manager: ResourcePackManager,
    atlas: TextureAtlas,
    env_map: ?Texture,
    render_graph: RenderGraph,
    cloud_system: *cloud_pkg.CloudSystem,
    shadow_passes: [4]render_graph_pkg.ShadowPass,
    g_pass: render_graph_pkg.GPass,
    ssao_pass: render_graph_pkg.SSAOPass,
    depth_pyramid_pass: render_graph_pkg.DepthPyramidPass,
    mesh_build_pass: render_graph_pkg.MeshBuildPass,
    sky_pass: render_graph_pkg.SkyPass,
    cloud_pass: render_graph_pkg.CloudPass,
    opaque_pass: render_graph_pkg.OpaquePass,
    entity_pass: render_graph_pkg.EntityPass,
    taa_pass: render_graph_pkg.TAAPass,
    bloom_pass: render_graph_pkg.BloomPass,
    post_process_pass: render_graph_pkg.PostProcessPass,
    fxaa_pass: render_graph_pkg.FXAAPass,
    water_reflection_pass: render_graph_pkg.WaterReflectionPass,
    water_pass: render_graph_pkg.WaterPass,
    safe_mode: bool,
    safe_render_mode: bool,

    pub fn init(allocator: Allocator, window: *c.SDL_Window, config: Config) !*RenderSystem {
        log.log.info("Initializing RenderSystem...", .{});

        const flags = RenderFeatureFlags.init();
        const safe_render_mode = flags.safe_render_mode;
        const safe_mode = flags.safe_mode;
        const disable_shadow_draw = flags.disable_shadow_draw;
        const disable_gpass_draw = flags.disable_gpass_draw;
        const disable_ssao = flags.disable_ssao;
        const disable_water = flags.disable_water;
        const disable_taa = flags.disable_taa;
        const disable_fxaa = flags.disable_fxaa;
        const disable_bloom = flags.disable_bloom;

        if (flags.chunk_debug_mode) {
            log.log.warn("CHUNK DEBUG MODE enabled: restore='{s}'", .{flags.chunk_debug_enable});
        }
        if (safe_render_mode) {
            log.log.warn("ZIGCRAFT_SAFE_RENDER enabled: skipping world rendering passes", .{});
        }
        if (!flags.safe_mode_explicit and runtime_env.strictSafeModeAutoEnabled()) {
            log.log.warn("Wayland direct-world launch detected: enabling strict ZIGCRAFT_SAFE_MODE defaults for stability. Set ZIGCRAFT_SAFE_MODE=0 to override", .{});
        } else if (!flags.safe_mode_explicit and safe_mode) {
            log.log.warn("Wayland session detected: enabling ZIGCRAFT_SAFE_MODE by default for stability. Set ZIGCRAFT_SAFE_MODE=0 to override", .{});
        }
        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: disabling depth pyramid and LPV compute passes", .{});
        }
        if (disable_shadow_draw) {
            log.log.warn("ZIGCRAFT_DISABLE_SHADOWS enabled", .{});
        }
        if (disable_gpass_draw) {
            log.log.warn("ZIGCRAFT_DISABLE_GPASS enabled", .{});
        }
        if (disable_ssao) {
            log.log.warn("ZIGCRAFT_DISABLE_SSAO enabled", .{});
        }
        if (disable_water) {
            log.log.warn("ZIGCRAFT_DISABLE_WATER enabled", .{});
        }
        if (disable_taa) {
            log.log.warn("ZIGCRAFT_DISABLE_TAA enabled", .{});
        }
        if (disable_fxaa) {
            log.log.warn("ZIGCRAFT_DISABLE_FXAA enabled", .{});
        }
        if (disable_bloom) {
            log.log.warn("ZIGCRAFT_DISABLE_BLOOM enabled", .{});
        }

        log.log.info("Initializing {s} backend...", .{@tagName(backend_dispatcher.BackendChoice.vulkan)});
        var rhi = try backend_dispatcher.createRHI(allocator, window, .vulkan, .{
            .shadow_resolution = config.shadow_resolution,
            .msaa_samples = config.msaa_samples,
            .anisotropic_filtering = config.anisotropic_filtering,
        });
        errdefer rhi.deinit();

        const render_device = try allocator.create(RenderDevice);
        errdefer allocator.destroy(render_device);
        render_device.* = try RenderDevice.init(allocator);
        errdefer render_device.deinit();

        log.log.info("RenderSystem.init: initializing RHI device", .{});
        try rhi.init(allocator, render_device);
        rhi.device = render_device;

        log.log.info("RenderSystem.init: scanning resource packs", .{});
        var resource_pack_manager = ResourcePackManager.init(allocator);
        errdefer resource_pack_manager.deinit();
        try resource_pack_manager.scanPacks();
        if (resource_pack_manager.packExists(config.texture_pack)) {
            try resource_pack_manager.setActivePack(config.texture_pack);
        } else if (resource_pack_manager.packExists("default")) {
            try resource_pack_manager.setActivePack("default");
        }

        log.log.info("RenderSystem.init: creating texture atlas (max_resolution={})", .{config.max_texture_resolution});
        const atlas = try TextureAtlas.init(allocator, rhi.resourceManager(), &resource_pack_manager, config.max_texture_resolution, config.block_textures);
        var atlas_mut = atlas;
        errdefer atlas_mut.deinit();

        var env_map: ?Texture = null;
        if (!std.mem.eql(u8, config.environment_map, "default")) {
            if (resource_pack_manager.loadImageFileFloat(config.environment_map)) |tex_data| {
                env_map = try Texture.initFloat(rhi.resourceManager(), tex_data.width, tex_data.height, tex_data.pixels);
                log.log.info("Loaded Environment Map: {s}", .{config.environment_map});
                var td = tex_data;
                td.deinit(allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{config.environment_map});
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                env_map = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
            }
        } else {
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            env_map = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
        }
        errdefer if (env_map) |*t| t.deinit();

        log.log.info("RenderSystem.init: initializing graph systems (LPV grid_size={}, cell_size={})", .{ config.lpv_grid_size, config.lpv_cell_size });
        var render_graph = try RenderGraph.init(allocator, rhi, .{
            .grid_size = config.lpv_grid_size,
            .cell_size = config.lpv_cell_size,
            .intensity = config.lpv_intensity,
            .propagation_iterations = config.lpv_propagation_iterations,
            .enabled = config.lpv_enabled,
        });
        var render_graph_owned = true;
        errdefer if (render_graph_owned) render_graph.deinit();

        const cloud_system = try cloud_pkg.CloudSystem.init(allocator, rhi.resourceManager(), .{
            .enabled = config.clouds_enabled,
            .enable_3d = config.clouds_3d_enabled,
            .radius = config.cloud_radius,
            .density = config.cloud_density,
            .height = config.cloud_height,
            .thickness = config.cloud_thickness,
            .speed_x = config.cloud_speed_x,
            .speed_z = config.cloud_speed_z,
        });
        errdefer cloud_system.deinit();

        const self = try allocator.create(RenderSystem);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .render_device = render_device,
            .shader = rhi_pkg.InvalidShaderHandle,
            .resource_pack_manager = resource_pack_manager,
            .atlas = atlas,
            .env_map = env_map,
            .render_graph = render_graph,
            .cloud_system = cloud_system,
            .shadow_passes = undefined,
            .g_pass = undefined,
            .ssao_pass = .{},
            .depth_pyramid_pass = .{},
            .mesh_build_pass = .{},
            .sky_pass = .{},
            .cloud_pass = .{},
            .opaque_pass = undefined,
            .entity_pass = .{},
            .taa_pass = .{ .enabled = !disable_taa },
            .bloom_pass = .{ .enabled = !disable_bloom and config.bloom_enabled },
            .post_process_pass = .{},
            .fxaa_pass = .{ .enabled = !disable_fxaa and config.fxaa_enabled },
            .water_reflection_pass = undefined,
            .water_pass = .{ .enabled = !disable_water },
            .safe_mode = safe_mode,
            .safe_render_mode = safe_render_mode,
        };
        render_graph_owned = false;
        errdefer self.render_graph.deinit();

        log.log.info("RenderSystem.init: initializing render graph materials", .{});
        try self.render_graph.initMaterials(&self.atlas);
        const material_system = self.render_graph.materials();
        self.shadow_passes = .{
            render_graph_pkg.ShadowPass.init(0, material_system),
            render_graph_pkg.ShadowPass.init(1, material_system),
            render_graph_pkg.ShadowPass.init(2, material_system),
            render_graph_pkg.ShadowPass.init(3, material_system),
        };
        if (disable_shadow_draw) {
            for (&self.shadow_passes) |*pass| pass.enabled = false;
        }
        self.g_pass = render_graph_pkg.GPass.init(material_system);
        self.g_pass.enabled = !disable_gpass_draw;
        self.ssao_pass.enabled = !disable_ssao;
        self.depth_pyramid_pass.enabled = !disable_gpass_draw;
        self.opaque_pass = render_graph_pkg.OpaquePass.init(material_system);
        self.water_reflection_pass = render_graph_pkg.WaterReflectionPass.init(material_system);
        self.water_reflection_pass.enabled = !disable_water;

        self.rhi.options().setFXAA((config.fxaa_enabled and !config.taa_enabled) and !disable_fxaa);
        self.rhi.options().setBloom(config.bloom_enabled and !disable_bloom);
        self.rhi.options().setBloomIntensity(config.bloom_intensity);

        if (config.apply_to_rhi) |apply_to_rhi| {
            apply_to_rhi(config.apply_context, &self.rhi);
        }

        if (!safe_render_mode) {
            if (self.shadow_passes[0].enabled) {
                try self.render_graph.addPass(self.shadow_passes[0].pass());
                try self.render_graph.addPass(self.shadow_passes[1].pass());
                try self.render_graph.addPass(self.shadow_passes[2].pass());
                try self.render_graph.addPass(self.shadow_passes[3].pass());
            }
            try self.render_graph.addPass(self.mesh_build_pass.pass());
            try self.render_graph.addPass(self.g_pass.pass());
            try self.render_graph.addPass(self.ssao_pass.pass());
            if (!safe_mode) {
                try self.render_graph.addPass(self.depth_pyramid_pass.pass());
            }
            if (self.water_reflection_pass.enabled) {
                try self.render_graph.addPass(self.water_reflection_pass.pass());
            }
            // Clouds share the non-blended terrain pipeline. Preserve their
            // order relative to opaque (including equal-depth ties), then fill
            // only uncovered samples with sky in the same main render pass.
            try self.render_graph.addPass(self.cloud_pass.pass());
            try self.render_graph.addPass(self.opaque_pass.pass());
            var late_sky_pass = self.sky_pass.pass();
            late_sky_pass.vtable = &.{
                .name = "SkyPass",
                .needs_main_pass = true,
                .execute = executeLateSky,
            };
            try self.render_graph.addPass(late_sky_pass);
            if (self.water_pass.enabled) {
                try self.render_graph.addPass(self.water_pass.pass());
            } else {
                log.log.warn("ZIGCRAFT_DISABLE_WATER enabled", .{});
            }
            try self.render_graph.addPass(self.entity_pass.pass());
            try self.render_graph.addPass(self.taa_pass.pass());
            try self.render_graph.addPass(self.bloom_pass.pass());
            try self.render_graph.addPass(self.post_process_pass.pass());
            try self.render_graph.addPass(self.fxaa_pass.pass());
        } else {
            log.log.warn("ZIGCRAFT_SAFE_RENDER: render graph disabled (UI only)", .{});
        }

        log.log.info("RenderSystem initialized successfully", .{});
        return self;
    }

    fn executeLateSky(ptr: *anyopaque, ctx: render_graph_pkg.SceneContext) anyerror!void {
        const sky: *render_graph_pkg.SkyPass = @ptrCast(@alignCast(ptr));
        // Sky binds a different pipeline after opaque; later overlays must not
        // reuse the cached terrain binding, even when water/clouds are disabled.
        defer ctx.render_ctx.setTerrainPipelineBound(false);
        try sky.pass().execute(ctx);
    }

    pub fn deinit(self: *RenderSystem) void {
        self.rhi.query().waitIdle();

        self.cloud_system.deinit();
        self.render_graph.deinit();
        self.atlas.deinit();
        if (self.env_map) |*t| t.deinit();
        self.resource_pack_manager.deinit();
        if (self.shader != rhi_pkg.InvalidShaderHandle) self.rhi.resourceManager().destroyShader(self.shader);
        self.rhi.deinit();
        self.render_device.deinit();
        self.allocator.destroy(self.render_device);

        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *RenderSystem) void {
        self.rhi.renderContext().beginFrame();
    }

    pub fn endFrame(self: *RenderSystem) void {
        self.rhi.renderContext().endFrame();
    }

    /// Discards the active frame without submitting it to the GPU.
    pub fn abortFrame(self: *RenderSystem) void {
        self.rhi.renderContext().abortFrame();
    }

    pub fn waitIdle(self: *RenderSystem) void {
        self.rhi.query().waitIdle();
    }

    pub fn setViewport(self: *RenderSystem, width: u32, height: u32) void {
        self.rhi.renderContext().setViewport(width, height);
    }

    pub fn updateGlobalUniforms(
        self: *RenderSystem,
        uniforms: rhi_pkg.GlobalUniforms,
        frame_params: rhi_pkg.FrameRenderParams,
    ) !void {
        try self.rhi.renderContext().updateGlobalUniforms(uniforms, frame_params);
    }

    pub fn applyConfig(self: *RenderSystem, config: Config) void {
        self.rhi.options().setFXAA(config.fxaa_enabled and !config.taa_enabled and self.fxaa_pass.enabled);
        self.rhi.options().setBloom(config.bloom_enabled and self.bloom_pass.enabled);
        self.rhi.options().setBloomIntensity(config.bloom_intensity);
        self.cloud_system.setConfig(.{
            .enabled = config.clouds_enabled,
            .enable_3d = config.clouds_3d_enabled,
            .radius = config.cloud_radius,
            .density = config.cloud_density,
            .height = config.cloud_height,
            .thickness = config.cloud_thickness,
            .speed_x = config.cloud_speed_x,
            .speed_z = config.cloud_speed_z,
        });
        if (config.apply_to_rhi) |apply_to_rhi| {
            apply_to_rhi(config.apply_context, &self.rhi);
        }
    }

    pub fn getRHI(self: *RenderSystem) *RHI {
        return &self.rhi;
    }

    pub fn getRenderGraph(self: *RenderSystem) *RenderGraph {
        return &self.render_graph;
    }

    pub fn getAtmosphereSystem(self: *RenderSystem) *render_graph_pkg.AtmosphereSystem {
        return self.render_graph.getAtmosphereSystem();
    }

    pub fn getLPVSystem(self: *RenderSystem) *render_graph_pkg.LPVSystem {
        return self.render_graph.getLPVSystem();
    }

    pub fn getCloudSystem(self: *RenderSystem) *cloud_pkg.CloudSystem {
        return self.cloud_system;
    }

    pub fn setCloudsEnabled(self: *RenderSystem, enabled: bool) void {
        var config = self.cloud_system.config;
        config.enabled = enabled;
        self.cloud_system.setConfig(config);
    }

    pub fn getAtlas(self: *RenderSystem) *TextureAtlas {
        return &self.atlas;
    }

    pub fn getEnvMapPtr(self: *RenderSystem) *?Texture {
        return &self.env_map;
    }

    pub fn getShader(self: *const RenderSystem) rhi_pkg.ShaderHandle {
        return self.shader;
    }

    pub fn setShader(self: *RenderSystem, handle: rhi_pkg.ShaderHandle) void {
        self.shader = handle;
    }

    pub fn getResourcePackManager(self: *RenderSystem) *ResourcePackManager {
        return &self.resource_pack_manager;
    }

    pub fn getSafeRenderMode(self: *const RenderSystem) bool {
        return self.safe_render_mode;
    }

    pub fn getSafeMode(self: *const RenderSystem) bool {
        return self.safe_mode;
    }

    pub fn getDisableShadowDraw(self: *const RenderSystem) bool {
        return !self.shadow_passes[0].enabled;
    }

    pub fn getDisableGPassDraw(self: *const RenderSystem) bool {
        return !self.g_pass.enabled;
    }

    pub fn getDisableSSAO(self: *const RenderSystem) bool {
        return !self.ssao_pass.enabled;
    }

    pub fn getCloudsEnabled(self: *const RenderSystem) bool {
        return self.cloud_system.config.enabled;
    }

    pub fn setDisableGPassDraw(self: *RenderSystem, value: bool) void {
        self.g_pass.enabled = !value;
    }

    pub fn setDisableSSAO(self: *RenderSystem, value: bool) void {
        self.ssao_pass.enabled = !value;
    }
};

test "late sky invalidates terrain binding after draw and skipped pipeline" {
    const Mock = struct {
        bound: bool = true,
        drew: bool = false,
        invalidated_after_draw: bool = false,
        skip: bool,

        fn drawSky(ptr: *anyopaque, _: rhi_pkg.SkyParams) rhi_pkg.RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.drew = true;
            if (self.skip) return error.SkyPipelineNotReady;
        }

        fn setBound(ptr: *anyopaque, bound: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.bound = bound;
            self.invalidated_after_draw = self.drew and !bound;
        }
    };
    var effects: rhi_pkg.IRenderEffectsContext.VTable = undefined;
    effects.drawSky = Mock.drawSky;
    var state: rhi_pkg.IRenderStateContext.VTable = undefined;
    state.setTerrainPipelineBound = Mock.setBound;
    var atmosphere = render_graph_pkg.AtmosphereSystem{ .allocator = std.testing.allocator };
    var sky = render_graph_pkg.SkyPass{};
    for ([_]bool{ false, true }) |skip| {
        var mock = Mock{ .skip = skip };
        var ctx: render_graph_pkg.SceneContext = undefined;
        ctx.render_ctx.effects = .{ .ptr = &mock, .vtable = &effects };
        ctx.render_ctx.state = .{ .ptr = &mock, .vtable = &state };
        ctx.atmosphere_system = &atmosphere;
        ctx.sky_params = std.mem.zeroes(rhi_pkg.SkyParams);
        try RenderSystem.executeLateSky(&sky, ctx);
        try std.testing.expect(mock.drew);
        try std.testing.expect(!mock.bound);
        try std.testing.expect(mock.invalidated_after_draw);
    }
}
