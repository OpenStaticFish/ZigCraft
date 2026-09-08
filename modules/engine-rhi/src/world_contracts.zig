const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const ShadowConfig = @import("rhi_types.zig").ShadowConfig;

pub const GpuLight = extern struct {
    pos_radius: [4]f32,
    color: [4]f32,
};

pub const IShadowScene = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        renderShadowPass: *const fn (ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void,
    };

    pub fn renderShadowPass(self: IShadowScene, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
        self.vtable.renderShadowPass(self.ptr, light_space_matrix, camera_pos, caster_min, caster_max, shadow_config);
    }
};

pub const IWorldRenderView = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        renderOpaque: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        renderFluid: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3) void,
        /// False proves no resident renderer-owned fluid can be drawn. Unknown
        /// geometry providers must return true, independent of camera visibility.
        hasDrawableFluid: *const fn (ptr: *anyopaque) bool,
    };

    pub fn render(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.render(self.ptr, view_proj, camera_pos);
    }

    pub fn renderOpaque(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.renderOpaque(self.ptr, view_proj, camera_pos);
    }

    pub fn renderFluid(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3) void {
        self.vtable.renderFluid(self.ptr, view_proj, camera_pos);
    }

    pub fn hasDrawableFluid(self: IWorldRenderView) bool {
        return self.vtable.hasDrawableFluid(self.ptr);
    }
};

pub const ILPVWorld = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        collectLights: *const fn (ptr: *anyopaque, origin: Vec3, grid_size: u32, cell_size: f32, out: []GpuLight) usize,
        buildOcclusionGrid: *const fn (ptr: *anyopaque, origin: Vec3, grid_size: u32, cell_size: f32, out: []u32) void,
    };

    pub fn collectLights(self: ILPVWorld, origin: Vec3, grid_size: u32, cell_size: f32, out: []GpuLight) usize {
        return self.vtable.collectLights(self.ptr, origin, grid_size, cell_size, out);
    }

    pub fn buildOcclusionGrid(self: ILPVWorld, origin: Vec3, grid_size: u32, cell_size: f32, out: []u32) void {
        self.vtable.buildOcclusionGrid(self.ptr, origin, grid_size, cell_size, out);
    }
};
