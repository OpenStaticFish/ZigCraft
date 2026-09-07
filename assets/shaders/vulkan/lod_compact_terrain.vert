#version 450

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

// One sample is the little-endian 128-bit CompactLODSample wire ABI. The
// uvec4 lanes are bits [0..31], [32..63], [64..95], and [96..127].
layout(set = 0, binding = 16) readonly buffer Samples {
    uvec4 sample_words[];
} samples;
struct CompactInstance { mat4 model; vec4 params; uvec4 words; vec4 ownership_bounds; };
layout(set = 0, binding = 17) readonly buffer CompactInstances {
    CompactInstance items[];
} compact_instances;

// Keep this byte-for-byte identical to rhi.CompactLODDraw. The explicit tail
// carries edge validity in the std430 tail word at offset 92.
layout(push_constant) uniform CompactDraw {
    mat4 model;
    float mask_radius;
    float lod_fade;
    uint sample_offset;
    uint width;
    float cell_size;
    uint layer;
    float skirt_depth;
    uint edge_masks;
    vec4 ownership_bounds;
} draw_data;

// `layer == 2` is the indirect sentinel. Direct draws retain their existing
// push-constant ABI; indirect indexed draws address this SSBO via firstInstance.
bool indirectMode() { return draw_data.layer == 2u; }
mat4 tileModel() { return indirectMode() ? compact_instances.items[gl_InstanceIndex].model : draw_data.model; }
vec4 tileParams() { return indirectMode() ? compact_instances.items[gl_InstanceIndex].params : vec4(draw_data.mask_radius, draw_data.lod_fade, draw_data.cell_size, draw_data.skirt_depth); }
uvec4 tileWords() { return indirectMode() ? compact_instances.items[gl_InstanceIndex].words : uvec4(draw_data.sample_offset, draw_data.width, draw_data.layer, draw_data.edge_masks); }

int decodeSigned16(uint word, uint shift) {
    uint raw = (word >> shift) & 0xffffu;
    return raw >= 0x8000u ? int(raw) - 65536 : int(raw);
}

uint sampleIndex(uint apron_x, uint apron_z) {
    uvec4 words = tileWords();
    return words.x + apron_z * (words.y + 2u) + apron_x;
}

uvec4 sampleAtApron(uint apron_x, uint apron_z) {
    return samples.sample_words[sampleIndex(apron_x, apron_z)];
}

float terrainHeight(uvec4 packed) {
    return float(decodeSigned16(packed.x, 0u)) * (1.0 / 8.0);
}

uint surfaceMaterial(uvec4 packed) {
    return (packed.y >> 16u) & 0x7fu;
}

// Compact tile edge bits are N/E/S/W. A clear bit is an explicit non-seamless
// contract: its apron is a local fallback, and its edge must retain a skirt.
bool hasAuthoritativeApron(uvec4 words, uint edge) {
    return (words.w & (1u << edge)) != 0u;
}

uint skirtTileEdge(uint skirt_edge) {
    if (skirt_edge == 0u) return 0u; // north
    if (skirt_edge == 1u) return 2u; // south
    if (skirt_edge == 2u) return 3u; // west
    return 1u; // east
}

uint sampleColor(uvec4 packed) {
    return (packed.z >> 5u) & 0x00ffffffu;
}

uint skyLight(uvec4 packed) {
    return ((packed.z >> 29u) & 0x7u) | ((packed.w & 0x1u) << 3u);
}

uint blockLight(uvec4 packed) {
    return (packed.w >> 1u) & 0x0fu;
}

uint ambientOcclusion(uvec4 packed) {
    return (packed.w >> 5u) & 0x3fu;
}

vec3 fallbackMaterialColor(uint material) {
    if (material == 3u) return vec3(0.32, 0.58, 0.20); // grass
    if (material == 2u || material == 51u || material == 52u || material == 53u) return vec3(0.43, 0.29, 0.16);
    if (material == 4u || material == 31u) return vec3(0.76, 0.66, 0.38);
    if (material == 10u) return vec3(0.42, 0.41, 0.38);
    if (material == 12u || material == 47u) return vec3(0.88, 0.92, 0.96);
    if (material == 19u) return vec3(0.24, 0.20, 0.14);
    return vec3(0.43, 0.45, 0.47);
}

void main() {
    uvec4 words = tileWords();
    vec4 params = tileParams();
    uint vertex_index = uint(gl_VertexIndex);
    if (words.y < 2u) {
        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
        return;
    }

    uint top_vertex_count = words.y * words.y;
    bool is_skirt = vertex_index >= top_vertex_count;
    uint x;
    uint z;
    uint skirt_edge = 0u;
    if (!is_skirt) {
        x = vertex_index % words.y;
        z = vertex_index / words.y;
    } else {
        uint skirt_vertex = vertex_index - top_vertex_count;
        skirt_edge = skirt_vertex / words.y;
        uint edge_position = skirt_vertex % words.y;
        if (skirt_edge >= 4u) {
            gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
            return;
        }
        if (skirt_edge == 0u) { x = edge_position; z = 0u; }
        else if (skirt_edge == 1u) { x = edge_position; z = words.y - 1u; }
        else if (skirt_edge == 2u) { x = 0u; z = edge_position; }
        else { x = words.y - 1u; z = edge_position; }
    }
    uvec4 packed = sampleAtApron(x + 1u, z + 1u);
    float height = terrainHeight(packed);
    float height_x0 = terrainHeight(sampleAtApron(x, z + 1u));
    float height_x1 = terrainHeight(sampleAtApron(x + 2u, z + 1u));
    float height_z0 = terrainHeight(sampleAtApron(x + 1u, z));
    float height_z1 = terrainHeight(sampleAtApron(x + 1u, z + 2u));
    // Do not discard an authoritative apron. Only explicit fallback edges use
    // slope extrapolation, so resident tiles never pretend an invalid apron is
    // a seamless normal.
    if (x == 0u && !hasAuthoritativeApron(words, 3u)) height_x0 = 2.0 * height - height_x1;
    if (x + 1u == words.y && !hasAuthoritativeApron(words, 1u)) height_x1 = 2.0 * height - height_x0;
    if (z == 0u && !hasAuthoritativeApron(words, 0u)) height_z0 = 2.0 * height - height_z1;
    if (z + 1u == words.y && !hasAuthoritativeApron(words, 2u)) height_z1 = 2.0 * height - height_z0;

    vec3 normal = normalize(vec3(
        height_x0 - height_x1,
        2.0 * params.z,
        height_z0 - height_z1
    ));
    // The static index buffer contains all four skirts. Valid same-level edges
    // collapse theirs to a degenerate strip; absent or cross-LOD neighbors keep
    // only their own edge skirt, rather than relying on a universal skirt.
    if (is_skirt && !hasAuthoritativeApron(words, skirtTileEdge(skirt_edge))) {
        height -= params.w;
        if (skirt_edge == 0u) normal = vec3(0.0, 0.0, -1.0);
        else if (skirt_edge == 1u) normal = vec3(0.0, 0.0, 1.0);
        else if (skirt_edge == 2u) normal = vec3(-1.0, 0.0, 0.0);
        else normal = vec3(1.0, 0.0, 0.0);
    }
    vec3 local_pos = vec3(float(x) * params.z, height, float(z) * params.z);
    vLODLocalXZ = local_pos.xz;
    vLODLocalNormalXZ = normal.xz;
    vLODOwnershipBounds = indirectMode() ? compact_instances.items[gl_InstanceIndex].ownership_bounds : draw_data.ownership_bounds;
    vec4 world_pos = tileModel() * vec4(local_pos, 1.0);
    vec4 clip_pos = global.view_proj * world_pos;

    gl_Position = clip_pos;
    gl_Position.y = -gl_Position.y;
    vClipPosCurrent = vec4(clip_pos.x, -clip_pos.y, clip_pos.z, clip_pos.w);
    vec4 previous_clip_pos = global.view_proj_prev * world_pos;
    vClipPosPrev = vec4(previous_clip_pos.x, -previous_clip_pos.y, previous_clip_pos.z, previous_clip_pos.w);

    uint color = sampleColor(packed);
    // Compact samples retain source 0xRRGGBB, unlike packed Vertex colors.
    vColor = vec3((color >> 16u) & 0xffu, (color >> 8u) & 0xffu, color & 0xffu) / 255.0;
    if (color == 0u) vColor = fallbackMaterialColor(surfaceMaterial(packed));
    if (is_skirt && !hasAuthoritativeApron(words, skirtTileEdge(skirt_edge))) vColor *= 0.82;
    vNormal = normal;
    vTexCoord = vec2(float(x), float(z)) * params.z;
    // Compact samples store semantic materials, not texture-atlas tile IDs.
    // The terrain fragment's color-only path is the stable far-distance ABI.
    vTileID = -1;
    vDistance = length(world_pos.xyz);
    vSkyLight = float(skyLight(packed)) / 15.0;
    vBlockLight = vec3(float(blockLight(packed)) / 15.0);
    vFragPosWorld = world_pos.xyz;
    vViewDepth = clip_pos.w;
    vAO = float(ambientOcclusion(packed)) / 63.0;
    vMaskRadius = params.x;
    vCloud = 0.0;
    vLODFade = clamp(params.y, 0.0, 1.0);
    vTangent = normalize(vec3(1.0, 0.0, (height_x1 - height_x0) / (2.0 * params.z)));
    vBitangent = normalize(cross(normal, vTangent));
}
