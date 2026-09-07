const Mat4 = @import("engine-math").Mat4;

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
