//! The engine-input self-import is the same module as this direct root.
comptime {
    _ = @import("input.zig");
    _ = @import("input_tests.zig");
    _ = @import("interfaces.zig");
}
