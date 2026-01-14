const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");

const log = @import("../engine/core/log.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
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

const Settings = @import("state.zig").Settings;
const InputSettings = @import("input_settings.zig").InputSettings;

const screen_pkg = @import("screen.zig");
const ScreenManager = screen_pkg.ScreenManager;
const EngineContext = screen_pkg.EngineContext;
const HomeScreen = @import("screens/home.zig").HomeScreen;

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

    settings: Settings,
    input: Input,
    input_mapper: InputMapper,
    time: Time,

    ui: ?UISystem,

    screen_manager: ScreenManager,

    pub fn init(allocator: std.mem.Allocator) !*App {
        // Load settings first to get window resolution
        log.log.info("Initializing engine systems...", .{});
        const settings = Settings.load(allocator);

        const wm = try WindowManager.init(allocator, true, settings.window_width, settings.window_height);

        var input = Input.init(allocator);
        input.initWindowSize(wm.window);
        const time = Time.init();

        log.log.info("Initializing Vulkan backend...", .{});
        const rhi = try rhi_vulkan.createRHI(allocator, wm.window, null, settings.getShadowResolution(), settings.msaa_samples, settings.anisotropic_filtering);

        try rhi.init(allocator, null);

        var resource_pack_manager = ResourcePackManager.init(allocator);
        try resource_pack_manager.scanPacks();
        if (resource_pack_manager.packExists(settings.texture_pack)) {
            try resource_pack_manager.setActivePack(settings.texture_pack);
        } else if (resource_pack_manager.packExists("default")) {
            try resource_pack_manager.setActivePack("default");
        }

        const atlas = try TextureAtlas.init(allocator, rhi, &resource_pack_manager, settings.max_texture_resolution);
        atlas.bind(1);
        // Bind PBR textures if available
        atlas.bindNormal(6);
        atlas.bindRoughness(7);
        atlas.bindDisplacement(8);

        // Load EXR Environment Map
        var env_map: ?Texture = null;
        if (!std.mem.eql(u8, settings.environment_map, "default")) {
            if (resource_pack_manager.loadImageFileFloat(settings.environment_map)) |tex_data| {
                env_map = Texture.initFloat(rhi, tex_data.width, tex_data.height, tex_data.pixels);
                env_map.?.bind(9);
                log.log.info("Loaded Environment Map: {s}", .{settings.environment_map});
                var td = tex_data;
                td.deinit(allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{settings.environment_map});
                // Fallback to white
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                env_map = Texture.initFloat(rhi, 1, 1, &white_pixel);
                env_map.?.bind(9);
            }
        } else {
            // Default white
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            env_map = Texture.initFloat(rhi, 1, 1, &white_pixel);
            env_map.?.bind(9);
        }

        const atmosphere_system = try AtmosphereSystem.init(allocator, rhi);
        const audio_system = try AudioSystem.init(allocator);

        const ui = try UISystem.init(rhi, input.window_width, input.window_height);

        // Load custom bindings
        const input_mapper = InputSettings.loadAndReturnMapper(allocator);

        const app = try allocator.create(App);
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
            .settings = settings,
            .input = input,
            .input_mapper = input_mapper,
            .time = time,
            .ui = ui,
            .screen_manager = ScreenManager.init(allocator),
        };

        app.material_system = try MaterialSystem.init(allocator, rhi, &app.atlas);

        // Build RenderGraph (OCP: We can easily modify this list based on quality)
        try app.render_graph.addPass(app.shadow_passes[0].pass());
        try app.render_graph.addPass(app.shadow_passes[1].pass());
        try app.render_graph.addPass(app.shadow_passes[2].pass());
        try app.render_graph.addPass(app.g_pass.pass());
        try app.render_graph.addPass(app.ssao_pass.pass());
        try app.render_graph.addPass(app.sky_pass.pass());
        try app.render_graph.addPass(app.opaque_pass.pass());
        try app.render_graph.addPass(app.cloud_pass.pass());

        const engine_ctx = app.engineContext();
        const home_screen = try HomeScreen.init(allocator, engine_ctx);
        app.screen_manager.setScreen(home_screen.screen());

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.ui) |*u| u.deinit();

        self.screen_manager.deinit();

        self.render_graph.deinit();
        self.atmosphere_system.deinit();
        self.material_system.deinit();
        self.audio_system.deinit();
        self.atlas.deinit();
        if (self.env_map) |*t| t.deinit();
        self.resource_pack_manager.deinit();
        self.settings.deinit(self.allocator);
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
            .rhi = self.rhi,
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
        };
    }

    pub fn saveAllSettings(self: *const App) void {
        self.settings.save(self.allocator);
        InputSettings.saveFromMapper(self.allocator, self.input_mapper) catch |err| {
            log.log.err("Failed to save input settings: {}", .{err});
        };
    }

    pub fn runSingleFrame(self: *App) !void {
        self.time.update();
        self.audio_system.update();

        self.input.beginFrame();
        self.input.pollEvents();

        self.rhi.setViewport(self.input.window_width, self.input.window_height);
        if (self.ui) |*u| u.resize(self.input.window_width, self.input.window_height);

        // Update current screen. Transitions happen here.
        try self.screen_manager.update(self.time.delta_time);

        // Early out if no screen is active (e.g. during transition or shutdown)
        if (self.screen_manager.stack.items.len == 0) return;

        self.rhi.beginFrame();

        if (self.ui) |*u| {
            try self.screen_manager.draw(u);
        }

        self.rhi.endFrame();
    }

    pub fn run(self: *App) !void {
        self.rhi.setViewport(self.input.window_width, self.input.window_height);
        log.log.info("=== ZigCraft ===", .{});
        while (!self.input.should_quit) {
            try self.runSingleFrame();
        }
    }
};
