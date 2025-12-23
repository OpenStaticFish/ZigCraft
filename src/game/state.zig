pub const AppState = enum {
    home,
    singleplayer,
    world,
    paused,
    settings,
};

pub const Settings = struct {
    render_distance: i32 = 15,
    mouse_sensitivity: f32 = 50.0,
    vsync: bool = true,
    fov: f32 = 45.0,
    textures_enabled: bool = true,
    wireframe_enabled: bool = false,
    shadow_resolution: u32 = 2048,
    shadow_distance: f32 = 250.0,
};
