#version 450
#extension GL_GOOGLE_include_directive : require

#include "distance_appearance.glsl"
#include "lod_ownership.glsl"

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in vec3 vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 11) in float vAO;
layout(location = 14) in float vMaskRadius;
layout(location = 16) in float vLODFade;
layout(location = 0) out vec4 outColor;

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

const float LOD_CHUNK_SIZE = 16.0;

bool shouldDiscardLODFragment(float encodedMaskRadius, vec2 cameraRelativeXZ) {
    float maskRadius = abs(encodedMaskRadius);
    if (maskRadius < 1.0) return false;

    bool readyDiskMask = encodedMaskRadius < 0.0;
    vec2 cameraChunkLocal = mod(global.cam_pos.xz, LOD_CHUNK_SIZE);
    vec2 chunkDelta = floor((cameraRelativeXZ + cameraChunkLocal) / LOD_CHUNK_SIZE);
    float detailRadiusChunks = floor(maskRadius / LOD_CHUNK_SIZE) + (readyDiskMask ? 0.0 : 2.0);
    return dot(chunkDelta, chunkDelta) <= detailRadiusChunks * detailRadiusChunks;
}

void main() {
    discardOutsideLODOwnership();
    if (shouldDiscardLODFragment(vMaskRadius, vFragPosWorld.xz)) discard;
    vec3 normal = normalize(vNormal);
    vec3 light_dir = normalize(global.sun_dir.xyz);
    float diffuse = max(dot(normal, light_dir), 0.0);
    float block_light = max(vBlockLight.r, max(vBlockLight.g, vBlockLight.b));
    float illumination = clamp(max(vSkyLight * global.lighting.x, block_light) + diffuse * global.params.w * 0.45, 0.18, 1.15);
    // CPU atlas-resolved color; compact lighting remains an approximation, not feature parity.
    vec3 color = vColor * illumination * mix(0.72, 1.0, clamp(vAO, 0.0, 1.0));
    if (global.params.z > 0.5) {
        float fog = atmosphericFogFactor(length(vFragPosWorld), global.params.y, vSkyLight);
        color = mix(color, global.fog_color.rgb, fog);
    }
    outColor = vec4(color, 1.0);
}
