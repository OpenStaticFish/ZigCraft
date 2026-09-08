//! Core engine interfaces following SOLID principles.
//! These abstractions allow for dependency inversion and extensibility.

/// Interface for render settings (wireframe, vsync, bloom, etc.).
/// Decouples screens and settings logic from the concrete RHI backend.
pub const IRenderSettings = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setWireframe: *const fn (ptr: *anyopaque, enabled: bool) void,
        setVSync: *const fn (ptr: *anyopaque, enabled: bool) void,
        setTexturesEnabled: *const fn (ptr: *anyopaque, enabled: bool) void,
        setAnisotropicFiltering: *const fn (ptr: *anyopaque, level: u8) void,
        setFXAA: *const fn (ptr: *anyopaque, enabled: bool) void,
        setBloom: *const fn (ptr: *anyopaque, enabled: bool) void,
        setBloomIntensity: *const fn (ptr: *anyopaque, intensity: f32) void,
        setTAABlendFactor: *const fn (ptr: *anyopaque, value: f32) void,
        setTAAVelocityRejection: *const fn (ptr: *anyopaque, value: f32) void,
        setVignetteEnabled: *const fn (ptr: *anyopaque, enabled: bool) void,
        setVignetteIntensity: *const fn (ptr: *anyopaque, intensity: f32) void,
        setFilmGrainEnabled: *const fn (ptr: *anyopaque, enabled: bool) void,
        setFilmGrainIntensity: *const fn (ptr: *anyopaque, intensity: f32) void,
        setVolumetricDensity: *const fn (ptr: *anyopaque, density: f32) void,
        setDebugShadowView: *const fn (ptr: *anyopaque, enabled: bool) void,
        setShadowDebugChannel: *const fn (ptr: *anyopaque, channel: u32) void,
        setShadowResolution: *const fn (ptr: *anyopaque, resolution: u32) void,
        setMSAA: *const fn (ptr: *anyopaque, samples: u8) void,
        setDynamicResolution: *const fn (ptr: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void,
    };

    /// Enables or disables wireframe rendering in the active render settings backend.
    /// The setting affects subsequent frames and is typically driven by debug UI or hotkeys.
    pub fn setWireframe(self: IRenderSettings, enabled: bool) void {
        self.vtable.setWireframe(self.ptr, enabled);
    }

    /// Enables or disables vertical synchronization for presentation.
    /// Backends may apply this on the next swapchain or presentation configuration update.
    pub fn setVSync(self: IRenderSettings, enabled: bool) void {
        self.vtable.setVSync(self.ptr, enabled);
    }

    /// Enables or disables material texture sampling in terrain and world rendering.
    /// Disabling textures leaves geometry active while forcing fallback material colors.
    pub fn setTexturesEnabled(self: IRenderSettings, enabled: bool) void {
        self.vtable.setTexturesEnabled(self.ptr, enabled);
    }

    /// Sets the anisotropic filtering level requested for sampled textures.
    /// The backend clamps unsupported levels to device capabilities.
    pub fn setAnisotropicFiltering(self: IRenderSettings, level: u8) void {
        self.vtable.setAnisotropicFiltering(self.ptr, level);
    }

    /// Enables or disables FXAA post-processing.
    /// The setting affects post-process pass selection for subsequent frames.
    pub fn setFXAA(self: IRenderSettings, enabled: bool) void {
        self.vtable.setFXAA(self.ptr, enabled);
    }

    /// Enables or disables bloom post-processing.
    /// When disabled, bloom extraction and composite work may be skipped by the renderer.
    pub fn setBloom(self: IRenderSettings, enabled: bool) void {
        self.vtable.setBloom(self.ptr, enabled);
    }

    /// Sets bloom strength used by the post-process composite.
    /// Values are backend-defined floats, normally authored by graphics settings UI.
    pub fn setBloomIntensity(self: IRenderSettings, intensity: f32) void {
        self.vtable.setBloomIntensity(self.ptr, intensity);
    }

    /// Sets the temporal anti-aliasing blend factor.
    /// Lower values favor the current frame; higher values retain more history and may increase ghosting.
    pub fn setTAABlendFactor(self: IRenderSettings, value: f32) void {
        self.vtable.setTAABlendFactor(self.ptr, value);
    }

    /// Sets how aggressively TAA rejects history using velocity differences.
    /// Higher values preserve more history; lower values reduce ghosting near fast motion.
    pub fn setTAAVelocityRejection(self: IRenderSettings, value: f32) void {
        self.vtable.setTAAVelocityRejection(self.ptr, value);
    }

    /// Enables or disables vignette post-processing.
    /// The setting affects only post-process composition, not scene lighting.
    pub fn setVignetteEnabled(self: IRenderSettings, enabled: bool) void {
        self.vtable.setVignetteEnabled(self.ptr, enabled);
    }

    /// Sets the vignette darkening strength used during post-processing.
    /// Implementations should clamp out-of-range values to their supported range.
    pub fn setVignetteIntensity(self: IRenderSettings, intensity: f32) void {
        self.vtable.setVignetteIntensity(self.ptr, intensity);
    }

    /// Enables or disables film-grain post-processing.
    /// This does not affect render targets, only final color presentation.
    pub fn setFilmGrainEnabled(self: IRenderSettings, enabled: bool) void {
        self.vtable.setFilmGrainEnabled(self.ptr, enabled);
    }

    /// Sets the film-grain strength used by the post-process pass.
    /// Backends may quantize or clamp this setting to their shader-supported range.
    pub fn setFilmGrainIntensity(self: IRenderSettings, intensity: f32) void {
        self.vtable.setFilmGrainIntensity(self.ptr, intensity);
    }

    /// Sets volumetric effect density for fog/cloud/atmosphere style rendering.
    /// The value is consumed by later frames and may be clamped by the backend.
    pub fn setVolumetricDensity(self: IRenderSettings, density: f32) void {
        self.vtable.setVolumetricDensity(self.ptr, density);
    }

    /// Enables or disables the debug shadow-map visualization path.
    /// Intended for diagnostics; normal gameplay rendering should leave this disabled.
    pub fn setDebugShadowView(self: IRenderSettings, enabled: bool) void {
        self.vtable.setDebugShadowView(self.ptr, enabled);
    }

    /// Selects the terrain/shadow diagnostic channel; zero disables the channel.
    pub fn setShadowDebugChannel(self: IRenderSettings, channel: u32) void {
        self.vtable.setShadowDebugChannel(self.ptr, channel);
    }

    /// Updates the dynamic-resolution enablement, scale range, and frame budget together.
    pub fn setDynamicResolution(self: IRenderSettings, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        self.vtable.setDynamicResolution(self.ptr, enabled, min_scale, max_scale, target_fps);
    }

    /// Sets the requested MSAA sample count.
    /// The backend may recreate render targets or clamp unsupported sample counts.
    pub fn setMSAA(self: IRenderSettings, samples: u8) void {
        self.vtable.setMSAA(self.ptr, samples);
    }

    /// Requests shadow-map recreation at the next render-frame boundary.
    pub fn setShadowResolution(self: IRenderSettings, resolution: u32) void {
        self.vtable.setShadowResolution(self.ptr, resolution);
    }
};

/// Erased screen handle used by navigation interfaces without coupling core to UI types.
pub const ScreenHandle = struct {
    ptr: *anyopaque,
    vtable: *const anyopaque,
};

/// Interface for screen navigation. Concrete screen implementations live at the app layer.
pub const IScreenManager = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        pushScreen: *const fn (ptr: *anyopaque, screen: ScreenHandle) void,
        popScreen: *const fn (ptr: *anyopaque) void,
        setScreen: *const fn (ptr: *anyopaque, screen: ScreenHandle) void,
        drawParentScreen: *const fn (ptr: *anyopaque, current_ptr: *anyopaque, ui: *anyopaque) anyerror!void,
    };

    /// Pushes a screen onto the navigation stack.
    /// Ownership and lifetime of `screen` are defined by the concrete screen manager implementation.
    pub fn pushScreen(self: IScreenManager, screen: ScreenHandle) void {
        self.vtable.pushScreen(self.ptr, screen);
    }

    /// Pops the current screen from the navigation stack.
    /// Implementations decide how to handle an empty or root-only stack.
    pub fn popScreen(self: IScreenManager) void {
        self.vtable.popScreen(self.ptr);
    }

    /// Replaces the active screen with `screen`.
    /// This is used for hard navigation transitions such as leaving a modal flow.
    pub fn setScreen(self: IScreenManager, screen: ScreenHandle) void {
        self.vtable.setScreen(self.ptr, screen);
    }

    /// Draws the parent screen behind the current screen when overlays need backdrop rendering.
    /// Propagates drawing errors from the concrete UI implementation.
    pub fn drawParentScreen(self: IScreenManager, current_ptr: *anyopaque, ui: *anyopaque) !void {
        try self.vtable.drawParentScreen(self.ptr, current_ptr, ui);
    }
};

// ============================================================================
// Common Types
// ============================================================================

pub const InputEvent = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    mouse_motion: MouseMotionEvent,
    mouse_button_down: MouseButtonEvent,
    mouse_button_up: MouseButtonEvent,
    mouse_scroll: MouseScrollEvent,
    window_resize: WindowResizeEvent,
    quit: void,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const MouseMotionEvent = struct {
    x: i32,
    y: i32,
    dx: i32,
    dy: i32,
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    x: i32,
    y: i32,
};

pub const MouseScrollEvent = struct {
    dx: f32,
    dy: f32,
};

pub const WindowResizeEvent = struct {
    width: u32,
    height: u32,
};

pub const MouseButton = enum(u8) {
    left = 1,
    middle = 2,
    right = 3,
    _,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    _padding: u5 = 0,
};

pub const Key = enum(u32) {
    unknown = 0,

    // Letters
    a = 'a',
    b = 'b',
    c = 'c',
    d = 'd',
    e = 'e',
    f = 'f',
    g = 'g',
    h = 'h',
    i = 'i',
    j = 'j',
    k = 'k',
    l = 'l',
    m = 'm',
    n = 'n',
    o = 'o',
    p = 'p',
    q = 'q',
    r = 'r',
    s = 's',
    t = 't',
    u = 'u',
    v = 'v',
    w = 'w',
    x = 'x',
    y = 'y',
    z = 'z',

    // Numbers
    @"0" = '0',
    @"1" = '1',
    @"2" = '2',
    @"3" = '3',
    @"4" = '4',
    @"5" = '5',
    @"6" = '6',
    @"7" = '7',
    @"8" = '8',
    @"9" = '9',

    // Special keys
    space = ' ',
    escape = 27,
    enter = 13,
    tab = 9,
    backspace = 8,
    plus = '=',
    minus = '-',
    kp_plus = 0x40000057,
    kp_minus = 0x40000056,

    // Arrow keys (using SDL scancodes offset)
    up = 0x40000052,
    down = 0x40000051,
    left_arrow = 0x40000050,
    right_arrow = 0x4000004F,

    // Modifiers
    left_shift = 0x400000E1,
    right_shift = 0x400000E5,
    left_ctrl = 0x400000E0,
    right_ctrl = 0x400000E4,

    // Function keys
    f1 = 0x4000003a,
    f2 = 0x4000003b,
    f3 = 0x4000003c,
    f4 = 0x4000003d,
    f5 = 0x4000003e,
    f6 = 0x4000003f,
    f7 = 0x40000040,
    f8 = 0x40000041,
    f9 = 0x40000042,
    f10 = 0x40000043,
    f11 = 0x40000044,
    f12 = 0x40000045,

    _,

    pub fn fromSDL(sdl_key: u32) Key {
        return @enumFromInt(sdl_key);
    }
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};
