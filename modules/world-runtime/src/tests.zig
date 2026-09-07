//! Stable-source capture and startup persistence tests, without graphics setup.
test {
    _ = @import("world_streamer.zig");
    _ = @import("world.zig");
    _ = @import("world_mutation.zig");
    _ = @import("chunk_queue_coordinator.zig");
}
