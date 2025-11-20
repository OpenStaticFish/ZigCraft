const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Camera = @import("camera.zig").Camera;

// Import C headers
const c = @cImport({
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("SDL3/SDL.h");
    @cInclude("GL/glew.h");
    @cInclude("SDL3/SDL_opengl.h");
});

// Simple Shader Sources
const vertex_shader_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\layout (location = 1) in vec3 aColor;
    \\out vec3 vColor;
    \\uniform mat4 transform;
    \\void main() {
    \\    gl_Position = transform * vec4(aPos, 1.0);
    \\    vColor = aColor;
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\in vec3 vColor;
    \\out vec4 FragColor;
    \\void main() {
    \\    FragColor = vec4(vColor, 1.0);
    \\}
;

pub fn main() !void {
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
    const window = c.SDL_CreateWindow("Zig SDL3 OpenGL", 800, 600, c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    // 4. Create Context
    const gl_context = c.SDL_GL_CreateContext(window);
    if (gl_context == null) return error.GLContextCreationFailed;
    defer _ = c.SDL_GL_DestroyContext(gl_context);

    _ = c.SDL_GL_MakeCurrent(window, gl_context);
    _ = c.SDL_SetWindowRelativeMouseMode(window, true);

    // 5. Initialize GLEW (Must be done after Context creation)
    c.glewExperimental = c.GL_TRUE;
    if (c.glewInit() != c.GLEW_OK) {
        return error.GLEWInitFailed;
    }

    // Enable Depth Test for 3D
    c.glEnable(c.GL_DEPTH_TEST);
    // Enable Backface Culling
    c.glEnable(c.GL_CULL_FACE);

    // 6. Setup Cube Data (Position x,y,z | Color r,g,b)
    const vertices = [_]f32{
        // Back Face
        -0.5, -0.5, -0.5, 1.0, 0.0, 0.0,
        0.5,  0.5,  -0.5, 1.0, 0.0, 0.0,
        0.5,  -0.5, -0.5, 1.0, 0.0, 0.0,
        0.5,  0.5,  -0.5, 1.0, 0.0, 0.0,
        -0.5, -0.5, -0.5, 1.0, 0.0, 0.0,
        -0.5, 0.5,  -0.5, 1.0, 0.0, 0.0,

        // Front Face
        -0.5, -0.5, 0.5,  0.0, 1.0, 0.0,
        0.5,  -0.5, 0.5,  0.0, 1.0, 0.0,
        0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
        0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
        -0.5, 0.5,  0.5,  0.0, 1.0, 0.0,
        -0.5, -0.5, 0.5,  0.0, 1.0, 0.0,

        // Left Face
        -0.5, 0.5,  0.5,  0.0, 0.0, 1.0,
        -0.5, 0.5,  -0.5, 0.0, 0.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 0.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 0.0, 1.0,
        -0.5, -0.5, 0.5,  0.0, 0.0, 1.0,
        -0.5, 0.5,  0.5,  0.0, 0.0, 1.0,

        // Right Face
        0.5,  0.5,  0.5,  1.0, 1.0, 0.0,
        0.5,  -0.5, -0.5, 1.0, 1.0, 0.0,
        0.5,  0.5,  -0.5, 1.0, 1.0, 0.0,
        0.5,  -0.5, -0.5, 1.0, 1.0, 0.0,
        0.5,  0.5,  0.5,  1.0, 1.0, 0.0,
        0.5,  -0.5, 0.5,  1.0, 1.0, 0.0,

        // Bottom Face
        -0.5, -0.5, -0.5, 0.0, 1.0, 1.0,
        0.5,  -0.5, -0.5, 0.0, 1.0, 1.0,
        0.5,  -0.5, 0.5,  0.0, 1.0, 1.0,
        0.5,  -0.5, 0.5,  0.0, 1.0, 1.0,
        -0.5, -0.5, 0.5,  0.0, 1.0, 1.0,
        -0.5, -0.5, -0.5, 0.0, 1.0, 1.0,

        // Top Face
        -0.5, 0.5,  -0.5, 1.0, 0.0, 1.0,
        -0.5, 0.5,  0.5,  1.0, 0.0, 1.0,
        0.5,  0.5,  0.5,  1.0, 0.0, 1.0,
        0.5,  0.5,  0.5,  1.0, 0.0, 1.0,
        0.5,  0.5,  -0.5, 1.0, 0.0, 1.0,
        -0.5, 0.5,  -0.5, 1.0, 0.0, 1.0,
    };

    var vao: c.GLuint = undefined;
    var vbo: c.GLuint = undefined;
    c.glGenVertexArrays().?(1, &vao);
    c.glGenBuffers().?(1, &vbo);

    c.glBindVertexArray().?(vao);

    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);

    // Position Attribute (Layout 0, 3 floats, Stride 6 * f32)
    c.glVertexAttribPointer().?(0, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(f32), null);
    c.glEnableVertexAttribArray().?(0);

    // Color Attribute (Layout 1, 3 floats, Offset 3 * f32)
    c.glVertexAttribPointer().?(1, 3, c.GL_FLOAT, c.GL_FALSE, 6 * @sizeOf(f32), @ptrFromInt(3 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(1);

    // 7. Compile Shaders
    const shader_program = try createShaderProgram();
    defer c.glDeleteProgram().?(shader_program);

    const transform_loc = c.glGetUniformLocation().?(shader_program, "transform");

    // Camera Setup
    var camera = Camera.new(Vec3.new(0.0, 0.0, 3.0), Vec3.new(0.0, 1.0, 0.0), -90.0, 0.0);
    var lastTime: u64 = c.SDL_GetTicks();

    // 8. Main Loop
    var running = true;
    while (running) {
        // Calculate Delta Time
        const currentTime = c.SDL_GetTicks();
        const deltaTime = @as(f32, @floatFromInt(currentTime - lastTime)) / 1000.0;
        lastTime = currentTime;

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_ESCAPE) running = false;

            if (event.type == c.SDL_EVENT_MOUSE_MOTION) {
                camera.processMouseMovement(event.motion.xrel, event.motion.yrel, true);
            }

            if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
                var w: c_int = 0;
                var h: c_int = 0;
                _ = c.SDL_GetWindowSize(window, &w, &h);
                c.glViewport(0, 0, w, h);
            }
        }

        // Keyboard Input
        const keys = c.SDL_GetKeyboardState(null);

        if (keys[c.SDL_SCANCODE_W]) camera.processKeyboard(.FORWARD, deltaTime);
        if (keys[c.SDL_SCANCODE_S]) camera.processKeyboard(.BACKWARD, deltaTime);
        if (keys[c.SDL_SCANCODE_A]) camera.processKeyboard(.LEFT, deltaTime);
        if (keys[c.SDL_SCANCODE_D]) camera.processKeyboard(.RIGHT, deltaTime);

        // Projection
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &w, &h);
        const aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
        const proj = Mat4.perspective(std.math.degreesToRadians(45.0), aspect, 0.1, 100.0);
        // View (Camera)
        const view = camera.getViewMatrix();

        // Model (Identity)
        const model = Mat4.identity();

        const mvp = Mat4.multiply(proj, Mat4.multiply(view, model));

        // Render
        c.glClearColor(0.2, 0.3, 0.3, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);

        c.glUseProgram().?(shader_program);

        c.glUniformMatrix4fv().?(transform_loc, 1, c.GL_TRUE, &mvp.data[0][0]);

        c.glBindVertexArray().?(vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 36);

        _ = c.SDL_GL_SwapWindow(window);
    }
}

fn createShaderProgram() !c.GLuint {
    // Helper to compile single shader
    const compile = struct {
        fn func(shader_type: c.GLenum, source: [*c]const u8) !c.GLuint {
            const shader = c.glCreateShader().?(shader_type);
            c.glShaderSource().?(shader, 1, &source, null);
            c.glCompileShader().?(shader);

            var success: c.GLint = undefined;
            c.glGetShaderiv().?(shader, c.GL_COMPILE_STATUS, &success);
            if (success == 0) return error.ShaderCompileFailed;

            return shader;
        }
    }.func;

    const vert = try compile(c.GL_VERTEX_SHADER, vertex_shader_src);
    const frag = try compile(c.GL_FRAGMENT_SHADER, fragment_shader_src);

    const prog = c.glCreateProgram().?();
    c.glAttachShader().?(prog, vert);
    c.glAttachShader().?(prog, frag);
    c.glLinkProgram().?(prog);

    c.glDeleteShader().?(vert);
    c.glDeleteShader().?(frag);

    return prog;
}
