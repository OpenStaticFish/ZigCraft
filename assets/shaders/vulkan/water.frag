#version 450
#extension GL_GOOGLE_include_directive : require

#include "distance_appearance.glsl"
#include "lod_ownership.glsl"

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in vec3 vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 8) in float vViewDepth;
layout(location = 9) in vec4 vClipPos;
layout(location = 10) in float vMaskRadius;
layout(location = 11) in float vLODFade;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev;
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 reserved0;
    vec4 params;
    vec4 lighting;
    vec4 render_flags;
    vec4 shadow_params;
    vec4 pbr_params;
    vec4 volumetric_params;
    vec4 viewport_size;
    vec4 lpv_params;
    vec4 lpv_origin;
} global;

#include "lod_water_appearance.glsl"

layout(set = 0, binding = 1) uniform sampler2D uTexture;
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;
layout(set = 0, binding = 14) uniform sampler2D uReflection;
layout(set = 0, binding = 15) uniform sampler2D uSceneDepth;

const float PI = 3.14159265359;
const float WATER_LEVEL = 64.0;
const float F0_WATER = 0.02; // Fresnel reflectance at normal incidence for water (dielectric)

const vec3 WATER_SHALLOW = vec3(0.20, 0.58, 0.86);
const vec3 WATER_MID = vec3(0.08, 0.34, 0.70);
const vec3 WATER_DEEP = vec3(0.02, 0.12, 0.42);
const float WATER_MAX_DEPTH = 14.0;
// Matches the two-chunk overlap reserved by LODConfig.calculateMaskRadius().
const float LOD_MASK_BLEND_WIDTH = 32.0;

const float WAVE_AMPLITUDE = 0.5;
const float WAVE_FREQUENCY = 1.5;
const float WAVE_SPEED = 0.8;

vec2 SampleSphericalMap(vec3 v) {
    vec3 n = normalize(v);
    float phi = atan(n.z, n.x);
    float theta = acos(clamp(n.y, -1.0, 1.0));
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

float schlickFresnel(float cos_theta, float F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cos_theta, 5.0);
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float lodTransitionNoise(vec2 worldXZ) {
    vec2 p = floor(worldXZ * 0.25);
    p = fract(p * vec2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
    float sum = 0.0;
    float amp = 0.5;
    mat2 rot = mat2(0.80, -0.60, 0.60, 0.80);

    for (int i = 0; i < 4; i++) {
        sum += valueNoise(p) * amp;
        p = rot * p * 2.03 + vec2(11.7, -5.4);
        amp *= 0.5;
    }

    return sum;
}

vec3 fbmNormal(vec2 p, float time) {
    vec2 driftA = vec2(time * 0.045, -time * 0.030);
    vec2 driftB = vec2(-time * 0.026, time * 0.038);
    float e = 0.08;

    float h = fbm(p + driftA) * 0.62 + fbm(p * 1.9 + driftB) * 0.38;
    float hx = fbm(p + vec2(e, 0.0) + driftA) * 0.62 + fbm((p + vec2(e, 0.0)) * 1.9 + driftB) * 0.38;
    float hy = fbm(p + vec2(0.0, e) + driftA) * 0.62 + fbm((p + vec2(0.0, e)) * 1.9 + driftB) * 0.38;

    return normalize(vec3((h - hx) * 2.4, 1.0, (h - hy) * 2.4));
}

float linearizeDepthReverseZ(float depth, float near, float far) {
    return (near * far) / (near + depth * (far - near));
}

vec2 atlasUV(int tileID, vec2 texCoord) {
    vec2 tiledUV = fract(texCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    return (vec2(mod(float(tileID), 16.0), floor(float(tileID) / 16.0)) + tiledUV) * (1.0 / 16.0);
}

void main() {
    discardOutsideLODOwnership();
    bool isLOD = vTileID < 0 || abs(vMaskRadius) > 0.0;
    float lodMaskAlpha = 1.0;
    if (abs(vMaskRadius) >= 1.0) {
        // A negative radius carries the outer edge of the ready detail disk;
        // begin water's translucent handoff two chunks inside that edge.
        bool readyDiskMask = vMaskRadius < 0.0;
        float maskRadius = abs(vMaskRadius);
        if (readyDiskMask) maskRadius = max(maskRadius - LOD_MASK_BLEND_WIDTH, 0.0);
        float maskDistance = length(vFragPosWorld.xz);
        if (maskDistance < maskRadius) discard;
        // Fade the translucent LOD underlay in across the detailed-water
        // overlap instead of changing its contribution at a hard circle.
        lodMaskAlpha = smoothstep(maskRadius, maskRadius + LOD_MASK_BLEND_WIDTH, maskDistance);
    }
    if (isLOD) {
        FragColor = lodWaterAppearance(vColor, vNormal, vFragPosWorld, vSkyLight, vBlockLight);
        FragColor.a *= lodMaskAlpha;
        return;
    }
    float time = global.params.x;

    vec3 base_normal = normalize(vNormal);
    // Keep voxel water top faces lit like a block surface instead of flipping
    // with the camera side; underwater rendering can tune this separately.
    if (base_normal.y < 0.0) {
        base_normal = -base_normal;
    }

    vec3 V = normalize(-vFragPosWorld);

    vec3 noise_normal = fbmNormal(vFragPosWorld.xz * 0.10, time);
    vec3 N = normalize(base_normal + noise_normal * 0.16);

    float NdotV = max(dot(N, V), 0.0);

    vec3 L = normalize(global.sun_dir.xyz);
    float NdotL = max(dot(N, L), 0.0);

    float fresnel = schlickFresnel(NdotV, F0_WATER);
    fresnel = clamp(fresnel * 0.55, 0.01, 0.28);

    vec2 screenUV = vClipPos.xy / vClipPos.w * 0.5 + 0.5;
    screenUV.y = 1.0 - screenUV.y;

    vec3 R = reflect(-V, N);
    vec2 envUV = SampleSphericalMap(R);
    vec3 envColor = textureLod(uEnvMap, envUV, 4.0).rgb;

    vec2 reflectUV = screenUV + N.xz * 0.004;
    reflectUV = clamp(reflectUV, 0.001, 0.999);
    vec3 reflectionColor = texture(uReflection, reflectUV).rgb;

    float scene_depth_raw = texture(uSceneDepth, screenUV).r;
    float scene_depth_linear = linearizeDepthReverseZ(scene_depth_raw, 0.5, 10000.0);
    float surface_depth = -vViewDepth;
    float water_depth = scene_depth_linear - surface_depth;
    water_depth = max(water_depth, 0.0);

    float depth_factor = smoothstep(0.0, 1.0, clamp(water_depth / WATER_MAX_DEPTH, 0.0, 1.0));
    float distance_water_mass = smoothstep(96.0, 520.0, vDistance);
    float water_mass = max(depth_factor, distance_water_mass);
    float edge_depth = 1.0 - smoothstep(0.0, 2.5, water_depth);

    vec2 uv = atlasUV(vTileID, vTexCoord + vec2(time * 0.025, time * 0.012));
    vec2 uv2 = atlasUV(vTileID, vTexCoord * 0.5 + vec2(-time * 0.018, time * 0.020));
    vec3 texA = texture(uTexture, uv).rgb;
    vec3 texB = texture(uTexture, uv2).rgb;
    vec3 water_tex = mix(texA, texB, 0.35);

    vec3 depth_color = mix(WATER_SHALLOW, mix(WATER_MID, WATER_DEEP, depth_factor), depth_factor);
    vec3 tint = mix(vec3(1.0), clamp(vColor * 1.35, 0.0, 1.0), 0.25);
    float texture_mix = 0.42;
    vec3 waterColor = mix(depth_color, water_tex * depth_color * 1.8, texture_mix) * tint;

    float tile_grid = max(smoothstep(0.030, 0.0, fract(vTexCoord.x)), smoothstep(0.030, 0.0, fract(vTexCoord.y)));
    waterColor *= 1.0 - tile_grid * 0.045;
    waterColor = mix(waterColor, WATER_SHALLOW * 1.18, edge_depth * 0.18);
    waterColor = mix(waterColor, mix(WATER_MID, WATER_DEEP, water_mass), water_mass * 0.34);

    vec3 reflected = mix(reflectionColor, envColor, 0.45);
    waterColor = mix(waterColor, reflected, fresnel * 0.16);

    float direct_light = NdotL * global.params.w * (1.0 - 0.3);
    float sky_light = vSkyLight * (global.lighting.x + direct_light * 0.5);
    float light_level = max(sky_light, max(vBlockLight.r, max(vBlockLight.g, vBlockLight.b)));
    light_level = clamp(max(light_level, global.lighting.x * 0.55), 0.34, 1.05);

    waterColor *= light_level;

    vec3 H = normalize(V + L);
    float spec = pow(max(dot(N, H), 0.0), 96.0);
    vec3 sun_specular = global.sun_color.rgb * global.params.w * spec * 0.22;

    waterColor += sun_specular;

    if (global.params.z > 0.5) {
        float fogBlend = atmosphericFogFactor(length(vFragPosWorld), global.params.y, vSkyLight);
        waterColor = mix(waterColor, global.fog_color.rgb, fogBlend);
    }

    float alpha = mix(0.66, 0.94, water_mass);
    alpha = mix(alpha, 0.90, fresnel * 0.20);
    alpha = mix(alpha, 0.56, edge_depth * 0.18);
    alpha = clamp(alpha, 0.56, 0.96);

    FragColor = vec4(waterColor, alpha * lodMaskAlpha);
}
