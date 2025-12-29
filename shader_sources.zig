//! OpenGL shader sources for testing and runtime embedding.
//!
//! This module provides compile-time access to all OpenGL shader files
//! for validation tests and runtime use via @embedFile.

pub const terrain_vert = @embedFile("assets/shaders/terrain.vert");
pub const terrain_frag = @embedFile("assets/shaders/terrain.frag");
pub const ui_vert = @embedFile("assets/shaders/ui.vert");
pub const ui_frag = @embedFile("assets/shaders/ui.frag");
pub const ui_tex_vert = @embedFile("assets/shaders/ui_tex.vert");
pub const ui_tex_frag = @embedFile("assets/shaders/ui_tex.frag");
pub const sky_vert = @embedFile("assets/shaders/sky.vert");
pub const sky_frag = @embedFile("assets/shaders/sky.frag");
pub const cloud_vert = @embedFile("assets/shaders/cloud.vert");
pub const cloud_frag = @embedFile("assets/shaders/cloud.frag");
pub const debug_shadow_vert = @embedFile("assets/shaders/debug_shadow.vert");
pub const debug_shadow_frag = @embedFile("assets/shaders/debug_shadow.frag");

pub const all = [_][]const u8{
    terrain_vert,
    terrain_frag,
    ui_vert,
    ui_frag,
    ui_tex_vert,
    ui_tex_frag,
    sky_vert,
    sky_frag,
    cloud_vert,
    cloud_frag,
    debug_shadow_vert,
    debug_shadow_frag,
};
