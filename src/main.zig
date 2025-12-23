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
const Rect = @import("engine/ui/ui_system.zig").Rect;
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

const rhi_pkg = @import("engine/graphics/rhi.zig");
const RHI = rhi_pkg.RHI;
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
    \\    // XY [-1,1]->[0,1]. Z is mapped if OpenGL (Vulkan already [0,1])
    \\    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    \\    
    \\    // In OpenGL (without glClipControl), Z is in [-1, 1].
    \\    // If the matrix was built for [-1, 1], we map it to [0, 1] to match texture.
    \\    projCoords.z = projCoords.z * 0.5 + 0.5;
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
    wireframe_enabled: bool = false,
    shadow_resolution: u32 = 2048,
    shadow_distance: f32 = 250.0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var use_vulkan = false;
    {
        var args_iter = try std.process.argsWithAllocator(allocator);
        defer args_iter.deinit();
        _ = args_iter.skip();
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--backend") and std.mem.eql(u8, args_iter.next() orelse "", "vulkan")) {
                use_vulkan = true;
                break;
            }
        }
    }

    if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) {
        std.debug.print("SDL Init Failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    if (!use_vulkan) {
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE);
        _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
    }

    var window_flags: u32 = c.SDL_WINDOW_RESIZABLE;
    if (use_vulkan) {
        window_flags |= c.SDL_WINDOW_VULKAN;
    } else {
        window_flags |= c.SDL_WINDOW_OPENGL;
    }

    const window = c.SDL_CreateWindow(
        "Zig Voxel Engine",
        1280,
        720,
        @intCast(window_flags),
    );
    if (window == null) {
        log.log.err("Window Creation Failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    }
    log.log.info("Window created successfully", .{});
    defer c.SDL_DestroyWindow(window);

    var gl_context: ?c.SDL_GLContext = null;
    if (!use_vulkan) {
        gl_context = c.SDL_GL_CreateContext(window);
        if (gl_context == null) return error.GLContextCreationFailed;
        _ = c.SDL_GL_MakeCurrent(window, gl_context.?);
        c.glewExperimental = c.GL_TRUE;
    }
    defer if (gl_context) |ctx| {
        _ = c.SDL_GL_DestroyContext(ctx);
    };

    const RhiResult = struct {
        rhi: RHI,
        is_vulkan: bool,
    };

    const rhi_and_type = if (use_vulkan) blk: {
        log.log.info("Attempting to initialize Vulkan backend...", .{});
        const res = rhi_vulkan.createRHI(allocator, window.?);
        if (res) |v| {
            break :blk RhiResult{ .rhi = v, .is_vulkan = true };
        } else |err| {
            log.log.err("Failed to initialize Vulkan: {}. Falling back to OpenGL.", .{err});
            if (c.glewInit() != c.GLEW_OK) return error.GLEWInitFailed;
            break :blk RhiResult{ .rhi = try rhi_opengl.createRHI(allocator), .is_vulkan = false };
        }
    } else blk: {
        log.log.info("Initializing OpenGL backend...", .{});
        if (c.glewInit() != c.GLEW_OK) {
            return error.GLEWInitFailed;
        }
        break :blk RhiResult{ .rhi = try rhi_opengl.createRHI(allocator), .is_vulkan = false };
    };
    const rhi = rhi_and_type.rhi;
    const is_vulkan = rhi_and_type.is_vulkan;
    defer rhi.deinit();

    // Initialize RHI resources (UI shaders, etc.)
    try rhi.init(allocator);

    log.log.info("Initializing engine systems...", .{});
    var settings = Settings{};
    var input = Input.init(allocator);
    defer input.deinit();
    input.window_width = 1280;
    input.window_height = 720;
    var time = Time.init();
    var renderer: ?Renderer = if (!is_vulkan) Renderer.init() else null;
    if (!is_vulkan) setVSync(settings.vsync);

    var camera = Camera.init(.{
        .position = Vec3.init(8, 100, 8),
        .pitch = -0.3,
        .move_speed = 50.0,
    });

    var shader: ?Shader = if (!is_vulkan) try Shader.initFromFile(allocator, "assets/shaders/terrain.vert", "assets/shaders/terrain.frag") else null;
    var debug_shader: ?Shader = null;
    var debug_quad_vao: c.GLuint = 0;
    var debug_quad_vbo: c.GLuint = 0;

    if (!is_vulkan) {
        const debug_vs = "#version 330 core\nlayout (location = 0) in vec2 aPos;layout (location = 1) in vec2 aTexCoord;out vec2 vTexCoord;void main() {gl_Position = vec4(aPos, 0.0, 1.0);vTexCoord = aTexCoord;}";
        const debug_fs = "#version 330 core\nout vec4 FragColor;in vec2 vTexCoord;uniform sampler2D uDepthMap;void main() {float depth = texture(uDepthMap, vTexCoord).r;FragColor = vec4(vec3(depth), 1.0);}";
        debug_shader = try Shader.initSimple(debug_vs, debug_fs);
        const quad_vertices = [_]f32{ -1.0, 1.0, 0.0, 1.0, -1.0, -1.0, 0.0, 0.0, 1.0, -1.0, 1.0, 0.0, -1.0, 1.0, 0.0, 1.0, 1.0, -1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0 };
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
    defer if (shader) |*s| s.deinit();
    defer if (debug_shader) |*s| s.deinit();

    var atlas = TextureAtlas.init(allocator, rhi);
    defer atlas.deinit();
    var ui: ?UISystem = try UISystem.init(rhi, 1280, 720);
    defer if (ui) |*u| u.deinit();
    var atmosphere: ?Atmosphere = if (is_vulkan) Atmosphere.initNoGL() else Atmosphere.init();
    defer if (atmosphere) |*a| a.deinit();
    var clouds: ?Clouds = if (is_vulkan) Clouds.initNoGL() else try Clouds.init();
    defer if (clouds) |*cl| cl.deinit();
    var shadow_map: ?ShadowMap = if (!is_vulkan) ShadowMap.init(rhi, settings.shadow_resolution) catch null else null;
    defer if (shadow_map) |*sm| sm.deinit();

    var app_state: AppState = .home;
    var last_state: AppState = .home;
    var pending_world_cleanup = false;
    var pending_new_world_seed: ?u64 = null;
    var debug_shadows = false;
    var debug_cascade_idx: usize = 0;
    var seed_input = std.ArrayListUnmanaged(u8).empty;
    defer seed_input.deinit(allocator);
    var seed_focused = false;
    var world: ?*World = null;

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

    if (renderer) |*r| r.setViewport(1280, 720);
    log.log.info("=== Zig Voxel Engine ===", .{});

    while (!input.should_quit) {
        // Safe deferred world management OUTSIDE the frame window
        if (pending_world_cleanup or pending_new_world_seed != null) {
            rhi.waitIdle();
            if (world) |w| {
                w.deinit();
                world = null;
            }
            pending_world_cleanup = false;
        }

        if (pending_new_world_seed) |seed| {
            world = try World.init(allocator, settings.render_distance, seed, rhi);
            if (world_map == null) world_map = WorldMap.init(rhi, 256, 256);
            show_map = false;
            map_needs_update = true;
            camera = Camera.init(.{ .position = Vec3.init(8, 100, 8), .pitch = -0.3, .move_speed = 50.0 });
            pending_new_world_seed = null;
        }

        time.update();
        if (atmosphere) |*a| a.update(time.delta_time);
        if (clouds) |*cl| cl.update(time.delta_time);
        input.beginFrame();
        input.pollEvents();
        if (renderer) |*r| r.setViewport(input.window_width, input.window_height);
        if (ui) |*u| u.resize(input.window_width, input.window_height);
        const screen_w: f32 = @floatFromInt(input.window_width);
        const screen_h: f32 = @floatFromInt(input.window_height);
        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = input.isMouseButtonPressed(.left);

        if (input.isKeyPressed(.escape)) {
            if (show_map) {
                show_map = false;
                if (app_state == .world) input.setMouseCapture(window, true);
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
            if (in_world and input.isKeyPressed(.tab)) input.setMouseCapture(window, !input.mouse_captured);
            if (input.isKeyPressed(.c)) if (clouds) |*cl| {
                cl.enabled = !cl.enabled;
            };
            if (input.isKeyPressed(.f)) {
                settings.wireframe_enabled = !settings.wireframe_enabled;
                if (renderer) |*r| r.toggleWireframe();
                rhi.setWireframe(settings.wireframe_enabled);
            }
            if (input.isKeyPressed(.t)) {
                settings.textures_enabled = !settings.textures_enabled;
                rhi.setTexturesEnabled(settings.textures_enabled);
            }
            if (input.isKeyPressed(.v)) {
                settings.vsync = !settings.vsync;
                rhi.setVSync(settings.vsync);
            }
            if (input.isKeyPressed(.u)) debug_shadows = !debug_shadows;
            if (input.isKeyPressed(.m)) {
                show_map = !show_map;
                if (show_map) {
                    map_pos_x = camera.position.x;
                    map_pos_z = camera.position.z;
                    map_target_zoom = map_zoom;
                    map_needs_update = true;
                    input.setMouseCapture(window, false);
                } else if (app_state == .world) input.setMouseCapture(window, true);
            }

            if (show_map) {
                const dt = @min(time.delta_time, 0.033);
                if (input.isKeyDown(.plus) or input.isKeyDown(.kp_plus)) {
                    map_target_zoom /= @exp(1.2 * dt);
                    map_needs_update = true;
                }
                if (input.isKeyDown(.minus) or input.isKeyDown(.kp_minus)) {
                    map_target_zoom *= @exp(1.2 * dt);
                    map_needs_update = true;
                }
                if (input.scroll_y != 0) {
                    map_target_zoom *= @exp(-input.scroll_y * 0.12);
                    map_needs_update = true;
                }
                map_target_zoom = std.math.clamp(map_target_zoom, 0.05, 128.0);
                const old_zoom = map_zoom;
                map_zoom = std.math.lerp(map_zoom, map_target_zoom, 20.0 * dt);
                if (@abs(map_zoom - old_zoom) > 0.001 * map_zoom) map_needs_update = true;
                if (input.isKeyPressed(.space)) {
                    map_pos_x = camera.position.x;
                    map_pos_z = camera.position.z;
                    map_needs_update = true;
                }
                const map_ui_size: f32 = @min(screen_w, screen_h) * 0.8;
                const world_to_screen_ratio = if (world_map) |m| @as(f32, @floatFromInt(m.width)) / map_ui_size else 1.0;
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

            if (debug_shadows and input.isKeyPressed(.k)) debug_cascade_idx = (debug_cascade_idx + 1) % 3;
            if (input.isKeyPressed(.@"1")) if (atmosphere) |*a| a.setTimeOfDay(0.0);
            if (input.isKeyPressed(.@"2")) if (atmosphere) |*a| a.setTimeOfDay(0.25);
            if (input.isKeyPressed(.@"3")) if (atmosphere) |*a| a.setTimeOfDay(0.5);
            if (input.isKeyPressed(.@"4")) if (atmosphere) |*a| a.setTimeOfDay(0.75);
            if (input.isKeyPressed(.n)) if (atmosphere) |*a| {
                a.time_scale = if (a.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
            };

            if (in_world) {
                if (!show_map and !in_pause) {
                    camera.update(&input, time.delta_time);
                }

                if (world) |active_world| {
                    // Sync render distance
                    if (active_world.render_distance != settings.render_distance) {
                        active_world.render_distance = settings.render_distance;
                    }

                    try active_world.update(camera.position);
                } else app_state = .home;
            }
        } else if (input.mouse_captured) input.setMouseCapture(window, false);

        const clear_color = if (in_world or in_pause) (if (atmosphere) |a| a.fog_color else Vec3.init(0.5, 0.7, 1.0)) else Vec3.init(0.07, 0.08, 0.1);
        rhi.setClearColor(clear_color);
        if (renderer) |*r| {
            r.setClearColor(clear_color);
            r.beginFrame();
        }
        rhi.beginFrame();

        if (in_world or in_pause) {
            if (world) |active_world| {
                const aspect = screen_w / screen_h;
                const view_proj_cull = camera.getViewProjectionMatrixOriginCentered(aspect);
                const view_proj_render = if (is_vulkan)
                    Mat4.perspectiveReverseZ(camera.fov, aspect, camera.near, camera.far).multiply(camera.getViewMatrixOriginCentered())
                else
                    view_proj_cull;
                if (shadow_map) |*sm| {
                    if (atmosphere) |atmo| {
                        var light_dir = atmo.sun_dir;
                        if (atmo.sun_intensity < 0.05 and atmo.moon_intensity > 0.05) light_dir = atmo.moon_dir;
                        if (atmo.sun_intensity > 0.05 or atmo.moon_intensity > 0.05) {
                            sm.update(camera.fov, aspect, 0.1, settings.shadow_distance, light_dir, camera.position, camera.getViewMatrixOriginCentered());
                            for (0..3) |i| {
                                sm.begin(i);
                                active_world.renderShadowPass(&sm.shader, sm.light_space_matrices[i], camera.position);
                            }
                            sm.end(input.window_width, input.window_height);
                        }
                    }
                }
                if (renderer) |*r| {
                    r.setClearColor(clear_color);
                    r.beginFrame();
                }
                if (!is_vulkan) if (atmosphere) |*a| a.renderSky(camera.forward, camera.right, camera.up, aspect, camera.fov);
                if (shader) |*s| {
                    s.use();
                    atlas.bind(0);
                    s.setInt("uTexture", 0);
                    s.setBool("uUseTexture", settings.textures_enabled);
                    if (shadow_map) |*sm| {
                        for (0..3) |i| {
                            sm.depth_maps[i].bind(@intCast(1 + i));
                            var buf: [64]u8 = undefined;
                            s.setInt(std.fmt.bufPrintZ(&buf, "uShadowMap{}", .{i}) catch "uShadowMap0", @intCast(1 + i));
                            s.setMat4(std.fmt.bufPrintZ(&buf, "uLightSpaceMatrices[{}]", .{i}) catch unreachable, &sm.light_space_matrices[i].data);
                            s.setFloat(std.fmt.bufPrintZ(&buf, "uCascadeSplits[{}]", .{i}) catch unreachable, sm.cascade_splits[i]);
                            s.setFloat(std.fmt.bufPrintZ(&buf, "uShadowTexelSizes[{}]", .{i}) catch unreachable, sm.texel_sizes[i]);
                        }
                    }
                    if (atmosphere) |atmo| {
                        s.setVec3("uSunDir", atmo.sun_dir.x, atmo.sun_dir.y, atmo.sun_dir.z);
                        s.setFloat("uSunIntensity", atmo.sun_intensity);
                        s.setFloat("uAmbient", atmo.ambient_intensity);
                        s.setVec3("uFogColor", atmo.fog_color.x, atmo.fog_color.y, atmo.fog_color.z);
                        s.setFloat("uFogDensity", atmo.fog_density);
                        s.setBool("uFogEnabled", atmo.fog_enabled);
                    }
                    if (clouds) |*cl| {
                        const p = cl.getCloudShadowParams();
                        s.setFloat("uCloudWindOffsetX", p.wind_offset_x);
                        s.setFloat("uCloudWindOffsetZ", p.wind_offset_z);
                        s.setFloat("uCloudScale", p.cloud_scale);
                        s.setFloat("uCloudCoverage", p.cloud_coverage);
                        s.setFloat("uCloudShadowStrength", 0.15);
                        s.setFloat("uCloudHeight", p.cloud_height);
                    }
                    active_world.render(s, view_proj_cull, camera.position);
                } else if (is_vulkan) {
                    const fallback_sun_dir = Vec3.init(0.5, 0.8, 0.2);
                    const fallback_sky_color = Vec3.init(0.5, 0.7, 1.0);
                    const fallback_horizon_color = Vec3.init(0.8, 0.85, 0.95);

                    const sun_dir = if (atmosphere) |a| a.sun_dir else fallback_sun_dir;
                    const time_val = if (atmosphere) |a| a.time_of_day else 0.25;
                    const fog_color = if (atmosphere) |a| a.fog_color else Vec3.init(0.7, 0.8, 0.9);
                    const fog_density = if (atmosphere) |a| a.fog_density else 0.0;
                    const fog_enabled = if (atmosphere) |a| a.fog_enabled else false;
                    const sun_intensity_val = if (atmosphere) |a| a.sun_intensity else 1.0;
                    const moon_intensity_val = if (atmosphere) |a| a.moon_intensity else 0.0;
                    const ambient_val = if (atmosphere) |a| a.ambient_intensity else 0.2;
                    const sky_color = if (atmosphere) |a| a.sky_color else fallback_sky_color;
                    const horizon_color = if (atmosphere) |a| a.horizon_color else fallback_horizon_color;

                    var light_dir = sun_dir;
                    var light_active = true;
                    if (atmosphere) |atmo| {
                        if (atmo.sun_intensity < 0.05 and atmo.moon_intensity > 0.05) {
                            light_dir = atmo.moon_dir;
                        }
                        light_active = atmo.sun_intensity > 0.05 or atmo.moon_intensity > 0.05;
                    }

                    if (light_active) {
                        const cascades = ShadowMap.computeCascades(settings.shadow_resolution, camera.fov, aspect, 0.1, settings.shadow_distance, light_dir, camera.getViewMatrixOriginCentered(), true);
                        rhi.updateShadowUniforms(.{
                            .light_space_matrices = cascades.light_space_matrices,
                            .cascade_splits = cascades.cascade_splits,
                            .shadow_texel_sizes = cascades.texel_sizes,
                        });
                        for (0..ShadowMap.CASCADE_COUNT) |i| {
                            rhi.beginShadowPass(@intCast(i));
                            rhi.updateGlobalUniforms(cascades.light_space_matrices[i], camera.position, light_dir, time_val, fog_color, fog_density, false, 0.0, 0.0, .{});
                            active_world.renderShadowPass(null, cascades.light_space_matrices[i], camera.position);
                            rhi.endShadowPass();
                        }
                    }

                    rhi.drawSky(.{
                        .cam_pos = camera.position,
                        .cam_forward = camera.forward,
                        .cam_right = camera.right,
                        .cam_up = camera.up,
                        .aspect = aspect,
                        .tan_half_fov = @tan(camera.fov / 2.0),
                        .sun_dir = sun_dir,
                        .sky_color = sky_color,
                        .horizon_color = horizon_color,
                        .sun_intensity = sun_intensity_val,
                        .moon_intensity = moon_intensity_val,
                        .time = time_val,
                    });

                    atlas.bind(0);
                    const cp: rhi_pkg.CloudParams = if (clouds) |*cl| blk: {
                        const p = cl.getCloudShadowParams();
                        break :blk .{
                            .wind_offset_x = p.wind_offset_x,
                            .wind_offset_z = p.wind_offset_z,
                            .cloud_scale = p.cloud_scale,
                            .cloud_coverage = p.cloud_coverage,
                            .cloud_height = p.cloud_height,
                        };
                    } else .{};
                    rhi.updateGlobalUniforms(view_proj_render, camera.position, sun_dir, time_val, fog_color, fog_density, fog_enabled, sun_intensity_val, ambient_val, cp);
                    active_world.render(null, view_proj_cull, camera.position);
                }
                if (clouds) |*cl| if (atmosphere) |atmo| if (!is_vulkan) cl.render(camera.position, &view_proj_cull.data, atmo.sun_dir, atmo.sun_intensity, atmo.fog_color, atmo.fog_density);
                if (debug_shadows and debug_shader != null and shadow_map != null) {
                    debug_shader.?.use();
                    c.glActiveTexture().?(c.GL_TEXTURE0);
                    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(shadow_map.?.depth_maps[debug_cascade_idx].handle));
                    debug_shader.?.setInt("uDepthMap", 0);
                    c.glBindVertexArray().?(debug_quad_vao);
                    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
                    c.glBindVertexArray().?(0);
                }
                if (ui) |*u| {
                    u.begin();
                    if (show_map) if (world_map) |*m| {
                        if (map_needs_update) {
                            try m.update(&active_world.generator, map_pos_x, map_pos_z, map_zoom);
                            map_needs_update = false;
                        }
                        const sz: f32 = @min(screen_w, screen_h) * 0.8;
                        const mx = (screen_w - sz) * 0.5;
                        const my = (screen_h - sz) * 0.5;
                        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
                        u.drawTexture(@intCast(m.texture.handle), .{ .x = mx, .y = my, .width = sz, .height = sz });
                        u.drawRectOutline(.{ .x = mx, .y = my, .width = sz, .height = sz }, Color.white, 2.0);
                        drawTextCentered(u, "WORLD MAP", screen_w * 0.5, my - 40.0, 3.0, Color.white);
                        const rx = (camera.position.x - map_pos_x) / (map_zoom * @as(f32, @floatFromInt(m.width)));
                        const rz = (camera.position.z - map_pos_z) / (map_zoom * @as(f32, @floatFromInt(m.height)));
                        const px = mx + (rx + 0.5) * sz;
                        const pz = my + (rz + 0.5) * sz;
                        if (px >= mx and px <= mx + sz and pz >= my and pz <= my + sz) {
                            u.drawRect(.{ .x = px - 5, .y = pz - 1, .width = 10, .height = 2 }, Color.red);
                            u.drawRect(.{ .x = px - 1, .y = pz - 5, .width = 2, .height = 10 }, Color.red);
                        }
                    };
                    u.drawRect(.{ .x = 10, .y = 10, .width = 80, .height = 30 }, Color.rgba(0, 0, 0, 0.7));
                    drawNumber(u, @intFromFloat(time.fps), 15, 15, Color.white);
                    const stats = active_world.getStats();
                    const rs = active_world.getRenderStats();
                    const pc = worldToChunk(@intFromFloat(camera.position.x), @intFromFloat(camera.position.z));
                    const hy: f32 = 50.0;
                    u.drawRect(.{ .x = 10, .y = hy, .width = 220, .height = 170 }, Color.rgba(0, 0, 0, 0.6));
                    drawText(u, "POS:", 15, hy + 5, 1.5, Color.white);
                    drawNumber(u, pc.chunk_x, 120, hy + 5, Color.white);
                    drawNumber(u, pc.chunk_z, 170, hy + 5, Color.white);
                    drawText(u, "CHUNKS:", 15, hy + 25, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.chunks_loaded), 140, hy + 25, Color.white);
                    drawText(u, "VISIBLE:", 15, hy + 45, 1.5, Color.white);
                    drawNumber(u, @intCast(rs.chunks_rendered), 140, hy + 45, Color.white);
                    drawText(u, "QUEUED GEN:", 15, hy + 65, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.gen_queue), 140, hy + 65, Color.white);
                    drawText(u, "QUEUED MESH:", 15, hy + 85, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.mesh_queue), 140, hy + 85, Color.white);
                    drawText(u, "PENDING UP:", 15, hy + 105, 1.5, Color.white);
                    drawNumber(u, @intCast(stats.upload_queue), 140, hy + 105, Color.white);
                    var hr: i32 = 0;
                    var mn: i32 = 0;
                    var si: f32 = 1.0;
                    if (atmosphere) |atmo| {
                        const h = atmo.getHours();
                        hr = @intFromFloat(h);
                        mn = @intFromFloat((h - @as(f32, @floatFromInt(hr))) * 60.0);
                        si = atmo.sun_intensity;
                    }
                    drawText(u, "TIME:", 15, hy + 125, 1.5, Color.white);
                    drawNumber(u, hr, 100, hy + 125, Color.white);
                    drawText(u, ":", 125, hy + 125, 1.5, Color.white);
                    drawNumber(u, mn, 140, hy + 125, Color.white);
                    drawText(u, "SUN:", 15, hy + 145, 1.5, Color.white);
                    drawNumber(u, @intFromFloat(si * 100.0), 100, hy + 145, Color.white);
                    if (in_pause) {
                        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.5));
                        const pw: f32 = 300.0;
                        const ph: f32 = 48.0;
                        const px: f32 = (screen_w - pw) * 0.5;
                        var py: f32 = screen_h * 0.35;
                        drawTextCentered(u, "PAUSED", screen_w * 0.5, py - 60.0, 3.0, Color.white);
                        if (drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "RESUME", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .world;
                            input.setMouseCapture(window, true);
                        }
                        py += ph + 16.0;
                        if (drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "SETTINGS", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            last_state = .paused;
                            app_state = .settings;
                        }
                        py += ph + 16.0;
                        if (drawButton(u, .{ .x = px, .y = py, .width = pw, .height = ph }, "QUIT TO TITLE", 2.0, mouse_x, mouse_y, mouse_clicked)) {
                            app_state = .home;
                            pending_world_cleanup = true;
                        }
                    }
                    u.end();
                }
            }
        } else if (ui) |*u| {
            u.begin();
            switch (app_state) {
                .home => {
                    drawTextCentered(u, "ZIG VOXEL ENGINE", screen_w * 0.5, screen_h * 0.16, 4.0, Color.rgba(0.95, 0.96, 0.98, 1.0));
                    const bw: f32 = @min(screen_w * 0.5, 360.0);
                    const bh: f32 = 48.0;
                    const bx: f32 = (screen_w - bw) * 0.5;
                    var by: f32 = screen_h * 0.4;
                    if (drawButton(u, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SINGLEPLAYER", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .singleplayer;
                        seed_focused = true;
                    }
                    by += bh + 14.0;
                    if (drawButton(u, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SETTINGS", 2.2, mouse_x, mouse_y, mouse_clicked)) {
                        last_state = .home;
                        app_state = .settings;
                    }
                    by += bh + 14.0;
                    if (drawButton(u, .{ .x = bx, .y = by, .width = bw, .height = bh }, "QUIT", 2.2, mouse_x, mouse_y, mouse_clicked)) input.should_quit = true;
                },
                .settings => {
                    const pw: f32 = @min(screen_w * 0.7, 600.0);
                    const ph: f32 = 400.0;
                    const px: f32 = (screen_w - pw) * 0.5;
                    const py: f32 = (screen_h - ph) * 0.5;
                    u.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.95));
                    u.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);
                    drawTextCentered(u, "SETTINGS", screen_w * 0.5, py + 20.0, 2.8, Color.white);
                    var sy: f32 = py + 80.0;
                    const lx: f32 = px + 40.0;
                    const vx: f32 = px + pw - 200.0;
                    drawText(u, "RENDER DISTANCE", lx, sy, 2.0, Color.white);
                    drawNumber(u, @intCast(settings.render_distance), vx + 60.0, sy, Color.white);
                    if (drawButton(u, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.render_distance > 1) settings.render_distance -= 1;
                    }
                    if (drawButton(u, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        settings.render_distance += 1;
                    }
                    sy += 50.0;
                    drawText(u, "SENSITIVITY", lx, sy, 2.0, Color.white);
                    drawNumber(u, @intFromFloat(settings.mouse_sensitivity), vx + 60.0, sy, Color.white);
                    if (drawButton(u, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
                    }
                    if (drawButton(u, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
                    }
                    sy += 50.0;
                    drawText(u, "FOV", lx, sy, 2.0, Color.white);
                    drawNumber(u, @intFromFloat(settings.fov), vx + 60.0, sy, Color.white);
                    if (drawButton(u, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.fov > 30.0) settings.fov -= 5.0;
                    }
                    if (drawButton(u, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.fov < 120.0) settings.fov += 5.0;
                    }
                    sy += 50.0;
                    drawText(u, "VSYNC", lx, sy, 2.0, Color.white);
                    if (drawButton(u, .{ .x = vx, .y = sy - 5.0, .width = 130.0, .height = 30.0 }, if (settings.vsync) "ENABLED" else "DISABLED", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        settings.vsync = !settings.vsync;
                        rhi.setVSync(settings.vsync);
                    }
                    sy += 50.0;
                    drawText(u, "SHADOW DISTANCE", lx, sy, 2.0, Color.white);
                    drawNumber(u, @intFromFloat(settings.shadow_distance), vx + 60.0, sy, Color.white);
                    if (drawButton(u, .{ .x = vx, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "-", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.shadow_distance > 50.0) settings.shadow_distance -= 50.0;
                    }
                    if (drawButton(u, .{ .x = vx + 100.0, .y = sy - 5.0, .width = 30.0, .height = 30.0 }, "+", 1.5, mouse_x, mouse_y, mouse_clicked)) {
                        if (settings.shadow_distance < 1000.0) settings.shadow_distance += 50.0;
                    }
                    if (drawButton(u, .{ .x = px + (pw - 120.0) * 0.5, .y = py + ph - 60.0, .width = 120.0, .height = 40.0 }, "BACK", 2.0, mouse_x, mouse_y, mouse_clicked)) app_state = last_state;
                },
                .singleplayer => {
                    const pw: f32 = @min(screen_w * 0.7, 520.0);
                    const ph: f32 = 260.0;
                    const px: f32 = (screen_w - pw) * 0.5;
                    const py: f32 = screen_h * 0.24;
                    u.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.12, 0.14, 0.18, 0.92));
                    u.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, Color.rgba(0.28, 0.33, 0.42, 1.0), 2.0);
                    drawTextCentered(u, "CREATE WORLD", screen_w * 0.5, py + 18.0, 2.8, Color.rgba(0.92, 0.94, 0.97, 1.0));
                    const ly: f32 = py + 78.0;
                    drawText(u, "SEED", px + 24.0, ly, 2.0, Color.rgba(0.72, 0.78, 0.86, 1.0));
                    const ih: f32 = 42.0;
                    const iy: f32 = ly + 22.0;
                    const rw: f32 = 120.0;
                    const iw: f32 = pw - 24.0 - rw - 12.0 - 24.0;
                    const ix: f32 = px + 24.0;
                    const rx: f32 = ix + iw + 12.0;
                    const seed_rect = Rect{ .x = ix, .y = iy, .width = iw, .height = ih };
                    const random_rect = Rect{ .x = rx, .y = iy, .width = rw, .height = ih };
                    if (mouse_clicked) seed_focused = seed_rect.contains(mouse_x, mouse_y);
                    drawTextInput(u, seed_rect, seed_input.items, "LEAVE BLANK FOR RANDOM", 2.0, seed_focused, @as(u32, @intFromFloat(time.elapsed * 2.0)) % 2 == 0);
                    if (drawButton(u, random_rect, "RANDOM", 1.8, mouse_x, mouse_y, mouse_clicked)) {
                        const gen = randomSeedValue();
                        try setSeedInput(&seed_input, allocator, gen);
                        seed_focused = true;
                    }
                    if (seed_focused) try handleSeedTyping(&seed_input, allocator, &input, 32);
                    const byy: f32 = py + ph - 64.0;
                    const hw: f32 = (pw - 24.0 - 12.0 - 24.0) / 2.0;
                    if (drawButton(u, .{ .x = px + 24.0, .y = byy, .width = hw, .height = 40.0 }, "BACK", 1.9, mouse_x, mouse_y, mouse_clicked)) {
                        app_state = .home;
                        seed_focused = false;
                    }
                    if (drawButton(u, .{ .x = px + 24.0 + hw + 12.0, .y = byy, .width = hw, .height = 40.0 }, "CREATE", 1.9, mouse_x, mouse_y, mouse_clicked) or input.isKeyPressed(.enter)) {
                        const seed = try resolveSeed(&seed_input, allocator);
                        pending_new_world_seed = seed;
                        app_state = .world;
                        seed_focused = false;
                        log.log.info("World seed: {}", .{seed});
                    }
                },
                .world, .paused => unreachable,
            }
            u.end();
        }

        rhi.endFrame();
        if (!is_vulkan) _ = c.SDL_GL_SwapWindow(window);
        if (in_world) {
            if (world) |active_world| {
                if (time.frame_count % 120 == 0) {
                    const s = active_world.getStats();
                    const rs = active_world.getRenderStats();
                    std.debug.print("FPS: {d:.1} | Chunks: {}/{} (culled: {}) | Vertices: {} | Pos: ({d:.1}, {d:.1}, {d:.1})\n", .{ time.fps, rs.chunks_rendered, s.chunks_loaded, rs.chunks_culled, rs.vertices_rendered, camera.position.x, camera.position.y, camera.position.z });
                }
            }
        }
    }
}

fn drawNumber(u: *UISystem, num: i32, x: f32, y: f32, color: Color) void {
    var buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{num}) catch return;
    drawText(u, text, x, y, 2.0, color);
}

fn drawDigit(u: *UISystem, digit: u4, x: f32, y: f32, color: Color) void {
    const segments: [10][7]bool = .{ .{ true, true, true, false, true, true, true }, .{ false, false, true, false, false, true, false }, .{ true, false, true, true, true, false, true }, .{ true, false, true, true, false, true, true }, .{ false, true, true, true, false, true, false }, .{ true, true, false, true, false, true, true }, .{ true, true, false, true, true, true, true }, .{ true, false, true, false, false, true, false }, .{ true, true, true, true, true, true, true }, .{ true, true, true, true, false, true, true } };
    const seg = segments[digit];
    if (seg[0]) u.drawRect(.{ .x = x, .y = y, .width = 10, .height = 2 }, color);
    if (seg[1]) u.drawRect(.{ .x = x, .y = y, .width = 2, .height = 8 }, color);
    if (seg[2]) u.drawRect(.{ .x = x + 8, .y = y, .width = 2, .height = 8 }, color);
    if (seg[3]) u.drawRect(.{ .x = x, .y = y + 7, .width = 10, .height = 2 }, color);
    if (seg[4]) u.drawRect(.{ .x = x, .y = y + 8, .width = 2, .height = 8 }, color);
    if (seg[5]) u.drawRect(.{ .x = x + 8, .y = y + 8, .width = 2, .height = 8 }, color);
    if (seg[6]) u.drawRect(.{ .x = x, .y = y + 14, .width = 10, .height = 2 }, color);
}

const font_letters = [_][7]u8{ .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }, .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }, .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }, .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }, .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }, .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10011, 0b10001, 0b01110 }, .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 }, .{ 0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b10001, 0b01110 }, .{ 0b10001, 0b10100, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }, .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }, .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001 }, .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }, .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }, .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }, .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 }, .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10101, 0b01010, 0b00100 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 }, .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 }, .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 }, .{ 0b11111, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111, 0b11111 } };
const font_digits = [_][7]u8{ .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 }, .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 }, .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 } };
fn glyphForChar(ch: u8) [7]u8 {
    if (ch >= 'A' and ch <= 'Z') return font_letters[ch - 'A'];
    if (ch >= '0' and ch <= '9') return font_digits[ch - '0'];
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
        const rb = glyph[row];
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const shift: u3 = @intCast(4 - col);
            if ((rb & (@as(u8, 1) << shift)) != 0) u.drawRect(.{ .x = x + @as(f32, @floatFromInt(col)) * scale, .y = y + @as(f32, @floatFromInt(row)) * scale, .width = scale, .height = scale }, color);
        }
    }
}
fn drawText(u: *UISystem, text: []const u8, x: f32, y: f32, scale: f32, color: Color) void {
    var cx = x;
    for (text) |raw| {
        var ch = raw;
        if (ch >= 'a' and ch <= 'z') ch = std.ascii.toUpper(ch);
        drawGlyph(u, glyphForChar(ch), cx, y, scale, color);
        cx += 6.0 * scale;
    }
}
fn measureTextWidth(text: []const u8, scale: f32) f32 {
    if (text.len == 0) return 0;
    return @as(f32, @floatFromInt(text.len)) * 6.0 * scale - scale;
}
fn drawTextCentered(u: *UISystem, text: []const u8, cx: f32, y: f32, scale: f32, color: Color) void {
    const w = measureTextWidth(text, scale);
    drawText(u, text, cx - w * 0.5, y, scale, color);
}
fn drawButton(u: *UISystem, rect: Rect, label: []const u8, scale: f32, mx: f32, my: f32, clicked: bool) bool {
    const hov = rect.contains(mx, my);
    u.drawRect(rect, if (hov) Color.rgba(0.2, 0.26, 0.36, 0.95) else Color.rgba(0.13, 0.17, 0.24, 0.92));
    u.drawRectOutline(rect, if (hov) Color.rgba(0.55, 0.7, 0.9, 1.0) else Color.rgba(0.29, 0.35, 0.45, 1.0), 2.0);
    drawTextCentered(u, label, rect.x + rect.width * 0.5, rect.y + (rect.height - 7.0 * scale) * 0.5, scale, Color.rgba(0.95, 0.96, 0.98, 1.0));
    return hov and clicked;
}
fn drawTextInput(u: *UISystem, rect: Rect, text: []const u8, ph: []const u8, scale: f32, foc: bool, caret: bool) void {
    u.drawRect(rect, Color.rgba(0.07, 0.09, 0.13, 0.95));
    u.drawRectOutline(rect, if (foc) Color.rgba(0.5, 0.75, 0.95, 1.0) else Color.rgba(0.25, 0.3, 0.38, 1.0), 2.0);
    const ty = rect.y + (rect.height - 7.0 * scale) * 0.5;
    if (text.len > 0) drawText(u, text, rect.x + 8, ty, scale, Color.rgba(0.92, 0.95, 0.98, 1.0)) else drawText(u, ph, rect.x + 8, ty, scale, Color.rgba(0.5, 0.56, 0.65, 1.0));
    if (foc and caret) u.drawRect(.{ .x = rect.x + 8 + measureTextWidth(text, scale), .y = rect.y + 8, .width = 2, .height = rect.height - 16 }, Color.rgba(0.9, 0.95, 1.0, 1.0));
}
fn handleSeedTyping(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: *const Input, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (seed_input.items.len > 0) _ = seed_input.pop();
    }
    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);
    const letters = [_]Key{ .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z };
    inline for (letters) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) {
        var ch: u8 = @intCast(@intFromEnum(key));
        if (shift) ch = std.ascii.toUpper(ch);
        try seed_input.append(allocator, ch);
    };
    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| if (input.isKeyPressed(key) and seed_input.items.len < max_len) try seed_input.append(allocator, @intCast(@intFromEnum(key)));
    if (input.isKeyPressed(.space) and seed_input.items.len < max_len) try seed_input.append(allocator, ' ');
}

fn randomSeedValue() u64 {
    const t: u64 = @intCast(c.SDL_GetTicks());
    const p: u64 = @intCast(c.SDL_GetPerformanceCounter());
    var s = p ^ (t << 32);
    s ^= s >> 33;
    s *%= 0xff51afd7ed558ccd;
    s ^= s >> 33;
    s *%= 0xc4ceb9fe1a85ec53;
    s ^= s >> 33;
    return s;
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (bytes) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

fn seedFromText(text: []const u8) u64 {
    var all = true;
    for (text) |ch| {
        if (ch < '0' or ch > '9') {
            all = false;
            break;
        }
    }
    if (all) return std.fmt.parseUnsigned(u64, text, 10) catch fnv1a64(text);
    return fnv1a64(text);
}

fn resolveSeed(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !u64 {
    const trimmed = std.mem.trim(u8, seed_input.items, " \t");
    if (trimmed.len == 0) {
        const gen = randomSeedValue();
        try setSeedInput(seed_input, allocator, gen);
        return gen;
    }
    return seedFromText(trimmed);
}

fn setSeedInput(seed_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u64) !void {
    var buf: [32]u8 = undefined;
    const wr = try std.fmt.bufPrint(&buf, "{d}", .{val});
    seed_input.clearRetainingCapacity();
    try seed_input.appendSlice(allocator, wr);
}
