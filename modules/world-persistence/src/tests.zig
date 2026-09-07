//! Executable persistence and canonical-source regression root.
test {
    _ = @import("summary_store.zig");
    _ = @import("save_manager.zig");
    _ = @import("region_file.zig");
    _ = @import("chunk_serializer.zig");
}
