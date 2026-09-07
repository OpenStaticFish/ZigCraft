const std = @import("std");
const LODLevel = @import("lod_types.zig").LODLevel;
const LODSimplifiedData = @import("lod_chunk.zig").LODSimplifiedData;
const ChunkSummary = @import("world-core").lod_scene.ChunkSummary;

pub const LODGenerator = struct {
    ptr: *anyopaque,
    generate_heightmap_only: *const fn (ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void,
    maybe_recenter_cache: *const fn (ptr: *anyopaque, player_x: i32, player_z: i32) bool,
    seed: u64,
    identity_hash: u64,
    version: u32,
    summary_context: ?*anyopaque = null,
    /// Strict, non-creating block-source lookup: only confirmed absence is null.
    load_chunk_summary: ?*const fn (ctx: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator) anyerror!?ChunkSummary = null,
    generate_chunk_summary: ?*const fn (ctx: *anyopaque, cx: i32, cz: i32, allocator: std.mem.Allocator, cancel: ?*const std.atomic.Value(bool)) anyerror!ChunkSummary = null,
    saved_source_epoch: ?*const fn (ctx: *anyopaque) u64 = null,

    pub fn generateHeightmapOnly(self: LODGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
        self.generate_heightmap_only(self.ptr, data, region_x, region_z, lod_level, stop_flag);
    }

    pub fn maybeRecenterCache(self: LODGenerator, player_x: i32, player_z: i32) bool {
        return self.maybe_recenter_cache(self.ptr, player_x, player_z);
    }
};
