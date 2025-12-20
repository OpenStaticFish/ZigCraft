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
const Key = @import("engine/core/interfaces.zig").Key;
const log = @import("engine/core/log.zig");
const TextureAtlas = @import("engine/graphics/texture_atlas.zig").TextureAtlas;

// World imports
const World = @import("world/world.zig").World;
const worldToChunk = @import("world/chunk.zig").worldToChunk;

// C imports
const c = @import("c.zig").c;

// Textured terrain shaders
const vertex_shader_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\layout (location = 1) in vec3 aColor;
    \\layout (location = 2) in vec3 aNormal;
    \\layout (location = 3) in vec2 aTexCoord;
    \\layout (location = 4) in float aTileID;
    \\out vec3 vColor;
    \\out vec3 vNormal;
    \\out vec2 vTexCoord;
    \\flat out int vTileID;
    \\uniform mat4 transform;
    \\void main() {
    \\    gl_Position = transform * vec4(aPos, 1.0);
    \\    vColor = aColor;
    \\    vNormal = aNormal;
    \\    vTexCoord = aTexCoord;
    \\    vTileID = int(aTileID);
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\in vec3 vColor;
    \\in vec3 vNormal;
    \\in vec2 vTexCoord;
    \\flat in int vTileID;
    \\out vec4 FragColor;
    \\uniform sampler2D uTexture;
    \\uniform bool uUseTexture;
    \\void main() {
    \\    vec3 lightDir = normalize(vec3(0.5, 1.0, 0.3));
    \\    float diff = max(dot(vNormal, lightDir), 0.0) * 0.4 + 0.6;
    \\    
    \\    vec3 color;
    \\    if (uUseTexture) {
    \\        // Tiled atlas sampling
    \\        vec2 atlasSize = vec2(16.0, 16.0); // 16x16 tiles
    \\        vec2 tileSize = 1.0 / atlasSize;
    \\        vec2 tilePos = vec2(mod(float(vTileID), atlasSize.x), floor(float(vTileID) / atlasSize.x));
    \\        
    \\        // Apply fract to vTexCoord for greedy tiling, then inset to prevent bleeding
    \\        vec2 tiledUV = fract(vTexCoord);
    \\        // Clamp tiledUV slightly to avoid edge bleeding
    \\        tiledUV = clamp(tiledUV, 0.001, 0.999);
    \\        
    \\        vec2 uv = (tilePos + tiledUV) * tileSize;
    \\        vec4 texColor = texture(uTexture, uv);
    \\        if (texColor.a < 0.1) discard;
    \\        color = texColor.rgb * vColor * diff;
    \\    } else {
    \\        color = vColor * diff;
    \\    }
    \\    FragColor = vec4(color, 1.0);
    \\}
;

const AppState = enum {
    home,
    singleplayer,
    world,
    paused,
    settings,
};

const Settings = struct {
    render_distance: i32 = 15,
    mouse_sensitivity: f32 = 50.0,
    vsync: bool = true,
    fov: f32 = 45.0,
    textures_enabled: bool = true,
};

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
    input.window_width = 1280;
    input.window_height = 720;

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

    // 8. Create Texture Atlas
    var atlas = TextureAtlas.init(allocator);
    defer atlas.deinit();

    // 9. Create UI System for menus/FPS display
    var ui = try UISystem.init(1280, 720);
    defer ui.deinit();

    // 10. Menu + world state
    var app_state: AppState = .home;
    var last_state: AppState = .home; // For "Back" button in settings
    var settings = Settings{};
    var seed_input = std.ArrayList(u8).empty;
    defer seed_input.deinit(allocator);
    var seed_focused = false;

    var world: ?*World = null;
    defer if (world) |active_world| active_world.deinit();

    // Initial viewport
    renderer.setViewport(1280, 720);

    log.log.info("=== Zig Voxel Engine ===", .{});
    log.log.info("Controls: WASD=Move, Space/Shift=Up/Down, Tab=Mouse, F=Wireframe, T=Textures, V=VSync, Esc=Quit", .{});

    // 11. Main Loop
    // Sync initial settings
    setVSync(settings.vsync);

    while (!input.should_quit) {
        // Update time
        time.update();

        // Process input
        input.beginFrame();
        input.pollEvents();

        // Handle window resize
        renderer.setViewport(input.window_width, input.window_height);
        ui.resize(input.window_width, input.window_height);

        const screen_w: f32 = @floatFromInt(input.window_width);
        const screen_h: f32 = @floatFromInt(input.window_height);
        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = input.isMouseButtonPressed(.left);

        // Global Escape Handling
        if (input.isKeyPressed(.escape)) {
            switch (app_state) {
                .home => input.should_quit = true,
                .singleplayer => {
                    app_state = .home;
                    seed_focused = false;
                },
                .settings => app_state = last_state,
                .world => {
                    app_state = .paused;
                    input.setMouseCapture(window, false);
                },
                .paused => {
                    app_state = .world;
                    input.setMouseCapture(window, true);
                },
            }
        }

        const in_world = app_state == .world;
        const in_pause = app_state == .paused;

        if (in_world or in_pause) {
            // Toggle mouse capture with Tab (only in world)
            if (in_world and input.isKeyPressed(.tab)) {
                input.setMouseCapture(window, !input.mouse_captured);
            }

            // Toggle wireframe with F
            if (input.isKeyPressed(.f)) {
                renderer.toggleWireframe();
            }

            // Toggle textures with T
            if (input.isKeyPressed(.t)) {
                settings.textures_enabled = !settings.textures_enabled;
                log.log.info("Textures: {}", .{settings.textures_enabled});
            }

            // Toggle VSync with V
            if (input.isKeyPressed(.v)) {
                settings.vsync = !settings.vsync;
                setVSync(settings.vsync);
            }

            // Update camera only if in world
            if (in_world) {
                camera.move_speed = settings.mouse_sensitivity;
                camera.update(&input, time.delta_time);
            }

            if (world) |active_world| {
                // Update world (load chunks around player)
                active_world.render_distance = settings.render_distance;
                try active_world.update(camera.position);
            } else {
                app_state = .home;
            }
        } else {
            if (input.mouse_captured) {
                input.setMouseCapture(window, false);
            }
        }

        renderer.setClearColor(if (in_world or in_pause) Vec3.init(0.5, 0.7, 1.0) else Vec3.init(0.07, 0.08, 0.1));
        renderer.beginFrame();

        if (in_world or in_pause) {
            if (world) |active_world| {
                // Calculate matrices
                const aspect = screen_w / screen_h;
                // TODO: Update camera FOV with settings.fov
                const view_proj = camera.getViewProjectionMatrix(aspect);

                // Bind texture atlas and set uniforms
                shader.use();
                atlas.bind(0);
                shader.setInt("uTexture", 0);
                shader.setBool("uUseTexture", settings.textures_enabled);

                active_world.render(&shader, view_proj);

                // Render UI (FPS counter)
                ui.begin();
                ui.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                drawNumber(&ui, @intFromFloat(time.fps), 15, 15, Color.white);

                // Streaming HUD
                const stats = active_world.getStats();
                const rs = active_world.getRenderStats();
                const player_chunk = worldToChunk(@intFromFloat(camera.position.x), @intFromFloat(camera.position.z));
                const hud_y: f32 = 50.0;
                ui.drawRect(.{ .x = 10, .y = hud_y, .width = 220, .height = 130 }, Color.rgba(0, 0, 0, 0.6));

                drawText(&ui, "POS:", 15, hud_y + 5, 1.5, Color.white);
                drawNumber(&ui, player_chunk.chunk_x, 120, hud_y + 5, Color.white);
                drawNumber(&ui, player_chunk.chunk_z, 170, hud_y + 5, Color.white);

                drawText(&ui, "CHUNKS:", 15, hud_y + 25, 1.5, Color.white);
                drawNumber(&ui, @intCast(stats.chunks_loaded), 140, hud_y + 25, Color.white);

                drawText(&ui, "VISIBLE:", 15, hud_y + 45, 1.5, Color.white);
                drawNumber(&ui, @intCast(rs.chunks_rendered), 140, hud_y + 45, Color.white);

                drawText(&ui, "QUEUED GEN:", 15, hud_y + 65, 1.5, Color.white);
                drawNumber(&ui, @intCast(stats.gen_queue), 140, hud_y + 65, Color.white);

                drawText(&ui, "QUEUED MESH:", 15, hud_y + 85, 1.5, Color.white);
                drawNumber(&ui, @intCast(stats.mesh_queue), 140, hud_y + 85, Color.white);

                drawText(&ui, "PENDING UP:", 15, hud_y + 105, 1.5, Color.white);
                drawNumber(&ui, @intCast(stats.upload_queue), 140, hud_y + 105, Color.white);

                if (in_pause) {
                    // Darken background
                    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));

                    const pause_w: f32 = 300.0;
                    const pause_h: f32 = 48.0;
                    const pause_x: f32 = (screen_w - pause_w) * 0.5;
                    var pause_y: f32 = screen_h * 0.35;

                    drawTextCentered(&ui, "PAUSED", screen_w * 0.5, pause_y - 60.0, 3.0, Color.white);

                    if (drawButton(&ui, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .world;
                        input.setMouseCapture(window, true);
                    }
                    pause_y += pause_h + 16.0;

                    if (drawButton(&ui, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                        last_state = .paused;
                        app_state = .settings;
                    }
                    pause_y += pause_h + 16.0;

                    if (drawButton(&ui, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .home;
                        if (world) |w| {
                            w.deinit();
                            world = null;
                        }
                    }
                }

                ui.end();
            }
        } else {
            ui.begin();

            switch (app_state) {
                .home => {
                    const title_scale: f32 = 4.0;
                    drawTextCentered(&ui, "ZIG VOXEL ENGINE", screen_w * 0.5, screen_h * 0.16, title_scale, Color.rgba(0.95, 0.96, 0.98, 1.0));

                    const button_w: f32 = @min(screen_w * 0.5, 360.0);
                    const button_h: f32 = 48.0;
                    const button_x: f32 = (screen_w - button_w) * 0.5;
                    var button_y: f32 = screen_h * 0.4;

                    if (drawButton(&ui, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "SINGLEPLAYER", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .singleplayer;
                        seed_focused = true;
                    }
                    button_y += button_h + 14.0;

                    if (drawButton(&ui, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "SETTINGS", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                        last_state = .home;
                        app_state = .settings;
                    }
                    button_y += button_h + 14.0;

                    if (drawButton(&ui, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "QUIT", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                        input.should_quit = true;
                    }
                },
                .settings => {
                    const panel_w: f32 = @min(screen_w * 0.7, 600.0);
                    const panel_h: f32 = 400.0;
                    const panel_x: f32 = (screen_w - panel_w) * 0.5;
                    const panel_y: f32 = (screen_h - panel_h) * 0.5;

                    ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.12, 0.14, 0.18, 0.95));
                    ui.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);

                    drawTextCentered(&ui, "SETTINGS", screen_w * 0.5, panel_y + 20.0, 2.8, Color.white);

                    var setting_y: f32 = panel_y + 80.0;
                    const label_x: f32 = panel_x + 40.0;
                    const value_x: f32 = panel_x + panel_w - 200.0;

                    // Render Distance
                    drawText(&ui, "RENDER DISTANCE", label_x, setting_y, 2.0, Color.white);
                    drawNumber(&ui, @intCast(settings.render_distance), value_x + 60.0, setting_y, Color.white);
                    if (drawButton(&ui, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.render_distance > 1) settings.render_distance -= 1;
                    }
                    if (drawButton(&ui, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.render_distance < 32) settings.render_distance += 1;
                    }
                    setting_y += 50.0;

                    // Mouse Sensitivity
                    drawText(&ui, "SENSITIVITY", label_x, setting_y, 2.0, Color.white);
                    drawNumber(&ui, @intFromFloat(settings.mouse_sensitivity), value_x + 60.0, setting_y, Color.white);
                    if (drawButton(&ui, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
                    }
                    if (drawButton(&ui, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
                    }
                    setting_y += 50.0;

                    // FOV
                    drawText(&ui, "FOV", label_x, setting_y, 2.0, Color.white);
                    drawNumber(&ui, @intFromFloat(settings.fov), value_x + 60.0, setting_y, Color.white);
                    if (drawButton(&ui, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.fov > 30.0) settings.fov -= 5.0;
                    }
                    if (drawButton(&ui, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.fov < 120.0) settings.fov += 5.0;
                    }
                    setting_y += 50.0;

                    // VSync
                    drawText(&ui, "VSYNC", label_x, setting_y, 2.0, Color.white);
                    if (drawButton(&ui, .{ .x = value_x, .y = setting_y - 5.0, .width = 130.0, .height = 30.0 }, if (settings.vsync) "ENABLED" else "DISABLED", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        settings.vsync = !settings.vsync;
                        setVSync(settings.vsync);
                    }
                    setting_y += 50.0;

                    // Back Button
                    if (drawButton(&ui, .{ .x = panel_x + (panel_w - 120.0) * 0.5, .y = panel_y + panel_h - 60.0, .width = 120.0, .height = 40.0 }, "BACK", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = last_state;
                    }
                },
                .singleplayer => {
                    const panel_w: f32 = @min(screen_w * 0.7, 520.0);
                    const panel_h: f32 = 260.0;
                    const panel_x: f32 = (screen_w - panel_w) * 0.5;
                    const panel_y: f32 = screen_h * 0.24;

                    ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.12, 0.14, 0.18, 0.92));
                    ui.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);

                    drawTextCentered(&ui, "CREATE WORLD", screen_w * 0.5, panel_y + 18.0, 2.8, Color.rgba(0.92, 0.94, 0.97, 1.0));

                    const label_y: f32 = panel_y + 78.0;
                    drawText(&ui, "SEED", panel_x + 24.0, label_y, 2.0, Color.rgba(0.72, 0.78, 0.86, 1.0));

                    const input_h: f32 = 42.0;
                    const input_y: f32 = label_y + 22.0;
                    const random_w: f32 = 120.0;
                    const input_w: f32 = panel_w - 24.0 - random_w - 12.0 - 24.0;
                    const input_x: f32 = panel_x + 24.0;
                    const random_x: f32 = input_x + input_w + 12.0;

                    const seed_rect = Rect{ .x = input_x, .y = input_y, .width = input_w, .height = input_h };
                    const random_rect = Rect{ .x = random_x, .y = input_y, .width = random_w, .height = input_h };

                    if (mouse_clicked) {
                        seed_focused = seed_rect.contains(mouse_x, mouse_y);
                    }

                    const caret_on = @as(u32, @intFromFloat(time.elapsed * 2.0)) % 2 == 0;
                    drawTextInput(&ui, seed_rect, seed_input.items, "LEAVE BLANK FOR RANDOM", 2.0, seed_focused, caret_on);

                    if (drawButton(&ui, random_rect, "RANDOM", 1.8, mouse_x, mouse_y, mouse_clicked)) {
                        const generated = randomSeedValue();
                        try setSeedInput(&seed_input, allocator, generated);
                        seed_focused = true;
                    }

                    if (seed_focused) {
                        try handleSeedTyping(&seed_input, allocator, &input, 32);
                    }

                    const button_y: f32 = panel_y + panel_h - 64.0;
                    const half_w: f32 = (panel_w - 24.0 - 12.0 - 24.0) / 2.0;
                    const back_rect = Rect{ .x = panel_x + 24.0, .y = button_y, .width = half_w, .height = 40.0 };
                    const create_rect = Rect{ .x = panel_x + 24.0 + half_w + 12.0, .y = button_y, .width = half_w, .height = 40.0 };

                    if (drawButton(&ui, back_rect, "BACK", 1.9, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .home;
                        seed_focused = false;
                    }

                    const create_clicked = drawButton(&ui, create_rect, "CREATE", 1.9, mouse_x, mouse_y, mouse_clicked);
                    const create_pressed = input.isKeyPressed(.enter);

                    if (create_clicked or create_pressed) {
                        const seed_value = try resolveSeed(&seed_input, allocator);
                        if (world) |active_world| {
                            active_world.deinit();
                            world = null;
                        }
                        world = try World.init(allocator, 2, seed_value);
                        app_state = .world;
                        seed_focused = false;
                        camera = Camera.init(.{
                            .position = Vec3.init(8, 100, 8),
                            .pitch = -0.3,
                            .move_speed = 50.0,
                        });
                        log.log.info("World seed: {}", .{seed_value});
                    }
                },
                .world, .paused => {},
            }

            ui.end();
        }

        // Swap buffers
        _ = c.SDL_GL_SwapWindow(window);

        if (in_world) {
            if (world) |active_world| {
                if (time.frame_count % 120 == 0) {
                    const stats = active_world.getStats();
                    const render_stats = active_world.getRenderStats();
                    std.debug.print("FPS: {d:.1} | Chunks: {}/{} (culled: {}) | Vertices: {} | Pos: ({d:.1}, {d:.1}, {d:.1})\n", .{
                        time.fps,
                        render_stats.chunks_rendered,
                        stats.chunks_loaded,
                        render_stats.chunks_culled,
                        render_stats.vertices_rendered,
                        camera.position.x,
                        camera.position.y,
                        camera.position.z,
                    });
                }
            }
        }
    }
}

// Simple digit drawing using rectangles (7-segment style)
fn drawNumber(ui: *UISystem, num: i32, x: f32, y: f32, color: Color) void {
    var buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{num}) catch return;
    drawText(ui, text, x, y, 2.0, color);
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

const font_letters = [_][7]u8{
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // A
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }, // B
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }, // C
    .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }, // D
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }, // E
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }, // F
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10011, 0b10001, 0b01110 }, // G
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // H
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 }, // I
    .{ 0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b10001, 0b01110 }, // J
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }, // K
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }, // L
    .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001 }, // M
    .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }, // N
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // O
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }, // P
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }, // Q
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }, // R
    .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 }, // S
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // T
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // U
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 }, // V
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 }, // W
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 }, // X
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 }, // Y
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }, // Z
};

const font_digits = [_][7]u8{
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // 0
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 1
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 }, // 2
    .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 }, // 3
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, // 4
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, // 5
    .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, // 6
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 7
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, // 8
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 }, // 9
};

fn glyphForChar(ch: u8) [7]u8 {
    if (ch >= 'A' and ch <= 'Z') {
        return font_letters[ch - 'A'];
    }
    if (ch >= '0' and ch <= '9') {
        return font_digits[ch - '0'];
    }
    return switch (ch) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        '-' => .{ 0, 0, 0, 0b01110, 0, 0, 0 },
        ':' => .{ 0, 0b00100, 0b00100, 0, 0b00100, 0b00100, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 0b00100, 0b00100 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

fn drawGlyph(ui: *UISystem, glyph: [7]u8, x: f32, y: f32, scale: f32, color: Color) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        const row_bits = glyph[row];
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const shift: u3 = @intCast(4 - col);
            const mask: u8 = @as(u8, 1) << shift;
            if ((row_bits & mask) != 0) {
                ui.drawRect(.{
                    .x = x + @as(f32, @floatFromInt(col)) * scale,
                    .y = y + @as(f32, @floatFromInt(row)) * scale,
                    .width = scale,
                    .height = scale,
                }, color);
            }
        }
    }
}

fn drawText(ui: *UISystem, text: []const u8, x: f32, y: f32, scale: f32, color: Color) void {
    var cursor_x = x;
    for (text) |raw| {
        var ch = raw;
        if (ch >= 'a' and ch <= 'z') {
            ch = std.ascii.toUpper(ch);
        }
        drawGlyph(ui, glyphForChar(ch), cursor_x, y, scale, color);
        cursor_x += (5.0 + 1.0) * scale;
    }
}

fn measureTextWidth(text: []const u8, scale: f32) f32 {
    if (text.len == 0) return 0;
    return @as(f32, @floatFromInt(text.len)) * (5.0 + 1.0) * scale - scale;
}

fn drawTextCentered(ui: *UISystem, text: []const u8, center_x: f32, y: f32, scale: f32, color: Color) void {
    const width = measureTextWidth(text, scale);
    drawText(ui, text, center_x - width * 0.5, y, scale, color);
}

fn drawButton(ui: *UISystem, rect: Rect, label: []const u8, scale: f32, mouse_x: f32, mouse_y: f32, clicked: bool) bool {
    const hovered = rect.contains(mouse_x, mouse_y);
    const fill = if (hovered) Color.rgba(0.2, 0.26, 0.36, 0.95) else Color.rgba(0.13, 0.17, 0.24, 0.92);
    const border = if (hovered) Color.rgba(0.55, 0.7, 0.9, 1.0) else Color.rgba(0.29, 0.35, 0.45, 1.0);

    ui.drawRect(rect, fill);
    ui.drawRectOutline(rect, border, 2.0);

    const text_y = rect.y + (rect.height - 7.0 * scale) * 0.5;
    drawTextCentered(ui, label, rect.x + rect.width * 0.5, text_y, scale, Color.rgba(0.95, 0.96, 0.98, 1.0));

    return hovered and clicked;
}

fn drawTextInput(ui: *UISystem, rect: Rect, text: []const u8, placeholder: []const u8, scale: f32, focused: bool, caret_on: bool) void {
    const background = Color.rgba(0.07, 0.09, 0.13, 0.95);
    const border = if (focused) Color.rgba(0.5, 0.75, 0.95, 1.0) else Color.rgba(0.25, 0.3, 0.38, 1.0);

    ui.drawRect(rect, background);
    ui.drawRectOutline(rect, border, 2.0);

    const padding: f32 = 8.0;
    const text_y = rect.y + (rect.height - 7.0 * scale) * 0.5;
    if (text.len > 0) {
        drawText(ui, text, rect.x + padding, text_y, scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
    } else {
        drawText(ui, placeholder, rect.x + padding, text_y, scale, Color.rgba(0.5, 0.56, 0.65, 1.0));
    }

    if (focused and caret_on) {
        const caret_x = rect.x + padding + measureTextWidth(text, scale);
        ui.drawRect(.{
            .x = caret_x,
            .y = rect.y + 8.0,
            .width = 2.0,
            .height = rect.height - 16.0,
        }, Color.rgba(0.9, 0.95, 1.0, 1.0));
    }
}

fn handleSeedTyping(seed_input: *std.ArrayList(u8), allocator: std.mem.Allocator, input: *const Input, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (seed_input.items.len > 0) {
            _ = seed_input.pop();
        }
    }

    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);

    const letters = [_]Key{
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
        .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
    };

    inline for (letters) |key| {
        if (input.isKeyPressed(key) and seed_input.items.len < max_len) {
            var ch: u8 = @intCast(@intFromEnum(key));
            if (shift) {
                ch = std.ascii.toUpper(ch);
            }
            try seed_input.append(allocator, ch);
        }
    }

    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| {
        if (input.isKeyPressed(key) and seed_input.items.len < max_len) {
            const ch: u8 = @intCast(@intFromEnum(key));
            try seed_input.append(allocator, ch);
        }
    }

    if (input.isKeyPressed(.space) and seed_input.items.len < max_len) {
        try seed_input.append(allocator, ' ');
    }
}

fn randomSeedValue() u64 {
    const ticks: u64 = @intCast(c.SDL_GetTicks());
    const perf: u64 = @intCast(c.SDL_GetPerformanceCounter());
    var seed = perf ^ (ticks << 32);
    seed ^= seed >> 33;
    seed *%= 0xff51afd7ed558ccd;
    seed ^= seed >> 33;
    seed *%= 0xc4ceb9fe1a85ec53;
    seed ^= seed >> 33;
    return seed;
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 1099511628211;
    }
    return hash;
}

fn seedFromText(text: []const u8) u64 {
    var all_digits = true;
    for (text) |ch| {
        if (ch < '0' or ch > '9') {
            all_digits = false;
            break;
        }
    }

    if (all_digits) {
        return std.fmt.parseUnsigned(u64, text, 10) catch fnv1a64(text);
    }
    return fnv1a64(text);
}

fn resolveSeed(seed_input: *std.ArrayList(u8), allocator: std.mem.Allocator) !u64 {
    const trimmed = std.mem.trim(u8, seed_input.items, " \t");
    if (trimmed.len == 0) {
        const generated = randomSeedValue();
        try setSeedInput(seed_input, allocator, generated);
        return generated;
    }
    return seedFromText(trimmed);
}

fn setSeedInput(seed_input: *std.ArrayList(u8), allocator: std.mem.Allocator, seed_value: u64) !void {
    var buffer: [32]u8 = undefined;
    const written = try std.fmt.bufPrint(&buffer, "{d}", .{seed_value});
    seed_input.clearRetainingCapacity();
    try seed_input.appendSlice(allocator, written);
}
