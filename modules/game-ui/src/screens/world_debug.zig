const DebugFeature = @import("engine-ui").DebugFeature;
const RenderSystem = @import("engine-graphics").RenderSystem;
const rhi_pkg = @import("engine-rhi");
const settings_data = @import("game-core").settings.data;
const GameSession = @import("game-core").GameSession;
const ChunkInspectorOverlay = @import("engine-ui").ChunkInspectorOverlay;
const WorldContext = @import("../screen.zig").WorldContext;

pub const ScreenDebugState = struct {
    session: *GameSession,
    last_debug_toggle_time: *f32,
    chunk_inspector_overlay: *ChunkInspectorOverlay,
};

pub fn collectStates(screen: ScreenDebugState, ctx: WorldContext, render_system: *RenderSystem) [DebugFeature.count]bool {
    var states: [DebugFeature.count]bool = @splat(false);
    states[@intFromEnum(DebugFeature.wireframe)] = ctx.settings.wireframe_enabled;
    states[@intFromEnum(DebugFeature.textures)] = ctx.settings.textures_enabled;
    states[@intFromEnum(DebugFeature.vsync)] = ctx.settings.vsync;
    states[@intFromEnum(DebugFeature.fps_counter)] = screen.session.debug_show_fps;
    states[@intFromEnum(DebugFeature.block_info)] = screen.session.debug_show_block_info;
    states[@intFromEnum(DebugFeature.shadow_sandbox)] = ctx.settings.shadow_sandbox_enabled;
    states[@intFromEnum(DebugFeature.shadow_beauty)] = ctx.settings.shadow_beauty_enabled;
    states[@intFromEnum(DebugFeature.shadow_probe)] = ctx.settings.shadow_probe_enabled;
    states[@intFromEnum(DebugFeature.shadow_debug)] = ctx.settings.debug_shadows_active;
    states[@intFromEnum(DebugFeature.shadow_cascade_index)] = ctx.settings.debug_shadow_cascade_index;
    states[@intFromEnum(DebugFeature.shadow_caster_coverage)] = ctx.settings.debug_shadow_caster_coverage;
    states[@intFromEnum(DebugFeature.shadow_seam_diag)] = ctx.settings.debug_shadow_seam_diag;
    states[@intFromEnum(DebugFeature.direct_key_debug)] = ctx.settings.debug_direct_key_active;
    states[@intFromEnum(DebugFeature.sky_fill_debug)] = ctx.settings.debug_sky_fill_active;
    states[@intFromEnum(DebugFeature.block_light_debug)] = ctx.settings.debug_block_light_active;
    states[@intFromEnum(DebugFeature.outdoor_factor_debug)] = ctx.settings.debug_outdoor_factor_active;
    states[@intFromEnum(DebugFeature.gpass_render)] = !render_system.getDisableGPassDraw();
    states[@intFromEnum(DebugFeature.ssao)] = !render_system.getDisableSSAO();
    states[@intFromEnum(DebugFeature.fog)] = screen.session.atmosphere.fog_enabled;
    states[@intFromEnum(DebugFeature.clouds)] = render_system.getCloudsEnabled();
    states[@intFromEnum(DebugFeature.lpv_overlay)] = ctx.settings.debug_lpv_overlay_active;
    states[@intFromEnum(DebugFeature.frustum_debug)] = ctx.settings.debug_frustum_active;
    states[@intFromEnum(DebugFeature.occlusion_debug)] = ctx.settings.debug_occlusion_active;
    states[@intFromEnum(DebugFeature.creative_mode)] = screen.session.creative_mode;
    states[@intFromEnum(DebugFeature.time_pause)] = screen.session.atmosphere.time.time_scale == 0.0;
    states[@intFromEnum(DebugFeature.chunk_inspector)] = screen.chunk_inspector_overlay.enabled;
    return states;
}

pub fn applyToggle(screen: ScreenDebugState, feature: DebugFeature, ctx: WorldContext, render_system: *RenderSystem, rhi: *rhi_pkg.RHI, now: f32) void {
    screen.last_debug_toggle_time.* = now;
    const options = rhi.options();
    switch (feature) {
        .wireframe => {
            ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
            options.setWireframe(ctx.settings.wireframe_enabled);
        },
        .textures => {
            ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
            options.setTexturesEnabled(ctx.settings.textures_enabled);
        },
        .vsync => {
            ctx.settings.vsync = !ctx.settings.vsync;
            options.setVSync(ctx.settings.vsync);
        },
        .fps_counter => screen.session.debug_show_fps = !screen.session.debug_show_fps,
        .block_info => screen.session.debug_show_block_info = !screen.session.debug_show_block_info,
        .shadow_sandbox => {
            ctx.settings.shadow_sandbox_enabled = !ctx.settings.shadow_sandbox_enabled;
            if (!ctx.settings.shadow_sandbox_enabled) {
                ctx.settings.shadow_beauty_enabled = false;
                ctx.settings.shadow_probe_enabled = false;
                settings_data.clearTerrainDebugViews(ctx.settings);
                options.setDebugShadowView(false);
                options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
            }
        },
        .shadow_beauty => {
            ctx.settings.shadow_beauty_enabled = !ctx.settings.shadow_beauty_enabled;
            if (ctx.settings.shadow_beauty_enabled and !render_system.getDisableShadowDraw()) ctx.settings.shadow_sandbox_enabled = true;
        },
        .shadow_probe => {
            ctx.settings.shadow_probe_enabled = !ctx.settings.shadow_probe_enabled;
            if (ctx.settings.shadow_probe_enabled and !render_system.getDisableShadowDraw()) ctx.settings.shadow_sandbox_enabled = true;
        },
        .shadow_debug, .shadow_cascade_index, .shadow_caster_coverage, .shadow_seam_diag => applyShadowDebugToggle(feature, ctx, render_system, rhi),
        .direct_key_debug, .sky_fill_debug, .block_light_debug, .outdoor_factor_debug => applyTerrainDebugToggle(feature, ctx, rhi),
        .timing_overlay => {},
        .gpass_render => render_system.setDisableGPassDraw(!render_system.getDisableGPassDraw()),
        .ssao => render_system.setDisableSSAO(!render_system.getDisableSSAO()),
        .fog => screen.session.atmosphere.fog_enabled = !screen.session.atmosphere.fog_enabled,
        .clouds => {
            ctx.settings.clouds_enabled = !ctx.settings.clouds_enabled;
            render_system.setCloudsEnabled(ctx.settings.clouds_enabled);
        },
        .lpv_overlay => ctx.settings.debug_lpv_overlay_active = !ctx.settings.debug_lpv_overlay_active,
        .frustum_debug => ctx.settings.debug_frustum_active = !ctx.settings.debug_frustum_active,
        .occlusion_debug => ctx.settings.debug_occlusion_active = !ctx.settings.debug_occlusion_active,
        .creative_mode => {
            screen.session.creative_mode = !screen.session.creative_mode;
            screen.session.player.setCreativeMode(screen.session.creative_mode);
        },
        .time_pause => screen.session.atmosphere.time.time_scale = if (screen.session.atmosphere.time.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0),
        .chunk_inspector => screen.chunk_inspector_overlay.toggle(),
    }
}

fn applyShadowDebugToggle(feature: DebugFeature, ctx: WorldContext, render_system: *RenderSystem, rhi: *rhi_pkg.RHI) void {
    const options = rhi.options();
    const enable = switch (feature) {
        .shadow_debug => !ctx.settings.debug_shadows_active,
        .shadow_cascade_index => !ctx.settings.debug_shadow_cascade_index,
        .shadow_caster_coverage => !ctx.settings.debug_shadow_caster_coverage,
        .shadow_seam_diag => !ctx.settings.debug_shadow_seam_diag,
        else => unreachable,
    };
    if (enable and !render_system.getDisableShadowDraw()) ctx.settings.shadow_sandbox_enabled = true;
    settings_data.clearTerrainDebugViews(ctx.settings);
    switch (feature) {
        .shadow_debug => ctx.settings.debug_shadows_active = enable,
        .shadow_cascade_index => ctx.settings.debug_shadow_cascade_index = enable,
        .shadow_caster_coverage => ctx.settings.debug_shadow_caster_coverage = enable,
        .shadow_seam_diag => ctx.settings.debug_shadow_seam_diag = enable,
        else => unreachable,
    }
    options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
    options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
}

fn applyTerrainDebugToggle(feature: DebugFeature, ctx: WorldContext, rhi: *rhi_pkg.RHI) void {
    const options = rhi.options();
    const enable = switch (feature) {
        .direct_key_debug => !ctx.settings.debug_direct_key_active,
        .sky_fill_debug => !ctx.settings.debug_sky_fill_active,
        .block_light_debug => !ctx.settings.debug_block_light_active,
        .outdoor_factor_debug => !ctx.settings.debug_outdoor_factor_active,
        else => unreachable,
    };
    settings_data.clearTerrainDebugViews(ctx.settings);
    switch (feature) {
        .direct_key_debug => ctx.settings.debug_direct_key_active = enable,
        .sky_fill_debug => ctx.settings.debug_sky_fill_active = enable,
        .block_light_debug => ctx.settings.debug_block_light_active = enable,
        .outdoor_factor_debug => ctx.settings.debug_outdoor_factor_active = enable,
        else => unreachable,
    }
    options.setDebugShadowView(settings_data.anyTerrainDebugActive(ctx.settings));
    options.setShadowDebugChannel(resolveShadowDebugChannel(ctx.settings));
}

fn resolveShadowDebugChannel(settings: *const settings_data.Settings) u32 {
    return @intFromEnum(settings_data.resolveShadowDebugChannel(settings));
}
