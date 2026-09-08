//! The engine-ecs self-import is the same module as this direct root.
comptime {
    _ = @import("components.zig");
    _ = @import("ecs_tests.zig");
    _ = @import("entity.zig");
    _ = @import("manager.zig");
    _ = @import("storage.zig");
    _ = @import("systems/physics.zig");
    _ = @import("systems/render.zig");
}
