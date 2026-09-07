//! Integration smoke test for ZigCraft.
//!
//! Tests the full application lifecycle: launch, generate terrain, render a frame, and exit.
//! Requires a display server (use xvfb-run in CI).
//!
//! Run with: zig build test-integration
//! CI: xvfb-run -a zig build test-integration

const std = @import("std");
const testing = std.testing;
const fs = @import("fs");

const App = @import("game/app.zig").App;
const build_options = @import("build_options");

const WorldScreen = @import("game-ui").WorldScreen;
const Screen = @import("game-ui").screen;
const rhi = @import("engine-rhi");
const UISystem = @import("engine-ui").UISystem;
const c = @import("c").c;
const world_core = @import("world-core");
const world_meshing = @import("world-meshing");
const world_runtime = @import("world-runtime");
const SaveManager = @import("world-persistence").SaveManager;

const EngineContext = Screen.EngineContext;
const IScreen = Screen.IScreen;

/// CPU-only world fixture for save/reload integration evidence. Its undefined
/// graphics/streaming members are intentionally never reached: this test uses
/// only the production storage and persistence facade methods.
fn initStorageOnlyPersistenceWorld(allocator: std.mem.Allocator) world_runtime.World {
    return .{
        .storage = world_meshing.ChunkStorage.init(allocator),
        .streamer = undefined,
        .renderer = undefined,
        .allocator = allocator,
        .generator = undefined,
        .render_distance = 8,
        .rhi = undefined,
        .paused = false,
        .safe_mode = false,
        .safe_render_distance = 8,
        .save_manager = null,
        .gpu_block_buffer = null,
        .mutation = undefined,
        .lpv_grid_builder = undefined,
    };
}

fn deinitStorageOnlyPersistenceWorld(world: *world_runtime.World) void {
    if (world.save_manager) |save_manager| {
        save_manager.deinit();
        world.save_manager = null;
    }
    world.storage.deinitWithoutRHI();
}

const UploadScreen = struct {
    context: EngineContext,
    buffer: rhi.BufferHandle,
    payload: [64]u8 = [_]u8{0} ** 64,
    tick: u8 = 0,
    quit_on_draw: bool = false,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*UploadScreen {
        const upload_screen = try allocator.create(UploadScreen);
        const rm = context.render_system.getRHI().resourceManager();
        const buffer = try rm.createBuffer(upload_screen.payload.len, .vertex);
        upload_screen.* = .{ .context = context, .buffer = buffer };
        return upload_screen;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.context.render_system.getRHI().resourceManager().destroyBuffer(self.buffer);
        self.context.allocator.destroy(self);
    }

    fn update(ptr: *anyopaque, _: f32) !void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.payload[0] = self.tick;
        self.tick +%= 1;
        try self.context.render_system.getRHI().resourceManager().updateBuffer(self.buffer, 0, self.payload[0..]);
    }

    fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        ui.begin();
        ui.end();
        if (self.quit_on_draw) self.context.input.setShouldQuit(true);
    }
    pub fn screen(self: *UploadScreen) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

const UploadScreenFactory = struct {
    context: EngineContext,
    result: *?*UploadScreen,

    pub fn construct(self: *@This()) !IScreen {
        const screen = try UploadScreen.init(self.context.allocator, self.context);
        self.result.* = screen;
        return screen.screen();
    }
};

/// Pause-menu analogue: render the world parent, then request a destructive
/// replacement factory during UI drawing. App must submit that frame before it
/// constructs the replacement or destroys the world and its Vulkan resources.
const ReplaceDuringDrawScreen = struct {
    context: EngineContext,
    replacement: ?Screen.ScreenFactory,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext, replacement: Screen.ScreenFactory) !*ReplaceDuringDrawScreen {
        const result = try allocator.create(ReplaceDuringDrawScreen);
        result.* = .{ .context = context, .replacement = replacement };
        return result;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *ReplaceDuringDrawScreen = @ptrCast(@alignCast(ptr));
        if (self.replacement) |replacement| replacement.deinit();
        self.context.allocator.destroy(self);
    }

    fn update(_: *anyopaque, _: f32) !void {}

    fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *ReplaceDuringDrawScreen = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        if (self.replacement) |replacement| {
            self.replacement = null;
            self.context.screen_manager.setScreenFactory(replacement);
        }
    }

    pub fn screen(self: *ReplaceDuringDrawScreen) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

test "smoke test: launch, generate, render, exit" {
    const test_allocator = testing.allocator;

    @import("engine-core").log.log.min_level = .err;

    var app = App.init(test_allocator) catch |err| {
        if (err == error.WindowCreationFailed or err == error.SDLInitializationFailed) {
            std.debug.print("Skipping integration test: SDL/Vulkan initialization failed (likely no display or Vulkan driver)\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();

    const world_screen = try WorldScreen.init(test_allocator, app.engineContext(), 12345, 0);
    app.screen_manager.setScreen(world_screen.screen());

    try app.runSingleFrame();

    // The app consumes the pending transition at the next GPU frame boundary.

    try testing.expect(app.screen_manager.stack.items.len > 0);

    const stats = world_screen.session.world.getStats();

    try testing.expect(stats.chunks_loaded > 0);

    // Runtime World settings are literal live controls, not display-only
    // values capped by the startup preset. Decrease by one so this remains
    // inexpensive even when the local test settings use a large radius.
    const settings = app.engineContext().settings;
    const requested_detail = if (settings.render_distance > 2) settings.render_distance - 1 else settings.render_distance + 1;
    settings.render_distance = requested_detail;
    try app.runSingleFrame();
    try testing.expectEqual(requested_detail, world_screen.session.world.render_distance);

    var upload_screen: ?*UploadScreen = null;
    const upload_factory = try Screen.makeScreenFactory(UploadScreenFactory, test_allocator, .{ .context = app.engineContext(), .result = &upload_screen });
    const replace_during_draw = try ReplaceDuringDrawScreen.init(test_allocator, app.engineContext(), upload_factory);
    app.screen_manager.pushScreen(replace_during_draw.screen());
    try testing.expect(upload_screen == null);

    // The overlay draws the world's menu-safe background, requests replacement
    // during draw, and App applies it only after endFrame. This is the real
    // Quit-to-Title ordering retains the pause overlay until the frame boundary,
    // drains GPU work, then constructs replacement Vulkan resources.
    const fault_count_before_replace = app.render_system.getRHI().query().getFaultCount();
    try app.runSingleFrame();
    const active_upload_screen = upload_screen.?;
    try testing.expectEqual(@as(usize, 1), app.screen_manager.stack.items.len);
    try testing.expect(app.screen_manager.stack.items[0].ptr == @as(*anyopaque, @ptrCast(active_upload_screen)));
    try testing.expectEqual(fault_count_before_replace, app.render_system.getRHI().query().getFaultCount());

    const frame_count = rhi.MAX_FRAMES_IN_FLIGHT + 2;
    for (0..frame_count) |_| {
        try app.runSingleFrame();
    }

    const resize_width: u32 = 1024;
    const resize_height: u32 = 720;
    app.window_manager.setSize(resize_width, resize_height);
    app.input.initWindowSize(app.window_manager.window);
    try app.runSingleFrame();

    var actual_w: c_int = 0;
    var actual_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(app.window_manager.window, &actual_w, &actual_h);
    const extent = app.render_system.getRHI().vulkanHandles().getSwapchainExtent();
    if (!build_options.skip_present) {
        try testing.expectEqual(@as(u32, @intCast(actual_w)), extent[0]);
        try testing.expectEqual(@as(u32, @intCast(actual_h)), extent[1]);
    }

    // A quit event must stop the frame before beginFrame/endFrame. Submitting
    // one final frame while the window system is closing can report device
    // loss on otherwise healthy Vulkan devices.
    const fault_count_before_quit = app.render_system.getRHI().query().getFaultCount();
    var quit_event = std.mem.zeroes(c.SDL_Event);
    quit_event.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    _ = c.SDL_PushEvent(&quit_event);
    try app.runSingleFrame();
    try testing.expect(app.input.interface().shouldQuit());
    try testing.expectEqual(fault_count_before_quit, app.render_system.getRHI().query().getFaultCount());
    app.input.interface().setShouldQuit(false);

    // A quit requested after beginFrame must discard both graphics commands and
    // this screen's pending transfer upload. Teardown immediately follows and
    // must not leave recording command buffers referencing destroyed resources.
    active_upload_screen.quit_on_draw = true;
    const fault_count_before_late_quit = app.render_system.getRHI().query().getFaultCount();
    try app.runSingleFrame();
    try testing.expect(app.input.interface().shouldQuit());
    try testing.expectEqual(fault_count_before_late_quit, app.render_system.getRHI().query().getFaultCount());

    const val_count = app.render_system.getRHI().query().getValidationErrorCount();
    if (val_count > 0) {
        std.debug.print("Integration test finished with {} Vulkan validation errors\n", .{val_count});
    }
    try testing.expectEqual(@as(u32, 0), val_count);
}

test "end-to-end edited terrain survives save reload" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try dir.realpath(".", &path_buf);

    // Persist a real world-owned full-detail chunk, destroy that storage-only
    // world state, then recreate it and reload it.
    var source_world = initStorageOnlyPersistenceWorld(allocator);
    source_world.save_manager = try SaveManager.init(allocator, save_path, "edit-persistence", 923, "integration");
    const edited_data = try source_world.storage.getOrCreate(0, 0);
    edited_data.chunk.generated = true;
    var y: u32 = 0;
    while (y <= 96) : (y += 1) {
        edited_data.chunk.setBlock(0, y, 0, if (y == 96) .grass else .stone);
    }
    source_world.saveAllModifiedChunks();
    try testing.expect(!edited_data.chunk.modified);
    try testing.expectEqual(@as(usize, 0), source_world.takeSaveFailureWarningCount());
    deinitStorageOnlyPersistenceWorld(&source_world);

    var reloaded_world = initStorageOnlyPersistenceWorld(allocator);
    defer deinitStorageOnlyPersistenceWorld(&reloaded_world);
    reloaded_world.save_manager = try SaveManager.init(allocator, save_path, "edit-persistence", 923, "integration");
    var reloaded_chunk = world_core.Chunk.init(0, 0);
    const load_result = reloaded_world.loadChunkFromSave(0, 0, &reloaded_chunk);
    try testing.expect(load_result == .success or load_result == .success_relight_required);
    try testing.expectEqual(world_core.BlockType.grass, reloaded_chunk.getBlock(0, 96, 0));
}
