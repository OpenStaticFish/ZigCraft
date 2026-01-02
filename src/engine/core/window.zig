const std = @import("std");
const c = @import("../../c.zig").c;
const log = @import("log.zig");

pub const WindowManager = struct {
    window: *c.SDL_Window,
    gl_context: ?c.SDL_GLContext,
    is_vulkan: bool,

    pub fn init(allocator: std.mem.Allocator, use_vulkan: bool, width: u32, height: u32) !WindowManager {
        _ = allocator;
        if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) {
            std.debug.print("SDL Init Failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitializationFailed;
        }

        if (!use_vulkan) {
            _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
            _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
            _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
            _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
        }

        var window_flags: u32 = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (use_vulkan) {
            window_flags |= c.SDL_WINDOW_VULKAN;
        } else {
            window_flags |= c.SDL_WINDOW_OPENGL;
        }

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

        var gl_context: ?c.SDL_GLContext = null;
        if (!use_vulkan) {
            gl_context = c.SDL_GL_CreateContext(window);
            if (gl_context == null) return error.GLContextCreationFailed;
            _ = c.SDL_GL_MakeCurrent(window, gl_context.?);
            c.glewExperimental = c.GL_TRUE;
            if (c.glewInit() != c.GLEW_OK) {
                log.log.err("GLEW Initialization Failed", .{});
                return error.GLEWInitializationFailed;
            }
        }

        return WindowManager{
            .window = window.?,
            .gl_context = gl_context,
            .is_vulkan = use_vulkan,
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
        if (self.gl_context) |ctx| {
            _ = c.SDL_GL_DestroyContext(ctx);
        }
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
