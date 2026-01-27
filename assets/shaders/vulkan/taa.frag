#version 450

// TAA Resolve Shader
// Expects inputs in the following formats:
// - texColor: HDR R16G16B16A16_SFLOAT or B10G11R11_UFLOAT
// - texHistory: Same as texColor
// - texVelocity: R16G16_SFLOAT (UV space motion vectors)

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev;
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset;
    vec4 params;
    vec4 lighting;
    vec4 cloud_params;
    vec4 pbr_params;
    vec4 volumetric_params;
    vec4 viewport_size;
} global;

layout(set = 1, binding = 0) uniform sampler2D texColor;
layout(set = 1, binding = 1) uniform sampler2D texHistory;
layout(set = 1, binding = 2) uniform sampler2D texVelocity;

layout(push_constant) uniform PushConstants {
    vec2 jitter_offset;
    float feedback_min;
    float feedback_max;
} pc;

vec3 clip_aabb(vec3 q, vec3 aabb_min, vec3 aabb_max) {
    vec3 p_clip = 0.5 * (aabb_max + aabb_min);
    vec3 e_clip = 0.5 * (aabb_max - aabb_min) + 0.00000001;
    vec3 v_clip = q - p_clip;
    vec3 v_unit = v_clip / e_clip;
    vec3 a_unit = abs(v_unit);
    float ma_unit = max(a_unit.x, max(a_unit.y, a_unit.z));

    if (ma_unit > 1.0)
        return p_clip + v_clip / ma_unit;
    else
        return q;
}

void main() {
    vec2 uv = inUV;
    
    // 1. Get Velocity
    vec2 velocity = texture(texVelocity, uv).xy;
    
    // 2. Reproject
    vec2 prev_uv = uv - velocity;
    
    // 3. Sample Current Color
    vec3 color_center = texture(texColor, uv).rgb;
    
    // 5x5 Neighborhood for variance-based clipping (to reduce ghosting in foliage)
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    
    vec2 texel_size = 1.0 / global.viewport_size.xy;
    
    // Use a 5x5 box neighborhood (25 samples) for high quality statistics
    for(int x = -2; x <= 2; x++) {
        for(int y = -2; y <= 2; y++) {
            vec3 neighbor = texture(texColor, uv + vec2(x, y) * texel_size).rgb;
            m1 += neighbor;
            m2 += neighbor * neighbor;
        }
    }
    
    vec3 mu = m1 / 25.0;
    vec3 sigma = sqrt(max(vec3(0.0), m2 / 25.0 - mu * mu));
    
    // Variance-based clipping
    float gamma = 1.25; // Slightly tighter for 5x5
    vec3 color_min = mu - gamma * sigma;
    vec3 color_max = mu + gamma * sigma;
    
    // 4. Sample History
    if(prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
        outColor = vec4(color_center, 1.0);
        return;
    }
    
    vec3 history = texture(texHistory, prev_uv).rgb;
    
    // 5. Clip History
    history = clip_aabb(history, color_min, color_max);
    
    // 6. Blend
    float velocity_mag = length(velocity * global.viewport_size.xy);
    float blend_factor = mix(pc.feedback_max, pc.feedback_min, clamp(velocity_mag / 2.0, 0.0, 1.0));
    
    vec3 result = mix(color_center, history, blend_factor);
    
    outColor = vec4(result, 1.0);
}
