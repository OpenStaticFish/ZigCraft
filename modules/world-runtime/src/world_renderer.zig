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
const MB: usize = 1024 * 1024;
const GPU_BLOCK_SLOT_SIZE: usize = 16 * 16 * 256;

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

pub const RenderLayer = enum {
    all,
    terrain,
    fluid,
};

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
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
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

        const max_chunks = MAX_MDI_CHUNKS;
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        var indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.InstanceData), .storage);
            indirect_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.DrawIndirectCommand) * 3, .indirect);
        }

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
            .instance_buffers = instance_buffers,
            .indirect_buffers = indirect_buffers,
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
            if (self.instance_buffers[i] != 0) self.rm.destroyBuffer(self.instance_buffers[i]);
            if (self.indirect_buffers[i] != 0) self.rm.destroyBuffer(self.indirect_buffers[i]);
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

        if (self.instance_data.items.len > 0 and self.draw_commands.items.len > 0) {
            const fi = self.query.getFrameIndex();

            const max_instances: usize = MAX_MDI_CHUNKS;
            const max_commands: usize = MAX_MDI_CHUNKS * 3;

            std.debug.assert(self.instance_data.items.len <= max_instances);
            std.debug.assert(self.draw_commands.items.len <= max_commands);

            const instance_bytes = std.mem.sliceAsBytes(self.instance_data.items);
            self.rm.updateBuffer(self.instance_buffers[fi], 0, instance_bytes) catch |err| {
                log.log.err("MDI: failed to update instance buffer: {}", .{err});
                return;
            };

            const cmd_bytes = std.mem.sliceAsBytes(self.draw_commands.items);
            self.rm.updateBuffer(self.indirect_buffers[fi], 0, cmd_bytes) catch |err| {
                log.log.err("MDI: failed to update indirect buffer: {}", .{err});
                return;
            };

            self.render_ctx.setInstanceBuffer(self.instance_buffers[fi]);

            self.render_ctx.drawIndirect(
                self.vertex_allocator.buffer,
                self.indirect_buffers[fi],
                0,
                @intCast(self.draw_commands.items.len),
                @sizeOf(rhi_mod.DrawIndirectCommand),
            );
        }

        self.drawGuaranteedNearChunks(@intCast(pc_x), @intCast(pc_z), r_dist, camera_pos, layer);
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

                            const instance_idx: u32 = @intCast(self.instance_data.items.len);
                            self.instance_data.append(self.allocator, .{
                                .model = model,
                            }) catch continue;

                            if (data.render.mesh.solid_allocation) |alloc| {
                                self.draw_commands.append(self.allocator, .{
                                    .vertexCount = alloc.count,
                                    .instanceCount = 1,
                                    .firstVertex = @intCast(alloc.offset / vertex_size),
                                    .firstInstance = instance_idx,
                                }) catch {};
                            }
                            if (data.render.mesh.cutout_allocation) |alloc| {
                                self.draw_commands.append(self.allocator, .{
                                    .vertexCount = alloc.count,
                                    .instanceCount = 1,
                                    .firstVertex = @intCast(alloc.offset / vertex_size),
                                    .firstInstance = instance_idx,
                                }) catch {};
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

        if (supports_shadow_mdi and self.instance_data.items.len > 0 and self.draw_commands.items.len > 0) {
            const fi = self.query.getFrameIndex();
            std.debug.assert(self.instance_data.items.len <= MAX_MDI_CHUNKS);
            std.debug.assert(self.draw_commands.items.len <= MAX_MDI_CHUNKS * 3);
            self.rm.updateBuffer(self.instance_buffers[fi], 0, std.mem.sliceAsBytes(self.instance_data.items)) catch |err| {
                log.log.err("Shadow MDI: failed to update instance buffer: {}", .{err});
                return;
            };
            self.rm.updateBuffer(self.indirect_buffers[fi], 0, std.mem.sliceAsBytes(self.draw_commands.items)) catch |err| {
                log.log.err("Shadow MDI: failed to update indirect buffer: {}", .{err});
                return;
            };
            self.render_ctx.setInstanceBuffer(self.instance_buffers[fi]);
            self.render_ctx.drawIndirect(self.vertex_allocator.buffer, self.indirect_buffers[fi], 0, @intCast(self.draw_commands.items.len), @sizeOf(rhi_mod.DrawIndirectCommand));
        }
    }
};
