//! Atmosphere system - day/night cycle, sun/moon, sky rendering, fog
//! Implements atmosphere-lighting.md spec

const std = @import("std");
const c = @import("../../c.zig").c;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Shader = @import("shader.zig").Shader;

/// Time of day constants
pub const TICKS_PER_DAY: u32 = 24000;
pub const DAWN_START: f32 = 0.20;
pub const DAWN_END: f32 = 0.30;
pub const DUSK_START: f32 = 0.70;
pub const DUSK_END: f32 = 0.80;

/// Smoothstep for smooth transitions
fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Atmosphere system managing day/night cycle, sun/moon, and sky rendering
pub const Atmosphere = struct {
    // Time state
    world_ticks: u64 = 0,
    tick_accumulator: f32 = 0.0,
    time_scale: f32 = 1.0,

    // Computed values (updated each frame)
    time_of_day: f32 = 0.25, // Start at sunrise
    sun_intensity: f32 = 1.0,
    moon_intensity: f32 = 0.0,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    moon_dir: Vec3 = Vec3.init(0, -1, 0),

    // Sky colors
    sky_color: Vec3 = Vec3.init(0.5, 0.7, 1.0),
    horizon_color: Vec3 = Vec3.init(0.8, 0.85, 0.95),
    fog_color: Vec3 = Vec3.init(0.6, 0.75, 0.95),

    // Ambient lighting
    ambient_intensity: f32 = 0.3,

    // Sky shader
    sky_shader: ?Shader = null,
    sky_vao: c.GLuint = 0,
    sky_vbo: c.GLuint = 0,

    // Fog parameters
    fog_density: f32 = 0.0015,
    fog_enabled: bool = true,

    // Sun orbit tilt (radians)
    orbit_tilt: f32 = 0.35, // ~20 degrees

    pub fn init() Atmosphere {
        var atmo = Atmosphere{};
        atmo.initSkyMesh();
        atmo.initSkyShader() catch {
            // Sky shader optional - will use fallback
        };
        return atmo;
    }

    pub fn deinit(self: *Atmosphere) void {
        if (self.sky_vao != 0) c.glDeleteVertexArrays().?(1, &self.sky_vao);
        if (self.sky_vbo != 0) c.glDeleteBuffers().?(1, &self.sky_vbo);
        if (self.sky_shader) |*shader| shader.deinit();
    }

    /// Update atmosphere state based on elapsed time
    pub fn update(self: *Atmosphere, delta_time: f32) void {
        // Advance world time with accumulator for sub-tick precision
        self.tick_accumulator += delta_time * 20.0 * self.time_scale; // 20 ticks/sec base
        if (self.tick_accumulator >= 1.0) {
            const ticks_delta: u64 = @intFromFloat(self.tick_accumulator);
            self.world_ticks +%= ticks_delta;
            self.tick_accumulator -= @floatFromInt(ticks_delta);
        }

        // Calculate time of day [0, 1)
        const day_ticks = self.world_ticks % TICKS_PER_DAY;
        self.time_of_day = @as(f32, @floatFromInt(day_ticks)) / @as(f32, @floatFromInt(TICKS_PER_DAY));

        // Update sun/moon directions
        self.updateCelestialBodies();

        // Update intensities
        self.updateIntensities();

        // Update colors
        self.updateColors();
    }

    /// Set time of day directly (0-1)
    pub fn setTimeOfDay(self: *Atmosphere, time: f32) void {
        self.world_ticks = @intFromFloat(time * @as(f32, @floatFromInt(TICKS_PER_DAY)));
        self.time_of_day = time;
        self.tick_accumulator = 0;
        self.updateCelestialBodies();
        self.updateIntensities();
        self.updateColors();
    }

    /// Get current time as hours (0-24)
    pub fn getHours(self: *const Atmosphere) f32 {
        return self.time_of_day * 24.0;
    }

    fn updateCelestialBodies(self: *Atmosphere) void {
        // Sun angle: 0 at midnight, π at noon
        // We use standard trigonometric circle where 0 is right (East), PI/2 is Up.
        // But we want 0.0 (Midnight) to be Down (-Y).
        // Y = -cos(angle).
        // X = sin(angle).
        const sun_angle = self.time_of_day * std.math.tau;

        // Sun direction with orbit tilt
        // Rotate around X axis (east-west movement) with tilt
        const cos_angle = @cos(sun_angle);
        const sin_angle = @sin(sun_angle);
        const cos_tilt = @cos(self.orbit_tilt);
        const sin_tilt = @sin(self.orbit_tilt);

        // Sun moves from east (sunrise) to west (sunset)
        // Y is up, Z is north
        // We invert cos_angle so that at angle 0 (midnight), Y is -1 (Down)
        self.sun_dir = Vec3.init(
            sin_angle, // East-West
            -cos_angle * cos_tilt, // Up-Down (main) - Inverted for correct phase
            -cos_angle * sin_tilt, // North-South (tilt)
        ).normalize();

        // Moon is opposite
        self.moon_dir = self.sun_dir.scale(-1);
    }

    fn updateIntensities(self: *Atmosphere) void {
        const t = self.time_of_day;

        // Sun intensity: peak at noon (0.5), zero at night
        // Ramp up during dawn (0.20-0.30), ramp down during dusk (0.70-0.80)
        if (t < DAWN_START) {
            self.sun_intensity = 0;
        } else if (t < DAWN_END) {
            self.sun_intensity = smoothstep(DAWN_START, DAWN_END, t);
        } else if (t < DUSK_START) {
            self.sun_intensity = 1.0;
        } else if (t < DUSK_END) {
            self.sun_intensity = 1.0 - smoothstep(DUSK_START, DUSK_END, t);
        } else {
            self.sun_intensity = 0;
        }

        // Moon intensity: inverse of sun with lower max
        self.moon_intensity = (1.0 - self.sun_intensity) * 0.15;

        // Ambient: brighter during day
        const day_ambient: f32 = 0.30;
        const night_ambient: f32 = 0.08;
        self.ambient_intensity = std.math.lerp(night_ambient, day_ambient, self.sun_intensity);
    }

    fn updateColors(self: *Atmosphere) void {
        const t = self.time_of_day;

        // Base colors
        const day_sky = Vec3.init(0.4, 0.65, 1.0);
        const day_horizon = Vec3.init(0.7, 0.8, 0.95);
        const night_sky = Vec3.init(0.02, 0.02, 0.08);
        const night_horizon = Vec3.init(0.05, 0.05, 0.12);
        const dawn_sky = Vec3.init(0.4, 0.4, 0.6);
        const dawn_horizon = Vec3.init(1.0, 0.5, 0.3);
        const dusk_sky = Vec3.init(0.35, 0.25, 0.5);
        const dusk_horizon = Vec3.init(1.0, 0.4, 0.2);

        // Blend based on time of day
        if (t < DAWN_START) {
            // Night
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
        } else if (t < DAWN_END) {
            // Dawn transition
            const blend = smoothstep(DAWN_START, DAWN_END, t);
            self.sky_color = lerpVec3(night_sky, dawn_sky, blend);
            self.horizon_color = lerpVec3(night_horizon, dawn_horizon, blend);
        } else if (t < 0.35) {
            // Dawn to day
            const blend = smoothstep(DAWN_END, 0.35, t);
            self.sky_color = lerpVec3(dawn_sky, day_sky, blend);
            self.horizon_color = lerpVec3(dawn_horizon, day_horizon, blend);
        } else if (t < DUSK_START) {
            // Day
            self.sky_color = day_sky;
            self.horizon_color = day_horizon;
        } else if (t < 0.75) {
            // Day to dusk
            const blend = smoothstep(DUSK_START, 0.75, t);
            self.sky_color = lerpVec3(day_sky, dusk_sky, blend);
            self.horizon_color = lerpVec3(day_horizon, dusk_horizon, blend);
        } else if (t < DUSK_END) {
            // Dusk transition
            const blend = smoothstep(0.75, DUSK_END, t);
            self.sky_color = lerpVec3(dusk_sky, night_sky, blend);
            self.horizon_color = lerpVec3(dusk_horizon, night_horizon, blend);
        } else {
            // Night
            self.sky_color = night_sky;
            self.horizon_color = night_horizon;
        }

        // Fog color matches horizon
        self.fog_color = self.horizon_color;

        // Increase fog at night
        self.fog_density = std.math.lerp(0.002, 0.0012, self.sun_intensity);
    }

    fn initSkyMesh(self: *Atmosphere) void {
        // Fullscreen triangle (covers screen with single triangle)
        const vertices = [_]f32{
            -1.0, -1.0, // bottom-left
            3.0, -1.0, // bottom-right (extends past screen)
            -1.0, 3.0, // top-left (extends past screen)
        };

        c.glGenVertexArrays().?(1, &self.sky_vao);
        c.glGenBuffers().?(1, &self.sky_vbo);

        c.glBindVertexArray().?(self.sky_vao);
        c.glBindBuffer().?(c.GL_ARRAY_BUFFER, self.sky_vbo);
        c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_STATIC_DRAW);

        c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
        c.glEnableVertexAttribArray().?(0);
        c.glBindVertexArray().?(0);
    }

    fn initSkyShader(self: *Atmosphere) !void {
        self.sky_shader = try Shader.initSimple(sky_vertex_src, sky_fragment_src);
    }

    /// Render the sky (call before terrain, with depth write disabled)
    /// Pass camera forward, right, up vectors and FOV info for correct ray direction
    pub fn renderSky(self: *Atmosphere, cam_forward: Vec3, cam_right: Vec3, cam_up: Vec3, aspect: f32, fov: f32) void {
        const shader = self.sky_shader orelse return;

        // Disable depth write, keep depth test
        c.glDepthMask(c.GL_FALSE);
        defer c.glDepthMask(c.GL_TRUE);

        const tan_half_fov = @tan(fov / 2.0);

        shader.use();
        shader.setVec3("uCamForward", cam_forward.x, cam_forward.y, cam_forward.z);
        shader.setVec3("uCamRight", cam_right.x, cam_right.y, cam_right.z);
        shader.setVec3("uCamUp", cam_up.x, cam_up.y, cam_up.z);
        shader.setFloat("uAspect", aspect);
        shader.setFloat("uTanHalfFov", tan_half_fov);
        shader.setVec3("uSunDir", self.sun_dir.x, self.sun_dir.y, self.sun_dir.z);
        shader.setVec3("uSkyColor", self.sky_color.x, self.sky_color.y, self.sky_color.z);
        shader.setVec3("uHorizonColor", self.horizon_color.x, self.horizon_color.y, self.horizon_color.z);
        shader.setFloat("uSunIntensity", self.sun_intensity);
        shader.setFloat("uMoonIntensity", self.moon_intensity);
        shader.setFloat("uTime", self.time_of_day);

        c.glBindVertexArray().?(self.sky_vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindVertexArray().?(0);
    }

    /// Get sky factor for terrain lighting (0 at night, 1 at day)
    pub fn getSkyLightFactor(self: *const Atmosphere) f32 {
        return @max(self.sun_intensity, self.moon_intensity);
    }
};

fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return Vec3.init(
        std.math.lerp(a.x, b.x, t),
        std.math.lerp(a.y, b.y, t),
        std.math.lerp(a.z, b.z, t),
    );
}

// Sky vertex shader - compute view ray from camera vectors
const sky_vertex_src =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\out vec3 vWorldDir;
    \\uniform vec3 uCamForward;
    \\uniform vec3 uCamRight;
    \\uniform vec3 uCamUp;
    \\uniform float uAspect;
    \\uniform float uTanHalfFov;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.9999, 1.0);
    \\    // Compute view ray direction from screen coordinates
    \\    vec3 rayDir = uCamForward
    \\                + uCamRight * aPos.x * uAspect * uTanHalfFov
    \\                + uCamUp * aPos.y * uTanHalfFov;
    \\    vWorldDir = rayDir;
    \\}
;

// Sky fragment shader with sun, moon, stars, and gradient
const sky_fragment_src =
    \\#version 330 core
    \\in vec3 vWorldDir;
    \\out vec4 FragColor;
    \\
    \\uniform vec3 uSunDir;
    \\uniform vec3 uSkyColor;
    \\uniform vec3 uHorizonColor;
    \\uniform float uSunIntensity;
    \\uniform float uMoonIntensity;
    \\uniform float uTime;
    \\
    \\// Hash functions for stars
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\vec2 hash22(vec2 p) {
    \\    float n = hash21(p);
    \\    return vec2(n, hash21(p + n));
    \\}
    \\
    \\// Stable star field using spherical coordinates
    \\float stars(vec3 dir) {
    \\    // Convert to spherical coordinates for uniform distribution
    \\    float theta = atan(dir.z, dir.x); // azimuth [-pi, pi]
    \\    float phi = asin(clamp(dir.y, -1.0, 1.0)); // elevation [-pi/2, pi/2]
    \\    
    \\    // Create grid in angular space (higher density = more stars)
    \\    vec2 gridCoord = vec2(theta * 15.0, phi * 30.0);
    \\    vec2 cell = floor(gridCoord);
    \\    vec2 cellFrac = fract(gridCoord);
    \\    
    \\    float brightness = 0.0;
    \\    
    \\    // Check current cell and neighbors for smooth transitions
    \\    for (int dy = -1; dy <= 1; dy++) {
    \\        for (int dx = -1; dx <= 1; dx++) {
    \\            vec2 neighbor = cell + vec2(float(dx), float(dy));
    \\            
    \\            // Hash to determine if this cell has a star
    \\            float starChance = hash21(neighbor);
    \\            if (starChance > 0.92) {
    \\                // Star position within cell
    \\                vec2 starPos = hash22(neighbor * 1.7);
    \\                vec2 offset = vec2(float(dx), float(dy)) + starPos - cellFrac;
    \\                float dist = length(offset);
    \\                
    \\                // Star brightness based on distance (point-like)
    \\                float starBright = smoothstep(0.08, 0.0, dist);
    \\                
    \\                // Vary star brightness
    \\                starBright *= 0.5 + 0.5 * hash21(neighbor * 3.14);
    \\                
    \\                // Twinkle effect
    \\                float twinkle = 0.7 + 0.3 * sin(hash21(neighbor) * 50.0 + uTime * 8.0);
    \\                starBright *= twinkle;
    \\                
    \\                brightness = max(brightness, starBright);
    \\            }
    \\        }
    \\    }
    \\    
    \\    return brightness;
    \\}
    \\
    \\void main() {
    \\    vec3 dir = normalize(vWorldDir);
    \\    
    \\    // Sky gradient based on vertical angle
    \\    float horizon = 1.0 - abs(dir.y);
    \\    horizon = pow(horizon, 1.5);
    \\    vec3 sky = mix(uSkyColor, uHorizonColor, horizon);
    \\    
    \\    // Sun disc
    \\    float sunDot = dot(dir, uSunDir);
    \\    float sunDisc = smoothstep(0.9995, 0.9999, sunDot);
    \\    vec3 sunColor = vec3(1.0, 0.95, 0.8);
    \\    
    \\    // Sun glow
    \\    float sunGlow = pow(max(sunDot, 0.0), 8.0) * 0.5;
    \\    sunGlow += pow(max(sunDot, 0.0), 64.0) * 0.3;
    \\    
    \\    // Moon disc
    \\    float moonDot = dot(dir, -uSunDir);
    \\    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    \\    vec3 moonColor = vec3(0.9, 0.9, 1.0);
    \\    
    \\    // Stars (visible at night, fade during dawn/dusk)
    \\    float starIntensity = 0.0;
    \\    if (uSunIntensity < 0.3 && dir.y > 0.0) {
    \\        float nightFactor = 1.0 - uSunIntensity * 3.33;
    \\        starIntensity = stars(dir) * nightFactor * 1.5;
    \\    }
    \\    
    \\    // Combine
    \\    vec3 finalColor = sky;
    \\    finalColor += sunGlow * uSunIntensity * vec3(1.0, 0.8, 0.4);
    \\    finalColor += sunDisc * sunColor * uSunIntensity;
    \\    finalColor += moonDisc * moonColor * uMoonIntensity * 3.0;
    \\    finalColor += vec3(starIntensity);
    \\    
    \\    FragColor = vec4(finalColor, 1.0);
    \\}
;
