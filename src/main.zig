const std = @import("std");

// Engine imports
const Vec3 = @import("engine/math/vec3.zig").Vec3;
const Mat4 = @import("engine/math/mat4.zig").Mat4;
const Camera = @import("engine/graphics/camera.zig").Camera;
const Shader = @import("engine/graphics/shader.zig").Shader;
const Renderer = @import("engine/graphics/renderer.zig").Renderer;
const setVSync = @import("engine/graphics/renderer.zig").setVSync;
const Input = @import("engine/input/input.zig").Input;
const Time = @import("engine/core/time.zig").Time;
const UISystem = @import("engine/ui/ui_system.zig").UISystem;
const Color = @import("engine/ui/ui_system.zig").Color;
const Rect = @import("engine/core/interfaces.zig").Rect;
const log = @import("engine/core/log.zig");

// World imports
const World = @import("world/world.zig").World;

// C imports
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("SDL3/SDL.h");
    @cInclude("GL/glew.h");
    @cInclude("SDL3/SDL_opengl.h");
});

// Shaders
const vertex_shader_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\layout (location = 1) in vec3 aColor;
    \\layout (location = 2) in vec3 aNormal;
    \\out vec3 vColor;
    \\out vec3 vNormal;
    \\uniform mat4 transform;
    \\void main() {
    \\    gl_Position = transform * vec4(aPos, 1.0);
    \\    vColor = aColor;
    \\    vNormal = aNormal;
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\in vec3 vColor;
    \\in vec3 vNormal;
    \\out vec4 FragColor;
    \\void main() {
    \\    // Simple directional lighting
    \\    vec3 lightDir = normalize(vec3(0.5, 1.0, 0.3));
    \\    float diff = max(dot(vNormal, lightDir), 0.0) * 0.3 + 0.7;
    \\    FragColor = vec4(vColor * diff, 1.0);
    \\}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize SDL
    if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) {
        std.debug.print("SDL Init Failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    // 2. Configure OpenGL Attributes
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);

    // 3. Create Window
    const window = c.SDL_CreateWindow(
        "Zig Voxel Engine",
        1280,
        720,
        c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE,
    );
    if (window == null) return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    // 4. Create GL Context
    const gl_context = c.SDL_GL_CreateContext(window);
    if (gl_context == null) return error.GLContextCreationFailed;
    defer _ = c.SDL_GL_DestroyContext(gl_context);
    _ = c.SDL_GL_MakeCurrent(window, gl_context);

    // 5. Initialize GLEW
    c.glewExperimental = c.GL_TRUE;
    if (c.glewInit() != c.GLEW_OK) {
        return error.GLEWInitFailed;
    }

    // 6. Initialize Engine Systems
    log.log.info("Initializing engine systems...", .{});

    var input = Input.init(allocator);
    defer input.deinit();

    var time = Time.init();
    var renderer = Renderer.init();

    // Enable VSync
    setVSync(true);

    // Start camera high above ground level, looking down
    var camera = Camera.init(.{
        .position = Vec3.init(8, 100, 8),
        .pitch = -0.3, // Look slightly down
        .move_speed = 50.0, // Fast movement for testing
    });

    // 7. Create Shader
    var shader = try Shader.initSimple(vertex_shader_src, fragment_shader_src);
    defer shader.deinit();

    // 8. Create World
    const seed: u64 = 12345; // World seed for terrain generation
    var world = World.init(allocator, 2, seed); // 2 chunk render distance (5x5 = 25 chunks)
    defer world.deinit();

    // 9. Create UI System for FPS display
    var ui = try UISystem.init(1280, 720);
    defer ui.deinit();

    // Initial viewport
    renderer.setViewport(1280, 720);

    log.log.info("=== Zig Voxel Engine ===", .{});
    log.log.info("Controls: WASD=Move, Space/Shift=Up/Down, Tab=Mouse, F=Wireframe, V=VSync, Esc=Quit", .{});

    // 10. Main Loop
    var vsync_enabled = true;
    while (!input.should_quit) {
        // Update time
        time.update();

        // Process input
        input.beginFrame();
        input.pollEvents();

        // Handle escape to quit
        if (input.isKeyPressed(.escape)) {
            input.should_quit = true;
        }

        // Toggle mouse capture with Tab
        if (input.isKeyPressed(.tab)) {
            const captured = !input.mouse_captured;
            input.mouse_captured = captured;
            _ = c.SDL_SetWindowRelativeMouseMode(window, captured);
        }

        // Toggle wireframe with F
        if (input.isKeyPressed(.f)) {
            renderer.toggleWireframe();
        }

        // Toggle VSync with V
        if (input.isKeyPressed(.v)) {
            vsync_enabled = !vsync_enabled;
            setVSync(vsync_enabled);
        }

        // Update camera
        camera.update(&input, time.delta_time);

        // Update world (load chunks around player)
        try world.update(camera.position);

        // Debug: print stats on first few frames
        if (time.frame_count < 3) {
            const stats = world.getStats();
            std.debug.print("Frame {}: Chunks={}, Vertices={}\n", .{
                time.frame_count, stats.chunks_loaded, stats.total_vertices,
            });
        }

        // Handle window resize
        renderer.setViewport(input.window_width, input.window_height);
        ui.resize(input.window_width, input.window_height);

        // Calculate matrices
        const aspect = @as(f32, @floatFromInt(input.window_width)) / @as(f32, @floatFromInt(input.window_height));
        const view_proj = camera.getViewProjectionMatrix(aspect);

        // Render 3D world
        renderer.beginFrame();
        world.render(&shader, view_proj);

        // Render UI (FPS counter)
        ui.begin();

        // Draw FPS background
        ui.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));

        // Draw FPS digits
        drawNumber(&ui, @intFromFloat(time.fps), 15, 15, Color.white);

        ui.end();

        // Swap buffers
        _ = c.SDL_GL_SwapWindow(window);

        // Print stats occasionally
        if (time.frame_count % 120 == 0) {
            const stats = world.getStats();
            std.debug.print("FPS: {d:.1} | Chunks: {} | Vertices: {} | Pos: ({d:.1}, {d:.1}, {d:.1})\n", .{
                time.fps,
                stats.chunks_loaded,
                stats.total_vertices,
                camera.position.x,
                camera.position.y,
                camera.position.z,
            });
        }
    }
}

// Simple digit drawing using rectangles (7-segment style)
fn drawNumber(ui: *UISystem, num: u32, x: f32, y: f32, color: Color) void {
    var n = num;
    var digit_x = x + 50; // Start from right

    if (n == 0) {
        drawDigit(ui, 0, digit_x, y, color);
        return;
    }

    while (n > 0) : (digit_x -= 15) {
        const digit: u4 = @intCast(n % 10);
        drawDigit(ui, digit, digit_x, y, color);
        n /= 10;
    }
}

fn drawDigit(ui: *UISystem, digit: u4, x: f32, y: f32, color: Color) void {
    const w: f32 = 10;
    const h: f32 = 16;
    const t: f32 = 2; // thickness

    // 7-segment display: top, top-left, top-right, middle, bottom-left, bottom-right, bottom
    const segments: [10][7]bool = .{
        .{ true, true, true, false, true, true, true }, // 0
        .{ false, false, true, false, false, true, false }, // 1
        .{ true, false, true, true, true, false, true }, // 2
        .{ true, false, true, true, false, true, true }, // 3
        .{ false, true, true, true, false, true, false }, // 4
        .{ true, true, false, true, false, true, true }, // 5
        .{ true, true, false, true, true, true, true }, // 6
        .{ true, false, true, false, false, true, false }, // 7
        .{ true, true, true, true, true, true, true }, // 8
        .{ true, true, true, true, false, true, true }, // 9
    };

    const seg = segments[digit];

    if (seg[0]) ui.drawRect(.{ .x = x, .y = y, .width = w, .height = t }, color); // top
    if (seg[1]) ui.drawRect(.{ .x = x, .y = y, .width = t, .height = h / 2 }, color); // top-left
    if (seg[2]) ui.drawRect(.{ .x = x + w - t, .y = y, .width = t, .height = h / 2 }, color); // top-right
    if (seg[3]) ui.drawRect(.{ .x = x, .y = y + h / 2 - t / 2, .width = w, .height = t }, color); // middle
    if (seg[4]) ui.drawRect(.{ .x = x, .y = y + h / 2, .width = t, .height = h / 2 }, color); // bottom-left
    if (seg[5]) ui.drawRect(.{ .x = x + w - t, .y = y + h / 2, .width = t, .height = h / 2 }, color); // bottom-right
    if (seg[6]) ui.drawRect(.{ .x = x, .y = y + h - t, .width = w, .height = t }, color); // bottom
}
