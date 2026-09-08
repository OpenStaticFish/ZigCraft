const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const WorldContext = Screen.WorldContext;
const GameSession = @import("game-core").GameSession;
const IWorld = @import("world-runtime").IWorld;
const Vec3 = @import("engine-math").Vec3;
const rhi_pkg = @import("engine-rhi");
const Camera = @import("engine-camera").Camera;
const RenderSystem = @import("engine-graphics").RenderSystem;
const render_graph_pkg = @import("engine-graphics").render_graph;
const PausedScreen = @import("paused.zig").PausedScreen;
const RmlPausedScreen = @import("rml_paused.zig").RmlPausedScreen;
const rmlui = @import("engine-ui").rmlui;
const DebugShadowOverlay = @import("engine-ui").DebugShadowOverlay;
const DebugLPVOverlay = @import("engine-ui").DebugLPVOverlay;
const DebugUI = @import("engine-ui").DebugUI;
const DebugFeature = @import("engine-ui").DebugFeature;
const DebugFrustum = @import("engine-ui").debug_frustum;
const DebugFrustumOverlay = DebugFrustum.DebugFrustum;
const FRUSTUM_VERTEX_COUNT = DebugFrustum.FRUSTUM_VERTEX_COUNT;
const ChunkInspectorOverlay = @import("engine-ui").ChunkInspectorOverlay;
const Font = @import("engine-ui").font;
const Color = @import("engine-ui").Color;
const Rect = @import("engine-ui").Rect;
const WorldStats = @import("engine-ui").WorldStats;
const log = @import("engine-core").log;
const CSM = @import("engine-graphics").csm;
const settings_data = @import("game-core").settings.data;
const world_debug = @import("world_debug.zig");
const world_frame_params = @import("world_frame_params.zig");

const PauseScreenFactory = struct {
    context: EngineContext,

    pub fn construct(self: *@This()) !IScreen {
        if (rmlui.available and self.context.ui_manager.getRmlUi() != null) {
            const paused_screen = try RmlPausedScreen.init(self.context.allocator, self.context);
            return paused_screen.screen();
        }
        const paused_screen = try PausedScreen.init(self.context.allocator, self.context);
        return paused_screen.screen();
    }
};

const ShadowProbeInfo = struct {
    block_x: i32,
    block_y: i32,
    block_z: i32,
    world_pos: Vec3,
    view_depth: f32,
    cascade_index: usize,
    split_near: f32,
    split_far: f32,
    proj: Vec3,
    in_bounds: bool,
    texel_size: f32,
    texel_x: f32,
    texel_y: f32,
    texel_frac_x: f32,
    texel_frac_y: f32,
    matrix_translation: Vec3,
};

pub const WorldScreen = struct {
    context: WorldContext,
    parent_context: EngineContext,
    session: *GameSession,
    world: IWorld,
    last_debug_toggle_time: f32 = 0,
    debug_ui: DebugUI,
    frustum_buffer: rhi_pkg.BufferHandle = 0,
    frustum_initialized: bool = false,
    chunk_inspector_overlay: ChunkInspectorOverlay = .{},
    startup_diagnostic_start: f32 = 0,
    startup_diagnostic_start_frame: u64 = 0,
    startup_diagnostic_logged: bool = false,
    stable_shadow_sun_dir: Vec3 = Vec3.init(0.0, 1.0, 0.0),
    stable_shadow_sun_initialized: bool = false,
    save_failure_warning_count: usize = 0,
    menu_preview: bool = false,
    menu_preview_center: Vec3 = Vec3.zero,
    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .onExit = onExit,
        .getWorldStats = getWorldStatsIScreen,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize) !*WorldScreen {
        return initWithDistance(allocator, context, seed, generator_index, context.settings.render_distance, false, .diagnostic);
    }

    pub fn initPersistent(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize, save_dir_path: []const u8) !*WorldScreen {
        return initWithDistance(allocator, context, seed, generator_index, context.settings.render_distance, false, .{ .directory = save_dir_path });
    }

    pub fn initMenuPreview(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize) !*WorldScreen {
        return initWithDistance(allocator, context, seed, generator_index, context.settings.render_distance, true, .transient);
    }

    fn initWithDistance(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize, render_distance: i32, menu_preview: bool, persistence: GameSession.Persistence) !*WorldScreen {
        const render_system = context.render_system;
        const session = try GameSession.init(allocator, render_system.getRHI(), render_system.getAtlas(), seed, render_distance, generator_index, context.build_config, persistence);
        errdefer session.deinit();
        const world = session.world.interface();

        const self = try allocator.create(WorldScreen);
        self.* = .{
            .context = context.worldContext(),
            .parent_context = context,
            .session = session,
            .world = world,
            .last_debug_toggle_time = 0,
            .debug_ui = .{},
            .startup_diagnostic_start = context.time.elapsed,
            .startup_diagnostic_start_frame = context.time.frame_count,
            .startup_diagnostic_logged = false,
            .save_failure_warning_count = world.takeSaveFailureWarningCount(),
            .menu_preview = menu_preview,
            .menu_preview_center = session.player.position,
        };
        if (menu_preview) self.applyMenuCamera();
        settings_data.clearTerrainDebugViews(context.settings);
        render_system.getRHI().options().setShadowDebugChannel(@intFromEnum(settings_data.resolveShadowDebugChannel(context.settings)));
        render_system.getRHI().options().setDebugShadowView(false);
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.frustum_initialized) {
            self.context.render_system.getRHI().resourceManager().destroyBuffer(self.frustum_buffer);
        }
        self.session.deinit();
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const render_system = ctx.render_system;
        const now = ctx.time.elapsed;
        const benchmark_mode = ctx.benchmark_runner != null;
        const automated_capture = ctx.build_config.shadow_test_scene and ctx.build_config.screenshot_path.len > 0;

        const save_failures = self.world.takeSaveFailureWarningCount();
        if (save_failures > 0) {
            self.save_failure_warning_count += save_failures;
        }

        if (!self.menu_preview and !benchmark_mode and !automated_capture) {
            if (try self.processControls(now)) return;
        }

        if (benchmark_mode) {
            if (ctx.benchmark_runner) |benchmark| {
                benchmark.applyPose(&self.session.player);
            }
        }

        const cam = &self.session.player.camera;
        if (!self.menu_preview) {
            // Keep persisted/manual values aligned with the supported UI range
            cam.far = @import("game-core").session.cameraFarPlaneForRenderDistance(ctx.settings.render_distance);
            const world_telemetry = self.world.telemetry();
            if (world_telemetry.getRenderDistance() != ctx.settings.render_distance) {
                world_telemetry.setRenderDistance(ctx.settings.render_distance);
            }
        }
        ctx.audio_system.setListener(cam.position, cam.forward, cam.up);

        try self.session.update(dt, ctx.time.elapsed, ctx.input, ctx.input_mapper, render_system.getAtlas(), ctx.window_manager.window, false, ctx.skip_world_update, benchmark_mode or automated_capture or self.menu_preview);
        if (self.menu_preview) self.applyMenuCamera();
        render_system.getCloudSystem().step(dt);

        self.maybeLogStartupDiagnostic(now);
    }

    fn applyMenuCamera(self: *@This()) void {
        const angle = self.context.time.elapsed * 0.002 + 0.72;
        const radius: f32 = 32.0;
        const camera = &self.session.player.camera;
        camera.position = Vec3.init(
            self.menu_preview_center.x + std.math.cos(angle) * radius,
            self.menu_preview_center.y + 16.0,
            self.menu_preview_center.z + std.math.sin(angle) * radius,
        );
        camera.setYawPitch(angle + std.math.pi, -0.28);
    }

    fn processControls(self: *@This(), now: f32) !bool {
        const ctx = self.context;
        const render_system = ctx.render_system;
        const rhi = render_system.getRHI();
        const options = rhi.options();
        const can_toggle_debug = now - self.last_debug_toggle_time > 0.2;

        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_debug_menu)) {
            self.debug_ui.toggleMenu();
            ctx.input.setMouseCapture(@ptrCast(@alignCast(ctx.window_manager.window)), !self.debug_ui.menuEnabled());
            self.last_debug_toggle_time = now;
        }

        if (ctx.input_mapper.isActionPressed(ctx.input, .ui_back)) {
            const factory = try Screen.makeScreenFactory(PauseScreenFactory, ctx.allocator, .{ .context = self.parent_context });
            ctx.screen_manager.pushScreenFactory(factory);
            return true;
        }

        if (ctx.input_mapper.isActionPressed(ctx.input, .tab_menu)) {
            ctx.input.setMouseCapture(@ptrCast(@alignCast(ctx.window_manager.window)), !ctx.input.isMouseCaptured());
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_wireframe)) {
            ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
            options.setWireframe(ctx.settings.wireframe_enabled);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_textures)) {
            ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
            options.setTexturesEnabled(ctx.settings.textures_enabled);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_vsync)) {
            ctx.settings.vsync = !ctx.settings.vsync;
            options.setVSync(ctx.settings.vsync);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_shadow_debug_vis)) {
            log.log.info("Toggling shadow debug visualization (G pressed)", .{});
            const enable = !ctx.settings.debug_shadows_active;
            if (enable and !render_system.getDisableShadowDraw()) {
                ctx.settings.shadow_sandbox_enabled = true;
            }
            settings_data.clearTerrainDebugViews(ctx.settings);
            ctx.settings.debug_shadows_active = enable;
            options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
            options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_gpass_render)) {
            const new_val = !render_system.getDisableGPassDraw();
            render_system.setDisableGPassDraw(new_val);
            log.log.info("G-pass rendering {s}", .{if (new_val) "disabled" else "enabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_ssao)) {
            const new_val = !render_system.getDisableSSAO();
            render_system.setDisableSSAO(new_val);
            log.log.info("SSAO {s}", .{if (new_val) "disabled" else "enabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_fog)) {
            self.session.atmosphere.fog_enabled = !self.session.atmosphere.fog_enabled;
            log.log.info("Fog {s}", .{if (self.session.atmosphere.fog_enabled) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_lpv_overlay)) {
            ctx.settings.debug_lpv_overlay_active = !ctx.settings.debug_lpv_overlay_active;
            log.log.info("LPV overlay {s}", .{if (ctx.settings.debug_lpv_overlay_active) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_frustum_debug)) {
            ctx.settings.debug_frustum_active = !ctx.settings.debug_frustum_active;
            log.log.info("Frustum debug {s}", .{if (ctx.settings.debug_frustum_active) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_chunk_inspector)) {
            self.chunk_inspector_overlay.toggle();
            log.log.info("Chunk inspector {s}", .{if (self.chunk_inspector_overlay.enabled) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }

        return false;
    }

    fn maybeLogStartupDiagnostic(self: *@This(), now: f32) void {
        if (self.context.build_config.startup_diagnostic_seconds == 0 or self.startup_diagnostic_logged) return;

        const delay_s: f32 = @floatFromInt(self.context.build_config.startup_diagnostic_seconds);
        if (now - self.startup_diagnostic_start < delay_s) return;

        const world_telemetry = self.world.telemetry();
        const stats = world_telemetry.getStats();
        const render_stats = world_telemetry.getRenderStats();
        const state_counts = world_telemetry.getChunkStateCounts();
        const elapsed = now - self.startup_diagnostic_start;
        const frames_elapsed = self.context.time.frame_count - self.startup_diagnostic_start_frame;
        const avg_fps = if (elapsed > 0.001) @as(f32, @floatFromInt(frames_elapsed)) / elapsed else self.context.time.fps;

        log.log.warn(
            "STARTUP_DIAG: generator='{s}' elapsed={d:.2}s fps={d:.1} avg_fps={d:.1} frames={} rd={} chunks_loaded={} chunks_total={} chunks_rendered={} chunks_culled={} gen_queue={} mesh_queue={} upload_queue={}",
            .{
                world_telemetry.getGeneratorName(),
                elapsed,
                self.context.time.fps,
                avg_fps,
                frames_elapsed,
                world_telemetry.getRenderDistance(),
                stats.chunks_loaded,
                render_stats.chunks_total,
                render_stats.chunks_rendered,
                render_stats.chunks_culled,
                stats.gen_queue,
                stats.mesh_queue,
                stats.upload_queue,
            },
        );
        log.log.warn(
            "STARTUP_DIAG_STATES: total={} missing={} generating={} meshing={} renderable={} other={} dirty={} vertices_rendered={}",
            .{
                state_counts.total,
                state_counts.missing,
                state_counts.generating,
                state_counts.meshing,
                state_counts.renderable,
                state_counts.other_states,
                state_counts.dirty,
                render_stats.vertices_rendered,
            },
        );
        self.startup_diagnostic_logged = true;
        self.context.input.setShouldQuit(true);
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const render_system = ctx.render_system;
        const rhi = render_system.getRHI();
        const camera = &self.session.player.camera;

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const safe_mode = render_system.getSafeMode();
        const world_telemetry = self.world.telemetry();
        const world_render_view = self.world.renderView();
        const startup_busy = world_telemetry.isStartupBusy();
        const startup_loading = ctx.build_config.auto_world.len > 0 and startup_busy;
        const startup_light_render = startup_loading and !safe_mode;
        const shadow_sandbox_active = ctx.settings.shadow_sandbox_enabled and !render_system.getDisableShadowDraw() and !startup_light_render;
        const shadow_beauty_active = ctx.settings.shadow_beauty_enabled and shadow_sandbox_active;
        const clean_capture = ctx.build_config.shadow_test_scene and ctx.build_config.screenshot_path.len > 0;
        const shadow_distance_active = ctx.settings.shadow_distance;
        const shadow_caster_distance_active = ctx.settings.shadow_caster_distance;
        const render_sun_dir = self.session.atmosphere.celestial.sun_dir;
        const shadow_sun_dir = if (shadow_sandbox_active) self.resolveStableShadowSunDir(render_sun_dir) else render_sun_dir;
        if (!shadow_sandbox_active) self.stable_shadow_sun_initialized = false;

        const lpv_quality = resolveLPVQuality(ctx.settings.lpv_quality_preset);
        const lpv_system = render_system.getLPVSystem();
        try lpv_system.setSettings(
            ctx.settings.lpv_enabled and !safe_mode and !startup_light_render,
            ctx.settings.lpv_intensity,
            ctx.settings.lpv_cell_size,
            lpv_quality.propagation_iterations,
            lpv_quality.grid_size,
            lpv_quality.update_interval_frames,
        );
        if (lpv_system.isEnabled()) {
            rhi.timing().beginPassTiming("LPVPass");
            try lpv_system.update(world_render_view.lpvWorld(), camera.position, ctx.settings.debug_lpv_overlay_active);
            rhi.timing().endPassTiming("LPVPass");
        }

        const lpv_origin = lpv_system.getOrigin();
        const built_params = world_frame_params.build(.{
            .camera = camera,
            .settings = ctx.settings,
            .render_system = render_system,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .render_sun_dir = render_sun_dir,
            .sky_color = self.session.atmosphere.sky_color,
            .horizon_color = self.session.atmosphere.horizon_color,
            .sun_intensity = self.session.atmosphere.sun_intensity,
            .moon_intensity = self.session.atmosphere.moon_intensity,
            .time_of_day = self.session.atmosphere.time.time_of_day,
            .fog_color = self.session.atmosphere.fog_color,
            .fog_density = self.session.atmosphere.fog_density,
            .safe_mode = safe_mode,
            .startup_light_render = startup_light_render,
            .shadow_sandbox_active = shadow_sandbox_active,
            .shadow_beauty_active = shadow_beauty_active,
            .shadow_distance_active = shadow_distance_active,
            .shadow_caster_distance_active = shadow_caster_distance_active,
            .lpv_cell_size = lpv_system.getCellSize(),
            .lpv_grid_size = lpv_system.getGridSize(),
            .lpv_origin = lpv_origin,
            .lpv_available = lpv_system.isEnabled(),
        });
        const aspect = built_params.aspect;
        const taa_enabled = built_params.taa_enabled;
        const view_proj_render = built_params.view_proj_render;
        const frame_params = built_params.frame;
        const ssao_enabled = built_params.ssao_enabled;

        const skip_world_render = render_system.getSafeRenderMode();
        if (!skip_world_render and !startup_loading) {
            const boosted_horizon = self.session.atmosphere.horizon_color.scale(1.5);
            const clear_color = Vec3.init(
                std.math.clamp(boosted_horizon.x, 0.0, 1.0),
                std.math.clamp(boosted_horizon.y, 0.0, 1.0),
                std.math.clamp(boosted_horizon.z, 0.0, 1.0),
            );
            rhi.renderContext().setClearColor(clear_color);
            try rhi.renderContext().updateGlobalUniforms(.{
                .view_proj = view_proj_render,
                .cam_pos = camera.position,
                .sun_dir = render_sun_dir,
                .sun_color = self.session.atmosphere.sun_color,
                .time = self.session.atmosphere.time.time_of_day,
                .fog_color = self.session.atmosphere.fog_color,
                .fog_density = self.session.atmosphere.fog_density,
                .fog_enabled = self.session.atmosphere.fog_enabled and !safe_mode,
                .sun_intensity = self.session.atmosphere.sun_intensity,
                .ambient = self.session.atmosphere.ambient_intensity,
                .use_texture = ctx.settings.textures_enabled,
            }, frame_params);

            const env_map_ptr = render_system.getEnvMapPtr();
            const env_map_handle = if (env_map_ptr.*) |t| t.handle else 0;

            var frame_cascades: ?@import("engine-graphics").ShadowCascades = null;

            const resolution_scale = rhi.options().getResolutionScale();
            const render_w = screen_w * resolution_scale;
            const render_h = screen_h * resolution_scale;

            const gpu_mesh_dispatch = world_render_view.getGpuMeshDispatch();
            const render_ctx = render_graph_pkg.SceneContext{
                .render_ctx = rhi.renderContext(),
                .shadow_ctx = rhi.shadowSystem(),
                .water_ctx = rhi.waterSystem(),
                .ssao_ctx = rhi.ssao(),
                .timing = rhi.timing(),
                .world = world_render_view.graphicsRenderView(),
                .shadow_scene = self.world.shadowScene(),
                .camera = camera,
                .atmosphere_system = render_system.getAtmosphereSystem(),
                .aspect = aspect,
                .taa_enabled = taa_enabled,
                .viewport_width = render_w,
                .viewport_height = render_h,
                .sky_params = built_params.sky,
                .shadow_sun_dir = shadow_sun_dir,
                .main_shader = render_system.getShader(),
                .env_map_handle = env_map_handle,
                .shadow = frame_params.shadow,
                .ssao_enabled = ssao_enabled,
                .gpu_culling_enabled = self.world.isGpuCullingEnabled(),
                .shadow_draw_enabled = shadow_sandbox_active,
                .fxaa_enabled = ctx.settings.fxaa_enabled and !ctx.settings.taa_enabled,
                .bloom_enabled = ctx.settings.bloom_enabled and !startup_light_render,
                .resolution_scale = resolution_scale,
                .overlay_renderer = if (clean_capture or self.menu_preview) null else renderOverlay,
                .overlay_ctx = if (clean_capture or self.menu_preview) null else self,
                .shadow_caster_renderer = renderEntityShadowCasters,
                .shadow_caster_ctx = self,
                .cached_cascades = &frame_cascades,
                .lpv_textures = render_graph_pkg.LPVTextureHandles.fromSystem(lpv_system),
                .gpu_mesh_dispatch_fn = gpu_mesh_dispatch.dispatch_fn,
                .gpu_mesh_dispatch_ctx = gpu_mesh_dispatch.dispatch_ctx,
                .cloud_system = render_system.getCloudSystem(),
            };
            try render_system.getRenderGraph().execute(render_ctx);
        }
        if (taa_enabled) {
            camera.advanceJitter();
        } else {
            camera.resetJitter();
        }

        ui.begin();
        defer ui.end();

        if (self.save_failure_warning_count > 0) {
            var save_warning_buf: [96]u8 = undefined;
            const save_warning = std.fmt.bufPrint(&save_warning_buf, "SAVE WARNING: {} save failure(s). Check logs.", .{self.save_failure_warning_count}) catch "SAVE WARNING: save failures. Check logs.";
            const warning_rect = Rect{ .x = 14.0 * ctx.settings.ui_scale, .y = 14.0 * ctx.settings.ui_scale, .width = 360.0 * ctx.settings.ui_scale, .height = 34.0 * ctx.settings.ui_scale };
            ui.drawRect(warning_rect, Color.rgba(0.18, 0.04, 0.05, 0.88));
            ui.drawRectOutline(warning_rect, Color.rgba(0.78, 0.30, 0.34, 1.0), 1.0 * ctx.settings.ui_scale);
            Font.drawText(ui, save_warning, warning_rect.x + 10.0 * ctx.settings.ui_scale, warning_rect.y + 10.0 * ctx.settings.ui_scale, 0.78 * ctx.settings.ui_scale, Color.rgba(1.0, 0.90, 0.84, 1.0));
        }

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const hud_clicked = if (self.debug_ui.menuEnabled()) false else mouse_clicked;

        if (!clean_capture and !self.menu_preview) {
            try self.session.drawHUD(ui, render_system.getAtlas(), render_system.getResourcePackManager().active_pack, ctx.time.fps, screen_w, screen_h, mouse_x, mouse_y, hud_clicked);
        }

        if (startup_loading) {
            const msg = "LOADING TERRAIN...";
            const box_w = 240.0;
            const box_h = 34.0;
            const box_x = screen_w * 0.5 - box_w * 0.5;
            const box_y = screen_h * 0.5 - box_h * 0.5;
            ui.drawRect(.{ .x = box_x, .y = box_y, .width = box_w, .height = box_h }, Color.rgba(0.010, 0.020, 0.030, 0.78));
            ui.drawRect(.{ .x = box_x, .y = box_y, .width = 5.0, .height = box_h }, Color.rgba(0.95, 0.62, 0.24, 0.92));
            ui.drawRectOutline(.{ .x = box_x, .y = box_y, .width = box_w, .height = box_h }, Color.rgba(0.42, 0.66, 0.82, 0.68), 1.0);
            Font.drawText(ui, msg, box_x + 18.0, box_y + 8.0, 2.0, Color.rgba(1.0, 0.93, 0.76, 1.0));
        }

        if (shadow_sandbox_active and settings_data.anyShadowMapDebugActive(ctx.settings)) {
            const shadow_res = ctx.settings.getShadowResolution();
            const shadow_dist = shadow_distance_active;
            const debug_cascades = CSM.computeCascadesWithCamera(
                shadow_res,
                camera.fov,
                aspect,
                0.1,
                shadow_dist,
                shadow_sun_dir,
                camera.getViewMatrixOriginCentered(),
                camera.position,
                true,
            );
            DebugShadowOverlay.draw(ui, rhi.shadowSystem(), screen_w, screen_h, .{
                .debug_shadow_cascade_index = ctx.settings.debug_shadow_cascade_index,
                .debug_shadow_caster_coverage = ctx.settings.debug_shadow_caster_coverage,
                .debug_shadow_seam_diag = ctx.settings.debug_shadow_seam_diag,
            }, &debug_cascades.cascade_splits);
        }
        if (ctx.settings.shadow_probe_enabled) {
            const probe = if (shadow_sandbox_active)
                self.buildShadowProbe(camera, aspect, ctx.settings.getShadowResolution(), shadow_distance_active, shadow_sun_dir)
            else
                null;
            self.drawShadowProbeOverlay(ui, probe, screen_h, ctx.settings.ui_scale);
        }
        if (ctx.settings.debug_lpv_overlay_active) {
            const overlay_size = std.math.clamp(220.0 * ctx.settings.ui_scale, 160.0, screen_h * 0.4);
            const cfg = DebugLPVOverlay.Config{
                .width = overlay_size,
                .height = overlay_size,
                .spacing = 10.0 * ctx.settings.ui_scale,
            };
            const r = DebugLPVOverlay.rect(screen_h, cfg);
            DebugLPVOverlay.draw(ui, lpv_system.getDebugOverlayTextureHandle(), screen_h, cfg);

            const stats = lpv_system.getStats();
            const timing_results = rhi.timing().getTimingResults();
            var line0_buf: [64]u8 = undefined;
            var line1_buf: [64]u8 = undefined;
            var line2_buf: [64]u8 = undefined;
            var line3_buf: [64]u8 = undefined;
            const line0 = std.fmt.bufPrint(&line0_buf, "LPV GRID:{d} ITER:{d}", .{ stats.grid_size, stats.propagation_iterations }) catch "LPV";
            const line1 = std.fmt.bufPrint(&line1_buf, "LIGHTS:{d} UPDATE:{d:.2}MS", .{ stats.light_count, stats.cpu_update_ms }) catch "LIGHTS";
            const line2 = std.fmt.bufPrint(&line2_buf, "TICK:{d} UPDATED:{d}", .{ stats.update_interval_frames, if (stats.updated_this_frame) @as(u8, 1) else @as(u8, 0) }) catch "TICK";
            const line3 = std.fmt.bufPrint(&line3_buf, "LPV GPU:{d:.2}MS", .{timing_results.lpv_pass_ms}) catch "GPU";

            const text_x = r.x;
            const text_y = r.y - 28.0;
            Font.drawText(ui, line0, text_x, text_y, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line1, text_x, text_y + 10.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line2, text_x, text_y + 20.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line3, text_x, text_y + 30.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
        }

        if (ctx.settings.debug_frustum_active) {
            if (!self.frustum_initialized) {
                self.frustum_buffer = try render_system.getRHI().resourceManager().createBuffer(
                    @sizeOf([FRUSTUM_VERTEX_COUNT]rhi_pkg.Vertex),
                    .vertex,
                );
                self.frustum_initialized = true;
            }

            const corners = DebugFrustumOverlay.extractCorners(view_proj_render, camera.getViewMatrixOriginCentered());
            const frustum_verts = DebugFrustumOverlay.buildLineVertices(corners, DebugFrustumOverlay.DefaultColor);
            try render_system.getRHI().resourceManager().uploadBuffer(
                self.frustum_buffer,
                std.mem.asBytes(&frustum_verts),
            );

            DebugFrustumOverlay.draw(
                rhi.renderContext(),
                self.frustum_buffer,
                FRUSTUM_VERTEX_COUNT,
                camera.position,
            );
        }

        if (self.chunk_inspector_overlay.enabled) {
            const world_state = world_telemetry.getWorldStateData();
            const render_stats = world_telemetry.getRenderStats();
            self.chunk_inspector_overlay.draw(
                ui,
                .{
                    .chunks_total = render_stats.chunks_total,
                    .chunks_rendered = render_stats.chunks_rendered,
                    .chunks_culled = render_stats.chunks_culled,
                    .vertices_rendered = render_stats.vertices_rendered,
                },
                world_telemetry.getChunkStateCounts(),
                world_state,
            );
        }

        if (self.debug_ui.menuEnabled()) {
            const debug_state = world_debug.ScreenDebugState{
                .session = self.session,
                .last_debug_toggle_time = &self.last_debug_toggle_time,
                .chunk_inspector_overlay = &self.chunk_inspector_overlay,
            };
            const feature_states = world_debug.collectStates(debug_state, ctx, render_system);
            const scroll_delta = ctx.input.getScrollDelta();
            if (self.debug_ui.drawMenu(ui, feature_states, mouse_x, mouse_y, mouse_clicked, ctx.settings.ui_scale, scroll_delta.y, ctx.ui_manager.getImguiBackend())) |click| {
                world_debug.applyToggle(debug_state, click.feature, ctx, render_system, rhi, ctx.time.elapsed);
            }
        }
    }

    fn drawBackground(ptr: *anyopaque, ui: *UISystem) !void {
        try draw(ptr, ui);
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

    pub fn getWorldStats(self: *WorldScreen) ?WorldStats {
        const ws = self.world.telemetry();
        const rs = ws.getRenderStats();
        const stats = ws.getStats();
        return .{
            .chunks_total = rs.chunks_total,
            .chunks_rendered = rs.chunks_rendered,
            .chunks_culled = rs.chunks_culled,
            .vertices_rendered = rs.vertices_rendered,
            .gen_queue = stats.gen_queue,
            .mesh_queue = stats.mesh_queue,
            .upload_queue = stats.upload_queue,
        };
    }

    fn getWorldStatsIScreen(ptr: *anyopaque) ?WorldStats {
        const self: *WorldScreen = @ptrCast(@alignCast(ptr));
        return self.getWorldStats();
    }

    fn buildShadowProbe(self: *WorldScreen, camera: *Camera, aspect: f32, shadow_res: u32, shadow_dist: f32, sun_dir: Vec3) ?ShadowProbeInfo {
        const target = self.session.player.target_block orelse return null;
        const cascades = CSM.computeCascadesWithCamera(
            shadow_res,
            camera.fov,
            aspect,
            0.1,
            shadow_dist,
            sun_dir,
            camera.getViewMatrixOriginCentered(),
            camera.position,
            true,
        );
        if (!cascades.isValid()) return null;

        const eye = self.session.player.getEyePosition();
        const probe_distance = @max(target.distance - 0.01, 0.0);
        const probe_world = eye.add(camera.forward.scale(probe_distance));
        const probe_relative = probe_world.sub(camera.position);
        const cascade_distance = probe_relative.length();

        var cascade_index: usize = 3;
        if (cascade_distance < cascades.cascade_splits[0]) cascade_index = 0 else if (cascade_distance < cascades.cascade_splits[1]) cascade_index = 1 else if (cascade_distance < cascades.cascade_splits[2]) cascade_index = 2;

        const shadow_pos = cascades.light_space_matrices[cascade_index].transformPoint(probe_relative);
        const proj = Vec3.init(
            shadow_pos.x * 0.5 + 0.5,
            shadow_pos.y * 0.5 + 0.5,
            shadow_pos.z,
        );
        const split_near: f32 = if (cascade_index == 0) 0.1 else cascades.cascade_splits[cascade_index - 1];
        const split_far = cascades.cascade_splits[cascade_index];
        const shadow_res_f: f32 = @floatFromInt(shadow_res);
        const texel_x = proj.x * shadow_res_f;
        const texel_y = proj.y * shadow_res_f;

        return .{
            .block_x = target.x,
            .block_y = target.y,
            .block_z = target.z,
            .world_pos = probe_world,
            .view_depth = cascade_distance,
            .cascade_index = cascade_index,
            .split_near = split_near,
            .split_far = split_far,
            .proj = proj,
            .in_bounds = proj.x >= 0.0 and proj.x <= 1.0 and proj.y >= 0.0 and proj.y <= 1.0 and proj.z >= 0.0 and proj.z <= 1.0,
            .texel_size = cascades.texel_sizes[cascade_index],
            .texel_x = texel_x,
            .texel_y = texel_y,
            .texel_frac_x = texel_x - @floor(texel_x),
            .texel_frac_y = texel_y - @floor(texel_y),
            .matrix_translation = Vec3.init(
                cascades.light_space_matrices[cascade_index].data[3][0],
                cascades.light_space_matrices[cascade_index].data[3][1],
                cascades.light_space_matrices[cascade_index].data[3][2],
            ),
        };
    }

    fn resolveStableShadowSunDir(self: *WorldScreen, live_sun_dir: Vec3) Vec3 {
        // Cloud shadows make quantized sun-direction updates visibly pop sideways.
        // Cascades are already texel-snapped, so keep the light direction continuous.
        self.stable_shadow_sun_dir = live_sun_dir;
        self.stable_shadow_sun_initialized = true;
        return self.stable_shadow_sun_dir;
    }

    fn drawShadowProbeOverlay(self: *WorldScreen, ui: *UISystem, probe: ?ShadowProbeInfo, screen_h: f32, ui_scale: f32) void {
        _ = self;
        const panel_x = 12.0 * ui_scale;
        const panel_h = 126.0 * ui_scale;
        const panel_y = @max(12.0 * ui_scale, screen_h - panel_h - 12.0 * ui_scale);
        const panel_w = 372.0 * ui_scale;
        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.010, 0.020, 0.030, 0.78));
        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = 5.0 * ui_scale, .height = panel_h }, Color.rgba(0.95, 0.62, 0.24, 0.92));
        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = 28.0 * ui_scale }, Color.rgba(0.10, 0.20, 0.28, 0.62));
        ui.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.42, 0.66, 0.82, 0.68), 1.0 * ui_scale);

        const text_scale = 1.75 * ui_scale;
        const text_x = panel_x + 10.0 * ui_scale;
        const line_h = 14.0 * ui_scale;
        var y = panel_y + 10.0 * ui_scale;
        Font.drawText(ui, "SHADOW PROBE", panel_x + 10.0 * ui_scale, y, text_scale, Color.rgba(1.0, 0.93, 0.76, 1.0));
        y += line_h;

        if (probe) |p| {
            var line0: [64]u8 = undefined;
            var line1: [80]u8 = undefined;
            var line2: [96]u8 = undefined;
            var line3: [96]u8 = undefined;
            var line4: [96]u8 = undefined;
            var line5: [96]u8 = undefined;
            var line6: [96]u8 = undefined;

            const text0 = std.fmt.bufPrint(&line0, "BLOCK {d} {d} {d}", .{ p.block_x, p.block_y, p.block_z }) catch "BLOCK";
            const text1 = std.fmt.bufPrint(&line1, "CAS {d} D {d:.1} [{d:.1}-{d:.1}]", .{ p.cascade_index, p.view_depth, p.split_near, p.split_far }) catch "CAS";
            const text2 = std.fmt.bufPrint(&line2, "UVZ {d:.3} {d:.3} {d:.3}", .{ p.proj.x, p.proj.y, p.proj.z }) catch "UVZ";
            const text3 = std.fmt.bufPrint(&line3, "TEXEL {d:.2} {d:.2}  FRAC {d:.3} {d:.3}", .{ p.texel_x, p.texel_y, p.texel_frac_x, p.texel_frac_y }) catch "TEXEL";
            const text4 = std.fmt.bufPrint(&line4, "IN {s} WORLD-TEXEL {d:.5}", .{ if (p.in_bounds) "YES" else "NO", p.texel_size }) catch "IN";
            const text5 = std.fmt.bufPrint(&line5, "WORLD {d:.2} {d:.2} {d:.2}", .{ p.world_pos.x, p.world_pos.y, p.world_pos.z }) catch "WORLD";
            const text6 = std.fmt.bufPrint(&line6, "M43 {d:.2} {d:.2} {d:.2}", .{ p.matrix_translation.x, p.matrix_translation.y, p.matrix_translation.z }) catch "M43";

            Font.drawText(ui, text0, text_x, y, text_scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
            y += line_h;
            Font.drawText(ui, text1, text_x, y, text_scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
            y += line_h;
            Font.drawText(ui, text2, text_x, y, text_scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
            y += line_h;
            Font.drawText(ui, text3, text_x, y, text_scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
            y += line_h;
            Font.drawText(ui, text4, text_x, y, text_scale, if (p.in_bounds) Color.rgba(0.42, 1.0, 0.48, 1.0) else Color.rgba(0.92, 0.42, 0.42, 1.0));
            y += line_h;
            Font.drawText(ui, text5, text_x, y, text_scale, Color.rgba(0.72, 0.80, 0.92, 1.0));
            y += line_h;
            Font.drawText(ui, text6, text_x, y, text_scale, Color.rgba(0.72, 0.80, 0.92, 1.0));
        } else {
            Font.drawText(ui, "NO TARGET BLOCK", text_x, y, text_scale, Color.rgba(0.92, 0.42, 0.42, 1.0));
        }
    }

    fn collectDebugStates(self: *WorldScreen, ctx: EngineContext, render_system: *RenderSystem) [DebugFeature.count]bool {
        var states: [DebugFeature.count]bool = @splat(false);
        states[@intFromEnum(DebugFeature.wireframe)] = ctx.settings.wireframe_enabled;
        states[@intFromEnum(DebugFeature.textures)] = ctx.settings.textures_enabled;
        states[@intFromEnum(DebugFeature.vsync)] = ctx.settings.vsync;
        states[@intFromEnum(DebugFeature.fps_counter)] = self.session.debug_show_fps;
        states[@intFromEnum(DebugFeature.block_info)] = self.session.debug_show_block_info;
        states[@intFromEnum(DebugFeature.shadow_sandbox)] = ctx.settings.shadow_sandbox_enabled;
        states[@intFromEnum(DebugFeature.shadow_beauty)] = ctx.settings.shadow_beauty_enabled;
        states[@intFromEnum(DebugFeature.shadow_probe)] = ctx.settings.shadow_probe_enabled;
        states[@intFromEnum(DebugFeature.shadow_debug)] = ctx.settings.debug_shadows_active;
        states[@intFromEnum(DebugFeature.shadow_cascade_index)] = ctx.settings.debug_shadow_cascade_index;
        states[@intFromEnum(DebugFeature.shadow_caster_coverage)] = ctx.settings.debug_shadow_caster_coverage;
        states[@intFromEnum(DebugFeature.shadow_seam_diag)] = ctx.settings.debug_shadow_seam_diag;
        states[@intFromEnum(DebugFeature.direct_key_debug)] = ctx.settings.debug_direct_key_active;
        states[@intFromEnum(DebugFeature.sky_fill_debug)] = ctx.settings.debug_sky_fill_active;
        states[@intFromEnum(DebugFeature.block_light_debug)] = ctx.settings.debug_block_light_active;
        states[@intFromEnum(DebugFeature.outdoor_factor_debug)] = ctx.settings.debug_outdoor_factor_active;
        states[@intFromEnum(DebugFeature.gpass_render)] = !render_system.getDisableGPassDraw();
        states[@intFromEnum(DebugFeature.ssao)] = !render_system.getDisableSSAO();
        states[@intFromEnum(DebugFeature.fog)] = self.session.atmosphere.fog_enabled;
        states[@intFromEnum(DebugFeature.lpv_overlay)] = ctx.settings.debug_lpv_overlay_active;
        states[@intFromEnum(DebugFeature.frustum_debug)] = ctx.settings.debug_frustum_active;
        states[@intFromEnum(DebugFeature.occlusion_debug)] = ctx.settings.debug_occlusion_active;
        states[@intFromEnum(DebugFeature.creative_mode)] = self.session.creative_mode;
        states[@intFromEnum(DebugFeature.time_pause)] = self.session.atmosphere.time.time_scale == 0.0;
        states[@intFromEnum(DebugFeature.chunk_inspector)] = self.chunk_inspector_overlay.enabled;
        return states;
    }

    fn applyDebugFeatureToggle(self: *WorldScreen, feature: DebugFeature, ctx: EngineContext, render_system: *RenderSystem, rhi: *rhi_pkg.RHI, now: f32) void {
        self.last_debug_toggle_time = now;
        const options = rhi.options();
        switch (feature) {
            .wireframe => {
                ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
                options.setWireframe(ctx.settings.wireframe_enabled);
            },
            .textures => {
                ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
                options.setTexturesEnabled(ctx.settings.textures_enabled);
            },
            .vsync => {
                ctx.settings.vsync = !ctx.settings.vsync;
                options.setVSync(ctx.settings.vsync);
            },
            .fps_counter => {
                self.session.debug_show_fps = !self.session.debug_show_fps;
            },
            .block_info => {
                self.session.debug_show_block_info = !self.session.debug_show_block_info;
            },
            .shadow_sandbox => {
                ctx.settings.shadow_sandbox_enabled = !ctx.settings.shadow_sandbox_enabled;
                if (!ctx.settings.shadow_sandbox_enabled) {
                    ctx.settings.shadow_beauty_enabled = false;
                    ctx.settings.shadow_probe_enabled = false;
                    settings_data.clearTerrainDebugViews(ctx.settings);
                    options.setDebugShadowView(false);
                    options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
                }
            },
            .shadow_beauty => {
                ctx.settings.shadow_beauty_enabled = !ctx.settings.shadow_beauty_enabled;
                if (ctx.settings.shadow_beauty_enabled and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
            },
            .shadow_probe => {
                ctx.settings.shadow_probe_enabled = !ctx.settings.shadow_probe_enabled;
                if (ctx.settings.shadow_probe_enabled and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
            },
            .shadow_debug => {
                const enable = !ctx.settings.debug_shadows_active;
                if (enable and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_shadows_active = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .shadow_cascade_index => {
                const enable = !ctx.settings.debug_shadow_cascade_index;
                if (enable and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_shadow_cascade_index = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .shadow_caster_coverage => {
                const enable = !ctx.settings.debug_shadow_caster_coverage;
                if (enable and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_shadow_caster_coverage = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .shadow_seam_diag => {
                const enable = !ctx.settings.debug_shadow_seam_diag;
                if (enable and !render_system.getDisableShadowDraw()) {
                    ctx.settings.shadow_sandbox_enabled = true;
                }
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_shadow_seam_diag = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .direct_key_debug => {
                const enable = !ctx.settings.debug_direct_key_active;
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_direct_key_active = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .sky_fill_debug => {
                const enable = !ctx.settings.debug_sky_fill_active;
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_sky_fill_active = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .block_light_debug => {
                const enable = !ctx.settings.debug_block_light_active;
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_block_light_active = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .outdoor_factor_debug => {
                const enable = !ctx.settings.debug_outdoor_factor_active;
                settings_data.clearTerrainDebugViews(ctx.settings);
                ctx.settings.debug_outdoor_factor_active = enable;
                options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            },
            .gpass_render => {
                const new_val = !render_system.getDisableGPassDraw();
                render_system.setDisableGPassDraw(new_val);
            },
            .ssao => {
                const new_val = !render_system.getDisableSSAO();
                render_system.setDisableSSAO(new_val);
            },
            .fog => {
                self.session.atmosphere.fog_enabled = !self.session.atmosphere.fog_enabled;
            },
            .lpv_overlay => {
                ctx.settings.debug_lpv_overlay_active = !ctx.settings.debug_lpv_overlay_active;
            },
            .frustum_debug => {
                ctx.settings.debug_frustum_active = !ctx.settings.debug_frustum_active;
            },
            .occlusion_debug => {
                ctx.settings.debug_occlusion_active = !ctx.settings.debug_occlusion_active;
            },
            .creative_mode => {
                self.session.creative_mode = !self.session.creative_mode;
                self.session.player.setCreativeMode(self.session.creative_mode);
            },
            .time_pause => {
                self.session.atmosphere.time.time_scale = if (self.session.atmosphere.time.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
            },
            .chunk_inspector => {
                self.chunk_inspector_overlay.toggle();
            },
        }
    }

    fn renderOverlay(scene_ctx: render_graph_pkg.SceneContext) void {
        const self: *WorldScreen = @ptrCast(@alignCast(scene_ctx.overlay_ctx.?));
        if (self.session.player.target_block) |target| self.session.block_outline.draw(scene_ctx.render_ctx, target.x, target.y, target.z, scene_ctx.camera.position);
        self.session.renderEntities(scene_ctx.render_ctx, scene_ctx.camera.position);
        self.session.hand_renderer.draw(scene_ctx.render_ctx, scene_ctx.camera.position, scene_ctx.camera.yaw, scene_ctx.camera.pitch);
    }

    fn renderEntityShadowCasters(opaque_ptr: *anyopaque, render_ctx: rhi_pkg.RenderContext, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void {
        const self: *WorldScreen = @ptrCast(@alignCast(opaque_ptr));
        self.session.renderEntityShadowCasters(render_ctx, camera_pos, caster_min, caster_max);
    }
};

const LPVQualityResolved = struct {
    grid_size: u32,
    propagation_iterations: u32,
    update_interval_frames: u32,
};

fn resolveLPVQuality(preset: u32) LPVQualityResolved {
    return switch (preset) {
        0 => .{ .grid_size = 16, .propagation_iterations = 2, .update_interval_frames = 8 },
        2 => .{ .grid_size = 64, .propagation_iterations = 5, .update_interval_frames = 3 },
        else => .{ .grid_size = 32, .propagation_iterations = 3, .update_interval_frames = 6 },
    };
}

fn resolveShadowDebugChannel(settings: *const @import("game-core").settings.data.Settings) u32 {
    return @intFromEnum(@import("game-core").settings.data.resolveShadowDebugChannel(settings));
}
