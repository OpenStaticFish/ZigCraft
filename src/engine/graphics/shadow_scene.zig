const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const IShadowScene = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        renderShadowPass: *const fn (ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3) void,
    };

    pub fn renderShadowPass(self: IShadowScene, light_space_matrix: Mat4, camera_pos: Vec3) void {
        self.vtable.renderShadowPass(self.ptr, light_space_matrix, camera_pos);
    }
};
