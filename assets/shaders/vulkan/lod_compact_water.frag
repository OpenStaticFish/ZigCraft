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

layout(location = 0) out vec4 outColor;

// Matches the two-chunk overlap reserved by LODConfig.calculateMaskRadius().
const float LOD_MASK_BLEND_WIDTH = 32.0;

layout(set = 0, binding = 0) uniform Global {
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

void main() {
    discardOutsideLODOwnership();
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
    outColor = lodWaterAppearance(vColor, vNormal, vFragPosWorld, vSkyLight, vBlockLight);
    outColor.a *= lodMaskAlpha;
}
