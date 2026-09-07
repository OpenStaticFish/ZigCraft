const std = @import("std");
const build_options = @import("build_options");
const c = @import("c").c;

const log = @import("engine-core").log;
const WindowManager = @import("engine-core").WindowManager;
const Input = @import("engine-input").Input;
const Time = @import("engine-core").Time;
const UISystemManager = @import("engine-ui").UISystemManager;
const rmlui = @import("engine-ui").rmlui;
const WorldStats = @import("engine-ui").WorldStats;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const InputMapper = @import("game-core").InputMapper;
const RenderSystem = @import("engine-graphics").RenderSystem;
const AudioSystemManager = @import("audio_system_manager.zig").AudioSystemManager;
const BenchmarkRunner = @import("game-core").BenchmarkRunner;
const BENCHMARK_WORLD_SEED = @import("game-core").BENCHMARK_WORLD_SEED;
const json_presets = @import("game-core").settings.json_presets;

const SettingsManager = @import("game-core").SettingsManager;
const Settings = @import("game-core").Settings;
const InputSettings = @import("game-core").InputSettings;
const BuildConfig = @import("game-core").BuildConfig;
const worldgen_registry = @import("world-worldgen").registry;

const screen_pkg = @import("game-ui").screen;
const ScreenManager = screen_pkg.ScreenManager;
const EngineContext = screen_pkg.EngineContext;
const HomeScreen = @import("game-ui").HomeScreen;
const RmlHomeScreen = @import("game-ui").RmlHomeScreen;
const WorldScreen = @import("game-ui").WorldScreen;
const RenderSettingsAdapter = @import("engine-rhi").RenderSettingsAdapter;
const runtime_env = @import("engine-core").runtime_env;
const RHI = @import("engine-rhi").RHI;
pub const BLOCK_TEXTURE_DEFINITIONS = @import("game-core").BLOCK_TEXTURE_DEFINITIONS;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn applySettingsToRhi(ctx: *const anyopaque, rhi: *RHI) void {
    const settings: *const Settings = @ptrCast(@alignCast(ctx));
    @import("game-core").settings.apply_logic.applyToRHI(settings, rhi);
}

fn renderConfigFromSettings(settings: *const Settings) RenderSystem.Config {
    return .{
        .shadow_resolution = settings.getShadowResolution(),
        .msaa_samples = settings.msaa_samples,
        .anisotropic_filtering = settings.anisotropic_filtering,
        .texture_pack = settings.texture_pack,
        .max_texture_resolution = settings.max_texture_resolution,
        .environment_map = settings.environment_map,
        .lpv_grid_size = settings.lpv_grid_size,
        .lpv_cell_size = settings.lpv_cell_size,
        .lpv_intensity = settings.lpv_intensity,
        .lpv_propagation_iterations = settings.lpv_propagation_iterations,
        .lpv_enabled = settings.lpv_enabled,
        .clouds_enabled = settings.clouds_enabled,
        .clouds_3d_enabled = settings.clouds_3d_enabled,
        .cloud_radius = settings.cloud_radius,
        .cloud_density = settings.cloud_density,
        .cloud_height = settings.cloud_height,
        .cloud_thickness = settings.cloud_thickness,
        .cloud_speed_x = settings.cloud_speed_x,
        .cloud_speed_z = settings.cloud_speed_z,
        .taa_enabled = settings.taa_enabled,
        .bloom_enabled = settings.bloom_enabled,
        .bloom_intensity = settings.bloom_intensity,
        .fxaa_enabled = settings.fxaa_enabled,
        .block_textures = &BLOCK_TEXTURE_DEFINITIONS,
        .apply_to_rhi = applySettingsToRhi,
        .apply_context = settings,
    };
}

fn gameBuildConfig() BuildConfig {
    return .{
        .auto_world = build_options.auto_world,
        .chunk_debug_enable = build_options.chunk_debug_enable,
        .chunk_debug_mode = build_options.chunk_debug_mode,
        .screenshot_path = build_options.screenshot_path,
        .shadow_test_scene = build_options.shadow_test_scene,
        .shadow_test_variant = build_options.shadow_test_variant,
        .startup_diagnostic_seconds = build_options.startup_diagnostic_seconds,
    };
}

pub const App = struct {
    const PendingWorldLaunch = struct {
        seed: u64,
        generator_index: usize,
    };

    allocator: std.mem.Allocator,
    window_manager: WindowManager,
    render_system: *RenderSystem,
    audio_manager: *AudioSystemManager,
    settings_manager: SettingsManager,
    input: Input,
    input_mapper: InputMapper,
    time: Time,
    ui_manager: UISystemManager,
    screen_manager: ScreenManager,
    skip_world_update: bool,
    smoke_test_frames: u32 = 0,
    render_settings_adapter: RenderSettingsAdapter,
    resize_debounce_frames: u32 = 0,
    benchmark_runner: ?*BenchmarkRunner = null,
    pending_world_launch: ?PendingWorldLaunch = null,
    startup_world_delay_frames: u32 = 3,
    direct_launch_resize_guard_frames: u32 = 0,
    screenshot_delay_start: ?f32 = null,
    screenshot_settle_frames: u32 = 0,
    frame_start_counter: u64 = 0,
    reveal_window_when_menu_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*App {
        log.log.info("Initializing engine systems...", .{});

        log.log.info("App.init: initializing SettingsManager", .{});
        var settings_manager = try SettingsManager.init(allocator);
        errdefer settings_manager.deinit();

        if (build_options.benchmark) {
            applyBenchmarkSettings(settings_manager.ptr(), build_options.benchmark_preset, build_options.benchmark_render_distance);
        }
        // Benchmark setup owns its render-distance override. Reapplying
        // `auto_preset` here would reset the selected benchmark distance.
        if (build_options.auto_preset.len > 0 and !build_options.benchmark) {
            _ = applyNamedPreset(settings_manager.ptr(), build_options.auto_preset, "AUTO PRESET");
        }
        if (build_options.screenshot_path.len > 0) {
            // Captures are regression artifacts, not a replay of persisted
            // developer visualization toggles.
            settings_manager.settings.wireframe_enabled = false;
        }
        if (build_options.shadow_test_scene) {
            applyShadowTestPreset(settings_manager.ptr());
        }

        const preload_menu_preview = !build_options.skip_present and !build_options.smoke_test and build_options.screenshot_path.len == 0 and !build_options.benchmark and !build_options.shadow_test_scene and resolveAutoWorldGenerator() == null;
        const initial_window_width: u32 = if (build_options.benchmark) 1920 else settings_manager.settings.window_width;
        const initial_window_height: u32 = if (build_options.benchmark) 1080 else settings_manager.settings.window_height;
        log.log.info("App.init: initializing WindowManager ({}x{})", .{ initial_window_width, initial_window_height });
        var wm = try WindowManager.init(allocator, true, initial_window_width, initial_window_height, .{
            .monitor_index = build_options.monitor_index,
            .monitor_name = build_options.monitor_name,
            .video_driver = build_options.window_video_driver,
            .no_focus = build_options.window_no_focus,
            .hidden = build_options.skip_present or preload_menu_preview,
        });
        errdefer wm.deinit();

        var input = Input.init(allocator);
        errdefer input.deinit();
        input.initWindowSize(wm.window);
        const time = Time.init();

        log.log.info("App.init: initializing RenderSystem", .{});
        const render_system = try RenderSystem.init(allocator, wm.window, renderConfigFromSettings(&settings_manager.settings));
        errdefer render_system.deinit();

        const native_extent = render_system.getRHI().renderContext().getNativeSwapchainExtent();
        if (native_extent[0] > 0 and native_extent[1] > 0) {
            input.window_width = native_extent[0];
            input.window_height = native_extent[1];
        }

        const safe_render_env = getenv("ZIGCRAFT_SAFE_RENDER");
        const safe_render_mode = if (safe_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const skip_world_update_env = getenv("ZIGCRAFT_SKIP_WORLD_UPDATE");
        const skip_world_update = safe_render_mode or if (skip_world_update_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (skip_world_update and !safe_render_mode) {
            log.log.warn("ZIGCRAFT_SKIP_WORLD_UPDATE enabled", .{});
        }

        log.log.info("App.init: initializing AudioSystemManager", .{});
        const audio_manager = try AudioSystemManager.init(allocator);
        errdefer audio_manager.deinit();

        log.log.info("App.init: initializing UISystemManager", .{});
        var ui_manager = try UISystemManager.init(allocator, render_system.getRHI().uiRenderer(), render_system.getRHI().resourceManager(), render_system.getRHI(), &wm, input.window_width, input.window_height, build_options.smoke_test);
        errdefer ui_manager.deinit(render_system.getRHI().resourceManager());

        const input_mapper = InputSettings.loadAndReturnMapper(allocator);

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        var benchmark_runner: ?*BenchmarkRunner = null;
        if (build_options.benchmark) {
            // Benchmarks include renderer GPU pass breakdowns.
            render_system.getRHI().timing().setTimingEnabled(true);
            const runner = try allocator.create(BenchmarkRunner);
            const benchmark_duration_s: f32 = @as(f32, @floatFromInt(build_options.benchmark_duration));
            runner.* = try BenchmarkRunner.init(
                allocator,
                build_options.benchmark_preset,
                build_options.benchmark_scenario,
                settings_manager.settings.render_distance,
                benchmark_duration_s,
                BENCHMARK_WORLD_SEED,
                build_options.benchmark_build_mode,
                build_options.benchmark_world,
                build_options.benchmark_output,
            );
            benchmark_runner = runner;
        }

        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .render_system = render_system,
            .audio_manager = audio_manager,
            .settings_manager = settings_manager,
            .input = input,
            .input_mapper = input_mapper,
            .time = time,
            .ui_manager = ui_manager,
            .screen_manager = ScreenManager.init(allocator),
            .skip_world_update = skip_world_update,
            .smoke_test_frames = 0,
            .render_settings_adapter = RenderSettingsAdapter.init(render_system.getRHI()),
            .resize_debounce_frames = 0,
            .benchmark_runner = benchmark_runner,
            .pending_world_launch = null,
            .startup_world_delay_frames = 3,
            .direct_launch_resize_guard_frames = 0,
            .screenshot_delay_start = null,
            .screenshot_settle_frames = 0,
            .frame_start_counter = 0,
            .reveal_window_when_menu_ready = preload_menu_preview,
        };
        errdefer app.screen_manager.deinit();
        // `app` is heap allocated now. Bind the raw event sink only after the
        // final UISystemManager address is stable, avoiding a callback into the
        // temporary manager value used during initialization.
        app.input.setRawEventProcessor(.{ .context = &app.ui_manager, .process = UISystemManager.processRawEvent });

        if (build_options.smoke_test or build_options.screenshot_path.len > 0) {
            app.render_system.getRHI().timing().setTimingEnabled(true);
        }

        if (build_options.shadow_test_scene) {
            log.log.info("SHADOW TEST SCENE: Deferring deterministic test world launch", .{});
            app.pending_world_launch = .{ .seed = 12345, .generator_index = worldgen_registry.findGeneratorIndex("test") orelse 0 };
            if (runtime_env.strictSafeModeAutoEnabled()) app.direct_launch_resize_guard_frames = 240;
        } else if (build_options.screenshot_path.len > 0) {
            if (resolveAutoWorldGenerator()) |generator_index| {
                log.log.info("SCREENSHOT WORLD MODE: Deferring '{s}' world launch for capture to '{s}'", .{ build_options.auto_world, build_options.screenshot_path });
                app.pending_world_launch = .{ .seed = 12345, .generator_index = generator_index };
                if (runtime_env.strictSafeModeAutoEnabled()) app.direct_launch_resize_guard_frames = 240;
            } else {
                log.log.info("SCREENSHOT MODE: Loading menu for screenshot capture to '{s}'", .{build_options.screenshot_path});
                app.screen_manager.setScreen(try app.createHomeScreen());
            }
        } else if (build_options.benchmark) {
            log.log.info("BENCHMARK MODE: Deferring world launch until swapchain settles", .{});
            app.pending_world_launch = .{ .seed = BENCHMARK_WORLD_SEED, .generator_index = 0 };
            if (runtime_env.strictSafeModeAutoEnabled()) app.direct_launch_resize_guard_frames = 240;
        } else if (resolveAutoWorldGenerator()) |generator_index| {
            log.log.info("AUTO WORLD MODE: Deferring '{s}' world launch until swapchain settles", .{build_options.auto_world});
            app.pending_world_launch = .{ .seed = 12345, .generator_index = generator_index };
            if (runtime_env.strictSafeModeAutoEnabled()) app.direct_launch_resize_guard_frames = 240;
        } else if (build_options.smoke_test) {
            log.log.info("SMOKE TEST MODE: Deferring world launch until swapchain settles", .{});
            app.pending_world_launch = .{ .seed = 12345, .generator_index = 0 };
            if (runtime_env.strictSafeModeAutoEnabled()) app.direct_launch_resize_guard_frames = 240;
        } else {
            app.screen_manager.setScreen(try app.createHomeScreen());
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.render_system.waitIdle();

        self.input.setRawEventProcessor(null);
        self.screen_manager.deinit();
        self.ui_manager.deinit(self.render_system.getRHI().resourceManager());
        if (self.benchmark_runner) |runner| {
            runner.deinit();
            self.allocator.destroy(runner);
        }
        self.audio_manager.deinit();
        self.render_system.deinit();
        self.settings_manager.deinit();

        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn engineContext(self: *App) EngineContext {
        return .{
            .allocator = self.allocator,
            .window_manager = &self.window_manager,
            .render_system = self.render_system,
            .audio_system = self.audio_manager.audio_system,
            .ui_manager = &self.ui_manager,
            .settings = self.settings_manager.ptr(),
            .input = self.input.interface(),
            .input_mapper = self.input_mapper.interface(),
            .time = &self.time,
            .screen_manager = &self.screen_manager,
            .skip_world_update = self.skip_world_update,
            .render_settings = self.render_settings_adapter.interface(),
            .benchmark_runner = self.benchmark_runner,
            .build_config = gameBuildConfig(),
        };
    }

    pub fn saveAllSettings(self: *const App) void {
        self.settings_manager.save() catch |err| {
            log.log.errWithTrace("Failed to save game settings: {}", .{err});
        };
        InputSettings.saveFromMapper(self.allocator, self.input_mapper.interface()) catch |err| {
            log.log.errWithTrace("Failed to save input settings: {}", .{err});
        };
    }

    fn getWorldStats(self: *const App) ?WorldStats {
        if (self.screen_manager.stack.items.len == 0) return null;
        const top = self.screen_manager.stack.getLast();
        return top.getWorldStats();
    }

    fn maybeLaunchPendingWorld(self: *App, swapchain_extent: [2]u32) !void {
        const pending = self.pending_world_launch orelse return;
        if (self.screen_manager.stack.items.len != 0) return;

        const window_width = self.input.interface().getWindowWidth();
        const window_height = self.input.interface().getWindowHeight();
        if (window_width == 0 or window_height == 0) return;
        if (self.resize_debounce_frames > 0) return;
        if (swapchain_extent[0] == 0 or swapchain_extent[1] == 0) return;
        if (window_width != swapchain_extent[0] or window_height != swapchain_extent[1]) return;

        if (self.startup_world_delay_frames > 0) {
            self.startup_world_delay_frames -= 1;
            return;
        }

        log.log.info("PENDING WORLD LAUNCH: creating world after swapchain settled at {}x{}", .{ swapchain_extent[0], swapchain_extent[1] });
        const world_screen = WorldScreen.init(self.allocator, self.engineContext(), pending.seed, pending.generator_index) catch |err| {
            log.log.err("PENDING WORLD LAUNCH FAILED (seed={}, generator_index={}): {} - returning to home screen", .{ pending.seed, pending.generator_index, err });
            self.pending_world_launch = null;
            self.direct_launch_resize_guard_frames = 0;
            self.resize_debounce_frames = 0;
            const home_screen = self.createHomeScreen() catch |home_err| {
                log.log.err("Failed to initialize home screen after world launch failure: {}", .{home_err});
                return home_err;
            };
            self.screen_manager.setScreen(home_screen);
            return;
        };
        self.screen_manager.setScreen(world_screen.screen());
        self.pending_world_launch = null;
        self.direct_launch_resize_guard_frames = 0;
        self.resize_debounce_frames = 0;
        self.render_system.getRHI().renderContext().requestSwapchainRecreate();
    }

    fn createHomeScreen(self: *App) !screen_pkg.IScreen {
        if (rmlui.available and self.ui_manager.getRmlUi() != null) {
            const screen = try RmlHomeScreen.init(self.allocator, self.engineContext());
            return screen.screen();
        }
        const screen = try HomeScreen.init(self.allocator, self.engineContext());
        return screen.screen();
    }

    fn applyPendingScreenTransitions(self: *App) !void {
        if (!self.screen_manager.hasPendingTransition()) return;

        // Screen factories and destructors can load/close RmlUi documents and
        // create/destroy complete world render resources. A submitted frame is
        // still allowed to reference those resources after endFrame returns, so
        // a command-recording boundary alone is insufficient. Drain in-flight
        // GPU work before resolving any ownership-changing transition.
        self.render_system.waitIdle();
        try self.screen_manager.applyPendingTransitions();
    }

    pub fn runSingleFrame(self: *App) !void {
        self.frame_start_counter = c.SDL_GetPerformanceCounter();
        self.time.update();
        if (!build_options.benchmark) {
            self.audio_manager.update();
        }

        self.input.beginFrame();
        self.input.pollEvents();
        self.ui_manager.handleTimingToggle(
            self.input_mapper.isActionPressed(self.input.interface(), .toggle_timing_overlay),
            &self.time,
            self.render_system.getRHI(),
        );
        // Do not record and submit one more frame after SDL reports that the
        // window is closing. On some WSI/driver paths that final submission
        // races surface teardown and returns VK_ERROR_DEVICE_LOST.
        if (self.input.interface().shouldQuit()) return;

        // Screen replacement destroys the old world/session. Keep that
        // ownership change outside a recording Vulkan frame; a device idle wait
        // cannot sanitize unsubmitted command buffers.
        try self.applyPendingScreenTransitions();

        const swapchain_extent = self.render_system.getRHI().renderContext().getNativeSwapchainExtent();
        if (build_options.skip_present and swapchain_extent[0] > 0 and swapchain_extent[1] > 0) {
            self.input.window_width = swapchain_extent[0];
            self.input.window_height = swapchain_extent[1];
        }
        if (self.direct_launch_resize_guard_frames > 0 and swapchain_extent[0] > 0 and swapchain_extent[1] > 0) {
            self.direct_launch_resize_guard_frames -= 1;
            self.input.window_width = swapchain_extent[0];
            self.input.window_height = swapchain_extent[1];
        }

        const window_width = self.input.interface().getWindowWidth();
        const window_height = self.input.interface().getWindowHeight();
        if (!build_options.skip_present and self.direct_launch_resize_guard_frames == 0) {
            if (self.resize_debounce_frames > 0) {
                self.resize_debounce_frames -= 1;
            } else if (window_width > 0 and window_height > 0 and (window_width != swapchain_extent[0] or window_height != swapchain_extent[1])) {
                self.render_system.getRHI().renderContext().requestSwapchainRecreate();
                self.resize_debounce_frames = 2;
            } else if (window_width == swapchain_extent[0] and window_height == swapchain_extent[1]) {
                self.resize_debounce_frames = 0;
            }
        }

        try self.maybeLaunchPendingWorld(swapchain_extent);

        // UI geometry is rendered in swapchain pixels. SDL input dimensions can
        // remain logical on HiDPI desktops, which previously confined RmlUi to
        // the top-left quarter of the framebuffer.
        const ui_width = if (swapchain_extent[0] > 0) swapchain_extent[0] else window_width;
        const ui_height = if (swapchain_extent[1] > 0) swapchain_extent[1] else window_height;
        self.ui_manager.resize(ui_width, ui_height);

        self.render_system.setViewport(window_width, window_height);

        self.render_system.beginFrame();
        var frame_open = true;
        defer if (frame_open) self.render_system.abortFrame();

        try self.render_system.updateGlobalUniforms(.{
            .view_proj = Mat4.identity,
            .cam_pos = Vec3.zero,
            .sun_dir = Vec3.init(0, -1, 0),
            .sun_color = Vec3.one,
            .time = 0,
            .fog_color = Vec3.zero,
            .fog_density = 0,
            .fog_enabled = false,
            .sun_intensity = 1.0,
            .ambient = 0.1,
            .use_texture = false,
        }, .{
            .cam_pos = Vec3.zero,
            .view_proj = Mat4.identity,
            .sun_dir = Vec3.init(0, -1, 0),
            .sun_intensity = 1.0,
            .fog_color = Vec3.zero,
            .fog_density = 0,
            .pbr_enabled = false,
            .shadow = .{ .distance = 100, .resolution = 1024, .pcf_samples = 1, .cascade_blend = false },
            .pbr_quality = 0,
            .exposure = 1.0,
            .saturation = 1.0,
            .volumetric_enabled = false,
            .volumetric_density = 0,
            .volumetric_steps = 0,
            .volumetric_scattering = 0,
            .ssao_enabled = false,
            .lpv_enabled = false,
            .lpv_intensity = 0,
            .lpv_cell_size = 2.0,
            .lpv_grid_size = 32,
            .lpv_origin = Vec3.zero,
        });

        try self.screen_manager.updateCurrent(self.time.delta_time);

        // Screen updates can request shutdown (for example, a bounded startup
        // diagnostic). Discard commands recorded so far instead of submitting
        // a final frame after shutdown has begun.
        if (self.input.interface().shouldQuit()) return;

        if (self.screen_manager.stack.items.len == 0) {
            self.render_system.endFrame();
            frame_open = false;
            try self.applyPendingScreenTransitions();
            return;
        }

        const world_stats = self.getWorldStats();
        const cpu_ms = self.time.delta_time * 1000.0;
        try self.ui_manager.draw(&self.screen_manager, self.render_system.getRHI(), world_stats, cpu_ms, self.time.fps);

        // The legacy immediate-mode menu resolves its Exit action while
        // drawing. Never submit that frame after the action requests quit.
        if (self.input.interface().shouldQuit()) return;

        // Capture is recorded before endFrame so Vulkan appends its copy after
        // the UI pass, but before normal presentation releases the image.
        var finish_screenshot_run = false;
        if (build_options.smoke_test or build_options.screenshot_path.len > 0) {
            self.smoke_test_frames += 1;
            const requires_world_ready = build_options.shadow_test_scene or build_options.auto_world.len > 0;
            const world_ready = if (world_stats) |stats|
                self.pending_world_launch == null and stats.chunks_rendered > 0 and stats.gen_queue == 0 and stats.mesh_queue == 0 and stats.upload_queue == 0
            else
                false;
            // The world statistics can settle one frame before the render graph
            // has emitted its first scene draw. Require a rendered frame as
            // well; otherwise the headless UI-only fallback clears the output
            // black and a screenshot can race that transient frame.
            const rendered_frame = self.render_system.getRHI().query().getDrawCallCount() > 0;
            if ((!requires_world_ready or world_ready) and (!requires_world_ready or rendered_frame)) {
                self.screenshot_settle_frames += 1;
            } else {
                self.screenshot_settle_frames = 0;
            }
            var target_frames: u32 = 120;
            if (build_options.screenshot_path.len > 0) {
                target_frames = build_options.screenshot_frame;
            }
            if (getenv("ZIGCRAFT_SMOKE_FRAMES")) |val| {
                if (std.fmt.parseInt(u32, val, 10)) |parsed| {
                    target_frames = parsed;
                } else |_| {}
            }

            const capture_ready = self.smoke_test_frames >= target_frames and self.screenshot_settle_frames >= 30;
            const screenshot_delay_ready = build_options.screenshot_path.len > 0 and build_options.screenshot_delay_seconds > 0;
            const should_finish = if (screenshot_delay_ready and capture_ready) blk: {
                // A delay is additional settling time, not a replacement for
                // readiness. The old branch captured after wall time alone,
                // often while the auto world was still displaying its black
                // loading frame in unthrottled headless runs.
                const start = self.screenshot_delay_start orelse start: {
                    self.screenshot_delay_start = self.time.elapsed;
                    break :start self.time.elapsed;
                };
                const delay_s: f32 = @floatFromInt(build_options.screenshot_delay_seconds);
                break :blk self.time.elapsed - start >= delay_s;
            } else capture_ready and !screenshot_delay_ready;

            // Headless frames are intentionally unthrottled. A frame-count
            // timeout can therefore expire before generation workers receive
            // meaningful CPU time; use a wall-time bound instead.
            if (build_options.screenshot_path.len > 0 and requires_world_ready and self.time.elapsed >= 90.0 and !capture_ready) {
                return error.ScreenshotWorldNotReady;
            }

            if (should_finish) {
                if (build_options.screenshot_path.len > 0) {
                    log.log.info("SCREENSHOT: Requesting final composed frame to '{s}'", .{build_options.screenshot_path});
                    if (!self.render_system.getRHI().screenshot().captureFrame(build_options.screenshot_path)) {
                        log.log.err("SCREENSHOT: Failed to request screenshot", .{});
                        return error.ScreenshotCaptureFailed;
                    }
                }
                finish_screenshot_run = true;
            }
        }

        // Screenshot requests must reach the RHI while this frame's command
        // buffer is still open. Vulkan records the readback after its final
        // output pass and before submission/presentation.
        self.render_system.endFrame();
        frame_open = false;
        try self.applyPendingScreenTransitions();
        self.revealMenuWindowWhenReady();

        if (build_options.benchmark) {
            if (self.benchmark_runner) |runner| {
                const gpu_timing = self.render_system.getRHI().timing().getTimingResults();
                const rhi = self.render_system.getRHI();
                const draw_calls = rhi.query().getDrawCallCount();
                const gpu_memory_mb = if (rhi.device) |device| gpuMemoryMb(device.getStats()) else 0;
                try runner.recordFrame(self.time.delta_time, self.time.fps, gpu_timing, world_stats, draw_calls, gpu_memory_mb);

                if (runner.isComplete()) {
                    try runner.writeResults();
                    log.log.info("BENCHMARK COMPLETE: {} frames written to '{s}'", .{ runner.samples.items.len, runner.output_path });
                    self.input.should_quit = true;
                }
            }
        }

        if (finish_screenshot_run) {
            log.log.info("SMOKE TEST COMPLETE: frame rendered and screenshot submitted. Exiting.", .{});
            self.input.should_quit = true;
        }

        self.limitFrameRateIfNeeded();
    }

    fn revealMenuWindowWhenReady(self: *App) void {
        if (!self.reveal_window_when_menu_ready or !self.screen_manager.isReadyForPresentation()) return;
        log.log.info("MENU PREVIEW READY: revealing preloaded window", .{});
        self.window_manager.show();
        self.reveal_window_when_menu_ready = false;
    }

    fn limitFrameRateIfNeeded(self: *App) void {
        if (build_options.benchmark or build_options.skip_present) return;

        const settings = self.settings_manager.settings;
        if (settings.vsync or settings.target_fps == 0) return;

        const target_ns = @divFloor(std.time.ns_per_s, @as(u64, settings.target_fps));
        const now = c.SDL_GetPerformanceCounter();
        if (now <= self.frame_start_counter) return;

        const freq = c.SDL_GetPerformanceFrequency();
        const elapsed_counts = now - self.frame_start_counter;
        const elapsed_ns = @divFloor(elapsed_counts * std.time.ns_per_s, freq);
        if (elapsed_ns >= target_ns) return;

        std.Options.debug_io.sleep(.fromNanoseconds(target_ns - elapsed_ns), .boot) catch {};
    }

    pub fn run(self: *App) !void {
        self.render_system.setViewport(self.input.interface().getWindowWidth(), self.input.interface().getWindowHeight());
        log.log.info("=== ZigCraft ===", .{});
        var last_fault_count: u32 = self.render_system.getRHI().query().getFaultCount();
        var gpu_recovery_attempts: u32 = 0;
        while (!self.input.interface().shouldQuit()) {
            self.runSingleFrame() catch |err| {
                log.log.err("Frame error: {}", .{err});
                return err;
            };
            const current_faults = self.render_system.getRHI().query().getFaultCount();
            if (current_faults > last_fault_count) {
                gpu_recovery_attempts += 1;
                last_fault_count = current_faults;
                if (gpu_recovery_attempts > 3) {
                    log.log.err("GPU lost after {d} recovery attempts. Exiting.", .{gpu_recovery_attempts});
                    return error.GpuLost;
                }
                log.log.warn("GPU fault detected (total faults: {d}), attempting recovery ({d}/3)...", .{ current_faults, gpu_recovery_attempts });
                self.render_system.getRHI().recovery().recover() catch {
                    log.log.err("GPU recovery failed. Exiting.", .{});
                    return error.GpuLost;
                };
                log.log.info("GPU recovery step completed.", .{});
            }
        }

        if (build_options.smoke_test) {
            const validation_errors = self.render_system.getRHI().query().getValidationErrorCount();
            if (validation_errors > 0) {
                log.log.err("Smoke test finished with {d} Vulkan validation errors", .{validation_errors});
                return error.VulkanValidationFailed;
            }
        }
    }
};

fn applyBenchmarkPreset(settings: *Settings, preset_name: []const u8) void {
    if (applyNamedPreset(settings, preset_name, "BENCHMARK")) {
        settings.vsync = false;
    }
}

/// Apply the preset first, then explicit benchmark render distance.
fn applyBenchmarkSettings(settings: *Settings, preset_name: []const u8, render_distance: i32) void {
    applyBenchmarkPreset(settings, preset_name);
    if (render_distance > 0) {
        settings.render_distance = render_distance;
    }
}

test "benchmark render distance override is retained after its preset" {
    var settings = Settings{};
    applyBenchmarkSettings(&settings, "high", 12);
    try std.testing.expectEqual(@as(i32, 12), settings.render_distance);
}

fn gpuMemoryMb(stats: @import("engine-rhi").Stats) f32 {
    const bytes = stats.total_buffer_memory + stats.total_texture_memory;
    return @as(f32, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn applyNamedPreset(settings: *Settings, preset_name: []const u8, label: []const u8) bool {
    if (json_presets.findAndApplyNamed(settings, preset_name)) |applied_name| {
        log.log.info("{s}: Applied graphics preset '{s}'", .{ label, applied_name });
        return true;
    }

    log.log.warn("{s}: Unknown preset '{s}', keeping loaded settings", .{ label, preset_name });
    return false;
}

fn applyShadowTestPreset(settings: *Settings) void {
    settings.window_width = 1280;
    settings.window_height = 720;
    settings.render_distance = 4;
    settings.shadow_sandbox_enabled = true;
    settings.shadow_beauty_enabled = true;
    settings.shadow_quality = 2;
    settings.shadow_distance = 120.0;
    settings.shadow_caster_distance = 120.0;
    settings.shadow_pcf_samples = 1;
    settings.shadow_cascade_blend = false;
    settings.pbr_enabled = false;
    settings.volumetric_lighting_enabled = false;
    settings.ssao_enabled = false;
    settings.lpv_enabled = false;
    settings.taa_enabled = false;
    settings.fxaa_enabled = false;
    settings.bloom_enabled = false;
    settings.vignette_enabled = false;
    settings.film_grain_enabled = false;
}

fn resolveAutoWorldGenerator() ?usize {
    if (build_options.shadow_test_scene) return worldgen_registry.findGeneratorIndex("test") orelse 0;
    if (build_options.auto_world.len == 0) return null;
    if (worldgen_registry.findGeneratorIndex(build_options.auto_world)) |index| return index;

    log.log.warn("Unknown -Dauto-world value '{s}', defaulting to overworld", .{build_options.auto_world});
    return worldgen_registry.findGeneratorIndex("overworld") orelse 0;
}
