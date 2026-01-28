#version 450

layout (location = 0) in vec2 inUV;
layout (location = 0) out float outAO;

layout (binding = 0) uniform sampler2D samplerDepth;
layout (binding = 1) uniform sampler2D samplerNormal;
layout (binding = 2) uniform sampler2D samplerNoise;

layout (binding = 3) uniform SSAOParams {
    mat4 projection;
    mat4 invProjection;
    vec4 samples[64];
    float radius;
    float bias;
} params;

// Reconstruct view space position from depth
vec3 getViewPos(vec2 uv, float depth) {
    // depth is in [0, 1] range (Vulkan)
    // Reconstruct NDC
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 viewPos = params.invProjection * ndc;
    return viewPos.xyz / viewPos.w;
}

void main() {
    float depth = texture(samplerDepth, inUV).r;
    if (depth <= 0.0001) {
        outAO = 1.0;
        return;
    }

    vec3 normal = texture(samplerNormal, inUV).rgb;
    // Normals are stored in [0, 1] range, convert to [-1, 1]
    normal = normal * 2.0 - 1.0;
    if (length(normal) < 0.1) {
        outAO = 1.0;
        return;
    }
    normal = normalize(normal);

    vec3 fragPos = getViewPos(inUV, depth);

    // Get random rotation from noise texture
    ivec2 texSize = textureSize(samplerDepth, 0);
    ivec2 noiseSize = textureSize(samplerNoise, 0);
    vec2 noiseUV = vec2(float(texSize.x) / float(noiseSize.x), float(texSize.y) / float(noiseSize.y)) * inUV;
    vec3 randomVec = texture(samplerNoise, noiseUV).xyz * 2.0 - 1.0;

    // Create TBN matrix for hemisphere samples
    vec3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
    vec3 bitangent = cross(normal, tangent);
    mat3 TBN = mat3(tangent, bitangent, normal);

    float occlusion = 0.0;
    for (int i = 0; i < 16; i++) {
        // Get sample position in view space
        vec3 samplePos = TBN * params.samples[i].xyz;
        samplePos = fragPos + samplePos * params.radius;

        // Project sample position to screen space
        vec4 offset = vec4(samplePos, 1.0);
        offset = params.projection * offset;
        offset.xyz /= offset.w;
        offset.xy = offset.xy * 0.5 + 0.5;

        // Get depth of sample from depth buffer
        float sampleDepth = getViewPos(offset.xy, texture(samplerDepth, offset.xy).r).z;

        // Range check to avoid occlusion from far objects
        float rangeCheck = smoothstep(0.0, 1.0, params.radius / abs(fragPos.z - sampleDepth));
        occlusion += (sampleDepth >= samplePos.z + params.bias ? 1.0 : 0.0) * rangeCheck;
    }

    outAO = 1.0 - (occlusion / 16.0);
}
