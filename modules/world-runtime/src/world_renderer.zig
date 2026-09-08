const std = @import("std");
const log = @import("engine-core").log;
const world_meshing = @import("world-meshing");
const ChunkData = world_meshing.ChunkData;
const ChunkStorage = world_meshing.ChunkStorage;
const world_core = @import("world-core");
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const GlobalVertexAllocator = world_meshing.GlobalVertexAllocator;
const rhi_mod = @import("engine-rhi").rhi;
const ResourceManager = rhi_mod.ResourceManager;
const RenderContext = rhi_mod.RenderContext;
const IDeviceQuery = rhi_mod.IDeviceQuery;
const IDeviceTiming = rhi_mod.IDeviceTiming;
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const culling = @import("engine-rhi").culling;
const ICullingSystem = culling.ICullingSystem;
const ChunkCullData = culling.ChunkCullData;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;
const CpuCullDiagnostics = @import("world_diagnostics.zig").CpuCullDiagnostics;
const build_options = @import("world_runtime_options");
const runtime_env = @import("engine-core").runtime_env;

pub const MAX_MDI_CHUNKS: usize = 16384;
const MAX_MDI_BATCHES: usize = 16;
const MB: usize = 1024 * 1024;
const GPU_BLOCK_SLOT_SIZE: usize = 16 * 16 * 256;

// Every recorded batch needs its own destination, not just fresh staging data.
const MdiBatchSlots = struct {
    next: usize = 0,

    fn reserve(self: *MdiBatchSlots) !usize {
        if (self.next == MAX_MDI_BATCHES) return error.MdiBatchCapacityExceeded;
        const slot = self.next;
        self.next += 1;
        return slot;
    }

    fn reset(self: *MdiBatchSlots) void {
        self.next = 0;
    }
};

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}

fn parseEnabledEnv(value: ?[]const u8, default_enabled: bool) bool {
    const val = value orelse return default_enabled;
    return !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"));
}

pub fn chooseVertexCapacityMb(vram_mb: usize, strict_safe_mode: bool) usize {
    if (strict_safe_mode) return @min(@as(usize, 256), @max(@as(usize, 128), @divFloor(vram_mb, 8)));
    if (vram_mb >= 8192) return 768;
    if (vram_mb >= 6144) return 512;
    if (vram_mb >= 4096) return 256;
    return 128;
}

pub fn chooseGpuBlockCapacity(vram_mb: usize) usize {
    const block_budget_mb: usize = if (vram_mb >= 8192) 512 else if (vram_mb >= 6144) 384 else if (vram_mb >= 4096) 256 else 128;
    const max_by_budget = (block_budget_mb * MB) / GPU_BLOCK_SLOT_SIZE;
    return @min(MAX_MDI_CHUNKS, max_by_budget);
}

fn gpuBlockCapacityForBudgetMb(budget_mb: usize) usize {
    const max_by_budget = (budget_mb * MB) / GPU_BLOCK_SLOT_SIZE;
    return @min(MAX_MDI_CHUNKS, max_by_budget);
}

pub fn isWithinChunkRenderRadius(chunk_x: i64, chunk_z: i64, player_chunk_x: i64, player_chunk_z: i64, radius: i64) bool {
    const dx = @as(i128, chunk_x) - @as(i128, player_chunk_x);
    const dz = @as(i128, chunk_z) - @as(i128, player_chunk_z);
    const safe_radius = @as(i128, @max(radius, 0));
    return dx * dx + dz * dz <= safe_radius * safe_radius;
}

pub fn hasMdiCapacity(instance_count: usize, command_count: usize, additional_commands: usize) bool {
    return instance_count < MAX_MDI_CHUNKS and command_count <= MAX_MDI_CHUNKS * 3 and additional_commands <= MAX_MDI_CHUNKS * 3 - command_count;
}

pub const RenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
    gpu_culling: bool = false,
};

pub const ShadowStats = struct {
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
};

test "WorldRenderer chooses vertex capacity from VRAM tier" {
    try std.testing.expectEqual(@as(usize, 128), chooseVertexCapacityMb(2048, false));
    try std.testing.expectEqual(@as(usize, 256), chooseVertexCapacityMb(4096, false));
    try std.testing.expectEqual(@as(usize, 512), chooseVertexCapacityMb(6144, false));
    try std.testing.expectEqual(@as(usize, 768), chooseVertexCapacityMb(8192, false));
}

test "WorldRenderer clamps strict safe vertex capacity" {
    try std.testing.expectEqual(@as(usize, 128), chooseVertexCapacityMb(512, true));
    try std.testing.expectEqual(@as(usize, 128), chooseVertexCapacityMb(1024, true));
    try std.testing.expectEqual(@as(usize, 256), chooseVertexCapacityMb(4096, true));
    try std.testing.expectEqual(@as(usize, 256), chooseVertexCapacityMb(8192, true));
}

test "WorldRenderer parses boolean feature env" {
    try std.testing.expect(!parseEnabledEnv("0", true));
    try std.testing.expect(!parseEnabledEnv("false", true));
    try std.testing.expect(parseEnabledEnv("1", false));
    try std.testing.expect(parseEnabledEnv(null, true));
    try std.testing.expect(!parseEnabledEnv(null, false));
}

test "WorldRenderer MDI slots exhaust without reuse and reset only the retired frame" {
    var frames = [_]MdiBatchSlots{.{}} ** rhi_mod.MAX_FRAMES_IN_FLIGHT;
    _ = try frames[1].reserve();
    for (0..MAX_MDI_BATCHES) |i| try std.testing.expectEqual(i, try frames[0].reserve());
    try std.testing.expectError(error.MdiBatchCapacityExceeded, frames[0].reserve());
    try std.testing.expectError(error.MdiBatchCapacityExceeded, frames[0].reserve());
    frames[0].reset();
    try std.testing.expectEqual(@as(usize, 0), try frames[0].reserve());
    try std.testing.expectEqual(@as(usize, 1), try frames[1].reserve());
}

test "WorldRenderer MDI uploads retain every batch destination and model until frame reuse" {
    const Capture = struct {
        next_handle: rhi_mod.BufferHandle = 1,
        bytes: [MAX_MDI_BATCHES * 2][@sizeOf(rhi_mod.InstanceData)]u8 = undefined,
        lengths: [MAX_MDI_BATCHES * 2]usize = .{0} ** (MAX_MDI_BATCHES * 2),
        instance: rhi_mod.BufferHandle = 0,
        draws: [MAX_MDI_BATCHES]struct { instance: rhi_mod.BufferHandle, indirect: rhi_mod.BufferHandle } = undefined,
        draw_count: usize = 0,

        fn create(ptr: *anyopaque, _: usize, _: rhi_mod.BufferUsage) rhi_mod.RhiError!rhi_mod.BufferHandle {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const handle = self.next_handle;
            self.next_handle += 1;
            return handle;
        }

        fn update(ptr: *anyopaque, handle: rhi_mod.BufferHandle, offset: usize, data: []const u8) rhi_mod.RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (offset != 0 or data.len > self.bytes[0].len) return error.InvalidState;
            @memcpy(self.bytes[handle - 1][0..data.len], data);
            self.lengths[handle - 1] = data.len;
        }

        fn bindInstance(ptr: *anyopaque, handle: rhi_mod.BufferHandle) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.instance = handle;
        }

        fn drawIndirect(ptr: *anyopaque, _: rhi_mod.BufferHandle, indirect: rhi_mod.BufferHandle, _: usize, _: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.draws[self.draw_count] = .{ .instance = self.instance, .indirect = indirect };
            self.draw_count += 1;
        }

        fn frameIndex(_: *anyopaque) usize {
            return 0;
        }
    };
    var capture = Capture{};
    var factory: rhi_mod.IResourceFactory.VTable = undefined;
    factory.createBuffer = Capture.create;
    factory.updateBuffer = Capture.update;
    var state: rhi_mod.IRenderStateContext.VTable = undefined;
    state.setInstanceBuffer = Capture.bindInstance;
    var encoder: rhi_mod.IGraphicsCommandEncoder.VTable = undefined;
    encoder.drawIndirect = Capture.drawIndirect;
    var query: IDeviceQuery.VTable = undefined;
    query.getFrameIndex = Capture.frameIndex;
    var vertices: GlobalVertexAllocator = undefined;
    vertices.buffer = 99;
    var renderer: WorldRenderer = undefined;
    renderer.rm = .{ .factory = .{ .ptr = &capture, .vtable = &factory } };
    renderer.render_ctx = .{
        .render = undefined,
        .passes = undefined,
        .post_process = undefined,
        .effects = undefined,
        .vulkan = undefined,
        .state = .{ .ptr = &capture, .vtable = &state },
        .encoder = .{ .ptr = &capture, .vtable = &encoder },
    };
    renderer.query = .{ .ptr = &capture, .vtable = &query };
    renderer.vertex_allocator = &vertices;
    renderer.instance_buffers = .{.{0} ** MAX_MDI_BATCHES} ** rhi_mod.MAX_FRAMES_IN_FLIGHT;
    renderer.indirect_buffers = .{.{0} ** MAX_MDI_BATCHES} ** rhi_mod.MAX_FRAMES_IN_FLIGHT;
    renderer.mdi_batch_slots = [_]MdiBatchSlots{.{}} ** rhi_mod.MAX_FRAMES_IN_FLIGHT;

    // Four cascades plus geometry, reflection, terrain and water all upload
    // before execution. Inspect destinations only after the final upload.
    const batch_count = rhi_mod.SHADOW_CASCADE_COUNT + 4;
    var instances: [batch_count]rhi_mod.InstanceData = undefined;
    var commands: [batch_count]rhi_mod.DrawIndirectCommand = undefined;
    for (0..batch_count) |i| {
        instances[i] = .{ .model = Mat4.translate(Vec3.init(@floatFromInt(i), 2, 3)) };
        commands[i] = .{ .vertexCount = @intCast((i + 1) * 3), .instanceCount = 1, .firstVertex = @intCast(i * 6), .firstInstance = 0 };
        renderer.instance_data = .{ .items = instances[i .. i + 1], .capacity = 1 };
        renderer.draw_commands = .{ .items = commands[i .. i + 1], .capacity = 1 };
        try renderer.uploadMdiBatch();
    }
    try std.testing.expectEqual(batch_count, capture.draw_count);
    for (capture.draws[0..batch_count], 0..) |draw_call, i| {
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&instances[i]), capture.bytes[draw_call.instance - 1][0..capture.lengths[draw_call.instance - 1]]);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&commands[i]), capture.bytes[draw_call.indirect - 1][0..capture.lengths[draw_call.indirect - 1]]);
    }
    renderer.mdi_batch_slots[0].reset();
    try renderer.uploadMdiBatch();
    try std.testing.expectEqual(capture.draws[0].instance, capture.draws[batch_count].instance);
    try std.testing.expectEqual(capture.draws[0].indirect, capture.draws[batch_count].indirect);
    try std.testing.expectEqual(@as(rhi_mod.BufferHandle, batch_count * 2 + 1), capture.next_handle);
}

pub const RenderLayer = enum {
    all,
    terrain,
    fluid,
};

test "WorldRenderer shadow MDI allocation failures retain solid and cutout geometry" {
    const Capture = struct {
        model: Mat4 = Mat4.identity,
        draws: usize = 0,
        vertices: u32 = 0,
        offsets: [2]usize = undefined,

        fn supports(_: *anyopaque) bool {
            return true;
        }

        fn setModel(ptr: *anyopaque, model: Mat4, _: Vec3) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.model = model;
        }

        fn draw(ptr: *anyopaque, _: rhi_mod.BufferHandle, count: u32, _: rhi_mod.DrawMode, offset: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.offsets[self.draws] = offset;
            self.draws += 1;
            self.vertices += count;
        }
    };
    var storage = ChunkStorage.init(std.testing.allocator);
    defer storage.deinitWithoutRHI();
    const chunk = try storage.getOrCreate(-3, -5);
    chunk.render.mesh.solid_allocation = .{ .offset = 0, .count = 6, .handle = 1 };
    chunk.render.mesh.cutout_allocation = .{ .offset = 6 * @sizeOf(rhi_mod.Vertex), .count = 3, .handle = 2 };
    chunk.render.mesh.fluid_allocation = .{ .offset = 9 * @sizeOf(rhi_mod.Vertex), .count = 12, .handle = 3 };
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var capture = Capture{};
        var state: rhi_mod.IRenderStateContext.VTable = undefined;
        state.setModelMatrix = Capture.setModel;
        var encoder: rhi_mod.IGraphicsCommandEncoder.VTable = undefined;
        encoder.drawOffset = Capture.draw;
        var query: IDeviceQuery.VTable = undefined;
        query.supportsIndirectFirstInstance = Capture.supports;
        var vertices: GlobalVertexAllocator = undefined;
        vertices.buffer = 99;
        var renderer: WorldRenderer = undefined;
        renderer.allocator = failing.allocator();
        renderer.storage = &storage;
        renderer.vertex_allocator = &vertices;
        renderer.render_ctx = .{
            .render = undefined,
            .passes = undefined,
            .post_process = undefined,
            .effects = undefined,
            .vulkan = undefined,
            .state = .{ .ptr = &capture, .vtable = &state },
            .encoder = .{ .ptr = &capture, .vtable = &encoder },
        };
        renderer.query = .{ .ptr = &capture, .vtable = &query };
        renderer.instance_data = .empty;
        defer renderer.instance_data.deinit(renderer.allocator);
        renderer.draw_commands = .empty;
        defer renderer.draw_commands.deinit(renderer.allocator);
        renderer.last_shadow_stats = .{};
        const camera = Vec3.init(-49, 10, -81);
        renderer.renderShadowPass(Mat4.identity, camera, Vec3.init(-48, 0, -80), Vec3.init(-48, 256, -80));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 2), capture.draws);
        try std.testing.expectEqual(@as(u32, 9), capture.vertices);
        try std.testing.expectEqualSlices(usize, &.{ 0, 6 * @sizeOf(rhi_mod.Vertex) }, &capture.offsets);
        try std.testing.expect(WorldRenderer.mat4ExactEqual(Mat4.translate(Vec3.init(1, -10, 1)), capture.model));
        try std.testing.expectEqual(@as(usize, 0), renderer.instance_data.items.len);
        try std.testing.expectEqual(@as(usize, 0), renderer.draw_commands.items.len);
        try std.testing.expectEqual(@as(u32, 1), renderer.last_shadow_stats.chunks_rendered);
    }
}

test "WorldRenderer terrain submissions are nearest first while cached fluid order and models survive" {
    const Capture = struct {
        model: Mat4 = Mat4.identity,
        models: [9]Mat4 = undefined,
        offsets: [9]usize = undefined,
        counts: [9]u32 = undefined,
        draws: usize = 0,

        fn supports(_: *anyopaque) bool {
            return false;
        }

        fn setModel(ptr: *anyopaque, model: Mat4, _: Vec3) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.model = model;
        }

        fn draw(ptr: *anyopaque, _: rhi_mod.BufferHandle, count: u32, _: rhi_mod.DrawMode, offset: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.models[self.draws] = self.model;
            self.offsets[self.draws] = offset;
            self.counts[self.draws] = count;
            self.draws += 1;
        }
    };
    var storage = ChunkStorage.init(std.testing.allocator);
    defer storage.deinitWithoutRHI();
    var chunks: [3]*ChunkData = undefined;
    for ([_][2]i32{ .{ -3, -5 }, .{ -4, -6 }, .{ -5, -6 } }, 0..) |coord, i| {
        const chunk = try storage.getOrCreate(coord[0], coord[1]);
        chunks[i] = chunk;
        chunk.render.mesh.solid_allocation = .{ .offset = i * 1000, .count = 6, .handle = 1 };
        chunk.render.mesh.cutout_allocation = .{ .offset = i * 1000 + 100, .count = 3, .handle = 2 };
        chunk.render.mesh.fluid_allocation = .{ .offset = i * 1000 + 200, .count = 12, .handle = 3 };
    }
    var capture = Capture{};
    var state: rhi_mod.IRenderStateContext.VTable = undefined;
    state.setModelMatrix = Capture.setModel;
    var encoder: rhi_mod.IGraphicsCommandEncoder.VTable = undefined;
    encoder.drawOffset = Capture.draw;
    var query: IDeviceQuery.VTable = undefined;
    query.supportsIndirectFirstInstance = Capture.supports;
    var vertices: GlobalVertexAllocator = undefined;
    vertices.buffer = 99;
    var renderer: WorldRenderer = undefined;
    renderer.allocator = std.testing.allocator;
    renderer.storage = &storage;
    renderer.vertex_allocator = &vertices;
    renderer.render_ctx = .{
        .render = undefined,
        .passes = undefined,
        .post_process = undefined,
        .effects = undefined,
        .vulkan = undefined,
        .state = .{ .ptr = &capture, .vtable = &state },
        .encoder = .{ .ptr = &capture, .vtable = &encoder },
    };
    renderer.query = .{ .ptr = &capture, .vtable = &query };
    renderer.visible_chunks = .empty;
    defer renderer.visible_chunks.deinit(renderer.allocator);
    renderer.cpu_cull_cache = .empty;
    defer renderer.cpu_cull_cache.deinit(renderer.allocator);
    renderer.cpu_cull_cache_valid = false;
    renderer.frame_serial = 1;
    renderer.render_frame_count = 0;
    renderer.instance_data = .empty;
    renderer.draw_commands = .empty;
    renderer.use_gpu_culling = false;
    renderer.force_mdi_fallback = true;
    renderer.last_render_stats = .{};
    const camera = Vec3.init(-49, 10, -81);
    renderer.render(Mat4.identity, camera, 6, .fluid);
    try std.testing.expectEqual(@as(usize, 3), capture.draws);
    const fluid_offsets = capture.offsets[0..3].*;
    const fluid_models = capture.models[0..3].*;
    for (0..2) |_| {
        capture.draws = 0;
        renderer.render(Mat4.identity, camera, 6, .terrain);
        try std.testing.expectEqual(@as(usize, 6), capture.draws);
        try std.testing.expectEqual(@as(u32, 3), renderer.last_render_stats.chunks_rendered);
        try std.testing.expectEqual(@as(u64, 27), renderer.last_render_stats.vertices_rendered);
        for ([_]usize{ 1, 0, 2 }, 0..) |index, rank| {
            const chunk = chunks[index];
            const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(chunk.chunk.chunk_x * CHUNK_SIZE_X)) - camera.x, -camera.y, @as(f32, @floatFromInt(chunk.chunk.chunk_z * CHUNK_SIZE_Z)) - camera.z));
            try std.testing.expectEqual(index * 1000, capture.offsets[rank * 2]);
            try std.testing.expectEqual(index * 1000 + 100, capture.offsets[rank * 2 + 1]);
            try std.testing.expectEqual(@as(u32, 6), capture.counts[rank * 2]);
            try std.testing.expectEqual(@as(u32, 3), capture.counts[rank * 2 + 1]);
            try std.testing.expect(WorldRenderer.mat4ExactEqual(model, capture.models[rank * 2]));
            try std.testing.expect(WorldRenderer.mat4ExactEqual(model, capture.models[rank * 2 + 1]));
        }
    }
    capture.draws = 0;
    renderer.render(Mat4.identity, camera, 6, .fluid);
    try std.testing.expectEqual(@as(usize, 3), capture.draws);
    try std.testing.expectEqualSlices(usize, &fluid_offsets, capture.offsets[0..3]);
    for (fluid_models, capture.models[0..3]) |expected, actual| try std.testing.expect(WorldRenderer.mat4ExactEqual(expected, actual));
    try std.testing.expectEqual(@as(u64, 1), renderer.render_frame_count);
}

test "WorldRenderer chunk centre ordering stays precise at negative coordinate limits" {
    var storage = ChunkStorage.init(std.testing.allocator);
    defer storage.deinitWithoutRHI();
    const origin = std.math.minInt(i32);
    const near = try storage.getOrCreate(origin, origin);
    const east = try storage.getOrCreate(origin + 1, origin);
    const south = try storage.getOrCreate(origin, origin + 1);
    var visible = [_]*ChunkData{ south, east, near };
    const context = WorldRenderer.ChunkDistance{ .pc_x = origin, .pc_z = origin, .local_x = 8, .local_z = 8 };
    std.mem.sort(*ChunkData, &visible, context, WorldRenderer.ChunkDistance.lessThan);
    try std.testing.expectEqualSlices(*ChunkData, &.{ near, east, south }, &visible);
    try std.testing.expectEqual(@as(f64, 0), context.squared(near));
    try std.testing.expectEqual(@as(f64, 256), context.squared(east));
    // Near the east edge, sorting origins would incorrectly prefer the east
    // chunk; sorting centres still prefers the camera's own chunk.
    const edge = WorldRenderer.ChunkDistance{ .pc_x = origin, .pc_z = origin, .local_x = 15, .local_z = 8 };
    std.mem.sort(*ChunkData, &visible, edge, WorldRenderer.ChunkDistance.lessThan);
    try std.testing.expectEqualSlices(*ChunkData, &.{ near, east, south }, &visible);
}

test "WorldRenderer fluid demand follows real upload draw and resident eviction" {
    const Capture = struct {
        uploads: usize = 0,
        draws: usize = 0,
        vertices: u32 = 0,
        fn create(_: *anyopaque, _: usize, _: rhi_mod.BufferUsage) rhi_mod.RhiError!rhi_mod.BufferHandle {
            return 99;
        }
        fn destroy(_: *anyopaque, _: rhi_mod.BufferHandle) void {}
        fn supports(_: *anyopaque) bool {
            return false;
        }
        fn update(ptr: *anyopaque, _: rhi_mod.BufferHandle, _: usize, _: []const u8) rhi_mod.RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.uploads += 1;
        }
        fn frame(_: *anyopaque) usize {
            return 0;
        }
        fn model(_: *anyopaque, _: Mat4, _: Vec3) void {}
        fn draw(ptr: *anyopaque, _: rhi_mod.BufferHandle, count: u32, _: rhi_mod.DrawMode, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.draws += 1;
            self.vertices += count;
        }
    };
    var capture = Capture{};
    var factory: rhi_mod.IResourceFactory.VTable = undefined;
    factory.createBuffer = Capture.create;
    factory.destroyBuffer = Capture.destroy;
    factory.updateBuffer = Capture.update;
    var query: IDeviceQuery.VTable = undefined;
    query.getFrameIndex = Capture.frame;
    query.supportsIndirectFirstInstance = Capture.supports;
    var vertices = try GlobalVertexAllocator.init(std.testing.allocator, .{ .factory = .{ .ptr = &capture, .vtable = &factory } }, .{ .ptr = &capture, .vtable = &query }, 1);
    defer vertices.deinit();
    var storage = ChunkStorage.init(std.testing.allocator);
    defer storage.deinitWithoutRHI();
    var renderer: WorldRenderer = undefined;
    renderer.storage = &storage;
    renderer.gpu_mesher = null;
    renderer.gpu_block_buffer = null;
    renderer.vertex_allocator = &vertices;
    renderer.last_render_stats = .{};
    renderer.allocator = std.testing.allocator;
    renderer.query = .{ .ptr = &capture, .vtable = &query };
    renderer.visible_chunks = .empty;
    defer renderer.visible_chunks.deinit(renderer.allocator);
    renderer.cpu_cull_cache = .empty;
    defer renderer.cpu_cull_cache.deinit(renderer.allocator);
    renderer.cpu_cull_cache_valid = false;
    renderer.frame_serial = 1;
    renderer.render_frame_count = 0;
    renderer.instance_data = .empty;
    renderer.draw_commands = .empty;
    renderer.use_gpu_culling = false;
    renderer.force_mdi_fallback = true;
    var state: rhi_mod.IRenderStateContext.VTable = undefined;
    state.setModelMatrix = Capture.model;
    var encoder: rhi_mod.IGraphicsCommandEncoder.VTable = undefined;
    encoder.drawOffset = Capture.draw;
    renderer.render_ctx = .{ .render = undefined, .passes = undefined, .post_process = undefined, .effects = undefined, .vulkan = undefined, .state = .{ .ptr = &capture, .vtable = &state }, .encoder = .{ .ptr = &capture, .vtable = &encoder } };
    try std.testing.expect(!renderer.hasDrawableFluid());
    const chunk = try storage.getOrCreate(-3, -5);
    chunk.render.mesh.pending_cutout = try std.testing.allocator.alloc(rhi_mod.Vertex, 3);
    @memset(chunk.render.mesh.pending_cutout.?, std.mem.zeroes(rhi_mod.Vertex));
    chunk.render.mesh.upload(&vertices);
    try std.testing.expect(!renderer.hasDrawableFluid());
    const camera = Vec3.init(-49, 10, -81);
    renderer.render(Mat4.identity, camera, 6, .fluid);
    try std.testing.expectEqual(@as(usize, 0), capture.draws);
    chunk.render.mesh.pending_fluid = try std.testing.allocator.alloc(rhi_mod.Vertex, 6);
    @memset(chunk.render.mesh.pending_fluid.?, std.mem.zeroes(rhi_mod.Vertex));
    try std.testing.expect(!renderer.hasDrawableFluid());
    chunk.render.mesh.upload(&vertices);
    try std.testing.expectEqual(@as(usize, 2), capture.uploads);
    try std.testing.expect(renderer.hasDrawableFluid());
    renderer.render(Mat4.identity, camera, 6, .fluid);
    try std.testing.expectEqual(@as(usize, 1), renderer.visible_chunks.items.len);
    try std.testing.expectEqual(@as(u64, 6), renderer.last_render_stats.vertices_rendered);
    try std.testing.expectEqual(@as(usize, 1), capture.draws);
    try std.testing.expectEqual(@as(u32, 6), capture.vertices);
    // Mesh/state flags cannot hide a retained drawable allocation.
    chunk.render.mesh.ready = false;
    try std.testing.expect(renderer.hasDrawableFluid());
    try std.testing.expect(chunk.render.mesh.mutex.tryLock());
    chunk.render.mesh.mutex.unlock();
    try std.testing.expect(storage.remove(-3, -5, &vertices));
    try std.testing.expect(!renderer.hasDrawableFluid());
    try std.testing.expect(storage.chunks_mutex.tryLock());
    storage.chunks_mutex.unlock();
}

test "WorldRenderer fluid demand is conservative for unknown compute streams" {
    var storage = ChunkStorage.init(std.testing.allocator);
    defer storage.deinitWithoutRHI();
    var renderer: WorldRenderer = undefined;
    renderer.storage = &storage;
    var mesher: GpuMesher = undefined;
    var blocks: GpuBlockBuffer = undefined;
    renderer.gpu_mesher = &mesher;
    renderer.gpu_block_buffer = null;
    try std.testing.expect(renderer.hasDrawableFluid());
    renderer.gpu_mesher = null;
    renderer.gpu_block_buffer = &blocks;
    try std.testing.expect(renderer.hasDrawableFluid());
    renderer.gpu_block_buffer = null;
    try std.testing.expect(!renderer.hasDrawableFluid());
}

pub const WorldRenderer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    rm: ResourceManager,
    render_ctx: RenderContext,
    query: IDeviceQuery,
    timing: IDeviceTiming,
    culling_screen_size: rhi_mod.RenderResolution,

    vertex_allocator: *GlobalVertexAllocator,
    visible_chunks: std.ArrayListUnmanaged(*ChunkData),
    last_render_stats: RenderStats,
    last_shadow_stats: ShadowStats,

    // MDI Resources
    instance_data: std.ArrayListUnmanaged(rhi_mod.InstanceData),
    draw_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT][MAX_MDI_BATCHES]rhi_mod.BufferHandle = .{.{0} ** MAX_MDI_BATCHES} ** rhi_mod.MAX_FRAMES_IN_FLIGHT,
    indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT][MAX_MDI_BATCHES]rhi_mod.BufferHandle = .{.{0} ** MAX_MDI_BATCHES} ** rhi_mod.MAX_FRAMES_IN_FLIGHT,
    mdi_batch_slots: [rhi_mod.MAX_FRAMES_IN_FLIGHT]MdiBatchSlots = [_]MdiBatchSlots{.{}} ** rhi_mod.MAX_FRAMES_IN_FLIGHT,
    force_mdi_fallback: bool,

    // GPU Culling
    culling_system: ?ICullingSystem,
    aabb_data: std.ArrayListUnmanaged(ChunkCullData),
    chunk_lookup: [rhi_mod.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(*ChunkData),
    gpu_visible_indices: std.ArrayListUnmanaged(u32),
    use_gpu_culling: bool,

    // CPU culling cache for repeated terrain/fluid passes with the same view in
    // one frame. G-pass, opaque, and water can otherwise rescan the same RD area.
    cpu_cull_cache: std.ArrayListUnmanaged(*ChunkData),
    cpu_cull_cache_valid: bool,
    cpu_cull_cache_frame: u64,
    cpu_cull_cache_pc_x: i64,
    cpu_cull_cache_pc_z: i64,
    cpu_cull_cache_r_dist: i64,
    cpu_cull_cache_camera_pos: Vec3,
    cpu_cull_cache_view_proj: Mat4,
    cpu_cull_cache_culled: u32,
    frame_serial: u64,

    // GPU Block Buffer (Batch 5 - Issue #389)
    gpu_block_buffer: ?*GpuBlockBuffer,

    // GPU Mesher (Batch 6 - Issue #391)
    gpu_mesher: ?*GpuMesher,

    // Diagnostic frame counter
    render_frame_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, render_ctx: RenderContext, query: IDeviceQuery, storage: *ChunkStorage, atlas: *const TextureAtlas, rhi: rhi_mod.RHI, culling_system: *?ICullingSystem, culling_screen_size: rhi_mod.RenderResolution, safe_mode_enabled: bool) !*WorldRenderer {
        const renderer = try allocator.create(WorldRenderer);

        const strict_safe_mode = runtime_env.strictSafeModeEnabled();

        const vram_bytes = query.getDeviceLocalVramBytes();
        const vram_mb = vram_bytes / (1024 * 1024);
        const vertex_capacity_mb = runtime_env.envInt("ZIGCRAFT_VERTEX_CAPACITY_MB", chooseVertexCapacityMb(vram_mb, strict_safe_mode));
        const gpu_block_budget_mb = runtime_env.envInt("ZIGCRAFT_GPU_BLOCK_BUDGET_MB", 0);
        const gpu_block_capacity = if (gpu_block_budget_mb > 0) gpuBlockCapacityForBudgetMb(gpu_block_budget_mb) else chooseGpuBlockCapacity(vram_mb);

        log.log.info("VRAM budget: {}MB | vertex_allocator: {}MB | gpu_block_buffer: {} slots", .{ vram_mb, vertex_capacity_mb, gpu_block_capacity });

        if (strict_safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: reduced GPU buffer sizes", .{});
        } else if (safe_mode_enabled) {
            log.log.warn("Wayland stability profile active: keeping normal GPU buffer budgets while using CPU chunk path", .{});
        }

        const vertex_allocator = try allocator.create(GlobalVertexAllocator);
        vertex_allocator.* = try GlobalVertexAllocator.init(allocator, rm, query, vertex_capacity_mb);

        // The compute mesher does not yet match the production vertex/light contract.
        const gpu_meshing_enabled = false;

        const owned_culling_system = culling_system.*;
        const use_gpu = !safe_mode_enabled and owned_culling_system != null and parseEnabledEnv(getenv("ZIGCRAFT_ENABLE_GPU_CULLING"), false);
        if (use_gpu) {
            log.log.info("GPU chunk frustum culling enabled; temporal depth-pyramid occlusion remains disabled", .{});
        } else if (!safe_mode_enabled and owned_culling_system != null) {
            log.log.info("GPU chunk culling available but disabled by default; set ZIGCRAFT_ENABLE_GPU_CULLING=1 to test compute frustum culling", .{});
        } else if (safe_mode_enabled) {
            log.log.info("Safe mode: GPU frustum culling disabled, using CPU culling", .{});
        }

        var gpu_block_buffer: ?*GpuBlockBuffer = null;
        errdefer if (gpu_block_buffer) |buf| buf.deinit();
        if (!safe_mode_enabled and gpu_meshing_enabled) {
            gpu_block_buffer = try GpuBlockBuffer.init(allocator, rm, gpu_block_capacity);
            log.log.info("GpuBlockBuffer initialized (capacity={})", .{gpu_block_capacity});
        }

        var gpu_mesher: ?*GpuMesher = null;
        errdefer if (gpu_mesher) |m| m.deinit();
        if (!safe_mode_enabled and gpu_meshing_enabled) {
            if (gpu_block_buffer) |buf| {
                gpu_mesher = GpuMesher.init(allocator, rhi, atlas, buf) catch |err| blk: {
                    log.log.warn("GpuMesher init failed ({}), CPU meshing fallback active", .{err});
                    break :blk null;
                };
            }
        } else if (!safe_mode_enabled) {
            log.log.info("GPU meshing disabled until its vertex, light, and AO output matches CPU meshing", .{});
        } else {
            log.log.info("Safe mode: GPU meshing disabled, using CPU meshing fallback", .{});
        }

        const force_mdi_fallback = parseEnabledEnv(getenv("ZIGCRAFT_FORCE_MDI_FALLBACK"), true);
        if (force_mdi_fallback) {
            log.log.info("MDI chunk rendering disabled by default; set ZIGCRAFT_FORCE_MDI_FALLBACK=0 to test indirect chunk batches", .{});
        }

        renderer.* = .{
            .allocator = allocator,
            .storage = storage,
            .rm = rm,
            .render_ctx = render_ctx,
            .query = query,
            .timing = rhi.timing(),
            .culling_screen_size = culling_screen_size,
            .vertex_allocator = vertex_allocator,
            .visible_chunks = .empty,
            .last_render_stats = .{},
            .last_shadow_stats = .{},
            .instance_data = .empty,
            .draw_commands = .empty,
            .force_mdi_fallback = force_mdi_fallback,
            .culling_system = owned_culling_system,
            .aabb_data = .empty,
            .chunk_lookup = undefined,
            .gpu_visible_indices = .empty,
            .use_gpu_culling = use_gpu,
            .cpu_cull_cache = .empty,
            .cpu_cull_cache_valid = false,
            .cpu_cull_cache_frame = 0,
            .cpu_cull_cache_pc_x = 0,
            .cpu_cull_cache_pc_z = 0,
            .cpu_cull_cache_r_dist = 0,
            .cpu_cull_cache_camera_pos = Vec3.zero,
            .cpu_cull_cache_view_proj = Mat4.identity,
            .cpu_cull_cache_culled = 0,
            .frame_serial = 0,
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_mesher = gpu_mesher,
        };
        culling_system.* = null;

        for (&renderer.chunk_lookup) |*lookup| lookup.* = .empty;

        return renderer;
    }

    pub fn beginFrame(self: *WorldRenderer) void {
        self.resetShadowStats();
        self.frame_serial += 1;
        self.cpu_cull_cache_valid = false;
        // The RHI begins the frame (and waits its fence) before world rendering.
        self.mdi_batch_slots[self.query.getFrameIndex()].reset();
        self.vertex_allocator.tick(self.query.getFrameIndex());
    }

    pub fn resetShadowStats(self: *WorldRenderer) void {
        self.last_shadow_stats = .{ .chunks_rendered = 0, .chunks_culled = 0 };
    }

    pub fn getGpuBlockBuffer(self: *WorldRenderer) ?*GpuBlockBuffer {
        return self.gpu_block_buffer;
    }

    pub fn getGpuMesher(self: *WorldRenderer) ?*GpuMesher {
        return self.gpu_mesher;
    }

    pub fn isGpuCullingEnabled(self: *const WorldRenderer) bool {
        return self.use_gpu_culling;
    }

    pub fn processGpuMeshing(ctx: *anyopaque) void {
        const self: *WorldRenderer = @ptrCast(@alignCast(ctx));
        if (self.gpu_mesher) |mesher| {
            if (self.gpu_block_buffer) |buf| {
                mesher.process(self.vertex_allocator, self.storage, buf);
            }
        }
    }

    pub fn deinit(self: *WorldRenderer) void {
        self.visible_chunks.deinit(self.allocator);
        self.cpu_cull_cache.deinit(self.allocator);
        self.aabb_data.deinit(self.allocator);
        for (&self.chunk_lookup) |*lookup| lookup.deinit(self.allocator);
        self.gpu_visible_indices.deinit(self.allocator);

        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            for (self.instance_buffers[i]) |buffer| if (buffer != 0) self.rm.destroyBuffer(buffer);
            for (self.indirect_buffers[i]) |buffer| if (buffer != 0) self.rm.destroyBuffer(buffer);
        }
        self.instance_data.deinit(self.allocator);
        self.draw_commands.deinit(self.allocator);

        if (self.culling_system) |cs| cs.deinit();

        if (self.gpu_block_buffer) |buf| buf.deinit();

        if (self.gpu_mesher) |mesher| mesher.deinit();

        self.vertex_allocator.deinit();
        self.allocator.destroy(self.vertex_allocator);
        self.allocator.destroy(self);
    }

    pub fn hasDrawableFluid(self: *WorldRenderer) bool {
        // Experimental compute streams need not use the CPU fluid allocation.
        if (self.gpu_mesher != null or self.gpu_block_buffer != null) return true;

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();
        var chunks = self.storage.chunks.valueIterator();
        while (chunks.next()) |data| {
            // Retained allocations remain drawable during remeshing. Do not
            // infer demand from block contents, chunk state, or visibility.
            data.*.render.mesh.mutex.lock();
            defer data.*.render.mesh.mutex.unlock();
            if (data.*.render.mesh.fluid_allocation != null) return true;
        }
        return false;
    }

    pub fn render(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, render_distance: i32, layer: RenderLayer) void {
        if (layer != .fluid) {
            self.last_render_stats = .{ .gpu_culling = self.use_gpu_culling };
        }
        const detail_render_radius = render_distance;

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        self.visible_chunks.clearRetainingCapacity();
        self.instance_data.clearRetainingCapacity();
        self.draw_commands.clearRetainingCapacity();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        const pc = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
        const pc_x: i64 = pc.chunk_x;
        const pc_z: i64 = pc.chunk_z;

        const r_dist: i64 = @as(i64, @intCast(detail_render_radius));
        const count_stats = layer != .fluid;

        if (self.use_gpu_culling) {
            self.renderGpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist, count_stats);
        } else {
            self.renderCpuCullCached(view_proj, camera_pos, pc_x, pc_z, r_dist, count_stats);
        }

        self.last_render_stats.chunks_total = @intCast(self.storage.chunks.count());

        // Keep the shared visibility cache in its original order for fluid/all.
        // Only opaque/cutout submissions benefit from front-to-back depth rejection.
        if (layer == .terrain) {
            std.mem.sort(*ChunkData, self.visible_chunks.items, ChunkDistance{
                .pc_x = pc_x,
                .pc_z = pc_z,
                .local_x = @as(f64, camera_pos.x) - @as(f64, @floatFromInt(pc_x * CHUNK_SIZE_X)),
                .local_z = @as(f64, camera_pos.z) - @as(f64, @floatFromInt(pc_z * CHUNK_SIZE_Z)),
            }, ChunkDistance.lessThan);
        }

        const vertex_size = @sizeOf(rhi_mod.Vertex);
        const supports_indirect_first_instance = self.query.supportsIndirectFirstInstance();

        const force_mdi_fallback = self.force_mdi_fallback;
        var total_vertices: u64 = 0;

        for (self.visible_chunks.items) |data| {
            if (layer != .fluid) {
                self.last_render_stats.chunks_rendered += 1;
            }
            const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
            const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);
            const rel_x = chunk_world_x - camera_pos.x;
            const rel_z = chunk_world_z - camera_pos.z;
            const rel_y = -camera_pos.y;
            const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

            const is_camera_neighborhood = @abs(data.chunk.chunk_x - @as(i32, @intCast(pc_x))) <= 1 and @abs(data.chunk.chunk_z - @as(i32, @intCast(pc_z))) <= 1;
            if (!supports_indirect_first_instance or force_mdi_fallback or is_camera_neighborhood) {
                total_vertices += self.drawChunkDirect(data, model, layer, true);
                continue;
            }

            const chunk_command_count = @as(usize, if (layer != .fluid and data.render.mesh.solid_allocation != null) 1 else 0) +
                @as(usize, if (layer != .fluid and data.render.mesh.cutout_allocation != null) 1 else 0) +
                @as(usize, if (layer != .terrain and data.render.mesh.fluid_allocation != null) 1 else 0);
            if (chunk_command_count == 0) continue;
            if (!hasMdiCapacity(self.instance_data.items.len, self.draw_commands.items.len, chunk_command_count)) {
                total_vertices += self.drawChunkDirect(data, model, layer, true);
                continue;
            }
            self.instance_data.ensureUnusedCapacity(self.allocator, 1) catch {
                total_vertices += self.drawChunkDirect(data, model, layer, true);
                continue;
            };
            self.draw_commands.ensureUnusedCapacity(self.allocator, chunk_command_count) catch {
                total_vertices += self.drawChunkDirect(data, model, layer, true);
                continue;
            };

            const instance_idx: u32 = @intCast(self.instance_data.items.len);

            self.instance_data.appendAssumeCapacity(.{
                .model = model,
            });

            if (layer != .fluid) {
                if (data.render.mesh.solid_allocation) |alloc| {
                    self.last_render_stats.vertices_rendered += alloc.count;
                    self.draw_commands.appendAssumeCapacity(.{
                        .vertexCount = alloc.count,
                        .instanceCount = 1,
                        .firstVertex = @intCast(alloc.offset / vertex_size),
                        .firstInstance = instance_idx,
                    });
                }
                if (data.render.mesh.cutout_allocation) |alloc| {
                    self.last_render_stats.vertices_rendered += alloc.count;
                    self.draw_commands.appendAssumeCapacity(.{
                        .vertexCount = alloc.count,
                        .instanceCount = 1,
                        .firstVertex = @intCast(alloc.offset / vertex_size),
                        .firstInstance = instance_idx,
                    });
                }
            }
            if (layer != .terrain) {
                if (data.render.mesh.fluid_allocation) |alloc| {
                    self.last_render_stats.vertices_rendered += alloc.count;
                    self.draw_commands.appendAssumeCapacity(.{
                        .vertexCount = alloc.count,
                        .instanceCount = 1,
                        .firstVertex = @intCast(alloc.offset / vertex_size),
                        .firstInstance = instance_idx,
                    });
                }
            }
        }

        self.submitMdiBatch();

        self.drawGuaranteedNearChunks(@intCast(pc_x), @intCast(pc_z), r_dist, camera_pos, layer);
    }

    const ChunkDistance = struct {
        pc_x: i64,
        pc_z: i64,
        local_x: f64,
        local_z: f64,

        fn squared(self: @This(), data: *ChunkData) f64 {
            // Subtract chunk coordinates before conversion; visible deltas are
            // bounded by render distance, even at large negative world positions.
            const x = @as(f64, @floatFromInt(@as(i64, data.chunk.chunk_x) - self.pc_x)) * CHUNK_SIZE_X + CHUNK_SIZE_X / 2 - self.local_x;
            const z = @as(f64, @floatFromInt(@as(i64, data.chunk.chunk_z) - self.pc_z)) * CHUNK_SIZE_Z + CHUNK_SIZE_Z / 2 - self.local_z;
            return x * x + z * z;
        }

        fn lessThan(self: @This(), a: *ChunkData, b: *ChunkData) bool {
            const ad = self.squared(a);
            const bd = self.squared(b);
            if (ad != bd) return ad < bd;
            return a.chunk.chunk_z < b.chunk.chunk_z or (a.chunk.chunk_z == b.chunk.chunk_z and a.chunk.chunk_x < b.chunk.chunk_x);
        }
    };

    fn submitMdiBatch(self: *WorldRenderer) void {
        if (self.instance_data.items.len == 0 or self.draw_commands.items.len == 0) return;
        self.uploadMdiBatch() catch |err| {
            log.log.warn("MDI: batch unavailable ({}), drawing this batch directly", .{err});
            for (self.draw_commands.items) |command| {
                self.render_ctx.setModelMatrix(self.instance_data.items[command.firstInstance].model, Vec3.one);
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, command.vertexCount, .triangles, @as(usize, command.firstVertex) * @sizeOf(rhi_mod.Vertex));
            }
        };
    }

    fn uploadMdiBatch(self: *WorldRenderer) !void {
        const fi = self.query.getFrameIndex();
        // Do not release the slot on failure: one of its uploads may be queued.
        const slot = try self.mdi_batch_slots[fi].reserve();
        if (self.instance_buffers[fi][slot] == 0) {
            self.instance_buffers[fi][slot] = try self.rm.createBuffer(MAX_MDI_CHUNKS * @sizeOf(rhi_mod.InstanceData), .storage);
        }
        if (self.indirect_buffers[fi][slot] == 0) {
            self.indirect_buffers[fi][slot] = try self.rm.createBuffer(MAX_MDI_CHUNKS * 3 * @sizeOf(rhi_mod.DrawIndirectCommand), .indirect);
        }
        try self.rm.updateBuffer(self.instance_buffers[fi][slot], 0, std.mem.sliceAsBytes(self.instance_data.items));
        try self.rm.updateBuffer(self.indirect_buffers[fi][slot], 0, std.mem.sliceAsBytes(self.draw_commands.items));
        self.render_ctx.setInstanceBuffer(self.instance_buffers[fi][slot]);
        self.render_ctx.drawIndirect(self.vertex_allocator.buffer, self.indirect_buffers[fi][slot], 0, @intCast(self.draw_commands.items.len), @sizeOf(rhi_mod.DrawIndirectCommand));
    }

    fn drawChunkDirect(self: *WorldRenderer, data: *ChunkData, model: Mat4, layer: RenderLayer, count_vertices: bool) u64 {
        self.render_ctx.setModelMatrix(model, Vec3.one);
        var total_vertices: u64 = 0;

        if (layer != .fluid) {
            if (data.render.mesh.solid_allocation) |alloc| {
                total_vertices += alloc.count;
                if (count_vertices) self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
            if (data.render.mesh.cutout_allocation) |alloc| {
                total_vertices += alloc.count;
                if (count_vertices) self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
        }
        if (layer != .terrain) {
            if (data.render.mesh.fluid_allocation) |alloc| {
                total_vertices += alloc.count;
                if (count_vertices) self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
        }
        return total_vertices;
    }

    fn drawGuaranteedNearChunks(self: *WorldRenderer, pc_x: i32, pc_z: i32, render_radius: i64, camera_pos: Vec3, layer: RenderLayer) void {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = pc_x + dx;
                const cz = pc_z + dz;
                if (!isWithinChunkRenderRadius(@as(i64, cx), @as(i64, cz), @as(i64, pc_x), @as(i64, pc_z), render_radius)) continue;
                const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse continue;

                var already_drawn = false;
                for (self.visible_chunks.items) |visible| {
                    if (visible == data) {
                        already_drawn = true;
                        break;
                    }
                }
                if (already_drawn) continue;

                const chunk_world_x: f32 = @floatFromInt(cx * CHUNK_SIZE_X);
                const chunk_world_z: f32 = @floatFromInt(cz * CHUNK_SIZE_Z);
                const model = Mat4.translate(Vec3.init(chunk_world_x - camera_pos.x, -camera_pos.y, chunk_world_z - camera_pos.z));
                _ = self.drawChunkDirect(data, model, layer, false);
            }
        }
    }

    fn renderCpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64, count_stats: bool) void {
        self.render_frame_count += 1;
        const frustum = Frustum.fromViewProj(view_proj);

        var diagnostics = CpuCullDiagnostics.init();

        var chunk_iter = self.storage.iteratorUnsafe();
        while (chunk_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const cx = @as(i64, key.x);
            const cz = @as(i64, key.z);
            const dx = cx - pc_x;
            const dz = cz - pc_z;
            const dist_sq = dx * dx + dz * dz;
            if (!isWithinChunkRenderRadius(cx, cz, pc_x, pc_z, r_dist)) continue;
            if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null or data.render.mesh.cutout_allocation != null or data.render.mesh.fluid_allocation != null) {
                const is_camera_neighborhood = @abs(cx - pc_x) <= 1 and @abs(cz - pc_z) <= 1;
                if (!is_camera_neighborhood and !frustum.intersectsChunkRelative(key.x, key.z, camera_pos.x, camera_pos.y, camera_pos.z)) {
                    diagnostics.recordFrustumCulled();
                    if (count_stats) self.last_render_stats.chunks_culled += 1;
                    continue;
                }
                self.visible_chunks.append(self.allocator, data) catch {};
                diagnostics.recordVisible(cx, cz, data);
            } else {
                diagnostics.recordNotRenderable(cx, cz, dist_sq, r_dist);
            }
        }
        diagnostics.logFrame(self.storage, self.visible_chunks.items.len, pc_x, pc_z, r_dist, self.render_frame_count, build_options.startup_diagnostic_seconds);
    }

    fn renderCpuCullCached(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64, count_stats: bool) void {
        if (self.cpu_cull_cache_valid and
            self.cpu_cull_cache_frame == self.frame_serial and
            self.cpu_cull_cache_pc_x == pc_x and
            self.cpu_cull_cache_pc_z == pc_z and
            self.cpu_cull_cache_r_dist == r_dist and
            vec3ExactEqual(self.cpu_cull_cache_camera_pos, camera_pos) and
            mat4ExactEqual(self.cpu_cull_cache_view_proj, view_proj))
        {
            self.visible_chunks.appendSlice(self.allocator, self.cpu_cull_cache.items) catch return;
            if (count_stats) self.last_render_stats.chunks_culled += self.cpu_cull_cache_culled;
            return;
        }

        const culled_before = self.last_render_stats.chunks_culled;
        self.renderCpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist, count_stats);

        self.cpu_cull_cache.clearRetainingCapacity();
        self.cpu_cull_cache.appendSlice(self.allocator, self.visible_chunks.items) catch {
            self.cpu_cull_cache_valid = false;
            return;
        };
        self.cpu_cull_cache_valid = true;
        self.cpu_cull_cache_frame = self.frame_serial;
        self.cpu_cull_cache_pc_x = pc_x;
        self.cpu_cull_cache_pc_z = pc_z;
        self.cpu_cull_cache_r_dist = r_dist;
        self.cpu_cull_cache_camera_pos = camera_pos;
        self.cpu_cull_cache_view_proj = view_proj;
        self.cpu_cull_cache_culled = self.last_render_stats.chunks_culled - culled_before;
    }

    fn vec3ExactEqual(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    fn mat4ExactEqual(a: Mat4, b: Mat4) bool {
        for (0..4) |col| {
            for (0..4) |row| {
                if (a.data[col][row] != b.data[col][row]) return false;
            }
        }
        return true;
    }

    fn chunkAABB(chunk_x: i32, chunk_z: i32, camera_pos: Vec3) ChunkCullData {
        const world_x: f32 = @floatFromInt(chunk_x * CHUNK_SIZE_X);
        const world_z: f32 = @floatFromInt(chunk_z * CHUNK_SIZE_Z);
        return .{
            .min_point = .{ world_x - camera_pos.x, -camera_pos.y, world_z - camera_pos.z, 0.0 },
            .max_point = .{
                world_x - camera_pos.x + @as(f32, @floatFromInt(CHUNK_SIZE_X)),
                -camera_pos.y + @as(f32, @floatFromInt(CHUNK_SIZE_Y)),
                world_z - camera_pos.z + @as(f32, @floatFromInt(CHUNK_SIZE_Z)),
                0.0,
            },
        };
    }

    fn renderGpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64, count_stats: bool) void {
        const cs = self.culling_system orelse {
            log.log.err("GPU culling enabled but system is null, falling back to CPU", .{});
            self.use_gpu_culling = false;
            return self.renderCpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist, count_stats);
        };

        const fi = self.query.getFrameIndex();
        const prev_fi = (fi + rhi_mod.MAX_FRAMES_IN_FLIGHT - 1) % rhi_mod.MAX_FRAMES_IN_FLIGHT;

        const prev_visible_count = cs.readVisibleCount(prev_fi);
        self.gpu_visible_indices.clearRetainingCapacity();
        if (prev_visible_count > 0) {
            self.gpu_visible_indices.resize(self.allocator, prev_visible_count) catch return;
            cs.readVisibleIndices(prev_fi, prev_visible_count, self.gpu_visible_indices.items);

            const limit = @min(@as(usize, @intCast(prev_visible_count)), self.gpu_visible_indices.items.len);
            for (self.gpu_visible_indices.items[0..limit]) |idx| {
                if (idx < self.chunk_lookup[prev_fi].items.len) {
                    const data = self.chunk_lookup[prev_fi].items[idx];
                    if (!isWithinChunkRenderRadius(@as(i64, data.chunk.chunk_x), @as(i64, data.chunk.chunk_z), pc_x, pc_z, r_dist)) continue;
                    self.visible_chunks.append(self.allocator, data) catch continue;
                }
            }
        }

        const prev_rendered: u32 = @intCast(self.visible_chunks.items.len);

        self.aabb_data.clearRetainingCapacity();
        self.chunk_lookup[fi].clearRetainingCapacity();

        var chunk_iter = self.storage.iteratorUnsafe();
        while (chunk_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (!isWithinChunkRenderRadius(key.x, key.z, pc_x, pc_z, r_dist)) continue;
            if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null or data.render.mesh.cutout_allocation != null or data.render.mesh.fluid_allocation != null) {
                self.aabb_data.append(self.allocator, chunkAABB(data.chunk.chunk_x, data.chunk.chunk_z, camera_pos)) catch continue;
                self.chunk_lookup[fi].append(self.allocator, data) catch continue;
            }
        }

        if (self.aabb_data.items.len > MAX_MDI_CHUNKS) {
            log.log.warn("GPU chunk culling capacity exceeded ({} > {}); switching to uncapped CPU culling", .{ self.aabb_data.items.len, MAX_MDI_CHUNKS });
            self.use_gpu_culling = false;
            self.visible_chunks.clearRetainingCapacity();
            return self.renderCpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist, count_stats);
        }

        const chunk_count: u32 = @intCast(self.aabb_data.items.len);
        if (chunk_count == 0) return;

        if (count_stats) {
            self.last_render_stats.chunks_culled += chunk_count - @min(prev_rendered, chunk_count);
        }

        cs.updateAABBData(fi, self.aabb_data.items);
        // The previous-frame depth pyramid is currently too unstable during camera
        // rotation and causes chunks to be wrongly occluded. Keep GPU frustum
        // culling, but disable temporal occlusion until the reprojection path is fixed.
        cs.dispatch(.{
            .view_proj = view_proj,
            .chunk_count = chunk_count,
            .screen_width = @floatFromInt(self.culling_screen_size.width),
            .screen_height = @floatFromInt(self.culling_screen_size.height),
            .previous_frame_valid = false,
        });
    }

    pub fn renderShadowPass(self: *WorldRenderer, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        // Candidate bounds already derive from the exact receiver volume; retaining
        // the matrix preserves the shadow-scene interface for backend callers.
        _ = light_space_matrix;
        const margin: i64 = 1;
        const min_chunk = worldToChunkFromFloat(caster_min.x, caster_min.z);
        const max_chunk = worldToChunkFromFloat(caster_max.x, caster_max.z);
        const min_x: i64 = @as(i64, min_chunk.chunk_x) - margin;
        const min_z: i64 = @as(i64, min_chunk.chunk_z) - margin;
        const max_x: i64 = @as(i64, max_chunk.chunk_x) + margin;
        const max_z: i64 = @as(i64, max_chunk.chunk_z) + margin;
        const supports_shadow_mdi = self.query.supportsIndirectFirstInstance() and parseEnabledEnv(getenv("ZIGCRAFT_ENABLE_SHADOW_MDI"), true);
        const vertex_size = @sizeOf(rhi_mod.Vertex);

        self.instance_data.clearRetainingCapacity();
        self.draw_commands.clearRetainingCapacity();

        var cz = min_z;
        while (cz <= max_z) : (cz += 1) {
            var cx = min_x;
            while (cx <= max_x) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null or data.render.mesh.cutout_allocation != null or data.render.mesh.fluid_allocation != null) {
                        const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
                        const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);

                        self.last_shadow_stats.chunks_rendered += 1;

                        const rel_x = chunk_world_x - camera_pos.x;
                        const rel_z = chunk_world_z - camera_pos.z;
                        const rel_y = -camera_pos.y;
                        const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

                        if (supports_shadow_mdi) {
                            const command_count: usize = @as(usize, if (data.render.mesh.solid_allocation != null) 1 else 0) + @as(usize, if (data.render.mesh.cutout_allocation != null) 1 else 0);
                            if (command_count == 0) continue;
                            if (self.instance_data.items.len >= MAX_MDI_CHUNKS or self.draw_commands.items.len + command_count > MAX_MDI_CHUNKS * 3) {
                                log.log.warn("Shadow MDI: batch capacity reached, drawing overflow chunk directly", .{});
                                if (data.render.mesh.solid_allocation) |alloc| {
                                    self.render_ctx.setModelMatrix(model, Vec3.one);
                                    self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                                }
                                if (data.render.mesh.cutout_allocation) |alloc| {
                                    self.render_ctx.setModelMatrix(model, Vec3.one);
                                    self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                                }
                                continue;
                            }

                            // Reserve the whole chunk before appending so allocation failure
                            // cannot silently drop either solid or cutout shadow geometry.
                            self.instance_data.ensureUnusedCapacity(self.allocator, 1) catch {
                                _ = self.drawChunkDirect(data, model, .terrain, false);
                                continue;
                            };
                            self.draw_commands.ensureUnusedCapacity(self.allocator, command_count) catch {
                                _ = self.drawChunkDirect(data, model, .terrain, false);
                                continue;
                            };
                            const instance_idx: u32 = @intCast(self.instance_data.items.len);
                            self.instance_data.appendAssumeCapacity(.{
                                .model = model,
                            });

                            if (data.render.mesh.solid_allocation) |alloc| {
                                self.draw_commands.appendAssumeCapacity(.{
                                    .vertexCount = alloc.count,
                                    .instanceCount = 1,
                                    .firstVertex = @intCast(alloc.offset / vertex_size),
                                    .firstInstance = instance_idx,
                                });
                            }
                            if (data.render.mesh.cutout_allocation) |alloc| {
                                self.draw_commands.appendAssumeCapacity(.{
                                    .vertexCount = alloc.count,
                                    .instanceCount = 1,
                                    .firstVertex = @intCast(alloc.offset / vertex_size),
                                    .firstInstance = instance_idx,
                                });
                            }
                            continue;
                        }

                        if (data.render.mesh.solid_allocation) |alloc| {
                            self.render_ctx.setModelMatrix(model, Vec3.one);
                            self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                        }
                        if (data.render.mesh.cutout_allocation) |alloc| {
                            self.render_ctx.setModelMatrix(model, Vec3.one);
                            self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                        }
                    }
                }
            }
        }

        self.submitMdiBatch();
    }
};
