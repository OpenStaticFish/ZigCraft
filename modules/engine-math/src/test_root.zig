//! File-relative discovery only; named imports do not register module tests.
comptime {
    _ = @import("aabb.zig");
    _ = @import("frustum.zig");
    _ = @import("frustum_tests.zig");
    _ = @import("mat4.zig");
    _ = @import("mat4_tests.zig");
    _ = @import("ray.zig");
    _ = @import("ray_fuzz_tests.zig");
    _ = @import("utils.zig");
    _ = @import("utils_tests.zig");
    _ = @import("vec3.zig");
    _ = @import("voxel.zig");
    _ = @import("voxel_tests.zig");
}
