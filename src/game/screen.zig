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
const rhi_pkg = @import("../engine/graphics/rhi.zig");

pub const EngineContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    rhi: RHI,
    resource_pack_manager: *ResourcePackManager,
    atlas: *TextureAtlas,
    render_graph: *RenderGraph,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    env_map: *?Texture,
    shader: rhi_pkg.ShaderHandle,

    settings: *Settings,
    input: *Input,
    input_mapper: *InputMapper,
    time: *Time,

    screen_manager: *ScreenManager,
};

pub const IScreen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        update: *const fn (ptr: *anyopaque, dt: f32) anyerror!void,
        draw: *const fn (ptr: *anyopaque, ui: *UISystem) anyerror!void,
        onEnter: *const fn (ptr: *anyopaque) void,
        onExit: *const fn (ptr: *anyopaque) void,
    };

    pub fn deinit(self: IScreen) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn update(self: IScreen, dt: f32) !void {
        try self.vtable.update(self.ptr, dt);
    }

    pub fn draw(self: IScreen, ui: *UISystem) !void {
        try self.vtable.draw(self.ptr, ui);
    }

    pub fn onEnter(self: IScreen) void {
        self.vtable.onEnter(self.ptr);
    }

    pub fn onExit(self: IScreen) void {
        self.vtable.onExit(self.ptr);
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
        if (self.next_screen) |next| {
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
            self.next_screen = null;
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
};
