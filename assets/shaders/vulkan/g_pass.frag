#version 450

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 9) in vec3 vTangent;
layout(location = 10) in vec3 vBitangent;

layout(location = 0) out vec3 outNormal;

layout(set = 0, binding = 1) uniform sampler2D uTexture;
layout(set = 0, binding = 6) uniform sampler2D uNormalMap;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
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

void main() {
    // Calculate UV coordinates in atlas
    vec2 atlasSize = vec2(16.0, 16.0);
    vec2 tileSize = 1.0 / atlasSize;
    vec2 tilePos = vec2(mod(float(vTileID), atlasSize.x), floor(float(vTileID) / atlasSize.x));
    vec2 tiledUV = fract(vTexCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    vec2 uv = (tilePos + tiledUV) * tileSize;

    if (texture(uTexture, uv).a < 0.1) discard;

    vec3 N = normalize(vNormal);

    if (global.lighting.z > 0.5 && global.pbr_params.x > 1.5 && vTileID >= 0) {
        vec3 normalMapValue = texture(uNormalMap, uv).rgb * 2.0 - 1.0;
        mat3 TBN = mat3(normalize(vTangent), normalize(vBitangent), N);
        N = normalize(TBN * normalMapValue);
    }

    // Convert normal from [-1, 1] to [0, 1] for storage in UNORM texture
    outNormal = N * 0.5 + 0.5;
}
