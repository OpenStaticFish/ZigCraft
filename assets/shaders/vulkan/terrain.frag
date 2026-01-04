#version 450

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in float vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 8) in float vViewDepth;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 fog_color;
    float time;
    float fog_density;
    float fog_enabled;
    float sun_intensity;
    float ambient;
    float use_texture; // 0.0 = vertex colors only, 1.0 = use textures
    vec2 cloud_wind_offset;
    float cloud_scale;
    float cloud_coverage;
    float cloud_shadow_strength;
    float cloud_height;
    float padding[2];
} global;

// Cloud shadow noise functions
float cloudHash(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float cloudNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = cloudHash(i);
    float b = cloudHash(i + vec2(1.0, 0.0));
    float c = cloudHash(i + vec2(0.0, 1.0));
    float d = cloudHash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float cloudFbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * cloudNoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

float getCloudShadow(vec3 worldPos, vec3 sunDir) {
    // Project position along sun direction to cloud plane
    vec2 shadowOffset = sunDir.xz * (global.cloud_height - worldPos.y) / max(sunDir.y, 0.1);
    vec2 samplePos = (worldPos.xz + shadowOffset + global.cloud_wind_offset) * global.cloud_scale;
    
    float n1 = cloudFbm(samplePos * 0.5);
    float n2 = cloudFbm(samplePos * 2.0 + vec2(100.0, 200.0)) * 0.3;
    float cloudValue = n1 * 0.7 + n2;
    
    float threshold = 1.0 - global.cloud_coverage;
    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    
    return cloudMask * global.cloud_shadow_strength;
}

layout(set = 0, binding = 1) uniform sampler2D uTexture;

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[3];
    vec4 cascade_splits;
    vec4 shadow_texel_sizes;
} shadows;

layout(set = 0, binding = 3) uniform sampler2DShadow uShadowMap0;
layout(set = 0, binding = 4) uniform sampler2DShadow uShadowMap1;
layout(set = 0, binding = 5) uniform sampler2DShadow uShadowMap2;

layout(push_constant) uniform ModelUniforms {
    mat4 view_proj;
    mat4 model;
    float mask_radius;
    vec3 padding;
} model_data;

float shadowHash(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float calculateShadow(vec3 fragPosWorld, float nDotL, int layer) {
    vec4 fragPosLightSpace = shadows.light_space_matrices[layer] * vec4(fragPosWorld, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;

    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    
    if (projCoords.x < 0.0 || projCoords.x > 1.0 ||
        projCoords.y < 0.0 || projCoords.y > 1.0 ||
        projCoords.z > 1.0 || projCoords.z < 0.0) return 0.0;

    float currentDepth = projCoords.z;

    // Adjusted bias for hardware PCF + Poisson
    float bias = max(0.0002 * (1.0 - nDotL), 0.00005);
    if (layer == 1) bias *= 2.0;
    if (layer == 2) bias *= 5.0;

    float shadow = 0.0;
    vec2 texelSize = 1.0 / vec2(textureSize(uShadowMap0, 0));

    // Better Poisson Disk for jittered PCF
    float angle = shadowHash(fragPosWorld) * 6.283185;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, s, -s, c);

    const int SAMPLES = 16;
    vec2 poissonDisk[16] = vec2[](
        vec2(-0.94201624, -0.39906216), vec2(0.94558609, -0.76890725),
        vec2(-0.094184101, -0.92938870), vec2(0.34495938, 0.29387760),
        vec2(-0.91588581, 0.45771432), vec2(-0.81544232, -0.87912464),
        vec2(-0.38277543, 0.27676845), vec2(0.97484398, 0.75648379),
        vec2(0.44323325, -0.97511554), vec2(0.53742981, -0.47373420),
        vec2(-0.51339162, 0.84062361), vec2(0.18737649, -0.15983421),
        vec2(-0.41011392, -0.54401124), vec2(0.67105663, 0.92716503),
        vec2(-0.64335855, -0.28876165), vec2(0.40141695, 0.81434191)
    );

    // Hardware PCF + Poisson hybrid
    for (int i = 0; i < SAMPLES; i++) {
        vec2 offset = (rot * poissonDisk[i]) * texelSize * 2.2;
        vec3 shadowCoord = vec3(projCoords.xy + offset, currentDepth + bias);
        
        if (layer == 0) {
            shadow += texture(uShadowMap0, shadowCoord);
        } else if (layer == 1) {
            shadow += texture(uShadowMap1, shadowCoord);
        } else {
            shadow += texture(uShadowMap2, shadowCoord);
        }
    }

    return 1.0 - (shadow / float(SAMPLES));
}

void main() {
    float nDotL = max(dot(vNormal, global.sun_dir.xyz), 0.0);

    int layer = 2;
    float depth = vViewDepth;
    if (depth < shadows.cascade_splits.x) {
        layer = 0;
    } else if (depth < shadows.cascade_splits.y) {
        layer = 1;
    }

    float shadow = calculateShadow(vFragPosWorld, nDotL, layer);

    float blendThreshold = 0.9;
    if (layer < 2) {
        float splitDist = layer == 0 ? shadows.cascade_splits.x : shadows.cascade_splits.y;
        float prevSplit = layer == 0 ? 0.0 : shadows.cascade_splits.x;
        float range = splitDist - prevSplit;
        float distInto = depth - prevSplit;
        float normDist = distInto / range;

        if (normDist > blendThreshold) {
            float blend = (normDist - blendThreshold) / (1.0 - blendThreshold);
            float nextShadow = calculateShadow(vFragPosWorld, nDotL, layer + 1);
            shadow = mix(shadow, nextShadow, blend);
        }
    }

    // Cloud shadow
    float cloudShadow = 0.0;
    if (global.sun_intensity > 0.05 && global.sun_dir.y > 0.05) {
        cloudShadow = getCloudShadow(vFragPosWorld, global.sun_dir.xyz);
    }
    
    float totalShadow = min(shadow + cloudShadow, 1.0);

    float directLight = nDotL * global.sun_intensity * (1.0 - totalShadow);
    float skyLight = vSkyLight * (global.ambient + directLight * 0.8);
    float blockLight = vBlockLight;
    float lightLevel = max(skyLight, blockLight);

    lightLevel = max(lightLevel, global.ambient * 0.5);
    lightLevel = clamp(lightLevel, 0.0, 1.0);

    // Circular masking for LODs (Issue #119: Seamless transition)
    if (vTileID < 0 && model_data.mask_radius > 0.0) {
        float horizontalDist = length(vFragPosWorld.xz);
        if (horizontalDist < model_data.mask_radius * 16.0) discard;
    }

    vec3 color;
    if (global.use_texture > 0.5 && vTileID >= 0) {
        vec2 atlasSize = vec2(16.0, 16.0);
        vec2 tileSize = 1.0 / atlasSize;
        vec2 tilePos = vec2(mod(float(vTileID), atlasSize.x), floor(float(vTileID) / atlasSize.x));
        vec2 tiledUV = fract(vTexCoord);
        tiledUV = clamp(tiledUV, 0.001, 0.999);
        vec2 uv = (tilePos + tiledUV) * tileSize;

        vec4 texColor = texture(uTexture, uv);
        if (texColor.a < 0.1) discard;

        color = texColor.rgb * vColor * lightLevel;
    } else {
        color = vColor * lightLevel;
    }

    if (global.fog_enabled > 0.5) {
        float fogFactor = 1.0 - exp(-vDistance * global.fog_density);
        fogFactor = clamp(fogFactor, 0.0, 1.0);
        color = mix(color, global.fog_color.rgb, fogFactor);
    }

    FragColor = vec4(color, 1.0);
}
