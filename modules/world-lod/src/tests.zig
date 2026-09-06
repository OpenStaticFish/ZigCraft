//! Dedicated world-lod test root.

test {
    _ = @import("lod_cache.zig");
    _ = @import("lod_manager_internal_tests.zig");
    _ = @import("lod_manager_tests.zig");
    _ = @import("lod_tile.zig");
    _ = @import("lod_compact_pool.zig");
    _ = @import("lod_mesh.zig");
    _ = @import("lod_mesh_tests.zig");
    _ = @import("lod_renderer.zig");
    _ = @import("lod_vertex_pool.zig");
    _ = @import("lod_store.zig");
    _ = @import("lod_streaming_coordinator.zig");
    _ = @import("lod_scheduler.zig");
}
