#version 450

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uHDRBuffer;
layout(set = 0, binding = 2) uniform sampler2D uBloomTexture;

layout(push_constant) uniform PostProcessParams {
    float bloomEnabled;   // 0.0 = disabled, 1.0 = enabled
    float bloomIntensity; // Final bloom blend intensity
} postParams;

layout(set = 0, binding = 1) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset;
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    vec4 cloud_params;
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation
    vec4 volumetric_params;
    vec4 viewport_size;
} global;

// AgX Log2 encoding for HDR input
vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

vec3 agx(vec3 val) {
    const mat3 agx_mat = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104
    );
    
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    
    // Input transform (sRGB to AgX working space)
    val = agx_mat * val;
    
    // Log2 encoding
    val = clamp(log2(max(val, vec3(1e-6))), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    
    // Apply sigmoid contrast curve
    val = agxDefaultContrastApprox(val);
    
    return val;
}

vec3 agxEotf(vec3 val) {
    const mat3 agx_mat_inv = mat3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116
    );
    
    // Inverse input transform
    val = agx_mat_inv * val;
    
    // sRGB IEC 61966-2-1 2.2 Exponent Reference EOTF Display
    return pow(max(val, vec3(0.0)), vec3(2.2));
}

vec3 agxLook(vec3 val, float saturation, float contrast) {
    float luma = dot(val, vec3(0.2126, 0.7152, 0.0722));
    
    // Saturation adjustment
    val = luma + saturation * (val - luma);
    
    // Contrast adjustment around mid-gray
    val = 0.5 + (0.5 + contrast * 0.5) * (val - 0.5);
    
    return val;
}

vec3 agxToneMap(vec3 color, float exposure, float saturation) {
    color *= exposure;
    color = max(color, vec3(0.0));
    color = agx(color);
    color = agxLook(color, saturation, 1.2);
    color = agxEotf(color);
    return clamp(color, 0.0, 1.0);
}

vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec3 hdrColor = texture(uHDRBuffer, inUV).rgb;
    
    // Add bloom contribution before tonemapping (in HDR space)
    if (postParams.bloomEnabled > 0.5) {
        vec3 bloom = texture(uBloomTexture, inUV).rgb;
        hdrColor += bloom * postParams.bloomIntensity;
    }
    
    vec3 color;
    // Tone mapper selection: 0.0 (default) = AgX, 1.0 = AgX, 2.0 = ACES
    // We use pbr_params.w as a spare field for this.
    if (global.pbr_params.w < 1.5) {
        color = agxToneMap(hdrColor, global.pbr_params.y, global.pbr_params.z);
    } else {
        color = ACESFilm(hdrColor * global.pbr_params.y);
    }
    
    outColor = vec4(color, 1.0);
}
