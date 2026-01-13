const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");

const log = @import("../engine/core/log.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const Camera = @import("../engine/graphics/camera.zig").Camera;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Color = @import("../engine/ui/ui_system.zig").Color;
const Font = @import("../engine/ui/font.zig");
const Widgets = @import("../engine/ui/widgets.zig");
const MapController = @import("map_controller.zig").MapController;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const worldToChunk = @import("../world/chunk.zig").worldToChunk;
const WorldMap = @import("../world/worldgen/world_map.zig").WorldMap;
const region_pkg = @import("../world/worldgen/region.zig");
const LODConfig = @import("../world/lod_chunk.zig").LODConfig;
const CSM = @import("../engine/graphics/csm.zig");

const World = @import("../world/world.zig").World;
const GameSession = @import("session.zig").GameSession;
const AtmosphereState = @import("session.zig").AtmosphereState;
const CloudState = @import("session.zig").CloudState;
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

const AppState = @import("state.zig").AppState;
const Settings = @import("state.zig").Settings;
const Menus = @import("menus.zig");
const InputSettings = @import("input_settings.zig").InputSettings;

// Player physics and interaction
const Player = @import("player.zig").Player;
const Inventory = @import("inventory.zig").Inventory;
const hotbar = @import("ui/hotbar.zig");
const inventory_ui = @import("ui/inventory_ui.zig");
const BlockOutline = @import("block_outline.zig").BlockOutline;
const HandRenderer = @import("hand_renderer.zig").HandRenderer;

const debug_build = builtin.mode == .Debug;

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,

    rhi: RHI,
    shader: rhi_pkg.ShaderHandle = rhi_pkg.InvalidShaderHandle,
    resource_pack_manager: ResourcePackManager,
    atlas: TextureAtlas,
    env_map: ?@import("../engine/graphics/texture.zig").Texture,
    render_graph: RenderGraph,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
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
    camera: Camera,

    ui: ?UISystem,

    app_state: AppState,
    last_state: AppState,
    pending_world_cleanup: bool,
    pending_new_world_seed: ?u64,
    seed_input: std.ArrayListUnmanaged(u8),
    seed_focused: bool,

    game_session: ?*GameSession,

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

        const camera = Camera.init(.{
            .position = Vec3.init(8, 100, 8),
            .pitch = -0.3,
            .move_speed = 50.0,
        });

        const ui = try UISystem.init(rhi, input.window_width, input.window_height);

        // Load custom bindings
        var input_settings = InputSettings.load(allocator);
        defer input_settings.deinit();

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
            .input_mapper = input_settings.input_mapper,
            .time = time,
            .camera = camera,
            .ui = ui,
            .app_state = .home,
            .last_state = .home,
            .pending_world_cleanup = false,
            .pending_new_world_seed = null,
            .seed_input = std.ArrayListUnmanaged(u8).empty,
            .seed_focused = false,
            .game_session = null,
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

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.game_session) |session| session.deinit();
        self.seed_input.deinit(self.allocator);

        if (self.ui) |*u| u.deinit();

        self.render_graph.deinit();
        self.atmosphere_system.deinit();
        self.material_system.deinit();
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

    pub fn saveAllSettings(self: *const App) void {
        self.settings.save(self.allocator);
        var input_settings = InputSettings.init(self.allocator);
        defer input_settings.deinit();
        input_settings.input_mapper = self.input_mapper;
        input_settings.save() catch |err| {
            log.log.err("Failed to save input settings: {}", .{err});
        };
    }

    fn handleUiBack(self: *App) void {
        var handled = false;
        if (self.game_session) |session| {
            if (session.map_controller.show_map) {
                session.map_controller.show_map = false;
                if (self.app_state == .world) self.input.setMouseCapture(self.window_manager.window, true);
                handled = true;
            }
        }

        if (!handled) {
            switch (self.app_state) {
                .home => self.input.should_quit = true,
                .singleplayer => {
                    self.app_state = .home;
                    self.seed_focused = false;
                },
                .settings => self.app_state = self.last_state,
                .graphics => self.app_state = .settings,
                .resource_packs => {
                    self.saveAllSettings();
                    self.app_state = self.last_state;
                },
                .environment => {
                    self.saveAllSettings();
                    self.app_state = self.last_state;
                },
                .world => {
                    self.app_state = .paused;
                    self.input.setMouseCapture(self.window_manager.window, false);
                },
                .paused => {
                    self.app_state = .world;
                    self.input.setMouseCapture(self.window_manager.window, true);
                },
            }
        }
    }

    pub fn runSingleFrame(self: *App) !void {
        self.rhi.setViewport(self.input.window_width, self.input.window_height);

        if (self.pending_world_cleanup or self.pending_new_world_seed != null) {
            self.rhi.waitIdle();
            if (self.game_session) |session| {
                session.deinit();
                self.game_session = null;
            }
            self.pending_world_cleanup = false;
        }

        if (self.pending_new_world_seed) |seed| {
            self.pending_new_world_seed = null;
            self.game_session = GameSession.init(self.allocator, self.rhi, seed, self.settings.render_distance, self.settings.lod_enabled) catch |err| {
                log.log.err("Failed to create game session: {}", .{err});
                self.app_state = .home;
                return;
            };
            self.camera = self.game_session.?.camera;
        }

        self.time.update();

        const in_world = self.app_state == .world;
        const in_pause = self.app_state == .paused;

        self.input.beginFrame();
        self.input.pollEvents();
        self.rhi.setViewport(self.input.window_width, self.input.window_height);
        if (self.ui) |*u| u.resize(self.input.window_width, self.input.window_height);
        const screen_w: f32 = @floatFromInt(self.input.window_width);
        const screen_h: f32 = @floatFromInt(self.input.window_height);
        const mouse_pos = self.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = self.input.isMouseButtonPressed(.left);

        if (self.input_mapper.isActionPressed(&self.input, .ui_back)) {
            self.handleUiBack();
        }

        if (in_world or in_pause) {
            if (self.game_session) |session| {
                if (in_world and self.input_mapper.isActionPressed(&self.input, .tab_menu)) self.input.setMouseCapture(self.window_manager.window, !self.input.mouse_captured);
                if (self.input_mapper.isActionPressed(&self.input, .toggle_wireframe)) {
                    self.settings.wireframe_enabled = !self.settings.wireframe_enabled;
                    self.rhi.setWireframe(self.settings.wireframe_enabled);
                }
                if (self.input_mapper.isActionPressed(&self.input, .toggle_textures)) {
                    self.settings.textures_enabled = !self.settings.textures_enabled;
                    self.rhi.setTexturesEnabled(self.settings.textures_enabled);
                }
                if (self.input_mapper.isActionPressed(&self.input, .toggle_vsync)) {
                    self.settings.vsync = !self.settings.vsync;
                    self.rhi.setVSync(self.settings.vsync);
                }

                // Update session (handles internal input, physics, etc.)
                try session.update(self.time.delta_time, self.time.elapsed, &self.input, &self.input_mapper, &self.atlas, self.window_manager.window, in_pause);
                self.camera = session.player.camera;

                if (session.world.render_distance != self.settings.render_distance) {
                    session.world.setRenderDistance(self.settings.render_distance);
                }
            } else self.app_state = .home;
        } else if (self.input.mouse_captured) self.input.setMouseCapture(self.window_manager.window, false);

        const clear_color = if ((in_world or in_pause) and self.game_session != null) self.game_session.?.atmosphere.fog_color else Vec3.init(0.07, 0.08, 0.1).toLinear();
        self.rhi.setClearColor(clear_color);
        self.rhi.beginFrame();

        if (in_world or in_pause) {
            if (self.game_session) |session| {
                const aspect = screen_w / screen_h;
                const view_proj_render = Mat4.perspectiveReverseZ(self.camera.fov, aspect, self.camera.near, self.camera.far).multiply(self.camera.getViewMatrixOriginCentered());
                const sky_params = rhi_pkg.SkyParams{
                    .cam_pos = self.camera.position,
                    .cam_forward = self.camera.forward,
                    .cam_right = self.camera.right,
                    .cam_up = self.camera.up,
                    .aspect = aspect,
                    .tan_half_fov = @tan(self.camera.fov / 2.0),
                    .sun_dir = session.atmosphere.sun_dir,
                    .sky_color = session.atmosphere.sky_color,
                    .horizon_color = session.atmosphere.horizon_color,
                    .sun_intensity = session.atmosphere.sun_intensity,
                    .moon_intensity = session.atmosphere.moon_intensity,
                    .time = session.atmosphere.time_of_day,
                };
                const cloud_params: rhi_pkg.CloudParams = blk: {
                    const p = session.clouds.getShadowParams();
                    break :blk .{
                        .cam_pos = self.camera.position,
                        .view_proj = view_proj_render,
                        .sun_dir = session.atmosphere.sun_dir,
                        .sun_intensity = session.atmosphere.sun_intensity,
                        .fog_color = session.atmosphere.fog_color,
                        .fog_density = session.atmosphere.fog_density,
                        .wind_offset_x = p.wind_offset_x,
                        .wind_offset_z = p.wind_offset_z,
                        .cloud_scale = p.cloud_scale,
                        .cloud_coverage = p.cloud_coverage,
                        .cloud_height = p.cloud_height,
                        .base_color = session.clouds.base_color,
                        .pbr_enabled = self.settings.pbr_enabled and self.atlas.has_pbr,
                        .shadow_samples = self.settings.shadow_pcf_samples,
                        .shadow_blend = self.settings.shadow_cascade_blend,
                        .cloud_shadows = self.settings.cloud_shadows_enabled,
                        .pbr_quality = self.settings.pbr_quality,
                        .exposure = self.settings.exposure,
                        .saturation = self.settings.saturation,
                        .volumetric_enabled = self.settings.volumetric_lighting_enabled,
                        .volumetric_density = self.settings.volumetric_density,
                        .volumetric_steps = self.settings.volumetric_steps,
                        .volumetric_scattering = self.settings.volumetric_scattering,
                        .ssao_enabled = self.settings.ssao_enabled,
                    };
                };

                self.rhi.updateGlobalUniforms(view_proj_render, self.camera.position, session.atmosphere.sun_dir, session.atmosphere.sun_color, session.atmosphere.time_of_day, session.atmosphere.fog_color, session.atmosphere.fog_density, session.atmosphere.fog_enabled, session.atmosphere.sun_intensity, session.atmosphere.ambient_intensity, self.settings.textures_enabled, cloud_params);

                const render_ctx = render_graph_pkg.SceneContext{
                    .rhi = self.rhi,
                    .world = session.world,
                    .camera = &self.camera,
                    .atmosphere_system = self.atmosphere_system,
                    .material_system = self.material_system,
                    .aspect = aspect,
                    .sky_params = sky_params,
                    .cloud_params = cloud_params,
                    .main_shader = self.shader,
                    .env_map_handle = if (self.env_map) |t| t.handle else 0,
                    .shadow_distance = self.settings.shadow_distance,
                    .shadow_resolution = self.settings.getShadowResolution(),
                    .ssao_enabled = self.settings.ssao_enabled,
                };
                self.render_graph.execute(render_ctx);

                if (session.player.target_block) |target| session.block_outline.draw(target.x, target.y, target.z, self.camera.position);
                session.hand_renderer.draw(self.camera.position, self.camera.yaw, self.camera.pitch);

                if (self.ui) |*u| {
                    u.begin();

                    if (in_pause) {
                        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
                        const pw: f32 = 300.0;
                        const ph: f32 = 48.0;
                        const px: f32 = (screen_w - pw) * 0.5;
                        var py: f32 = screen_h * 0.35;
                        Font.drawTextCentered(u, "PAUSED", screen_w * 0.5, py - 60.0, 3.0, Color.white);
                        if (Widgets.drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            self.app_state = .world;
                            self.input.setMouseCapture(self.window_manager.window, true);
                        }
                        py += ph + 16.0;
                        if (Widgets.drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            self.last_state = .paused;
                            self.app_state = .settings;
                        }
                        py += ph + 16.0;
                        if (Widgets.drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            self.app_state = .home;
                            self.pending_world_cleanup = true;
                        }
                    } else {
                        try session.drawHUD(u, self.resource_pack_manager.active_pack, self.time.fps, screen_w, screen_h, mouse_x, mouse_y, mouse_clicked);
                    }

                    u.end();
                }
            }
        } else if (self.ui) |*u| {
            u.begin();
            const ctx = Menus.MenuContext{ .ui = u, .input = &self.input, .input_mapper = &self.input_mapper, .screen_w = screen_w, .screen_h = screen_h, .time = &self.time, .allocator = self.allocator, .window_manager = &self.window_manager, .resource_pack_manager = &self.resource_pack_manager };
            switch (self.app_state) {
                .home => {
                    const action = Menus.drawHome(ctx, &self.app_state, &self.last_state, &self.seed_focused);
                    if (action == .quit) self.input.should_quit = true;
                },
                .settings => Menus.drawSettings(ctx, &self.app_state, &self.settings, self.last_state, self.rhi),
                .graphics => try Menus.drawGraphics(ctx, &self.app_state, &self.settings, self.last_state, self.rhi),
                .resource_packs => {
                    const prev_pack_ptr = self.settings.texture_pack.ptr;
                    try Menus.drawResourcePacks(ctx, &self.app_state, &self.settings, self.last_state);
                    if (prev_pack_ptr != self.settings.texture_pack.ptr) {
                        self.rhi.waitIdle();
                        self.atlas.deinit();
                        self.atlas = try TextureAtlas.init(self.allocator, self.rhi, &self.resource_pack_manager, self.settings.max_texture_resolution);
                        self.atlas.bind(1);
                        // Bind PBR textures if available
                        self.atlas.bindNormal(6);
                        self.atlas.bindRoughness(7);
                        self.atlas.bindDisplacement(8);
                    }
                },
                .environment => {
                    const prev_env_ptr = self.settings.environment_map.ptr;
                    try Menus.drawEnvironment(ctx, &self.app_state, &self.settings, self.last_state);
                    if (prev_env_ptr != self.settings.environment_map.ptr) {
                        self.rhi.waitIdle();
                        if (self.env_map) |*t| t.deinit();
                        self.env_map = null;

                        if (!std.mem.eql(u8, self.settings.environment_map, "default")) {
                            if (self.resource_pack_manager.loadImageFileFloat(self.settings.environment_map)) |tex_data| {
                                self.env_map = Texture.initFloat(self.rhi, tex_data.width, tex_data.height, tex_data.pixels);
                                self.env_map.?.bind(9);
                                log.log.info("Loaded Environment Map: {s}", .{self.settings.environment_map});
                                var td = tex_data;
                                td.deinit(self.allocator);
                            } else {
                                log.log.warn("Could not load environment map: {s}", .{self.settings.environment_map});
                                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                                self.env_map = Texture.initFloat(self.rhi, 1, 1, &white_pixel);
                                self.env_map.?.bind(9);
                            }
                        } else {
                            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                            self.env_map = Texture.initFloat(self.rhi, 1, 1, &white_pixel);
                            self.env_map.?.bind(9);
                        }
                    }
                },
                .singleplayer => try Menus.drawSingleplayer(ctx, &self.app_state, &self.seed_input, &self.seed_focused, &self.pending_new_world_seed),
                .world, .paused => unreachable,
            }
            u.end();
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
