const rhi_pkg = @import("root.zig");
const RHI = rhi_pkg.RHI;
const IRenderSettings = @import("engine-core").interfaces.IRenderSettings;
pub const RenderSettingsAdapter = struct {
    rhi: *RHI,

    pub fn init(rhi: *RHI) RenderSettingsAdapter {
        return .{ .rhi = rhi };
    }

    pub fn interface(self: *RenderSettingsAdapter) IRenderSettings {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = IRenderSettings.VTable{
        .setWireframe = setWireframe,
        .setVSync = setVSync,
        .setTexturesEnabled = setTexturesEnabled,
        .setAnisotropicFiltering = setAnisotropicFiltering,
        .setFXAA = setFXAA,
        .setBloom = setBloom,
        .setBloomIntensity = setBloomIntensity,
        .setTAABlendFactor = setTAABlendFactor,
        .setTAAVelocityRejection = setTAAVelocityRejection,
        .setVignetteEnabled = setVignetteEnabled,
        .setVignetteIntensity = setVignetteIntensity,
        .setFilmGrainEnabled = setFilmGrainEnabled,
        .setFilmGrainIntensity = setFilmGrainIntensity,
        .setVolumetricDensity = setVolumetricDensity,
        .setDebugShadowView = setDebugShadowView,
        .setShadowDebugChannel = setShadowDebugChannel,
        .setShadowResolution = setShadowResolution,
        .setMSAA = setMSAA,
        .setDynamicResolution = setDynamicResolution,
    };

    fn setWireframe(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setWireframe(enabled);
    }

    fn setVSync(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVSync(enabled);
    }

    fn setTexturesEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTexturesEnabled(enabled);
    }

    fn setAnisotropicFiltering(ptr: *anyopaque, level: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setAnisotropicFiltering(level);
    }

    fn setFXAA(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFXAA(enabled);
    }

    fn setBloom(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setBloom(enabled);
    }

    fn setBloomIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setBloomIntensity(intensity);
    }

    fn setTAABlendFactor(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTAABlendFactor(value);
    }

    fn setTAAVelocityRejection(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTAAVelocityRejection(value);
    }

    fn setVignetteEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVignetteEnabled(enabled);
    }

    fn setVignetteIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVignetteIntensity(intensity);
    }

    fn setFilmGrainEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFilmGrainEnabled(enabled);
    }

    fn setFilmGrainIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFilmGrainIntensity(intensity);
    }

    fn setVolumetricDensity(ptr: *anyopaque, density: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVolumetricDensity(density);
    }

    fn setDebugShadowView(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setDebugShadowView(enabled);
    }

    fn setShadowDebugChannel(ptr: *anyopaque, channel: u32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setShadowDebugChannel(channel);
    }

    fn setDynamicResolution(ptr: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setDynamicResolution(enabled, min_scale, max_scale, target_fps);
    }

    fn setShadowResolution(ptr: *anyopaque, resolution: u32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setShadowResolution(resolution);
    }

    fn setMSAA(ptr: *anyopaque, samples: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setMSAA(samples);
    }
};
