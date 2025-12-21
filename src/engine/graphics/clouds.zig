//! Cloud system - 2D layered clouds with noise-based rendering
//! Implements clouds.md spec (v1: cheap, stable, Minecraft-like)

const std = @import("std");
const c = @import("../../c.zig").c;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Shader = @import("shader.zig").Shader;

/// Cloud system with projected plane rendering
pub const Clouds = struct {
    // Cloud layer parameters
    cloud_height: f32 = 160.0,
    cloud_thickness: f32 = 12.0,
    cloud_coverage: f32 = 0.5,
    cloud_scale: f32 = 1.0 / 64.0,
    mesh_size: f32 = 10000.0,

    // Wind
    wind_dir: [2]f32 = .{ 1.0, 0.2 },
    wind_speed: f32 = 2.0,
    wind_offset: [2]f32 = .{ 0.0, 0.0 },

    // Rendering
    enabled: bool = true,
    cloud_shader: ?Shader = null,
    cloud_vao: c.GLuint = 0,
    cloud_vbo: c.GLuint = 0,
    cloud_ebo: c.GLuint = 0,

    // Cloud colors
    base_color: Vec3 = Vec3.init(1.0, 1.0, 1.0),
    shadow_color: Vec3 = Vec3.init(0.8, 0.8, 0.85),

    pub fn init() !Clouds {
        var clouds = Clouds{};
        try clouds.initCloudMesh();
        try clouds.initCloudShader();
        return clouds;
    }

    pub fn deinit(self: *Clouds) void {
        if (self.cloud_vao != 0) c.glDeleteVertexArrays().?(1, &self.cloud_vao);
        if (self.cloud_vbo != 0) c.glDeleteBuffers().?(1, &self.cloud_vbo);
        if (self.cloud_ebo != 0) c.glDeleteBuffers().?(1, &self.cloud_ebo);
        if (self.cloud_shader) |*shader| shader.deinit();
    }

    pub fn update(self: *Clouds, delta_time: f32) void {
        self.wind_offset[0] += self.wind_dir[0] * self.wind_speed * delta_time;
        self.wind_offset[1] += self.wind_dir[1] * self.wind_speed * delta_time;
    }

    fn initCloudMesh(self: *Clouds) !void {
        const size = self.mesh_size;

        const vertices = [_]f32{
            -size, -size,
            size,  -size,
            size,  size,
            -size, size,
        };

        const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

        c.glGenVertexArrays().?(1, &self.cloud_vao);
        c.glGenBuffers().?(1, &self.cloud_vbo);
        c.glGenBuffers().?(1, &self.cloud_ebo);

        if (self.cloud_vao == 0 or self.cloud_vbo == 0 or self.cloud_ebo == 0) return error.OpenGLInitializationFailed;

        c.glBindVertexArray().?(self.cloud_vao);

        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, self.cloud_vbo);
        c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);

        c.glBindBuffer().?(c.GL_ELEMENT_ARRAY_BUFFER, self.cloud_ebo);
        c.glBufferData().?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(indices)), &indices, c.GL_STATIC_DRAW);

        c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
        c.glEnableVertexAttribArray().?(0);

        c.glBindVertexArray().?(0);
    }

    fn initCloudShader(self: *Clouds) !void {
        self.cloud_shader = try Shader.initSimple(cloud_vertex_src, cloud_fragment_src);
    }

    pub fn render(
        self: *Clouds,
        cam_pos: Vec3,
        view_proj: *const [4][4]f32,
        sun_dir: Vec3,
        sun_intensity: f32,
        fog_color: Vec3,
        fog_density: f32,
    ) void {
        if (!self.enabled) return;
        const shader = self.cloud_shader orelse return;

        c.glDepthMask(c.GL_FALSE); // Don't write to depth
        c.glDisable(c.GL_CULL_FACE);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        // Proper depth testing to ensure mountains hide clouds
        c.glDepthFunc(c.GL_GEQUAL);
        defer c.glDepthMask(c.GL_TRUE);

        shader.use();
        shader.setVec3("uCameraPos", cam_pos.x, cam_pos.y, cam_pos.z);
        shader.setFloat("uCloudHeight", self.cloud_height);
        shader.setFloat("uCloudCoverage", self.cloud_coverage);
        shader.setFloat("uCloudScale", self.cloud_scale);
        shader.setFloat("uWindOffsetX", self.wind_offset[0]);
        shader.setFloat("uWindOffsetZ", self.wind_offset[1]);
        shader.setVec3("uSunDir", sun_dir.x, sun_dir.y, sun_dir.z);
        shader.setFloat("uSunIntensity", sun_intensity);
        shader.setVec3("uBaseColor", self.base_color.x, self.base_color.y, self.base_color.z);
        shader.setVec3("uFogColor", fog_color.x, fog_color.y, fog_color.z);
        shader.setFloat("uFogDensity", fog_density);
        shader.setMat4("uViewProj", view_proj);

        c.glBindVertexArray().?(self.cloud_vao);
        c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
        c.glBindVertexArray().?(0);
    }

    /// Get cloud shadow factor at a world position (for terrain shading)
    pub fn getCloudShadowParams(self: *const Clouds) struct {
        wind_offset_x: f32,
        wind_offset_z: f32,
        cloud_scale: f32,
        cloud_coverage: f32,
        cloud_height: f32,
    } {
        return .{
            .wind_offset_x = self.wind_offset[0],
            .wind_offset_z = self.wind_offset[1],
            .cloud_scale = self.cloud_scale,
            .cloud_coverage = self.cloud_coverage,
            .cloud_height = self.cloud_height,
        };
    }
};

// Cloud vertex shader
const cloud_vertex_src =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\
    \\out vec3 vWorldPos;
    \\out float vDistance;
    \\
    \\uniform vec3 uCameraPos;
    \\uniform float uCloudHeight;
    \\uniform mat4 uViewProj;
    \\
    \\void main() {
    \\    // Position cloud plane centered on camera XZ, at cloud height
    \\    // We use camera-relative coordinates for the projection
    \\    vec3 relPos = vec3(
    \\        aPos.x,
    \\        uCloudHeight - uCameraPos.y,
    \\        aPos.y
    \\    );
    \\    
    \\    vWorldPos = vec3(aPos.x + uCameraPos.x, uCloudHeight, aPos.y + uCameraPos.z);
    \\    vDistance = length(relPos);
    \\    
    \\    gl_Position = uViewProj * vec4(relPos, 1.0);
    \\}
;

// Cloud fragment shader with blocky FBM noise
const cloud_fragment_src =
    \\#version 330 core
    \\in vec3 vWorldPos;
    \\in float vDistance;
    \\out vec4 FragColor;
    \\
    \\uniform vec3 uCameraPos;
    \\uniform float uCloudHeight;
    \\uniform float uCloudThickness;
    \\uniform float uCloudCoverage;
    \\uniform float uCloudScale;
    \\uniform float uWindOffsetX;
    \\uniform float uWindOffsetZ;
    \\uniform vec3 uSunDir;
    \\uniform float uSunIntensity;
    \\uniform vec3 uBaseColor;
    \\uniform vec3 uShadowColor;
    \\uniform vec3 uFogColor;
    \\uniform float uFogDensity;
    \\
    \\// Hash function for noise
    \\float hash(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\// 2D noise
    \\float noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    
    \\    float a = hash(i);
    \\    float b = hash(i + vec2(1.0, 0.0));
    \\    float c = hash(i + vec2(0.0, 1.0));
    \\    float d = hash(i + vec2(1.0, 1.0));
    \\    
    \\    vec2 u = f * f * (3.0 - 2.0 * f);
    \\    
    \\    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    \\}
    \\
    \\// Fractal Brownian Motion for cloud shapes
    \\float fbm(vec2 p, int octaves) {
    \\    float value = 0.0;
    \\    float amplitude = 0.5;
    \\    float frequency = 1.0;
    \\    
    \\    for (int i = 0; i < octaves; i++) {
    \\        value += amplitude * noise(p * frequency);
    \\        amplitude *= 0.5;
    \\        frequency *= 2.0;
    \\    }
    \\    
    \\    return value;
    \\}
    \\
    \\void main() {
    \\    // Minecraft style: Pixelate the sampling position
    \\    float cloudBlockSize = 12.0; 
    \\    vec2 worldXZ = vWorldPos.xz + vec2(uWindOffsetX, uWindOffsetZ);
    \\    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    \\    vec2 samplePos = pixelPos * uCloudScale;
    \\    
    \\    // Use a sharp noise
    \\    float cloudValue = fbm(samplePos, 3);
    \\    
    \\    // Threshold for solid clouds
    \\    float threshold = 1.0 - uCloudCoverage;
    \\    if (cloudValue < threshold) discard;
    \\    
    \\    // Day/night color blending
    \\    vec3 nightTint = vec3(0.1, 0.12, 0.2);
    \\    vec3 dayColor = uBaseColor;
    \\    vec3 cloudColor = mix(nightTint, dayColor, uSunIntensity);
    \\    
    \\    // Apply lighting
    \\    float lightFactor = clamp(uSunDir.y, 0.0, 1.0);
    \\    cloudColor *= (0.7 + 0.3 * lightFactor);
    \\    
    \\    // Distance fade (fog blending)
    \\    float fogFactor = 1.0 - exp(-vDistance * uFogDensity * 0.4);
    \\    cloudColor = mix(cloudColor, uFogColor, fogFactor);
    \\    
    \\    float alpha = 1.0 * (1.0 - fogFactor * 0.8);
    \\    
    \\    // Camera altitude fade
    \\    float altitudeDiff = uCameraPos.y - uCloudHeight;
    \\    if (altitudeDiff > 0.0) {
    \\        alpha *= 1.0 - smoothstep(10.0, 400.0, altitudeDiff);
    \\    }
    \\    
    \\    FragColor = vec4(cloudColor, alpha);
    \\}
;
