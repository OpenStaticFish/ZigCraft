const Mat4 = @import("engine-math").Mat4;
const rhi_types = @import("rhi_types.zig");

pub const ChunkCullData = extern struct {
    min_point: [4]f32,
    max_point: [4]f32,
};

pub const DispatchConfig = struct {
    view_proj: Mat4,
    chunk_count: u32,
    screen_width: f32,
    screen_height: f32,
    previous_frame_valid: bool,
};

pub const ICullingSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        updateAABBData: *const fn (ptr: *anyopaque, frame_index: usize, chunks: []const ChunkCullData) void,
        readVisibleCount: *const fn (ptr: *anyopaque, frame_index: usize) u32,
        readVisibleIndices: *const fn (ptr: *anyopaque, frame_index: usize, count: u32, out: []u32) void,
        dispatch: *const fn (ptr: *anyopaque, config: DispatchConfig) void,
    };

    /// Releases backend culling buffers, pipelines, and readback resources.
    /// No dispatch or readback methods may be used after this returns.
    pub fn deinit(self: ICullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    /// Uploads chunk AABB data for the selected frame-in-flight slot.
    /// `chunks` is copied or staged by the backend and must match the dispatch chunk count used for that frame.
    pub fn updateAABBData(self: ICullingSystem, frame_index: usize, chunks: []const ChunkCullData) void {
        self.vtable.updateAABBData(self.ptr, frame_index, chunks);
    }

    /// Reads the visible chunk count produced by a previous culling dispatch.
    /// The returned value is valid only after the backend has completed the corresponding frame's compute work.
    pub fn readVisibleCount(self: ICullingSystem, frame_index: usize) u32 {
        return self.vtable.readVisibleCount(self.ptr, frame_index);
    }

    /// Copies visible chunk indices from backend readback storage into `out`.
    /// `count` should come from `readVisibleCount`; the implementation clamps writes to `out.len`.
    pub fn readVisibleIndices(self: ICullingSystem, frame_index: usize, count: u32, out: []u32) void {
        self.vtable.readVisibleIndices(self.ptr, frame_index, count, out);
    }

    /// Dispatches GPU frustum/occlusion culling for the configured chunk set.
    /// Must run on the render thread with current-frame AABB data already uploaded.
    pub fn dispatch(self: ICullingSystem, config: DispatchConfig) void {
        self.vtable.dispatch(self.ptr, config);
    }
};

/// A command source has two vec4 lanes in the candidate SSBO. Standard draws
/// use `count`, `instance_count`, `first`, and `first_instance`; compact draws
/// additionally use `vertex_offset` and are emitted as indexed commands.
pub const LODCullCommand = extern struct {
    count: u32,
    instance_count: u32,
    first: u32,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
    _padding: [3]u32 = .{ 0, 0, 0 },
};

/// One CPU-approved LOD region. The layout is a fixed std430 ABI shared with
/// lod_culling.comp. `lod_and_flags[1]` selects indexed compact output.
pub const LODCullCandidate = extern struct {
    min_point: [4]f32,
    max_point: [4]f32,
    model: Mat4,
    instance_params: [4]f32,
    /// x=sample offset, y=grid width; only meaningful for compact candidates.
    compact_words: [4]u32,
    /// x=cell size, y=skirt depth; mask/fade remain in instance_params.
    compact_metrics: [4]f32,
    terrain_command: LODCullCommand,
    water_command: LODCullCommand,
    lod_and_padding: [4]u32,
    ownership_bounds: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const LODCullDispatch = extern struct {
    planes: [6][4]f32,
    candidate_count: u32,
    max_distance_blocks: f32,
    max_commands_per_lod: u32,
    _padding: u32 = 0,
};

pub const LODCullDiagnostics = extern struct {
    overflow_count: u32 = 0,
    validation_mismatch_count: u32 = 0,
    /// Monotonic opt-in validation work generation. A generation is assigned
    /// when its device readback has been queued, not when it is assumed done.
    validation_generation: u64 = 0,
    /// Last validation generation observed after its delayed frame-slot fence.
    validation_completed_generation: u64 = 0,
    /// Number of delayed validation readbacks actually completed.
    validation_completed_count: u64 = 0,
};

pub const ILODCullingSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        dispatch: *const fn (ptr: *anyopaque, frame_index: usize, candidates: []const LODCullCandidate, config: LODCullDispatch) bool,
        instanceBuffer: *const fn (ptr: *anyopaque, frame_index: usize, fluid: bool, compact: bool) rhi_types.BufferHandle,
        indirectBuffer: *const fn (ptr: *anyopaque, frame_index: usize, fluid: bool, compact: bool) rhi_types.BufferHandle,
        countBuffer: *const fn (ptr: *anyopaque, frame_index: usize) rhi_types.BufferHandle,
        diagnostics: *const fn (ptr: *anyopaque) LODCullDiagnostics,
    };

    pub fn deinit(self: ILODCullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    /// Records same-frame compute culling before graphics render passes begin.
    /// Returns false when inputs exceed the fixed GPU capacity.
    pub fn dispatch(self: ILODCullingSystem, frame_index: usize, candidates: []const LODCullCandidate, config: LODCullDispatch) bool {
        return self.vtable.dispatch(self.ptr, frame_index, candidates, config);
    }

    pub fn instanceBuffer(self: ILODCullingSystem, frame_index: usize, fluid: bool, compact: bool) rhi_types.BufferHandle {
        return self.vtable.instanceBuffer(self.ptr, frame_index, fluid, compact);
    }

    pub fn indirectBuffer(self: ILODCullingSystem, frame_index: usize, fluid: bool, compact: bool) rhi_types.BufferHandle {
        return self.vtable.indirectBuffer(self.ptr, frame_index, fluid, compact);
    }
    pub fn countBuffer(self: ILODCullingSystem, frame_index: usize) rhi_types.BufferHandle {
        return self.vtable.countBuffer(self.ptr, frame_index);
    }
    pub fn diagnostics(self: ILODCullingSystem) LODCullDiagnostics {
        return self.vtable.diagnostics(self.ptr);
    }
};

test "LOD culling candidate ABI is std430 aligned" {
    try @import("std").testing.expectEqual(@as(usize, 240), @sizeOf(LODCullCandidate));
    try @import("std").testing.expectEqual(@as(usize, 224), @offsetOf(LODCullCandidate, "ownership_bounds"));
    try @import("std").testing.expectEqual(@as(usize, 32), @offsetOf(LODCullCandidate, "model"));
    try @import("std").testing.expectEqual(@as(usize, 96), @offsetOf(LODCullCandidate, "instance_params"));
    try @import("std").testing.expectEqual(@as(usize, 144), @offsetOf(LODCullCandidate, "terrain_command"));
    try @import("std").testing.expectEqual(@as(usize, 208), @offsetOf(LODCullCandidate, "lod_and_padding"));
    try @import("std").testing.expectEqual(@as(usize, 32), @sizeOf(LODCullCommand));
}

test "LOD culling diagnostics expose delayed validation completion" {
    const diagnostics = LODCullDiagnostics{
        .validation_generation = 9,
        .validation_completed_generation = 8,
        .validation_completed_count = 8,
    };
    try @import("std").testing.expectEqual(@as(u64, 9), diagnostics.validation_generation);
    try @import("std").testing.expectEqual(@as(u64, 8), diagnostics.validation_completed_generation);
    try @import("std").testing.expectEqual(@as(u64, 8), diagnostics.validation_completed_count);
}
