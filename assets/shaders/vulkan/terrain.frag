#version 450

layout(constant_id = 0) const bool WATER_REFLECTION = false;

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in vec3 vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 8) in float vViewDepth;
layout(location = 9) in vec3 vTangent;
layout(location = 10) in vec3 vBitangent;
layout(location = 11) in float vAO;
layout(location = 12) in vec4 vClipPosCurrent;
layout(location = 13) in vec4 vClipPosPrev;
layout(location = 15) in float vCloud;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 reserved0;
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = reserved
    vec4 render_flags; // z = PBR material maps enabled
    vec4 shadow_params; // x = pcf_samples, y = cascade_blend, z = shadow strength, w = apply to beauty
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation, w = ssao_strength
    vec4 volumetric_params; // x = enabled, y = density, z = steps, w = scattering
    vec4 viewport_size; // xy = width/height, z = terrain debug active, w = terrain debug channel
    vec4 lpv_params; // x = enabled, y = intensity, z = cell_size, w = grid_size
    vec4 lpv_origin; // xyz = world origin
} global;

// Constants
const float PI = 3.14159265359;

float saturate(float v) {
    return clamp(v, 0.0, 1.0);
}

const int DEBUG_OFF = 0;
const int DEBUG_SHADOW_FACTOR = 1;
const int DEBUG_CASCADE_INDEX = 2;
const int DEBUG_CASTER_COVERAGE = 3;
const int DEBUG_SEAM_DIAG = 4;
const int DEBUG_TILE_ID = 5;
const int DEBUG_TEX_COLOR = 6;
const int DEBUG_DIRECT_KEY = 7;
const int DEBUG_SKY_FILL = 8;
const int DEBUG_BLOCK_LIGHT = 9;
const int DEBUG_OUTDOOR_FACTOR = 10;
const int DEBUG_SKYLIGHT = 12;
const int DEBUG_AMBIENT_OCCLUSION = 13;

float skyVisibilityFactor(float skyLight) {
    return smoothstep(0.05, 0.25, clamp(skyLight, 0.0, 1.0));
}

vec3 absoluteWorldPos(vec3 cameraRelativePos) {
    return cameraRelativePos + global.cam_pos.xyz;
}

layout(set = 0, binding = 1) uniform sampler2D uTexture;         // Diffuse/albedo
layout(set = 0, binding = 6) uniform sampler2D uNormalMap;       // Normal map (OpenGL format)
layout(set = 0, binding = 7) uniform sampler2D uRoughnessMap;    // Roughness map
layout(set = 0, binding = 8) uniform sampler2D uDisplacementMap; // Displacement map (unused for now)
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;          // Environment Map (EXR)
layout(set = 0, binding = 10) uniform sampler2D uSSAOMap;       // SSAO Map
layout(set = 0, binding = 11) uniform sampler3D uLPVGrid;       // LPV SH Red channel (4 SH coefficients)
layout(set = 0, binding = 12) uniform sampler3D uLPVGridG;      // LPV SH Green channel
layout(set = 0, binding = 13) uniform sampler3D uLPVGridB;      // LPV SH Blue channel

vec3 sampleTileAverage(vec2 tileBase) {
    const float TILE_SIZE = 1.0 / 16.0;
    vec4 s0 = texture(uTexture, tileBase + vec2(0.25, 0.25) * TILE_SIZE);
    vec4 s1 = texture(uTexture, tileBase + vec2(0.75, 0.25) * TILE_SIZE);
    vec4 s2 = texture(uTexture, tileBase + vec2(0.25, 0.75) * TILE_SIZE);
    vec4 s3 = texture(uTexture, tileBase + vec2(0.75, 0.75) * TILE_SIZE);

    vec4 samples[4] = vec4[](s0, s1, s2, s3);
    vec3 sum = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 4; i++) {
        float w = smoothstep(0.05, 0.5, samples[i].a);
        sum += samples[i].rgb * w;
        weight += w;
    }
    if (weight <= 0.001) {
        return texture(uTexture, tileBase + vec2(0.5) * TILE_SIZE).rgb;
    }
    return sum / weight;
}

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[4];
    vec4 cascade_splits;
    vec4 overlap_starts;
    vec4 shadow_texel_sizes;
    vec4 shadow_depth_spans;
    vec4 shadow_params; // y = inverse resolution
    vec4 fade_params; // x = fade start, y = configured shadow distance
} shadows;

layout(set = 0, binding = 3) uniform sampler2DArrayShadow uShadowMaps;
layout(set = 0, binding = 4) uniform sampler2DArray uShadowMapsRegular;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec4 color_override;
} model_data;

// Poisson Disk for PCF (16-sample)
const vec2 poissonDisk16[16] = vec2[](
    vec2(-0.94201624, -0.39906216),
    vec2(0.94558609, -0.76890725),
    vec2(-0.094184101, -0.92938870),
    vec2(0.34495938, 0.29387760),
    vec2(-0.91588581, 0.45771432),
    vec2(-0.81544232, -0.87912464),
    vec2(0.97484398, 0.75648379),
    vec2(0.44323325, -0.97511554),
    vec2(0.53742981, -0.47373420),
    vec2(-0.26496911, -0.41893023),
    vec2(0.79197514, 0.19090188),
    vec2(-0.24188840, 0.99706507),
    vec2(-0.81409955, 0.91437590),
    vec2(0.19984126, 0.78641367),
    vec2(0.14383161, -0.14100790),
    vec2(-0.63242006, 0.31173663)
);

// 4-sample cross pattern for LOW preset (no noise, no PCSS)
const vec2 pcfCross4[4] = vec2[](
    vec2(-1.0, 0.0),
    vec2(1.0, 0.0),
    vec2(0.0, -1.0),
    vec2(0.0, 1.0)
);

float interleavedGradientNoise(vec2 fragCoord) {
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(fragCoord.xy, magic.xy)));
}

vec3 shadowProjCoords(vec3 fragPosWorld, int layer) {
    vec4 fragPosLightSpace = shadows.light_space_matrices[layer] * vec4(fragPosWorld, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    return projCoords;
}

bool shadowProjInBounds(vec3 projCoords, float margin) {
    return projCoords.x >= margin && projCoords.x <= 1.0 - margin &&
           projCoords.y >= margin && projCoords.y <= 1.0 - margin &&
           projCoords.z >= 0.0 && projCoords.z <= 1.0;
}

int shadowResolution() {
    float invResolution = max(shadows.shadow_params.y, 1.0 / 4096.0);
    return max(1, int(round(1.0 / invResolution)));
}

ivec2 shadowTexelCoord(vec2 uv) {
    int resolution = shadowResolution();
    vec2 maxTexel = vec2(float(resolution - 1));
    return ivec2(clamp(floor(uv * float(resolution)), vec2(0.0), maxTexel));
}

float fetchShadowDepthNearest(vec2 uv, int layer) {
    ivec2 texel = shadowTexelCoord(uv);
    return texelFetch(uShadowMapsRegular, ivec3(texel, layer), 0).r;
}

float fetchShadowDepthTexel(ivec2 texel, int layer) {
    int resolution = shadowResolution();
    ivec2 clampedTexel = clamp(texel, ivec2(0), ivec2(resolution - 1));
    return texelFetch(uShadowMapsRegular, ivec3(clampedTexel, layer), 0).r;
}

float hardShadowCompareTexel(ivec2 texel, int layer, float compareDepth) {
    float mapDepth = fetchShadowDepthTexel(texel, layer);
    return compareDepth >= mapDepth ? 0.0 : 1.0;
}

float manualShadowCompareLinear(vec2 uv, int layer, float compareDepth) {
    int resolution = shadowResolution();
    vec2 texelPos = clamp(uv, vec2(0.0), vec2(1.0)) * float(resolution) - vec2(0.5);
    ivec2 baseTexel = ivec2(floor(texelPos));
    vec2 blend = fract(texelPos);

    float s00 = hardShadowCompareTexel(baseTexel, layer, compareDepth);
    float s10 = hardShadowCompareTexel(baseTexel + ivec2(1, 0), layer, compareDepth);
    float s01 = hardShadowCompareTexel(baseTexel + ivec2(0, 1), layer, compareDepth);
    float s11 = hardShadowCompareTexel(baseTexel + ivec2(1, 1), layer, compareDepth);

    return mix(mix(s00, s10, blend.x), mix(s01, s11, blend.x), blend.y);
}

float manualShadowPcfStable(vec2 uv, int layer, float compareDepth) {
    return manualShadowCompareLinear(uv, layer, compareDepth);
}

float hardShadowCompare(vec2 uv, int layer, float compareDepth) {
    ivec2 texel = shadowTexelCoord(uv);
    return hardShadowCompareTexel(texel, layer, compareDepth);
}

int selectShadowCascade(vec3 fragPosWorld, float cascadeDistance) {
    int preferred = cascadeDistance < shadows.cascade_splits[0] ? 0
                  : (cascadeDistance < shadows.cascade_splits[1] ? 1
                  : (cascadeDistance < shadows.cascade_splits[2] ? 2 : 3));
    int tier = int(global.shadow_params.x);
    float kernelRadius = tier <= 1 ? 0.5 : (tier <= 4 ? 1.5 : (tier <= 9 ? 2.0 : 2.5));
    float margin = shadows.shadow_params.y * kernelRadius;

    if (shadowProjInBounds(shadowProjCoords(fragPosWorld, preferred), margin)) return preferred;

    for (int offset = 1; offset < 4; offset++) {
        int layer = preferred + offset;
        if (layer < 4 && shadowProjInBounds(shadowProjCoords(fragPosWorld, layer), margin)) return layer;
    }

    for (int layer = preferred - 1; layer >= 0; layer--) {
        if (shadowProjInBounds(shadowProjCoords(fragPosWorld, layer), margin)) return layer;
    }
    return preferred;
}

float computeShadowFactor(vec3 fragPosWorld, vec3 N, vec3 L, int layer) {
    vec3 projCoords = shadowProjCoords(fragPosWorld, layer);
    
    int pcfSamples = int(global.shadow_params.x);
    float kernelRadius = pcfSamples <= 1 ? 0.5 : (pcfSamples <= 4 ? 1.5 : (pcfSamples <= 9 ? 2.0 : 2.5));
    if (!shadowProjInBounds(projCoords, shadows.shadow_params.y * kernelRadius)) return 0.0;

    float currentDepth = projCoords.z;
    float worldTexelSize = shadows.shadow_texel_sizes[layer];
    float depthSpan = max(shadows.shadow_depth_spans[layer], 0.0001);
    float uvTexelSize = max(shadows.shadow_params.y, 1.0 / 4096.0);
    
    float NdotL = max(dot(N, L), 0.001);
    float sinTheta = sqrt(1.0 - NdotL * NdotL);
    float tanTheta = sinTheta / NdotL;
    
    // Reverse-Z receiver bias. The shadow sampler uses GREATER_OR_EQUAL, so the
    // receiver reference moves slightly closer to the light (higher depth) to
    // avoid self-shadowing on coplanar surfaces.
    float biasTexels = 0.35 + 0.2 * min(tanTheta, 5.0);
    float bias = worldTexelSize * biasTexels / depthSpan;
    float compareDepth = min(currentDepth + bias, 1.0);

    if (pcfSamples <= 1) {
        return hardShadowCompare(projCoords.xy, layer, compareDepth);
    }

    if (pcfSamples <= 4) {
        float shadow = 0.0;
        float radius = uvTexelSize * 1.5;
        for (int i = 0; i < 4; i++) {
            shadow += texture(uShadowMaps, vec4(projCoords.xy + pcfCross4[i] * radius, float(layer), compareDepth));
        }
        return 1.0 - (shadow / 4.0);
    }

    int tapCount = pcfSamples <= 9 ? 9 : 16;
    float radius = uvTexelSize * (tapCount == 9 ? 2.0 : 2.5);
    float shadow = 0.0;
    for (int i = 0; i < tapCount; i++) {
        shadow += texture(uShadowMaps, vec4(projCoords.xy + poissonDisk16[i] * radius, float(layer), compareDepth));
    }
    return 1.0 - (shadow / float(tapCount));
}

float computeShadowCascades(vec3 fragPosWorld, vec3 N, vec3 L, float cascadeDistance, int layer) {
    if (global.shadow_params.z <= 0.0) return 0.0;

    float shadow = computeShadowFactor(fragPosWorld, N, L, layer);
    
    // Cascade blending transition (only when enabled).
    // shadow_params.y is packed as 1.0 (on) or 0.0 (off) from ShadowConfig.cascade_blend.
    if (global.shadow_params.y > 0.0 && layer < 3) {
        float nextSplit = shadows.cascade_splits[layer];
        float blendThreshold = shadows.overlap_starts[layer + 1];
        if (cascadeDistance > blendThreshold) {
            float blend = (cascadeDistance - blendThreshold) / (nextSplit - blendThreshold);
            float nextShadow = computeShadowFactor(fragPosWorld, N, L, layer + 1);
            shadow = mix(shadow, nextShadow, clamp(blend, 0.0, 1.0));
        }
    }
    return shadow;
}

// PBR functions
const float MAX_ENV_MIP_LEVEL = 8.0; 
const float SUN_RADIANCE_TO_IRRADIANCE = 4.0;
const float SUN_VOLUMETRIC_INTENSITY = 3.0;   
const vec3 IBL_CLAMP = vec3(3.0);             
const float VOLUMETRIC_DENSITY_FACTOR = 0.1;  
const float DIELECTRIC_F0 = 0.04;             
const float COOK_TORRANCE_DENOM_FACTOR = 4.0; 

float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float nom = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return nom / max(denom, 0.001);
}

float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    float nom = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return nom / max(denom, 0.001);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec2 SampleSphericalMap(vec3 v) {
    vec3 n = normalize(v);
    float phi = atan(n.z, n.x);
    float theta = acos(clamp(n.y, -1.0, 1.0));
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

vec3 computeIBLAmbient(vec3 N, float roughness) {
    float envMipLevel = roughness * MAX_ENV_MIP_LEVEL;
    vec2 envUV = SampleSphericalMap(normalize(N));
    return textureLod(uEnvMap, envUV, envMipLevel).rgb;
}

// SH L1 constants for irradiance reconstruction
const float LPV_SH_C0 = 0.282095;
const float LPV_SH_C1 = 0.488603;

// Evaluate SH L1 irradiance for a given direction
float evaluateLPVSH(vec4 sh, vec3 dir) {
    return max(0.0, sh.x * LPV_SH_C0 + sh.y * LPV_SH_C1 * dir.x + sh.z * LPV_SH_C1 * dir.y + sh.w * LPV_SH_C1 * dir.z);
}

// Sample the native 3D LPV SH grid and reconstruct directional irradiance using surface normal.
vec3 sampleLPVAtlas(vec3 worldPos, vec3 normal) {
    if (global.lpv_params.x < 0.5) return vec3(0.0);

    float gridSize = max(global.lpv_params.w, 1.0);
    float cellSize = max(global.lpv_params.z, 0.001);
    vec3 local = (worldPos - global.lpv_origin.xyz) / cellSize;

    if (any(lessThan(local, vec3(0.0))) || any(greaterThanEqual(local, vec3(gridSize)))) {
        return vec3(0.0);
    }

    // Normalize to [0,1] UV range for hardware trilinear sampling
    vec3 uvw = (local + 0.5) / gridSize;

    // Sample 4 SH coefficients per color channel
    vec4 sh_r = texture(uLPVGrid, uvw);
    vec4 sh_g = texture(uLPVGridG, uvw);
    vec4 sh_b = texture(uLPVGridB, uvw);

    // Reconstruct directional irradiance using the surface normal
    float irr_r = evaluateLPVSH(sh_r, normal);
    float irr_g = evaluateLPVSH(sh_g, normal);
    float irr_b = evaluateLPVSH(sh_b, normal);

    // Clamp to prevent overexposure from accumulated SH values
    return clamp(vec3(irr_r, irr_g, irr_b) * global.lpv_params.y, vec3(0.0), vec3(2.0));
}

vec3 computeBRDF(vec3 albedo, vec3 N, vec3 V, vec3 L, float roughness) {
    vec3 H = normalize(V + L);
    vec3 F0 = mix(vec3(DIELECTRIC_F0), albedo, 0.0);
    float NDF = DistributionGGX(N, H, roughness);
    float G = GeometrySmith(N, V, L, roughness);
    vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
    vec3 numerator = NDF * G * F;
    float denominator = COOK_TORRANCE_DENOM_FACTOR * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.001;
    vec3 specular = numerator / denominator;
    vec3 kD = (vec3(1.0) - F);
    return (kD * albedo / PI + specular);
}

float baselineOutdoorFactor(float skyLight) {
    return smoothstep(0.86, 0.98, clamp(skyLight, 0.0, 1.0));
}

float debugOutdoorFactor(float skyLight) {
    return baselineOutdoorFactor(skyLight);
}

vec3 computeTerrainLighting(vec3 albedo, vec3 N, vec3 V, vec3 L, float roughness, float totalShadow, float skyLight, float skyVisibility, vec3 blockLight, float ao, float ssao, out float directKeyOut, out float skyFillOut, out float blockLightOut, out float outdoorOut) {
    float outdoor = baselineOutdoorFactor(skyVisibility);
    float nDotL = max(dot(N, L), 0.0);
    // Guard only the BRDF to retain the contribution's multiply/add chain.
    vec3 brdf = vec3(0.0);
    if (nDotL != 0.0 && outdoor != 0.0 && global.params.w != 0.0 && totalShadow != 1.0) {
        brdf = computeBRDF(albedo, N, V, L, roughness);
    }
    vec3 sunRadiance = global.sun_color.rgb * global.params.w * SUN_RADIANCE_TO_IRRADIANCE / PI;
    vec3 direct = brdf * sunRadiance * nDotL * (1.0 - totalShadow) * outdoor;
    float indirectSky = sqrt(clamp(skyLight, 0.0, 1.0)) * clamp(skyVisibility, 0.0, 1.0);
    vec3 tunnelIrradiance = vec3(0.42);
    vec3 outdoorIrradiance = vec3(0.0);
    // IBL uses explicit LOD, so per-fragment zero weights need no derivatives.
    if (outdoor != 0.0 && indirectSky != 0.0) {
        outdoorIrradiance = min(computeIBLAmbient(N, roughness), IBL_CLAMP);
    }
    vec3 skyIrradiance = mix(tunnelIrradiance, outdoorIrradiance, outdoor) * indirectSky;
    vec3 groundBounce = vec3(0.018) * indirectSky * max(-N.y, 0.0) * outdoor;
    vec3 propagated = sampleLPVAtlas(absoluteWorldPos(vFragPosWorld), N);
    vec3 indirect = albedo * (skyIrradiance + groundBounce + propagated + blockLight);
    // AO is an indirect-diffuse visibility term: do not darken sunlight or specular.
    indirect *= ao * ssao;
    float readableFloor = smoothstep(0.002, 0.08, max(skyLight, max(blockLight.r, max(blockLight.g, blockLight.b))));
    indirect += albedo * vec3(0.012) * readableFloor;

    directKeyOut = clamp(max(max(direct.r, direct.g), direct.b), 0.0, 1.0);
    skyFillOut = clamp(max(max((albedo * (skyIrradiance + groundBounce + propagated)).r, (albedo * (skyIrradiance + groundBounce + propagated)).g), (albedo * (skyIrradiance + groundBounce + propagated)).b), 0.0, 1.0);
    blockLightOut = clamp(max(blockLight.r, max(blockLight.g, blockLight.b)), 0.0, 1.0);
    outdoorOut = outdoor;
    return direct + indirect;
}

// Simple shadow sampler for volumetric points, optimized
float getVolShadow(vec3 p, float viewDepth) {
    int layer = 3;
    if (viewDepth < shadows.cascade_splits[0]) layer = 0;
    else if (viewDepth < shadows.cascade_splits[1]) layer = 1;
    else if (viewDepth < shadows.cascade_splits[2]) layer = 2;
    vec4 lightSpacePos = shadows.light_space_matrices[layer] * vec4(p, 1.0);
    vec3 proj = lightSpacePos.xyz / lightSpacePos.w;
    proj.xy = proj.xy * 0.5 + 0.5;
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z < 0.0 || proj.z > 1.0) return 1.0;
    return texture(uShadowMaps, vec4(proj.xy, float(layer), proj.z + 0.002));
}

// Henyey-Greenstein Phase Function for Mie Scattering (Phase 4)
float henyeyGreensteinVol(float g, float cosTheta) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 0.01), 1.5));
}

vec4 computeVolumetric(vec3 rayStart, vec3 rayEnd, float dither) {
    if (global.volumetric_params.x < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);
    vec3 rayDir = rayEnd - rayStart;
    float totalDist = length(rayDir);
    rayDir /= totalDist;
    float maxDist = min(totalDist, 180.0); 
    int steps = 16; 
    float stepSize = maxDist / float(steps);
    float cosTheta = dot(rayDir, normalize(global.sun_dir.xyz));
    float phase = henyeyGreensteinVol(global.volumetric_params.w, cosTheta);
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_VOLUMETRIC_INTENSITY / PI;
    vec3 accumulatedScattering = vec3(0.0);
    float transmittance = 1.0;
    float density = global.volumetric_params.y * VOLUMETRIC_DENSITY_FACTOR;
    for (int i = 0; i < steps; i++) {
        float d = (float(i) + dither) * stepSize;
        vec3 p = rayStart + rayDir * d;
        float worldY = p.y + global.cam_pos.y;
        float heightFactor = exp(-max(worldY, 0.0) * 0.05);
        float stepDensity = density * heightFactor;
        if (stepDensity > 0.0001) {
            float shadow = getVolShadow(p, d);
            vec3 stepScattering = sunColor * phase * stepDensity * shadow * stepSize;
            accumulatedScattering += stepScattering * transmittance;
            transmittance *= exp(-stepDensity * stepSize);
            if (transmittance < 0.01) break;
        }
    }
    return vec4(accumulatedScattering, transmittance);
}

void main() {
    vec3 color;
    float outputAlpha = 1.0;
    float debugDirectKey = 0.0;
    float debugSkyFill = 0.0;
    float debugBlockLight = clamp(max(vBlockLight.r, max(vBlockLight.g, vBlockLight.b)), 0.0, 1.0);
    float debugOutdoor = baselineOutdoorFactor(vSkyLight);
    const float AO_FADE_DISTANCE = 128.0;
    const float TEXTURE_FADE_START = 32.0;
    const float TEXTURE_FADE_END = 128.0;
    // Keep world positions/normals in the main-origin coordinate system for
    // shadows and LPV, but evaluate view-dependent terms from the reflected eye.
    vec3 eye = vec3(0.0);
    if (WATER_REFLECTION) eye.y = 2.0 * (64.0 - global.cam_pos.y);
    float viewDistance = length(vFragPosWorld - eye);
    float textureDetail = 1.0 - smoothstep(TEXTURE_FADE_START, TEXTURE_FADE_END, viewDistance);

    vec2 tileBase = vec2(mod(float(vTileID), 16.0), floor(float(vTileID) / 16.0)) * (1.0 / 16.0);
    vec2 tiledUV = fract(vTexCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    vec2 uv = tileBase + tiledUV * (1.0 / 16.0);

    bool isCloud = vCloud > 0.5;
    vec3 N = normalize(vNormal);
    vec4 normalMapSample = vec4(0.5, 0.5, 1.0, 0.0);
    if (!isCloud && global.lighting.z > 0.5 && global.pbr_params.x > 1.5 && textureDetail > 0.2) {
        normalMapSample = texture(uNormalMap, uv);
        vec3 T = normalize(vTangent - N * dot(N, vTangent));
        float handedness = dot(cross(N, T), vBitangent) < 0.0 ? -1.0 : 1.0;
        mat3 TBN = mat3(T, normalize(cross(N, T)) * handedness, N);
        vec3 mappedNormal = normalize(TBN * (normalMapSample.rgb * 2.0 - 1.0));
        N = normalize(mix(N, mappedNormal, textureDetail));
    }

    vec3 L = normalize(global.sun_dir.xyz);
    float skyVisibility = clamp(vSkyLight, 0.0, 1.0);
    float atmosphericVisibility = skyVisibilityFactor(skyVisibility);
    float cascadeDistance = max(vViewDepth, 0.0);
    float debugChannel = global.viewport_size.w;
    bool debugNeedsLayer = global.viewport_size.z > 0.5 &&
        debugChannel >= DEBUG_SHADOW_FACTOR + 0.5 && debugChannel < DEBUG_SEAM_DIAG + 0.5;
    bool needsShadow = !isCloud && global.shadow_params.z > 0.0;
    int layer = 0;
    if (needsShadow || debugNeedsLayer) {
        layer = selectShadowCascade(vFragPosWorld, cascadeDistance);
    }
    float shadowFactor = 0.0;
    // Shadow maps have one mip, identical min/mag filters and no anisotropy.
    if (needsShadow) {
        shadowFactor = computeShadowCascades(vFragPosWorld, N, L, cascadeDistance, layer);
        shadowFactor *= 1.0 - smoothstep(shadows.fade_params.x, shadows.fade_params.y, cascadeDistance);
    }
    
    float totalShadow = shadowFactor * clamp(global.shadow_params.z, 0.0, 1.0);

    float ssao = 1.0;
    if (global.pbr_params.w != 0.0) {
        ssao = mix(1.0, texture(uSSAOMap, gl_FragCoord.xy / global.viewport_size.xy).r, global.pbr_params.w);
    }
    float ao = mix(1.0, vAO, mix(0.4, 0.05, clamp(viewDistance / AO_FADE_DISTANCE, 0.0, 1.0)));

    vec3 albedo = vColor;
    float roughness = 0.85;
    if (!isCloud && global.lighting.y > 0.5) {
        vec4 texColor = texture(uTexture, uv);
        if (texColor.a < 0.1) discard;
        outputAlpha = texColor.a;
        vec3 flatTexColor = sampleTileAverage(tileBase) * vColor;
        albedo = mix(flatTexColor, texColor.rgb * vColor, textureDetail);
        if (global.lighting.z > 0.5 && global.pbr_params.x > 0.5) {
            roughness = texture(uRoughnessMap, uv).r;
        }
    }
    vec3 V = normalize(eye - vFragPosWorld);
    color = computeTerrainLighting(albedo, N, V, L, clamp(roughness, 0.05, 1.0), totalShadow, vSkyLight * global.lighting.x, skyVisibility, vBlockLight, ao, ssao, debugDirectKey, debugSkyFill, debugBlockLight, debugOutdoor);

    if (global.volumetric_params.x > 0.5) {
        float shaftDither = interleavedGradientNoise(gl_FragCoord.xy + vec2(global.params.x));
        if (atmosphericVisibility > 0.01) {
            vec4 volumetric = computeVolumetric(eye, vFragPosWorld, shaftDither);
            volumetric.rgb *= atmosphericVisibility;
            color = color * volumetric.a + volumetric.rgb;
        }
    }

    if (global.params.z > 0.5) {
        float rawFog = clamp(1.0 - exp(-viewDistance * global.params.y), 0.0, 1.0);
        float fogFactor = rawFog * rawFog * 0.72 * atmosphericVisibility;
        color = mix(color, global.fog_color.rgb, fogFactor);
    }

    if (global.viewport_size.z > 0.5 && debugChannel > 0.5) {
        if (debugChannel < DEBUG_SHADOW_FACTOR + 0.5) {
            color = vec3(clamp(shadowFactor, 0.0, 1.0));
        } else if (debugChannel < DEBUG_CASCADE_INDEX + 0.5) {
            color = (layer == 0) ? vec3(1.0, 0.2, 0.2)
                  : (layer == 1) ? vec3(0.2, 1.0, 0.2)
                  : (layer == 2) ? vec3(0.2, 0.4, 1.0)
                  : vec3(0.8, 0.3, 1.0);
        } else if (debugChannel < DEBUG_CASTER_COVERAGE + 0.5) {
            vec3 projCoords = shadowProjCoords(vFragPosWorld, layer);
            bool inBounds = projCoords.x >= 0.0 && projCoords.x <= 1.0 && projCoords.y >= 0.0 && projCoords.y <= 1.0 && projCoords.z >= 0.0 && projCoords.z <= 1.0;
            float mapDepth = inBounds ? fetchShadowDepthNearest(projCoords.xy, layer) : 0.0;
            float fragDepth = projCoords.z;
            float hasCaster = (mapDepth > 0.001) ? 1.0 : 0.0;
            float isInShadow = (mapDepth > fragDepth + 0.0001) ? 1.0 : 0.0;
            color = inBounds ? vec3(hasCaster * 0.3, isInShadow * 0.5 + 0.2, mapDepth) : vec3(1.0, 0.0, 1.0);
        } else if (debugChannel < DEBUG_SEAM_DIAG + 0.5) {
            float nextSplit = shadows.cascade_splits[layer];
            float blendStart = layer < 3 ? shadows.overlap_starts[layer + 1] : nextSplit;
            float distToSplit = abs(cascadeDistance - nextSplit) / max(nextSplit, 0.01);
            float inBlend = (cascadeDistance > blendStart && layer < 3) ? (cascadeDistance - blendStart) / max(nextSplit - blendStart, 0.01) : 0.0;
            float splitLine = 1.0 - smoothstep(0.0, 0.05, distToSplit);
            color = vec3(splitLine, distToSplit * 2.0, clamp(inBlend, 0.0, 1.0));
        } else if (debugChannel < DEBUG_TILE_ID + 0.5) {
            if (vTileID < 0) {
                color = vec3(1.0, 0.0, 1.0);
            } else if (vTileID == 0) {
                color = vec3(1.0, 1.0, 1.0);
            } else {
                float tid = float(vTileID);
                color = vec3(fract(tid * 0.618), fract(tid * 0.381), fract(tid * 0.236));
            }
        } else if (debugChannel < DEBUG_TEX_COLOR + 0.5) {
            vec4 texColor = texture(uTexture, uv);
            color = texColor.rgb;
        } else if (debugChannel < DEBUG_DIRECT_KEY + 0.5) {
            color = mix(vec3(0.02, 0.02, 0.02), vec3(1.0, 0.80, 0.28), debugDirectKey);
        } else if (debugChannel < DEBUG_SKY_FILL + 0.5) {
            color = mix(vec3(0.02, 0.02, 0.02), vec3(0.30, 0.70, 1.0), debugSkyFill);
        } else if (debugChannel < DEBUG_BLOCK_LIGHT + 0.5) {
            color = clamp(vBlockLight, 0.0, 1.0);
        } else if (debugChannel < DEBUG_OUTDOOR_FACTOR + 0.5) {
            color = vec3(debugOutdoor);
        } else if (debugChannel < DEBUG_SKYLIGHT + 0.5) {
            color = vec3(clamp(vSkyLight, 0.0, 1.0));
        } else if (debugChannel < DEBUG_AMBIENT_OCCLUSION + 0.5) {
            color = vec3(clamp(vAO, 0.0, 1.0));
        }
    }

    FragColor = vec4(color, outputAlpha);
}
