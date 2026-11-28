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
    overwrite_upload: bool = false,
    indirect_draw: ?struct { vertices: rhi.BufferHandle, command: rhi.BufferHandle } = null,
    overwrite_indirect: ?rhi.BufferHandle = null,
    culling: ?rhi.ICullingSystem = null,
    water_vertices: ?rhi.BufferHandle = null,
    screenshot_path: ?[]const u8 = null,
    resize_during_draw: bool = false,
    quit_on_draw: bool = false,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*UploadScreen {
        const upload_screen = try allocator.create(UploadScreen);
        const rm = context.render_system.getRHI().resourceManager();
        const buffer = try rm.createBuffer(upload_screen.payload.len, .storage);
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
        // Reuse the previous submitted range in the skipped-frame test,
        // then overwrite it again within the same upload batch.
        const offset = (if (self.overwrite_upload) self.tick -% 1 else self.tick) % self.payload.len;
        self.tick +%= 1;
        self.payload[offset] = self.tick;
        try self.context.render_system.getRHI().resourceManager().updateBuffer(self.buffer, offset, self.payload[offset..][0..1]);
        if (self.overwrite_upload) {
            self.payload[offset] +%= 100;
            try self.context.render_system.getRHI().resourceManager().updateBuffer(self.buffer, offset, self.payload[offset..][0..1]);
        }
        if (self.overwrite_indirect) |command| {
            try self.context.render_system.getRHI().resourceManager().updateBuffer(command, 0, &.{0xcd});
        }
    }

    fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        const vk: *@import("engine-graphics").VulkanContext = @ptrCast(@alignCast(self.context.render_system.rhi.ptr));
        const slot = vk.frames.current_frame;
        if (self.culling) |culling| {
            culling.updateAABBData(slot, &.{.{ .min_point = .{ 0, 0, 0, 0 }, .max_point = .{ 0, 0, 0, 0 } }});
            culling.dispatch(.{
                .view_proj = .{ .data = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } } },
                .chunk_count = 1,
            });
        }
        // A pyramid request without a G-pass must not sample unwritten depth,
        // including on the first frame after swapchain recreation.
        self.context.render_system.getRHI().postProcess().computeDepthPyramid();
        self.context.render_system.getRHI().ssao().compute(.identity, .identity);
        if (self.indirect_draw) |indirect| {
            const render = self.context.render_system.getRHI().renderContext();
            render.setInstanceBuffer(self.buffer);
            render.drawIndirect(indirect.vertices, indirect.command, 0, 1, @sizeOf(c.VkDrawIndirectCommand));
        }
        if (self.water_vertices) |vertices| {
            const gpu = self.context.render_system.getRHI();
            const render = gpu.renderContext();
            const water = gpu.water();
            render.beginGPass();
            render.endGPass();
            gpu.ssao().compute(.identity, .identity);
            water.beginReflectionPass();
            water.endReflectionPass();
            render.setInstanceBuffer(self.buffer);
            render.beginMainPass();
            try testing.expect(render.beginWaterDraw(water.getReflectionTextureHandle(), water.getSceneDepthTextureHandle()));
            render.setModelMatrix(.identity, .one);
            render.draw(vertices, 3, .triangles);
            render.endWaterDraw();
            render.endMainPass();
        }
        ui.begin();
        ui.end();
        if (self.screenshot_path) |path| {
            try testing.expect(self.context.render_system.getRHI().screenshot().captureFrame(path));
        }
        if (self.resize_during_draw) self.context.render_system.getRHI().context().requestSwapchainRecreate();
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

fn skipGraphicsFrame(_: *anyopaque) anyerror!bool {
    return false;
}

fn timeOutImageAcquire(_: c.VkDevice, _: c.VkSwapchainKHR, _: u64, _: c.VkSemaphore, _: c.VkFence, _: [*c]u32) callconv(.c) c.VkResult {
    return c.VK_TIMEOUT;
}

fn failGraphicsSubmit(_: *@import("engine-graphics").VulkanDevice, _: c.VkSubmitInfo, _: c.VkFence) anyerror!void {
    return error.OutOfMemory;
}

fn failUploadSubmit(_: c.VkQueue, _: u32, _: [*c]const c.VkSubmitInfo, _: c.VkFence) callconv(.c) c.VkResult {
    return c.VK_ERROR_OUT_OF_HOST_MEMORY;
}

fn failLayoutWait(_: c.VkQueue) callconv(.c) c.VkResult {
    return c.VK_ERROR_OUT_OF_HOST_MEMORY;
}

var teardown_wait_attempts: usize = 0;

fn failFirstTeardownWait(device: c.VkDevice) callconv(.c) c.VkResult {
    teardown_wait_attempts += 1;
    if (teardown_wait_attempts == 1) return c.VK_ERROR_OUT_OF_HOST_MEMORY;
    return c.vkDeviceWaitIdle(device);
}

fn failPresentation(_: c.VkQueue, _: [*c]const c.VkPresentInfoKHR) callconv(.c) c.VkResult {
    return c.VK_ERROR_OUT_OF_HOST_MEMORY;
}

fn loseGraphicsDevice(_: *anyopaque) anyerror!bool {
    return error.GpuLost;
}

fn unexpectedFrameCompletion(_: *anyopaque) void {
    unreachable;
}

fn unexpectedFrameSubmission(_: *anyopaque) anyerror!void {
    unreachable;
}

fn readUploadedByte(vulkan: *@import("engine-graphics").VulkanContext, handle: rhi.BufferHandle, offset: usize) !u8 {
    const utils = @import("engine-graphics").vulkan_utils;
    const device = vulkan.vulkan_device.vk_device;
    const src = vulkan.resources.buffers.get(handle).?;
    const dst = try utils.createVulkanBuffer(&vulkan.vulkan_device, 1, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    defer c.vkFreeMemory(device, dst.memory, null);
    defer c.vkDestroyBuffer(device, dst.buffer, null);
    defer c.vkUnmapMemory(device, dst.memory);

    const pool = vulkan.frames.command_pool;
    const alloc = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var cmd: c.VkCommandBuffer = null;
    try utils.checkVk(c.vkAllocateCommandBuffers(device, &alloc, &cmd));
    defer c.vkFreeCommandBuffers(device, pool, 1, &cmd);
    const begin = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    try utils.checkVk(c.vkBeginCommandBuffer(cmd, &begin));
    const upload_to_copy = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
    };
    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &upload_to_copy, 0, null, 0, null);
    const region = c.VkBufferCopy{ .srcOffset = offset, .dstOffset = 0, .size = 1 };
    c.vkCmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &region);
    const host_read = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_HOST_READ_BIT,
    };
    c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &host_read, 0, null, 0, null);
    try utils.checkVk(c.vkEndCommandBuffer(cmd));
    const submit = c.VkSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    const fence_info = c.VkFenceCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    var fence: c.VkFence = null;
    try utils.checkVk(c.vkCreateFence(device, &fence_info, null, &fence));
    defer c.vkDestroyFence(device, fence, null);
    try vulkan.vulkan_device.submitGuarded(submit, fence);
    const waited = c.vkWaitForFences(device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));
    if (waited != c.VK_SUCCESS and waited != c.VK_ERROR_DEVICE_LOST) {
        const drained = c.vkDeviceWaitIdle(device);
        if (drained != c.VK_SUCCESS and drained != c.VK_ERROR_DEVICE_LOST) {
            std.debug.panic("Cannot safely retire test readback: Vulkan returned {}", .{drained});
        }
    }
    try utils.checkVk(waited);
    const mapped: *const u8 = @ptrCast(dst.mapped_ptr.?);
    return mapped.*;
}

test "smoke test: launch, generate, render, exit" {
    const test_allocator = testing.allocator;

    @import("engine-core").log.log.min_level = .err;

    var app = App.init(test_allocator) catch |err| {
        if (std.c.getenv("ZIGCRAFT_ALLOW_MISSING_TEST_DISPLAY") != null and
            (err == error.WindowCreationFailed or err == error.SDLInitializationFailed))
        {
            std.debug.print("Skipping integration test: SDL/Vulkan initialization failed (likely no display or Vulkan driver)\n", .{});
            return;
        }
        return err;
    };
    var app_deinitialized = false;
    defer if (!app_deinitialized) app.deinit();
    if (!build_options.skip_present) app.window_manager.show();

    const graphics = @import("engine-graphics");
    const vulkan: *graphics.VulkanContext = @ptrCast(@alignCast(app.render_system.rhi.ptr));
    if (build_options.skip_present) {
        for ([_]@TypeOf(vulkan.init_failure){ .resources, .frames }) |failure| {
            const partial = try graphics.rhi_vulkan.createRHI(test_allocator, app.window_manager.window, null, 256, 1, 1, true);
            defer partial.deinit();
            const context: *graphics.VulkanContext = @ptrCast(@alignCast(partial.ptr));
            context.init_failure = failure;
            try testing.expectError(error.OutOfMemory, partial.init(test_allocator, null));
            try testing.expect(context.vulkan_device.vk_device != null);
        }
    }

    const world_screen = try WorldScreen.init(test_allocator, app.engineContext(), 12345, 0);
    app.screen_manager.setScreen(world_screen.screen());

    try app.runSingleFrame();

    // The app consumes the pending transition at the next GPU frame boundary.

    try testing.expect(app.screen_manager.stack.items.len > 0);

    const stats = world_screen.session.world.getStats();

    try testing.expect(stats.chunks_loaded > 0);
    try testing.expect(app.render_system.getRHI().query().getDrawCallCount() > 0);

    // Runtime World settings are literal live controls, not display-only
    // values capped by the startup preset. Decrease by one so this remains
    // inexpensive even when the local test settings use a large radius.
    const settings = app.engineContext().settings;
    const requested_detail = if (settings.render_distance > 2) settings.render_distance - 1 else settings.render_distance + 1;
    settings.render_distance = requested_detail;
    try app.runSingleFrame();
    try testing.expectEqual(requested_detail, world_screen.session.world.render_distance);

    if (build_options.skip_present and app.render_system.g_pass.enabled) {
        const old_taa = settings.taa_enabled;
        const old_ssao = settings.ssao_enabled;
        const old_taa_pass = app.render_system.taa_pass.enabled;
        defer settings.taa_enabled = old_taa;
        defer settings.ssao_enabled = old_ssao;
        defer app.render_system.taa_pass.enabled = old_taa_pass;
        settings.taa_enabled = true;
        settings.ssao_enabled = false;
        app.render_system.taa_pass.enabled = true;
        for (0..3) |frame| {
            if (frame == 1) app.render_system.rhi.context().requestSwapchainRecreate();
            try app.runSingleFrame();
            try testing.expect(vulkan.runtime.g_pass_depth_ready);
            try testing.expect(vulkan.taa.ran_this_frame);
        }
    }

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
    // An upload immediately after submission must not reset a pending command
    // buffer. Use a byte outside the screen's rotating test writes.
    try app.render_system.getRHI().resourceManager().updateBuffer(active_upload_screen.buffer, 63, &.{0xab});

    {
        const culling = (try app.render_system.getRHI().createCullingSystem(test_allocator, 1)) orelse return error.MissingCullingSystem;
        defer culling.deinit();
        defer app.render_system.waitIdle();
        active_upload_screen.culling = culling;
        defer active_upload_screen.culling = null;

        const dispatch_frame = vulkan.runtime.frame_index;
        const slot_before = vulkan.frames.current_frame;
        try app.runSingleFrame();
        try testing.expectEqual(dispatch_frame + 1, vulkan.runtime.frame_index);
        app.render_system.getRHI().context().requestSwapchainRecreate();
        const slot_after = vulkan.frames.current_frame;
        try app.runSingleFrame();
        try testing.expectEqual(dispatch_frame + 2, vulkan.runtime.frame_index);
        app.render_system.waitIdle();
        try testing.expectEqual(@as(u32, 1), culling.readVisibleCount(slot_before));
        try testing.expectEqual(@as(u32, 1), culling.readVisibleCount(slot_after));
    }
    try testing.expectEqual(@as(u8, 0xab), try readUploadedByte(vulkan, active_upload_screen.buffer, 63));

    // Read from one frame's graphics submission, then overwrite the same
    // range in the next frame's transfer batch without draining the queue.
    {
        const resources = app.render_system.getRHI().resourceManager();
        const vertices = try resources.createBuffer(64, .vertex);
        defer resources.destroyBuffer(vertices);
        const command = try resources.createBuffer(@sizeOf(c.VkDrawIndirectCommand), .indirect);
        defer resources.destroyBuffer(command);
        defer app.render_system.waitIdle();
        defer active_upload_screen.indirect_draw = null;
        defer active_upload_screen.overwrite_indirect = null;

        // Zero vertices: the GPU still fetches the indirect command.
        const empty_draw: [@sizeOf(c.VkDrawIndirectCommand)]u8 = @splat(0);
        try resources.updateBuffer(command, 0, &empty_draw);
        const read_frame = vulkan.runtime.frame_index;
        active_upload_screen.indirect_draw = .{ .vertices = vertices, .command = command };
        try app.runSingleFrame();
        try testing.expectEqual(read_frame + 1, vulkan.runtime.frame_index);
        active_upload_screen.indirect_draw = null;
        active_upload_screen.overwrite_indirect = command;
        try app.runSingleFrame();
        try testing.expectEqual(read_frame + 2, vulkan.runtime.frame_index);
        try testing.expectEqual(@as(u8, 0xcd), try readUploadedByte(vulkan, command, 0));
    }

    {
        const resources = app.render_system.getRHI().resourceManager();
        const positions = [_][3]f32{ .{ -0.8, -0.8, 0.5 }, .{ 0.8, -0.8, 0.5 }, .{ 0, 0.8, 0.5 } };
        var water_triangle: [positions.len]rhi.Vertex = undefined;
        for (&water_triangle, positions) |*vertex, position| {
            vertex.* = rhi.Vertex.init(position, .{ 1, 1, 1 }, .{ 0, 1, 0 }, .{ 0, 0 }, 0, 1, .{ 0, 0, 0 }, 1);
        }
        const vertices = try resources.createBuffer(@sizeOf(@TypeOf(water_triangle)), .vertex);
        defer resources.destroyBuffer(vertices);
        try resources.updateBuffer(vertices, 0, std.mem.asBytes(&water_triangle));
        active_upload_screen.water_vertices = vertices;
        defer active_upload_screen.water_vertices = null;
        const first_frame = vulkan.runtime.frame_index;
        try app.runSingleFrame();
        try app.runSingleFrame();
        try testing.expectEqual(first_frame + 2, vulkan.runtime.frame_index);
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

    // Simulate a skipped acquire after successful frames. The screen still
    // updates, but its draw and the frame-completion callbacks must not run.
    // A normal frame has submitted the upload screen's copy. A subsequent
    // upload in the same slot must not replay that batch.
    try testing.expectEqual(@as(usize, 0), vulkan.resources.transfer.pendingCopyCount());
    try testing.expectEqual(@as(c.VkAccessFlags, 0), vulkan.resources.transfer.getPendingDstAccessMask());
    if (!build_options.skip_present) {
        const acquired_frame_slot = vulkan.frames.current_frame;
        const tick = active_upload_screen.tick;
        const acquire = vulkan.swapchain.acquire_image;
        {
            vulkan.swapchain.acquire_image = &timeOutImageAcquire;
            defer vulkan.swapchain.acquire_image = acquire;
            try app.runSingleFrame();
        }
        try testing.expectEqual(acquired_frame_slot, vulkan.frames.current_frame);
        try testing.expectEqual(tick +% 1, active_upload_screen.tick);
        try testing.expect(!app.input.interface().shouldQuit());
        active_upload_screen.quit_on_draw = false;
        try app.runSingleFrame();
        try testing.expect(acquired_frame_slot != vulkan.frames.current_frame);
        active_upload_screen.quit_on_draw = true;
    }
    const skipped_tick = active_upload_screen.tick;
    {
        app.render_system.waitIdle();
        const original_vtable = app.render_system.rhi.vtable;
        var render_vtable = original_vtable.render.?.*;
        render_vtable.beginFrame = skipGraphicsFrame;
        render_vtable.endFrame = unexpectedFrameSubmission;
        render_vtable.abortFrame = unexpectedFrameCompletion;
        var skipped_vtable = original_vtable.*;
        skipped_vtable.render = &render_vtable;
        app.render_system.rhi.vtable = &skipped_vtable;
        defer app.render_system.rhi.vtable = original_vtable;

        const previous_tick = active_upload_screen.tick;
        active_upload_screen.overwrite_upload = true;
        defer active_upload_screen.overwrite_upload = false;
        try app.runSingleFrame();
        try testing.expectEqual(previous_tick +% 1, active_upload_screen.tick);
        try testing.expect(!app.input.interface().shouldQuit());

        render_vtable.beginFrame = loseGraphicsDevice;
        try testing.expectError(error.GpuLost, app.runSingleFrame());
    }

    // Exercise the real Vulkan frame-start guard with the state left by a
    // failed rebuild. A new recreation request should let the next frame draw.
    vulkan.runtime.swapchain_recreate_failed = true;
    vulkan.runtime.pipeline_rebuild_needed = true;
    try app.runSingleFrame();
    try testing.expect(!vulkan.frames.frame_in_progress);
    try testing.expect(!app.input.interface().shouldQuit());
    {
        const ring = &vulkan.resources.staging_ring;
        const capacity = ring.capacity;
        ring.capacity = 256;
        defer ring.capacity = capacity;
        // Alignment leaves space for only one upload at a time. Repeated
        // skipped frames must not fill the ring with finished copies.
        for (0..4) |_| {
            try app.runSingleFrame();
            try testing.expectEqual(@as(u64, 1), ring.allocated());
        }
    }
    app.render_system.rhi.context().requestSwapchainRecreate();

    const fault_count_before_late_quit = app.render_system.getRHI().query().getFaultCount();
    try app.runSingleFrame();
    try testing.expect(app.input.interface().shouldQuit());
    try testing.expectEqual(fault_count_before_late_quit, app.render_system.getRHI().query().getFaultCount());
    try testing.expectEqual(skipped_tick +% 101, try readUploadedByte(vulkan, active_upload_screen.buffer, (skipped_tick -% 1) % active_upload_screen.payload.len));

    if (!build_options.skip_present) {
        const aborted_slot = vulkan.frames.current_frame;
        const suspended_tick = active_upload_screen.tick;
        app.input.interface().setShouldQuit(false);
        active_upload_screen.quit_on_draw = false;

        // The abort requests recreation. Fail the format-list allocation
        // after Vulkan has already torn down the previous swapchain.
        const swapchain = &vulkan.swapchain.swapchain;
        const allocator = swapchain.allocator;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        {
            swapchain.allocator = failing.allocator();
            defer swapchain.allocator = allocator;
            try app.runSingleFrame();
        }
        try testing.expect(failing.has_induced_failure);
        try testing.expect(vulkan.runtime.swapchain_recreate_failed);
        try testing.expect(swapchain.handle == null);
        try testing.expectEqual(aborted_slot, vulkan.frames.current_frame);

        const submit = vulkan.frames.submit_graphics;
        {
            vulkan.frames.submit_graphics = &failGraphicsSubmit;
            defer vulkan.frames.submit_graphics = submit;
            app.render_system.rhi.context().requestSwapchainRecreate();
            try app.runSingleFrame();
        }
        try testing.expect(vulkan.runtime.swapchain_recreate_failed);
        try testing.expectEqual(aborted_slot, vulkan.frames.current_frame);

        app.render_system.rhi.context().requestSwapchainRecreate();
        try app.runSingleFrame();
        try testing.expect(aborted_slot != vulkan.frames.current_frame);
        try testing.expectEqual(suspended_tick +% 1, try readUploadedByte(vulkan, active_upload_screen.buffer, suspended_tick % active_upload_screen.payload.len));

        vulkan.frames.retirement_error = error.GpuLost;
        try testing.expectError(error.GpuLost, app.runSingleFrame());
        vulkan.frames.retirement_error = null;

        if (swapchain.screenshot_capture_supported) {
            var capture_dir = testing.tmpDir(.{});
            defer capture_dir.cleanup();
            const dir = fs.Dir{ .inner = capture_dir.dir };
            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const dir_path = try dir.realpath(".", &path_buf);
            const capture_path = try std.fmt.allocPrint(test_allocator, "{s}/present-error.png", .{dir_path});
            defer test_allocator.free(capture_path);
            active_upload_screen.screenshot_path = capture_path;
            const present = vulkan.swapchain.fp_vkQueuePresentKHR;
            vulkan.swapchain.fp_vkQueuePresentKHR = &failPresentation;
            defer vulkan.swapchain.fp_vkQueuePresentKHR = present;
            // Mark resize during draw, after successful frame acquisition.
            active_upload_screen.resize_during_draw = true;
            try testing.expectError(error.OutOfMemory, app.runSingleFrame());
            try testing.expect(vulkan.screenshot_capture.staging == null);
            try dir.access("present-error.png", .{});
            try testing.expectError(error.OutOfMemory, app.runSingleFrame());
        }
    }

    if (build_options.skip_present) {
        const render = app.render_system.getRHI().renderContext();
        for (0..3) |attempt| {
            try testing.expect(try render.beginFrame());
            errdefer render.abortFrame();
            render.beginGPass();
            render.endGPass();
            render.computeDepthPyramid();
            try testing.expect(vulkan.depth_pyramid.recorded);
            const expected_layout: c.VkImageLayout = if (attempt < 2) c.VK_IMAGE_LAYOUT_UNDEFINED else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            try testing.expectEqual(expected_layout, vulkan.depth_pyramid.pyramid_layout);
            if (attempt == 0) {
                render.abortFrame();
                try testing.expect(!vulkan.depth_pyramid.recorded);
            } else {
                try render.endFrame();
                try testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL), vulkan.depth_pyramid.pyramid_layout);
            }
        }
        app.render_system.waitIdle();

        const quality = app.render_system.getRHI().options();
        const original_samples = vulkan.options.msaa_samples;
        const original_taa = vulkan.taa.enabled;
        const original_bloom = vulkan.bloom.enabled;
        vulkan.taa.enabled = true;
        quality.setBloom(false);
        const taa_modes = [_]struct { samples: u8, scale: f32 }{
            .{ .samples = 1, .scale = 1 },
            .{ .samples = 4, .scale = 1 },
            .{ .samples = 1, .scale = 0.75 },
        };
        for (taa_modes) |mode| {
            if (mode.samples > vulkan.vulkan_device.max_msaa_samples) continue;
            quality.setMSAA(mode.samples);
            quality.setDynamicResolution(mode.scale < 1, mode.scale, mode.scale, 60);
            // Start at the requested scale, without waiting for the rolling timer.
            vulkan.dynamic_resolution.current_scale = mode.scale;
            for (0..4) |frame| {
                if (!try render.beginFrame()) return error.TaaFrameSkipped;
                errdefer render.abortFrame();
                try testing.expectEqual(mode.scale < 1, vulkan.dynamic_resolution.isActive());
                if (mode.scale < 1) try testing.expect(vulkan.dynamic_resolution.upscale_image != null);
                const write_index = vulkan.taa.history_index;
                const had_history = vulkan.taa.history_valid;
                render.beginGPass();
                render.endGPass();
                render.beginMainPass();
                render.endMainPass();
                render.computeTAA();
                try testing.expect(vulkan.taa.ran_this_frame);
                try testing.expectEqual(write_index, vulkan.taa.history_index);
                if (frame == 1) {
                    render.abortFrame();
                    try testing.expectEqual(write_index, vulkan.taa.history_index);
                    try testing.expectEqual(had_history, vulkan.taa.history_valid);
                    try testing.expect(!vulkan.taa.ran_this_frame);
                    continue;
                }
                try render.endFrame();
                try testing.expect(vulkan.taa.history_valid);
                try testing.expect(write_index != vulkan.taa.history_index);
            }
        }
        quality.setDynamicResolution(false, 0.5, 1, 60);
        quality.setBloom(original_bloom);
        try testing.expect(try render.beginFrame());
        render.computeTAA();
        const history_valid_without_gpass = vulkan.taa.history_valid;
        const taa_ran_without_gpass = vulkan.taa.ran_this_frame;
        render.abortFrame();
        try testing.expect(!history_valid_without_gpass);
        try testing.expect(!taa_ran_without_gpass);
        vulkan.taa.enabled = original_taa;
        quality.setMSAA(original_samples);
        if (!try render.beginFrame()) return error.MsaaRestoreFrameSkipped;
        render.abortFrame();

        app.input.interface().setShouldQuit(false);
        active_upload_screen.quit_on_draw = false;
        const submit_graphics = vulkan.frames.submit_graphics;
        vulkan.frames.submit_graphics = &failGraphicsSubmit;
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());

        // The failed graphics submit deliberately leaves this slot terminal.
        // Test the transfer failure on the closed frame before any fence wait.
        vulkan.frames.retirement_error = null;
        vulkan.resources.transfer.submit_sync = &failUploadSubmit;
        try app.render_system.getRHI().resourceManager().updateBuffer(active_upload_screen.buffer, 63, &.{0xcd});
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());

        // Shadow recreation runs before any frame fence wait. Submit its
        // actual transition, then fail only the completion check.
        vulkan.frames.retirement_error = null;
        vulkan.frames.submit_graphics = submit_graphics;
        const old_shadow_image = vulkan.shadow_system.shadow_image;
        vulkan.shadow_runtime.pending_shadow_resolution = if (vulkan.shadow_runtime.shadow_resolution == 256) 512 else 256;
        vulkan.frames.wait_layout_queue_idle = &failLayoutWait;
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());
        try testing.expect(vulkan.shadow_system.shadow_image != null);
        try testing.expect(vulkan.shadow_system.shadow_image != old_shadow_image);
        try testing.expectError(error.OutOfMemory, app.runSingleFrame());
        teardown_wait_attempts = 0;
        vulkan.frames.wait_device_idle = &failFirstTeardownWait;
    }

    const val_count = app.render_system.getRHI().query().getValidationErrorCount();
    if (val_count > 0) {
        std.debug.print("Integration test finished with {} Vulkan validation errors\n", .{val_count});
    }
    try testing.expectEqual(@as(u32, 0), val_count);
    if (build_options.skip_present) {
        app.deinit();
        app_deinitialized = true;
        try testing.expect(teardown_wait_attempts >= 2);
    }
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
