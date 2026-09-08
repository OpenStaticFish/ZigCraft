comptime {
    _ = @import("chunk_queue_coordinator.zig");
    _ = @import("gpu_acceleration_coordinator.zig");
    _ = @import("gpu_mesher.zig");
    _ = @import("lighting_engine.zig");
    _ = @import("lpv_grid_builder.zig");
    _ = @import("world.zig");
    _ = @import("world_diagnostics.zig");
    _ = @import("world_diagnostics_tests.zig");
    _ = @import("world_facade_tests.zig");
    _ = @import("world_mutation.zig");
    _ = @import("world_renderer.zig");
    _ = @import("world_streamer.zig");
}
