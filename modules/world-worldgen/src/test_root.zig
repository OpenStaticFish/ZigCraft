//! Generator implementations have their own direct roots; do not rediscover
//! their tests through this registry's named facade imports.
comptime {
    _ = @import("fuzz_tests.zig");
    _ = @import("registry.zig");
}
