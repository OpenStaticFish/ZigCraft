const std = @import("std");
const c = @import("../../c.zig").c;
const log = @import("log.zig");

pub const WindowManager = struct {
    window: *c.SDL_Window,
    is_vulkan: bool = true,

    pub fn init(allocator: std.mem.Allocator, use_vulkan: bool, width: u32, height: u32) !WindowManager {
        _ = allocator;
        _ = use_vulkan;
        if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) {
            std.debug.print("SDL Init Failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitializationFailed;
        }

        const window_flags: u32 = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_VULKAN;

        const window = c.SDL_CreateWindow(
            "ZigCraft",
            @intCast(width),
            @intCast(height),
            @intCast(window_flags),
        );
        if (window == null) {
            log.log.err("Window Creation Failed: {s}", .{c.SDL_GetError()});
            return error.WindowCreationFailed;
        }
        log.log.info("Window created at {}x{}", .{ width, height });

        return WindowManager{
            .window = window.?,
        };
    }

    /// Resize the window to a new resolution
    pub fn setSize(self: *WindowManager, width: u32, height: u32) void {
        // Check if window is maximized or fullscreen - resize won't work in those states
        const flags = c.SDL_GetWindowFlags(self.window);
        if ((flags & c.SDL_WINDOW_MAXIMIZED) != 0) {
            log.log.info("Restoring maximized window before resize", .{});
            _ = c.SDL_RestoreWindow(self.window);
            _ = c.SDL_SyncWindow(self.window);
        }
        if ((flags & c.SDL_WINDOW_FULLSCREEN) != 0) {
            log.log.info("Exiting fullscreen before resize", .{});
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_SyncWindow(self.window);
        }

        if (c.SDL_SetWindowSize(self.window, @intCast(width), @intCast(height)) == false) {
            log.log.warn("SDL_SetWindowSize failed: {s}", .{c.SDL_GetError()});
            return;
        }
        // On Wayland, window resize is asynchronous. SDL_SyncWindow blocks until complete.
        if (c.SDL_SyncWindow(self.window) == false) {
            log.log.warn("SDL_SyncWindow failed: {s}", .{c.SDL_GetError()});
        }
        log.log.info("Window resized to {}x{}", .{ width, height });
    }

    pub fn deinit(self: *WindowManager) void {
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
