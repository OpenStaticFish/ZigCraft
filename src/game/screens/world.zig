const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const GameSession = @import("../session.zig").GameSession;
const Mat4 = @import("../../engine/math/mat4.zig").Mat4;
const Vec3 = @import("../../engine/math/vec3.zig").Vec3;
const rhi_pkg = @import("../../engine/graphics/rhi.zig");
const render_graph_pkg = @import("../../engine/graphics/render_graph.zig");
const log = @import("../../engine/core/log.zig");
const PausedScreen = @import("paused.zig").PausedScreen;

pub const WorldScreen = struct {
    context: EngineContext,
    session: *GameSession,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize) !*WorldScreen {
        const session = try GameSession.init(allocator, context.rhi, context.atlas, seed, context.settings.render_distance, context.settings.lod_enabled, generator_index);
        errdefer session.deinit();

        const self = try allocator.create(WorldScreen);
        self.* = .{
            .context = context,
            .session = session,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.session.deinit();
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        if (ctx.input_mapper.isActionPressed(ctx.input, .ui_back)) {
            const paused_screen = try PausedScreen.init(ctx.allocator, ctx);
            errdefer paused_screen.deinit(paused_screen);
            ctx.screen_manager.pushScreen(paused_screen.screen());
            return;
        }

        if (ctx.input_mapper.isActionPressed(ctx.input, .tab_menu)) {
            ctx.input.setMouseCapture(ctx.window_manager.window, !ctx.input.mouse_captured);
        }
        if (ctx.input_mapper.isActionPressed(ctx.input, .toggle_wireframe)) {
            ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
            ctx.rhi.*.setWireframe(ctx.settings.wireframe_enabled);
        }
        if (ctx.input_mapper.isActionPressed(ctx.input, .toggle_textures)) {
            ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
            ctx.rhi.*.setTexturesEnabled(ctx.settings.textures_enabled);
        }
        if (ctx.input_mapper.isActionPressed(ctx.input, .toggle_vsync)) {
            ctx.settings.vsync = !ctx.settings.vsync;
            ctx.rhi.*.setVSync(ctx.settings.vsync);
        }

        // Update Audio Listener
        const cam = &self.session.player.camera;
        ctx.audio_system.setListener(cam.position, cam.forward, cam.up);

        try self.session.update(dt, ctx.time.elapsed, ctx.input, ctx.input_mapper, ctx.atlas, ctx.window_manager.window, false, ctx.skip_world_update);

        if (self.session.world.render_distance != ctx.settings.render_distance) {
            self.session.world.setRenderDistance(ctx.settings.render_distance);
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const camera = &self.session.player.camera;

        const screen_w: f32 = @floatFromInt(ctx.input.window_width);
        const screen_h: f32 = @floatFromInt(ctx.input.window_height);
        const aspect = screen_w / screen_h;

        const view_proj_render = Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered());

        const sky_params = rhi_pkg.SkyParams{
            .cam_pos = camera.position,
            .cam_forward = camera.forward,
            .cam_right = camera.right,
            .cam_up = camera.up,
            .aspect = aspect,
            .tan_half_fov = @tan(camera.fov / 2.0),
            .sun_dir = self.session.atmosphere.celestial.sun_dir,
            .sky_color = self.session.atmosphere.sky_color,
            .horizon_color = self.session.atmosphere.horizon_color,
            .sun_intensity = self.session.atmosphere.sun_intensity,
            .moon_intensity = self.session.atmosphere.moon_intensity,
            .time = self.session.atmosphere.time.time_of_day,
        };

        const cloud_params: rhi_pkg.CloudParams = blk: {
            const p = self.session.clouds.getShadowParams();
            break :blk .{
                .cam_pos = camera.position,
                .view_proj = view_proj_render,
                .sun_dir = self.session.atmosphere.celestial.sun_dir,
                .sun_intensity = self.session.atmosphere.sun_intensity,
                .fog_color = self.session.atmosphere.fog_color,
                .fog_density = self.session.atmosphere.fog_density,
                .wind_offset_x = p.wind_offset_x,
                .wind_offset_z = p.wind_offset_z,
                .cloud_scale = p.cloud_scale,
                .cloud_coverage = p.cloud_coverage,
                .cloud_height = p.cloud_height,
                .base_color = self.session.clouds.base_color,
                .pbr_enabled = ctx.settings.pbr_enabled and ctx.atlas.has_pbr,
                .shadow = .{
                    .distance = ctx.settings.shadow_distance,
                    .resolution = ctx.settings.getShadowResolution(),
                    .pcf_samples = ctx.settings.shadow_pcf_samples,
                    .cascade_blend = ctx.settings.shadow_cascade_blend,
                },
                .cloud_shadows = ctx.settings.cloud_shadows_enabled,
                .pbr_quality = ctx.settings.pbr_quality,
                .exposure = ctx.settings.exposure,
                .saturation = ctx.settings.saturation,
                .volumetric_enabled = ctx.settings.volumetric_lighting_enabled,
                .volumetric_density = ctx.settings.volumetric_density,
                .volumetric_steps = ctx.settings.volumetric_steps,
                .volumetric_scattering = ctx.settings.volumetric_scattering,
                .ssao_enabled = ctx.settings.ssao_enabled,
            };
        };

        if (!ctx.skip_world_render) {
            ctx.rhi.*.updateGlobalUniforms(view_proj_render, camera.position, self.session.atmosphere.celestial.sun_dir, self.session.atmosphere.sun_color, self.session.atmosphere.time.time_of_day, self.session.atmosphere.fog_color, self.session.atmosphere.fog_density, self.session.atmosphere.fog_enabled, self.session.atmosphere.sun_intensity, self.session.atmosphere.ambient_intensity, ctx.settings.textures_enabled, cloud_params);

            const env_map_handle = if (ctx.env_map_ptr) |e_ptr| (if (e_ptr.*) |t| t.handle else 0) else 0;

            const ssao_enabled = ctx.settings.ssao_enabled and !ctx.disable_ssao and !ctx.disable_gpass_draw;
            const render_ctx = render_graph_pkg.SceneContext{
                .rhi = ctx.rhi.*, // SceneContext expects value for now
                .world = self.session.world,
                .shadow_scene = self.session.world.shadowScene(),
                .camera = camera,
                .atmosphere_system = ctx.atmosphere_system,
                .material_system = ctx.material_system,
                .aspect = aspect,
                .sky_params = sky_params,
                .cloud_params = cloud_params,
                .main_shader = ctx.shader,
                .env_map_handle = env_map_handle,
                .shadow = cloud_params.shadow,
                .ssao_enabled = ssao_enabled,
                .disable_shadow_draw = ctx.disable_shadow_draw,
                .disable_gpass_draw = ctx.disable_gpass_draw,
                .disable_ssao = ctx.disable_ssao,
                .disable_clouds = ctx.disable_clouds,
                .fxaa_enabled = ctx.settings.fxaa_enabled,
                .bloom_enabled = ctx.settings.bloom_enabled,
            };
            ctx.render_graph.execute(render_ctx);

            if (!ctx.safe_render_mode) {
                if (self.session.player.target_block) |target| self.session.block_outline.draw(target.x, target.y, target.z, camera.position);
                self.session.renderEntities(camera.position);
                self.session.hand_renderer.draw(camera.position, camera.yaw, camera.pitch);
            }
        }

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        try self.session.drawHUD(ui, ctx.atlas, ctx.resource_pack_manager.active_pack, ctx.time.fps, screen_w, screen_h, mouse_x, mouse_y, mouse_clicked);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, true);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
