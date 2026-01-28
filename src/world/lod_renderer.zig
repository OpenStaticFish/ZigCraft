//! LOD Renderer - handles culling and drawing of LOD meshes using MDI.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;

const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const rhi_types = @import("../engine/graphics/rhi_types.zig");
const log = @import("../engine/core/log.zig");

/// Expected RHI interface for LODRenderer:
/// - createBuffer(size: usize, usage: BufferUsage) !BufferHandle
/// - destroyBuffer(handle: BufferHandle) void
/// - getFrameIndex() usize
/// - setModelMatrix(model: Mat4, color: Vec3, mask_radius: f32) void
/// - draw(handle: BufferHandle, count: u32, mode: DrawMode) void
pub fn LODRenderer(comptime RHI: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        rhi: RHI,

        // MDI Resources (Moved from LODManager)
        instance_data: std.ArrayListUnmanaged(rhi_types.InstanceData),
        draw_list: std.ArrayListUnmanaged(*LODMesh),
        instance_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        frame_index: usize,

        pub fn init(allocator: std.mem.Allocator, rhi: RHI) !*Self {
            const renderer = try allocator.create(Self);

            // Init MDI buffers (capacity for ~2048 LOD regions)
            const max_regions = 2048;
            var instance_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle = undefined;
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                instance_buffers[i] = try rhi.createBuffer(max_regions * @sizeOf(rhi_types.InstanceData), .storage);
            }

            renderer.* = .{
                .allocator = allocator,
                .rhi = rhi,
                .instance_data = .empty,
                .draw_list = .empty,
                .instance_buffers = instance_buffers,
                .frame_index = 0,
            };

            return renderer;
        }

        pub fn deinit(self: *Self) void {
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                if (self.instance_buffers[i] != 0) {
                    self.rhi.destroyBuffer(self.instance_buffers[i]);
                }
            }
            self.instance_data.deinit(self.allocator);
            self.draw_list.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Render all LOD meshes
        pub fn render(
            self: *Self,
            manager: anytype,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?*const fn (i32, i32, *anyopaque) bool,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
        ) void {
            // Update frame index
            self.frame_index = self.rhi.getFrameIndex();

            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();

            // Set LOD mode on RHI
            self.rhi.setLODInstanceBuffer(self.instance_buffers[self.frame_index]);

            const frustum = Frustum.fromViewProj(view_proj);
            const lod_y_offset: f32 = -3.0;

            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();

            // Collect visible meshes
            // Process from highest LOD down
            var i: usize = LODLevel.count - 1;
            while (i > 0) : (i -= 1) {
                self.collectVisibleMeshes(manager, &manager.meshes[i], &manager.regions[i], view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx, use_frustum) catch |err| {
                    log.log.err("Failed to collect visible meshes for LOD{}: {}", .{ i, err });
                };
            }

            if (self.instance_data.items.len == 0) return;

            for (self.draw_list.items, 0..) |mesh, idx| {
                const instance = self.instance_data.items[idx];
                self.rhi.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
                self.rhi.draw(mesh.buffer_handle, mesh.vertex_count, .triangles);
            }
        }

        fn collectVisibleMeshes(
            self: *Self,
            manager: anytype,
            meshes: anytype,
            regions: anytype,
            view_proj: Mat4,
            camera_pos: Vec3,
            frustum: Frustum,
            lod_y_offset: f32,
            chunk_checker: ?*const fn (i32, i32, *anyopaque) bool,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
        ) !void {
            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                const mesh = entry.value_ptr.*;
                if (!mesh.ready or mesh.vertex_count == 0) continue;
                if (regions.get(entry.key_ptr.*)) |chunk| {
                    if (chunk.state != .renderable) continue;
                    const bounds = chunk.worldBounds();

                    // Check if all underlying block chunks are loaded.
                    // If they are, we skip rendering the LOD chunk to let blocks show through.
                    if (chunk_checker) |checker| {
                        const side: i32 = @intCast(chunk.lod_level.chunksPerSide());
                        const start_cx = chunk.region_x * side;
                        const start_cz = chunk.region_z * side;

                        var all_loaded = true;
                        var lcz: i32 = 0;
                        while (lcz < side) : (lcz += 1) {
                            var lcx: i32 = 0;
                            while (lcx < side) : (lcx += 1) {
                                if (!checker(start_cx + lcx, start_cz + lcz, checker_ctx.?)) {
                                    all_loaded = false;
                                    break;
                                }
                            }
                            if (!all_loaded) break;
                        }

                        if (all_loaded) continue;
                    }

                    const aabb_min = Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, 0.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z);
                    const aabb_max = Vec3.init(@as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, 256.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z);
                    if (use_frustum and !frustum.intersectsAABB(AABB.init(aabb_min, aabb_max))) continue;

                    const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                    const mask_radius = manager.config.calculateMaskRadius() * @as(f32, @floatFromInt(CHUNK_SIZE_X));
                    try self.instance_data.append(self.allocator, .{
                        .view_proj = view_proj,
                        .model = model,
                        .mask_radius = mask_radius,
                        .padding = .{ 0, 0, 0 },
                    });
                    try self.draw_list.append(self.allocator, mesh);
                }
            }
        }
    };
}

// Tests
test "LODRenderer init/deinit lifecycle" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        buffers_created: u32 = 0,
        buffers_destroyed: u32 = 0,
    };

    const MockRHI = struct {
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

    // Verify init created buffers for each frame in flight
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT), mock_state.buffers_created);
    try std.testing.expectEqual(@as(u32, 0), mock_state.buffers_destroyed);

    renderer.deinit();

    // Verify deinit destroyed all buffers
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT), mock_state.buffers_destroyed);
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

    // Create mock mesh
    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 42;
    mesh.vertex_count = 100;
    mesh.ready = true;

    // Create mock LODChunk in renderable state
    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    // Create mock manager with meshes and regions
    const MeshMap = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80);
    const RegionMap = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80);

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
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    const MockManager = struct {
        meshes: *[LODLevel.count]MeshMap,
        regions: *[LODLevel.count]RegionMap,
        config: ILODConfig,

        pub fn unloadLODWhereChunksLoaded(_: @This(), _: anytype, _: anytype) void {}
        pub fn areAllChunksLoaded(_: @This(), _: anytype, _: anytype, _: anytype) bool {
            return false; // Not loaded, so LOD should render
        }
    };

    var mock_config = LODConfig{};
    const mock_manager = MockManager{
        .meshes = &meshes,
        .regions = &regions,
        .config = mock_config.interface(),
    };

    // Create view-projection matrix that includes origin (where our chunk is)
    // Use identity for simplicity - frustum will include everything
    const view_proj = Mat4.identity;
    const camera_pos = Vec3.zero;

    // Call render
    renderer.render(mock_manager, view_proj, camera_pos, null, null, true);

    // Verify draw was called with correct parameters
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
    try std.testing.expectEqual(@as(u32, 42), mock_state.last_buffer_handle);
    try std.testing.expectEqual(@as(u32, 100), mock_state.last_vertex_count);
}
