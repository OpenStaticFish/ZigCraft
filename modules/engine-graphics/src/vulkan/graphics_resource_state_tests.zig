const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const lpv = @import("lpv_system.zig");
const factory = @import("rhi_context_factory.zig");
const init_deinit = @import("rhi_init_deinit.zig");
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
const ResourceManager = @import("resource_manager.zig").ResourceManager;
const TAASystem = @import("taa_system.zig").TAASystem;

test "LPV occlusion capacity rejects a stale smaller grid buffer" {
    try testing.expectEqual(@as(usize, 4096), try lpv.occlusionCellCount(16));
    try testing.expectEqual(@as(usize, 262144), try lpv.occlusionCellCount(64));
    try testing.expectError(error.InvalidGridSize, lpv.occlusionCellCount(0));
    try testing.expectError(error.InvalidGridSize, lpv.occlusionCellCount(std.math.maxInt(u32)));

    var storage: u32 = 0;
    var buffer = @import("utils.zig").VulkanBuffer{ .size = 4096 * 4, .mapped_ptr = &storage };
    try lpv.validateOcclusionCapacity(16, 4096, buffer);
    try testing.expectError(error.InvalidBufferSize, lpv.validateOcclusionCapacity(64, 262144, buffer));
    buffer.size = 262144 * 4;
    try lpv.validateOcclusionCapacity(64, 262144, buffer);
    try testing.expectError(error.InvalidBufferSize, lpv.validateOcclusionCapacity(64, 4096, buffer));
    buffer.mapped_ptr = null;
    try testing.expectError(error.InvalidBuffer, lpv.validateOcclusionCapacity(64, 262144, buffer));
}

test "LPV setSettings allocation failure preserves the previous configuration" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    // Disabled construction and the failing allocation never access the backend.
    var ctx: VulkanContext = undefined;
    const backend = rhi.RHI{ .ptr = &ctx, .vtable = undefined, .device = null };
    const system = try lpv.LPVSystem.init(failing.allocator(), backend, 16, 1.0, 1.0, 2, false);
    defer system.deinit();

    try testing.expectError(error.OutOfMemory, system.setSettings(true, 3.0, 2.0, 8, 64, 1));
    try testing.expect(!system.isEnabled());
    try testing.expectEqual(@as(u32, 16), system.getGridSize());
    try testing.expectEqual(@as(f32, 1.0), system.intensity);
    try testing.expectEqual(@as(f32, 1.0), system.getCellSize());
    try testing.expectEqual(@as(u32, 2), system.getStats().propagation_iterations);
    try testing.expectEqual(@as(usize, 0), system.occlusion_grid.len);
}

test "Vulkan context typed defaults survive factory initialization and pre-init teardown" {
    const ctx = try testing.allocator.create(VulkanContext);
    // An actual address is sufficient: defaults do not call or dereference SDL.
    var window_storage: u8 = 0;
    try factory.initializeDefaults(ctx, testing.allocator, @ptrCast(&window_storage), null, 1024, 4, 8);
    defer init_deinit.deinit(ctx);

    try testing.expect(ctx.taa.enabled);
    try testing.expectEqual(@as(f32, 0.9), ctx.taa.blend_factor);
    try testing.expectEqual(@as(f32, 0.02), ctx.taa.velocity_rejection);
    try testing.expectEqual(@as(f32, 1.0), ctx.dynamic_resolution.current_scale);
    try testing.expectEqual(@as(f32, 0.5), ctx.dynamic_resolution.min_scale);
    try testing.expect(ctx.options.textures_enabled);
    try testing.expectEqual(@as(u8, 4), ctx.options.msaa_samples);
    try testing.expectEqual(@as(u8, 8), ctx.options.anisotropic_filtering);
    try testing.expect(!ctx.init_ownership.vulkan_device);
    try testing.expectEqual(@as(u32, 5), ctx.vulkan_device.max_recovery_attempts);
}

test "InitOwnership unwinds only completed constructor stages once" {
    const Trace = struct {
        order: [5]usize = undefined,
        count: usize = 0,
    };
    const Manager = struct {
        trace: *Trace,
        id: usize,

        pub fn deinit(self: *@This()) void {
            self.trace.order[self.trace.count] = self.id;
            self.trace.count += 1;
        }
    };
    const Context = struct {
        init_ownership: init_deinit.InitOwnership = .{},
        vulkan_device: Manager = undefined,
        resources: Manager = undefined,
        frames: Manager = undefined,
        swapchain: Manager = undefined,
        descriptors: Manager = undefined,
    };
    // Every prefix is a possible failure boundary. Later managers remain poison,
    // exactly as in the typed factory, rather than containing fake valid pointers.
    for (0..6) |completed| {
        var trace = Trace{};
        var ctx = Context{};
        inline for (.{ "vulkan_device", "resources", "frames", "swapchain", "descriptors" }, 0..) |name, i| {
            if (i < completed) {
                @field(ctx, name) = .{ .trace = &trace, .id = i };
                @field(ctx.init_ownership, name) = true;
            }
        }
        init_deinit.unwindManagers(&ctx);
        try testing.expectEqual(completed, trace.count);
        for (trace.order[0..trace.count], 0..) |id, i| try testing.expectEqual(completed - i - 1, id);
        init_deinit.unwindManagers(&ctx);
        try testing.expectEqual(completed, trace.count);
    }
}

test "Terrain rasterizer variants keep G-pass filled and preserve solid culling" {
    const specialized = @import("pipeline_specialized.zig");
    var base = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    base.cullMode = c.VK_CULL_MODE_BACK_BIT;
    base.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
    base.lineWidth = 1.0;
    const wireframe = specialized.terrainRasterizer(base, .wireframe);
    const solid = specialized.terrainRasterizer(base, .solid);
    const selection = specialized.terrainRasterizer(base, .selection);
    const line = specialized.terrainRasterizer(base, .line);
    try testing.expectEqual(@as(c.VkPolygonMode, c.VK_POLYGON_MODE_LINE), wireframe.polygonMode);
    try testing.expectEqual(@as(c.VkPolygonMode, c.VK_POLYGON_MODE_FILL), solid.polygonMode);
    try testing.expectEqual(@as(c.VkCullModeFlags, c.VK_CULL_MODE_BACK_BIT), solid.cullMode);
    try testing.expectEqual(@as(c.VkCullModeFlags, c.VK_CULL_MODE_NONE), selection.cullMode);
    try testing.expectEqual(@as(c.VkPolygonMode, c.VK_POLYGON_MODE_FILL), line.polygonMode);
    try testing.expectEqual(base.frontFace, solid.frontFace);
}

test "Water pipeline multisampling matches the selected main-pass sample count" {
    const waterMultisampling = @import("water_system.zig").waterMultisampling;
    for ([_]u8{ 1, 2, 4, 8 }) |samples| {
        const state = waterMultisampling(samples);
        try testing.expectEqual(@as(c.VkSampleCountFlagBits, samples), state.rasterizationSamples);
        try testing.expectEqual(@as(c.VkBool32, c.VK_FALSE), state.sampleShadingEnable);
    }
}

test "TAA frame state drops history across skipped graph frames and rejects empty commands" {
    var taa = TAASystem{ .ran_this_frame = true, .history_valid = true };
    taa.beginFrame();
    try testing.expect(taa.history_valid);
    try testing.expect(!taa.ran_this_frame);
    taa.beginFrame();
    try testing.expect(!taa.history_valid);

    var resources: ResourceManager = undefined;
    var draws: u32 = 0;
    taa.compute(null, null, 0, &resources, null, null, .{ .width = 0, .height = 0 }, &draws);
    try testing.expectEqual(@as(u32, 0), draws);
    try testing.expect(!taa.ran_this_frame);
    try testing.expect(!taa.pass_active);
}

test "Dynamic resolution requires an initial extent and ignores invalid timing samples" {
    var state = @import("dynamic_resolution.zig").DynamicResolutionState{ .enabled = true, .current_scale = 0.5 };
    state.update(20.0);
    try testing.expectEqual(@as(u32, 0), state.getRenderExtent().width);
    try testing.expect(!state.isActive());
    state.setSwapchainExtent(.{ .width = 1920, .height = 1080 });
    try testing.expectEqual(@as(u32, 960), state.getRenderExtent().width);
    try testing.expectEqual(@as(u32, 540), state.getRenderExtent().height);
    try testing.expect(state.isActive());
    state.update(std.math.nan(f32));
    state.update(0.0);
    try testing.expectEqual(@as(usize, 0), state.frame_time_count);
    state.setSwapchainExtent(.{ .width = 0, .height = 1080 });
    try testing.expectEqual(@as(u32, 0), state.getRenderExtent().height);
    try testing.expect(!state.isActive());
}

test "Aborted temporal recording invalidates LPV generation and stops publishing its results" {
    const orchestration = @import("rhi_frame_orchestration.zig");
    var ctx: VulkanContext = undefined;
    ctx.runtime = .{};
    ctx.draw = .{ .dummy_texture_3d = 7 };
    ctx.taa = .{ .history_valid = true, .ran_this_frame = true, .pass_active = true, .output_texture = 8 };
    const backend = rhi.RHI{ .ptr = &ctx, .vtable = undefined, .device = null };
    const system = try lpv.LPVSystem.init(testing.allocator, backend, 16, 1.0, 1.0, 2, false);
    defer {
        // Only publication state is mocked, never Vulkan allocations.
        system.resources_initialized = false;
        system.deinit();
    }
    system.enabled = true;
    system.resources_initialized = true;
    system.active_grid_textures = .{ 11, 12, 13 };
    system.debug_overlay_texture = 14;
    system.stats.updated_this_frame = true;
    system.stats.light_count = 2;
    ctx.runtime.lpv_recorded_this_frame = true;
    try testing.expect(system.isEnabled());
    try testing.expectEqual(@as(rhi.TextureHandle, 11), system.getTextureHandle());

    orchestration.invalidateAbortedTemporalState(&ctx);
    try testing.expectEqual(@as(u64, 1), ctx.runtime.lpv_abort_generation);
    try testing.expect(!ctx.runtime.lpv_recorded_this_frame);
    try testing.expect(!system.isEnabled());
    try testing.expectEqual(@as(rhi.TextureHandle, 0), system.getTextureHandle());
    try testing.expectEqual(@as(rhi.TextureHandle, 0), system.getTextureHandleG());
    try testing.expectEqual(@as(rhi.TextureHandle, 0), system.getTextureHandleB());
    try testing.expectEqual(@as(rhi.TextureHandle, 0), system.getDebugOverlayTextureHandle());
    try testing.expect(!system.getStats().updated_this_frame);
    try testing.expectEqual(@as(u32, 0), system.getStats().light_count);
    try testing.expectEqual(@as(rhi.TextureHandle, 7), ctx.draw.current_lpv_texture);
    try testing.expect(!ctx.taa.history_valid);
    try testing.expect(!ctx.taa.ran_this_frame);
    try testing.expect(!ctx.taa.pass_active);
    try testing.expectEqual(@as(rhi.TextureHandle, 0), ctx.taa.output_texture);

    // A frame that never recorded LPV must not cause another rebuild. Neither
    // frame start nor a second abort may acknowledge an invalid LPV generation.
    ctx.taa.beginFrame();
    orchestration.invalidateAbortedTemporalState(&ctx);
    try testing.expectEqual(@as(u64, 1), ctx.runtime.lpv_abort_generation);
    try testing.expect(!system.isEnabled());
}

test "Vulkan buffer creation rejects zero bytes before touching the device" {
    const device = @import("../vulkan_device.zig").VulkanDevice{ .allocator = testing.allocator };
    try testing.expectError(error.InvalidState, @import("utils.zig").createVulkanBuffer(&device, 0, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT));
}

const SubmissionMock = struct {
    var end_calls: usize = 0;
    var fail_end_call: usize = 0;
    var queue_calls: usize = 0;
    var queue_result: c.VkResult = c.VK_SUCCESS;

    fn endCommandBuffer(_: c.VkCommandBuffer) callconv(.c) c.VkResult {
        end_calls += 1;
        return if (end_calls == fail_end_call) c.VK_ERROR_OUT_OF_HOST_MEMORY else c.VK_SUCCESS;
    }

    fn queueSubmit(_: c.VkQueue, _: u32, _: [*c]const c.VkSubmitInfo, _: c.VkFence) callconv(.c) c.VkResult {
        queue_calls += 1;
        return queue_result;
    }

    const Context = struct {
        vulkan_device: @import("../vulkan_device.zig").VulkanDevice,
        frames: @import("frame_manager.zig").FrameManager,
        runtime: @TypeOf(@as(VulkanContext, undefined).runtime) = .{ .frame_index = 9, .lpv_recorded_this_frame = true },
        draw: @TypeOf(@as(VulkanContext, undefined).draw) = .{ .dummy_texture_3d = 7 },
        taa: TAASystem = .{ .history_valid = true, .ran_this_frame = true, .output_texture = 8 },
        screenshot_capture: @import("screenshot.zig").PendingCapture = .{ .staging = .{ .size = 64 }, .path = "retained.png" },
        swapchain: struct {
            skip_present: bool = false,
            framebuffer_resized: bool = false,
            failure: ?anyerror = null,
            present_calls: usize = 0,

            pub fn present(self: *@This(), _: c.VkSemaphore, _: u32) !void {
                self.present_calls += 1;
                if (self.failure) |err| return err;
            }
        } = .{},
        resources: struct {
            transfer: struct { is_dedicated: bool = false } = .{},
            failure: ?anyerror = null,
            submit_calls: usize = 0,

            pub fn submitTransfer(self: *@This()) !void {
                self.submit_calls += 1;
                if (self.failure) |err| return err;
            }

            pub fn getTransferSemaphore(_: *@This()) ?c.VkSemaphore {
                return null;
            }
        } = .{},

        fn init(self: *@This()) void {
            end_calls = 0;
            fail_end_call = 0;
            queue_calls = 0;
            queue_result = c.VK_SUCCESS;
            self.* = .{
                .vulkan_device = .{ .allocator = testing.allocator, .queue_submit_fn = queueSubmit },
                .frames = .{
                    .vulkan_device = &self.vulkan_device,
                    .command_pool = null,
                    .frame_command_pools = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
                    .command_buffers = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
                    .image_available_semaphores = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
                    .render_finished_semaphores = .{null} ** rhi.MAX_SWAPCHAIN_IMAGES,
                    .in_flight_fences = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
                    .current_frame = 1,
                    .frame_in_progress = true,
                    .end_command_buffer_fn = endCommandBuffer,
                },
            };
        }
    };
};

test "Frame submission failures quarantine the slot without publishing temporal results" {
    const passes = @import("rhi_pass_orchestration.zig");
    const Failure = enum { main_end, transfer_end, submit, device_lost, present, dedicated_transfer };
    for (std.enums.values(Failure)) |failure| {
        var ctx: SubmissionMock.Context = undefined;
        ctx.init();
        var transfer_cb: ?c.VkCommandBuffer = null;
        var expected_error: anyerror = error.OutOfMemory;
        switch (failure) {
            .main_end => SubmissionMock.fail_end_call = 1,
            .transfer_end => {
                SubmissionMock.fail_end_call = 2;
                transfer_cb = @as(c.VkCommandBuffer, @ptrFromInt(1));
            },
            .submit => SubmissionMock.queue_result = c.VK_ERROR_OUT_OF_DEVICE_MEMORY,
            .device_lost => {
                SubmissionMock.queue_result = c.VK_ERROR_DEVICE_LOST;
                expected_error = error.GpuLost;
            },
            .present => {
                ctx.swapchain.failure = error.BackendError;
                expected_error = error.BackendError;
            },
            .dedicated_transfer => {
                ctx.resources.transfer.is_dedicated = true;
                ctx.resources.failure = error.OutOfMemory;
                transfer_cb = @as(c.VkCommandBuffer, @ptrFromInt(1));
            },
        }
        // Command finalization, queue submission and presentation are all mocked;
        // production FrameManager/end-frame error handling remains under test.
        try testing.expectError(expected_error, passes.submitFrame(&ctx, transfer_cb));
        try testing.expect(ctx.frames.terminal_failure);
        try testing.expect(!ctx.frames.frame_in_progress);
        try testing.expect(ctx.runtime.gpu_fault_detected);
        try testing.expectEqual(@as(u32, 1), ctx.vulkan_device.fault_count);
        try testing.expectEqual(@as(usize, 1), ctx.frames.current_frame);
        try testing.expectEqual(@as(usize, 9), ctx.runtime.frame_index);
        try testing.expectEqual(@as(u64, 1), ctx.runtime.lpv_abort_generation);
        try testing.expect(!ctx.taa.history_valid);
        try testing.expect(!ctx.taa.ran_this_frame);
        try testing.expectEqual(@as(rhi.TextureHandle, 0), ctx.taa.output_texture);
        try testing.expect(ctx.screenshot_capture.staging != null);
        try testing.expectEqualStrings("retained.png", ctx.screenshot_capture.path);
        try testing.expectEqual(@as(usize, if (failure == .present) 1 else 0), ctx.swapchain.present_calls);
        try testing.expectEqual(@as(usize, switch (failure) {
            .submit, .device_lost, .present => 1,
            else => 0,
        }), SubmissionMock.queue_calls);

        const end_calls = SubmissionMock.end_calls;
        const queue_calls = SubmissionMock.queue_calls;
        var swapchain: @import("swapchain_presenter.zig").SwapchainPresenter = undefined;
        try testing.expectError(error.GpuLost, ctx.frames.beginFrame(&swapchain));
        ctx.frames.abortFrame();
        try testing.expectError(error.GpuLost, passes.submitFrame(&ctx, transfer_cb));
        try testing.expectEqual(end_calls, SubmissionMock.end_calls);
        try testing.expectEqual(queue_calls, SubmissionMock.queue_calls);
        try testing.expectEqual(@as(u32, 1), ctx.vulkan_device.fault_count);
        try testing.expectEqual(@as(usize, 1), ctx.frames.current_frame);
    }
}

test "Successful submission commits the frame even when presentation requests recreation" {
    var ctx: SubmissionMock.Context = undefined;
    ctx.init();
    ctx.swapchain.failure = error.OutOfDate;
    try @import("rhi_pass_orchestration.zig").submitFrame(&ctx, null);
    try testing.expectEqual(@as(usize, 1), SubmissionMock.queue_calls);
    try testing.expect(ctx.swapchain.framebuffer_resized);
    try testing.expect(!ctx.frames.terminal_failure);
    try testing.expect(!ctx.frames.frame_in_progress);
    try testing.expectEqual(@as(usize, 0), ctx.frames.current_frame);
    try testing.expect(!ctx.runtime.gpu_fault_detected);
    try testing.expectEqual(@as(u32, 0), ctx.vulkan_device.fault_count);
    try testing.expectEqual(@as(u64, 0), ctx.runtime.lpv_abort_generation);
    try testing.expect(ctx.taa.history_valid);
    try testing.expect(ctx.taa.ran_this_frame);
}

test "Quarantined frame recovery rejects reuse before accessing the Vulkan device" {
    var ctx: VulkanContext = undefined;
    ctx.runtime = .{};
    ctx.frames.terminal_failure = true;
    try testing.expectError(error.GpuLost, @import("rhi_state_control.zig").recover(&ctx));
    try testing.expect(ctx.runtime.gpu_fault_detected);
}

const FrameStartMock = struct {
    const Event = enum { wait, acquire, reset_fence, reset_pool, begin_command };
    var events: [5]Event = undefined;
    var event_count: usize = 0;
    var failure: ?Event = null;
    var failure_result: c.VkResult = c.VK_ERROR_OUT_OF_HOST_MEMORY;
    var fence_signaled: bool = false;

    fn step(event: Event) c.VkResult {
        events[event_count] = event;
        event_count += 1;
        return if (failure == event) failure_result else c.VK_SUCCESS;
    }

    fn waitForFences(_: c.VkDevice, _: u32, _: [*c]const c.VkFence, _: c.VkBool32, _: u64) callconv(.c) c.VkResult {
        const result = step(.wait);
        if (result == c.VK_SUCCESS) fence_signaled = true;
        return result;
    }

    fn resetFences(_: c.VkDevice, _: u32, _: [*c]const c.VkFence) callconv(.c) c.VkResult {
        // Treat even a failed reset as uncertain; production must not wait on it again.
        fence_signaled = false;
        return step(.reset_fence);
    }

    fn resetCommandPool(_: c.VkDevice, _: c.VkCommandPool, _: c.VkCommandPoolResetFlags) callconv(.c) c.VkResult {
        return step(.reset_pool);
    }

    fn beginCommandBuffer(_: c.VkCommandBuffer, _: [*c]const c.VkCommandBufferBeginInfo) callconv(.c) c.VkResult {
        return step(.begin_command);
    }

    const Context = struct {
        frames: *@import("frame_manager.zig").FrameManager,
        vulkan_device: *@import("../vulkan_device.zig").VulkanDevice,
        runtime: @TypeOf(@as(VulkanContext, undefined).runtime) = .{},
        resources: struct {
            current_frame_index: usize = 0,
            handoff_calls: usize = 0,
            transfer: @import("transfer_queue.zig").TransferQueue = .{
                .transfer_ready = .{ false, false },
                .transfer_submitted = .{ true, false },
                .pending_copy_count = .{ 17, 0 },
                .pending_staging_buffer = .{ null, null },
                .pending_dst_access_mask = .{ 0, 0 },
            },

            pub fn setCurrentFrame(self: *@This(), frame: usize) void {
                self.handoff_calls += 1;
                self.current_frame_index = frame;
                self.transfer.setCurrentFrame(frame);
                self.transfer.beginFrame(frame, null);
            }
        } = .{},
        swapchain: struct {
            out_of_date: bool = false,
            framebuffer_resized: bool = false,

            pub fn acquireNextImage(self: *@This(), _: c.VkSemaphore) !u32 {
                try @import("utils.zig").checkVk(step(.acquire));
                if (self.out_of_date) return error.OutOfDate;
                return 0;
            }
        } = .{},
    };

    fn init(fixture: *SubmissionMock.Context) Context {
        fixture.init();
        fixture.frames.frame_in_progress = false;
        fixture.frames.wait_for_fences_fn = waitForFences;
        fixture.frames.reset_fences_fn = resetFences;
        fixture.frames.reset_command_pool_fn = resetCommandPool;
        fixture.frames.begin_command_buffer_fn = beginCommandBuffer;
        events = undefined;
        event_count = 0;
        failure = null;
        failure_result = c.VK_ERROR_OUT_OF_HOST_MEMORY;
        fence_signaled = false;
        return .{ .frames = &fixture.frames, .vulkan_device = &fixture.vulkan_device };
    }
};

test "Frame start failures stop before later driver calls and quarantine unsignaled slots" {
    const orchestration = @import("rhi_frame_orchestration.zig");
    const expected_events = [_]FrameStartMock.Event{ .wait, .acquire, .reset_fence, .reset_pool, .begin_command };
    for (expected_events, 0..) |failure, index| {
        var fixture: SubmissionMock.Context = undefined;
        var ctx = FrameStartMock.init(&fixture);
        FrameStartMock.failure = failure;
        try testing.expectError(error.OutOfMemory, orchestration.startFrame(&ctx));
        try testing.expectEqualSlices(FrameStartMock.Event, expected_events[0 .. index + 1], FrameStartMock.events[0..FrameStartMock.event_count]);
        try testing.expect(ctx.frames.terminal_failure);
        try testing.expect(!ctx.frames.frame_in_progress);
        try testing.expect(ctx.runtime.gpu_fault_detected);
        try testing.expectEqual(@as(u32, 1), ctx.vulkan_device.fault_count);
        try testing.expectEqual(@as(usize, 1), ctx.frames.current_frame);
        try testing.expectEqual(@as(usize, 0), ctx.resources.handoff_calls);
        try testing.expectEqual(@as(usize, 0), ctx.resources.transfer.current_frame);
        try testing.expectEqual(@as(usize, 17), ctx.resources.transfer.pending_copy_count[0]);

        // Retry and abort must not touch a fence/pool whose state is uncertain.
        try testing.expectError(error.GpuLost, orchestration.startFrame(&ctx));
        ctx.frames.abortFrame();
        try testing.expectEqual(index + 1, FrameStartMock.event_count);
        try testing.expectEqual(@as(u32, 1), ctx.vulkan_device.fault_count);
    }
}

test "Aborted presented recording retains acquisition until a successful re-recorded frame" {
    var fixture: SubmissionMock.Context = undefined;
    var ctx = FrameStartMock.init(&fixture);
    try testing.expect(try ctx.frames.beginFrame(&ctx.swapchain));
    try testing.expect(ctx.frames.image_acquired);
    const image_index = ctx.frames.current_image_index;
    const frame = ctx.frames.current_frame;

    FrameStartMock.event_count = 0;
    ctx.frames.abortFrame();
    try testing.expect(!ctx.frames.frame_in_progress);
    try testing.expect(ctx.frames.image_acquired);
    try testing.expectEqual(frame, ctx.frames.current_frame);
    try testing.expectEqual(@as(usize, 1), SubmissionMock.queue_calls);

    FrameStartMock.event_count = 0;
    try testing.expect(try ctx.frames.beginFrame(&ctx.swapchain));
    const expected = [_]FrameStartMock.Event{ .wait, .reset_fence, .reset_pool, .begin_command };
    try testing.expectEqualSlices(FrameStartMock.Event, &expected, FrameStartMock.events[0..FrameStartMock.event_count]);
    try testing.expectEqual(image_index, ctx.frames.current_image_index);
    try ctx.frames.endFrame(&fixture.swapchain, null, null);
    try testing.expect(!ctx.frames.image_acquired);
    try testing.expectEqual(@as(usize, 1), fixture.swapchain.present_calls);
}

test "Frame acquisition OutOfDate leaves the fence signaled and permits a later start" {
    const orchestration = @import("rhi_frame_orchestration.zig");
    var fixture: SubmissionMock.Context = undefined;
    var ctx = FrameStartMock.init(&fixture);
    ctx.swapchain.out_of_date = true;
    try testing.expect(!try orchestration.startFrame(&ctx));
    try testing.expectEqualSlices(FrameStartMock.Event, &.{ .wait, .acquire }, FrameStartMock.events[0..FrameStartMock.event_count]);
    try testing.expect(FrameStartMock.fence_signaled);
    try testing.expect(ctx.swapchain.framebuffer_resized);
    try testing.expect(!ctx.frames.terminal_failure);
    try testing.expect(!ctx.frames.frame_in_progress);
    try testing.expect(!ctx.runtime.gpu_fault_detected);
    try testing.expectEqual(@as(u32, 0), ctx.vulkan_device.fault_count);
    try testing.expectEqual(@as(usize, 1), ctx.resources.handoff_calls);
    try testing.expectEqual(@as(usize, 1), ctx.resources.current_frame_index);
    try testing.expectEqual(@as(usize, 1), ctx.resources.transfer.current_frame);
    try testing.expect(ctx.resources.transfer.transfer_submitted[0]);
    try testing.expectEqual(@as(usize, 17), ctx.resources.transfer.pending_copy_count[0]);

    FrameStartMock.event_count = 0;
    ctx.swapchain.out_of_date = false;
    try testing.expect(try orchestration.startFrame(&ctx));
    try testing.expectEqualSlices(FrameStartMock.Event, &.{ .wait, .acquire, .reset_fence, .reset_pool, .begin_command }, FrameStartMock.events[0..FrameStartMock.event_count]);
    try testing.expect(!FrameStartMock.fence_signaled);
    try testing.expect(ctx.frames.frame_in_progress);
    try testing.expect(!ctx.frames.terminal_failure);
    try testing.expectEqual(@as(usize, 2), ctx.resources.handoff_calls);
}

test "Frame fence wait device loss is reported before acquisition or reset" {
    var fixture: SubmissionMock.Context = undefined;
    var ctx = FrameStartMock.init(&fixture);
    FrameStartMock.failure = .wait;
    FrameStartMock.failure_result = c.VK_ERROR_DEVICE_LOST;
    try testing.expectError(error.GpuLost, @import("rhi_frame_orchestration.zig").startFrame(&ctx));
    try testing.expectEqualSlices(FrameStartMock.Event, &.{.wait}, FrameStartMock.events[0..FrameStartMock.event_count]);
    try testing.expect(ctx.frames.terminal_failure);
    try testing.expect(!ctx.frames.frame_in_progress);
    try testing.expect(ctx.runtime.gpu_fault_detected);
    try testing.expectEqual(@as(u32, 1), ctx.vulkan_device.fault_count);
    try testing.expectEqual(@as(usize, 0), ctx.resources.handoff_calls);
}

test "Frame skipped acquisition directs uploads away from the previous pending transfer slot" {
    var fixture: SubmissionMock.Context = undefined;
    var ctx = FrameStartMock.init(&fixture);
    ctx.swapchain.out_of_date = true;
    try testing.expect(!try @import("rhi_frame_orchestration.zig").startFrame(&ctx));

    try testing.expect(ctx.resources.transfer.addPendingCopy(.{ .src_offset = 0, .dst_buffer = null, .dst_offset = 0, .size = 64 }));
    try testing.expectEqual(@as(usize, 1), ctx.resources.transfer.current_frame);
    try testing.expectEqual(@as(usize, 1), ctx.resources.transfer.pending_copy_count[1]);
    try testing.expectEqual(@as(usize, 17), ctx.resources.transfer.pending_copy_count[0]);
    try testing.expect(ctx.resources.transfer.transfer_submitted[0]);
    try testing.expect(!ctx.frames.frame_in_progress);
    try testing.expect(!ctx.frames.terminal_failure);
}

test "TAA render pass publishes color writes and orders history reuse without Bloom" {
    const config = @import("taa_system.zig").renderPassConfig();
    try testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED), config.attachment.initialLayout);
    try testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL), config.attachment.finalLayout);
    try testing.expectEqual(@as(c.VkAttachmentStoreOp, c.VK_ATTACHMENT_STORE_OP_STORE), config.attachment.storeOp);

    const incoming = config.dependencies[0];
    const outgoing = config.dependencies[1];
    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), incoming.srcSubpass);
    try testing.expectEqual(@as(u32, 0), incoming.dstSubpass);
    try testing.expectEqual(@as(c.VkPipelineStageFlags, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT), incoming.srcStageMask);
    try testing.expectEqual(@as(c.VkAccessFlags, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT), incoming.srcAccessMask);
    try testing.expectEqual(@as(c.VkPipelineStageFlags, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT), incoming.dstStageMask);
    try testing.expectEqual(@as(c.VkAccessFlags, c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT), incoming.dstAccessMask);

    try testing.expectEqual(@as(u32, 0), outgoing.srcSubpass);
    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), outgoing.dstSubpass);
    try testing.expectEqual(@as(c.VkPipelineStageFlags, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT), outgoing.srcStageMask);
    try testing.expectEqual(@as(c.VkAccessFlags, c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT), outgoing.srcAccessMask);
    try testing.expectEqual(@as(c.VkPipelineStageFlags, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT), outgoing.dstStageMask);
    try testing.expectEqual(@as(c.VkAccessFlags, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT), outgoing.dstAccessMask);
    // Temporal reprojection and filtering can sample outside the matching pixel.
    try testing.expectEqual(@as(c.VkDependencyFlags, 0), outgoing.dependencyFlags & c.VK_DEPENDENCY_BY_REGION_BIT);
}
