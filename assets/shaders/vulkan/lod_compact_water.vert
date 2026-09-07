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
layout(location = 9) out vec4 vClipPos;
layout(location = 10) out float vMaskRadius;
layout(location = 11) out float vLODFade;
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

layout(set = 0, binding = 16) readonly buffer Samples {
    uvec4 sample_words[];
} samples;
struct CompactInstance { mat4 model; vec4 params; uvec4 words; vec4 ownership_bounds; };
layout(set = 0, binding = 17) readonly buffer CompactInstances {
    CompactInstance items[];
} compact_instances;

// Must remain byte-for-byte identical to rhi.CompactLODDraw.
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

uint waterCoverage(uvec4 packed) {
    return (packed.y >> 8u) & 0xffu;
}

bool isFullyCoveredWater(uvec4 packed) {
    return decodeSigned16(packed.x, 16u) != -32768 && waterCoverage(packed) == 255u;
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

void collapsePrimitiveVertex() {
    // All rejected vertices share one clipped point, so fully dry primitives
    // are degenerate. Boundary water also collapses, avoiding wet/dry bridge
    // triangles; partial-water tiles are intentionally CPU-meshed instead.
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    vColor = vec3(0.0);
    vNormal = vec3(0.0, 1.0, 0.0);
    vTexCoord = vec2(0.0);
    vTileID = -1;
    vDistance = 0.0;
    vSkyLight = 0.0;
    vBlockLight = vec3(0.0);
    vFragPosWorld = vec3(0.0);
    vViewDepth = 0.0;
    vClipPos = gl_Position;
    vMaskRadius = 0.0;
    vLODFade = 0.0;
    vLODLocalXZ = vec2(0.0);
    vLODOwnershipBounds = vec4(0.0);
    vLODLocalNormalXZ = vec2(0.0);
}

void main() {
    uvec4 words = tileWords();
    vec4 params = tileParams();
    if (words.y < 2u) {
        collapsePrimitiveVertex();
        return;
    }

    uint vertex_index = uint(gl_VertexIndex);
    if (vertex_index / words.y >= words.y) {
        collapsePrimitiveVertex();
        return;
    }

    uint x = vertex_index % words.y;
    uint z = vertex_index / words.y;
    uvec4 packed = sampleAtApron(x + 1u, z + 1u);
    // Compact generation accepts only uniformly wet or uniformly dry tiles.
    // Keep this guard as defense against stale/corrupt payloads; mixed shoreline
    // topology requires per-cell indices and remains on the expanded path.
    if (!isFullyCoveredWater(packed)) {
        collapsePrimitiveVertex();
        return;
    }

    float water_height = float(decodeSigned16(packed.x, 16u)) * (1.0 / 8.0);
    vLODLocalXZ = vec2(float(x), float(z)) * params.z;
    vLODLocalNormalXZ = vec2(0.0);
    vLODOwnershipBounds = indirectMode() ? compact_instances.items[gl_InstanceIndex].ownership_bounds : draw_data.ownership_bounds;
    vec4 world_pos = tileModel() * vec4(float(x) * params.z, water_height, float(z) * params.z, 1.0);
    vec4 clip_pos = global.view_proj * world_pos;
    gl_Position = clip_pos;
    gl_Position.y = -gl_Position.y;

    uint color = sampleColor(packed);
    // Compact samples retain source 0xRRGGBB, unlike packed Vertex colors.
    vColor = vec3((color >> 16u) & 0xffu, (color >> 8u) & 0xffu, color & 0xffu) / 255.0;
    vNormal = vec3(0.0, 1.0, 0.0);
    vTexCoord = vec2(float(x), float(z)) * params.z;
    vTileID = -1;
    vDistance = length(world_pos.xyz);
    vSkyLight = float(skyLight(packed)) / 15.0;
    vBlockLight = vec3(float(blockLight(packed)) / 15.0);
    vFragPosWorld = world_pos.xyz;
    vViewDepth = -clip_pos.w;
    vClipPos = vec4(clip_pos.x, -clip_pos.y, clip_pos.z, clip_pos.w);
    vMaskRadius = params.x;
    vLODFade = clamp(params.y, 0.0, 1.0);
}
