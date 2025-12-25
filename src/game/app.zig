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
const ShadowMap = @import("../engine/graphics/shadows.zig").ShadowMap;
const World = @import("../world/world.zig").World;
const worldToChunk = @import("../world/chunk.zig").worldToChunk;
const WorldMap = @import("../world/worldgen/world_map.zig").WorldMap;

const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
const rhi_opengl = @import("../engine/graphics/rhi_opengl.zig");
const rhi_vulkan = @import("../engine/graphics/rhi_vulkan.zig");
const Shader = @import("../engine/graphics/shader.zig").Shader;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;

const AppState = @import("state.zig").AppState;
const Settings = @import("state.zig").Settings;
const Menus = @import("menus.zig");

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
        const day_ambient: f32 = 0.30;
        const night_ambient: f32 = 0.08;
        self.ambient_intensity = std.math.lerp(night_ambient, day_ambient, self.sun_intensity);
    }

    fn updateColors(self: *AtmosphereState) void {
        const t = self.time_of_day;
        const DAWN_START: f32 = 0.20;
        const DAWN_END: f32 = 0.30;
        const DUSK_START: f32 = 0.70;
        const DUSK_END: f32 = 0.80;

        const day_sky = Vec3.init(0.4, 0.65, 1.0);
        const day_horizon = Vec3.init(0.7, 0.8, 0.95);
        const night_sky = Vec3.init(0.02, 0.02, 0.08);
        const night_horizon = Vec3.init(0.05, 0.05, 0.12);
        const dawn_sky = Vec3.init(0.4, 0.4, 0.6);
        const dawn_horizon = Vec3.init(1.0, 0.5, 0.3);
        const dusk_sky = Vec3.init(0.35, 0.25, 0.5);
        const dusk_horizon = Vec3.init(1.0, 0.4, 0.2);

        if (t < DAWN_START) {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
        } else if (t < DAWN_END) {
            const blend = smoothstep(DAWN_START, DAWN_END, t);
            self.sky_color = lerpVec3(night_sky, dawn_sky, blend);
            self.horizon_color = lerpVec3(night_horizon, dawn_horizon, blend);
        } else if (t < 0.35) {
            const blend = smoothstep(DAWN_END, 0.35, t);
            self.sky_color = lerpVec3(dawn_sky, day_sky, blend);
            self.horizon_color = lerpVec3(dawn_horizon, day_horizon, blend);
        } else if (t < DUSK_START) {
            self.sky_color = day_sky;
            self.horizon_color = day_horizon;
        } else if (t < 0.75) {
            const blend = smoothstep(DUSK_START, 0.75, t);
            self.sky_color = lerpVec3(day_sky, dusk_sky, blend);
            self.horizon_color = lerpVec3(day_horizon, dusk_horizon, blend);
        } else if (t < DUSK_END) {
            const blend = smoothstep(0.75, DUSK_END, t);
            self.sky_color = lerpVec3(dusk_sky, night_sky, blend);
            self.horizon_color = lerpVec3(dusk_horizon, night_horizon, blend);
        } else {
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
        }

        self.fog_color = self.horizon_color;
        self.fog_density = std.math.lerp(0.002, 0.0012, self.sun_intensity);
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
    enabled: bool = true,

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

const DebugState = packed struct {
    shadows: bool = false,
    cascade_idx: usize = 0,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,

    rhi: RHI,
    is_vulkan: bool,
    shader: ?Shader,
    atlas: TextureAtlas,
    atmosphere: AtmosphereState,
    clouds: CloudState,
    shadow_map: ?ShadowMap,

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

    debug_state: DebugState,

    pub fn init(allocator: std.mem.Allocator) !*App {
        var use_vulkan = false;
        {
            var args_iter = try std.process.argsWithAllocator(allocator);
            defer args_iter.deinit();
            _ = args_iter.skip();
            while (args_iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "--backend") and std.mem.eql(u8, args_iter.next() orelse "", "vulkan")) {
                    use_vulkan = true;
                    break;
                }
            }
        }

        const wm = try WindowManager.init(allocator, use_vulkan);

        log.log.info("Initializing engine systems...", .{});
        const settings = Settings{};
        var input = Input.init(allocator);
        input.window_width = 1280;
        input.window_height = 720;
        const time = Time.init();

        const RhiResult = struct {
            rhi: RHI,
            is_vulkan: bool,
        };

        const rhi_and_type = if (use_vulkan) blk: {
            log.log.info("Attempting to initialize Vulkan backend...", .{});
            const res = rhi_vulkan.createRHI(allocator, wm.window);
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
        var atmosphere = AtmosphereState{};
        atmosphere.setTimeOfDay(0.25);
        const clouds = CloudState{};
        const shadow_map = if (!actual_is_vulkan) blk: {
            const sm = ShadowMap.init(rhi, settings.shadow_resolution) catch |err| {
                log.log.warn("ShadowMap initialization failed: {}. Shadows disabled.", .{err});
                break :blk null;
            };
            break :blk sm;
        } else null;

        if (!actual_is_vulkan) rhi.setVSync(settings.vsync);

        const camera = Camera.init(.{
            .position = Vec3.init(8, 100, 8),
            .pitch = -0.3,
            .move_speed = 50.0,
        });

        const ui = try UISystem.init(rhi, 1280, 720);

        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .rhi = rhi,
            .is_vulkan = actual_is_vulkan,
            .shader = shader,
            .atlas = atlas,
            .atmosphere = atmosphere,
            .clouds = clouds,
            .shadow_map = shadow_map,
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
            .debug_state = .{},
        };

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.world_map) |*m| m.deinit();
        if (self.world) |w| w.deinit();
        self.seed_input.deinit(self.allocator);

        if (self.ui) |*u| u.deinit();

        if (self.shadow_map) |*sm| sm.deinit();
        self.atlas.deinit();
        if (self.shader) |*s| s.deinit();
        self.rhi.deinit();

        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        self.rhi.setViewport(1280, 720);
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
                self.world = World.init(self.allocator, self.settings.render_distance, seed, self.rhi) catch |err| {
                    log.log.err("Failed to create world: {}", .{err});
                    self.app_state = .home;
                    continue;
                };
                if (self.world_map == null) self.world_map = WorldMap.init(self.rhi, 256, 256);
                self.map_controller.show_map = false;
                self.map_controller.map_needs_update = true;
                self.camera = Camera.init(.{ .position = Vec3.init(8, 100, 8), .pitch = -0.3, .move_speed = 50.0 });
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
                if (self.input.isKeyPressed(.c)) {
                    self.clouds.enabled = !self.clouds.enabled;
                }
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
                if (debug_build and self.input.isKeyPressed(.u)) self.debug_state.shadows = !self.debug_state.shadows;

                self.map_controller.update(&self.input, &self.camera, self.time.delta_time, self.window_manager.window, screen_w, screen_h, if (self.world_map) |m| m.width else 256);

                if (debug_build and self.debug_state.shadows and self.input.isKeyPressed(.k)) self.debug_state.cascade_idx = (self.debug_state.cascade_idx + 1) % 3;

                if (self.input.isKeyPressed(.@"1")) self.atmosphere.setTimeOfDay(0.0);
                if (self.input.isKeyPressed(.@"2")) self.atmosphere.setTimeOfDay(0.25);
                if (self.input.isKeyPressed(.@"3")) self.atmosphere.setTimeOfDay(0.5);
                if (self.input.isKeyPressed(.@"4")) self.atmosphere.setTimeOfDay(0.75);
                if (self.input.isKeyPressed(.n)) {
                    self.atmosphere.time_scale = if (self.atmosphere.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
                }

                if (in_world) {
                    if (!self.map_controller.show_map and !in_pause) {
                        self.camera.update(&self.input, self.time.delta_time);
                    }

                    if (self.world) |active_world| {
                        if (active_world.render_distance != self.settings.render_distance) {
                            active_world.render_distance = self.settings.render_distance;
                        }

                        try active_world.update(self.camera.position);
                    } else self.app_state = .home;
                }
            } else if (self.input.mouse_captured) self.input.setMouseCapture(self.window_manager.window, false);

            const clear_color = if (in_world or in_pause) self.atmosphere.fog_color else Vec3.init(0.07, 0.08, 0.1);
            self.rhi.setClearColor(clear_color);
            self.rhi.beginFrame();

            if (in_world or in_pause) {
                if (self.world) |active_world| {
                    const aspect = screen_w / screen_h;
                    const view_proj_cull = self.camera.getViewProjectionMatrixOriginCentered(aspect);
                    const view_proj_render = if (self.is_vulkan)
                        Mat4.perspectiveReverseZ(self.camera.fov, aspect, self.camera.near, self.camera.far).multiply(self.camera.getViewMatrixOriginCentered())
                    else
                        view_proj_cull;
                    if (self.shadow_map) |*sm| {
                        var light_dir = self.atmosphere.sun_dir;
                        if (self.atmosphere.sun_intensity < 0.05 and self.atmosphere.moon_intensity > 0.05) light_dir = self.atmosphere.moon_dir;
                        if (self.atmosphere.sun_intensity > 0.05 or self.atmosphere.moon_intensity > 0.05) {
                            sm.update(self.camera.fov, aspect, 0.1, self.settings.shadow_distance, light_dir, self.camera.position, self.camera.getViewMatrixOriginCentered());
                            for (0..3) |i| {
                                sm.begin(i);
                                active_world.renderShadowPass(sm.light_space_matrices[i], self.camera.position);
                            }
                            sm.end(self.input.window_width, self.input.window_height);
                        }
                    }
                    self.rhi.beginMainPass();
                    self.rhi.drawSky(.{
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
                    });
                    if (self.shader) |*s| {
                        s.use();
                        self.atlas.bind(0);
                        if (self.shadow_map) |*sm| {
                            var shadow_map_handles: [3]rhi_pkg.TextureHandle = undefined;
                            for (0..3) |i| {
                                shadow_map_handles[i] = sm.depth_maps[i].handle;
                            }
                            self.rhi.setTextureUniforms(self.settings.textures_enabled, shadow_map_handles);
                            self.rhi.updateShadowUniforms(.{
                                .light_space_matrices = sm.light_space_matrices,
                                .cascade_splits = sm.cascade_splits,
                                .shadow_texel_sizes = sm.texel_sizes,
                            });
                        } else {
                            self.rhi.setTextureUniforms(self.settings.textures_enabled, [_]rhi_pkg.TextureHandle{ 0, 0, 0 });
                        }
                        const cp: rhi_pkg.CloudParams = blk: {
                            const p = self.clouds.getShadowParams();
                            break :blk .{
                                .cam_pos = self.camera.position,
                                .view_proj = view_proj_cull,
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
                            };
                        };
                        self.rhi.updateGlobalUniforms(view_proj_cull, self.camera.position, self.atmosphere.sun_dir, self.atmosphere.time_of_day, self.atmosphere.fog_color, self.atmosphere.fog_density, self.atmosphere.fog_enabled, self.atmosphere.sun_intensity, self.atmosphere.ambient_intensity, self.settings.textures_enabled, cp);
                        active_world.render(view_proj_cull, self.camera.position);
                    } else if (self.is_vulkan) {
                        const sun_dir = self.atmosphere.sun_dir;
                        const time_val = self.atmosphere.time_of_day;
                        const fog_color = self.atmosphere.fog_color;
                        const fog_density = self.atmosphere.fog_density;
                        const fog_enabled = self.atmosphere.fog_enabled;
                        const sun_intensity_val = self.atmosphere.sun_intensity;
                        const moon_intensity_val = self.atmosphere.moon_intensity;
                        const ambient_val = self.atmosphere.ambient_intensity;
                        const sky_color = self.atmosphere.sky_color;
                        const horizon_color = self.atmosphere.horizon_color;

                        var light_dir = sun_dir;
                        var light_active = true;
                        if (self.atmosphere.sun_intensity < 0.05 and self.atmosphere.moon_intensity > 0.05) {
                            light_dir = self.atmosphere.moon_dir;
                        }
                        light_active = self.atmosphere.sun_intensity > 0.05 or self.atmosphere.moon_intensity > 0.05;

                        if (light_active) {
                            const cascades = ShadowMap.computeCascades(self.settings.shadow_resolution, self.camera.fov, aspect, 0.1, self.settings.shadow_distance, light_dir, self.camera.getViewMatrixOriginCentered(), true);
                            self.rhi.updateShadowUniforms(.{
                                .light_space_matrices = cascades.light_space_matrices,
                                .cascade_splits = cascades.cascade_splits,
                                .shadow_texel_sizes = cascades.texel_sizes,
                            });
                            for (0..ShadowMap.CASCADE_COUNT) |i| {
                                self.rhi.beginShadowPass(@intCast(i));
                                self.rhi.updateGlobalUniforms(cascades.light_space_matrices[i], self.camera.position, light_dir, time_val, fog_color, fog_density, false, 0.0, 0.0, false, .{});
                                active_world.renderShadowPass(cascades.light_space_matrices[i], self.camera.position);
                                self.rhi.endShadowPass();
                            }
                        }

                        self.rhi.beginMainPass();
                        self.rhi.drawSky(.{
                            .cam_pos = self.camera.position,
                            .cam_forward = self.camera.forward,
                            .cam_right = self.camera.right,
                            .cam_up = self.camera.up,
                            .aspect = aspect,
                            .tan_half_fov = @tan(self.camera.fov / 2.0),
                            .sun_dir = sun_dir,
                            .sky_color = sky_color,
                            .horizon_color = horizon_color,
                            .sun_intensity = sun_intensity_val,
                            .moon_intensity = moon_intensity_val,
                            .time = time_val,
                        });

                        self.atlas.bind(0);
                        self.rhi.setTextureUniforms(self.settings.textures_enabled, [_]rhi_pkg.TextureHandle{ 0, 0, 0 });
                        const cp: rhi_pkg.CloudParams = blk: {
                            const p = self.clouds.getShadowParams();
                            break :blk .{
                                .cam_pos = self.camera.position,
                                .view_proj = view_proj_render,
                                .sun_dir = sun_dir,
                                .sun_intensity = sun_intensity_val,
                                .fog_color = fog_color,
                                .fog_density = fog_density,
                                .wind_offset_x = p.wind_offset_x,
                                .wind_offset_z = p.wind_offset_z,
                                .cloud_scale = p.cloud_scale,
                                .cloud_coverage = p.cloud_coverage,
                                .cloud_height = p.cloud_height,
                                .base_color = self.clouds.base_color,
                            };
                        };
                        self.rhi.updateGlobalUniforms(view_proj_render, self.camera.position, sun_dir, time_val, fog_color, fog_density, fog_enabled, sun_intensity_val, ambient_val, self.settings.textures_enabled, cp);
                        active_world.render(view_proj_cull, self.camera.position);
                    }

                    if (self.clouds.enabled) {
                        const p = self.clouds.getShadowParams();
                        self.rhi.drawClouds(.{
                            .cam_pos = self.camera.position,
                            .view_proj = view_proj_cull,
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
                        });
                    }
                    if (debug_build and !self.is_vulkan and self.debug_state.shadows and self.shadow_map != null) {
                        self.rhi.drawDebugShadowMap(self.debug_state.cascade_idx, self.shadow_map.?.depth_maps[self.debug_state.cascade_idx].handle);
                    }

                    if (self.ui) |*u| {
                        u.begin();
                        if (self.world_map) |*m| {
                            try self.map_controller.draw(u, screen_w, screen_h, m, &active_world.generator, self.camera.position);
                        }
                        if (debug_build) {
                            u.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                            Font.drawNumber(u, @intFromFloat(self.time.fps), 15, 15, Color.white);
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
                            var hr: i32 = 0;
                            var mn: i32 = 0;
                            var si: f32 = 1.0;
                            const h = self.atmosphere.getHours();
                            hr = @intFromFloat(h);
                            mn = @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0);
                            si = self.atmosphere.sun_intensity;
                            Font.drawText(u, "TIME:", 15, hy + 125, 1.5, Color.white);
                            Font.drawNumber(u, hr, 100, hy + 125, Color.white);
                            Font.drawText(u, ":", 125, hy + 125, 1.5, Color.white);
                            Font.drawNumber(u, mn, 140, hy + 125, Color.white);
                            Font.drawText(u, "SUN:", 15, hy + 145, 1.5, Color.white);
                            Font.drawNumber(u, @intFromFloat(si * 100.0), 100, hy + 145, Color.white);
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
                            }
                        }
                        u.end();
                    }
                }
            } else if (self.ui) |*u| {
                u.begin();
                const ctx = Menus.MenuContext{
                    .ui = u,
                    .input = &self.input,
                    .screen_w = screen_w,
                    .screen_h = screen_h,
                    .time = &self.time,
                    .allocator = self.allocator,
                };
                switch (self.app_state) {
                    .home => {
                        const action = Menus.drawHome(ctx, &self.app_state, &self.last_state, &self.seed_focused);
                        if (action == .quit) self.input.should_quit = true;
                    },
                    .settings => Menus.drawSettings(ctx, &self.app_state, &self.settings, self.last_state, self.rhi),
                    .singleplayer => try Menus.drawSingleplayer(ctx, &self.app_state, &self.seed_input, &self.seed_focused, &self.pending_new_world_seed),
                    .world, .paused => unreachable,
                }
                u.end();
            }

            self.rhi.endFrame();
            if (!self.is_vulkan) _ = c.SDL_GL_SwapWindow(self.window_manager.window);
            if (debug_build and in_world) {
                if (self.world) |active_world| {
                    if (self.time.frame_count % 120 == 0) {
                        const s = active_world.getStats();
                        const rs = active_world.getRenderStats();
                        std.debug.print("FPS: {d:.1} | Chunks: {}/{} (culled: {}) | Vertices: {} | Pos: ({d:.1}, {d:.1}, {d:.1})\n", .{ self.time.fps, rs.chunks_rendered, s.chunks_loaded, rs.chunks_culled, rs.vertices_rendered, self.camera.position.x, self.camera.position.y, self.camera.position.z });
                    }
                }
            }
        }
    }
};
