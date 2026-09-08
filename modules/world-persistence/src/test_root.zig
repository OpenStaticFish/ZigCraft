//! build.zig supplies level_fixture_v0_1 as an anonymous embedFile import on
//! this module. Reusing the production module retains that fixture contract.
comptime {
    _ = @import("chunk_serializer.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("level_data.zig");
    _ = @import("region_file.zig");
    _ = @import("save_manager.zig");
}
