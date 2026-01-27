const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");
const build_options = @import("build_options");

const log = @import("../engine/core/log.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const InputMapper = @import("input_mapper.zig").InputMapper;
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const rhi_vulkan = @import("../engine/graphics/rhi_vulkan.zig");
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const Texture = @import("../engine/graphics/texture.zig").Texture;
const render_graph_pkg = @import("../engine/graphics/render_graph.zig");
const RenderGraph = render_graph_pkg.RenderGraph;
const AtmosphereSystem = @import("../engine/graphics/atmosphere_system.zig").AtmosphereSystem;
const MaterialSystem = @import("../engine/graphics/material_system.zig").MaterialSystem;
const ResourcePackManager = @import("../engine/graphics/resource_pack.zig").ResourcePackManager;
const AudioSystem = @import("../engine/audio/system.zig").AudioSystem;
const TimingOverlay = @import("../engine/ui/timing_overlay.zig").TimingOverlay;

const settings_pkg = @import("settings.zig");
const Settings = settings_pkg.Settings;
const InputSettings = @import("input_settings.zig").InputSettings;

const screen_pkg = @import("screen.zig");
const ScreenManager = screen_pkg.ScreenManager;
const EngineContext = screen_pkg.EngineContext;
const HomeScreen = @import("screens/home.zig").HomeScreen;
const WorldScreen = @import("screens/world.zig").WorldScreen;

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,

    rhi: RHI,
    shader: rhi_pkg.ShaderHandle = rhi_pkg.InvalidShaderHandle,
    resource_pack_manager: ResourcePackManager,
    atlas: TextureAtlas,
    env_map: ?Texture,
    render_graph: RenderGraph,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    audio_system: *AudioSystem,
    shadow_passes: [3]render_graph_pkg.ShadowPass,
    g_pass: render_graph_pkg.GPass,
    ssao_pass: render_graph_pkg.SSAOPass,
    sky_pass: render_graph_pkg.SkyPass,
    opaque_pass: render_graph_pkg.OpaquePass,
    cloud_pass: render_graph_pkg.CloudPass,
    entity_pass: render_graph_pkg.EntityPass,
    bloom_pass: render_graph_pkg.BloomPass,
    taa_pass: render_graph_pkg.TAAPass,
    post_process_pass: render_graph_pkg.PostProcessPass,
    fxaa_pass: render_graph_pkg.FXAAPass,

    settings: Settings,
    input: Input,
    input_mapper: InputMapper,
    time: Time,

    ui: ?UISystem,
    timing_overlay: TimingOverlay,

    screen_manager: ScreenManager,
    last_debug_toggle_time: f32 = 0,
    safe_render_mode: bool,
    skip_world_update: bool,
    skip_world_render: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,
    smoke_test_frames: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !*App {
        // Load settings first to get window resolution
        log.log.info("Initializing engine systems...", .{});
        settings_pkg.initPresets(allocator) catch |err| {
            log.log.warn("Failed to initialize presets: {}, proceeding with defaults", .{err});
        };
        // Clean up presets if init fails after this point
        errdefer settings_pkg.deinitPresets(allocator);

        const settings = settings_pkg.persistence.load(allocator);

        var wm = try WindowManager.init(allocator, true, settings.window_width, settings.window_height);
        errdefer wm.deinit();

        var input = Input.init(allocator);
        errdefer input.deinit();
        input.initWindowSize(wm.window);
        const time = Time.init();

        log.log.info("Initializing Vulkan backend...", .{});
        const rhi = try rhi_vulkan.createRHI(allocator, wm.window, null, settings.getShadowResolution(), settings.msaa_samples, settings.anisotropic_filtering);
        errdefer rhi.deinit();

        try rhi.init(allocator, null);

        var resource_pack_manager = ResourcePackManager.init(allocator);
        errdefer resource_pack_manager.deinit();
        try resource_pack_manager.scanPacks();
        if (resource_pack_manager.packExists(settings.texture_pack)) {
            try resource_pack_manager.setActivePack(settings.texture_pack);
        } else if (resource_pack_manager.packExists("default")) {
            try resource_pack_manager.setActivePack("default");
        }

        const safe_render_env = std.posix.getenv("ZIGCRAFT_SAFE_RENDER");
        const safe_render_mode = if (safe_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const skip_world_update_env = std.posix.getenv("ZIGCRAFT_SKIP_WORLD_UPDATE");
        const skip_world_update = safe_render_mode or if (skip_world_update_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const skip_world_render_env = std.posix.getenv("ZIGCRAFT_SKIP_WORLD_RENDER");
        const skip_world_render = safe_render_mode or if (skip_world_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_shadow_env = std.posix.getenv("ZIGCRAFT_DISABLE_SHADOWS");
        const disable_shadow_draw = if (disable_shadow_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_gpass_env = std.posix.getenv("ZIGCRAFT_DISABLE_GPASS");
        const disable_gpass_draw = if (disable_gpass_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_ssao_env = std.posix.getenv("ZIGCRAFT_DISABLE_SSAO");
        const disable_ssao = if (disable_ssao_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_clouds_env = std.posix.getenv("ZIGCRAFT_DISABLE_CLOUDS");
        const disable_clouds = if (disable_clouds_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (safe_render_mode) {
            log.log.warn("ZIGCRAFT_SAFE_RENDER enabled: skipping world rendering passes", .{});
        }
        if (skip_world_update and !safe_render_mode) {
            log.log.warn("ZIGCRAFT_SKIP_WORLD_UPDATE enabled", .{});
        }
        if (skip_world_render and !safe_render_mode) {
            log.log.warn("ZIGCRAFT_SKIP_WORLD_RENDER enabled", .{});
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
        if (disable_clouds) {
            log.log.warn("ZIGCRAFT_DISABLE_CLOUDS enabled", .{});
        }

        const atlas = try TextureAtlas.init(allocator, rhi, &resource_pack_manager, settings.max_texture_resolution);
        var atlas_mut = atlas;
        errdefer atlas_mut.deinit();
        atlas.bind(1);
        // Bind PBR textures if available
        atlas.bindNormal(6);
        atlas.bindRoughness(7);
        atlas.bindDisplacement(8);

        // Load EXR Environment Map
        var env_map: ?Texture = null;
        if (!std.mem.eql(u8, settings.environment_map, "default")) {
            if (resource_pack_manager.loadImageFileFloat(settings.environment_map)) |tex_data| {
                env_map = try Texture.initFloat(rhi, tex_data.width, tex_data.height, tex_data.pixels);
                env_map.?.bind(9);
                log.log.info("Loaded Environment Map: {s}", .{settings.environment_map});
                var td = tex_data;
                td.deinit(allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{settings.environment_map});
                // Fallback to white
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                env_map = try Texture.initFloat(rhi, 1, 1, &white_pixel);
                env_map.?.bind(9);
            }
        } else {
            // Default white
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            env_map = try Texture.initFloat(rhi, 1, 1, &white_pixel);
            env_map.?.bind(9);
        }
        errdefer if (env_map) |*t| t.deinit();

        const atmosphere_system = try AtmosphereSystem.init(allocator, rhi);
        errdefer atmosphere_system.deinit();
        const audio_system = try AudioSystem.init(allocator);
        errdefer audio_system.deinit();

        const ui = try UISystem.init(rhi, input.window_width, input.window_height);
        var ui_mut = ui;
        errdefer ui_mut.deinit();

        // Load custom bindings
        const input_mapper = InputSettings.loadAndReturnMapper(allocator);

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .rhi = rhi,
            .shader = rhi_pkg.InvalidShaderHandle,
            .resource_pack_manager = resource_pack_manager,
            .atlas = atlas,
            .env_map = env_map,
            .render_graph = RenderGraph.init(allocator),
            .atmosphere_system = atmosphere_system,
            .material_system = undefined,
            .audio_system = audio_system,
            .shadow_passes = .{
                render_graph_pkg.ShadowPass.init(0),
                render_graph_pkg.ShadowPass.init(1),
                render_graph_pkg.ShadowPass.init(2),
            },
            .g_pass = .{},
            .ssao_pass = .{},
            .sky_pass = .{},
            .opaque_pass = .{},
            .cloud_pass = .{},
            .entity_pass = .{},
            .bloom_pass = .{ .enabled = true },
            .taa_pass = .{ .enabled = true },
            .post_process_pass = .{},
            .fxaa_pass = .{ .enabled = true },
            .settings = settings,
            .input = input,
            .input_mapper = input_mapper,
            .time = time,
            .ui = ui,
            .timing_overlay = .{ .enabled = build_options.smoke_test },
            .screen_manager = ScreenManager.init(allocator),
            .safe_render_mode = safe_render_mode,
            .skip_world_update = skip_world_update,
            .skip_world_render = skip_world_render,
            .disable_shadow_draw = disable_shadow_draw,
            .disable_gpass_draw = disable_gpass_draw,
            .disable_ssao = disable_ssao,
            .disable_clouds = disable_clouds,
            .smoke_test_frames = 0,
        };
        errdefer app.screen_manager.deinit();
        errdefer app.render_graph.deinit();

        // EngineContext uses rhi as a pointer; App owns the instance.

        app.material_system = try MaterialSystem.init(allocator, rhi, &app.atlas);
        errdefer app.material_system.deinit();

        // Sync FXAA and Bloom settings to RHI after initialization
        app.rhi.setFXAA(settings.fxaa_enabled);
        app.rhi.setBloom(settings.bloom_enabled);
        app.rhi.setBloomIntensity(settings.bloom_intensity);

        // Apply all RHI settings (VSync, Wireframe, Textures, Debug Shadows, etc.)
        settings_pkg.apply_logic.applyToRHI(&settings, &app.rhi);

        if (build_options.smoke_test) {
            app.rhi.timing().setTimingEnabled(true);
        }

        // Build RenderGraph (OCP: We can easily modify this list based on quality)
        if (!safe_render_mode) {
            try app.render_graph.addPass(app.shadow_passes[0].pass());
            try app.render_graph.addPass(app.shadow_passes[1].pass());
            try app.render_graph.addPass(app.shadow_passes[2].pass());
            try app.render_graph.addPass(app.g_pass.pass());
            try app.render_graph.addPass(app.ssao_pass.pass());
            try app.render_graph.addPass(app.sky_pass.pass());
            try app.render_graph.addPass(app.opaque_pass.pass());
            try app.render_graph.addPass(app.cloud_pass.pass());
            try app.render_graph.addPass(app.entity_pass.pass());
            try app.render_graph.addPass(app.taa_pass.pass());
            try app.render_graph.addPass(app.bloom_pass.pass());
            try app.render_graph.addPass(app.post_process_pass.pass());
            try app.render_graph.addPass(app.fxaa_pass.pass());
        } else {
            log.log.warn("ZIGCRAFT_SAFE_RENDER: render graph disabled (UI only)", .{});
        }

        const engine_ctx = app.engineContext();
        if (build_options.smoke_test) {
            log.log.info("SMOKE TEST MODE: Bypassing menu and loading world", .{});
            const world_screen = try WorldScreen.init(allocator, engine_ctx, 12345, 0);
            app.screen_manager.setScreen(world_screen.screen());
        } else {
            const home_screen = try HomeScreen.init(allocator, engine_ctx);
            app.screen_manager.setScreen(home_screen.screen());
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.rhi.waitIdle();

        if (self.ui) |*u| u.deinit();

        self.screen_manager.deinit();

        self.render_graph.deinit();
        self.atmosphere_system.deinit();
        self.material_system.deinit();
        self.audio_system.deinit();
        self.atlas.deinit();
        if (self.env_map) |*t| t.deinit();
        self.resource_pack_manager.deinit();
        settings_pkg.persistence.deinit(&self.settings, self.allocator);
        settings_pkg.deinitPresets(self.allocator);
        if (self.shader != rhi_pkg.InvalidShaderHandle) self.rhi.destroyShader(self.shader);
        self.rhi.deinit();

        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn engineContext(self: *App) EngineContext {
        return .{
            .allocator = self.allocator,
            .window_manager = &self.window_manager,
            .rhi = &self.rhi,
            .resource_pack_manager = &self.resource_pack_manager,
            .atlas = &self.atlas,
            .render_graph = &self.render_graph,
            .atmosphere_system = self.atmosphere_system,
            .material_system = self.material_system,
            .audio_system = self.audio_system,
            .env_map_ptr = &self.env_map,
            .shader = self.shader,
            .settings = &self.settings,
            .input = &self.input,
            .input_mapper = &self.input_mapper,
            .time = &self.time,
            .screen_manager = &self.screen_manager,
            .safe_render_mode = self.safe_render_mode,
            .skip_world_update = self.skip_world_update,
            .skip_world_render = self.skip_world_render,
            .disable_shadow_draw = self.disable_shadow_draw,
            .disable_gpass_draw = self.disable_gpass_draw,
            .disable_ssao = self.disable_ssao,
            .disable_clouds = self.disable_clouds,
        };
    }

    pub fn saveAllSettings(self: *const App) void {
        settings_pkg.persistence.save(&self.settings, self.allocator);
        InputSettings.saveFromMapper(self.allocator, self.input_mapper) catch |err| {
            log.log.err("Failed to save input settings: {}", .{err});
        };
    }

    pub fn runSingleFrame(self: *App) !void {
        self.time.update();
        self.audio_system.update();

        self.input.beginFrame();
        self.input.pollEvents();

        if (self.input_mapper.isActionPressed(&self.input, .toggle_timing_overlay)) {
            const now = self.time.elapsed;
            if (now - self.last_debug_toggle_time > 0.2) {
                self.timing_overlay.toggle();
                self.rhi.timing().setTimingEnabled(self.timing_overlay.enabled);
                self.last_debug_toggle_time = now;
            }
        }

        if (self.ui) |*u| u.resize(self.input.window_width, self.input.window_height);

        self.rhi.setViewport(self.input.window_width, self.input.window_height);

        self.rhi.beginFrame();
        errdefer self.rhi.endFrame();

        // Ensure global uniforms are always updated with sane defaults even if no world is loaded.
        // This prevents black screen in menu due to zero exposure.
        // Call this AFTER beginFrame so it writes to the correct frame's buffer.
        self.rhi.updateGlobalUniforms(Mat4.identity, Vec3.zero, Vec3.init(0, -1, 0), Vec3.one, 0, Vec3.zero, 0, false, 1.0, 0.1, false, .{
            .cam_pos = Vec3.zero,
            .view_proj = Mat4.identity,
            .sun_dir = Vec3.init(0, -1, 0),
            .sun_intensity = 1.0,
            .fog_color = Vec3.zero,
            .fog_density = 0,
            .wind_offset_x = 0,
            .wind_offset_z = 0,
            .cloud_scale = 1.0,
            .cloud_coverage = 0.5,
            .cloud_height = 100,
            .base_color = Vec3.one,
            .pbr_enabled = false,
            .shadow = .{ .distance = 100, .resolution = 1024, .pcf_samples = 1, .cascade_blend = false },
            .cloud_shadows = false,
            .pbr_quality = 0,
            .exposure = 1.0,
            .saturation = 1.0,
            .volumetric_enabled = false,
            .volumetric_density = 0,
            .volumetric_steps = 0,
            .volumetric_scattering = 0,
            .ssao_enabled = false,
        });

        // Update current screen. Transitions happen here.
        try self.screen_manager.update(self.time.delta_time);

        // Early out if no screen is active (e.g. during transition or shutdown)
        if (self.screen_manager.stack.items.len == 0) {
            self.rhi.endFrame();
            return;
        }

        if (self.ui) |*u| {
            try self.screen_manager.draw(u);

            if (self.timing_overlay.enabled) {
                u.begin();
                const timing = self.rhi.timing();
                const results = timing.getTimingResults();
                self.timing_overlay.draw(u, results);
                u.end();
            }
        }

        self.rhi.endFrame();

        if (build_options.smoke_test) {
            self.smoke_test_frames += 1;
            var target_frames: u32 = 120;
            if (std.posix.getenv("ZIGCRAFT_SMOKE_FRAMES")) |val| {
                if (std.fmt.parseInt(u32, val, 10)) |parsed| {
                    target_frames = parsed;
                } else |_| {}
            }

            if (self.smoke_test_frames >= target_frames) {
                log.log.info("SMOKE TEST COMPLETE: {} frames rendered. Exiting.", .{target_frames});
                self.input.should_quit = true;
            }
        }
    }

    pub fn run(self: *App) !void {
        self.rhi.setViewport(self.input.window_width, self.input.window_height);
        log.log.info("=== ZigCraft ===", .{});
        while (!self.input.should_quit) {
            try self.runSingleFrame();
        }
    }
};
