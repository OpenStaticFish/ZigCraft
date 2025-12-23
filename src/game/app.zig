const std = @import("std");
const c = @import("../c.zig").c;

// Engine imports
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Camera = @import("../engine/graphics/camera.zig").Camera;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Color = @import("../engine/ui/ui_system.zig").Color;
const log = @import("../engine/core/log.zig");
const ShadowMap = @import("../engine/graphics/shadows.zig").ShadowMap;
const Font = @import("../engine/ui/font.zig");
const Widgets = @import("../engine/ui/widgets.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;

// World imports
const World = @import("../world/world.zig").World;
const worldToChunk = @import("../world/chunk.zig").worldToChunk;
const WorldMap = @import("../world/worldgen/world_map.zig").WorldMap;

const rhi_pkg = @import("../engine/graphics/rhi.zig");

// Game imports
const AppState = @import("state.zig").AppState;
const Settings = @import("state.zig").Settings;
const Menus = @import("menus.zig");
const RenderSystem = @import("render_system.zig").RenderSystem;

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,
    render_system: RenderSystem,

    settings: Settings,
    input: Input,
    time: Time,
    camera: Camera,

    ui: ?UISystem,

    app_state: AppState,
    last_state: AppState,
    pending_world_cleanup: bool,
    pending_new_world_seed: ?u64,
    debug_shadows: bool,
    debug_cascade_idx: usize,
    seed_input: std.ArrayListUnmanaged(u8),
    seed_focused: bool,

    world: ?*World,
    world_map: ?WorldMap,
    show_map: bool,
    map_needs_update: bool,
    map_zoom: f32,
    map_target_zoom: f32,
    map_pos_x: f32,
    map_pos_z: f32,
    last_mouse_x: f32,
    last_mouse_y: f32,

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

        const rs = try RenderSystem.init(allocator, wm.window, wm.is_vulkan, &settings);
        if (!rs.is_vulkan) rs.rhi.setVSync(settings.vsync);

        const camera = Camera.init(.{
            .position = Vec3.init(8, 100, 8),
            .pitch = -0.3,
            .move_speed = 50.0,
        });

        const ui = try UISystem.init(rs.rhi, 1280, 720);

        const app = try allocator.create(App);
        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .render_system = rs,
            .settings = settings,
            .input = input,
            .time = time,
            .camera = camera,
            .ui = ui,
            .app_state = .home,
            .last_state = .home,
            .pending_world_cleanup = false,
            .pending_new_world_seed = null,
            .debug_shadows = false,
            .debug_cascade_idx = 0,
            .seed_input = std.ArrayListUnmanaged(u8).empty,
            .seed_focused = false,
            .world = null,
            .world_map = null,
            .show_map = false,
            .map_needs_update = true,
            .map_zoom = 4.0,
            .map_target_zoom = 4.0,
            .map_pos_x = 0.0,
            .map_pos_z = 0.0,
            .last_mouse_x = 0.0,
            .last_mouse_y = 0.0,
        };

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.world_map) |*m| m.deinit();
        if (self.world) |w| w.deinit();
        self.seed_input.deinit(self.allocator);

        if (self.ui) |*u| u.deinit();
        self.render_system.deinit();
        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        self.render_system.rhi.setViewport(1280, 720);
        log.log.info("=== Zig Voxel Engine ===", .{});

        while (!self.input.should_quit) {
            // Safe deferred world management OUTSIDE the frame window
            if (self.pending_world_cleanup or self.pending_new_world_seed != null) {
                self.render_system.rhi.waitIdle();
                if (self.world) |w| {
                    w.deinit();
                    self.world = null;
                }
                self.pending_world_cleanup = false;
            }

            if (self.pending_new_world_seed) |seed| {
                self.pending_new_world_seed = null;
                self.world = World.init(self.allocator, self.settings.render_distance, seed, self.render_system.rhi) catch |err| {
                    log.log.err("Failed to create world: {}", .{err});
                    self.app_state = .home;
                    continue;
                };
                if (self.world_map == null) self.world_map = WorldMap.init(self.render_system.rhi, 256, 256);
                self.show_map = false;
                self.map_needs_update = true;
                self.camera = Camera.init(.{ .position = Vec3.init(8, 100, 8), .pitch = -0.3, .move_speed = 50.0 });
            }

            self.time.update();
            if (self.render_system.atmosphere) |*a| a.update(self.time.delta_time);
            if (self.render_system.clouds) |*cl| cl.update(self.time.delta_time);
            self.input.beginFrame();
            self.input.pollEvents();
            self.render_system.rhi.setViewport(self.input.window_width, self.input.window_height);
            if (self.ui) |*u| u.resize(self.input.window_width, self.input.window_height);
            const screen_w: f32 = @floatFromInt(self.input.window_width);
            const screen_h: f32 = @floatFromInt(self.input.window_height);
            const mouse_pos = self.input.getMousePosition();
            const mouse_x: f32 = @floatFromInt(mouse_pos.x);
            const mouse_y: f32 = @floatFromInt(mouse_pos.y);
            const mouse_clicked = self.input.isMouseButtonPressed(.left);

            if (self.input.isKeyPressed(.escape)) {
                if (self.show_map) {
                    self.show_map = false;
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
                if (self.input.isKeyPressed(.c)) if (self.render_system.clouds) |*cl| {
                    cl.enabled = !cl.enabled;
                };
                if (self.input.isKeyPressed(.f)) {
                    self.settings.wireframe_enabled = !self.settings.wireframe_enabled;
                    self.render_system.rhi.setWireframe(self.settings.wireframe_enabled);
                }
                if (self.input.isKeyPressed(.t)) {
                    self.settings.textures_enabled = !self.settings.textures_enabled;
                    self.render_system.rhi.setTexturesEnabled(self.settings.textures_enabled);
                }
                if (self.input.isKeyPressed(.v)) {
                    self.settings.vsync = !self.settings.vsync;
                    self.render_system.rhi.setVSync(self.settings.vsync);
                }
                if (self.input.isKeyPressed(.u)) self.debug_shadows = !self.debug_shadows;
                if (self.input.isKeyPressed(.m)) {
                    self.show_map = !self.show_map;
                    log.log.info("Toggle map: show={}", .{self.show_map});
                    if (self.show_map) {
                        self.map_pos_x = self.camera.position.x;
                        self.map_pos_z = self.camera.position.z;
                        self.map_target_zoom = self.map_zoom;
                        self.map_needs_update = true;
                        self.input.setMouseCapture(self.window_manager.window, false);
                    } else if (self.app_state == .world) self.input.setMouseCapture(self.window_manager.window, true);
                }

                if (self.show_map) {
                    const dt = @min(self.time.delta_time, 0.033);
                    // ... map input logic (omitted for brevity, same as before) ...
                    // Wait, I need to keep this logic or extract it.
                    // For now, I'll copy-paste the map input logic as it's coupled to App state.
                    if (self.input.isKeyDown(.plus) or self.input.isKeyDown(.kp_plus)) {
                        self.map_target_zoom /= @exp(1.2 * dt);
                        self.map_needs_update = true;
                    }
                    if (self.input.isKeyDown(.minus) or self.input.isKeyDown(.kp_minus)) {
                        self.map_target_zoom *= @exp(1.2 * dt);
                        self.map_needs_update = true;
                    }
                    if (self.input.scroll_y != 0) {
                        self.map_target_zoom *= @exp(-self.input.scroll_y * 0.12);
                        self.map_needs_update = true;
                    }
                    self.map_target_zoom = std.math.clamp(self.map_target_zoom, 0.05, 128.0);
                    const old_zoom = self.map_zoom;
                    self.map_zoom = std.math.lerp(self.map_zoom, self.map_target_zoom, 20.0 * dt);
                    if (@abs(self.map_zoom - old_zoom) > 0.001 * self.map_zoom) self.map_needs_update = true;
                    if (self.input.isKeyPressed(.space)) {
                        self.map_pos_x = self.camera.position.x;
                        self.map_pos_z = self.camera.position.z;
                        self.map_needs_update = true;
                    }
                    const map_ui_size: f32 = @min(screen_w, screen_h) * 0.8;
                    const world_to_screen_ratio = if (self.world_map) |m| @as(f32, @floatFromInt(m.width)) / map_ui_size else 1.0;
                    if (self.input.isMouseButtonPressed(.left)) {
                        self.last_mouse_x = mouse_x;
                        self.last_mouse_y = mouse_y;
                    }
                    if (self.input.isMouseButtonDown(.left)) {
                        const drag_dx = mouse_x - self.last_mouse_x;
                        const drag_dz = mouse_y - self.last_mouse_y;
                        if (@abs(drag_dx) > 0.1 or @abs(drag_dz) > 0.1) {
                            self.map_pos_x -= drag_dx * self.map_zoom * world_to_screen_ratio;
                            self.map_pos_z -= drag_dz * self.map_zoom * world_to_screen_ratio;
                            self.map_needs_update = true;
                        }
                        self.last_mouse_x = mouse_x;
                        self.last_mouse_y = mouse_y;
                    } else {
                        const pan_kb_speed = 800.0 * self.map_zoom;
                        var dx: f32 = 0;
                        var dz: f32 = 0;
                        if (self.input.isKeyDown(.w)) dz -= 1;
                        if (self.input.isKeyDown(.s)) dz += 1;
                        if (self.input.isKeyDown(.a)) dx -= 1;
                        if (self.input.isKeyDown(.d)) dx += 1;
                        if (dx != 0 or dz != 0) {
                            self.map_pos_x += dx * pan_kb_speed * dt;
                            self.map_pos_z += dz * pan_kb_speed * dt;
                            self.map_needs_update = true;
                        }
                    }
                }

                if (self.debug_shadows and self.input.isKeyPressed(.k)) self.debug_cascade_idx = (self.debug_cascade_idx + 1) % 3;
                if (self.input.isKeyPressed(.@"1")) if (self.render_system.atmosphere) |*a| a.setTimeOfDay(0.0);
                if (self.input.isKeyPressed(.@"2")) if (self.render_system.atmosphere) |*a| a.setTimeOfDay(0.25);
                if (self.input.isKeyPressed(.@"3")) if (self.render_system.atmosphere) |*a| a.setTimeOfDay(0.5);
                if (self.input.isKeyPressed(.@"4")) if (self.render_system.atmosphere) |*a| a.setTimeOfDay(0.75);
                if (self.input.isKeyPressed(.n)) if (self.render_system.atmosphere) |*a| {
                    a.time_scale = if (a.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
                };

                if (in_world) {
                    if (!self.show_map and !in_pause) {
                        self.camera.update(&self.input, self.time.delta_time);
                    }

                    if (self.world) |active_world| {
                        // Sync render distance
                        if (active_world.render_distance != self.settings.render_distance) {
                            active_world.render_distance = self.settings.render_distance;
                        }

                        try active_world.update(self.camera.position);
                    } else self.app_state = .home;
                }
            } else if (self.input.mouse_captured) self.input.setMouseCapture(self.window_manager.window, false);

            const clear_color = if (in_world or in_pause) (if (self.render_system.atmosphere) |a| a.fog_color else Vec3.init(0.5, 0.7, 1.0)) else Vec3.init(0.07, 0.08, 0.1);
            self.render_system.rhi.setClearColor(clear_color);
            self.render_system.rhi.beginFrame();

            if (in_world or in_pause) {
                if (self.world) |active_world| {
                    const aspect = screen_w / screen_h;
                    const view_proj_cull = self.camera.getViewProjectionMatrixOriginCentered(aspect);
                    const view_proj_render = if (self.render_system.is_vulkan)
                        Mat4.perspectiveReverseZ(self.camera.fov, aspect, self.camera.near, self.camera.far).multiply(self.camera.getViewMatrixOriginCentered())
                    else
                        view_proj_cull;
                    if (self.render_system.shadow_map) |*sm| {
                        if (self.render_system.atmosphere) |atmo| {
                            var light_dir = atmo.sun_dir;
                            if (atmo.sun_intensity < 0.05 and atmo.moon_intensity > 0.05) light_dir = atmo.moon_dir;
                            if (atmo.sun_intensity > 0.05 or atmo.moon_intensity > 0.05) {
                                sm.update(self.camera.fov, aspect, 0.1, self.settings.shadow_distance, light_dir, self.camera.position, self.camera.getViewMatrixOriginCentered());
                                for (0..3) |i| {
                                    sm.begin(i);
                                    active_world.renderShadowPass(sm.light_space_matrices[i], self.camera.position);
                                }
                                sm.end(self.input.window_width, self.input.window_height);
                            }
                        }
                    }
                    if (!self.render_system.is_vulkan) {
                        self.render_system.rhi.beginMainPass();
                        if (self.render_system.atmosphere) |*a| a.renderSky(self.camera.forward, self.camera.right, self.camera.up, aspect, self.camera.fov);
                    }
                    if (self.render_system.shader) |*s| {
                        s.use();
                        self.render_system.atlas.bind(0);
                        s.setInt("uTexture", 0);
                        s.setBool("uUseTexture", self.settings.textures_enabled);
                        if (self.render_system.shadow_map) |*sm| {
                            for (0..3) |i| {
                                sm.depth_maps[i].bind(@intCast(1 + i));
                                var buf: [64]u8 = undefined;
                                s.setInt(std.fmt.bufPrintZ(&buf, "uShadowMap{}", .{i}) catch "uShadowMap0", @intCast(1 + i));
                            }
                            const cascades = ShadowMap.computeCascades(self.settings.shadow_resolution, self.camera.fov, aspect, 0.1, self.settings.shadow_distance, if (self.render_system.atmosphere) |a| a.sun_dir else Vec3.init(0, 1, 0), self.camera.getViewMatrixOriginCentered(), true);
                            self.render_system.rhi.updateShadowUniforms(.{
                                .light_space_matrices = cascades.light_space_matrices,
                                .cascade_splits = cascades.cascade_splits,
                                .shadow_texel_sizes = cascades.texel_sizes,
                            });
                        }
                        if (self.render_system.atmosphere) |atmo| {
                            const cp: rhi_pkg.CloudParams = if (self.render_system.clouds) |*cl| blk: {
                                const p = cl.getCloudShadowParams();
                                break :blk .{
                                    .wind_offset_x = p.wind_offset_x,
                                    .wind_offset_z = p.wind_offset_z,
                                    .cloud_scale = p.cloud_scale,
                                    .cloud_coverage = p.cloud_coverage,
                                    .cloud_height = p.cloud_height,
                                };
                            } else .{};

                            self.render_system.rhi.updateGlobalUniforms(view_proj_cull, self.camera.position, atmo.sun_dir, atmo.time_of_day, atmo.fog_color, atmo.fog_density, atmo.fog_enabled, atmo.sun_intensity, atmo.ambient_intensity, cp);
                        }
                        active_world.render(view_proj_cull, self.camera.position);
                    } else if (self.render_system.is_vulkan) {
                        const fallback_sun_dir = Vec3.init(0.5, 0.8, 0.2);
                        const fallback_sky_color = Vec3.init(0.5, 0.7, 1.0);
                        const fallback_horizon_color = Vec3.init(0.8, 0.85, 0.95);

                        const sun_dir = if (self.render_system.atmosphere) |a| a.sun_dir else fallback_sun_dir;
                        const time_val = if (self.render_system.atmosphere) |a| a.time_of_day else 0.25;
                        const fog_color = if (self.render_system.atmosphere) |a| a.fog_color else Vec3.init(0.7, 0.8, 0.9);
                        const fog_density = if (self.render_system.atmosphere) |a| a.fog_density else 0.0;
                        const fog_enabled = if (self.render_system.atmosphere) |a| a.fog_enabled else false;
                        const sun_intensity_val = if (self.render_system.atmosphere) |a| a.sun_intensity else 1.0;
                        const moon_intensity_val = if (self.render_system.atmosphere) |a| a.moon_intensity else 0.0;
                        const ambient_val = if (self.render_system.atmosphere) |a| a.ambient_intensity else 0.2;
                        const sky_color = if (self.render_system.atmosphere) |a| a.sky_color else fallback_sky_color;
                        const horizon_color = if (self.render_system.atmosphere) |a| a.horizon_color else fallback_horizon_color;

                        var light_dir = sun_dir;
                        var light_active = true;
                        if (self.render_system.atmosphere) |atmo| {
                            if (atmo.sun_intensity < 0.05 and atmo.moon_intensity > 0.05) {
                                light_dir = atmo.moon_dir;
                            }
                            light_active = atmo.sun_intensity > 0.05 or atmo.moon_intensity > 0.05;
                        }

                        if (light_active) {
                            const cascades = ShadowMap.computeCascades(self.settings.shadow_resolution, self.camera.fov, aspect, 0.1, self.settings.shadow_distance, light_dir, self.camera.getViewMatrixOriginCentered(), true);
                            self.render_system.rhi.updateShadowUniforms(.{
                                .light_space_matrices = cascades.light_space_matrices,
                                .cascade_splits = cascades.cascade_splits,
                                .shadow_texel_sizes = cascades.texel_sizes,
                            });
                            for (0..ShadowMap.CASCADE_COUNT) |i| {
                                self.render_system.rhi.beginShadowPass(@intCast(i));
                                self.render_system.rhi.updateGlobalUniforms(cascades.light_space_matrices[i], self.camera.position, light_dir, time_val, fog_color, fog_density, false, 0.0, 0.0, .{});
                                active_world.renderShadowPass(cascades.light_space_matrices[i], self.camera.position);
                                self.render_system.rhi.endShadowPass();
                            }
                        }

                        self.render_system.rhi.drawSky(.{
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

                        self.render_system.atlas.bind(0);
                        const cp: rhi_pkg.CloudParams = if (self.render_system.clouds) |*cl| blk: {
                            const p = cl.getCloudShadowParams();
                            break :blk .{
                                .wind_offset_x = p.wind_offset_x,
                                .wind_offset_z = p.wind_offset_z,
                                .cloud_scale = p.cloud_scale,
                                .cloud_coverage = p.cloud_coverage,
                                .cloud_height = p.cloud_height,
                            };
                        } else .{};
                        self.render_system.rhi.updateGlobalUniforms(view_proj_render, self.camera.position, sun_dir, time_val, fog_color, fog_density, fog_enabled, sun_intensity_val, ambient_val, cp);
                        active_world.render(view_proj_cull, self.camera.position);
                    }
                    if (self.render_system.clouds) |*cl| if (self.render_system.atmosphere) |atmo| if (!self.render_system.is_vulkan) cl.render(self.camera.position, &view_proj_cull.data, atmo.sun_dir, atmo.sun_intensity, atmo.fog_color, atmo.fog_density);
                    if (self.debug_shadows and self.render_system.debug_shader != null and self.render_system.shadow_map != null) {
                        self.render_system.debug_shader.?.use();
                        c.glActiveTexture().?(c.GL_TEXTURE0);
                        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(self.render_system.shadow_map.?.depth_maps[self.debug_cascade_idx].handle));
                        self.render_system.debug_shader.?.setInt("uDepthMap", 0);
                        c.glBindVertexArray().?(self.render_system.debug_quad_vao);
                        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
                        c.glBindVertexArray().?(0);
                    }
                    if (self.ui) |*u| {
                        u.begin();
                        if (self.show_map) if (self.world_map) |*m| {
                            if (self.map_needs_update) {
                                try m.update(&active_world.generator, self.map_pos_x, self.map_pos_z, self.map_zoom);
                                self.map_needs_update = false;
                            }
                            const sz: f32 = @min(screen_w, screen_h) * 0.8;
                            const mx = (screen_w - sz) * 0.5;
                            const my = (screen_h - sz) * 0.5;
                            u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
                            u.drawTexture(@intCast(m.texture.handle), .{ .x = mx, .y = my, .width = sz, .height = sz });
                            u.drawRectOutline(.{ .x = mx, .y = my, .width = sz, .height = sz }, Color.white, 2.0);
                            Font.drawTextCentered(u, "WORLD MAP", screen_w * 0.5, my - 40.0, 3.0, Color.white);
                            const rx = (self.camera.position.x - self.map_pos_x) / (self.map_zoom * @as(f32, @floatFromInt(m.width)));
                            const rz = (self.camera.position.z - self.map_pos_z) / (self.map_zoom * @as(f32, @floatFromInt(m.height)));
                            const px = mx + (rx + 0.5) * sz;
                            const pz = my + (rz + 0.5) * sz;
                            if (px >= mx and px <= mx + sz and pz >= my and pz <= my + sz) {
                                u.drawRect(.{ .x = px - 5, .y = pz - 1, .width = 10, .height = 2 }, Color.red);
                                u.drawRect(.{ .x = px - 1, .y = pz - 5, .width = 2, .height = 10 }, Color.red);
                            }
                        };
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
                        if (self.render_system.atmosphere) |atmo| {
                            const h = atmo.getHours();
                            hr = @intFromFloat(h);
                            mn = @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0);
                            si = atmo.sun_intensity;
                        }
                        Font.drawText(u, "TIME:", 15, hy + 125, 1.5, Color.white);
                        Font.drawNumber(u, hr, 100, hy + 125, Color.white);
                        Font.drawText(u, ":", 125, hy + 125, 1.5, Color.white);
                        Font.drawNumber(u, mn, 140, hy + 125, Color.white);
                        Font.drawText(u, "SUN:", 15, hy + 145, 1.5, Color.white);
                        Font.drawNumber(u, @intFromFloat(si * 100.0), 100, hy + 145, Color.white);
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
                    .settings => Menus.drawSettings(ctx, &self.app_state, &self.settings, self.last_state, self.render_system.rhi),
                    .singleplayer => try Menus.drawSingleplayer(ctx, &self.app_state, &self.seed_input, &self.seed_focused, &self.pending_new_world_seed),
                    .world, .paused => unreachable,
                }
                u.end();
            }

            self.render_system.rhi.endFrame();
            if (!self.render_system.is_vulkan) _ = c.SDL_GL_SwapWindow(self.window_manager.window);
            if (in_world) {
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
