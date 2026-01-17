const std = @import("std");
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Input = @import("../engine/input/input.zig").Input;
const InputMapper = @import("input_mapper.zig").InputMapper;
const Time = @import("../engine/core/time.zig").Time;
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const ResourcePackManager = @import("../engine/graphics/resource_pack.zig").ResourcePackManager;
const RHI = @import("../engine/graphics/rhi.zig").RHI;
const Settings = @import("state.zig").Settings;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const RenderGraph = @import("../engine/graphics/render_graph.zig").RenderGraph;
const AtmosphereSystem = @import("../engine/graphics/atmosphere_system.zig").AtmosphereSystem;
const MaterialSystem = @import("../engine/graphics/material_system.zig").MaterialSystem;
const Texture = @import("../engine/graphics/texture.zig").Texture;
const AudioSystem = @import("../engine/audio/system.zig").AudioSystem;
const rhi_pkg = @import("../engine/graphics/rhi.zig");

pub const EngineContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    rhi: *RHI,
    resource_pack_manager: *ResourcePackManager,
    atlas: *TextureAtlas,
    render_graph: *RenderGraph,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    audio_system: *AudioSystem,
    env_map_ptr: ?*?Texture,
    shader: rhi_pkg.ShaderHandle,

    settings: *Settings,
    input: *Input,
    input_mapper: *InputMapper,
    time: *Time,

    screen_manager: *ScreenManager,
    safe_render_mode: bool,
    skip_world_update: bool,
    skip_world_render: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,

    /// Saves all persistent application settings.
    /// Screens should call this when settings are modified, typically on a 'Back' action.
    pub fn saveSettings(self: EngineContext) void {
        self.settings.save(self.allocator);
        @import("input_settings.zig").InputSettings.saveFromMapper(self.allocator, self.input_mapper.*) catch |err| {
            @import("../engine/core/log.zig").log.err("Failed to save input settings: {}", .{err});
        };
    }
};

pub const IScreen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        update: ?*const fn (ptr: *anyopaque, dt: f32) anyerror!void = null,
        draw: ?*const fn (ptr: *anyopaque, ui: *UISystem) anyerror!void = null,
        onEnter: ?*const fn (ptr: *anyopaque) void = null,
        onExit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn deinit(self: IScreen) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn update(self: IScreen, dt: f32) !void {
        if (self.vtable.update) |update_fn| {
            try update_fn(self.ptr, dt);
        }
    }

    pub fn draw(self: IScreen, ui: *UISystem) !void {
        if (self.vtable.draw) |draw_fn| {
            try draw_fn(self.ptr, ui);
        }
    }

    pub fn onEnter(self: IScreen) void {
        if (self.vtable.onEnter) |onEnter_fn| {
            onEnter_fn(self.ptr);
        }
    }

    pub fn onExit(self: IScreen) void {
        if (self.vtable.onExit) |onExit_fn| {
            onExit_fn(self.ptr);
        }
    }
};

pub const ScreenManager = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(IScreen),
    next_screen: ?union(enum) {
        push: IScreen,
        pop: void,
        replace: IScreen,
    } = null,

    pub fn init(allocator: std.mem.Allocator) ScreenManager {
        return .{
            .allocator = allocator,
            .stack = .empty,
        };
    }

    pub fn deinit(self: *ScreenManager) void {
        while (self.stack.items.len > 0) {
            const screen = self.stack.pop().?;
            screen.onExit();
            screen.deinit();
        }
        if (self.next_screen) |next| {
            switch (next) {
                .push => |s| s.deinit(),
                .replace => |s| s.deinit(),
                .pop => {},
            }
        }
        self.stack.deinit(self.allocator);
    }

    pub fn pushScreen(self: *ScreenManager, screen: IScreen) void {
        self.next_screen = .{ .push = screen };
    }

    pub fn popScreen(self: *ScreenManager) void {
        self.next_screen = .pop;
    }

    pub fn setScreen(self: *ScreenManager, screen: IScreen) void {
        self.next_screen = .{ .replace = screen };
    }

    pub fn update(self: *ScreenManager, dt: f32) !void {
        while (self.next_screen != null) {
            const next = self.next_screen.?;
            self.next_screen = null;
            switch (next) {
                .push => |screen| {
                    if (self.stack.items.len > 0) {
                        self.stack.items[self.stack.items.len - 1].onExit();
                    }
                    try self.stack.append(self.allocator, screen);
                    screen.onEnter();
                },
                .pop => {
                    if (self.stack.items.len > 0) {
                        const screen = self.stack.pop().?;
                        screen.onExit();
                        screen.deinit();
                        if (self.stack.items.len > 0) {
                            self.stack.items[self.stack.items.len - 1].onEnter();
                        }
                    }
                },
                .replace => |screen| {
                    while (self.stack.items.len > 0) {
                        const s = self.stack.pop().?;
                        s.onExit();
                        s.deinit();
                    }
                    try self.stack.append(self.allocator, screen);
                    screen.onEnter();
                },
            }
        }

        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].update(dt);
        }
    }

    pub fn draw(self: *ScreenManager, ui: *UISystem) !void {
        // We might want to draw multiple screens if they are transparent
        // For now, just draw the top one
        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].draw(ui);
        }
    }

    /// Draws the screen directly below the given screen pointer in the stack.
    /// Used by overlay screens (pause, settings) to render their parent screen as background.
    pub fn drawParentScreen(self: *ScreenManager, current_ptr: *anyopaque, ui: *UISystem) !void {
        // Find this screen's index in the stack
        for (self.stack.items, 0..) |screen, i| {
            if (screen.ptr == current_ptr) {
                // Found ourselves, draw the screen below us if it exists
                if (i > 0) {
                    try self.stack.items[i - 1].draw(ui);
                }
                return;
            }
        }
    }
};

pub fn makeScreen(comptime T: type, ptr: *T) IScreen {
    return .{
        .ptr = ptr,
        .vtable = &T.vtable,
    };
}
