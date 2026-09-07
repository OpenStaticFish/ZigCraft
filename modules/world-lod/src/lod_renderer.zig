//! LOD Renderer - handles culling and drawing of LOD meshes using Multi-Draw Indirect.
//!
//! This module is responsible for rendering distant terrain chunks (LOD1-LOD3)
//! using an instanced rendering approach. It receives prepared mesh and region
//! data from LODManager via the LODGPUBridge abstraction.
//!
//! ## Multi-Draw Indirect (MDI) Rendering
//!
//! The renderer uses instance buffers to batch-draw multiple LOD regions:
//! - Per-frame instance data (position, color, mask radius) is accumulated
//! - Data is uploaded to separate per-layer, per-frame GPU storage buffers
//! - RHI renders all visible regions in minimal draw calls
//!
//! ## GPU Data Flow
//!
//! ```
//! LODManager -> MeshMap/RegionMap -> LODRenderer.render() -> InstanceBuffer -> GPU
//! ```
//!
//! The LODGPUBridge and LODRenderInterface types abstract the data transfer,
//! allowing LODManager to remain decoupled from rendering concerns.
//!
//! ## Frustum Culling
//!
//! Visible regions are filtered by frustum culling before adding to the draw
//! list. Each LODChunk has conservative bounds that are tested against the camera frustum.
//! Optional ChunkChecker callback allows additional visibility filtering.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const ChunkBounds = lod_chunk.ChunkBounds;
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const LODMeshResources = @import("lod_mesh.zig").LODMeshResources;
const LODStagingCost = @import("lod_mesh_resources.zig").LODStagingCost;
const LODVertexPool = @import("lod_vertex_pool.zig").LODVertexPool;
const CompactLODPool = @import("lod_compact_pool.zig").CompactLODPool;
const CHUNK_SIZE_X = @import("world-core").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("world-core").CHUNK_SIZE_Z;
const worldToChunkFromFloat = @import("world-core").worldToChunkFromFloat;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const LODRendererMemoryStats = lod_gpu.LODRendererMemoryStats;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const ChunkChecker = lod_gpu.ChunkChecker;
const LODStats = @import("lod_stats.zig").LODStats;
const LODProfilingCollector = @import("lod_stats.zig").LODProfilingCollector;

const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Frustum = @import("engine-math").Frustum;
const rhi_types = @import("engine-rhi");
const engine_core = @import("engine-core");
const log = engine_core.log;
const build_options = @import("world_lod_options");
const LODCullCandidate = rhi_types.LODCullCandidate;
const LODCullDispatch = rhi_types.LODCullDispatch;
const ILODCullingSystem = rhi_types.ILODCullingSystem;

const CHUNK_COVERAGE_PADDING: i32 = 1;
const LOD_UNMASKED_SENTINEL: f32 = 0.5;
// Positive radii retain the legacy two-chunk overlap. A negative radius marks
// an exact contiguous ready-detail disk without consuming float precision in a
// fractional tag at large render distances.
const COMPACT_GRID_WIDTHS = [_]u32{ 5, 9, 17, 33, 65, 129 };

fn conservativeChunkDiskMaskRadius(mask_radius: f32) f32 {
    return if (mask_radius >= 1.0) -mask_radius else LOD_UNMASKED_SENTINEL;
}

fn readyDiskMaskRadius(ready_radius: i32) f32 {
    if (ready_radius < 0) return LOD_UNMASKED_SENTINEL;
    const radius_blocks = @as(f32, @floatFromInt(@as(i64, ready_radius) * CHUNK_SIZE_X));
    return -@max(radius_blocks, 1.0);
}

fn contiguousReadyDiskRadius(checker: ?ChunkChecker, checker_ctx: ?*anyopaque, camera_chunk_x: i32, camera_chunk_z: i32, max_radius: i32) i32 {
    return expandContiguousReadyDiskRadius(checker, checker_ctx, camera_chunk_x, camera_chunk_z, -1, max_radius);
}

fn readyDetailChunkAtOffset(check: ChunkChecker, ctx: *anyopaque, camera_chunk_x: i32, camera_chunk_z: i32, dx: i64, dz: i64) bool {
    const cx = @as(i64, camera_chunk_x) + dx;
    const cz = @as(i64, camera_chunk_z) + dz;
    if (cx < std.math.minInt(i32) or cx > std.math.maxInt(i32) or cz < std.math.minInt(i32) or cz > std.math.maxInt(i32)) return false;
    return check(@intCast(cx), @intCast(cz), ctx);
}

fn expandContiguousReadyDiskRadius(checker: ?ChunkChecker, checker_ctx: ?*anyopaque, camera_chunk_x: i32, camera_chunk_z: i32, known_ready_radius: i32, max_radius: i32) i32 {
    const check = checker orelse return -1;
    const ctx = checker_ctx orelse return -1;
    if (known_ready_radius >= max_radius) return max_radius;

    var radius = @as(i64, @max(known_ready_radius + 1, 0));
    const max_radius_i64 = @as(i64, @max(max_radius, 0));
    while (radius <= max_radius_i64) : (radius += 1) {
        const radius_sq = radius * radius;
        const previous_radius = radius - 1;
        const previous_sq = previous_radius * previous_radius;
        var max_dx = radius;
        var previous_max_dx = previous_radius;
        var abs_dz: i64 = 0;
        while (abs_dz <= radius) : (abs_dz += 1) {
            while (max_dx * max_dx + abs_dz * abs_dz > radius_sq) max_dx -= 1;
            if (abs_dz <= previous_radius) {
                while (previous_max_dx * previous_max_dx + abs_dz * abs_dz > previous_sq) previous_max_dx -= 1;
            } else {
                previous_max_dx = -1;
            }

            const first_new_x = previous_max_dx + 1;
            var abs_dx = first_new_x;
            while (abs_dx <= max_dx) : (abs_dx += 1) {
                if (!readyDetailChunkAtOffset(check, ctx, camera_chunk_x, camera_chunk_z, abs_dx, abs_dz)) return @intCast(radius - 1);
                if (abs_dx > 0 and !readyDetailChunkAtOffset(check, ctx, camera_chunk_x, camera_chunk_z, -abs_dx, abs_dz)) return @intCast(radius - 1);
                if (abs_dz > 0) {
                    if (!readyDetailChunkAtOffset(check, ctx, camera_chunk_x, camera_chunk_z, abs_dx, -abs_dz)) return @intCast(radius - 1);
                    if (abs_dx > 0 and !readyDetailChunkAtOffset(check, ctx, camera_chunk_x, camera_chunk_z, -abs_dx, -abs_dz)) return @intCast(radius - 1);
                }
            }
        }
    }
    return @max(max_radius, 0);
}

fn selectLODDescriptorStream(render_ctx: anytype, layer: LODRenderLayer, compact: bool, gpu: bool) void {
    if (comptime !@hasDecl(@TypeOf(render_ctx), "setLODDescriptorStream")) return;
    const stream: rhi_types.LODDescriptorStream = switch (layer) {
        .terrain => if (compact) if (gpu) .terrain_compact_gpu else .terrain_compact_direct else if (gpu) .terrain_standard_gpu else .terrain_standard_direct,
        .fluid => if (compact) if (gpu) .water_compact_gpu else .water_compact_direct else if (gpu) .water_standard_gpu else .water_standard_direct,
    };
    render_ctx.setLODDescriptorStream(stream);
}

fn compactGridIndexCount(width: u32, include_skirts: bool) usize {
    if (width < 2) return 0;
    const top = @as(usize, width - 1) * @as(usize, width - 1) * 6;
    const skirts = if (include_skirts) @as(usize, width - 1) * 4 * 6 else 0;
    return top + skirts;
}

fn compactGridIndices(allocator: std.mem.Allocator, width: u32, include_skirts: bool) ![]u32 {
    if (width < 2) return error.InvalidGrid;
    const result = try allocator.alloc(u32, compactGridIndexCount(width, include_skirts));
    var out: usize = 0;
    var z: u32 = 0;
    while (z + 1 < width) : (z += 1) {
        var x: u32 = 0;
        while (x + 1 < width) : (x += 1) {
            const a = z * width + x;
            const b = a + 1;
            const c = a + width;
            const d = c + 1;
            result[out + 0] = a;
            result[out + 1] = c;
            result[out + 2] = b;
            result[out + 3] = b;
            result[out + 4] = c;
            result[out + 5] = d;
            out += 6;
        }
    }

    if (include_skirts) {
        const top_vertex_count = width * width;
        const Edge = struct {
            fn append(result_slice: []u32, output: *usize, top_a: u32, top_b: u32, bottom_a: u32, bottom_b: u32) void {
                result_slice[output.* + 0] = top_a;
                result_slice[output.* + 1] = bottom_a;
                result_slice[output.* + 2] = top_b;
                result_slice[output.* + 3] = top_b;
                result_slice[output.* + 4] = bottom_a;
                result_slice[output.* + 5] = bottom_b;
                output.* += 6;
            }
        };
        for (0..width - 1) |edge_index| {
            const i: u32 = @intCast(edge_index);
            // North and south.
            Edge.append(result, &out, i, i + 1, top_vertex_count + i, top_vertex_count + i + 1);
            const south_top = (width - 1) * width + i;
            const south_bottom = top_vertex_count + width + i;
            Edge.append(result, &out, south_top + 1, south_top, south_bottom + 1, south_bottom);
            // West and east.
            const west_top = i * width;
            const west_bottom = top_vertex_count + width * 2 + i;
            Edge.append(result, &out, west_top + width, west_top, west_bottom + 1, west_bottom);
            const east_top = i * width + width - 1;
            const east_bottom = top_vertex_count + width * 3 + i;
            Edge.append(result, &out, east_top, east_top + width, east_bottom, east_bottom + 1);
        }
    }
    std.debug.assert(out == result.len);
    return result;
}

fn compactGridVariant(width: u32) ?usize {
    for (COMPACT_GRID_WIDTHS, 0..) |candidate, index| {
        if (candidate == width) return index;
    }
    return null;
}

const RenderDiag = struct {
    meshes_seen: u32 = 0,
    missing_region: u32 = 0,
    not_ready: u32 = 0,
    bad_state: u32 = 0,
    covered_finer_lod: u32 = 0,
    out_of_range: u32 = 0,
    covered_chunks: u32 = 0,
    frustum_culled: u32 = 0,
    drawn: u32 = 0,
};

/// A compact tile may be selected before render-graph resources or descriptor
/// snapshots become usable. That is a retryable availability state, not a
/// backend submission failure.
const CompactRenderResult = enum {
    drawn,
    unavailable,
    backend_failed,
};

/// Value-only result of the frame visibility projection. It deliberately holds
/// no mesh or region pointer: the projection can survive the terrain pass and
/// is revalidated under the manager's shared lock before a later water pass.
const VisibleRegion = struct {
    key: LODRegionKey,
    model: Mat4,
    mask_radius: f32,
    lod_fade: f32,
    /// Spatial owner may be a missing finer descendant using this mesh.
    owner: ?LODRegionKey = null,
    ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

const MAX_LOD_MDI_REGIONS: usize = 2048;

/// Expected RHI interface for LODRenderer:
/// - createBuffer(size: usize, usage: BufferUsage) !BufferHandle
/// - destroyBuffer(handle: BufferHandle) void
/// - getFrameIndex() usize
/// - setLODInstanceBuffer(handle: BufferHandle) void
/// - setModelMatrix(model: Mat4, color: Vec3, mask_radius: f32) void
/// - draw(handle: BufferHandle, count: u32, mode: DrawMode) void
pub fn LODRenderer(comptime RHI: type) type {
    return struct {
        const Self = @This();

        const DirectBuffer = struct {
            handle: rhi_types.BufferHandle,
            size: usize,
            retired_serial: ?u64 = null,
            frame_slot: usize = 0,
        };

        allocator: std.mem.Allocator,
        rhi: RHI,
        /// Main-thread-only ledger. Active storage belongs to meshes; retired
        /// storage remains GPU debt until the RHI completes its deletion slot.
        direct_buffers: std.ArrayListUnmanaged(DirectBuffer) = .empty,

        // MDI Resources (Moved from LODManager)
        instance_data: std.ArrayListUnmanaged(rhi_types.InstanceData),
        draw_list: std.ArrayListUnmanaged(*LODMesh),
        projection_regions: std.ArrayListUnmanaged(VisibleRegion),
        projection_frame: ?u64,
        draw_commands: [LODLevel.count]std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand),
        // Descriptor streams do not snapshot bytes. Terrain and fluid uploads
        // must remain disjoint until the frame slot's graphics work completes.
        instance_buffers: [2][rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        indirect_buffers: [2][rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        vertex_pools: [LODLevel.count]LODVertexPool,
        compact_pool: CompactLODPool,
        /// Per compact LOD: terrain grid with edge skirts, then water top grid.
        /// Exact-width topology for each compact LOD and layer. A prefix of a
        /// wider grid is not valid topology for a decimated tile: its row
        /// stride remains the wider grid's stride and can feed invalid vertex
        /// IDs to the water vertex-pulling path on RADV.
        compact_index_buffers: [2][2][COMPACT_GRID_WIDTHS.len]rhi_types.BufferHandle,
        /// Static index uploads are recorded in the first LOD render frame.
        /// They become drawable only after that frame has been submitted.
        compact_index_upload_frame: ?u64,
        compact_index_init_failed: bool,
        frame_index: usize,
        frame_serial: u64,
        begun_frame: ?u64 = null,
        maintenance_frame: ?u64 = null,
        memory_pressure_requested: bool = false,
        memory_pressure_budget_bytes: usize = 0,
        memory_pressure_accounted_bytes: usize = 0,
        memory_pressure_staging_bytes: usize = 0,
        enable_mdi: bool,
        gpu_culling_requested: bool,
        gpu_culling: ?ILODCullingSystem,
        gpu_candidates: std.ArrayListUnmanaged(LODCullCandidate),
        /// Keys parallel to `gpu_candidates`.  Ineligible meshes stay on the
        /// CPU path instead of disabling an otherwise valid GPU batch.
        gpu_candidate_keys: std.ArrayListUnmanaged(LODRegionKey),
        /// Compact submissions that need a parent fallback after the compact
        /// timing scope has ended. This keeps expanded fallback draws out of
        /// compact GPU timing evidence.
        compact_fallback_regions: std.ArrayListUnmanaged(VisibleRegion),
        gpu_culling_ready_frame: ?u64,
        gpu_culling_threshold: usize,
        gpu_culling_overflow_count: u32,
        /// GPU culling prepares one candidate projection for terrain and water.
        /// Keep its benchmark submission counter frame-scoped so those paired
        /// streams are not reported as two independent culling submissions.
        gpu_culling_submitted_frame: ?u64,

        fn uploadCompactIndexBuffer(allocator: std.mem.Allocator, resources: anytype, handle: rhi_types.BufferHandle, width: u32, include_skirts: bool) !void {
            const indices = try compactGridIndices(allocator, width, include_skirts);
            defer allocator.free(indices);
            try resources.uploadBuffer(handle, std.mem.sliceAsBytes(indices));
        }

        /// Record static compact topology uploads only after a render frame has
        /// opened its staging/transfer slot. Uploads queued during world setup
        /// can otherwise be discarded when the first frame resets that slot.
        fn ensureCompactIndexBuffers(self: *Self, frame_serial: u64) bool {
            // A direct-only backend has no compact upload contract. Keep the
            // expanded ownership path available rather than instantiating an
            // unsupported generic upload call.
            const resources = if (@hasDecl(RHI, "resourceManager")) self.rhi.resourceManager() else self.rhi;
            if (comptime !@hasDecl(@TypeOf(resources), "uploadBuffer")) return false;
            if (self.compact_index_upload_frame) |upload_frame| return frame_serial > upload_frame;
            if (self.compact_index_init_failed) return false;

            inline for (.{ LODLevel.lod3, LODLevel.lod4 }, 0..) |lod, idx| {
                const max_width = @import("world-core").LODSimplifiedData.getGridSize(lod);
                inline for (.{ true, false }, 0..) |include_skirts, layer_idx| for (COMPACT_GRID_WIDTHS, 0..) |width, width_idx| {
                    if (width > max_width) continue;
                    const handle = self.compact_index_buffers[idx][layer_idx][width_idx];
                    if (handle == 0) {
                        self.compact_index_init_failed = true;
                        log.log.err("Compact LOD index topology is missing LOD{} width={} layer={}", .{ @intFromEnum(lod), width, layer_idx });
                        return false;
                    }
                    uploadCompactIndexBuffer(self.allocator, resources, handle, width, include_skirts) catch |err| {
                        log.log.errWithTrace("Failed to upload compact LOD index topology: {}", .{err});
                        return false;
                    };
                };
            }
            self.compact_index_upload_frame = frame_serial;
            return false;
        }

        /// Allocates LOD renderer GPU buffers and per-frame indirect draw resources.
        /// The renderer owns created buffers until `deinit`; allocation failures are returned to the caller.
        pub fn init(allocator: std.mem.Allocator, rhi: RHI) !*Self {
            const renderer = try allocator.create(Self);
            errdefer allocator.destroy(renderer);

            var instance_buffers = std.mem.zeroes([2][rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle);
            var indirect_buffers = std.mem.zeroes([2][rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle);
            const resources = if (@hasDecl(RHI, "resourceManager")) rhi.resourceManager() else rhi;
            errdefer {
                for (instance_buffers, indirect_buffers) |instances, commands| {
                    for (instances, commands) |instance, command| {
                        if (instance != 0) resources.destroyBuffer(instance);
                        if (command != 0) resources.destroyBuffer(command);
                    }
                }
            }
            for (&instance_buffers, &indirect_buffers) |*instances, *commands| {
                for (instances, commands) |*instance, *command| {
                    instance.* = try resources.createBuffer(MAX_LOD_MDI_REGIONS * @sizeOf(rhi_types.InstanceData), .storage);
                    command.* = try resources.createBuffer(MAX_LOD_MDI_REGIONS * @sizeOf(rhi_types.DrawIndirectCommand), .indirect);
                }
            }

            var draw_commands: [LODLevel.count]std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand) = undefined;
            for (&draw_commands) |*commands| commands.* = .empty;

            var vertex_pools: [LODLevel.count]LODVertexPool = undefined;
            for (0..LODLevel.count) |i| {
                vertex_pools[i] = LODVertexPool.init(allocator, @enumFromInt(@as(u3, @intCast(i))), 8 * 1024 * 1024);
            }
            var compact_index_buffers = std.mem.zeroes([2][2][COMPACT_GRID_WIDTHS.len]rhi_types.BufferHandle);
            errdefer for (&compact_index_buffers) |*lod_handles| for (lod_handles) |layer_handles| for (layer_handles) |handle| if (handle != 0) resources.destroyBuffer(handle);
            if (comptime @hasDecl(RHI, "resourceManager") or @hasDecl(RHI, "uploadBuffer") or @hasDecl(RHI, "updateBuffer")) {
                inline for (.{ LODLevel.lod3, LODLevel.lod4 }, 0..) |lod, idx| {
                    const max_width = @import("world-core").LODSimplifiedData.getGridSize(lod);
                    inline for (.{ true, false }, 0..) |include_skirts, layer_idx| for (COMPACT_GRID_WIDTHS, 0..) |width, width_idx| {
                        _ = include_skirts;
                        if (width > max_width) continue;
                        const byte_count = compactGridIndexCount(width, layer_idx == 0) * @sizeOf(u32);
                        compact_index_buffers[idx][layer_idx][width_idx] = try resources.createBuffer(byte_count, .index);
                    };
                }
            }

            const gpu_culling_requested = gpuCullingRequested(build_options.benchmark_gpu_culling, engine_core.envFlag("ZIGCRAFT_LOD_GPU_CULLING", false));
            if (engine_core.envFlag("ZIGCRAFT_LOD_COMPACT_DIAG", false)) {
                std.debug.print("LOD_COMPACT: event=gpu_culling_init requested={} env={s}\n", .{ gpu_culling_requested, engine_core.getenv("ZIGCRAFT_LOD_GPU_CULLING") orelse "unset" });
            }
            var gpu_culling: ?ILODCullingSystem = null;
            if (gpu_culling_requested and @hasDecl(RHI, "createLODCullingSystem")) {
                gpu_culling = rhi.createLODCullingSystem(allocator, MAX_LOD_MDI_REGIONS) catch |err| blk: {
                    log.log.warn("LOD GPU culling unavailable ({}); CPU fallback active", .{err});
                    break :blk null;
                };
            }
            renderer.* = .{
                .allocator = allocator,
                .rhi = rhi,
                .instance_data = .empty,
                .draw_list = .empty,
                .projection_regions = .empty,
                .projection_frame = null,
                .draw_commands = draw_commands,
                .instance_buffers = instance_buffers,
                .indirect_buffers = indirect_buffers,
                .vertex_pools = vertex_pools,
                .compact_pool = CompactLODPool.init(allocator),
                .compact_index_buffers = compact_index_buffers,
                .compact_index_upload_frame = null,
                .compact_index_init_failed = false,
                .frame_index = 0,
                .frame_serial = 0,
                .enable_mdi = !engine_core.envFlag("ZIGCRAFT_DISABLE_LOD_MDI", false),
                .gpu_culling_requested = gpu_culling_requested,
                .gpu_culling = gpu_culling,
                .gpu_candidates = .empty,
                .gpu_candidate_keys = .empty,
                .compact_fallback_regions = .empty,
                .gpu_culling_ready_frame = null,
                .gpu_culling_threshold = gpuCullingThreshold(),
                .gpu_culling_overflow_count = 0,
                .gpu_culling_submitted_frame = null,
            };

            if (!renderer.enable_mdi) {
                log.log.info("LOD MDI disabled by ZIGCRAFT_DISABLE_LOD_MDI", .{});
            }

            return renderer;
        }

        /// Destroys GPU buffers owned by the LOD renderer and releases CPU-side storage.
        /// Call once when the world LOD renderer is no longer used.
        pub fn deinit(self: *Self) void {
            self.rhi.waitIdle();
            const resources = if (@hasDecl(RHI, "resourceManager")) self.rhi.resourceManager() else self.rhi;
            for (self.instance_buffers, self.indirect_buffers) |instances, commands| {
                for (instances, commands) |instance, command| {
                    if (instance != 0) resources.destroyBuffer(instance);
                    if (command != 0) resources.destroyBuffer(command);
                }
            }
            const mesh_resources = LODMeshResources.fromProvider(RHI, &self.rhi);
            for (0..LODLevel.count) |i| {
                self.vertex_pools[i].deinit(mesh_resources);
            }
            self.compact_pool.deinit(mesh_resources);
            for (self.compact_index_buffers) |lod_handles| for (lod_handles) |layer_handles| for (layer_handles) |handle| if (handle != 0) resources.destroyBuffer(handle);
            self.instance_data.deinit(self.allocator);
            self.draw_list.deinit(self.allocator);
            self.projection_regions.deinit(self.allocator);
            self.gpu_candidates.deinit(self.allocator);
            self.gpu_candidate_keys.deinit(self.allocator);
            self.compact_fallback_regions.deinit(self.allocator);
            // Meshes own active direct handles and must be destroyed first.
            // Retired handles were already handed to the RHI deletion queue.
            self.direct_buffers.deinit(self.allocator);
            if (self.gpu_culling) |gpu| gpu.deinit();
            for (&self.draw_commands) |*commands| commands.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// RHI frame begin must have completed its slot fence and deletion queue
        /// before this call.
        /// Update, prepare, terrain and water share one monotonic epoch; never
        /// recollect debt created by an upload/deletion in that same epoch.
        pub fn beginFrame(self: *Self, frame_serial: u64) void {
            if (self.begun_frame) |last| if (frame_serial <= last) return;
            self.begun_frame = frame_serial;
            self.frame_serial = frame_serial;
            const query = if (@hasDecl(RHI, "query")) self.rhi.query() else self.rhi;
            self.frame_index = query.getFrameIndex();
            self.compact_pool.collectRetired(frame_serial, self.frame_index);
            for (&self.vertex_pools) |*pool| pool.collectRetired(frame_serial, self.frame_index);
            var i: usize = 0;
            while (i < self.direct_buffers.items.len) {
                const record = self.direct_buffers.items[i];
                if (record.retired_serial) |serial| {
                    if (frame_serial > serial and record.frame_slot == self.frame_index) {
                        _ = self.direct_buffers.swapRemove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }

        /// Render all LOD meshes using explicitly provided data.
        ///
        /// `frame_serial` is supplied by WorldRenderer and advances only from
        /// its `beginFrame`. Visibility and full-chunk coverage are projected
        /// once for that frame; terrain and water then consume value-only
        /// entries without retaining map-owned mesh pointers.
        pub fn renderFrame(
            self: *Self,
            frame_serial: u64,
            meshes: *const [LODLevel.count]MeshMap,
            regions: *const [LODLevel.count]RegionMap,
            config: ILODConfig,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            detail_render_radius: i32,
            layer: LODRenderLayer,
            stats: ?*LODStats,
            profiling: ?*LODProfilingCollector,
        ) void {
            self.beginFrame(frame_serial);
            // Direct frame rendering skips maintenance and closes its window,
            // including when a later projection/submission fails.
            self.maintenance_frame = frame_serial;
            _ = self.ensureCompactIndexBuffers(frame_serial);
            if (self.projection_frame == null or self.projection_frame.? != frame_serial) {
                const timer = if (profiling) |profile| profile.begin() else null;
                defer if (profiling) |profile| profile.end(.visibility, timer);
                self.buildVisibilityProjection(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, detail_render_radius, false, false, stats, profiling) catch |err| {
                    log.log.errWithTrace("Failed to project LOD visibility: {}", .{err});
                    return;
                };
                self.projection_frame = frame_serial;
            }
            if (!self.renderProjectedLayer(meshes, layer, stats, profiling)) {
                // GPU submission can still fail after the compute prepass (for
                // example if a pooled buffer becomes unavailable). Never feed
                // the broad GPU candidate projection into the CPU renderer.
                self.gpu_culling_ready_frame = null;
                const timer = if (profiling) |profile| profile.begin() else null;
                defer if (profiling) |profile| profile.end(.visibility, timer);
                self.buildVisibilityProjection(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, detail_render_radius, false, false, stats, profiling) catch |err| {
                    log.log.errWithTrace("Failed to rebuild CPU LOD visibility: {}", .{err});
                    self.projection_frame = null;
                    return;
                };
                self.projection_frame = frame_serial;
                _ = self.renderProjectedLayer(meshes, layer, stats, profiling);
            }
        }

        /// Records the LOD compute pass before the render graph enters a graphics
        /// pass. Hierarchy/readiness/chunk-coverage stay CPU authoritative.
        pub fn prepareFrame(
            self: *Self,
            frame_serial: u64,
            meshes: *const [LODLevel.count]MeshMap,
            regions: *const [LODLevel.count]RegionMap,
            config: ILODConfig,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            max_distance_chunks: ?i32,
            detail_render_radius: i32,
            stats: ?*LODStats,
            profiling: ?*LODProfilingCollector,
        ) void {
            self.beginFrame(frame_serial);
            if (self.maintenance_frame != frame_serial) {
                self.maintenance_frame = frame_serial;
                if (self.memory_pressure_requested) {
                    self.memory_pressure_requested = false;
                    // A late prepare after rendering must not relocate ranges
                    // already captured by this frame's projection/commands.
                    if (self.projection_frame != frame_serial) {
                        const resources = LODMeshResources.fromProvider(RHI, &self.rhi);
                        var used = self.memory_pressure_accounted_bytes;
                        for (&self.vertex_pools) |*pool| {
                            const shadow_bytes = pool.gpuMemoryBytes();
                            // GPU backing remains debt until its fence. Freed
                            // shadows must pay any deficit before adding headroom.
                            if (pool.reclaimEmpty(resources)) used -|= shadow_bytes;
                        }
                        const available = self.memory_pressure_budget_bytes -| used;
                        var tried = [_]bool{false} ** LODLevel.count;
                        for (0..LODLevel.count) |_| {
                            var best: ?usize = null;
                            var most_slack: usize = 0;
                            for (&self.vertex_pools, 0..) |*pool, i| {
                                if (tried[i]) continue;
                                const slack = pool.gpuMemoryBytes() -| pool.allocatedBytes();
                                if (best == null or slack > most_slack) {
                                    best = i;
                                    most_slack = slack;
                                }
                            }
                            const i = best orelse break;
                            tried[i] = true;
                            const trimmed = self.vertex_pools[i].trim(resources, available, self.memory_pressure_staging_bytes) catch |err| {
                                // Failed migration may consume staging and add
                                // backing debt. Do not retry another pool now.
                                log.log.warn("LOD pool pressure trim failed: {}", .{err});
                                break;
                            };
                            if (trimmed) break;
                        }
                    }
                }
            }
            self.updateGpuCullingProfiling(profiling);
            const gpu = self.gpu_culling orelse return;
            if (!self.gpu_culling_requested or self.projection_frame == frame_serial) return;
            const visibility_timer = if (profiling) |profile| profile.begin() else null;
            defer if (profiling) |profile| profile.end(.visibility, visibility_timer);
            self.buildVisibilityProjection(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, false, max_distance_chunks, detail_render_radius, false, false, stats, profiling) catch |err| {
                log.log.err("LOD GPU culling projection failed: {}", .{err});
                return;
            };
            self.projection_frame = frame_serial;
            self.gpu_candidates.clearRetainingCapacity();
            self.gpu_candidate_keys.clearRetainingCapacity();
            // Never truncate a visibility projection: losing an LOD fallback
            // region can create a terrain hole, so overflow is CPU-rendered.
            if (self.projection_regions.items.len > MAX_LOD_MDI_REGIONS) {
                self.gpu_culling_overflow_count +%= 1;
                self.updateGpuCullingProfiling(profiling);
                self.projection_frame = null;
                return;
            }
            for (self.projection_regions.items) |visible| {
                const lod_index = @intFromEnum(visible.key.lod);
                const mesh = meshes[lod_index].get(visible.key) orelse continue;
                const chunk = regions[lod_index].get(visible.key) orelse continue;
                const terrain = mesh.drawRange(.terrain);
                const fluid = mesh.drawRange(.fluid);
                if ((terrain orelse fluid) == null) continue;
                const compact = mesh.isCompact();
                // Dedicated expanded fallback meshes are not backed by the
                // per-LOD vertex pools required for GPU indirect submission.
                // Omit only those meshes: compact candidates and pooled meshes
                // still benefit from GPU culling in the same frame.
                if (!compact and !mesh.isPooled()) continue;
                const bounds = chunk.worldBounds();
                const cell_size: f32 = if (compact) @as(f32, @floatFromInt(lod_chunk.regionSizeBlocks(visible.key.lod))) / @as(f32, @floatFromInt(mesh.compact_tile_width - 1)) else 0;
                self.gpu_candidates.append(self.allocator, .{
                    .min_point = .{ @as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, bounds.min_y - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z, 0 },
                    .max_point = .{ @as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, bounds.max_y - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z, 0 },
                    .model = visible.model,
                    .instance_params = .{ visible.mask_radius, visible.lod_fade, if (compact) cell_size else 0, if (compact) @max(16.0, cell_size * 2.0) else 0 },
                    .compact_words = .{ mesh.compact_sample_offset, mesh.compact_tile_width, 0, mesh.compactApronMask() },
                    .compact_metrics = .{ cell_size, @max(16.0, cell_size * 2.0), 0, 0 },
                    .terrain_command = cullCommandFor(mesh, terrain, compact, true),
                    .water_command = cullCommandFor(mesh, fluid, compact, false),
                    .lod_and_padding = .{ @intCast(lod_index), if (compact) 1 else 0, 0, 0 },
                    .ownership_bounds = visible.ownership_bounds,
                }) catch return;
                self.gpu_candidate_keys.append(self.allocator, visible.key) catch {
                    _ = self.gpu_candidates.pop();
                    return;
                };
            }
            if (profiling) |profile| profile.setGpuCullingCandidateCount(self.gpu_candidates.items.len);
            if (self.gpu_candidates.items.len < self.gpu_culling_threshold) {
                self.projection_frame = null;
                return;
            }
            const query = if (@hasDecl(RHI, "query")) self.rhi.query() else self.rhi;
            if (!query.supportsIndirectFirstInstance()) {
                self.projection_frame = null;
                return;
            }
            const distance_chunks = max_distance_chunks orelse config.getRadii()[lod_chunk.activeLODCount(config) - 1];
            if (comptime @hasDecl(RHI, "timing")) {
                const timing = self.rhi.timing();
                timing.beginPassTiming("LODGpuCullingComputeBarrier");
                defer timing.endPassTiming("LODGpuCullingComputeBarrier");
            }
            if (gpu.dispatch(query.getFrameIndex(), self.gpu_candidates.items, .{
                .planes = extractPlanes(view_proj),
                .candidate_count = 0,
                .max_distance_blocks = @as(f32, @floatFromInt(distance_chunks * CHUNK_SIZE_X)),
                .max_commands_per_lod = 0,
            })) self.gpu_culling_ready_frame = frame_serial else self.projection_frame = null;
            self.updateGpuCullingProfiling(profiling);
        }

        pub fn render(
            self: *Self,
            meshes: *const [LODLevel.count]MeshMap,
            regions: *const [LODLevel.count]RegionMap,
            config: ILODConfig,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            layer: LODRenderLayer,
            stats: ?*LODStats,
            profiling: ?*LODProfilingCollector,
        ) void {
            // Legacy callers have no render-frame epoch. Rebuild visibility on
            // every call without advancing `frame_serial`: advancing it here
            // could incorrectly retire GPU allocations/fences.
            self.beginFrame(self.frame_serial);
            self.maintenance_frame = self.frame_serial;
            const query = if (@hasDecl(RHI, "query")) self.rhi.query() else self.rhi;
            self.frame_index = query.getFrameIndex();
            // The legacy collection path cannot attach immutable ownership
            // metadata to compact draws. Route it through the frame projection,
            // which keeps direct, MDI, compact, and GPU candidate ownership
            // identical instead of drawing a whole partially covered parent.
            self.projection_frame = null;
            self.gpu_culling_ready_frame = null;
            _ = self.ensureCompactIndexBuffers(self.frame_serial);
            if (stats) |s| switch (layer) {
                .terrain => {
                    s.drawn = [_]u32{0} ** LODLevel.count;
                    s.instances = [_]u32{0} ** LODLevel.count;
                },
                .fluid => {
                    s.fluid_drawn = [_]u32{0} ** LODLevel.count;
                    s.fluid_instances = [_]u32{0} ** LODLevel.count;
                },
            };
            self.buildVisibilityProjection(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, config.getChunkRenderRadius(), true, true, stats, profiling) catch |err| {
                log.log.errWithTrace("Failed to build legacy LOD visibility: {}", .{err});
                return;
            };
            self.projection_frame = self.frame_serial;
            _ = self.renderProjectedLayer(meshes, layer, stats, profiling);
        }

        fn renderIndirectBatches(self: *Self, render_ctx: anytype, query: anytype, layer: LODRenderLayer) bool {
            if (comptime !supports_lod_indirect(@TypeOf(render_ctx), @TypeOf(query), @TypeOf(self.rhi))) return false;
            if (!query.supportsIndirectFirstInstance()) return false;
            if (self.instance_data.items.len == 0) return false;

            const resources = if (@hasDecl(RHI, "resourceManager")) self.rhi.resourceManager() else self.rhi;
            if (!@hasDecl(@TypeOf(resources), "updateBuffer")) return false;

            const fi = self.frame_index;
            const instance_buffer = self.instance_buffers[@intFromEnum(layer)][fi];
            const indirect_buffer = self.indirect_buffers[@intFromEnum(layer)][fi];
            if (self.instance_data.items.len > MAX_LOD_MDI_REGIONS) {
                log.log.warn("LOD MDI: instance overflow ({} > {}), falling back to CPU draw", .{ self.instance_data.items.len, MAX_LOD_MDI_REGIONS });
                return false;
            }

            var total_commands: usize = 0;
            for (self.draw_commands) |commands| total_commands += commands.items.len;
            if (total_commands == 0) return false;
            if (total_commands > MAX_LOD_MDI_REGIONS) {
                log.log.warn("LOD MDI: command overflow ({} > {}), falling back to CPU draw", .{ total_commands, MAX_LOD_MDI_REGIONS });
                return false;
            }

            for (0..LODLevel.count) |lod_idx| {
                if (self.draw_commands[lod_idx].items.len > 0 and self.vertex_pools[lod_idx].buffer_handle == 0) return false;
            }

            resources.updateBuffer(instance_buffer, 0, std.mem.sliceAsBytes(self.instance_data.items)) catch |err| {
                log.log.err("LOD MDI: failed to update instance buffer: {}", .{err});
                return false;
            };

            var merged_commands = std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand).empty;
            defer merged_commands.deinit(self.allocator);
            merged_commands.ensureTotalCapacity(self.allocator, total_commands) catch |err| {
                log.log.err("LOD MDI: failed to reserve command staging: {}", .{err});
                return false;
            };

            var lod_offsets: [LODLevel.count]usize = [_]usize{0} ** LODLevel.count;
            var lod_counts: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count;
            for (0..LODLevel.count) |lod_idx| {
                lod_offsets[lod_idx] = merged_commands.items.len;
                lod_counts[lod_idx] = @intCast(self.draw_commands[lod_idx].items.len);
                merged_commands.appendSliceAssumeCapacity(self.draw_commands[lod_idx].items);
            }

            resources.updateBuffer(indirect_buffer, 0, std.mem.sliceAsBytes(merged_commands.items)) catch |err| {
                log.log.err("LOD MDI: failed to update indirect buffer: {}", .{err});
                return false;
            };

            selectLODDescriptorStream(render_ctx, layer, false, false);
            render_ctx.setLODInstanceBuffer(instance_buffer);
            const stride = @sizeOf(rhi_types.DrawIndirectCommand);
            for (0..LODLevel.count) |lod_idx| {
                if (lod_counts[lod_idx] == 0) continue;
                const pool_buffer = self.vertex_pools[lod_idx].buffer_handle;
                render_ctx.drawIndirect(pool_buffer, indirect_buffer, lod_offsets[lod_idx] * stride, lod_counts[lod_idx], stride);
            }
            return true;
        }

        fn readyDiskRadiusForProjection(self: *Self, checker: ?ChunkChecker, checker_ctx: ?*anyopaque, camera_chunk_x: i32, camera_chunk_z: i32, max_radius: i32) i32 {
            _ = self;
            // Checker/context identity says nothing about mutable readiness.
            // The frame projection already shares this scan across both layers.
            return contiguousReadyDiskRadius(checker, checker_ctx, camera_chunk_x, camera_chunk_z, @max(max_radius, 0));
        }

        /// A non-empty descendant only owns its footprint when it is in this
        /// frame's distance selection. A canonical empty result is different:
        /// it is an authoritative no-geometry footprint and can suppress its
        /// parent even when it would not have produced a draw. Frustum culling
        /// is intentionally not part of this test. An off-frustum fine region
        /// cannot contribute false visible parent geometry, whereas a
        /// range-rejected region can leave a visible parent footprint.
        fn regionHasOwnershipCoverage(meshes: *const [LODLevel.count]MeshMap, regions: *const [LODLevel.count]RegionMap, key: LODRegionKey, camera_pos: Vec3, max_distance_chunks: ?i32) bool {
            const index = @intFromEnum(key.lod);
            if (regions[index].get(key)) |region| {
                if (region.isRenderable()) {
                    if (meshes[index].get(key)) |mesh| {
                        if (mesh.canonical_empty_coverage and mesh.isCoverageReady()) return true;
                        if (mesh.isCoverageReady()) {
                            if (max_distance_chunks == null or isRegionInRange(region.chunkBounds(), camera_pos, max_distance_chunks.?)) return true;
                        }
                    }
                }
            }
            return false;
        }

        fn subtreeHasOwnershipCoverage(meshes: *const [LODLevel.count]MeshMap, regions: *const [LODLevel.count]RegionMap, key: LODRegionKey, camera_pos: Vec3, max_distance_chunks: ?i32) bool {
            if (regionHasOwnershipCoverage(meshes, regions, key, camera_pos, max_distance_chunks)) return true;
            if (key.childKeys()) |children| for (children) |child| {
                if (subtreeHasOwnershipCoverage(meshes, regions, child, camera_pos, max_distance_chunks)) return true;
            };
            return false;
        }

        /// Subtract authoritative or range-selected descendants even through
        /// unavailable intermediate levels. Only retain an unpartitioned
        /// fallback when its subtree has no ownership coverage at any finer
        /// level.
        fn appendOwnershipProjection(self: *Self, meshes: *const [LODLevel.count]MeshMap, regions: *const [LODLevel.count]RegionMap, visible: VisibleRegion, owner: LODRegionKey, camera_pos: Vec3, max_distance_chunks: ?i32) !void {
            if (!owner.eql(visible.key)) {
                if (regionHasOwnershipCoverage(meshes, regions, owner, camera_pos, max_distance_chunks)) return;
            }
            if (owner.childKeys()) |children| {
                var has_covered_descendant = false;
                for (children) |child| {
                    if (subtreeHasOwnershipCoverage(meshes, regions, child, camera_pos, max_distance_chunks)) {
                        has_covered_descendant = true;
                        break;
                    }
                }
                if (!has_covered_descendant) {
                    var uncovered = visible;
                    uncovered.owner = owner;
                    uncovered.ownership_bounds = if (owner.eql(visible.key)) .{ 0, 0, 0, 0 } else visible.key.ownershipBounds(owner);
                    try self.projection_regions.append(self.allocator, uncovered);
                    return;
                }
                const start = self.projection_regions.items.len;
                for (children) |child| try self.appendOwnershipProjection(meshes, regions, visible, child, camera_pos, max_distance_chunks);
                // Four unchanged child footprints can remain one draw. A ready
                // child (including known air) never emits a parent footprint.
                const emitted = self.projection_regions.items[start..];
                var unchanged = emitted.len == 4;
                if (unchanged) for (emitted, children) |entry, child| {
                    if (entry.owner == null or !entry.owner.?.eql(child)) unchanged = false;
                };
                if (!unchanged) return;
                self.projection_regions.shrinkRetainingCapacity(start);
            }
            var owned = visible;
            owned.owner = owner;
            owned.ownership_bounds = if (owner.eql(visible.key)) .{ 0, 0, 0, 0 } else visible.key.ownershipBounds(owner);
            try self.projection_regions.append(self.allocator, owned);
        }

        fn buildVisibilityProjection(
            self: *Self,
            all_meshes: *const [LODLevel.count]MeshMap,
            all_regions: *const [LODLevel.count]RegionMap,
            config: ILODConfig,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            detail_render_radius: i32,
            legacy_masks: bool,
            preserve_layer_stats: bool,
            stats: ?*LODStats,
            profiling: ?*LODProfilingCollector,
        ) !void {
            self.projection_regions.clearRetainingCapacity();
            errdefer self.projection_regions.clearRetainingCapacity();
            if (!preserve_layer_stats) {
                if (stats) |s| {
                    s.drawn = [_]u32{0} ** LODLevel.count;
                    s.instances = [_]u32{0} ** LODLevel.count;
                    s.fluid_drawn = [_]u32{0} ** LODLevel.count;
                    s.fluid_instances = [_]u32{0} ** LODLevel.count;
                    s.gpu_terrain_candidates = 0;
                    s.gpu_fluid_candidates = 0;
                }
            }

            const frustum = Frustum.fromViewProj(view_proj);
            const disable_frustum = engine_core.envFlag("ZIGCRAFT_LOD_DISABLE_FRUSTUM", false);
            const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
            const chunk_radius = @max(detail_render_radius, 0);
            const ready_detail_radius = if (legacy_masks) -1 else self.readyDiskRadiusForProjection(chunk_checker, checker_ctx, camera_chunk.chunk_x, camera_chunk.chunk_z, chunk_radius);
            const handoff_mask_radius = readyDiskMaskRadius(ready_detail_radius);
            var i = lod_chunk.activeLODCount(config);
            while (i > 0) {
                i -= 1;
                const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
                var telemetry = @import("lod_stats.zig").LODVisibilityLevelSnapshot{};
                var iter = all_meshes[i].iterator();
                while (iter.next()) |entry| {
                    telemetry.candidates += 1;
                    const mesh = entry.value_ptr.*;
                    if (!mesh.isReady()) {
                        telemetry.rejected_not_ready += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    if ((mesh.drawRange(.terrain) orelse mesh.drawRange(.fluid)) == null) {
                        telemetry.rejected_no_draw += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    const chunk = all_regions[i].get(entry.key_ptr.*) orelse {
                        telemetry.rejected_missing_region += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    };
                    if (!chunk.isRenderable()) {
                        telemetry.rejected_not_renderable += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    const bounds = chunk.worldBounds();
                    const chunk_bounds = chunk.chunkBounds();
                    // Cheap radial and frustum tests intentionally precede the
                    // potentially large chunk-coverage scan.
                    if (max_distance_chunks) |max_dist| {
                        if (!isRegionInRange(chunk_bounds, camera_pos, max_dist)) {
                            telemetry.rejected_range += 1;
                            if (profiling) |profile| profile.addRejected();
                            continue;
                        }
                    }
                    if (use_frustum and !disable_frustum and !isRegionInFrustum(frustum, bounds, camera_pos)) {
                        telemetry.rejected_frustum += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }

                    const exact_mask_radius = config.calculateMaskRadius();
                    var mask_radius = if (legacy_masks) conservativeChunkDiskMaskRadius(exact_mask_radius) else handoff_mask_radius;
                    if (chunk_checker) |checker| {
                        if (checker_ctx) |ctx_ptr| {
                            const coverage_timer = if (profiling) |profile| profile.begin() else null;
                            const cov = self.isCoveredByChunks(bounds, checker, ctx_ptr, camera_chunk.chunk_x, camera_chunk.chunk_z, chunk_radius);
                            if (profiling) |profile| {
                                profile.end(.coverage, coverage_timer);
                                profile.addCoverage();
                            }
                            telemetry.coverage_checks += 1;
                            if (cov.covered) {
                                telemetry.rejected_chunk_coverage += 1;
                                if (profiling) |profile| profile.addRejected();
                                continue;
                            }
                            if (legacy_masks) {
                                if (cov.missing_chunk_in_radius) {
                                    if (!cov.has_chunk_coverage_in_radius) mask_radius = LOD_UNMASKED_SENTINEL;
                                } else {
                                    mask_radius = exact_mask_radius;
                                }
                            }
                        }
                    }

                    const ownership_start = self.projection_regions.items.len;
                    try self.appendOwnershipProjection(all_meshes, all_regions, .{
                        .key = entry.key_ptr.*,
                        .model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z)),
                        .mask_radius = mask_radius,
                        .lod_fade = 1.0,
                    }, entry.key_ptr.*, camera_pos, max_distance_chunks);
                    if (self.projection_regions.items.len == ownership_start) {
                        telemetry.rejected_finer_coverage += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    telemetry.accepted += 1;
                    if (profiling) |profile| profile.addVisible();
                }
                if (profiling) |profile| profile.addVisibilityLevel(lod, telemetry);
            }
        }

        /// Returns false only when a prepared GPU frame could not be submitted;
        /// callers must rebuild the CPU projection with normal culling first.
        fn renderProjectedLayer(self: *Self, all_meshes: *const [LODLevel.count]MeshMap, layer: LODRenderLayer, stats: ?*LODStats, profiling: ?*LODProfilingCollector) bool {
            const query = if (@hasDecl(RHI, "query")) self.rhi.query() else self.rhi;
            const render_ctx = if (@hasDecl(RHI, "renderContext")) self.rhi.renderContext() else self.rhi;
            self.frame_index = query.getFrameIndex();
            defer if (@hasDecl(@TypeOf(render_ctx), "setInstanceBuffer")) render_ctx.setInstanceBuffer(0);
            selectLODDescriptorStream(render_ctx, layer, false, false);
            render_ctx.setLODInstanceBuffer(self.instance_buffers[@intFromEnum(layer)][self.frame_index]);
            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();
            self.compact_fallback_regions.clearRetainingCapacity();
            for (&self.draw_commands) |*commands| commands.clearRetainingCapacity();
            self.updateGpuCullingProfiling(profiling);
            if (stats) |s| {
                s.gpu_culling_overflows = self.gpu_culling_overflow_count;
                s.gpu_culling_requested = self.gpu_culling_requested;
                s.gpu_culling_threshold = @intCast(@min(self.gpu_culling_threshold, std.math.maxInt(u32)));
                s.gpu_culling_candidate_count = 0;
                s.gpu_culling_draw_submissions = 0;
                if (self.gpu_culling) |gpu| {
                    const diagnostics = gpu.diagnostics();
                    s.gpu_culling_validation_mismatches = diagnostics.validation_mismatch_count;
                    s.gpu_culling_validation_generation = diagnostics.validation_generation;
                    s.gpu_culling_validation_completed_generation = diagnostics.validation_completed_generation;
                    s.gpu_culling_validation_completed_count = diagnostics.validation_completed_count;
                }
            }

            const gpu_frame_prepared = self.projection_frame != null and self.gpu_culling_ready_frame == self.projection_frame;
            const gpu_submitted = self.renderGpuCulledLayer(layer, stats, profiling, render_ctx, query);
            if (gpu_frame_prepared and !gpu_submitted) return false;
            // GPU and CPU fallbacks use distinct immutable descriptor streams.
            // Re-select direct before any fallback binding or draw is recorded.
            selectLODDescriptorStream(render_ctx, layer, false, false);
            render_ctx.setLODInstanceBuffer(self.instance_buffers[@intFromEnum(layer)][self.frame_index]);

            {
                var compact_timing_started = false;
                const compact_timing_name = if (layer == .terrain) "LODCompactTerrainPass" else "LODCompactWaterPass";
                defer if (compact_timing_started and @hasDecl(RHI, "timing")) self.rhi.timing().endPassTiming(compact_timing_name);
                for (self.projection_regions.items) |visible| {
                    const lod_idx = @intFromEnum(visible.key.lod);
                    const mesh = all_meshes[lod_idx].get(visible.key) orelse continue;
                    const range = mesh.drawRange(layer) orelse continue;
                    if (!mesh.isReady() or range.count == 0) continue;
                    if (gpu_submitted and self.gpuCandidateDraws(visible.key, layer)) continue;
                    if (mesh.isCompact()) {
                        if (!compact_timing_started and @hasDecl(RHI, "timing")) {
                            self.rhi.timing().beginPassTiming(compact_timing_name);
                            compact_timing_started = true;
                        }
                        const result = self.renderCompactMesh(render_ctx, visible, mesh, layer);
                        if (result == .drawn) {
                            if (profiling) |profile| profile.addCompactSubmission();
                            if (stats) |s| if (layer == .fluid) {
                                s.fluid_drawn[lod_idx] += 1;
                                s.fluid_instances[lod_idx] += 1;
                            } else {
                                s.drawn[lod_idx] += 1;
                                s.instances[lod_idx] += 1;
                            };
                        } else {
                            self.noteCompactRenderFailure(mesh, result, profiling);
                            // Draw parent fallbacks only after the compact pass
                            // scope closes so expanded draws do not contaminate
                            // compact GPU timing.
                            self.compact_fallback_regions.append(self.allocator, visible) catch {};
                        }
                        continue;
                    }
                    const lod_y_offset: f32 = if (layer == .fluid) 0.0 else -0.05;
                    var instance = rhi_types.InstanceData{ .model = visible.model, .mask_radius = visible.mask_radius, .lod_fade = visible.lod_fade, .padding = .{ 0, 0 }, .ownership_bounds = visible.ownership_bounds };
                    instance.model.data[3][1] += lod_y_offset;
                    self.instance_data.append(self.allocator, instance) catch continue;
                    self.draw_list.append(self.allocator, mesh) catch {
                        _ = self.instance_data.pop();
                        continue;
                    };
                    if (mesh.isPooled()) {
                        self.draw_commands[lod_idx].append(self.allocator, .{
                            .vertexCount = range.count,
                            .instanceCount = 1,
                            .firstVertex = mesh.firstVertex(range),
                            .firstInstance = @intCast(self.instance_data.items.len - 1),
                        }) catch {
                            _ = self.draw_list.pop();
                            _ = self.instance_data.pop();
                            continue;
                        };
                    }
                    if (stats) |s| {
                        if (layer == .fluid) {
                            s.fluid_drawn[lod_idx] += 1;
                            s.fluid_instances[lod_idx] += 1;
                        } else {
                            s.drawn[lod_idx] += 1;
                            s.instances[lod_idx] += 1;
                        }
                    }
                }
            }
            for (self.compact_fallback_regions.items) |visible| {
                _ = self.renderParentFallback(all_meshes, visible, layer, render_ctx, profiling);
            }
            if (self.instance_data.items.len == 0) return true;
            selectLODDescriptorStream(render_ctx, layer, false, false);
            render_ctx.setLODInstanceBuffer(self.instance_buffers[@intFromEnum(layer)][self.frame_index]);
            const indirect_drawn = self.enable_mdi and self.renderIndirectBatches(render_ctx, query, layer);
            for (self.draw_list.items, 0..) |mesh, index| {
                if (indirect_drawn and mesh.isPooled()) continue;
                const instance = self.instance_data.items[index];
                const range = mesh.drawRange(layer) orelse continue;
                render_ctx.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
                if (@hasDecl(@TypeOf(render_ctx), "setLODOwnershipBounds")) render_ctx.setLODOwnershipBounds(instance.ownership_bounds) else std.debug.assert(instance.ownership_bounds[2] == 0);
                if (@hasDecl(@TypeOf(render_ctx), "drawOffset")) {
                    render_ctx.drawOffset(mesh.bufferHandle(), range.count, .triangles, mesh.vertexOffset() + range.offset);
                } else render_ctx.draw(mesh.bufferHandle(), range.count, .triangles);
            }
            return true;
        }

        fn gpuCandidateDraws(self: *const Self, key: LODRegionKey, layer: LODRenderLayer) bool {
            for (self.gpu_candidate_keys.items, self.gpu_candidates.items) |candidate_key, candidate| {
                if (!std.meta.eql(candidate_key, key)) continue;
                const command = if (layer == .fluid) candidate.water_command else candidate.terrain_command;
                if (command.count == 0) return false;
                // Indirect compact streams are currently partitioned by LOD,
                // not grid width. If async density changes produce two widths
                // in one LOD, no single index buffer can draw that stream; keep
                // every affected tile on the width-correct direct path.
                if (candidate.lod_and_padding[1] != 0) return self.gpuCompactWidthForLOD(key.lod, layer) != null;
                return true;
            }
            return false;
        }

        fn renderParentFallback(self: *Self, all_meshes: *const [LODLevel.count]MeshMap, child: VisibleRegion, layer: LODRenderLayer, render_ctx: anytype, profiling: ?*LODProfilingCollector) bool {
            var child_key = child.key;
            var child_model = child.model;
            while (child_key.parentKey()) |parent_key| {
                const child_size: i32 = @intCast(child_key.lod.chunksPerSide() * CHUNK_SIZE_X);
                const parent_size: i32 = @intCast(parent_key.lod.chunksPerSide() * CHUNK_SIZE_X);
                child_model.data[3][0] += @floatFromInt(parent_key.rx * parent_size - child_key.rx * child_size);
                child_model.data[3][2] += @floatFromInt(parent_key.rz * parent_size - child_key.rz * child_size);
                const mesh = all_meshes[@intFromEnum(parent_key.lod)].get(parent_key) orelse {
                    child_key = parent_key;
                    continue;
                };
                const range = mesh.drawRange(layer) orelse {
                    child_key = parent_key;
                    continue;
                };
                if (!mesh.isReady() or range.count == 0) {
                    child_key = parent_key;
                    continue;
                }
                const parent_visible = VisibleRegion{
                    .key = parent_key,
                    .model = child_model,
                    .mask_radius = child.mask_radius,
                    .lod_fade = 1.0,
                    .owner = child.owner orelse child.key,
                    .ownership_bounds = parent_key.ownershipBounds(child.owner orelse child.key),
                };
                if (mesh.isCompact()) {
                    const result = self.renderCompactMesh(render_ctx, parent_visible, mesh, layer);
                    if (result == .drawn) {
                        if (profiling) |profile| profile.addCompactSubmission();
                        return true;
                    }
                    self.noteCompactRenderFailure(mesh, result, profiling);
                    child_key = parent_key;
                    continue;
                }
                selectLODDescriptorStream(render_ctx, layer, false, false);
                render_ctx.setLODInstanceBuffer(self.instance_buffers[@intFromEnum(layer)][self.frame_index]);
                render_ctx.setModelMatrix(child_model, Vec3.one, child.mask_radius);
                if (@hasDecl(@TypeOf(render_ctx), "setLODOwnershipBounds")) render_ctx.setLODOwnershipBounds(parent_visible.ownership_bounds) else return false;
                if (@hasDecl(@TypeOf(render_ctx), "drawOffset")) {
                    render_ctx.drawOffset(mesh.bufferHandle(), range.count, .triangles, mesh.vertexOffset() + range.offset);
                } else {
                    render_ctx.draw(mesh.bufferHandle(), range.count, .triangles);
                }
                return true;
            }
            return false;
        }

        fn noteCompactRenderFailure(_: *Self, mesh: *LODMesh, result: CompactRenderResult, profiling: ?*LODProfilingCollector) void {
            switch (result) {
                .drawn => unreachable,
                .unavailable => if (profiling) |profile| profile.addCompactDrawUnavailable(),
                .backend_failed => {
                    if (profiling) |profile| profile.addCompactDrawFailure();
                    if (mesh.noteCompactBackendDrawFailure()) {
                        log.log.warn("LOD{} compact draw failed {} times after preflight; scheduling expanded fallback", .{ @intFromEnum(mesh.lodLevel()), LODMesh.COMPACT_BACKEND_FAILURE_LIMIT });
                    }
                },
            }
        }

        fn renderCompactMesh(self: *Self, render_ctx: anytype, visible: VisibleRegion, mesh: *LODMesh, layer: LODRenderLayer) CompactRenderResult {
            if (comptime !@hasDecl(@TypeOf(render_ctx), "drawCompactLOD") or !@hasDecl(@TypeOf(render_ctx), "setLODCompactSampleBuffer") or !@hasDecl(@TypeOf(render_ctx), "setLODDescriptorStream")) return .unavailable;
            const lod = mesh.lodLevel();
            if ((lod != .lod3 and lod != .lod4) or self.compact_pool.buffer_handle == 0 or mesh.compact_tile_width < 2) return .unavailable;
            selectLODDescriptorStream(render_ctx, layer, true, false);
            render_ctx.setLODCompactSampleBuffer(self.compact_pool.buffer_handle);
            const index_buffer = self.compactIndexBuffer(lod, mesh.compact_tile_width, layer);
            if (index_buffer == 0) return .unavailable;
            const index_count: u32 = @intCast(compactGridIndexCount(mesh.compact_tile_width, layer == .terrain));
            if (index_count == 0) return .unavailable;
            var model = visible.model;
            // Match expanded terrain's handoff bias. Water remains at its true
            // surface height so compact/expanded representation changes do not
            // introduce a vertical seam.
            if (layer == .terrain) model.data[3][1] -= 0.05;
            if (render_ctx.drawCompactLOD(index_buffer, index_count, .{
                .model = model,
                .mask_radius = visible.mask_radius,
                .lod_fade = visible.lod_fade,
                .sample_offset = mesh.compact_sample_offset,
                .width = mesh.compact_tile_width,
                .cell_size = @as(f32, @floatFromInt(lod_chunk.regionSizeBlocks(lod))) / @as(f32, @floatFromInt(mesh.compact_tile_width - 1)),
                .layer = if (layer == .fluid) 1 else 0,
                .skirt_depth = @max(16.0, @as(f32, @floatFromInt(lod_chunk.regionSizeBlocks(lod))) / @as(f32, @floatFromInt(mesh.compact_tile_width - 1)) * 2.0),
                .edge_masks = mesh.compactApronMask(),
                .ownership_bounds = visible.ownership_bounds,
            })) {
                mesh.resetCompactBackendDrawFailures();
                return .drawn;
            }
            return .backend_failed;
        }

        fn renderGpuCulledLayer(self: *Self, layer: LODRenderLayer, stats: ?*LODStats, profiling: ?*LODProfilingCollector, render_ctx: anytype, query: anytype) bool {
            const frame = self.projection_frame orelse return false;
            if (self.gpu_culling_ready_frame != frame) return false;
            const gpu = self.gpu_culling orelse return false;
            if (!@hasDecl(@TypeOf(render_ctx), "drawIndirectCount")) return false;
            if (!query.supportsIndirectFirstInstance() or self.gpu_candidates.items.len < self.gpu_culling_threshold) return false;
            var has_standard = false;
            var has_compact = false;
            for (self.gpu_candidates.items) |candidate| {
                const lod_index = candidate.lod_and_padding[0];
                if (lod_index >= LODLevel.count) return false;
                const command = if (layer == .fluid) candidate.water_command else candidate.terrain_command;
                if (candidate.lod_and_padding[1] == 0 and command.count != 0) {
                    has_standard = true;
                    if (self.vertex_pools[lod_index].buffer_handle == 0) return false;
                }
                if (candidate.lod_and_padding[1] != 0 and command.count != 0) has_compact = true;
            }
            const fi = self.frame_index;
            // Complete validation before emitting any graphics command.  A
            // false result above is safe to fall back to CPU rendering; after
            // the first draw is recorded it is not.
            if ((has_standard or has_compact) and (gpu.countBuffer(fi) == 0 or gpu.indirectBuffer(fi, layer == .fluid, false) == 0)) return false;
            if (has_standard and gpu.instanceBuffer(fi, layer == .fluid, false) == 0) return false;
            if (has_compact) {
                if (!@hasDecl(@TypeOf(render_ctx), "drawCompactLODIndirectCount") or
                    !@hasDecl(@TypeOf(render_ctx), "setLODCompactSampleBuffer") or
                    !@hasDecl(@TypeOf(render_ctx), "setLODCompactInstanceBuffer") or
                    !@hasDecl(@TypeOf(render_ctx), "setLODDescriptorStream") or
                    self.compact_pool.buffer_handle == 0 or
                    gpu.instanceBuffer(fi, layer == .fluid, true) == 0 or
                    gpu.indirectBuffer(fi, layer == .fluid, true) == 0)
                {
                    return false;
                }
                inline for (.{ LODLevel.lod3, LODLevel.lod4 }) |lod| if (self.gpuCompactWidthForLOD(lod, layer)) |width| {
                    if (self.compactIndexBuffer(lod, width, layer) == 0) return false;
                };
            }
            selectLODDescriptorStream(render_ctx, layer, false, true);
            render_ctx.setLODInstanceBuffer(gpu.instanceBuffer(fi, layer == .fluid, false));
            const commands = gpu.indirectBuffer(fi, layer == .fluid, false);
            const counts = gpu.countBuffer(fi);
            const stride = @sizeOf(rhi_types.DrawIndirectCommand);
            if (has_standard) for (0..LODLevel.count) |lod_index| {
                if (self.vertex_pools[lod_index].buffer_handle == 0) continue;
                if (!render_ctx.drawIndirectCount(self.vertex_pools[lod_index].buffer_handle, commands, lod_index * MAX_LOD_MDI_REGIONS * stride, counts, (if (layer == .fluid) LODLevel.count + lod_index else lod_index) * @sizeOf(u32), MAX_LOD_MDI_REGIONS, stride)) return false;
            };
            if (has_compact) {
                selectLODDescriptorStream(render_ctx, layer, true, true);
                render_ctx.setLODCompactSampleBuffer(self.compact_pool.buffer_handle);
                render_ctx.setLODCompactInstanceBuffer(gpu.instanceBuffer(fi, layer == .fluid, true));
                const compact_commands = gpu.indirectBuffer(fi, layer == .fluid, true);
                const compact_count_base: usize = if (layer == .fluid) LODLevel.count * 3 else LODLevel.count * 2;
                const compact_timing_name = if (layer == .terrain) "LODCompactTerrainPass" else "LODCompactWaterPass";
                if (comptime @hasDecl(RHI, "timing")) {
                    const timing = self.rhi.timing();
                    timing.beginPassTiming(compact_timing_name);
                    defer timing.endPassTiming(compact_timing_name);
                }
                for ([_]LODLevel{ .lod3, .lod4 }) |lod| {
                    const lod_index = @intFromEnum(lod);
                    const width = self.gpuCompactWidthForLOD(lod, layer) orelse continue;
                    const index_buffer = self.compactIndexBuffer(lod, width, layer);
                    if (!render_ctx.drawCompactLODIndirectCount(index_buffer, compact_commands, lod_index * MAX_LOD_MDI_REGIONS * @sizeOf(rhi_types.DrawIndexedIndirectCommand), counts, (compact_count_base + lod_index) * @sizeOf(u32), MAX_LOD_MDI_REGIONS)) return false;
                }
                if (profiling) |profile| profile.addCompactSubmission();
            }
            if (stats) |s| {
                // GPU counters remain device-local; keep submitted streams distinct
                // from CPU visibility counts without introducing a readback stall.
                const submitted: u32 = @intCast(self.gpu_candidates.items.len);
                if (layer == .fluid) s.gpu_fluid_candidates = submitted else s.gpu_terrain_candidates = submitted;
                s.gpu_culling_candidate_count = submitted;
                s.gpu_culling_draw_submissions +|= 1;
                const diagnostics = gpu.diagnostics();
                s.gpu_culling_overflows = self.gpu_culling_overflow_count + diagnostics.overflow_count;
                s.gpu_culling_validation_mismatches = diagnostics.validation_mismatch_count;
                s.gpu_culling_validation_generation = diagnostics.validation_generation;
                s.gpu_culling_validation_completed_generation = diagnostics.validation_completed_generation;
                s.gpu_culling_validation_completed_count = diagnostics.validation_completed_count;
            }
            if (self.gpu_culling_submitted_frame != frame) {
                if (profiling) |profile| profile.addGpuCullingSubmission();
                self.gpu_culling_submitted_frame = frame;
            }
            self.updateGpuCullingProfiling(profiling);
            return true;
        }

        fn updateGpuCullingProfiling(self: *Self, profiling: ?*LODProfilingCollector) void {
            const profile = profiling orelse return;
            profile.setGpuCullingConfiguration(self.gpu_culling_requested, self.gpu_culling_threshold);
            if (self.gpu_culling) |gpu| {
                const diagnostics = gpu.diagnostics();
                profile.setGpuCullingDiagnostics(
                    self.gpu_culling_overflow_count +| diagnostics.overflow_count,
                    diagnostics.validation_mismatch_count,
                    diagnostics.validation_generation,
                    diagnostics.validation_completed_generation,
                    diagnostics.validation_completed_count,
                );
            } else profile.setGpuCullingDiagnostics(self.gpu_culling_overflow_count, 0, 0, 0, 0);
        }

        fn compactIndexBuffer(self: *const Self, lod: LODLevel, width: u32, layer: LODRenderLayer) rhi_types.BufferHandle {
            const upload_frame = self.compact_index_upload_frame orelse return 0;
            if (self.frame_serial <= upload_frame) return 0;
            if (lod != .lod3 and lod != .lod4) return 0;
            const width_index = compactGridVariant(width) orelse return 0;
            return self.compact_index_buffers[@intFromEnum(lod) - @intFromEnum(LODLevel.lod3)][if (layer == .fluid) 1 else 0][width_index];
        }

        fn gpuCompactWidthForLOD(self: *const Self, lod: LODLevel, layer: LODRenderLayer) ?u32 {
            var result: ?u32 = null;
            for (self.gpu_candidates.items) |candidate| {
                if (candidate.lod_and_padding[0] != @intFromEnum(lod) or candidate.lod_and_padding[1] == 0) continue;
                const command = if (layer == .fluid) candidate.water_command else candidate.terrain_command;
                if (command.count == 0) continue;
                const width = candidate.compact_words[1];
                if (result) |existing| {
                    if (existing != width) return null;
                } else result = width;
            }
            return result;
        }

        fn collectVisibleMeshes(
            self: *Self,
            all_meshes: *const [LODLevel.count]MeshMap,
            all_regions: *const [LODLevel.count]RegionMap,
            lod: LODLevel,
            config: ILODConfig,
            _: Mat4,
            camera_pos: Vec3,
            frustum: Frustum,
            lod_y_offset: f32,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            layer: LODRenderLayer,
            stats: ?*LODStats,
            profiling: ?*LODProfilingCollector,
        ) !void {
            const meshes = &all_meshes[@intFromEnum(lod)];
            const regions = &all_regions[@intFromEnum(lod)];
            const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);
            const disable_frustum = engine_core.envFlag("ZIGCRAFT_LOD_DISABLE_FRUSTUM", false);
            var diag = RenderDiag{};
            var lod_rendered: u32 = 0;
            var lod_covered: u32 = 0;
            var first_missing_cx: i32 = 0;
            var first_missing_cz: i32 = 0;
            var first_missing_in_radius: bool = false;

            const camera_chunk_diag = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
            const pc_x_diag = camera_chunk_diag.chunk_x;
            const pc_z_diag = camera_chunk_diag.chunk_z;

            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                diag.meshes_seen += 1;
                const mesh = entry.value_ptr.*;
                // The legacy immediate path has no indexed compact submission
                // context. Never reinterpret compact samples as expanded
                // vertices; frame-based rendering owns compact draws.
                if (mesh.isCompact()) continue;
                const draw_range = mesh.drawRange(layer) orelse {
                    diag.not_ready += 1;
                    if (profiling) |profile| profile.addRejected();
                    continue;
                };
                if (!mesh.isReady() or draw_range.count == 0) {
                    diag.not_ready += 1;
                    if (profiling) |profile| profile.addRejected();
                    continue;
                }
                if (regions.get(entry.key_ptr.*)) |chunk| {
                    if (!chunk.isRenderable()) {
                        diag.bad_state += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    if (self.isCoveredByFinerLOD(chunk, config)) {
                        diag.covered_finer_lod += 1;
                        if (profiling) |profile| profile.addRejected();
                        continue;
                    }
                    const bounds = chunk.worldBounds();
                    const chunk_bounds = chunk.chunkBounds();

                    if (max_distance_chunks) |max_dist| {
                        if (!isRegionInRange(chunk_bounds, camera_pos, max_dist)) {
                            diag.out_of_range += 1;
                            if (profiling) |profile| profile.addRejected();
                            continue;
                        }
                    }

                    if (use_frustum and !disable_frustum) {
                        if (!isRegionInFrustum(frustum, bounds, camera_pos)) {
                            diag.frustum_culled += 1;
                            if (profiling) |profile| profile.addRejected();
                            continue;
                        }
                    }

                    const exact_mask_radius = config.calculateMaskRadius();
                    var mask_radius = conservativeChunkDiskMaskRadius(exact_mask_radius);
                    if (chunk_checker) |checker| {
                        if (checker_ctx) |ctx_ptr| {
                            const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
                            const pc_x = camera_chunk.chunk_x;
                            const pc_z = camera_chunk.chunk_z;
                            const chunk_radius = config.getChunkRenderRadius();
                            const coverage_timer = if (profiling) |profile| profile.begin() else null;
                            const cov = self.isCoveredByChunks(bounds, checker, ctx_ptr, pc_x, pc_z, chunk_radius);
                            if (profiling) |profile| {
                                profile.end(.coverage, coverage_timer);
                                profile.addCoverage();
                            }
                            if (cov.covered) {
                                lod_covered += 1;
                                diag.covered_chunks += 1;
                                if (profiling) |profile| profile.addRejected();
                                continue;
                            }
                            if (lod_rendered == 0) {
                                first_missing_cx = cov.missing_cx;
                                first_missing_cz = cov.missing_cz;
                                first_missing_in_radius = cov.missing_chunk_in_radius;
                            }
                            // A single LOD instance cannot exclude individual loaded
                            // chunks while this boundary region is incomplete. Keep
                            // the conservative inner chunk disk until all of its detail
                            // cells are ready, then switch to exact chunk ownership.
                            if (cov.missing_chunk_in_radius) {
                                if (!cov.has_chunk_coverage_in_radius) mask_radius = LOD_UNMASKED_SENTINEL;
                            } else {
                                mask_radius = exact_mask_radius;
                            }
                        }
                    }

                    lod_rendered += 1;

                    const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                    // Parent coverage, not camera distance, owns LOD handoff. A
                    // distance-band cutoff creates concentric visible rings while
                    // the parent already provides complete fallback terrain.
                    const fade = chunk.transitionFadeProgress();
                    try self.instance_data.append(self.allocator, .{
                        .model = model,
                        .mask_radius = mask_radius,
                        .lod_fade = fade,
                        .padding = .{ 0, 0 },
                    });
                    try self.draw_list.append(self.allocator, mesh);
                    if (mesh.isPooled()) {
                        try self.draw_commands[@intFromEnum(lod)].append(self.allocator, .{
                            .vertexCount = draw_range.count,
                            .instanceCount = 1,
                            .firstVertex = mesh.firstVertex(draw_range),
                            .firstInstance = @intCast(self.instance_data.items.len - 1),
                        });
                    }
                    diag.drawn += 1;
                    if (profiling) |profile| profile.addVisible();
                    if (stats) |s| {
                        const lod_idx = @intFromEnum(lod);
                        if (layer == .fluid) {
                            s.fluid_drawn[lod_idx] += 1;
                            s.fluid_instances[lod_idx] += 1;
                        } else {
                            s.drawn[lod_idx] += 1;
                            s.instances[lod_idx] += 1;
                        }
                    }
                } else {
                    diag.missing_region += 1;
                    if (profiling) |profile| profile.addRejected();
                }
            }

            if (diag_enabled) {
                const S = struct {
                    var counter: [LODLevel.count]u64 = .{0} ** LODLevel.count;
                };
                const lod_idx = @intFromEnum(lod);
                S.counter[lod_idx] += 1;
                if (S.counter[lod_idx] % 120 == 1) {
                    log.log.info("LOD_RENDER_DIAG lod={} meshes={} drawn={} not_ready={} bad_state={} no_region={} finer={} chunk_cov={} frustum={} range={} frustum_disabled={} cam_chunk=({}, {})", .{
                        lod_idx,
                        diag.meshes_seen,
                        diag.drawn,
                        diag.not_ready,
                        diag.bad_state,
                        diag.missing_region,
                        diag.covered_finer_lod,
                        diag.covered_chunks,
                        diag.frustum_culled,
                        diag.out_of_range,
                        disable_frustum,
                        pc_x_diag,
                        pc_z_diag,
                    });
                }
            }

            if (lod_rendered > 0 or lod_covered > 0) {
                const missing_dx = first_missing_cx - pc_x_diag;
                const missing_dz = first_missing_cz - pc_z_diag;
                const missing_dist_sq = missing_dx * missing_dx + missing_dz * missing_dz;
                // Only log every 300 frames to reduce spam
                if (lod_covered == 0 and lod_rendered > 0) {
                    // Track a static counter for throttling
                    const S = struct {
                        var counter: u64 = 0;
                    };
                    S.counter += 1;
                    if (build_options.startup_diagnostic_seconds == 0 and S.counter % 300 == 1) {
                        log.log.debug("LOD_DIAG: rendered={} covered={} first_missing=({},{}) missing_dist2={} in_radius={} cam=({d:.0},{d:.0}) cam_chunk=({},{})", .{
                            lod_rendered,     lod_covered,
                            first_missing_cx, first_missing_cz,
                            missing_dist_sq,  first_missing_in_radius,
                            camera_pos.x,     camera_pos.z,
                            pc_x_diag,        pc_z_diag,
                        });
                    }
                }
            }
        }

        fn isCoveredByFinerLOD(
            _: *Self,
            chunk: *const LODChunk,
            config: ILODConfig,
        ) bool {
            return chunk.isCoveredByFinerLOD(config.getFallbackMissingChildThreshold());
        }

        const CoverageResult = struct {
            covered: bool,
            missing_cx: i32,
            missing_cz: i32,
            missing_chunk_in_radius: bool,
            has_chunk_coverage_in_radius: bool,
        };

        fn isCoveredByChunks(
            _: *Self,
            bounds: LODChunk.WorldBounds,
            checker: ChunkChecker,
            ctx: *anyopaque,
            pc_x: i32,
            pc_z: i32,
            lod0_radius: i32,
        ) CoverageResult {
            const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
            const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
            const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
            const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

            const radius_sq: i64 = @as(i64, lod0_radius) * @as(i64, lod0_radius);

            var first_outside_cx: i32 = 0;
            var first_outside_cz: i32 = 0;
            var has_outside_radius = false;
            var first_missing_cx: i32 = 0;
            var first_missing_cz: i32 = 0;
            var has_missing_in_radius = false;
            var has_chunk_coverage_in_radius = false;

            var cz = min_cz;
            while (cz <= max_cz) : (cz += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    const dx: i64 = @as(i64, cx) - @as(i64, pc_x);
                    const dz: i64 = @as(i64, cz) - @as(i64, pc_z);
                    if (dx * dx + dz * dz > radius_sq) {
                        if (!has_outside_radius) {
                            has_outside_radius = true;
                            first_outside_cx = cx;
                            first_outside_cz = cz;
                        }
                        continue;
                    }
                    if (checker(cx, cz, ctx)) {
                        has_chunk_coverage_in_radius = true;
                    } else if (!has_missing_in_radius) {
                        has_missing_in_radius = true;
                        first_missing_cx = cx;
                        first_missing_cz = cz;
                    }
                }
            }

            if (has_missing_in_radius) {
                return .{ .covered = false, .missing_cx = first_missing_cx, .missing_cz = first_missing_cz, .missing_chunk_in_radius = true, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
            }

            if (has_outside_radius) {
                return .{ .covered = false, .missing_cx = first_outside_cx, .missing_cz = first_outside_cz, .missing_chunk_in_radius = false, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
            }
            return .{ .covered = true, .missing_cx = 0, .missing_cz = 0, .missing_chunk_in_radius = false, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
        }

        fn dedicatedMeshResources(self: *Self) LODMeshResources {
            const Adapter = struct {
                fn createBuffer(ptr: *anyopaque, size: usize, usage: rhi_types.BufferUsage) rhi_types.RhiError!rhi_types.BufferHandle {
                    const renderer: *Self = @ptrCast(@alignCast(ptr));
                    // Reserve before GPU creation, including failure cleanup:
                    // retiring any tracked handle must never need allocation.
                    try renderer.direct_buffers.ensureUnusedCapacity(renderer.allocator, 1);
                    const base = LODMeshResources.fromProvider(RHI, &renderer.rhi);
                    const handle = try base.createBuffer(size, usage);
                    renderer.direct_buffers.appendAssumeCapacity(.{ .handle = handle, .size = size });
                    return handle;
                }
                fn uploadBuffer(ptr: *anyopaque, handle: rhi_types.BufferHandle, data: []const u8) rhi_types.RhiError!void {
                    const renderer: *Self = @ptrCast(@alignCast(ptr));
                    return LODMeshResources.fromProvider(RHI, &renderer.rhi).uploadBuffer(handle, data);
                }
                fn updateBuffer(ptr: *anyopaque, handle: rhi_types.BufferHandle, offset: usize, data: []const u8) rhi_types.RhiError!void {
                    const renderer: *Self = @ptrCast(@alignCast(ptr));
                    return LODMeshResources.fromProvider(RHI, &renderer.rhi).updateBuffer(handle, offset, data);
                }
                fn destroyBuffer(ptr: *anyopaque, handle: rhi_types.BufferHandle) void {
                    const renderer: *Self = @ptrCast(@alignCast(ptr));
                    const base = LODMeshResources.fromProvider(RHI, &renderer.rhi);
                    for (renderer.direct_buffers.items) |*record| {
                        if (record.handle != handle or record.retired_serial != null) continue;
                        record.retired_serial = renderer.frame_serial;
                        record.frame_slot = renderer.frame_index;
                        // Like pool retirement, void destroy is assumed to
                        // accept deletion for this actual RHI frame slot.
                        base.destroyBuffer(handle);
                        return;
                    }
                    for (renderer.direct_buffers.items) |record| {
                        if (record.handle == handle) return; // Already submitted.
                    }
                    // Externally supplied/test draw handles were not allocated
                    // by this adapter and have no tracked size or ownership.
                    base.destroyBuffer(handle);
                }
                fn waitIdle(ptr: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ptr));
                    LODMeshResources.fromProvider(RHI, &renderer.rhi).waitIdle();
                }
                const vtable = LODMeshResources.VTable{
                    .createBuffer = createBuffer,
                    .uploadBuffer = uploadBuffer,
                    .updateBuffer = updateBuffer,
                    .destroyBuffer = destroyBuffer,
                    .waitIdle = waitIdle,
                };
            };
            return .{ .ptr = self, .vtable = &Adapter.vtable };
        }

        /// Create a LODGPUBridge that delegates to this renderer's RHI.
        pub fn createGPUBridge(self: *Self) LODGPUBridge {
            const Wrapper = struct {
                fn onUpload(mesh: *LODMesh, ctx: *anyopaque) rhi_types.RhiError!void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    const resources = LODMeshResources.fromProvider(RHI, &renderer.rhi);
                    if (mesh.isCompact()) return renderer.compact_pool.upload(mesh, resources);
                    // Expanded far CPU fallback meshes use dedicated buffers.
                    // Growing a far shared pool republishes its whole shadow
                    // and can exceed the bounded staging ring in one frame.
                    if (!renderer.enable_mdi or mesh.lodLevel() == .lod3 or mesh.lodLevel() == .lod4 or mesh.usesDedicatedUploadFallback()) return mesh.upload(renderer.dedicatedMeshResources());
                    return renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].uploadMesh(mesh, resources);
                }
                fn onDestroy(mesh: *LODMesh, ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    if (mesh.isCompact()) {
                        renderer.compact_pool.retireMesh(mesh, renderer.frame_serial, renderer.frame_index);
                        return;
                    }
                    if (mesh.isPooled()) {
                        renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].destroyMeshDeferred(mesh, renderer.frame_serial, renderer.frame_index);
                    } else {
                        mesh.deinit(renderer.dedicatedMeshResources());
                    }
                }
                fn onUploadCost(mesh: *LODMesh, ctx: *anyopaque) LODStagingCost {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    if (mesh.isCompact() or !renderer.enable_mdi or mesh.lodLevel() == .lod3 or mesh.lodLevel() == .lod4 or mesh.usesDedicatedUploadFallback()) {
                        return .{ .payload_bytes = mesh.pendingUploadBytes() };
                    }
                    return renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].uploadCost(mesh);
                }
                fn onBeginFrame(frame_serial: u64, ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    renderer.beginFrame(frame_serial);
                }
                fn onPrepareUpload(mesh: *LODMesh, available_memory_bytes: usize, ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    if (!renderer.enable_mdi or mesh.lodLevel() == .lod3 or mesh.lodLevel() == .lod4) return;
                    const pending_len = snapshot: {
                        mesh.mutex.lock();
                        defer mesh.mutex.unlock();
                        if (mesh.compact or mesh.pooled or mesh.buffer_handle != 0 or mesh.dedicated_upload_fallback) return;
                        const pending = mesh.pending_vertices orelse return;
                        if (pending.len == 0) return;
                        break :snapshot pending.len;
                    };
                    const bytes = pending_len * @sizeOf(rhi_types.Vertex);
                    const dedicated_cost = @max(1024, std.math.ceilPowerOfTwo(usize, bytes) catch bytes);
                    if (dedicated_cost > available_memory_bytes) return;
                    // Pool methods lock pool -> mesh. Main-thread upload admission
                    // serializes pool mutations; never hold mesh across this call.
                    const pool = &renderer.vertex_pools[@intFromEnum(mesh.lodLevel())];
                    if (pool.uploadMemoryCost(mesh) <= available_memory_bytes) return;
                    mesh.mutex.lock();
                    defer mesh.mutex.unlock();
                    const pending = mesh.pending_vertices orelse return;
                    if (!mesh.compact and !mesh.pooled and mesh.buffer_handle == 0 and pending.len == pending_len) {
                        mesh.dedicated_upload_fallback = true;
                    }
                }
                fn onUploadMemoryCost(mesh: *LODMesh, ctx: *anyopaque) usize {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    if (mesh.isCompact()) {
                        renderer.compact_pool.mutex.lock();
                        defer renderer.compact_pool.mutex.unlock();
                        return if (renderer.compact_pool.buffer_handle == 0) renderer.compact_pool.capacity_bytes else 0;
                    }
                    if (!renderer.enable_mdi or mesh.lodLevel() == .lod3 or mesh.lodLevel() == .lod4 or mesh.usesDedicatedUploadFallback()) {
                        mesh.mutex.lock();
                        defer mesh.mutex.unlock();
                        const pending = mesh.pending_vertices orelse return 0;
                        if (mesh.isPooled() or pending.len == 0) return 0;
                        // Match LODMesh.upload's rounded allocation and reuse
                        // condition, not just the incoming vertex byte count.
                        const bytes = pending.len * @sizeOf(rhi_types.Vertex);
                        const capacity = @max(1024, std.math.ceilPowerOfTwo(usize, bytes) catch bytes);
                        return if (mesh.bufferHandle() == 0 or capacity > mesh.byteSize()) capacity else 0;
                    }
                    return renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].uploadMemoryCost(mesh);
                }
                fn onMemoryPressure(budget_bytes: usize, accounted_bytes: usize, staging_budget_bytes: usize, ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    renderer.memory_pressure_requested = true;
                    renderer.memory_pressure_budget_bytes = budget_bytes;
                    renderer.memory_pressure_accounted_bytes = accounted_bytes;
                    renderer.memory_pressure_staging_bytes = staging_budget_bytes;
                }
                fn onWaitIdle(ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    renderer.rhi.waitIdle();
                }
                fn onSupportsCompact(ctx: *anyopaque) bool {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    const RenderContext = @TypeOf(if (@hasDecl(RHI, "renderContext")) @as(RHI, undefined).renderContext() else @as(RHI, undefined));
                    if (!@hasDecl(RenderContext, "drawCompactLOD") or
                        !@hasDecl(RenderContext, "setLODCompactSampleBuffer") or
                        !@hasDecl(RenderContext, "setLODDescriptorStream")) return false;
                    inline for (.{ LODLevel.lod3, LODLevel.lod4 }, 0..) |lod, lod_index| {
                        const max_width = @import("world-core").LODSimplifiedData.getGridSize(lod);
                        for (COMPACT_GRID_WIDTHS, 0..) |width, width_index| {
                            if (width > max_width) continue;
                            for (renderer.compact_index_buffers[lod_index]) |layer_handles| {
                                if (layer_handles[width_index] == 0) return false;
                            }
                        }
                    }
                    return true;
                }
                fn onSupportsCompactGpuCulling(ctx: *anyopaque) bool {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    if (!onSupportsCompact(ctx)) return false;
                    const Query = @TypeOf(if (@hasDecl(RHI, "query")) @as(RHI, undefined).query() else @as(RHI, undefined));
                    if (comptime !@hasDecl(Query, "supportsCompactLODGpuCulling")) return false;
                    return renderer.rhi.query().supportsCompactLODGpuCulling();
                }
            };
            return .{
                .on_upload = Wrapper.onUpload,
                .on_destroy = Wrapper.onDestroy,
                .on_wait_idle = Wrapper.onWaitIdle,
                .on_upload_cost = Wrapper.onUploadCost,
                .on_prepare_upload = Wrapper.onPrepareUpload,
                .on_begin_frame = Wrapper.onBeginFrame,
                .on_upload_memory_cost = Wrapper.onUploadMemoryCost,
                .on_memory_pressure = Wrapper.onMemoryPressure,
                .ctx = @ptrCast(self),
                .on_supports_compact = Wrapper.onSupportsCompact,
                .on_supports_compact_gpu_culling = Wrapper.onSupportsCompactGpuCulling,
            };
        }

        fn memoryStats(self: *Self) LODRendererMemoryStats {
            var result = LODRendererMemoryStats{};
            for (self.direct_buffers.items) |record| {
                if (record.retired_serial != null) result.direct_gpu_retired_bytes +|= record.size;
            }
            for (&self.vertex_pools) |*pool| {
                const capacity = pool.gpuMemoryBytes();
                const allocated = pool.allocatedBytes();
                result.pool_gpu_capacity_bytes += capacity;
                result.pool_gpu_retired_bytes +|= pool.retiredGpuMemoryBytes();
                result.pool_gpu_allocated_bytes += allocated;
                result.pool_gpu_slack_bytes += capacity - allocated;
                // The pool keeps a full CPU copy so it can grow and compact
                // without a GPU readback.
                result.pool_cpu_shadow_bytes += capacity;
            }
            const compact = self.compact_pool.memoryStats();
            result.compact_pool_capacity_bytes = compact.capacity_bytes;
            result.compact_pool_allocated_bytes = compact.allocated_bytes;
            result.compact_pool_free_bytes = compact.free_bytes;
            result.compact_pool_retired_bytes = compact.retired_bytes;
            return result;
        }

        /// Create a type-erased LODRenderInterface from this renderer.
        pub fn toInterface(self: *Self) LODRenderInterface {
            const Wrapper = struct {
                fn renderFn(
                    self_ptr: *anyopaque,
                    meshes: *const [LODLevel.count]MeshMap,
                    regions: *const [LODLevel.count]RegionMap,
                    config: ILODConfig,
                    view_proj: Mat4,
                    camera_pos: Vec3,
                    chunk_checker: ?ChunkChecker,
                    checker_ctx: ?*anyopaque,
                    use_frustum: bool,
                    max_distance_chunks: ?i32,
                    layer: LODRenderLayer,
                    stats: ?*LODStats,
                    profiling: ?*LODProfilingCollector,
                ) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.render(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats, profiling);
                }
                fn renderFrameFn(
                    self_ptr: *anyopaque,
                    frame_serial: u64,
                    meshes: *const [LODLevel.count]MeshMap,
                    regions: *const [LODLevel.count]RegionMap,
                    config: ILODConfig,
                    view_proj: Mat4,
                    camera_pos: Vec3,
                    chunk_checker: ?ChunkChecker,
                    checker_ctx: ?*anyopaque,
                    use_frustum: bool,
                    max_distance_chunks: ?i32,
                    detail_render_radius: i32,
                    layer: LODRenderLayer,
                    stats: ?*LODStats,
                    profiling: ?*LODProfilingCollector,
                ) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.renderFrame(frame_serial, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, detail_render_radius, layer, stats, profiling);
                }
                fn prepareFrameFn(self_ptr: *anyopaque, frame_serial: u64, meshes: *const [LODLevel.count]MeshMap, regions: *const [LODLevel.count]RegionMap, config: ILODConfig, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, max_distance_chunks: ?i32, detail_render_radius: i32, stats: ?*LODStats, profiling: ?*LODProfilingCollector) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.prepareFrame(frame_serial, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, max_distance_chunks, detail_render_radius, stats, profiling);
                }
                fn memoryStatsFn(self_ptr: *anyopaque) LODRendererMemoryStats {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    return renderer.memoryStats();
                }
                fn deinitFn(self_ptr: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.deinit();
                }
            };
            return .{
                .render_fn = Wrapper.renderFn,
                .render_frame_fn = Wrapper.renderFrameFn,
                .prepare_frame_fn = Wrapper.prepareFrameFn,
                .memory_stats_fn = Wrapper.memoryStatsFn,
                .deinit_fn = Wrapper.deinitFn,
                .ptr = self,
            };
        }
    };
}

fn isRegionInRange(bounds: ChunkBounds, camera_pos: Vec3, max_distance_chunks: i32) bool {
    const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
    return bounds.intersectsRadius(camera_chunk.chunk_x, camera_chunk.chunk_z, max_distance_chunks);
}

test "distant LOD render limit rejects disconnected resident regions" {
    const near = ChunkBounds{ .min_x = 200, .min_z = -16, .max_x = 240, .max_z = 16 };
    const far = ChunkBounds{ .min_x = 300, .min_z = -16, .max_x = 340, .max_z = 16 };
    try std.testing.expect(isRegionInRange(near, Vec3.zero, 256));
    try std.testing.expect(!isRegionInRange(far, Vec3.zero, 256));
}

fn calculateBandFade(config: ILODConfig, lod: LODLevel, bounds: ChunkBounds, camera_pos: Vec3) f32 {
    const lod_idx = @intFromEnum(lod);
    if (lod_idx == 0) return 1.0;

    const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
    const dist_sq = bounds.distanceSquaredToPoint(camera_chunk.chunk_x, camera_chunk.chunk_z);
    const dist_chunks = @sqrt(@as(f32, @floatFromInt(dist_sq)));
    const radii = config.getRadii();
    const end = @as(f32, @floatFromInt(@max(radii[lod_idx], 1)));
    const inner = @as(f32, @floatFromInt(@max(radii[lod_idx - 1], 0)));
    const configured_start = end * std.math.clamp(config.getFogStartPercent(lod), 0.0, 1.0);
    const start = @min(@max(inner, configured_start), end - 0.001);
    return std.math.clamp((dist_chunks - start) / @max(end - start, 0.001), 0.0, 1.0);
}

fn supports_lod_indirect(comptime RenderCtx: type, comptime Query: type, comptime RHI: type) bool {
    _ = RHI;
    return @hasDecl(RenderCtx, "drawIndirect") and
        @hasDecl(RenderCtx, "setLODInstanceBuffer") and
        @hasDecl(Query, "supportsIndirectFirstInstance");
}

fn cullCommandFor(mesh: *const LODMesh, range: ?LODMesh.DrawRange, compact: bool, terrain: bool) rhi_types.LODCullCommand {
    const draw_range = range orelse return .{ .count = 0, .instance_count = 0, .first = 0 };
    if (compact) return .{
        .count = @intCast(compactGridIndexCount(mesh.compact_tile_width, terrain)),
        .instance_count = 1,
        .first = 0,
        .vertex_offset = 0,
    };
    return .{
        .count = draw_range.count,
        .instance_count = 1,
        .first = mesh.firstVertex(draw_range),
    };
}

fn extractPlanes(view_proj: Mat4) [6][4]f32 {
    const m = view_proj.data;
    var planes = [6][4]f32{
        .{ m[0][3] + m[0][0], m[1][3] + m[1][0], m[2][3] + m[2][0], m[3][3] + m[3][0] },
        .{ m[0][3] - m[0][0], m[1][3] - m[1][0], m[2][3] - m[2][0], m[3][3] - m[3][0] },
        .{ m[0][3] + m[0][1], m[1][3] + m[1][1], m[2][3] + m[2][1], m[3][3] + m[3][1] },
        .{ m[0][3] - m[0][1], m[1][3] - m[1][1], m[2][3] - m[2][1], m[3][3] - m[3][1] },
        .{ m[0][2], m[1][2], m[2][2], m[3][2] },
        .{ m[0][3] - m[0][2], m[1][3] - m[1][2], m[2][3] - m[2][2], m[3][3] - m[3][2] },
    };
    for (&planes) |*plane| {
        const length = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        if (length > 0.0001) {
            for (plane) |*value| value.* /= length;
        }
    }
    return planes;
}

fn gpuCullingThreshold() usize {
    return engine_core.envInt("ZIGCRAFT_LOD_GPU_CULLING_THRESHOLD", 128);
}

/// Keep the compile-time benchmark opt-in independent of process environment.
/// This is intentionally a pure helper so both build-option states are covered
/// without tests mutating a global environment.
fn gpuCullingRequested(benchmark_gpu_culling: bool, environment_requested: bool) bool {
    return benchmark_gpu_culling or environment_requested;
}

fn isRegionInFrustum(frustum: Frustum, bounds: LODChunk.WorldBounds, camera_pos: Vec3) bool {
    const min_x: f32 = @floatFromInt(bounds.min_x);
    const min_z: f32 = @floatFromInt(bounds.min_z);
    const max_x: f32 = @floatFromInt(bounds.max_x);
    const max_z: f32 = @floatFromInt(bounds.max_z);
    const min_y = bounds.min_y;
    const max_y = bounds.max_y;

    const center = Vec3.init(
        (min_x + max_x) * 0.5 - camera_pos.x,
        (min_y + max_y) * 0.5 - camera_pos.y,
        (min_z + max_z) * 0.5 - camera_pos.z,
    );
    const half_x = (max_x - min_x) * 0.5;
    const half_y = @max((max_y - min_y) * 0.5, 1.0);
    const half_z = (max_z - min_z) * 0.5;
    const radius = @sqrt(half_x * half_x + half_y * half_y + half_z * half_z);
    return frustum.intersectsSphere(center, radius);
}

// Tests
test "benchmark GPU-culling build option requests telemetry without environment" {
    try std.testing.expect(gpuCullingRequested(true, false));
    try std.testing.expect(!gpuCullingRequested(false, false));
}

test "GPU culling planes match the canonical high-altitude frustum" {
    const camera = Vec3.init(0.0, 900.0, 0.0);
    const target = Vec3.init(256.0, 64.0, -384.0);
    const view = Mat4.lookAt(Vec3.zero, target.sub(camera), Vec3.init(0.0, 0.0, -1.0));
    const projection = Mat4.perspectiveReverseZ(std.math.pi / 3.0, 16.0 / 9.0, 0.5, 20_000.0);
    const view_proj = projection.multiply(view);
    const canonical = Frustum.fromViewProj(view_proj);
    const gpu_planes = extractPlanes(view_proj);

    for (canonical.planes, gpu_planes) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected.normal.x, actual[0], 0.0001);
        try std.testing.expectApproxEqAbs(expected.normal.y, actual[1], 0.0001);
        try std.testing.expectApproxEqAbs(expected.normal.z, actual[2], 0.0001);
        try std.testing.expectApproxEqAbs(expected.distance, actual[3], 0.0001);
    }
}

test "compact grid variants retain exact decimated topology" {
    for (COMPACT_GRID_WIDTHS, 0..) |width, expected_variant| {
        try std.testing.expectEqual(expected_variant, compactGridVariant(width).?);
        inline for (.{ false, true }) |include_skirts| {
            const indices = try compactGridIndices(std.testing.allocator, width, include_skirts);
            defer std.testing.allocator.free(indices);
            try std.testing.expectEqual(compactGridIndexCount(width, include_skirts), indices.len);
            const vertex_count = @as(u32, width) * width + if (include_skirts) 4 * width else 0;
            for (indices) |index| try std.testing.expect(index < vertex_count);
        }
    }
    try std.testing.expect(compactGridVariant(7) == null);
}

test "compact index topology uploads in the first render frame before becoming drawable" {
    const MockState = struct {
        next_handle: u32 = 1,
        uploads: u32 = 0,
        destroys: u32 = 0,
    };
    const MockRHI = struct {
        state: *MockState,

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            const handle = self.state.next_handle;
            self.state.next_handle += 1;
            return handle;
        }
        pub fn uploadBuffer(self: @This(), _: u32, data: []const u8) !void {
            std.debug.assert(data.len > 0);
            self.state.uploads += 1;
        }
        pub fn destroyBuffer(self: @This(), _: u32) void {
            self.state.destroys += 1;
        }
        pub fn waitIdle(_: @This()) void {}
    };

    var state = MockState{};
    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(std.testing.allocator, .{ .state = &state });
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u32, 0), state.uploads);
    renderer.frame_serial = 7;
    try std.testing.expect(!renderer.ensureCompactIndexBuffers(7));
    try std.testing.expectEqual(@as(u32, 22), state.uploads);
    try std.testing.expectEqual(@as(rhi_types.BufferHandle, 0), renderer.compactIndexBuffer(.lod4, 65, .terrain));

    renderer.frame_serial = 8;
    try std.testing.expect(renderer.ensureCompactIndexBuffers(8));
    try std.testing.expect(renderer.compactIndexBuffer(.lod4, 65, .terrain) != 0);
    try std.testing.expectEqual(@as(u32, 22), state.uploads);
}

test "ready detail disk stops at the first incomplete chunk ring" {
    const CheckerState = struct {
        missing_x: i32,
        missing_z: i32,

        fn isLoaded(cx: i32, cz: i32, ctx: *anyopaque) bool {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            return cx != state.missing_x or cz != state.missing_z;
        }
    };

    try std.testing.expectEqual(@as(i32, -1), contiguousReadyDiskRadius(null, null, 0, 0, 4));

    var state = CheckerState{ .missing_x = -7, .missing_z = 3 };
    try std.testing.expectEqual(@as(i32, -1), contiguousReadyDiskRadius(CheckerState.isLoaded, &state, -7, 3, 4));

    state = .{ .missing_x = -5, .missing_z = 3 };
    try std.testing.expectEqual(@as(i32, 1), contiguousReadyDiskRadius(CheckerState.isLoaded, &state, -7, 3, 4));

    state = .{ .missing_x = 100, .missing_z = 100 };
    try std.testing.expectEqual(@as(i32, 4), contiguousReadyDiskRadius(CheckerState.isLoaded, &state, -7, 3, 4));
}

test "ready detail disk mask uses sign encoding" {
    try std.testing.expectEqual(@as(f32, 0.5), readyDiskMaskRadius(-1));
    try std.testing.expectEqual(@as(f32, -1.0), readyDiskMaskRadius(0));
    try std.testing.expectEqual(@as(f32, -16.0), readyDiskMaskRadius(1));
    try std.testing.expectEqual(@as(f32, -64.0), readyDiskMaskRadius(4));
}

test "LODRegionKey ownership bounds partition a parent at negative coordinates" {
    const parent = LODRegionKey{ .rx = -1, .rz = -1, .lod = .lod2 };
    const children = parent.childKeys().?;

    try std.testing.expectEqual([_]f32{ -1, -1, 64, 64 }, parent.ownershipBounds(children[0]));
    try std.testing.expectEqual([_]f32{ 64, -1, 129, 64 }, parent.ownershipBounds(children[1]));
    try std.testing.expectEqual([_]f32{ -1, 64, 64, 129 }, parent.ownershipBounds(children[2]));
    try std.testing.expectEqual([_]f32{ 64, 64, 129, 129 }, parent.ownershipBounds(children[3]));
}

test "LODRegionKey ownership retains inward-probed vertical boundary faces" {
    const bounds = [_]f32{ 0, 0, 64, 64 };

    try std.testing.expect(LODRegionKey.ownershipContainsLocalSurface(bounds, .{ 64, 12 }, .{ 3, 0 }));
    try std.testing.expect(!LODRegionKey.ownershipContainsLocalSurface(bounds, .{ 64, 12 }, .{ -3, 0 }));
    try std.testing.expect(LODRegionKey.ownershipContainsLocalSurface(bounds, .{ 12, 64 }, .{ 0, 2 }));
    try std.testing.expect(!LODRegionKey.ownershipContainsLocalSurface(bounds, .{ 12, 64 }, .{ 0, -2 }));
}

test "LODRenderer revalidates ready detail disk when the checker loses coverage" {
    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}
        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
    };
    const Checker = struct {
        ready: bool = true,
        fn check(_: i32, _: i32, ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.ready;
        }
    };

    const renderer = try LODRenderer(MockRHI).init(std.testing.allocator, .{});
    defer renderer.deinit();
    var checker = Checker{};

    try std.testing.expectEqual(@as(i32, 3), renderer.readyDiskRadiusForProjection(Checker.check, &checker, 7, -4, 3));
    checker.ready = false;
    try std.testing.expectEqual(@as(i32, -1), renderer.readyDiskRadiusForProjection(Checker.check, &checker, 7, -4, 3));
}

test "LODRenderer traverses missing intermediate levels for ready descendant ownership" {
    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}
        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
    };
    const renderer = try LODRenderer(MockRHI).init(std.testing.allocator, .{});
    defer renderer.deinit();
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(std.testing.allocator);
        regions[i] = RegionMap.init(std.testing.allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };

    const parent = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod4 };
    const missing_lod3 = parent.childKeys().?[0];
    const ready_lod2 = missing_lod3.childKeys().?[0];
    var known_empty_mesh = LODMesh.init(std.testing.allocator, .lod2);
    known_empty_mesh.ready = true;
    known_empty_mesh.canonical_empty_coverage = true;
    var ready_chunk = LODChunk.init(ready_lod2.rx, ready_lod2.rz, .lod2);
    ready_chunk.state = .renderable;
    try meshes[2].put(ready_lod2, &known_empty_mesh);
    try regions[2].put(ready_lod2, &ready_chunk);

    try renderer.appendOwnershipProjection(&meshes, &regions, .{ .key = parent, .model = Mat4.identity, .mask_radius = 0, .lod_fade = 1 }, parent, Vec3.zero, null);
    try std.testing.expectEqual(@as(usize, 6), renderer.projection_regions.items.len);
    for (renderer.projection_regions.items) |projected| {
        try std.testing.expect(projected.owner == null or !projected.owner.?.eql(ready_lod2));
    }
}

test "LODRenderer retains range-rejected fine footprints and suppresses eligible fine coverage" {
    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}
        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
    };
    const renderer = try LODRenderer(MockRHI).init(std.testing.allocator, .{});
    defer renderer.deinit();
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(std.testing.allocator);
        regions[i] = RegionMap.init(std.testing.allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };

    const parent_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    const fine_key = parent_key.childKeys().?[3];
    var parent_mesh = LODMesh.init(std.testing.allocator, .lod2);
    parent_mesh.buffer_handle = 1;
    parent_mesh.vertex_count = 12;
    parent_mesh.ready = true;
    var fine_mesh = LODMesh.init(std.testing.allocator, .lod1);
    fine_mesh.buffer_handle = 2;
    fine_mesh.vertex_count = 12;
    fine_mesh.ready = true;
    var parent_chunk = LODChunk.init(parent_key.rx, parent_key.rz, .lod2);
    parent_chunk.state = .renderable;
    var fine_chunk = LODChunk.init(fine_key.rx, fine_key.rz, .lod1);
    fine_chunk.state = .renderable;
    try meshes[2].put(parent_key, &parent_mesh);
    try regions[2].put(parent_key, &parent_chunk);
    try meshes[1].put(fine_key, &fine_mesh);
    try regions[1].put(fine_key, &fine_chunk);

    // The parent intersects the camera's zero-radius disk, but its far child
    // does not. Cached fine coverage must not erase the submitted parent.
    try renderer.appendOwnershipProjection(&meshes, &regions, .{ .key = parent_key, .model = Mat4.identity, .mask_radius = 0, .lod_fade = 1 }, parent_key, Vec3.zero, 0);
    try std.testing.expectEqual(@as(usize, 1), renderer.projection_regions.items.len);
    try std.testing.expectEqual([_]f32{ 0, 0, 0, 0 }, renderer.projection_regions.items[0].ownership_bounds);

    // Once that fine child is inside the selected range, it owns its quadrant
    // and the parent projects only the remaining three footprints.
    renderer.projection_regions.clearRetainingCapacity();
    try renderer.appendOwnershipProjection(&meshes, &regions, .{ .key = parent_key, .model = Mat4.identity, .mask_radius = 0, .lod_fade = 1 }, parent_key, Vec3.zero, 8);
    try std.testing.expectEqual(@as(usize, 3), renderer.projection_regions.items.len);
    for (renderer.projection_regions.items) |projected| {
        try std.testing.expect(projected.owner == null or !projected.owner.?.eql(fine_key));
    }
}

test "LODRenderer projects only unavailable parent quadrants around known-empty child" {
    const MockRHIState = struct {
        draw_count: usize = 0,
        current_bounds: [4]f32 = .{ 0, 0, 0, 0 },
        bounds: [4][4]f32 = undefined,
    };
    const MockRHI = struct {
        state: *MockRHIState,
        pub fn waitIdle(_: @This()) void {}
        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: u32) void {}
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.current_bounds = .{ 0, 0, 0, 0 };
        }
        pub fn setLODOwnershipBounds(self: @This(), bounds: [4]f32) void {
            self.state.current_bounds = bounds;
        }
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.bounds[self.state.draw_count] = self.state.current_bounds;
            self.state.draw_count += 1;
        }
    };

    var state = MockRHIState{};
    const renderer = try LODRenderer(MockRHI).init(std.testing.allocator, .{ .state = &state });
    defer renderer.deinit();
    var parent_mesh = LODMesh.init(std.testing.allocator, .lod2);
    parent_mesh.buffer_handle = 7;
    parent_mesh.vertex_count = 12;
    parent_mesh.ready = true;
    var parent_chunk = LODChunk.init(0, 0, .lod2);
    parent_chunk.state = .renderable;
    var empty_mesh = LODMesh.init(std.testing.allocator, .lod1);
    empty_mesh.ready = true;
    empty_mesh.canonical_empty_coverage = true;
    var empty_chunk = LODChunk.init(0, 0, .lod1);
    empty_chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(std.testing.allocator);
        regions[i] = RegionMap.init(std.testing.allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    const parent_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    const empty_key = parent_key.childKeys().?[0];
    try meshes[2].put(parent_key, &parent_mesh);
    try regions[2].put(parent_key, &parent_chunk);
    try meshes[1].put(empty_key, &empty_mesh);
    try regions[1].put(empty_key, &empty_chunk);

    var config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    renderer.renderFrame(1, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, config.chunk_render_radius, .terrain, null, null);

    try std.testing.expectEqual(@as(usize, 3), state.draw_count);
    try std.testing.expectEqual([_]f32{ 64, -1, 129, 64 }, state.bounds[0]);
    try std.testing.expectEqual([_]f32{ -1, 64, 64, 129 }, state.bounds[1]);
    try std.testing.expectEqual([_]f32{ 64, 64, 129, 129 }, state.bounds[2]);
}

test "LODRenderer legacy render rebuilds same-epoch visibility after camera and readiness change" {
    const State = struct {
        draw_count: usize = 0,
    };
    const MockRHI = struct {
        state: *State,
        pub fn waitIdle(_: @This()) void {}
        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: u32) void {}
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_count += 1;
        }
    };
    var state = State{};
    const renderer = try LODRenderer(MockRHI).init(std.testing.allocator, .{ .state = &state });
    defer renderer.deinit();
    var mesh = LODMesh.init(std.testing.allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;
    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(std.testing.allocator);
        regions[i] = RegionMap.init(std.testing.allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);
    var config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };

    renderer.render(&meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, 0, .terrain, null, null);
    try std.testing.expectEqual(@as(usize, 1), state.draw_count);
    mesh.ready = false;
    renderer.render(&meshes, &regions, config.interface(), Mat4.identity, Vec3.init(1024, 0, 1024), null, null, false, 0, .terrain, null, null);
    try std.testing.expectEqual(@as(usize, 1), state.draw_count);
    try std.testing.expectEqual(@as(usize, 0), renderer.projection_regions.items.len);
}

const ExpandedMDIMock = struct {
    const Buffer = struct {
        bytes: ?[]u8 = null,
        usage: rhi_types.BufferUsage = .storage,
        updated_len: usize = 0,
        updates: usize = 0,
        retired_slot: ?usize = null,
    };
    const Draw = struct {
        stream: rhi_types.LODDescriptorStream,
        instances: u32,
        indirect: u32,
        vertex: u32,
        offset: usize,
        count: u32,
        instance_bytes: [4 * @sizeOf(rhi_types.InstanceData)]u8,
        command_bytes: [4 * @sizeOf(rhi_types.DrawIndirectCommand)]u8,
        instance_len: usize,
        command_len: usize,
    };
    const State = struct {
        buffers: [64]Buffer = @splat(.{}),
        next_handle: u32 = 1,
        fail_create_at: ?u32 = null,
        fail_update_usage: ?rhi_types.BufferUsage = null,
        defer_destruction: bool = false,
        destroyed: usize = 0,
        live_bytes: usize = 0,
        waits: usize = 0,
        frame_index: usize = 0,
        supports_mdi: bool = true,
        stream: rhi_types.LODDescriptorStream = .terrain_standard_direct,
        instance_buffer: u32 = 0,
        resets: usize = 0,
        direct_draws: usize = 0,
        last_direct_vertex: u32 = 0,
        last_direct_count: u32 = 0,
        last_direct_offset: usize = 0,
        draws: [32]Draw = undefined,
        draw_count: usize = 0,

        fn completeSlot(self: *@This(), slot: usize) void {
            for (&self.buffers) |*buffer| {
                if (buffer.retired_slot != slot) continue;
                const bytes = buffer.bytes.?;
                self.live_bytes -= bytes.len;
                std.testing.allocator.free(bytes);
                buffer.bytes = null;
                buffer.retired_slot = null;
            }
        }

        fn expectUnchanged(self: *const @This()) !void {
            // Read the destination bytes after ALL uploads, as deferred graphics
            // would. A recorded descriptor/command only preserves its handles.
            for (self.draws[0..self.draw_count]) |draw| {
                try std.testing.expectEqualSlices(u8, draw.instance_bytes[0..draw.instance_len], self.buffers[draw.instances].bytes.?[0..draw.instance_len]);
                try std.testing.expectEqualSlices(u8, draw.command_bytes[0..draw.command_len], self.buffers[draw.indirect].bytes.?[0..draw.command_len]);
            }
        }
    };
    state: *State,

    pub fn createBuffer(self: @This(), size: usize, usage: rhi_types.BufferUsage) rhi_types.RhiError!u32 {
        const handle = self.state.next_handle;
        if (self.state.fail_create_at == handle) return error.OutOfMemory;
        const bytes = try std.testing.allocator.alloc(u8, size);
        @memset(bytes, 0);
        self.state.buffers[handle] = .{ .bytes = bytes, .usage = usage };
        self.state.next_handle += 1;
        self.state.live_bytes += size;
        return handle;
    }
    pub fn destroyBuffer(self: @This(), handle: u32) void {
        const buffer = &self.state.buffers[handle];
        const bytes = buffer.bytes orelse unreachable; // Reject double destruction.
        std.debug.assert(buffer.retired_slot == null);
        self.state.destroyed += 1;
        if (self.state.defer_destruction) {
            buffer.retired_slot = self.state.frame_index;
            return;
        }
        self.state.live_bytes -= bytes.len;
        std.testing.allocator.free(bytes);
        buffer.bytes = null;
    }
    pub fn updateBuffer(self: @This(), handle: u32, offset: usize, data: []const u8) rhi_types.RhiError!void {
        const buffer = &self.state.buffers[handle];
        if (self.state.fail_update_usage == buffer.usage) return error.OutOfMemory;
        @memcpy(buffer.bytes.?[offset .. offset + data.len], data);
        buffer.updated_len = offset + data.len;
        buffer.updates += 1;
    }
    pub fn uploadBuffer(self: @This(), handle: u32, data: []const u8) rhi_types.RhiError!void {
        try self.updateBuffer(handle, 0, data);
    }
    pub fn waitIdle(self: @This()) void {
        self.state.waits += 1;
    }
    pub fn getFrameIndex(self: @This()) usize {
        return self.state.frame_index;
    }
    pub fn supportsIndirectFirstInstance(self: @This()) bool {
        return self.state.supports_mdi;
    }
    pub fn setLODDescriptorStream(self: @This(), stream: rhi_types.LODDescriptorStream) void {
        self.state.stream = stream;
    }
    pub fn setLODInstanceBuffer(self: @This(), handle: u32) void {
        self.state.instance_buffer = handle;
    }
    pub fn setInstanceBuffer(self: @This(), handle: u32) void {
        std.debug.assert(handle == 0);
        self.state.instance_buffer = 0;
        self.state.resets += 1;
    }
    pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
    pub fn drawOffset(self: @This(), vertex: u32, count: u32, _: anytype, offset: usize) void {
        std.debug.assert(offset + count * @sizeOf(rhi_types.Vertex) <= self.state.buffers[vertex].bytes.?.len);
        self.state.direct_draws += 1;
        self.state.last_direct_vertex = vertex;
        self.state.last_direct_count = count;
        self.state.last_direct_offset = offset;
    }
    pub fn drawIndirect(self: @This(), vertex: u32, indirect: u32, offset: usize, count: u32, stride: u32) void {
        std.debug.assert(stride == @sizeOf(rhi_types.DrawIndirectCommand));
        const instances = self.state.buffers[self.state.instance_buffer];
        const commands = self.state.buffers[indirect];
        const draw = &self.state.draws[self.state.draw_count];
        draw.* = .{
            .stream = self.state.stream,
            .instances = self.state.instance_buffer,
            .indirect = indirect,
            .vertex = vertex,
            .offset = offset,
            .count = count,
            .instance_bytes = undefined,
            .command_bytes = undefined,
            .instance_len = instances.updated_len,
            .command_len = commands.updated_len,
        };
        @memcpy(draw.instance_bytes[0..draw.instance_len], instances.bytes.?[0..draw.instance_len]);
        @memcpy(draw.command_bytes[0..draw.command_len], commands.bytes.?[0..draw.command_len]);
        self.state.draw_count += 1;
    }
};

test "expanded MDI terrain and fluid preserve submitted bytes across layers and frame retirement" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer {
        renderer.deinit();
        std.testing.expectEqual(@as(usize, 0), state.live_bytes) catch unreachable;
        std.testing.expectEqual(state.next_handle - 1, state.destroyed) catch unreachable;
        std.testing.expectEqual(@as(usize, 1), state.waits) catch unreachable;
    }
    renderer.enable_mdi = true;
    renderer.gpu_culling_requested = false;
    const bridge = renderer.createGPUBridge();
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    var dry = LODMesh.init(allocator, .lod1);
    var wet = LODMesh.init(allocator, .lod2);
    var dry_chunk = LODChunk.init(4, 0, .lod1);
    var wet_chunk = LODChunk.init(8, 0, .lod2);
    dry_chunk.state = .renderable;
    wet_chunk.state = .renderable;
    for ([_]*LODMesh{ &dry, &wet }, [_]*LODChunk{ &dry_chunk, &wet_chunk }) |mesh, chunk| {
        const lod = mesh.lodLevel();
        const index = @intFromEnum(lod);
        renderer.vertex_pools[index].initial_capacity_bytes = 4096;
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 18);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        mesh.opaque_vertex_count = if (mesh == &wet) 12 else 18;
        mesh.water_vertex_offset = 12 * @sizeOf(rhi_types.Vertex);
        mesh.water_vertex_count = if (mesh == &wet) 6 else 0;
        try bridge.upload(mesh);
        const key = LODRegionKey{ .rx = if (mesh == &wet) 8 else 4, .rz = 0, .lod = lod };
        try meshes[index].put(key, mesh);
        try regions[index].put(key, chunk);
    }
    var config = LODConfig{ .radii = .{ 16, 128, 256, 512, 1024 } };
    // Every in-flight slot gets different camera-relative instance bytes.
    for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |fi| {
        state.frame_index = fi;
        const camera = Vec3.init(@floatFromInt(fi), 0, 0);
        const first_draw = state.draw_count;
        renderer.renderFrame(fi + 1, &meshes, &regions, config.interface(), Mat4.identity, camera, null, null, false, null, 16, .terrain, null, null);
        renderer.renderFrame(fi + 1, &meshes, &regions, config.interface(), Mat4.identity, camera, null, null, false, null, 16, .fluid, null, null);
        try std.testing.expectEqual(first_draw + 3, state.draw_count);
        const terrain = state.draws[first_draw];
        const terrain_wet = state.draws[first_draw + 1];
        const fluid = state.draws[first_draw + 2];
        try std.testing.expectEqual(rhi_types.LODDescriptorStream.terrain_standard_direct, terrain.stream);
        try std.testing.expectEqual(terrain.stream, terrain_wet.stream);
        try std.testing.expectEqual(rhi_types.LODDescriptorStream.water_standard_direct, fluid.stream);
        try std.testing.expect(terrain.instances != fluid.instances);
        try std.testing.expect(terrain.indirect != fluid.indirect);
        try std.testing.expectEqual(dry.bufferHandle(), terrain.vertex);
        try std.testing.expectEqual(wet.bufferHandle(), terrain_wet.vertex);
        try std.testing.expectEqual(wet.bufferHandle(), fluid.vertex);
        try std.testing.expectEqual(@as(u32, 1), fluid.count);
        try std.testing.expectEqual(@as(usize, 0), fluid.offset);
        try std.testing.expectEqual(@sizeOf(rhi_types.DrawIndirectCommand), terrain_wet.offset);
        const water_command = std.mem.bytesToValue(rhi_types.DrawIndirectCommand, fluid.command_bytes[0..@sizeOf(rhi_types.DrawIndirectCommand)]);
        try std.testing.expectEqual(@as(u32, 6), water_command.vertexCount);
        try std.testing.expectEqual(wet.firstVertex(wet.drawRange(.fluid).?), water_command.firstVertex);
        try std.testing.expectEqual(@as(u32, 0), water_command.firstInstance);
        const water_instance = std.mem.bytesToValue(rhi_types.InstanceData, fluid.instance_bytes[0..@sizeOf(rhi_types.InstanceData)]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(wet_chunk.worldBounds().min_x)) - camera.x, water_instance.model.data[3][0]);
        try std.testing.expectEqual(@as(f32, 0), water_instance.model.data[3][1]);
        for ([_]u32{ terrain.instances, terrain.indirect, fluid.instances, fluid.indirect }) |handle| {
            try std.testing.expectEqual(@as(usize, 1), state.buffers[handle].updates);
        }
        try state.expectUnchanged();
        try std.testing.expectEqual(@as(u32, 0), state.instance_buffer);
        try std.testing.expectEqual((fi + 1) * 2, state.resets);
    }
    try std.testing.expectEqual(@as(usize, 0), state.direct_draws);
    // Eviction clears future mesh draw state, not already-recorded MDI bytes.
    bridge.destroy(&wet);
    try state.expectUnchanged();
    try std.testing.expect(!wet.isReady());
    try std.testing.expectEqual(@as(usize, 1), renderer.vertex_pools[2].retired_ranges.items.len);
    _ = renderer.renderProjectedLayer(&meshes, .fluid, null, null);
    try state.expectUnchanged();
    try std.testing.expectEqual(@as(usize, 1), renderer.vertex_pools[2].retired_ranges.items.len);
    // The RHI fence has now completed the last slot. Discard completed draws
    // before reusing that slot and let renderFrame collect its retired ranges.
    state.draw_count = 0;
    renderer.renderFrame(rhi_types.MAX_FRAMES_IN_FLIGHT + 1, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, 16, .terrain, null, null);
    try std.testing.expectEqual(@as(usize, 0), renderer.vertex_pools[2].retired_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.draw_count);
    try std.testing.expectEqual(@as(usize, 2), state.buffers[state.draws[0].instances].updates);
    try std.testing.expectEqual(@as(usize, 2), state.buffers[state.draws[0].indirect].updates);
    try state.expectUnchanged();

    // Capability and either upload failure still fall back to direct draws.
    state.draw_count = 0;
    state.supports_mdi = false;
    _ = renderer.renderProjectedLayer(&meshes, .terrain, null, null);
    state.supports_mdi = true;
    for ([_]rhi_types.BufferUsage{ .storage, .indirect }) |usage| {
        state.fail_update_usage = usage;
        _ = renderer.renderProjectedLayer(&meshes, .terrain, null, null);
    }
    try std.testing.expectEqual(@as(usize, 3), state.direct_draws);
    try std.testing.expectEqual(@as(usize, 0), state.draw_count);
    try std.testing.expectEqual(rhi_types.LODDescriptorStream.terrain_standard_direct, state.stream);
    try std.testing.expectEqual(@as(u32, 0), state.instance_buffer);
    bridge.destroy(&dry);
}

test "LOD pressure fallback plans fresh near dedicated uploads without allocating or consuming pending data" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    for ([_]LODLevel{ .lod0, .lod1, .lod2 }) |lod| {
        var mesh = LODMesh.init(allocator, lod);
        defer bridge.destroy(&mesh);
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 1024 * 1024 / @sizeOf(rhi_types.Vertex) - 1);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        const pending = mesh.pending_vertices.?;
        const available = 1024 * 1024;
        try std.testing.expect(bridge.uploadMemoryCost(&mesh) > available);
        const created = state.next_handle;
        const live = state.live_bytes;
        bridge.prepareUpload(&mesh, available);
        try std.testing.expect(mesh.usesDedicatedUploadFallback());
        try std.testing.expectEqual(pending.ptr, mesh.pending_vertices.?.ptr);
        try std.testing.expectEqual(pending.len * @sizeOf(rhi_types.Vertex), bridge.uploadCost(&mesh).payload_bytes);
        try std.testing.expectEqual(@as(usize, 0), bridge.uploadCost(&mesh).migration_bytes);
        try std.testing.expectEqual(@as(usize, available), bridge.uploadMemoryCost(&mesh));
        try std.testing.expectEqual(created, state.next_handle);
        try std.testing.expectEqual(live, state.live_bytes);
        try std.testing.expectEqual(@as(u32, 0), mesh.bufferHandle());
        // Reconsidering with abundant headroom must not re-promote the mesh.
        bridge.prepareUpload(&mesh, std.math.maxInt(usize));
        try bridge.upload(&mesh);
        try std.testing.expect(mesh.usesDedicatedUploadFallback());
        try std.testing.expect(!mesh.isPooled());
        try std.testing.expect(mesh.isReady());
        try std.testing.expect(mesh.pending_vertices == null);
        try std.testing.expectEqual(@as(usize, available), state.live_bytes - live);
        try std.testing.expectEqual(@as(usize, available), state.buffers[mesh.bufferHandle()].bytes.?.len);
        try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().pool_gpu_capacity_bytes);
        try std.testing.expectEqual(@as(usize, 0), bridge.uploadMemoryCost(&mesh));
    }
}

test "LOD pressure fallback preserves normal pool admission and rejects ineligible or unaffordable plans" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    const bridge = renderer.createGPUBridge();
    const Case = enum { neither, legacy, exact_pool, unlimited, far3, far4, compact, empty, no_pending, no_mdi, dedicated };
    for (std.enums.values(Case)) |case| {
        renderer.enable_mdi = case != .no_mdi;
        const lod: LODLevel = if (case == .far3) .lod3 else if (case == .far4 or case == .compact) .lod4 else if (case == .no_mdi or case == .dedicated) .lod0 else .lod1;
        renderer.vertex_pools[@intFromEnum(lod)].initial_capacity_bytes = 4096;
        var mesh = LODMesh.init(allocator, lod);
        defer bridge.destroy(&mesh);
        if (case == .compact) {
            var source = try lod_chunk.LODSimplifiedData.init(allocator, lod);
            defer source.deinit();
            try mesh.buildCompactTile(&source);
        } else if (case != .no_pending) {
            mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, if (case == .empty) 0 else 3);
            @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        }
        if (case == .dedicated) {
            renderer.enable_mdi = false;
            try bridge.upload(&mesh);
            renderer.enable_mdi = true;
            mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
            @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        }
        var prepare_bridge = bridge;
        if (case == .legacy) prepare_bridge.on_prepare_upload = null;
        const available: usize = switch (case) {
            .neither => 1023,
            .exact_pool => 8192,
            .unlimited => std.math.maxInt(usize),
            else => 1024,
        };
        const created = state.next_handle;
        const cost = bridge.uploadMemoryCost(&mesh);
        const pending = mesh.pendingUploadBytes();
        prepare_bridge.prepareUpload(&mesh, available);
        try std.testing.expect(!mesh.usesDedicatedUploadFallback());
        try std.testing.expectEqual(cost, bridge.uploadMemoryCost(&mesh));
        try std.testing.expectEqual(pending, mesh.pendingUploadBytes());
        try std.testing.expectEqual(created, state.next_handle);
        if (case == .neither) try std.testing.expect(bridge.uploadMemoryCost(&mesh) > available);
        if (case == .exact_pool or case == .unlimited) {
            try bridge.upload(&mesh);
            try std.testing.expect(mesh.isPooled());
        }
    }
}

test "LOD pressure fallback never converts or retires a live pooled mesh" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    const pool = &renderer.vertex_pools[1];
    pool.initial_capacity_bytes = 1024;
    var mesh = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&mesh);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    try bridge.upload(&mesh);
    const handle = mesh.bufferHandle();
    const offset = mesh.vertexOffset();
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 1024 / @sizeOf(rhi_types.Vertex) + 1);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    const cost = bridge.uploadMemoryCost(&mesh);
    try std.testing.expect(cost > 2048);
    bridge.prepareUpload(&mesh, 2048);
    try std.testing.expect(!mesh.usesDedicatedUploadFallback());
    try std.testing.expect(mesh.isPooled());
    try std.testing.expect(mesh.isReady());
    try std.testing.expectEqual(handle, mesh.bufferHandle());
    try std.testing.expectEqual(offset, mesh.vertexOffset());
    try std.testing.expectEqual(@as(u32, 3), mesh.vertexCount());
    try std.testing.expectEqual(cost, bridge.uploadMemoryCost(&mesh));
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
    // A separate fresh mesh can avoid the same replacement peak, without
    // retiring the live mesh or paying its staging migration cost.
    var fresh = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&fresh);
    fresh.pending_vertices = try allocator.dupe(rhi_types.Vertex, mesh.pending_vertices.?);
    try std.testing.expect(bridge.uploadCost(&fresh).migration_bytes > 0);
    bridge.prepareUpload(&fresh, 2048);
    try std.testing.expect(fresh.usesDedicatedUploadFallback());
    try std.testing.expectEqual(@as(usize, 0), bridge.uploadCost(&fresh).migration_bytes);
    try bridge.upload(&fresh);
    try std.testing.expectEqual(handle, mesh.bufferHandle());
    try std.testing.expectEqual(@as(usize, 1024), pool.gpuMemoryBytes());
}

test "LOD pressure fallback upload failures retain sticky retries and old dedicated draw state" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .defer_destruction = true, .frame_index = 1 };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer {
        renderer.deinit();
        for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |slot| state.completeSlot(slot);
        std.testing.expectEqual(@as(usize, 0), state.live_bytes) catch unreachable;
        std.testing.expectEqual(state.next_handle - 1, state.destroyed) catch unreachable;
    }
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    const interface = renderer.toInterface();
    bridge.beginFrame(10);
    var mesh = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&mesh);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    const pending = mesh.pending_vertices.?;
    bridge.prepareUpload(&mesh, 1024);
    const live = state.live_bytes;
    state.fail_create_at = state.next_handle;
    try std.testing.expectError(error.OutOfMemory, bridge.upload(&mesh));
    try std.testing.expectEqual(@as(usize, 0), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 0), renderer.direct_buffers.items.len);
    try std.testing.expectEqual(live, state.live_bytes);
    state.fail_create_at = null;
    state.fail_update_usage = .vertex;
    try std.testing.expectError(error.OutOfMemory, bridge.upload(&mesh));
    try std.testing.expectEqual(@as(usize, 1024), interface.memoryStats().direct_gpu_retired_bytes);
    // Retrying before the fence adds debt; it cannot reuse the failed backing.
    try std.testing.expectError(error.OutOfMemory, bridge.upload(&mesh));
    try std.testing.expectEqual(@as(usize, 2048), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 1024), bridge.uploadMemoryCost(&mesh));
    state.fail_update_usage = null;
    try std.testing.expect(mesh.usesDedicatedUploadFallback());
    try std.testing.expectEqual(pending.ptr, mesh.pending_vertices.?.ptr);
    try std.testing.expectEqual(@as(u32, 0), mesh.bufferHandle());
    try std.testing.expect(!mesh.isReady());
    try std.testing.expectEqual(live + 2048, state.live_bytes);
    bridge.beginFrame(9);
    bridge.beginFrame(10);
    try std.testing.expectEqual(@as(usize, 2048), interface.memoryStats().direct_gpu_retired_bytes);
    state.frame_index = 0;
    state.completeSlot(0);
    bridge.beginFrame(11);
    try std.testing.expectEqual(@as(usize, 2048), interface.memoryStats().direct_gpu_retired_bytes);
    state.frame_index = 1;
    bridge.beginFrame(10); // Matching slot cannot make a stale serial valid.
    try std.testing.expectEqual(@as(usize, 2048), interface.memoryStats().direct_gpu_retired_bytes);
    state.completeSlot(1);
    bridge.beginFrame(12);
    try std.testing.expectEqual(@as(usize, 0), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 0), renderer.direct_buffers.items.len);
    try std.testing.expectEqual(live, state.live_bytes);
    bridge.prepareUpload(&mesh, std.math.maxInt(usize));
    try bridge.upload(&mesh);
    try std.testing.expectEqual(@as(usize, 0), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 1024), mesh.memorySnapshot().capacity_bytes);
    try std.testing.expectEqual(@as(usize, 1), renderer.direct_buffers.items.len);
    const old_handle = mesh.bufferHandle();
    const old_capacity = mesh.capacity;
    const old_bytes = try allocator.dupe(u8, state.buffers[old_handle].bytes.?);
    defer allocator.free(old_bytes);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 1024 / @sizeOf(rhi_types.Vertex) + 1);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    const replacement = mesh.pending_vertices.?;
    state.fail_update_usage = .vertex;
    bridge.prepareUpload(&mesh, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 2048), bridge.uploadMemoryCost(&mesh));
    try std.testing.expectError(error.OutOfMemory, bridge.upload(&mesh));
    try std.testing.expectEqual(@as(usize, 2048), interface.memoryStats().direct_gpu_retired_bytes);
    state.fail_update_usage = null;
    try std.testing.expect(mesh.usesDedicatedUploadFallback());
    try std.testing.expect(!mesh.isPooled());
    try std.testing.expect(mesh.isReady());
    try std.testing.expectEqual(old_handle, mesh.bufferHandle());
    try std.testing.expectEqual(old_capacity, mesh.capacity);
    try std.testing.expectEqual(@as(u32, 3), mesh.vertexCount());
    try std.testing.expectEqual(@as(usize, 0), mesh.vertexOffset());
    try std.testing.expectEqual(replacement.ptr, mesh.pending_vertices.?.ptr);
    try std.testing.expectEqualSlices(u8, old_bytes, state.buffers[old_handle].bytes.?);
    state.frame_index = 0;
    state.completeSlot(0);
    bridge.beginFrame(13);
    bridge.prepareUpload(&mesh, std.math.maxInt(usize));
    try bridge.upload(&mesh);
    try std.testing.expect(mesh.bufferHandle() != old_handle);
    try std.testing.expect(state.buffers[old_handle].bytes != null);
    try std.testing.expectEqual(@as(usize, 3072), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 2048), mesh.memorySnapshot().capacity_bytes);
    try std.testing.expectEqual(live + 5120, state.live_bytes);
    bridge.destroy(&mesh);
    try std.testing.expectEqual(@as(usize, 5120), interface.memoryStats().direct_gpu_retired_bytes);
    const destroyed = state.destroyed;
    bridge.destroy(&mesh);
    try std.testing.expectEqual(destroyed, state.destroyed);
    bridge.beginFrame(13);
    try std.testing.expectEqual(@as(usize, 5120), interface.memoryStats().direct_gpu_retired_bytes);
    state.frame_index = 1;
    state.completeSlot(1);
    bridge.beginFrame(14);
    try std.testing.expectEqual(@as(usize, 3072), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(live + 3072, state.live_bytes);
    state.frame_index = 0;
    state.completeSlot(0);
    bridge.beginFrame(15);
    try std.testing.expectEqual(@as(usize, 0), interface.memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(@as(usize, 0), renderer.direct_buffers.items.len);
    try std.testing.expectEqual(live, state.live_bytes);
    try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().pool_gpu_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.waits);
}

test "LOD dedicated ledger metadata OOM precedes GPU creation and retirement cannot allocate" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .defer_destruction = true };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer {
        renderer.deinit();
        for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |slot| state.completeSlot(slot);
        std.testing.expectEqual(@as(usize, 0), state.live_bytes) catch unreachable;
        std.testing.expectEqual(state.next_handle - 1, state.destroyed) catch unreachable;
    }
    const bridge = renderer.createGPUBridge();
    bridge.beginFrame(1);
    var mesh = LODMesh.init(allocator, .lod3);
    defer bridge.destroy(&mesh);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    const pending = mesh.pending_vertices.?;
    const created = state.next_handle;
    const live = state.live_bytes;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    renderer.allocator = failing.allocator();
    defer renderer.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, bridge.upload(&mesh));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(created, state.next_handle);
    try std.testing.expectEqual(live, state.live_bytes);
    try std.testing.expectEqual(pending.ptr, mesh.pending_vertices.?.ptr);
    try std.testing.expectEqual(@as(usize, 0), renderer.direct_buffers.items.len);
    try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
    renderer.allocator = allocator;
    try bridge.upload(&mesh);
    const handle = mesh.bufferHandle();
    failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    renderer.allocator = failing.allocator();
    bridge.destroy(&mesh);
    // A duplicate adapter destroy must not submit the same tracked handle twice.
    const destroyed = state.destroyed;
    renderer.dedicatedMeshResources().destroyBuffer(handle);
    try std.testing.expectEqual(destroyed, state.destroyed);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1024), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(live + 1024, state.live_bytes);
    state.completeSlot(0);
    bridge.beginFrame(2);
    try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
    try std.testing.expectEqual(live, state.live_bytes);
    try std.testing.expect(!failing.has_induced_failure);
}

test "LOD dedicated ledger tracks far and non MDI empty replacements without counting active storage" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .defer_destruction = true };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer {
        renderer.deinit();
        for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |slot| state.completeSlot(slot);
        std.testing.expectEqual(@as(usize, 0), state.live_bytes) catch unreachable;
        std.testing.expectEqual(state.next_handle - 1, state.destroyed) catch unreachable;
    }
    const bridge = renderer.createGPUBridge();
    const live = state.live_bytes;
    for ([_]LODLevel{ .lod3, .lod4, .lod0 }, 0..) |lod, i| {
        renderer.enable_mdi = lod != .lod0;
        var mesh = LODMesh.init(allocator, lod);
        defer bridge.destroy(&mesh);
        bridge.beginFrame(i * 2 + 1);
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        try bridge.upload(&mesh);
        const handle = mesh.bufferHandle();
        try std.testing.expectEqual(@as(usize, 1024), mesh.memorySnapshot().capacity_bytes);
        try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 0);
        try bridge.upload(&mesh);
        try std.testing.expectEqual(@as(usize, 0), mesh.memorySnapshot().capacity_bytes);
        try std.testing.expectEqual(@as(usize, 1024), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
        try std.testing.expect(state.buffers[handle].bytes != null);
        try std.testing.expectEqual(live + 1024, state.live_bytes);
        state.completeSlot(0);
        bridge.beginFrame(i * 2 + 2);
        try std.testing.expectEqual(@as(usize, 0), renderer.toInterface().memoryStats().direct_gpu_retired_bytes);
        try std.testing.expectEqual(live, state.live_bytes);
    }
}

test "LOD dedicated ledger shutdown does not take mesh or external buffer ownership" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .defer_destruction = true };
    var rhi = ExpandedMDIMock{ .state = &state };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, rhi);
    var renderer_alive = true;
    var mesh = LODMesh.init(allocator, .lod3);
    const resources = LODMeshResources.fromProvider(ExpandedMDIMock, &rhi);
    defer {
        if (renderer_alive) renderer.deinit();
        mesh.deinit(resources);
        for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |slot| state.completeSlot(slot);
        std.testing.expectEqual(@as(usize, 0), state.live_bytes) catch unreachable;
        std.testing.expectEqual(state.next_handle - 1, state.destroyed) catch unreachable;
    }
    // Deliberately retain a mesh beyond renderer shutdown to detect ownership
    // theft/double deletion. Production tears meshes down before the renderer.
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    try renderer.createGPUBridge().upload(&mesh);
    const handle = mesh.bufferHandle();
    const external = try resources.createBuffer(1024, .vertex);
    defer resources.destroyBuffer(external);
    renderer.deinit();
    renderer_alive = false;
    state.completeSlot(0);
    try std.testing.expect(state.buffers[handle].bytes != null);
    try std.testing.expect(state.buffers[external].bytes != null);
    try std.testing.expectEqual(@as(?usize, null), state.buffers[handle].retired_slot);
    try std.testing.expectEqual(@as(usize, 2048), state.live_bytes);
}

test "LOD pressure fallback renderFrame submits valid mixed pooled and dedicated terrain and water" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    var pooled = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&pooled);
    var dedicated = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&dedicated);
    var pooled_chunk = LODChunk.init(4, 0, .lod1);
    var dedicated_chunk = LODChunk.init(5, 0, .lod1);
    // Select the fallback before creating pool headroom for its later retry.
    for ([_]*LODMesh{ &dedicated, &pooled }, [_]*LODChunk{ &dedicated_chunk, &pooled_chunk }, [_]i32{ 5, 4 }) |mesh, chunk, rx| {
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 18);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        mesh.opaque_vertex_count = 12;
        mesh.water_vertex_offset = 12 * @sizeOf(rhi_types.Vertex);
        mesh.water_vertex_count = 6;
        bridge.prepareUpload(mesh, if (mesh == &dedicated) 1024 else std.math.maxInt(usize));
        try bridge.upload(mesh);
        chunk.state = .renderable;
        const key = LODRegionKey{ .rx = rx, .rz = 0, .lod = .lod1 };
        try meshes[1].put(key, mesh);
        try regions[1].put(key, chunk);
    }
    try std.testing.expect(pooled.isPooled());
    try std.testing.expect(!dedicated.isPooled());
    var config = LODConfig{ .radii = .{ 16, 128, 256, 512, 1024 } };
    for ([_]LODRenderLayer{ .terrain, .fluid }, 0..) |layer, i| {
        renderer.renderFrame(1, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, 16, layer, null, null);
        try std.testing.expectEqual(i + 1, state.direct_draws);
        try std.testing.expectEqual(i + 1, state.draw_count);
        const range = dedicated.drawRange(layer).?;
        try std.testing.expectEqual(dedicated.bufferHandle(), state.last_direct_vertex);
        try std.testing.expectEqual(range.count, state.last_direct_count);
        try std.testing.expectEqual(range.offset, state.last_direct_offset);
        const draw = state.draws[i];
        try std.testing.expectEqual(pooled.bufferHandle(), draw.vertex);
        try std.testing.expectEqual(@as(u32, 1), draw.count);
        const command = std.mem.bytesToValue(rhi_types.DrawIndirectCommand, draw.command_bytes[draw.offset..][0..@sizeOf(rhi_types.DrawIndirectCommand)]);
        try std.testing.expectEqual(pooled.drawRange(layer).?.count, command.vertexCount);
        try std.testing.expectEqual(pooled.firstVertex(pooled.drawRange(layer).?), command.firstVertex);
        try state.expectUnchanged();
    }
}

test "LOD production bridge establishes update epoch before growth and preserves same-frame debt" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .frame_index = 1 };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    const pool = &renderer.vertex_pools[1];
    pool.initial_capacity_bytes = 1024;
    var mesh = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&mesh);
    bridge.beginFrame(10);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    try bridge.upload(&mesh);

    // World.update notifies the new actual RHI slot before streaming grows it.
    state.frame_index = 0;
    bridge.beginFrame(11);
    mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 1024 / @sizeOf(rhi_types.Vertex) + 1);
    @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
    try std.testing.expectEqual(@as(usize, 4096), bridge.uploadMemoryCost(&mesh));
    try bridge.upload(&mesh);
    try std.testing.expectEqual(@as(u64, 11), pool.retired_backings.items[0].serial);
    try std.testing.expectEqual(@as(usize, 0), pool.retired_backings.items[0].frame_slot);
    const memory = renderer.toInterface().memoryStats();
    try std.testing.expectEqual(@as(usize, 2048), memory.pool_gpu_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 2048), memory.pool_cpu_shadow_bytes);
    try std.testing.expectEqual(@as(usize, 1024), memory.pool_gpu_retired_bytes);

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    var config = LODConfig{};
    renderer.prepareFrame(11, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    bridge.destroy(&mesh);
    bridge.beginFrame(11);
    try std.testing.expectEqual(@as(usize, 2), pool.retired_ranges.items.len);
    state.frame_index = 1;
    bridge.beginFrame(12);
    try std.testing.expectEqual(@as(usize, 1024), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 2), pool.retired_ranges.items.len);
    state.frame_index = 0;
    bridge.beginFrame(13);
    try std.testing.expectEqual(@as(usize, 0), pool.retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.retired_ranges.items.len);
}

test "LOD pressure maintenance without GPU culling credits only shadows and trims once across layers" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{ .frame_index = 1 };
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    try std.testing.expect(renderer.gpu_culling == null);
    const bridge = renderer.createGPUBridge();
    var empty = LODMesh.init(allocator, .lod0);
    var large = LODMesh.init(allocator, .lod1);
    var small = LODMesh.init(allocator, .lod2);
    defer bridge.destroy(&empty);
    defer bridge.destroy(&large);
    defer bridge.destroy(&small);
    bridge.beginFrame(20);
    for ([_]*LODMesh{ &empty, &large, &small }, [_]usize{ 1024, 8192, 4096 }) |mesh, capacity| {
        renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].initial_capacity_bytes = capacity;
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        try bridge.upload(mesh);
    }
    bridge.destroy(&empty);
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    var config = LODConfig{};
    const staging_bytes = 3 * @sizeOf(rhi_types.Vertex);
    bridge.memoryPressure(32 * 1024, 32 * 1024, staging_bytes);
    try std.testing.expectEqual(@as(usize, 1024), renderer.vertex_pools[0].gpuMemoryBytes());
    renderer.prepareFrame(20, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 1024), renderer.vertex_pools[0].gpuMemoryBytes());
    bridge.beginFrame(21);
    bridge.memoryPressure(32 * 1024, 32 * 1024, staging_bytes);
    renderer.prepareFrame(21, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 0), renderer.vertex_pools[0].gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 1024), renderer.vertex_pools[0].retiredGpuMemoryBytes());
    // Reclaim freed 1024 CPU bytes, not the 2048 required for a trim peak.
    try std.testing.expectEqual(@as(usize, 8192), renderer.vertex_pools[1].gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 4096), renderer.vertex_pools[2].gpuMemoryBytes());
    bridge.beginFrame(22);
    bridge.memoryPressure(32 * 1024, 30 * 1024, staging_bytes - 1);
    renderer.prepareFrame(22, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 8192), renderer.vertex_pools[1].gpuMemoryBytes());
    bridge.beginFrame(23);
    bridge.memoryPressure(32 * 1024, 30 * 1024, staging_bytes);
    renderer.prepareFrame(23, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 1024), renderer.vertex_pools[1].gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 4096), renderer.vertex_pools[2].gpuMemoryBytes());
    try std.testing.expect(!renderer.memory_pressure_requested);
    const created = state.next_handle;
    bridge.memoryPressure(32 * 1024, 30 * 1024, staging_bytes);
    renderer.prepareFrame(23, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    renderer.renderFrame(23, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, 16, .terrain, null, null);
    renderer.renderFrame(23, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, 16, .fluid, null, null);
    try std.testing.expectEqual(created, state.next_handle);
    try std.testing.expectEqual(@as(usize, 8192), renderer.vertex_pools[1].retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 4096), renderer.vertex_pools[2].gpuMemoryBytes());
    bridge.beginFrame(24);
    bridge.memoryPressure(32 * 1024, 30 * 1024, staging_bytes);
    renderer.prepareFrame(24, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 1024), renderer.vertex_pools[2].gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), state.waits);
}

test "LOD pressure shadow reclamation pays over-budget deficit before admitting trim" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    var empty = LODMesh.init(allocator, .lod0);
    var live = LODMesh.init(allocator, .lod1);
    defer bridge.destroy(&empty);
    defer bridge.destroy(&live);
    bridge.beginFrame(1);
    for ([_]*LODMesh{ &empty, &live }, [_]usize{ 8 * 1024, 16 * 1024 }) |mesh, capacity| {
        renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].initial_capacity_bytes = capacity;
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3 * 1024 / @sizeOf(rhi_types.Vertex));
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        try bridge.upload(mesh);
    }
    bridge.destroy(&empty);
    bridge.beginFrame(2);
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    var config = LODConfig{};
    const created = state.next_handle;
    // Units are KiB: 260 used - 8 released = 252, leaving only 4 of 256.
    // The live pool needs a 4 KiB backing plus shadow, so its 8 KiB peak fails.
    bridge.memoryPressure(256 * 1024, 260 * 1024, 3 * 1024);
    renderer.prepareFrame(2, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 0), renderer.vertex_pools[0].gpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 8 * 1024), renderer.vertex_pools[0].retiredGpuMemoryBytes());
    try std.testing.expectEqual(@as(usize, 16 * 1024), renderer.vertex_pools[1].gpuMemoryBytes());
    try std.testing.expectEqual(created, state.next_handle);
    // With a refreshed 8 KiB of headroom, the same useful trim succeeds.
    bridge.beginFrame(3);
    bridge.memoryPressure(256 * 1024, 248 * 1024, 3 * 1024);
    renderer.prepareFrame(3, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, null, 16, null, null);
    try std.testing.expectEqual(@as(usize, 4 * 1024), renderer.vertex_pools[1].gpuMemoryBytes());
    try std.testing.expectEqual(created + 1, state.next_handle);
}

test "LOD production bridge memory cost follows pooled dedicated and compact upload dispatch" {
    const allocator = std.testing.allocator;
    var state = ExpandedMDIMock.State{};
    const renderer = try LODRenderer(ExpandedMDIMock).init(allocator, .{ .state = &state });
    defer renderer.deinit();
    renderer.enable_mdi = true;
    const bridge = renderer.createGPUBridge();
    bridge.beginFrame(1);
    for ([_]LODLevel{ .lod1, .lod3, .lod4, .lod0 }, [_]usize{ 8192, 1024, 1024, 1024 }) |lod, expected| {
        if (lod == .lod0) renderer.enable_mdi = false;
        renderer.vertex_pools[@intFromEnum(lod)].initial_capacity_bytes = 4096;
        var mesh = LODMesh.init(allocator, lod);
        defer bridge.destroy(&mesh);
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        try std.testing.expectEqual(expected, bridge.uploadMemoryCost(&mesh));
        var legacy = bridge;
        legacy.on_upload_memory_cost = null;
        try std.testing.expectEqual(@as(usize, 0), legacy.uploadMemoryCost(&mesh));
        try bridge.upload(&mesh);
        const backing = state.buffers[mesh.bufferHandle()].bytes.?.len;
        try std.testing.expectEqual(expected, backing * @as(usize, if (mesh.isPooled()) 2 else 1));
        try std.testing.expectEqual(@as(usize, 0), bridge.uploadMemoryCost(&mesh));
        mesh.pending_vertices = try allocator.alloc(rhi_types.Vertex, 3);
        @memset(mesh.pending_vertices.?, std.mem.zeroes(rhi_types.Vertex));
        try std.testing.expectEqual(@as(usize, 0), bridge.uploadMemoryCost(&mesh));
        try bridge.upload(&mesh);
    }
    var source = try lod_chunk.LODSimplifiedData.init(allocator, .lod4);
    defer source.deinit();
    var compact = LODMesh.init(allocator, .lod4);
    defer bridge.destroy(&compact);
    try compact.buildCompactTile(&source);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), bridge.uploadMemoryCost(&compact));
    try bridge.upload(&compact);
    try std.testing.expectEqual(@as(usize, 0), bridge.uploadMemoryCost(&compact));
    const compact_bytes = renderer.compact_pool.memoryStats().allocated_bytes;
    bridge.destroy(&compact);
    bridge.beginFrame(1);
    try std.testing.expectEqual(compact_bytes, renderer.compact_pool.memoryStats().retired_bytes);
    state.frame_index = 1;
    bridge.beginFrame(2);
    try std.testing.expectEqual(compact_bytes, renderer.compact_pool.memoryStats().retired_bytes);
    state.frame_index = 0;
    bridge.beginFrame(3);
    try std.testing.expectEqual(@as(usize, 0), renderer.compact_pool.memoryStats().retired_bytes);
}

test "expanded MDI allocation failure cleans up every layer and frame handle exactly once" {
    var successful = ExpandedMDIMock.State{};
    const Renderer = LODRenderer(ExpandedMDIMock);
    const renderer = try Renderer.init(std.testing.allocator, .{ .state = &successful });
    var mdi_bytes: usize = 0;
    for (successful.buffers) |buffer| {
        if (buffer.usage == .storage or buffer.usage == .indirect) {
            if (buffer.bytes) |bytes| mdi_bytes += bytes.len;
        }
    }
    try std.testing.expectEqual(2 * rhi_types.MAX_FRAMES_IN_FLIGHT * MAX_LOD_MDI_REGIONS * (@sizeOf(rhi_types.InstanceData) + @sizeOf(rhi_types.DrawIndirectCommand)), mdi_bytes);
    renderer.deinit();
    try std.testing.expectEqual(@as(usize, 0), successful.live_bytes);
    try std.testing.expectEqual(successful.next_handle - 1, successful.destroyed);
    // Include failures after all MDI allocations, during compact topology init.
    for (1..successful.next_handle) |fail_at| {
        var state = ExpandedMDIMock.State{ .fail_create_at = @intCast(fail_at) };
        try std.testing.expectError(error.OutOfMemory, Renderer.init(std.testing.allocator, .{ .state = &state }));
        try std.testing.expectEqual(fail_at - 1, state.destroyed);
        try std.testing.expectEqual(@as(usize, 0), state.live_bytes);
    }
}

test "LODRenderer init/deinit lifecycle" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        buffers_created: u32 = 0,
        buffers_destroyed: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            self.state.buffers_created += 1;
            return self.state.buffers_created;
        }
        pub fn destroyBuffer(self: @This(), _: u32) void {
            self.state.buffers_destroyed += 1;
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn draw(_: @This(), _: u32, _: u32, _: anytype) void {}
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);

    // Verify init created instance + indirect buffers for each layer and frame.
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT * 4), mock_state.buffers_created);
    try std.testing.expectEqual(@as(u32, 0), mock_state.buffers_destroyed);

    renderer.compact_pool.buffer_handle = 999;
    const memory = renderer.memoryStats();
    try std.testing.expectEqual(@as(usize, 0), memory.pool_gpu_capacity_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.pool_gpu_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), memory.pool_gpu_slack_bytes);
    try std.testing.expectEqual(@as(usize, CompactLODPool.CAPACITY_BYTES), memory.compact_pool_capacity_bytes);
    renderer.compact_pool.buffer_handle = 0;

    renderer.deinit();

    // Verify deinit destroyed all buffers
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT * 4), mock_state.buffers_destroyed);
}

test "LODRenderer batches pooled meshes into per-LOD indirect draws" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        next_handle: u32 = 1,
        draw_indirect_calls: u32 = 0,
        direct_draw_calls: u32 = 0,
        instance_updates: u32 = 0,
        indirect_updates: u32 = 0,
        last_draw_count: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}

        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, usage: anytype) !u32 {
            _ = usage;
            const handle = self.state.next_handle;
            self.state.next_handle += 1;
            return handle;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn updateBuffer(self: @This(), _: u32, _: usize, data: []const u8) !void {
            if (data.len % @sizeOf(rhi_types.InstanceData) == 0 and data.len != @sizeOf(rhi_types.DrawIndirectCommand)) {
                self.state.instance_updates += 1;
            } else {
                self.state.indirect_updates += 1;
            }
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn supportsIndirectFirstInstance(_: @This()) bool {
            return true;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODOwnershipBounds(_: @This(), _: [4]f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(_: @This(), _: u32, _: u32, _: anytype) void {}
        pub fn drawOffset(self: @This(), _: u32, _: u32, _: anytype, _: usize) void {
            self.state.direct_draw_calls += 1;
        }
        pub fn drawIndirect(self: @This(), _: u32, _: u32, _: usize, draw_count: u32, _: u32) void {
            self.state.draw_indirect_calls += 1;
            self.state.last_draw_count += draw_count;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();
    // Explicitly exercise the default-on MDI path.
    renderer.enable_mdi = true;

    renderer.vertex_pools[1].buffer_handle = 101;
    renderer.vertex_pools[2].buffer_handle = 102;

    var mesh_lod1 = LODMesh.init(allocator, .lod1);
    mesh_lod1.buffer_handle = 101;
    mesh_lod1.vertex_offset = 0;
    mesh_lod1.vertex_count = 12;
    mesh_lod1.pooled = true;
    mesh_lod1.ready = true;

    var mesh_lod2 = LODMesh.init(allocator, .lod2);
    mesh_lod2.buffer_handle = 102;
    mesh_lod2.vertex_offset = 4 * @sizeOf(rhi_types.Vertex);
    mesh_lod2.vertex_count = 18;
    mesh_lod2.pooled = true;
    mesh_lod2.ready = true;

    var chunk_lod1 = LODChunk.init(4, 0, .lod1);
    chunk_lod1.state = .renderable;
    var chunk_lod2 = LODChunk.init(8, 0, .lod2);
    chunk_lod2.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    try meshes[1].put(.{ .rx = 4, .rz = 0, .lod = .lod1 }, &mesh_lod1);
    try regions[1].put(.{ .rx = 4, .rz = 0, .lod = .lod1 }, &chunk_lod1);
    try meshes[2].put(.{ .rx = 8, .rz = 0, .lod = .lod2 }, &mesh_lod2);
    try regions[2].put(.{ .rx = 8, .rz = 0, .lod = .lod2 }, &chunk_lod2);

    var mock_config = LODConfig{ .radii = .{ 16, 128, 256, 512, 1024 } };
    var profiling = LODProfilingCollector.init(true);
    renderer.renderFrame(99, &meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, mock_config.chunk_render_radius, .terrain, null, &profiling);

    try std.testing.expectEqual(@as(u32, 2), mock_state.draw_indirect_calls);
    try std.testing.expectEqual(@as(u32, 2), mock_state.last_draw_count);

    // Water reuses the pooled indirect path rather than falling back to one
    // direct submission per region.
    mesh_lod1.opaque_vertex_count = 12;
    mesh_lod1.water_vertex_offset = 12 * @sizeOf(rhi_types.Vertex);
    mesh_lod1.water_vertex_count = 6;
    mesh_lod2.opaque_vertex_count = 18;
    mesh_lod2.water_vertex_offset = 18 * @sizeOf(rhi_types.Vertex);
    mesh_lod2.water_vertex_count = 9;
    renderer.renderFrame(99, &meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, mock_config.chunk_render_radius, .fluid, null, &profiling);
    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_indirect_calls);
    try std.testing.expectEqual(@as(u32, 0), mock_state.direct_draw_calls);
    const projection = profiling.snapshot().visibility_levels;
    try std.testing.expectEqual(@as(u64, 1), projection[1].candidates);
    try std.testing.expectEqual(@as(u64, 1), projection[2].candidates);

    // A direct-only mesh must not disable indirect submission for its pooled
    // sibling. This is the upload-transition fallback used in production.
    mesh_lod2.pooled = false;
    renderer.renderFrame(99, &meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, mock_config.chunk_render_radius, .terrain, null, &profiling);
    try std.testing.expectEqual(@as(u32, 5), mock_state.draw_indirect_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.direct_draw_calls);
}

test "LODRenderer band fade follows configured fog start percent" {
    var config = LODConfig{
        .radii = .{ 16, 40, 80, 160, 512 },
        .fog_start_percent = .{ 1.0, 0.5, 0.5, 0.5, 0.5 },
    };
    const iface = config.interface();

    const near_bounds = ChunkBounds{ .min_x = 16, .min_z = 0, .max_x = 16, .max_z = 0 };
    try std.testing.expectEqual(@as(f32, 0.0), calculateBandFade(iface, .lod1, near_bounds, Vec3.zero));

    const mid_bounds = ChunkBounds{ .min_x = 30, .min_z = 0, .max_x = 30, .max_z = 0 };
    try std.testing.expect(calculateBandFade(iface, .lod1, mid_bounds, Vec3.zero) > 0.0);
    try std.testing.expect(calculateBandFade(iface, .lod1, mid_bounds, Vec3.zero) < 1.0);

    const far_bounds = ChunkBounds{ .min_x = 40, .min_z = 0, .max_x = 40, .max_z = 0 };
    try std.testing.expectEqual(@as(f32, 1.0), calculateBandFade(iface, .lod1, far_bounds, Vec3.zero));
}

test "LODRenderer transition fade distinguishes child fade-in and parent fade-out" {
    var child = LODChunk.init(0, 0, .lod1);
    child.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
    try std.testing.expectEqual(@as(f32, 0.0), child.transitionFadeProgress());

    child.transition_frames_remaining = 0;
    try std.testing.expectEqual(@as(f32, 1.0), child.transitionFadeProgress());

    var parent = LODChunk.init(0, 0, .lod2);
    parent.ready_children = 4;
    parent.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
    try std.testing.expectEqual(@as(f32, 1.0), parent.transitionFadeProgress());

    parent.transition_frames_remaining = 0;
    try std.testing.expectEqual(@as(f32, 1.0), parent.transitionFadeProgress());
}

test "LODRenderer render draw path" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
        last_vertex_count: u32 = 0,
        last_buffer_handle: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, count: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.last_buffer_handle = handle;
            self.state.last_vertex_count = count;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();
    // MDI is enabled, but this RHI intentionally lacks indirect support.
    // Rendering must preserve the direct fallback for both terrain and water.
    renderer.enable_mdi = true;

    // Create mock mesh
    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 42;
    mesh.vertex_count = 106;
    mesh.opaque_vertex_count = 100;
    mesh.water_vertex_offset = 100 * @sizeOf(rhi_types.Vertex);
    mesh.water_vertex_count = 6;
    mesh.ready = true;

    // Create mock LODChunk in renderable state
    var chunk = LODChunk.init(5, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    // Add mesh and region at LOD1
    const key = LODRegionKey{ .rx = 5, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Create view-projection matrix that includes origin (where our chunk is)
    // Use identity for simplicity - frustum will include everything
    const view_proj = Mat4.identity;
    const camera_pos = Vec3.zero;

    var stats = LODStats{};

    // Call render with explicit parameters
    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, false, null, .terrain, &stats, null);
    // Verify draw was called with correct parameters
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
    try std.testing.expectEqual(@as(u32, 42), mock_state.last_buffer_handle);
    try std.testing.expectEqual(@as(u32, 100), mock_state.last_vertex_count);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[1]);

    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, false, null, .fluid, &stats, null);
    try std.testing.expectEqual(@as(u32, 2), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 6), mock_state.last_vertex_count);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.fluid_drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.fluid_instances[1]);
}

test "LODRenderer keeps coarse LOD visible while finer bands stream" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod2);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    // Region (2,0) at LOD2 covers chunks 16..23. It sits inside the LOD1 radius,
    // so inner-band culling would incorrectly suppress it if no finer LOD exists yet.
    var chunk = LODChunk.init(2, 0, .lod2);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(key, &mesh);
    try regions[2].put(key, &chunk);

    var mock_config = LODConfig{
        .radii = .{ 16, 32, 64, 100, 256 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}

test "LODRenderer disables mask when chunks are missing inside chunk render radius" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn missingInRadius(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.missingInRadius, &checker_ctx, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(LOD_UNMASKED_SENTINEL, mock_state.last_mask_radius);
}

test "LODRenderer chunk mask uses chunk render radius instead of LOD0 radius" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    // Region rx=3 sits inside the LOD0 ring radius below, but outside the
    // configured full-chunk render radius. Missing chunks there must not unmask
    // the inner chunk/LOD handoff.
    var chunk = LODChunk.init(3, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 3, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{
        .chunk_render_radius = 4,
        .radii = .{ 16, 32, 64, 100, 256 },
    };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn missing(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.missing, &checker_ctx, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(mock_config.interface().calculateMaskRadius(), mock_state.last_mask_radius);
}

test "LODRenderer keeps mask when only outside-radius chunks are uncovered" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(4, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 4, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn loaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.loaded, &checker_ctx, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(mock_config.interface().calculateMaskRadius(), mock_state.last_mask_radius);
}

test "LODRenderer keeps mask for partially covered chunk regions" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .chunk_render_radius = 4, .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn partiallyLoaded(cx: i32, cz: i32, _: *anyopaque) bool {
            return cx == 0 and cz == 0;
        }
    };

    renderer.renderFrame(1, &meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.partiallyLoaded, &checker_ctx, false, null, mock_config.chunk_render_radius, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(readyDiskMaskRadius(0), mock_state.last_mask_radius);
}

test "LODRenderer skips coarse LOD when finer coverage is ready" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 7;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_chunk = LODChunk.init(2, 0, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 4;
    const coarse_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = 4, .rz = 0, .lod = .lod1 },
        .{ .rx = 5, .rz = 0, .lod = .lod1 },
        .{ .rx = 4, .rz = 1, .lod = .lod1 },
        .{ .rx = 5, .rz = 1, .lod = .lod1 },
    };
    var finer_chunks: [4]LODChunk = undefined;
    var finer_meshes: [4]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(10 + idx));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{
        .radii = .{ 16, 32, 64, 100, 256 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
}

test "LODRenderer always renders ready LOD0 regions" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod0);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(2, 0, .lod0);
    chunk.state = .renderable;
    chunk.ready_children = 4;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod0 };
    try meshes[0].put(key, &mesh);
    try regions[0].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var stats = LODStats{};
    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, &stats, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[0]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[0]);
}

test "LODRenderer keeps coarse LOD when a finer child is missing" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        handle_sum: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODOwnershipBounds(_: @This(), _: [4]f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.handle_sum += handle;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 100;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;
    var coarse_chunk = LODChunk.init(2, 0, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 3;
    const coarse_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = 4, .rz = 0, .lod = .lod1 },
        .{ .rx = 5, .rz = 0, .lod = .lod1 },
        .{ .rx = 4, .rz = 1, .lod = .lod1 },
    };
    var finer_chunks: [finer_keys.len]LODChunk = undefined;
    var finer_meshes: [finer_keys.len]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(idx + 1));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 106), mock_state.handle_sum);
}

test "LODRenderer resolves finer coverage across negative region boundaries" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        handle_sum: u32 = 0,
    };

    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.handle_sum += handle;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 100;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;
    var coarse_chunk = LODChunk.init(-1, -1, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 4;
    const coarse_key = LODRegionKey{ .rx = -1, .rz = -1, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = -2, .rz = -2, .lod = .lod1 },
        .{ .rx = -1, .rz = -2, .lod = .lod1 },
        .{ .rx = -2, .rz = -1, .lod = .lod1 },
        .{ .rx = -1, .rz = -1, .lod = .lod1 },
    };
    var finer_chunks: [finer_keys.len]LODChunk = undefined;
    var finer_meshes: [finer_keys.len]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(idx + 1));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 10), mock_state.handle_sum);
}

test "LODRenderer counts only consecutive compact backend draw failures" {
    const allocator = std.testing.allocator;
    const MockState = struct {
        draw_available: bool = true,
        draw_calls: u32 = 0,
    };
    const MockRHI = struct {
        pub fn waitIdle(_: @This()) void {}

        state: *MockState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setLODDescriptorStream(_: @This(), _: rhi_types.LODDescriptorStream) void {}
        pub fn setLODCompactSampleBuffer(_: @This(), _: u32) void {}
        pub fn drawCompactLOD(self: @This(), _: u32, _: u32, _: rhi_types.CompactLODDraw) bool {
            self.state.draw_calls += 1;
            return self.state.draw_available;
        }
    };

    var state = MockState{};
    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, .{ .state = &state });
    defer renderer.deinit();
    try std.testing.expect(!renderer.ensureCompactIndexBuffers(0));
    renderer.frame_serial = 1;

    var mesh = LODMesh.init(allocator, .lod3);
    mesh.compact = true;
    mesh.compact_tile_width = 5;
    mesh.compact_index_count = 192;
    mesh.ready = true;
    mesh.vertex_count = 192;
    const visible = VisibleRegion{ .key = .{ .rx = 0, .rz = 0, .lod = .lod3 }, .model = Mat4.identity, .mask_radius = 1, .lod_fade = 1 };

    // A first frame without a ready compact sample buffer is retryable. It
    // must not disable compact before a backend submission was attempted.
    try std.testing.expectEqual(CompactRenderResult.unavailable, renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain));
    try std.testing.expect(mesh.isRenderable());

    renderer.compact_pool.buffer_handle = 7;
    try std.testing.expectEqual(CompactRenderResult.drawn, renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain));
    try std.testing.expect(mesh.isRenderable());

    state.draw_available = false;
    var profiling = LODProfilingCollector.init(true);
    const first = renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain);
    renderer.noteCompactRenderFailure(&mesh, first, &profiling);
    try std.testing.expectEqual(CompactRenderResult.backend_failed, first);
    try std.testing.expect(mesh.isRenderable());

    // A confirmed draw breaks the failure streak. A transient unavailable
    // frame remains a non-submission and must not affect that reset state.
    state.draw_available = true;
    try std.testing.expectEqual(CompactRenderResult.drawn, renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain));
    try std.testing.expectEqual(@as(u8, 0), mesh.compact_backend_draw_failures);
    renderer.compact_pool.buffer_handle = 0;
    const unavailable = renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain);
    renderer.noteCompactRenderFailure(&mesh, unavailable, &profiling);
    try std.testing.expectEqual(CompactRenderResult.unavailable, unavailable);
    try std.testing.expectEqual(@as(u8, 0), mesh.compact_backend_draw_failures);

    renderer.compact_pool.buffer_handle = 7;
    state.draw_available = false;
    var attempt: u8 = 0;
    while (attempt < LODMesh.COMPACT_BACKEND_FAILURE_LIMIT) : (attempt += 1) {
        const repeated = renderer.renderCompactMesh(renderer.rhi, visible, &mesh, .terrain);
        renderer.noteCompactRenderFailure(&mesh, repeated, &profiling);
        try std.testing.expectEqual(CompactRenderResult.backend_failed, repeated);
        try std.testing.expectEqual(attempt + 1 < LODMesh.COMPACT_BACKEND_FAILURE_LIMIT, mesh.isRenderable());
    }
    try std.testing.expect(!mesh.isRenderable());
    try std.testing.expectEqual(@as(u64, LODMesh.COMPACT_BACKEND_FAILURE_LIMIT + 1), profiling.snapshot().compact_draw_failures);
    try std.testing.expectEqual(@as(u64, 1), profiling.snapshot().compact_draw_unavailable);
}

test "LODRenderer renderFrame times confirmed compact direct terrain and water submissions" {
    const allocator = std.testing.allocator;
    const State = struct {
        next_handle: u32 = 1,
        compact_draw_succeeds: bool = true,
        compact_draws: u32 = 0,
        terrain_timing_begins: u32 = 0,
        terrain_timing_ends: u32 = 0,
        water_timing_begins: u32 = 0,
        water_timing_ends: u32 = 0,
    };
    const MockRHI = struct {
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn draw(_: @This(), _: u32, _: u32, _: anytype) void {
            unreachable;
        }

        state: *State,

        const Timing = struct {
            state: *State,

            fn beginPassTiming(self: @This(), name: []const u8) void {
                if (std.mem.eql(u8, name, "LODCompactTerrainPass")) self.state.terrain_timing_begins += 1;
                if (std.mem.eql(u8, name, "LODCompactWaterPass")) self.state.water_timing_begins += 1;
            }
            fn endPassTiming(self: @This(), name: []const u8) void {
                if (std.mem.eql(u8, name, "LODCompactTerrainPass")) self.state.terrain_timing_ends += 1;
                if (std.mem.eql(u8, name, "LODCompactWaterPass")) self.state.water_timing_ends += 1;
            }
        };

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            const handle = self.state.next_handle;
            self.state.next_handle += 1;
            return handle;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}
        pub fn waitIdle(_: @This()) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setLODDescriptorStream(_: @This(), _: rhi_types.LODDescriptorStream) void {}
        pub fn setLODCompactSampleBuffer(_: @This(), _: u32) void {}
        pub fn drawCompactLOD(self: @This(), _: u32, _: u32, _: rhi_types.CompactLODDraw) bool {
            self.state.compact_draws += 1;
            return self.state.compact_draw_succeeds;
        }
        pub fn timing(self: @This()) Timing {
            return .{ .state = self.state };
        }
    };

    var state = State{};
    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, .{ .state = &state });
    defer renderer.deinit();
    try std.testing.expect(!renderer.ensureCompactIndexBuffers(0));
    renderer.compact_pool.buffer_handle = 99;

    var mesh = LODMesh.init(allocator, .lod3);
    mesh.compact = true;
    mesh.compact_tile_width = 5;
    mesh.compact_index_count = 192;
    mesh.compact_has_water = true;
    mesh.vertex_count = 192;
    mesh.ready = true;
    var chunk = LODChunk.init(0, 0, .lod3);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer for (0..LODLevel.count) |i| {
        meshes[i].deinit();
        regions[i].deinit();
    };
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    try meshes[@intFromEnum(LODLevel.lod3)].put(key, &mesh);
    try regions[@intFromEnum(LODLevel.lod3)].put(key, &chunk);

    var config = LODConfig{ .radii = .{ 16, 32, 64, 128, 256 } };
    var profiling = LODProfilingCollector.init(true);
    renderer.renderFrame(1, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, config.chunk_render_radius, .terrain, null, &profiling);
    renderer.renderFrame(1, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, config.chunk_render_radius, .fluid, null, &profiling);

    try std.testing.expectEqual(@as(u32, 2), state.compact_draws);
    try std.testing.expectEqual(state.terrain_timing_begins, state.terrain_timing_ends);
    try std.testing.expectEqual(state.water_timing_begins, state.water_timing_ends);
    try std.testing.expectEqual(@as(u32, 1), state.terrain_timing_begins);
    try std.testing.expectEqual(@as(u32, 1), state.water_timing_begins);
    try std.testing.expectEqual(@as(u64, 2), profiling.snapshot().compact_submissions);

    state.compact_draw_succeeds = false;
    renderer.renderFrame(2, &meshes, &regions, config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, config.chunk_render_radius, .terrain, null, &profiling);
    try std.testing.expectEqual(state.terrain_timing_begins, state.terrain_timing_ends);
    try std.testing.expectEqual(@as(u32, 2), state.terrain_timing_begins);
    try std.testing.expectEqual(@as(u64, 2), profiling.snapshot().compact_submissions);
}

test "LODRenderer submits fixed-capacity compact streams without indirect-count support" {
    const allocator = std.testing.allocator;
    const State = struct {
        next_handle: u32 = 1,
        indirect_succeeds: bool = true,
        compact_indirect_draws: u32 = 0,
        timing_begins: u32 = 0,
        timing_ends: u32 = 0,
    };
    const MockRHI = struct {
        state: *State,

        const Timing = struct {
            state: *State,

            fn beginPassTiming(self: @This(), name: []const u8) void {
                if (std.mem.eql(u8, name, "LODCompactTerrainPass")) self.state.timing_begins += 1;
            }
            fn endPassTiming(self: @This(), name: []const u8) void {
                if (std.mem.eql(u8, name, "LODCompactTerrainPass")) self.state.timing_ends += 1;
            }
        };

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            const handle = self.state.next_handle;
            self.state.next_handle += 1;
            return handle;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn uploadBuffer(_: @This(), _: u32, _: []const u8) !void {}
        pub fn waitIdle(_: @This()) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn supportsIndirectFirstInstance(_: @This()) bool {
            return true;
        }
        pub fn supportsIndirectCount(_: @This()) bool {
            return false;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setLODDescriptorStream(_: @This(), _: rhi_types.LODDescriptorStream) void {}
        pub fn setLODCompactSampleBuffer(_: @This(), _: u32) void {}
        pub fn setLODCompactInstanceBuffer(_: @This(), _: u32) void {}
        pub fn drawIndirectCount(_: @This(), _: u32, _: u32, _: usize, _: u32, _: usize, _: u32, _: u32) bool {
            return true;
        }
        pub fn drawCompactLODIndirectCount(self: @This(), _: u32, _: u32, _: usize, _: u32, _: usize, _: u32) bool {
            self.state.compact_indirect_draws += 1;
            return self.state.indirect_succeeds;
        }
        pub fn timing(self: @This()) Timing {
            return .{ .state = self.state };
        }
    };
    const Culling = struct {
        fn deinit(_: *anyopaque) void {}
        fn dispatch(_: *anyopaque, _: usize, _: []const LODCullCandidate, _: LODCullDispatch) bool {
            return true;
        }
        fn instanceBuffer(_: *anyopaque, _: usize, _: bool, _: bool) u32 {
            return 11;
        }
        fn indirectBuffer(_: *anyopaque, _: usize, _: bool, _: bool) u32 {
            return 12;
        }
        fn countBuffer(_: *anyopaque, _: usize) u32 {
            return 13;
        }
        fn diagnostics(_: *anyopaque) rhi_types.LODCullDiagnostics {
            return .{};
        }
        const vtable = ILODCullingSystem.VTable{
            .deinit = deinit,
            .dispatch = dispatch,
            .instanceBuffer = instanceBuffer,
            .indirectBuffer = indirectBuffer,
            .countBuffer = countBuffer,
            .diagnostics = diagnostics,
        };
    };

    var state = State{};
    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, .{ .state = &state });
    defer renderer.deinit();
    try std.testing.expect(!renderer.ensureCompactIndexBuffers(0));
    renderer.frame_serial = 1;
    renderer.compact_pool.buffer_handle = 99;
    renderer.gpu_culling_threshold = 1;
    renderer.projection_frame = 1;
    renderer.gpu_culling_ready_frame = 1;
    renderer.gpu_culling = .{ .ptr = @ptrCast(&state), .vtable = &Culling.vtable };

    var candidate = std.mem.zeroes(LODCullCandidate);
    candidate.terrain_command = .{ .count = 24, .instance_count = 1, .first = 0 };
    candidate.compact_words[1] = 65;
    candidate.lod_and_padding = .{ @intFromEnum(LODLevel.lod3), 1, 0, 0 };
    try renderer.gpu_candidates.append(allocator, candidate);
    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    try renderer.gpu_candidate_keys.append(allocator, first_key);

    var profiling = LODProfilingCollector.init(true);
    try std.testing.expect(renderer.renderGpuCulledLayer(.terrain, null, &profiling, renderer.rhi, renderer.rhi));
    try std.testing.expectEqual(@as(u32, 1), state.compact_indirect_draws);
    try std.testing.expectEqual(@as(u32, 1), state.timing_begins);
    try std.testing.expectEqual(state.timing_begins, state.timing_ends);
    try std.testing.expectEqual(@as(u64, 1), profiling.snapshot().compact_submissions);

    state.indirect_succeeds = false;
    try std.testing.expect(!renderer.renderGpuCulledLayer(.terrain, null, &profiling, renderer.rhi, renderer.rhi));
    try std.testing.expectEqual(state.timing_begins, state.timing_ends);
    try std.testing.expectEqual(@as(u64, 1), profiling.snapshot().compact_submissions);

    var second_candidate = candidate;
    second_candidate.compact_words[1] = 33;
    try renderer.gpu_candidates.append(allocator, second_candidate);
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod3 };
    try renderer.gpu_candidate_keys.append(allocator, second_key);
    try std.testing.expect(!renderer.gpuCandidateDraws(first_key, .terrain));
    try std.testing.expect(!renderer.gpuCandidateDraws(second_key, .terrain));
}

test "LODRenderer createGPUBridge and toInterface round-trip" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        upload_calls: u32 = 0,
        destroy_calls: u32 = 0,
        wait_idle_calls: u32 = 0,
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
    };

    const MockRHI = struct {
        pub fn supportsIndirectFirstInstance(_: @This()) bool {
            return false;
        }

        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            _ = self;
            return 1;
        }
        pub fn destroyBuffer(self: @This(), _: u32) void {
            self.state.destroy_calls += 1;
        }
        pub fn uploadBuffer(self: @This(), _: u32, _: []const u8) !void {
            self.state.upload_calls += 1;
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn waitIdle(self: @This()) void {
            self.state.wait_idle_calls += 1;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    // Test createGPUBridge round-trip
    const bridge = renderer.createGPUBridge();

    // Verify bridge.waitIdle calls through to MockRHI.waitIdle
    bridge.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), mock_state.wait_idle_calls);

    // Verify bridge.destroy calls through to MockRHI.destroyBuffer (via LODMesh.deinit)
    var test_mesh = LODMesh.init(allocator, .lod1);
    test_mesh.buffer_handle = 99;
    bridge.destroy(&test_mesh);
    try std.testing.expectEqual(@as(u32, 1), mock_state.destroy_calls);
    try std.testing.expectEqual(@as(u32, 0), test_mesh.buffer_handle); // deinit zeroes handle

    // Test toInterface round-trip: render through type-erased interface
    const iface = renderer.toInterface();

    // Set up meshes/regions with a renderable chunk
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 42;
    mesh.vertex_count = 50;
    mesh.ready = true;

    var chunk = LODChunk.init(5, 0, .lod1);
    chunk.state = .renderable;

    const key = LODRegionKey{ .rx = 5, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Render through the type-erased interface
    iface.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null, null);

    // Verify the real renderer's draw was invoked through the interface
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}
