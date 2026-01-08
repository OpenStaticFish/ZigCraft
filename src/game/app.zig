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
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const rhi_vulkan = @import("../engine/graphics/rhi_vulkan.zig");
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const Texture = @import("../engine/graphics/texture.zig").Texture;
const RenderGraph = @import("../engine/graphics/render_graph.zig").RenderGraph;
const ResourcePackManager = @import("../engine/graphics/resource_pack.zig").ResourcePackManager;

const AppState = @import("state.zig").AppState;
const Settings = @import("state.zig").Settings;
const Menus = @import("menus.zig");

// Player physics and interaction
const Player = @import("player.zig").Player;
const Inventory = @import("inventory.zig").Inventory;
const hotbar = @import("ui/hotbar.zig");
const inventory_ui = @import("ui/inventory_ui.zig");
const BlockOutline = @import("block_outline.zig").BlockOutline;
const HandRenderer = @import("hand_renderer.zig").HandRenderer;

const debug_build = builtin.mode == .Debug;

const AtmosphereState = struct {
    world_ticks: u64 = 0,
    tick_accumulator: f32 = 0.0,
    time_scale: f32 = 1.0,
    time_of_day: f32 = 0.25,
    sun_intensity: f32 = 1.0,
    moon_intensity: f32 = 0.0,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    moon_dir: Vec3 = Vec3.init(0, -1, 0),
    sky_color: Vec3 = Vec3.init(0.5, 0.7, 1.0),
    horizon_color: Vec3 = Vec3.init(0.8, 0.85, 0.95),
    sun_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),
    fog_color: Vec3 = Vec3.init(0.6, 0.75, 0.95),
    ambient_intensity: f32 = 0.3,
    fog_density: f32 = 0.0015,
    fog_enabled: bool = true,
    orbit_tilt: f32 = 0.35,

    fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
        const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
        return Vec3.init(
            std.math.lerp(a.x, b.x, t),
            std.math.lerp(a.y, b.y, t),
            std.math.lerp(a.z, b.z, t),
        );
    }

    pub fn update(self: *AtmosphereState, delta_time: f32) void {
        self.tick_accumulator += delta_time * 20.0 * self.time_scale;
        if (self.tick_accumulator >= 1.0) {
            const ticks_delta: u64 = @intFromFloat(self.tick_accumulator);
            self.world_ticks +%= ticks_delta;
            self.tick_accumulator -= @floatFromInt(ticks_delta);
        }

        const day_ticks = self.world_ticks % 24000;
        self.time_of_day = @as(f32, @floatFromInt(day_ticks)) / 24000.0;

        self.updateCelestialBodies();
        self.updateIntensities();
        self.updateColors();
    }

    fn updateCelestialBodies(self: *AtmosphereState) void {
        const sun_angle = self.time_of_day * std.math.tau;
        const cos_angle = @cos(sun_angle);
        const sin_angle = @sin(sun_angle);
        const cos_tilt = @cos(self.orbit_tilt);
        const sin_tilt = @sin(self.orbit_tilt);

        self.sun_dir = Vec3.init(
            sin_angle,
            -cos_angle * cos_tilt,
            -cos_angle * sin_tilt,
        ).normalize();
        self.moon_dir = self.sun_dir.scale(-1);
    }

    fn updateIntensities(self: *AtmosphereState) void {
        const t = self.time_of_day;
        const DAWN_START: f32 = 0.20;
        const DAWN_END: f32 = 0.30;
        const DUSK_START: f32 = 0.70;
        const DUSK_END: f32 = 0.80;

        if (t < DAWN_START) {
            self.sun_intensity = 0;
        } else if (t < DAWN_END) {
            self.sun_intensity = smoothstep(DAWN_START, DAWN_END, t);
        } else if (t < DUSK_START) {
            self.sun_intensity = 1.0;
        } else if (t < DUSK_END) {
            self.sun_intensity = 1.0 - smoothstep(DUSK_START, DUSK_END, t);
        } else {
            self.sun_intensity = 0;
        }

        self.moon_intensity = (1.0 - self.sun_intensity) * 0.15;
        const day_ambient: f32 = 0.70;
        const night_ambient: f32 = 0.15;
        self.ambient_intensity = std.math.lerp(night_ambient, day_ambient, self.sun_intensity);
    }

    fn updateColors(self: *AtmosphereState) void {
        const t = self.time_of_day;
        const DAWN_START: f32 = 0.20;
        const DAWN_END: f32 = 0.30;
        const DUSK_START: f32 = 0.70;
        const DUSK_END: f32 = 0.80;

        const day_sky = Vec3.init(0.4, 0.65, 1.0).toLinear();
        const day_horizon = Vec3.init(0.7, 0.8, 0.95).toLinear();
        const night_sky = Vec3.init(0.02, 0.02, 0.08).toLinear();
        const night_horizon = Vec3.init(0.05, 0.05, 0.12).toLinear();
        const dawn_sky = Vec3.init(0.25, 0.3, 0.5).toLinear();
        const dawn_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear();
        const dusk_sky = Vec3.init(0.25, 0.3, 0.5).toLinear();
        const dusk_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear();

        const day_sun = Vec3.init(1.0, 0.95, 0.9).toLinear();
        const dawn_sun = Vec3.init(1.0, 0.85, 0.6).toLinear();
        const dusk_sun = Vec3.init(1.0, 0.85, 0.6).toLinear();
        const night_sun = Vec3.init(0.04, 0.04, 0.1).toLinear();

        if (t < DAWN_START) {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
            self.sun_color = night_sun;
        } else if (t < DAWN_END) {
            const blend = smoothstep(DAWN_START, DAWN_END, t);
            self.sky_color = lerpVec3(night_sky, dawn_sky, blend);
            self.horizon_color = lerpVec3(night_horizon, dawn_horizon, blend);
            self.sun_color = lerpVec3(night_sun, dawn_sun, blend);
        } else if (t < 0.35) {
            const blend = smoothstep(DAWN_END, 0.35, t);
            self.sky_color = lerpVec3(dawn_sky, day_sky, blend);
            self.horizon_color = lerpVec3(dawn_horizon, day_horizon, blend);
            self.sun_color = lerpVec3(dawn_sun, day_sun, blend);
        } else if (t < DUSK_START) {
            self.sky_color = day_sky;
            self.horizon_color = day_horizon;
            self.sun_color = day_sun;
        } else if (t < 0.75) {
            const blend = smoothstep(DUSK_START, 0.75, t);
            self.sky_color = lerpVec3(day_sky, dusk_sky, blend);
            self.horizon_color = lerpVec3(day_horizon, dusk_horizon, blend);
            self.sun_color = lerpVec3(day_sun, dusk_sun, blend);
        } else if (t < DUSK_END) {
            const blend = smoothstep(0.75, DUSK_END, t);
            self.sky_color = lerpVec3(dusk_sky, night_sky, blend);
            self.horizon_color = lerpVec3(dusk_horizon, night_horizon, blend);
            self.sun_color = lerpVec3(dusk_sun, night_sun, blend);
        } else {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
            self.sun_color = night_sun;
        }

        self.fog_color = self.horizon_color;
        self.fog_density = std.math.lerp(0.0015, 0.0008, self.sun_intensity);
    }

    pub fn setTimeOfDay(self: *AtmosphereState, time: f32) void {
        self.world_ticks = @intFromFloat(time * 24000.0);
        self.time_of_day = time;
        self.tick_accumulator = 0;
        self.updateCelestialBodies();
        self.updateIntensities();
        self.updateColors();
    }

    pub fn getHours(self: *const AtmosphereState) f32 {
        return self.time_of_day * 24.0;
    }

    pub fn getSkyLightFactor(self: *const AtmosphereState) f32 {
        return @max(self.sun_intensity, self.moon_intensity);
    }
};

const CloudState = struct {
    wind_offset_x: f32 = 0.0,
    wind_offset_z: f32 = 0.0,
    cloud_scale: f32 = 1.0 / 64.0,
    cloud_coverage: f32 = 0.5,
    cloud_height: f32 = 160.0,
    cloud_thickness: f32 = 12.0,
    base_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),

    pub fn update(self: *CloudState, delta_time: f32) void {
        const wind_dir_x: f32 = 1.0;
        const wind_dir_z: f32 = 0.2;
        const wind_speed: f32 = 2.0;
        self.wind_offset_x += wind_dir_x * wind_speed * delta_time;
        self.wind_offset_z += wind_dir_z * wind_speed * delta_time;
    }

    pub fn getShadowParams(self: *const CloudState) struct {
        wind_offset_x: f32,
        wind_offset_z: f32,
        cloud_scale: f32,
        cloud_coverage: f32,
        cloud_height: f32,
    } {
        return .{
            .wind_offset_x = self.wind_offset_x,
            .wind_offset_z = self.wind_offset_z,
            .cloud_scale = self.cloud_scale,
            .cloud_coverage = self.cloud_coverage,
            .cloud_height = self.cloud_height,
        };
    }
};

const DebugState = struct {
    shadows: bool = false,
    cascade_idx: usize = 0,
    show_fps: bool = false,
    show_block_info: bool = false,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,

    rhi: RHI,
    shader: rhi_pkg.ShaderHandle = rhi_pkg.InvalidShaderHandle,
    resource_pack_manager: ResourcePackManager,
    atlas: TextureAtlas,
    env_map: ?@import("../engine/graphics/texture.zig").Texture,
    render_graph: RenderGraph,
    atmosphere: AtmosphereState,
    clouds: CloudState,

    settings: Settings,
    input: Input,
    time: Time,
    camera: Camera,

    ui: ?UISystem,

    app_state: AppState,
    last_state: AppState,
    pending_world_cleanup: bool,
    pending_new_world_seed: ?u64,
    seed_input: std.ArrayListUnmanaged(u8),
    seed_focused: bool,

    world: ?*World,
    world_map: ?WorldMap,
    map_controller: MapController,

    // Player and inventory system
    player: ?Player,
    inventory: Inventory,
    inventory_ui_state: inventory_ui.InventoryUI,
    creative_mode: bool,
    block_outline: BlockOutline,
    hand_renderer: HandRenderer,

    debug_state: DebugState,

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

        var atmosphere = AtmosphereState{};
        atmosphere.setTimeOfDay(0.25);
        const clouds = CloudState{};
        const render_graph = RenderGraph.init(allocator);

        const camera = Camera.init(.{
            .position = Vec3.init(8, 100, 8),
            .pitch = -0.3,
            .move_speed = 50.0,
        });

        const ui = try UISystem.init(rhi, input.window_width, input.window_height);

        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .rhi = rhi,
            .shader = rhi_pkg.InvalidShaderHandle,
            .resource_pack_manager = resource_pack_manager,
            .atlas = atlas,
            .env_map = env_map,
            .render_graph = render_graph,
            .atmosphere = atmosphere,
            .clouds = clouds,
            .settings = settings,
            .input = input,
            .time = time,
            .camera = camera,
            .ui = ui,
            .app_state = .home,
            .last_state = .home,
            .pending_world_cleanup = false,
            .pending_new_world_seed = null,
            .seed_input = std.ArrayListUnmanaged(u8).empty,
            .seed_focused = false,
            .world = null,
            .world_map = null,
            .map_controller = .{},
            .player = null,
            .inventory = Inventory.init(),
            .inventory_ui_state = .{},
            .creative_mode = true, // Default to creative mode
            .block_outline = BlockOutline.init(rhi),
            .hand_renderer = HandRenderer.init(rhi),
            .debug_state = .{},
        };

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.world_map) |*m| m.deinit();
        if (self.world) |w| w.deinit();
        self.seed_input.deinit(self.allocator);

        if (self.ui) |*u| u.deinit();

        self.block_outline.deinit();
        self.hand_renderer.deinit();
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

    pub fn runSingleFrame(self: *App) !void {
        self.rhi.setViewport(self.input.window_width, self.input.window_height);

        if (self.pending_world_cleanup or self.pending_new_world_seed != null) {
            self.rhi.waitIdle();
            if (self.world) |w| {
                w.deinit();
                self.world = null;
            }
            self.pending_world_cleanup = false;
        }

        if (self.pending_new_world_seed) |seed| {
            self.pending_new_world_seed = null;
            const lod_config = LODConfig{
                .lod0_radius = self.settings.render_distance,
                .lod1_radius = 40,
                .lod2_radius = 80,
                .lod3_radius = 160,
            };
            if (self.settings.lod_enabled) {
                self.world = World.initWithLOD(self.allocator, self.settings.render_distance, seed, self.rhi, lod_config) catch |err| {
                    log.log.err("Failed to create world with LOD: {}", .{err});
                    self.app_state = .home;
                    return;
                };
            } else {
                self.world = World.init(self.allocator, self.settings.render_distance, seed, self.rhi) catch |err| {
                    log.log.err("Failed to create world: {}", .{err});
                    self.app_state = .home;
                    return;
                };
            }
            if (self.world_map == null) self.world_map = WorldMap.init(self.rhi, 256, 256);
            self.map_controller.show_map = false;
            self.map_controller.map_needs_update = true;
            self.player = Player.init(Vec3.init(8, 100, 8), self.creative_mode);
            self.camera = self.player.?.camera;
        }

        self.time.update();
        self.atmosphere.update(self.time.delta_time);
        self.clouds.update(self.time.delta_time);
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

        if (self.input.isKeyPressed(.escape)) {
            if (self.map_controller.show_map) {
                self.map_controller.show_map = false;
                if (self.app_state == .world) self.input.setMouseCapture(self.window_manager.window, true);
            } else {
                switch (self.app_state) {
                    .home => self.input.should_quit = true,
                    .singleplayer => {
                        self.app_state = .home;
                        self.seed_focused = false;
                    },
                    .settings => self.app_state = self.last_state,
                    .graphics => self.app_state = .settings,
                    .resource_packs => {
                        self.settings.save(self.allocator);
                        self.app_state = self.last_state;
                    },
                    .environment => {
                        self.settings.save(self.allocator);
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

        const in_world = self.app_state == .world;
        const in_pause = self.app_state == .paused;

        if (in_world or in_pause) {
            if (in_world and self.input.isKeyPressed(.tab)) self.input.setMouseCapture(self.window_manager.window, !self.input.mouse_captured);
            if (self.input.isKeyPressed(.f)) {
                self.settings.wireframe_enabled = !self.settings.wireframe_enabled;
                self.rhi.setWireframe(self.settings.wireframe_enabled);
            }
            if (self.input.isKeyPressed(.t)) {
                self.settings.textures_enabled = !self.settings.textures_enabled;
                self.rhi.setTexturesEnabled(self.settings.textures_enabled);
            }
            if (self.input.isKeyPressed(.v)) {
                self.settings.vsync = !self.settings.vsync;
                self.rhi.setVSync(self.settings.vsync);
            }
            if (self.input.isKeyPressed(.f2)) {
                self.debug_state.show_fps = !self.debug_state.show_fps;
            }
            if (self.input.isKeyPressed(.f5)) {
                self.debug_state.show_block_info = !self.debug_state.show_block_info;
            }
            if (debug_build and self.input.isKeyPressed(.u)) self.debug_state.shadows = !self.debug_state.shadows;

            self.map_controller.update(&self.input, &self.camera, self.time.delta_time, self.window_manager.window, screen_w, screen_h, if (self.world_map) |m| m.width else 256);

            if (debug_build and self.debug_state.shadows and self.input.isKeyPressed(.k)) self.debug_state.cascade_idx = (self.debug_state.cascade_idx + 1) % 3;

            if (self.input.isKeyPressed(.n)) {
                self.atmosphere.time_scale = if (self.atmosphere.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
            }

            if (self.input.isKeyPressed(.i)) {
                self.inventory_ui_state.toggle();
                self.input.setMouseCapture(self.window_manager.window, !self.inventory_ui_state.visible);
            }

            if (self.input.isKeyPressed(.f3)) {
                self.creative_mode = !self.creative_mode;
                if (self.player) |*p| {
                    p.setCreativeMode(self.creative_mode);
                }
            }

            if (!self.inventory_ui_state.visible) {
                if (self.input.isKeyPressed(.@"1")) self.inventory.selectSlot(0);
                if (self.input.isKeyPressed(.@"2")) self.inventory.selectSlot(1);
                if (self.input.isKeyPressed(.@"3")) self.inventory.selectSlot(2);
                if (self.input.isKeyPressed(.@"4")) self.inventory.selectSlot(3);
                if (self.input.isKeyPressed(.@"5")) self.inventory.selectSlot(4);
                if (self.input.isKeyPressed(.@"6")) self.inventory.selectSlot(5);
                if (self.input.isKeyPressed(.@"7")) self.inventory.selectSlot(6);
                if (self.input.isKeyPressed(.@"8")) self.inventory.selectSlot(7);
                if (self.input.isKeyPressed(.@"9")) self.inventory.selectSlot(8);
                if (self.input.scroll_y != 0) {
                    self.inventory.scrollSelection(@intFromFloat(self.input.scroll_y));
                }
            }

            if (in_world) {
                if (!self.map_controller.show_map and !in_pause and !self.inventory_ui_state.visible) {
                    if (self.player) |*p| {
                        if (self.world) |active_world| {
                            p.update(&self.input, active_world, self.time.delta_time, self.time.elapsed);
                            self.camera = p.camera;
                            if (self.input.isMouseButtonPressed(.left)) {
                                p.breakTargetBlock(active_world);
                                self.hand_renderer.swing();
                            }
                            if (self.input.isMouseButtonPressed(.right)) {
                                if (self.inventory.getSelectedBlock()) |block_type| {
                                    p.placeBlock(active_world, block_type);
                                    self.hand_renderer.swing();
                                }
                            }
                        }
                    } else {
                        self.camera.update(&self.input, self.time.delta_time);
                    }
                    self.hand_renderer.update(self.time.delta_time);
                    self.hand_renderer.updateMesh(self.inventory, &self.atlas);
                }

                if (self.world) |active_world| {
                    if (active_world.render_distance != self.settings.render_distance) {
                        active_world.setRenderDistance(self.settings.render_distance);
                    }
                    try active_world.update(self.camera.position, self.time.delta_time);
                } else self.app_state = .home;
            } else if (in_pause) {
                if (self.world) |active_world| {
                    if (active_world.render_distance != self.settings.render_distance) {
                        active_world.setRenderDistance(self.settings.render_distance);
                    }
                }
            }
        } else if (self.input.mouse_captured) self.input.setMouseCapture(self.window_manager.window, false);

        const clear_color = if (in_world or in_pause) self.atmosphere.fog_color else Vec3.init(0.07, 0.08, 0.1).toLinear();
        self.rhi.setClearColor(clear_color);
        self.rhi.beginFrame();

        if (in_world or in_pause) {
            if (self.world) |active_world| {
                const aspect = screen_w / screen_h;
                const view_proj_render = Mat4.perspectiveReverseZ(self.camera.fov, aspect, self.camera.near, self.camera.far).multiply(self.camera.getViewMatrixOriginCentered());
                const sky_params = rhi_pkg.SkyParams{
                    .cam_pos = self.camera.position,
                    .cam_forward = self.camera.forward,
                    .cam_right = self.camera.right,
                    .cam_up = self.camera.up,
                    .aspect = aspect,
                    .tan_half_fov = @tan(self.camera.fov / 2.0),
                    .sun_dir = self.atmosphere.sun_dir,
                    .sky_color = self.atmosphere.sky_color,
                    .horizon_color = self.atmosphere.horizon_color,
                    .sun_intensity = self.atmosphere.sun_intensity,
                    .moon_intensity = self.atmosphere.moon_intensity,
                    .time = self.atmosphere.time_of_day,
                };
                const cloud_params: rhi_pkg.CloudParams = blk: {
                    const p = self.clouds.getShadowParams();
                    break :blk .{
                        .cam_pos = self.camera.position,
                        .view_proj = view_proj_render,
                        .sun_dir = self.atmosphere.sun_dir,
                        .sun_intensity = self.atmosphere.sun_intensity,
                        .fog_color = self.atmosphere.fog_color,
                        .fog_density = self.atmosphere.fog_density,
                        .wind_offset_x = p.wind_offset_x,
                        .wind_offset_z = p.wind_offset_z,
                        .cloud_scale = p.cloud_scale,
                        .cloud_coverage = p.cloud_coverage,
                        .cloud_height = p.cloud_height,
                        .base_color = self.clouds.base_color,
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
                    };
                };

                const atlas_handles = rhi_pkg.TextureAtlasHandles{
                    .diffuse = self.atlas.texture.handle,
                    .normal = if (self.atlas.normal_texture) |t| t.handle else 0,
                    .roughness = if (self.atlas.roughness_texture) |t| t.handle else 0,
                    .displacement = if (self.atlas.displacement_texture) |t| t.handle else 0,
                    .env = if (self.env_map) |t| t.handle else 0,
                };

                self.rhi.updateGlobalUniforms(view_proj_render, self.camera.position, self.atmosphere.sun_dir, self.atmosphere.sun_color, self.atmosphere.time_of_day, self.atmosphere.fog_color, self.atmosphere.fog_density, self.atmosphere.fog_enabled, self.atmosphere.sun_intensity, self.atmosphere.ambient_intensity, self.settings.textures_enabled, cloud_params);
                self.render_graph.execute(self.rhi, active_world, &self.camera, aspect, sky_params, cloud_params, self.shader, atlas_handles, self.settings.shadow_distance, self.settings.getShadowResolution());

                if (self.player) |p| {
                    if (p.target_block) |target| self.block_outline.draw(target.x, target.y, target.z, self.camera.position);
                }
                self.hand_renderer.draw(self.camera.position, self.camera.yaw, self.camera.pitch);

                if (self.ui) |*u| {
                    u.begin();
                    if (self.world_map) |*m| {
                        try self.map_controller.draw(u, screen_w, screen_h, m, &active_world.generator, self.camera.position);
                    }
                    if (self.debug_state.show_fps) {
                        u.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                        Font.drawNumber(u, @intFromFloat(self.time.fps), 15, 15, Color.white);
                    }
                    if (debug_build) {
                        if (!self.debug_state.show_fps) {
                            u.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                            Font.drawNumber(u, @intFromFloat(self.time.fps), 15, 15, Color.white);
                        }
                        const stats = active_world.getStats();
                        const rs = active_world.getRenderStats();
                        const pc = worldToChunk(@intFromFloat(self.camera.position.x), @intFromFloat(self.camera.position.z));
                        const hy: f32 = 50.0;
                        u.drawRect(.{ .x = 10, .y = hy, .width = 220, .height = 170 }, Color.rgba(0, 0, 0, 0.6));
                        Font.drawText(u, "POS:", 15, hy + 5, 1.5, Color.white);
                        Font.drawNumber(u, pc.chunk_x, 120, hy + 5, Color.white);
                        Font.drawNumber(u, pc.chunk_z, 170, hy + 5, Color.white);
                        Font.drawText(u, "CHUNKS:", 15, hy + 25, 1.5, Color.white);
                        Font.drawNumber(u, @intCast(stats.chunks_loaded), 140, hy + 25, Color.white);
                        Font.drawText(u, "VISIBLE:", 15, hy + 45, 1.5, Color.white);
                        Font.drawNumber(u, @intCast(rs.chunks_rendered), 140, hy + 45, Color.white);
                        Font.drawText(u, "QUEUED GEN:", 15, hy + 65, 1.5, Color.white);
                        Font.drawNumber(u, @intCast(stats.gen_queue), 140, hy + 65, Color.white);
                        Font.drawText(u, "QUEUED MESH:", 15, hy + 85, 1.5, Color.white);
                        Font.drawNumber(u, @intCast(stats.mesh_queue), 140, hy + 85, Color.white);
                        Font.drawText(u, "PENDING UP:", 15, hy + 105, 1.5, Color.white);
                        Font.drawNumber(u, @intCast(stats.upload_queue), 140, hy + 105, Color.white);
                        const h = self.atmosphere.getHours();
                        const hr = @as(i32, @intFromFloat(h));
                        const mn = @as(i32, @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0));
                        Font.drawText(u, "TIME:", 15, hy + 125, 1.5, Color.white);
                        Font.drawNumber(u, hr, 100, hy + 125, Color.white);
                        Font.drawText(u, ":", 125, hy + 125, 1.5, Color.white);
                        Font.drawNumber(u, mn, 140, hy + 125, Color.white);
                        Font.drawText(u, "SUN:", 15, hy + 145, 1.5, Color.white);
                        Font.drawNumber(u, @intFromFloat(self.atmosphere.sun_intensity * 100.0), 100, hy + 145, Color.white);

                        if (self.world) |world| {
                            const px_i: i32 = @intFromFloat(self.camera.position.x);
                            const pz_i: i32 = @intFromFloat(self.camera.position.z);
                            const region = world.generator.getRegionInfo(px_i, pz_i);
                            const c3 = region_pkg.getRoleColor(region.role);
                            Font.drawText(u, "ROLE:", 15, hy + 165, 1.5, Color.rgba(c3[0], c3[1], c3[2], 1.0));
                            var buf: [32]u8 = undefined;
                            const label = std.fmt.bufPrint(&buf, "{s}", .{@tagName(region.role)}) catch "???";
                            Font.drawText(u, label, 100, hy + 165, 1.5, Color.white);
                        }
                    }

                    if (self.debug_state.show_block_info) {
                        if (self.player) |p| {
                            if (p.target_block) |target| {
                                if (self.world) |world| {
                                    const block = world.getBlock(target.x, target.y, target.z);
                                    const tiles = TextureAtlas.getTilesForBlock(@intFromEnum(block));
                                    const ux = screen_w - 350;
                                    var uy: f32 = 10;
                                    u.drawRect(.{ .x = ux - 10, .y = uy, .width = 350, .height = 80 }, Color.rgba(0, 0, 0, 0.7));
                                    var buf: [128]u8 = undefined;
                                    const pos_text = std.fmt.bufPrint(&buf, "BLOCK: {s} ({}, {}, {})", .{ @tagName(block), target.x, target.y, target.z }) catch "BLOCK: ???";
                                    Font.drawText(u, pos_text, ux, uy + 5, 1.5, Color.white);
                                    uy += 25;
                                    const tiles_text = std.fmt.bufPrint(&buf, "TILES: T:{} B:{} S:{}", .{ tiles.top, tiles.bottom, tiles.side }) catch "TILES: ???";
                                    Font.drawText(u, tiles_text, ux, uy + 5, 1.5, Color.white);
                                    uy += 25;
                                    const pack_name = if (self.resource_pack_manager.active_pack) |ap| ap else "Default";
                                    const pack_text = std.fmt.bufPrint(&buf, "PACK: {s}", .{pack_name}) catch "PACK: ???";
                                    Font.drawText(u, pack_text, ux, uy + 5, 1.5, Color.white);
                                }
                            }
                        }
                    }

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
                            self.player = null;
                        }
                    }

                    if (!in_pause and !self.inventory_ui_state.visible) {
                        const cx = screen_w / 2.0;
                        const cy = screen_h / 2.0;
                        u.drawRect(.{ .x = cx - 10, .y = cy - 1, .width = 20, .height = 2 }, Color.white);
                        u.drawRect(.{ .x = cx - 1, .y = cy - 10, .width = 2, .height = 20 }, Color.white);
                    }
                    if (!self.inventory_ui_state.visible) hotbar.drawDefault(u, &self.inventory, screen_w, screen_h);
                    if (self.inventory_ui_state.visible) {
                        const time_action = self.inventory_ui_state.draw(u, &self.inventory, mouse_x, mouse_y, mouse_clicked, screen_w, screen_h);
                        if (time_action) |time_idx| {
                            const times = [_]f32{ 0.0, 0.25, 0.5, 0.75 };
                            if (time_idx < 4) self.atmosphere.setTimeOfDay(times[time_idx]);
                        }
                    }
                    if (self.creative_mode) {
                        Font.drawText(u, "CREATIVE", screen_w - 100, 10, 1.5, Color.rgba(100, 200, 255, 200));
                        if (self.player) |p| if (p.fly_mode) Font.drawText(u, "FLYING", screen_w - 80, 25, 1.5, Color.rgba(150, 255, 150, 200));
                    }
                    u.end();
                }
            }
        } else if (self.ui) |*u| {
            u.begin();
            const ctx = Menus.MenuContext{ .ui = u, .input = &self.input, .screen_w = screen_w, .screen_h = screen_h, .time = &self.time, .allocator = self.allocator, .window_manager = &self.window_manager, .resource_pack_manager = &self.resource_pack_manager };
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
            if (self.pending_world_cleanup or self.pending_new_world_seed != null) {
                self.rhi.waitIdle();
                if (self.world) |w| {
                    w.deinit();
                    self.world = null;
                }
                self.pending_world_cleanup = false;
            }
            if (self.pending_new_world_seed) |seed| {
                self.pending_new_world_seed = null;
                const lod_config = LODConfig{ .lod0_radius = self.settings.render_distance, .lod1_radius = 40, .lod2_radius = 80, .lod3_radius = 160 };
                if (self.settings.lod_enabled) {
                    self.world = World.initWithLOD(self.allocator, self.settings.render_distance, seed, self.rhi, lod_config) catch |err| {
                        log.log.err("Failed to create world with LOD: {}", .{err});
                        self.app_state = .home;
                        continue;
                    };
                } else {
                    self.world = World.init(self.allocator, self.settings.render_distance, seed, self.rhi) catch |err| {
                        log.log.err("Failed to create world: {}", .{err});
                        self.app_state = .home;
                        continue;
                    };
                }
                if (self.world_map == null) self.world_map = WorldMap.init(self.rhi, 256, 256);
                self.map_controller.show_map = false;
                self.map_controller.map_needs_update = true;
                self.player = Player.init(Vec3.init(8, 100, 8), self.creative_mode);
                self.camera = self.player.?.camera;
            }
            try self.runSingleFrame();
        }
    }
};
