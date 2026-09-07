#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in uint aColor;
layout(location = 2) in uint aNormal;
layout(location = 3) in vec2 aTexCoord;
layout(location = 4) in uint aPackedMeta;
layout(location = 5) in uint aBlockLight;

layout(location = 0) out vec3 vColor;
layout(location = 1) flat out vec3 vNormal;
layout(location = 2) out vec2 vTexCoord;
layout(location = 3) flat out int vTileID;
layout(location = 4) out float vDistance;
layout(location = 5) out float vSkyLight;
layout(location = 6) out vec3 vBlockLight;
layout(location = 7) out vec3 vFragPosWorld;
layout(location = 8) out float vViewDepth;
layout(location = 9) out vec3 vTangent;
layout(location = 10) out vec3 vBitangent;
layout(location = 11) out float vAO;
layout(location = 12) out vec4 vClipPosCurrent;
layout(location = 13) out vec4 vClipPosPrev;
layout(location = 14) out float vMaskRadius;
layout(location = 15) out float vCloud;
layout(location = 16) out float vLODFade;
layout(location = 18) out vec2 vLODLocalXZ;
layout(location = 19) flat out vec4 vLODOwnershipBounds;
layout(location = 20) flat out vec2 vLODLocalNormalXZ;

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

struct InstanceData {
    mat4 model;
    float mask_radius;
    float lod_fade;
    float _pad1;
    float _pad2;
    vec4 ownership_bounds;
};

layout(set = 0, binding = 5) readonly buffer InstanceBuffer {
    InstanceData instances[];
} instance_buf;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec4 color_override;
    float mask_radius;
    layout(offset = 96) vec4 ownership_bounds;
} model_data;

vec3 decodeColor(uint c) {
    return vec3(
        float(c & 0xFFu) / 255.0,
        float((c >> 8u) & 0xFFu) / 255.0,
        float((c >> 16u) & 0xFFu) / 255.0
    );
}

vec3 decodeNormal(uint packed) {
    vec2 oct = unpackSnorm2x16(packed);
    float px = oct.x;
    float py = oct.y;
    float pz = 1.0 - abs(px) - abs(py);
    if (pz < 0.0) {
        float orig_px = px;
        px = (1.0 - abs(py)) * (px >= 0.0 ? 1.0 : -1.0);
        py = (1.0 - abs(orig_px)) * (py >= 0.0 ? 1.0 : -1.0);
    }
    return normalize(vec3(px, py, pz));
}

void main() {
    mat4 model;
    float mask_radius;
    float lod_fade;
    vec3 color_override;

    // Color alpha is reserved as the indirect-draw sentinel. Signed mask
    // radii encode the dynamic ready-detail disk and are valid direct values.
    if (model_data.color_override.w < 0.0) {
        InstanceData inst = instance_buf.instances[gl_InstanceIndex];
        model = inst.model;
        mask_radius = inst.mask_radius;
        lod_fade = inst.lod_fade;
        color_override = vec3(1.0);
        vLODOwnershipBounds = inst.ownership_bounds;
    } else {
        model = model_data.model;
        mask_radius = model_data.mask_radius;
        lod_fade = 1.0;
        color_override = model_data.color_override.xyz;
        vLODOwnershipBounds = model_data.ownership_bounds;
    }

    vLODLocalXZ = aPos.xz;
    vec4 worldPos = model * vec4(aPos, 1.0);
    vec4 clipPos = global.view_proj * worldPos;
    vec4 clipPosPrev = global.view_proj_prev * worldPos;

    gl_Position = clipPos;
    gl_Position.y = -gl_Position.y;

    vClipPosCurrent = vec4(clipPos.x, -clipPos.y, clipPos.z, clipPos.w);
    vClipPosPrev = vec4(clipPosPrev.x, -clipPosPrev.y, clipPosPrev.z, clipPosPrev.w);

    vec3 decodedColor = decodeColor(aColor);
    vec3 decodedNormal = decodeNormal(aNormal);
    vLODLocalNormalXZ = decodedNormal.xz;

    uint tile_id_u16 = aPackedMeta & 0xFFFFu;
    float skylight = float((aPackedMeta >> 16u) & 0xFFu) / 255.0;
    float ao = float((aPackedMeta >> 24u) & 0xFFu) / 255.0;

    vec3 blocklight = vec3(
        float(aBlockLight & 0xFFu) / 255.0,
        float((aBlockLight >> 8u) & 0xFFu) / 255.0,
        float((aBlockLight >> 16u) & 0xFFu) / 255.0
    );
    float cloud = float((aBlockLight >> 24u) & 0xFFu) / 255.0;

    vColor = decodedColor * color_override;
    vNormal = decodedNormal;
    vTexCoord = aTexCoord;
    vTileID = (tile_id_u16 == 0xFFFFu) ? -1 : int(tile_id_u16);
    vDistance = length(worldPos.xyz);
    vSkyLight = skylight;
    vBlockLight = blocklight;
    vCloud = cloud;

    vFragPosWorld = worldPos.xyz;
    // clipPos.w is the positive forward view distance with our reverse-Z projection.
    vViewDepth = clipPos.w;
    vAO = ao;
    vMaskRadius = mask_radius;
    vLODFade = clamp(lod_fade, 0.0, 1.0);

    vec3 absNormal = abs(decodedNormal);
    if (absNormal.y > 0.9) {
        vTangent = vec3(1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 0.0, decodedNormal.y > 0.0 ? 1.0 : -1.0);
    } else if (absNormal.x > 0.9) {
        vTangent = vec3(0.0, 0.0, decodedNormal.x > 0.0 ? -1.0 : 1.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    } else {
        vTangent = vec3(decodedNormal.z > 0.0 ? 1.0 : -1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    }
}
