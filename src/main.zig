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
const Atmosphere = @import("engine/graphics/atmosphere.zig").Atmosphere;
const ShadowMap = @import("engine/graphics/shadows.zig").ShadowMap;
const Clouds = @import("engine/graphics/clouds.zig").Clouds;

// World imports
const World = @import("world/world.zig").World;
const worldToChunk = @import("world/chunk.zig").worldToChunk;
const WorldMap = @import("world/worldgen/world_map.zig").WorldMap;

const RHI = @import("engine/graphics/rhi.zig").RHI;
const rhi_opengl = @import("engine/graphics/rhi_opengl.zig");
const rhi_vulkan = @import("engine/graphics/rhi_vulkan.zig");

// C imports
const c = @import("c.zig").c;

// Textured terrain shaders with fog, dynamic sun lighting and CSM
const vertex_shader_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\layout (location = 1) in vec3 aColor;
    \\layout (location = 2) in vec3 aNormal;
    \\layout (location = 3) in vec2 aTexCoord;
    \\layout (location = 4) in float aTileID;
    \\layout (location = 5) in float aSkyLight;
    \\layout (location = 6) in float aBlockLight;
    \\out vec3 vColor;
    \\flat out vec3 vNormal;
    \\out vec2 vTexCoord;
    \\flat out int vTileID;
    \\out float vDistance;
    \\out float vSkyLight;
    \\out float vBlockLight;
    \\out vec3 vFragPosWorld;
    \\out float vViewDepth;
    \\
    \\uniform mat4 transform; // MVP
    \\uniform mat4 uModel;
    \\
    \\void main() {
    \\    vec4 clipPos = transform * vec4(aPos, 1.0);
    \\    gl_Position = clipPos;
    \\    vColor = aColor;
    \\    vNormal = aNormal;
    \\    vTexCoord = aTexCoord;
    \\    vTileID = int(aTileID);
    \\    vDistance = length(aPos);
    \\    vSkyLight = aSkyLight;
    \\    vBlockLight = aBlockLight;
    \\    
    \\    vFragPosWorld = (uModel * vec4(aPos, 1.0)).xyz;
    \\    vViewDepth = clipPos.w;
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\in vec3 vColor;
    \\flat in vec3 vNormal;
    \\in vec2 vTexCoord;
    \\flat in int vTileID;
    \\in float vDistance;
    \\in float vSkyLight;
    \\in float vBlockLight;
    \\in vec3 vFragPosWorld;
    \\in float vViewDepth;
    \\out vec4 FragColor;
    \\
    \\uniform sampler2D uTexture;
    \\uniform bool uUseTexture;
    \\uniform vec3 uSunDir;
    \\uniform float uSunIntensity;
    \\uniform float uAmbient;
    \\uniform vec3 uFogColor;
    \\uniform float uFogDensity;
    \\uniform bool uFogEnabled;
    \\
    \\// CSM
    \\uniform sampler2D uShadowMap0;
    \\uniform sampler2D uShadowMap1;
    \\uniform sampler2D uShadowMap2;
    \\uniform mat4 uLightSpaceMatrices[3];
    \\uniform float uCascadeSplits[3];
    \\uniform float uShadowTexelSizes[3];
    \\
    \\// Cloud shadows
    \\uniform float uCloudWindOffsetX;
    \\uniform float uCloudWindOffsetZ;
    \\uniform float uCloudScale;
    \\uniform float uCloudCoverage;
    \\uniform float uCloudShadowStrength;
    \\uniform float uCloudHeight;
    \\
    \\// Cloud shadow noise functions
    \\float cloudHash(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\float cloudNoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    float a = cloudHash(i);
    \\    float b = cloudHash(i + vec2(1.0, 0.0));
    \\    float c = cloudHash(i + vec2(0.0, 1.0));
    \\    float d = cloudHash(i + vec2(1.0, 1.0));
    \\    vec2 u = f * f * (3.0 - 2.0 * f);
    \\    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    \\}
    \\
    \\float cloudFbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.5;
    \\    for (int i = 0; i < 4; i++) {
    \\        v += a * cloudNoise(p);
    \\        p *= 2.0;
    \\        a *= 0.5;
    \\    }
    \\    return v;
    \\}
    \\
    \\float getCloudShadow(vec3 worldPos, vec3 sunDir) {
    \\    // Project position along sun direction to cloud plane
    \\    // This creates moving shadows that follow the sun
    \\    vec2 shadowOffset = sunDir.xz * (uCloudHeight - worldPos.y) / max(sunDir.y, 0.1);
    \\    vec2 samplePos = (worldPos.xz + shadowOffset + vec2(uCloudWindOffsetX, uCloudWindOffsetZ)) * uCloudScale;
    \\    
    \\    float n1 = cloudFbm(samplePos * 0.5);
    \\    float n2 = cloudFbm(samplePos * 2.0 + vec2(100.0, 200.0)) * 0.3;
    \\    float cloudValue = n1 * 0.7 + n2;
    \\    
    \\    float threshold = 1.0 - uCloudCoverage;
    \\    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    \\    
    \\    return cloudMask * uCloudShadowStrength;
    \\}
    \\
    \\float calculateShadow(vec3 fragPosWorld, float nDotL, int layer) {
    \\    vec4 fragPosLightSpace = uLightSpaceMatrices[layer] * vec4(fragPosWorld, 1.0);
    \\    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    \\
    \\    // XY [-1,1]->[0,1]. Z is already [0,1] due to glClipControl + Correct Matrix.
    \\    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    \\    
    \\    if (projCoords.z > 1.0 || projCoords.z < 0.0) return 0.0;
    \\    
    \\    float currentDepth = projCoords.z;
    \\    
    \\    // Revert to stable normalized bias, but scaled by layer
    \\    float bias = max(0.002 * (1.0 - nDotL), 0.0005);
    \\    if (layer == 1) bias *= 2.0;
    \\    if (layer == 2) bias *= 4.0;
    \\
    \\    float shadow = 0.0;
    \\    // Use dynamic texel size for PCF
    \\    vec2 texelSize = 1.0 / vec2(textureSize(uShadowMap0, 0));
    \\    
    \\    for(int x = -1; x <= 1; ++x) {
    \\        for(int y = -1; y <= 1; ++y) {
    \\            float pcfDepth;
    \\            if (layer == 0) pcfDepth = texture(uShadowMap0, projCoords.xy + vec2(x, y) * texelSize).r;
    \\            else if (layer == 1) pcfDepth = texture(uShadowMap1, projCoords.xy + vec2(x, y) * texelSize).r;
    \\            else pcfDepth = texture(uShadowMap2, projCoords.xy + vec2(x, y) * texelSize).r;
    \\            
    \\            shadow += currentDepth > pcfDepth + bias ? 1.0 : 0.0;
    \\        }
    \\    }
    \\    shadow /= 9.0;
    \\    return shadow;
    \\}
    \\
    \\void main() {
    \\    float nDotL = max(dot(vNormal, uSunDir), 0.0);
    \\    
    \\    // Select cascade layer using VIEW-SPACE depth (vViewDepth is clipPos.w = linear depth)
    \\    int layer = 2;
    \\    float depth = vViewDepth;
    \\    if (depth < uCascadeSplits[0]) layer = 0;
    \\    else if (depth < uCascadeSplits[1]) layer = 1;
    \\    
    \\    float shadow = calculateShadow(vFragPosWorld, nDotL, layer);
    \\
    \\    // Cascade Blending
    \\    float blendThreshold = 0.9; // Start blending at 90% of cascade range
    \\    if (layer < 2) {
    \\        float splitDist = uCascadeSplits[layer];
    \\        float prevSplit = (layer == 0) ? 0.0 : uCascadeSplits[layer-1];
    \\        float range = splitDist - prevSplit;
    \\        float distInto = depth - prevSplit;
    \\        float normDist = distInto / range;
    \\
    \\        if (normDist > blendThreshold) {
    \\            float blend = (normDist - blendThreshold) / (1.0 - blendThreshold);
    \\            float nextShadow = calculateShadow(vFragPosWorld, nDotL, layer + 1);
    \\            shadow = mix(shadow, nextShadow, blend);
    \\        }
    \\    }
    \\    
    \\    // DEBUG: Visualize cascades if shadows are missing
    \\    // if (layer == 0) FragColor = vec4(1.0, 0.0, 0.0, 1.0);
    \\    // else if (layer == 1) FragColor = vec4(0.0, 1.0, 0.0, 1.0);
    \\    // else FragColor = vec4(0.0, 0.0, 1.0, 1.0);
    \\    // return;
    \\    
    \\    // Cloud shadow (only when sun is up)
    \\    float cloudShadow = 0.0;
    \\    if (uSunIntensity > 0.05 && uSunDir.y > 0.05) {
    \\        cloudShadow = getCloudShadow(vFragPosWorld, uSunDir);
    \\    }
    \\    
    \\    // Combine terrain shadow and cloud shadow
    \\    float totalShadow = min(shadow + cloudShadow, 1.0);
    \\    
    \\    float directLight = nDotL * uSunIntensity * (1.0 - totalShadow);
    \\    float skyLight = vSkyLight * (uAmbient + directLight * 0.8);
    \\    
    \\    float blockLight = vBlockLight;
    \\    float lightLevel = max(skyLight, blockLight);
    \\    
    \\    lightLevel = max(lightLevel, uAmbient * 0.5);
    \\    lightLevel = clamp(lightLevel, 0.0, 1.0);
    \\    
    \\    vec3 color;
    \\    if (uUseTexture) {
    \\        vec2 atlasSize = vec2(16.0, 16.0);
    \\        vec2 tileSize = 1.0 / atlasSize;
    \\        vec2 tilePos = vec2(mod(float(vTileID), atlasSize.x), floor(float(vTileID) / atlasSize.x));
    \\        vec2 tiledUV = fract(vTexCoord);
    \\        tiledUV = clamp(tiledUV, 0.001, 0.999);
    \\        vec2 uv = (tilePos + tiledUV) * tileSize;
    \\        vec4 texColor = texture(uTexture, uv);
    \\        if (texColor.a < 0.1) discard;
    \\        color = texColor.rgb * vColor * lightLevel;
    \\    } else {
    \\        color = vColor * lightLevel;
    \\    }
    \\    
    \\    if (uFogEnabled) {
    \\        float fogFactor = 1.0 - exp(-vDistance * uFogDensity);
    \\        fogFactor = clamp(fogFactor, 0.0, 1.0);
    \\        color = mix(color, uFogColor, fogFactor);
    \\    }
    \\    
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
    shadow_resolution: u32 = 2048,
    shadow_distance: f32 = 250.0,
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
    // Request 24-bit depth buffer (32-bit may not be available on all drivers)
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);

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

    // Check arguments for --backend vulkan
    var use_vulkan = false;
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.skip();
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--backend") and std.mem.eql(u8, args_iter.next() orelse "", "vulkan")) {
            use_vulkan = true;
        }
    }

    var rhi: RHI = undefined;
    if (use_vulkan) {
        log.log.info("Attempting to initialize Vulkan backend...", .{});
        if (rhi_vulkan.createRHI(allocator)) |vulkan_rhi| {
            rhi = vulkan_rhi;
        } else |err| {
            log.log.err("Failed to initialize Vulkan: {}. Falling back to OpenGL.", .{err});
            if (c.glewInit() != c.GLEW_OK) return error.GLEWInitFailed;
            rhi = try rhi_opengl.createRHI(allocator);
            use_vulkan = false;
        }
    } else {
        log.log.info("Initializing OpenGL backend...", .{});
        if (c.glewInit() != c.GLEW_OK) {
            return error.GLEWInitFailed;
        }
        rhi = try rhi_opengl.createRHI(allocator);
    }
    defer rhi.deinit();

    // 6. Initialize Engine Systems
    log.log.info("Initializing engine systems...", .{});

    var input = Input.init(allocator);
    defer input.deinit();
    input.window_width = 1280;
    input.window_height = 720;

    var time = Time.init();
    var renderer: ?Renderer = null;
    if (!use_vulkan) {
        renderer = Renderer.init();
    }

    // Enable VSync
    if (!use_vulkan) {
        setVSync(true);
    }

    // Start camera high above ground level, looking down
    var camera = Camera.init(.{
        .position = Vec3.init(8, 100, 8),
        .pitch = -0.3, // Look slightly down
        .move_speed = 50.0, // Fast movement for testing
    });

    // 7. Create Shader
    var shader: ?Shader = null;
    var debug_shader: ?Shader = null;
    var debug_quad_vao: c.GLuint = 0;
    var debug_quad_vbo: c.GLuint = 0;

    if (!use_vulkan) {
        shader = try Shader.initFromFile(allocator, "assets/shaders/terrain.vert", "assets/shaders/terrain.frag");

        // Debug shader for shadow map
        const debug_vs =
            \\#version 330 core
            \\layout (location = 0) in vec2 aPos;
            \\layout (location = 1) in vec2 aTexCoord;
            \\out vec2 vTexCoord;
            \\void main() {
            \\    gl_Position = vec4(aPos, 0.0, 1.0);
            \\    vTexCoord = aTexCoord;
            \\}
        ;
        const debug_fs =
            \\#version 330 core
            \\out vec4 FragColor;
            \\in vec2 vTexCoord;
            \\uniform sampler2D uDepthMap;
            \\void main() {
            \\    float depth = texture(uDepthMap, vTexCoord).r;
            \\    // Linearize? No, ortho depth is linear.
            \\    FragColor = vec4(vec3(depth), 1.0);
            \\}
        ;
        debug_shader = try Shader.initSimple(debug_vs, debug_fs);

        // Debug Quad
        {
            const quad_vertices = [_]f32{
                // pos, tex
                -1.0, 1.0,  0.0, 1.0,
                -1.0, -1.0, 0.0, 0.0,
                1.0,  -1.0, 1.0, 0.0,

                -1.0, 1.0,  0.0, 1.0,
                1.0,  -1.0, 1.0, 0.0,
                1.0,  1.0,  1.0, 1.0,
            };
            c.glGenVertexArrays().?(1, &debug_quad_vao);
            c.glGenBuffers().?(1, &debug_quad_vbo);
            c.glBindVertexArray().?(debug_quad_vao);
            c.glBindBuffer().?(c.GL_ARRAY_BUFFER, debug_quad_vbo);
            c.glBufferData().?(c.GL_ARRAY_BUFFER, quad_vertices.len * @sizeOf(f32), &quad_vertices, c.GL_STATIC_DRAW);
            c.glEnableVertexAttribArray().?(0);
            c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
            c.glEnableVertexAttribArray().?(1);
            c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        }
    }
    defer if (shader) |*s| s.deinit();
    defer if (debug_shader) |*s| s.deinit();

    // 8. Create Texture Atlas
    var atlas: ?TextureAtlas = null;
    if (!use_vulkan) {
        atlas = TextureAtlas.init(allocator);
    }
    defer if (atlas) |*a| a.deinit();

    // 9. Create UI System for menus/FPS display
    var ui: ?UISystem = null;
    if (!use_vulkan) {
        ui = try UISystem.init(1280, 720);
    }
    defer if (ui) |*u| u.deinit();

    // 10. Create Atmosphere System for day/night cycle
    var atmosphere: ?Atmosphere = null;
    if (!use_vulkan) {
        atmosphere = Atmosphere.init();
    }
    defer if (atmosphere) |*a| a.deinit();

    // 10b. Create Cloud System
    var clouds: ?Clouds = null;
    if (!use_vulkan) {
        clouds = try Clouds.init();
    }
    defer if (clouds) |*cl| cl.deinit();

    var settings = Settings{};

    // 11. Create Shadow Map (CSM with configurable resolution)
    var shadow_map: ?ShadowMap = null;
    if (!use_vulkan) {
        shadow_map = try ShadowMap.init(settings.shadow_resolution);
    }
    defer if (shadow_map) |*sm| sm.deinit();

    // 12. Menu + world state
    var app_state: AppState = .home;
    var last_state: AppState = .home; // For "Back" button in settings
    var debug_shadows = false;
    var debug_cascade_idx: usize = 0;
    var seed_input = std.ArrayList(u8).empty;
    defer seed_input.deinit(allocator);
    var seed_focused = false;

    var world: ?*World = null;
    defer if (world) |active_world| active_world.deinit();

    var world_map: ?WorldMap = null;
    defer if (world_map) |*m| m.deinit();
    var show_map = false;
    var map_needs_update = true;
    var map_zoom: f32 = 4.0;
    var map_target_zoom: f32 = 4.0;
    var map_pos_x: f32 = 0.0;
    var map_pos_z: f32 = 0.0;
    var last_mouse_x: f32 = 0.0;
    var last_mouse_y: f32 = 0.0;

    // Initial viewport
    if (renderer) |*r| r.setViewport(1280, 720);

    log.log.info("=== Zig Voxel Engine ===", .{});
    log.log.info("Controls: WASD=Move, Space/Shift=Up/Down, Tab=Mouse, F=Wireframe, T=Textures, V=VSync, C=Clouds", .{});
    log.log.info("Time: 1=Midnight, 2=Sunrise, 3=Noon, 4=Sunset, N=Freeze/Unfreeze", .{});

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
        if (renderer) |*r| r.setViewport(input.window_width, input.window_height);
        if (ui) |*u| u.resize(input.window_width, input.window_height);

        const screen_w: f32 = @floatFromInt(input.window_width);
        const screen_h: f32 = @floatFromInt(input.window_height);
        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = input.isMouseButtonPressed(.left);

        // Global Escape Handling
        if (input.isKeyPressed(.escape)) {
            if (show_map) {
                show_map = false;
                if (app_state == .world) {
                    input.setMouseCapture(window, true);
                }
            } else {
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
        }

        const in_world = app_state == .world;
        const in_pause = app_state == .paused;

        if (in_world or in_pause) {
            // Toggle mouse capture with Tab (only in world)
            if (in_world and input.isKeyPressed(.tab)) {
                input.setMouseCapture(window, !input.mouse_captured);
            }

            // Toggle clouds with C
            if (input.isKeyPressed(.c)) {
                if (clouds) |*cl| {
                    cl.enabled = !cl.enabled;
                    log.log.info("Clouds: {}", .{cl.enabled});
                }
            }

            // Toggle wireframe with F
            if (input.isKeyPressed(.f)) {
                if (renderer) |*r| r.toggleWireframe();
            }

            // Toggle textures with T
            if (input.isKeyPressed(.t)) {
                settings.textures_enabled = !settings.textures_enabled;
                log.log.info("Textures: {}", .{settings.textures_enabled});
            }

            // Toggle VSync with V
            if (input.isKeyPressed(.v)) {
                settings.vsync = !settings.vsync;
                if (!use_vulkan) setVSync(settings.vsync);
            }

            // Toggle Shadow Debug with U
            if (input.isKeyPressed(.u)) {
                debug_shadows = !debug_shadows;
                log.log.info("Debug Shadows: {}", .{debug_shadows});
            }

            // Toggle World Map with M
            if (input.isKeyPressed(.m)) {
                show_map = !show_map;
                if (show_map) {
                    map_pos_x = camera.position.x;
                    map_pos_z = camera.position.z;
                    map_target_zoom = map_zoom;
                    map_needs_update = true;
                    input.setMouseCapture(window, false);
                } else if (app_state == .world) {
                    input.setMouseCapture(window, true);
                }
            }

            if (show_map) {
                const dt = @min(time.delta_time, 0.033); // Cap dt to prevent feedback loops

                // Smooth Zoom using Scroll Wheel or Keys
                const zoom_kb_speed: f32 = 1.2;
                if (input.isKeyDown(.plus) or input.isKeyDown(.kp_plus)) {
                    map_target_zoom /= @exp(zoom_kb_speed * dt);
                    map_needs_update = true;
                }
                if (input.isKeyDown(.minus) or input.isKeyDown(.kp_minus)) {
                    map_target_zoom *= @exp(zoom_kb_speed * dt);
                    map_needs_update = true;
                }

                if (input.scroll_y != 0) {
                    // Discrete scroll zoom is less prone to feedback
                    map_target_zoom *= @exp(-input.scroll_y * 0.12);
                    map_needs_update = true;
                }

                // Clamp zoom to prevent crashes/instability (0.05 to 128.0 blocks per pixel)
                map_target_zoom = std.math.clamp(map_target_zoom, 0.05, 128.0);

                const old_zoom = map_zoom;
                // Faster lerp for snappier feel
                map_zoom = std.math.lerp(map_zoom, map_target_zoom, 20.0 * dt);
                if (@abs(map_zoom - old_zoom) > 0.001 * map_zoom) map_needs_update = true;

                // Center on player with Space
                if (input.isKeyPressed(.space)) {
                    map_pos_x = camera.position.x;
                    map_pos_z = camera.position.z;
                    map_needs_update = true;
                }

                // Panning logic: Mouse Drag (Stable) or WASD
                const map_size: f32 = @min(screen_w, screen_h) * 0.8;
                const world_to_screen_ratio = if (world_map) |m| @as(f32, @floatFromInt(m.width)) / map_size else 1.0;

                if (input.isMouseButtonPressed(.left)) {
                    last_mouse_x = mouse_x;
                    last_mouse_y = mouse_y;
                }

                if (input.isMouseButtonDown(.left)) {
                    const drag_dx = mouse_x - last_mouse_x;
                    const drag_dz = mouse_y - last_mouse_y;
                    if (@abs(drag_dx) > 0.1 or @abs(drag_dz) > 0.1) {
                        map_pos_x -= drag_dx * map_zoom * world_to_screen_ratio;
                        map_pos_z -= drag_dz * map_zoom * world_to_screen_ratio;
                        map_needs_update = true;
                    }
                    last_mouse_x = mouse_x;
                    last_mouse_y = mouse_y;
                } else {
                    const pan_kb_speed = 800.0 * map_zoom;
                    var dx: f32 = 0;
                    var dz: f32 = 0;
                    if (input.isKeyDown(.w)) dz -= 1;
                    if (input.isKeyDown(.s)) dz += 1;
                    if (input.isKeyDown(.a)) dx -= 1;
                    if (input.isKeyDown(.d)) dx += 1;

                    if (dx != 0 or dz != 0) {
                        map_pos_x += dx * pan_kb_speed * dt;
                        map_pos_z += dz * pan_kb_speed * dt;
                        map_needs_update = true;
                    }
                }
            }

            // Cycle shadow cascades in debug mode with K

            if (debug_shadows and input.isKeyPressed(.k)) {
                debug_cascade_idx = (debug_cascade_idx + 1) % 3;
                log.log.info("Debug Cascade: {}", .{debug_cascade_idx});
            }

            // Time-of-day controls
            // 1-4: Time presets (midnight, sunrise, noon, sunset)
            if (input.isKeyPressed(.@"1")) {
                if (atmosphere) |*a| {
                    a.setTimeOfDay(0.0); // Midnight
                    log.log.info("Time: Midnight", .{});
                }
            }
            if (input.isKeyPressed(.@"2")) {
                if (atmosphere) |*a| {
                    a.setTimeOfDay(0.25); // Sunrise
                    log.log.info("Time: Sunrise", .{});
                }
            }
            if (input.isKeyPressed(.@"3")) {
                if (atmosphere) |*a| {
                    a.setTimeOfDay(0.5); // Noon
                    log.log.info("Time: Noon", .{});
                }
            }
            if (input.isKeyPressed(.@"4")) {
                if (atmosphere) |*a| {
                    a.setTimeOfDay(0.75); // Sunset
                    log.log.info("Time: Sunset", .{});
                }
            }
            // N: Toggle day/night cycle (freeze/unfreeze time)
            if (input.isKeyPressed(.n)) {
                if (atmosphere) |*a| {
                    if (a.time_scale > 0) {
                        a.time_scale = 0;
                        log.log.info("Time: Frozen", .{});
                    } else {
                        a.time_scale = 1.0;
                        log.log.info("Time: Running", .{});
                    }
                }
            }

            // Update systems only if NOT in map or specifically allowed
            if (in_world) {
                if (!show_map) {
                    camera.move_speed = settings.mouse_sensitivity;
                    camera.update(&input, time.delta_time);

                    // Update atmosphere (day/night cycle)
                    if (atmosphere) |*a| a.update(time.delta_time);

                    // Update clouds (wind movement)
                    if (clouds) |*cl| cl.update(time.delta_time);
                }

                if (world) |active_world| {
                    // Update world (load chunks around player) - always keep loading for background?
                    // No, pause loading to save CPU for map gen
                    if (!show_map) {
                        active_world.render_distance = settings.render_distance;
                        try active_world.update(camera.position);
                    }
                } else {
                    app_state = .home;
                }
            }
        } else {
            if (input.mouse_captured) {
                input.setMouseCapture(window, false);
            }
        }

        if (renderer) |*r| {
            r.setClearColor(if (in_world or in_pause) (if (atmosphere) |a| a.fog_color else Vec3.init(0.5, 0.7, 1.0)) else Vec3.init(0.07, 0.08, 0.1));
            r.beginFrame();
        }

        if (in_world or in_pause) {
            if (world) |active_world| {
                // Calculate matrices using origin-centered view for floating origin rendering
                const aspect = screen_w / screen_h;
                // TODO: Update camera FOV with settings.fov
                const view_proj = camera.getViewProjectionMatrixOriginCentered(aspect);

                // --- SHADOW PASS ---
                if (shadow_map) |*sm| {
                    if (atmosphere) |atmo| {
                        // Only render shadows if sun is up or moon is bright enough
                        var light_dir = atmo.sun_dir;
                        if (atmo.sun_intensity < 0.05 and atmo.moon_intensity > 0.05) {
                            light_dir = atmo.moon_dir;
                        }

                        // Only cast shadows if we have some light
                        const has_shadows = atmo.sun_intensity > 0.05 or atmo.moon_intensity > 0.05;

                        if (has_shadows) {
                            // Update cascades (splits and matrices)
                            // Shadow distance from settings
                            sm.update(camera.fov, aspect, 0.1, settings.shadow_distance, light_dir, camera.position, camera.getViewMatrixOriginCentered());

                            // Render each cascade
                            for (0..3) |i| {
                                sm.begin(i);
                                // Render world into shadow map
                                // We use the cascade's light space matrix
                                active_world.renderShadowPass(&sm.shader, sm.light_space_matrices[i], camera.position);
                            }
                            sm.end(input.window_width, input.window_height);
                        }
                    }
                }

                // --- MAIN PASS ---
                if (renderer) |*r| {
                    r.setClearColor(if (in_world or in_pause) (if (atmosphere) |a| a.fog_color else Vec3.init(0.5, 0.7, 1.0)) else Vec3.init(0.07, 0.08, 0.1));
                    r.beginFrame();
                }

                // Render sky first (before terrain, with depth write disabled)
                if (!use_vulkan) {
                    if (atmosphere) |*a| a.renderSky(camera.forward, camera.right, camera.up, aspect, camera.fov);
                }

                if (shader) |*s| {
                    // Bind texture atlas and set uniforms
                    s.use();
                    if (atlas) |*a| a.bind(0);
                    s.setInt("uTexture", 0);
                    s.setBool("uUseTexture", settings.textures_enabled);

                    // Bind CSM textures and uniforms
                    if (shadow_map) |*sm| {
                        for (0..3) |i| {
                            sm.depth_maps[i].bind(@intCast(1 + i));

                            var name_buf: [64]u8 = undefined;

                            const tex_name = std.fmt.bufPrintZ(&name_buf, "uShadowMap{}", .{i}) catch "uShadowMap0";
                            s.setInt(tex_name, @intCast(1 + i));

                            const mat_name = std.fmt.bufPrintZ(&name_buf, "uLightSpaceMatrices[{}]", .{i}) catch unreachable;
                            s.setMat4(mat_name, &sm.light_space_matrices[i].data);

                            const split_name = std.fmt.bufPrintZ(&name_buf, "uCascadeSplits[{}]", .{i}) catch unreachable;
                            s.setFloat(split_name, sm.cascade_splits[i]);

                            const size_name = std.fmt.bufPrintZ(&name_buf, "uShadowTexelSizes[{}]", .{i}) catch unreachable;
                            s.setFloat(size_name, sm.texel_sizes[i]);
                        }
                    }

                    // Set atmosphere/lighting uniforms
                    if (atmosphere) |atmo| {
                        s.setVec3("uSunDir", atmo.sun_dir.x, atmo.sun_dir.y, atmo.sun_dir.z);
                        s.setFloat("uSunIntensity", atmo.sun_intensity);
                        s.setFloat("uAmbient", atmo.ambient_intensity);
                        s.setVec3("uFogColor", atmo.fog_color.x, atmo.fog_color.y, atmo.fog_color.z);
                        s.setFloat("uFogDensity", atmo.fog_density);
                        s.setBool("uFogEnabled", atmo.fog_enabled);
                    } else {
                        // Fallback defaults
                        s.setVec3("uSunDir", 0.5, 0.8, 0.2);
                        s.setFloat("uSunIntensity", 1.0);
                        s.setFloat("uAmbient", 0.2);
                        s.setVec3("uFogColor", 0.5, 0.7, 1.0);
                        s.setFloat("uFogDensity", 0.0);
                        s.setBool("uFogEnabled", false);
                    }

                    // Set cloud shadow uniforms
                    if (clouds) |*cl| {
                        const shadow_params = cl.getCloudShadowParams();
                        s.setFloat("uCloudWindOffsetX", shadow_params.wind_offset_x);
                        s.setFloat("uCloudWindOffsetZ", shadow_params.wind_offset_z);
                        s.setFloat("uCloudScale", shadow_params.cloud_scale);
                        s.setFloat("uCloudCoverage", shadow_params.cloud_coverage);
                        s.setFloat("uCloudShadowStrength", 0.15);
                        s.setFloat("uCloudHeight", shadow_params.cloud_height);
                    }

                    // Pass camera position for floating origin chunk rendering
                    active_world.render(s, view_proj, camera.position);
                }

                // Render clouds (after terrain, with depth test enabled)
                if (clouds) |*cl| {
                    if (atmosphere) |atmo| {
                        cl.render(camera.position, &view_proj.data, atmo.sun_dir, atmo.sun_intensity, atmo.fog_color, atmo.fog_density);
                    }
                }

                if (debug_shadows and debug_shader != null and shadow_map != null) {
                    if (debug_shader) |*ds| {
                        ds.use();
                        c.glActiveTexture().?(c.GL_TEXTURE0);
                        // Visualize selected cascade
                        c.glBindTexture(c.GL_TEXTURE_2D, shadow_map.?.depth_maps[debug_cascade_idx].id);
                        ds.setInt("uDepthMap", 0);

                        c.glBindVertexArray().?(debug_quad_vao);
                        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
                        c.glBindVertexArray().?(0);
                    }
                }

                if (ui) |*u| {
                    u.begin();

                    if (show_map) {
                        if (world_map) |*m| {
                            if (map_needs_update) {
                                try m.update(&active_world.generator, map_pos_x, map_pos_z, map_zoom);
                                map_needs_update = false;
                            }

                            const map_size: f32 = @min(screen_w, screen_h) * 0.8;
                            const map_x = (screen_w - map_size) * 0.5;
                            const map_y = (screen_h - map_size) * 0.5;

                            u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
                            u.drawTexture(m.texture.id, .{ .x = map_x, .y = map_y, .width = map_size, .height = map_size });
                            u.drawRectOutline(.{ .x = map_x, .y = map_y, .width = map_size, .height = map_size }, Color.white, 2.0);

                            drawTextCentered(u, "WORLD MAP", screen_w * 0.5, map_y - 40.0, 3.0, Color.white);
                            drawTextCentered(u, "DRAG TO PAN - SCROLL TO ZOOM - SPACE TO CENTER - M TO CLOSE", screen_w * 0.5, map_y + map_size + 20.0, 1.5, Color.rgba(0.8, 0.8, 0.8, 1.0));

                            // Player position on map
                            const rel_x = (camera.position.x - map_pos_x) / (map_zoom * @as(f32, @floatFromInt(m.width)));
                            const rel_z = (camera.position.z - map_pos_z) / (map_zoom * @as(f32, @floatFromInt(m.height)));

                            const px = map_x + (rel_x + 0.5) * map_size;
                            const pz = map_y + (rel_z + 0.5) * map_size;

                            if (px >= map_x and px <= map_x + map_size and pz >= map_y and pz <= map_y + map_size) {
                                u.drawRect(.{ .x = px - 5, .y = pz - 1, .width = 10, .height = 2 }, Color.red);
                                u.drawRect(.{ .x = px - 1, .y = pz - 5, .width = 2, .height = 10 }, Color.red);
                            }
                        }
                    }

                    u.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                    drawNumber(u, @intFromFloat(time.fps), 15, 15, Color.white);

                    // Streaming HUD
                    const stats = active_world.getStats();
                    const rs = active_world.getRenderStats();
                    const player_chunk = worldToChunk(@intFromFloat(camera.position.x), @intFromFloat(camera.position.z));
                    const hud_y: f32 = 50.0;
                    u.drawRect(.{ .x = 10, .y = hud_y, .width = 220, .height = 170 }, Color.rgba(0, 0, 0, 0.6));

                    drawText(u, "POS:", 15, hud_y + 5, 1.5, Color.white);
                    drawNumber(u, player_chunk.chunk_x, 120, hud_y + 5, Color.white);
                    drawNumber(u, player_chunk.chunk_z, 170, hud_y + 5, Color.white);

                    drawText(u, "CHUNKS:", 15, hud_y + 25, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.chunks_loaded), 140, hud_y + 25, Color.white);

                    drawText(u, "VISIBLE:", 15, hud_y + 45, 1.5, Color.white);
                    drawNumber(u, @intCast(rs.chunks_rendered), 140, hud_y + 45, Color.white);

                    drawText(u, "QUEUED GEN:", 15, hud_y + 65, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.gen_queue), 140, hud_y + 65, Color.white);

                    drawText(u, "QUEUED MESH:", 15, hud_y + 85, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.mesh_queue), 140, hud_y + 85, Color.white);

                    drawText(u, "PENDING UP:", 15, hud_y + 105, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.upload_queue), 140, hud_y + 105, Color.white);

                    // Time display
                    var hour_int: i32 = 0;
                    var mins: i32 = 0;
                    var sun_intensity: f32 = 1.0;

                    if (atmosphere) |atmo| {
                        const hours = atmo.getHours();
                        hour_int = @intFromFloat(hours);
                        mins = @intFromFloat((hours - @as(f32, @floatFromInt(hour_int))) * 60.0);
                        sun_intensity = atmo.sun_intensity;
                    }

                    drawText(u, "TIME:", 15, hud_y + 125, 1.5, Color.white);
                    drawNumber(u, hour_int, 100, hud_y + 125, Color.white);
                    drawText(u, ":", 125, hud_y + 125, 1.5, Color.white);
                    drawNumber(u, mins, 140, hud_y + 125, Color.white);

                    // Sun intensity indicator
                    drawText(u, "SUN:", 15, hud_y + 145, 1.5, Color.white);
                    const sun_pct: i32 = @intFromFloat(sun_intensity * 100.0);
                    drawNumber(u, sun_pct, 100, hud_y + 145, Color.white);

                    if (in_pause) {
                        // Darken background
                        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));

                        const pause_w: f32 = 300.0;
                        const pause_h: f32 = 48.0;
                        const pause_x: f32 = (screen_w - pause_w) * 0.5;
                        var pause_y: f32 = screen_h * 0.35;

                        drawTextCentered(u, "PAUSED", screen_w * 0.5, pause_y - 60.0, 3.0, Color.white);

                        if (drawButton(u, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .world;
                            input.setMouseCapture(window, true);
                        }
                        pause_y += pause_h + 16.0;

                        if (drawButton(u, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            last_state = .paused;
                            app_state = .settings;
                        }
                        pause_y += pause_h + 16.0;

                        if (drawButton(u, .{ .x = pause_x, .y = pause_y, .width = pause_w, .height = pause_h }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .home;
                            if (world) |w| {
                                w.deinit();
                                world = null;
                            }
                        }
                    }

                    u.end();
                }
            }
        } else {
            if (ui) |*u| {
                u.begin();

                switch (app_state) {
                    .home => {
                        const title_scale: f32 = 4.0;
                        drawTextCentered(u, "ZIG VOXEL ENGINE", screen_w * 0.5, screen_h * 0.16, title_scale, Color.rgba(0.95, 0.96, 0.98, 1.0));

                        const button_w: f32 = @min(screen_w * 0.5, 360.0);
                        const button_h: f32 = 48.0;
                        const button_x: f32 = (screen_w - button_w) * 0.5;
                        var button_y: f32 = screen_h * 0.4;

                        if (drawButton(u, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "SINGLEPLAYER", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .singleplayer;
                            seed_focused = true;
                        }
                        button_y += button_h + 14.0;

                        if (drawButton(u, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "SETTINGS", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                            last_state = .home;
                            app_state = .settings;
                        }
                        button_y += button_h + 14.0;

                        if (drawButton(u, .{ .x = button_x, .y = button_y, .width = button_w, .height = button_h }, "QUIT", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                            input.should_quit = true;
                        }
                    },
                    .settings => {
                        const panel_w: f32 = @min(screen_w * 0.7, 600.0);
                        const panel_h: f32 = 400.0;
                        const panel_x: f32 = (screen_w - panel_w) * 0.5;
                        const panel_y: f32 = (screen_h - panel_h) * 0.5;

                        u.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.12, 0.14, 0.18, 0.95));
                        u.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);

                        drawTextCentered(u, "SETTINGS", screen_w * 0.5, panel_y + 20.0, 2.8, Color.white);

                        var setting_y: f32 = panel_y + 80.0;
                        const label_x: f32 = panel_x + 40.0;
                        const value_x: f32 = panel_x + panel_w - 200.0;

                        // Render Distance
                        drawText(u, "RENDER DISTANCE", label_x, setting_y, 2.0, Color.white);
                        drawNumber(u, @intCast(settings.render_distance), value_x + 60.0, setting_y, Color.white);
                        if (drawButton(u, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.render_distance > 1) settings.render_distance -= 1;
                        }
                        if (drawButton(u, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            settings.render_distance += 1; // No upper limit for experiments
                        }
                        setting_y += 50.0;

                        // Mouse Sensitivity
                        drawText(u, "SENSITIVITY", label_x, setting_y, 2.0, Color.white);
                        drawNumber(u, @intFromFloat(settings.mouse_sensitivity), value_x + 60.0, setting_y, Color.white);
                        if (drawButton(u, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
                        }
                        if (drawButton(u, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
                        }
                        setting_y += 50.0;

                        // FOV
                        drawText(u, "FOV", label_x, setting_y, 2.0, Color.white);
                        drawNumber(u, @intFromFloat(settings.fov), value_x + 60.0, setting_y, Color.white);
                        if (drawButton(u, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.fov > 30.0) settings.fov -= 5.0;
                        }
                        if (drawButton(u, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.fov < 120.0) settings.fov += 5.0;
                        }
                        setting_y += 50.0;

                        // VSync
                        drawText(u, "VSYNC", label_x, setting_y, 2.0, Color.white);
                        if (drawButton(u, .{ .x = value_x, .y = setting_y - 5.0, .width = 130.0, .height = 30.0 }, if (settings.vsync) "ENABLED" else "DISABLED", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            settings.vsync = !settings.vsync;
                            setVSync(settings.vsync);
                        }
                        setting_y += 50.0;

                        // Shadow Distance
                        drawText(u, "SHADOW DISTANCE", label_x, setting_y, 2.0, Color.white);
                        drawNumber(u, @intFromFloat(settings.shadow_distance), value_x + 60.0, setting_y, Color.white);
                        if (drawButton(u, .{ .x = value_x, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.shadow_distance > 50.0) settings.shadow_distance -= 50.0;
                        }
                        if (drawButton(u, .{ .x = value_x + 100.0, .y = setting_y - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                            if (settings.shadow_distance < 1000.0) settings.shadow_distance += 50.0;
                        }
                        setting_y += 50.0;

                        // Back Button
                        if (drawButton(u, .{ .x = panel_x + (panel_w - 120.0) * 0.5, .y = panel_y + panel_h - 60.0, .width = 120.0, .height = 40.0 }, "BACK", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = last_state;
                        }
                    },
                    .singleplayer => {
                        const panel_w: f32 = @min(screen_w * 0.7, 520.0);
                        const panel_h: f32 = 260.0;
                        const panel_x: f32 = (screen_w - panel_w) * 0.5;
                        const panel_y: f32 = screen_h * 0.24;

                        u.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.12, 0.14, 0.18, 0.92));
                        u.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);

                        drawTextCentered(u, "CREATE WORLD", screen_w * 0.5, panel_y + 18.0, 2.8, Color.rgba(0.92, 0.94, 0.97, 1.0));

                        const label_y: f32 = panel_y + 78.0;
                        drawText(u, "SEED", panel_x + 24.0, label_y, 2.0, Color.rgba(0.72, 0.78, 0.86, 1.0));

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
                        drawTextInput(u, seed_rect, seed_input.items, "LEAVE BLANK FOR RANDOM", 2.0, seed_focused, caret_on);

                        if (drawButton(u, random_rect, "RANDOM", 1.8, mouse_x, mouse_y, mouse_clicked)) {
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

                        if (drawButton(u, back_rect, "BACK", 1.9, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .home;
                            seed_focused = false;
                        }

                        const create_clicked = drawButton(u, create_rect, "CREATE", 1.9, mouse_x, mouse_y, mouse_clicked);
                        const create_pressed = input.isKeyPressed(.enter);

                        if (create_clicked or create_pressed) {
                            const seed_value = try resolveSeed(&seed_input, allocator);
                            if (world) |active_world| {
                                active_world.deinit();
                                world = null;
                            }
                            world = try World.init(allocator, 2, seed_value, rhi);
                            if (world_map == null) {
                                world_map = WorldMap.init(256, 256);
                            }
                            show_map = false;
                            map_needs_update = true;
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

                u.end();
            }
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
fn drawNumber(u: *UISystem, num: i32, x: f32, y: f32, color: Color) void {
    var buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{num}) catch return;
    drawText(u, text, x, y, 2.0, color);
}

fn drawDigit(u: *UISystem, digit: u4, x: f32, y: f32, color: Color) void {
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

    if (seg[0]) u.drawRect(.{ .x = x, .y = y, .width = w, .height = t }, color); // top
    if (seg[1]) u.drawRect(.{ .x = x, .y = y, .width = t, .height = h / 2 }, color); // top-left
    if (seg[2]) u.drawRect(.{ .x = x + w - t, .y = y, .width = t, .height = h / 2 }, color); // top-right
    if (seg[3]) u.drawRect(.{ .x = x, .y = y + h / 2 - t / 2, .width = w, .height = t }, color); // middle
    if (seg[4]) u.drawRect(.{ .x = x, .y = y + h / 2, .width = t, .height = h / 2 }, color); // bottom-left
    if (seg[5]) u.drawRect(.{ .x = x + w - t, .y = y + h / 2, .width = t, .height = h / 2 }, color); // bottom-right
    if (seg[6]) u.drawRect(.{ .x = x, .y = y + h - t, .width = w, .height = t }, color); // bottom
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

fn drawGlyph(u: *UISystem, glyph: [7]u8, x: f32, y: f32, scale: f32, color: Color) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        const row_bits = glyph[row];
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const shift: u3 = @intCast(4 - col);
            const mask: u8 = @as(u8, 1) << shift;
            if ((row_bits & mask) != 0) {
                u.drawRect(.{
                    .x = x + @as(f32, @floatFromInt(col)) * scale,
                    .y = y + @as(f32, @floatFromInt(row)) * scale,
                    .width = scale,
                    .height = scale,
                }, color);
            }
        }
    }
}

fn drawText(u: *UISystem, text: []const u8, x: f32, y: f32, scale: f32, color: Color) void {
    var cursor_x = x;
    for (text) |raw| {
        var ch = raw;
        if (ch >= 'a' and ch <= 'z') {
            ch = std.ascii.toUpper(ch);
        }
        drawGlyph(u, glyphForChar(ch), cursor_x, y, scale, color);
        cursor_x += (5.0 + 1.0) * scale;
    }
}

fn measureTextWidth(text: []const u8, scale: f32) f32 {
    if (text.len == 0) return 0;
    return @as(f32, @floatFromInt(text.len)) * (5.0 + 1.0) * scale - scale;
}

fn drawTextCentered(u: *UISystem, text: []const u8, center_x: f32, y: f32, scale: f32, color: Color) void {
    const width = measureTextWidth(text, scale);
    drawText(u, text, center_x - width * 0.5, y, scale, color);
}

fn drawButton(u: *UISystem, rect: Rect, label: []const u8, scale: f32, mouse_x: f32, mouse_y: f32, clicked: bool) bool {
    const hovered = rect.contains(mouse_x, mouse_y);
    const fill = if (hovered) Color.rgba(0.2, 0.26, 0.36, 0.95) else Color.rgba(0.13, 0.17, 0.24, 0.92);
    const border = if (hovered) Color.rgba(0.55, 0.7, 0.9, 1.0) else Color.rgba(0.29, 0.35, 0.45, 1.0);

    u.drawRect(rect, fill);
    u.drawRectOutline(rect, border, 2.0);

    const text_y = rect.y + (rect.height - 7.0 * scale) * 0.5;
    drawTextCentered(u, label, rect.x + rect.width * 0.5, text_y, scale, Color.rgba(0.95, 0.96, 0.98, 1.0));

    return hovered and clicked;
}

fn drawTextInput(u: *UISystem, rect: Rect, text: []const u8, placeholder: []const u8, scale: f32, focused: bool, caret_on: bool) void {
    const background = Color.rgba(0.07, 0.09, 0.13, 0.95);
    const border = if (focused) Color.rgba(0.5, 0.75, 0.95, 1.0) else Color.rgba(0.25, 0.3, 0.38, 1.0);

    u.drawRect(rect, background);
    u.drawRectOutline(rect, border, 2.0);

    const padding: f32 = 8.0;
    const text_y = rect.y + (rect.height - 7.0 * scale) * 0.5;
    if (text.len > 0) {
        drawText(u, text, rect.x + padding, text_y, scale, Color.rgba(0.92, 0.95, 0.98, 1.0));
    } else {
        drawText(u, placeholder, rect.x + padding, text_y, scale, Color.rgba(0.5, 0.56, 0.65, 1.0));
    }

    if (focused and caret_on) {
        const caret_x = rect.x + padding + measureTextWidth(text, scale);
        u.drawRect(.{
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
