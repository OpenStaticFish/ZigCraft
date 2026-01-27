#version 450

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
layout(location = 14) in float vMaskRadius;

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset; // xy = offset, z = scale, w = coverage
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    vec4 cloud_params; // x = cloud_height, y = shadow_samples, z = shadow_blend, w = cloud_shadows
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation, w = ssao_strength
    vec4 volumetric_params; // x = enabled, y = density, z = steps, w = scattering
    vec4 viewport_size; // xy = width/height
} global;

// Constants
const float PI = 3.14159265359;

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
    for (int i = 0; i < 2; i++) { 
        v += a * cloudNoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

// 4x4 Bayer matrix for dithered LOD transitions
float bayerDither4x4(vec2 position) {
    const float bayerMatrix[16] = float[](
        0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
        12.0/16.0, 4.0/16.0, 14.0/16.0,  6.0/16.0,
        3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
        15.0/16.0, 7.0/16.0, 13.0/16.0,  5.0/16.0
    );
    int x = int(mod(position.x, 4.0));
    int y = int(mod(position.y, 4.0));
    return bayerMatrix[x + y * 4];
}

float getCloudShadow(vec3 worldPos, vec3 sunDir) {
    vec3 actualWorldPos = worldPos + global.cam_pos.xyz;
    vec2 shadowOffset = sunDir.xz * (global.cloud_params.x - actualWorldPos.y) / max(sunDir.y, 0.1);
    vec2 samplePos = (actualWorldPos.xz + shadowOffset + global.cloud_wind_offset.xy) * global.cloud_wind_offset.z;
    float cloudValue = cloudFbm(samplePos * 0.5);
    float threshold = 1.0 - global.cloud_wind_offset.w;
    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    return cloudMask * global.lighting.w;
}

layout(set = 0, binding = 1) uniform sampler2D uTexture;         // Diffuse/albedo
layout(set = 0, binding = 6) uniform sampler2D uNormalMap;       // Normal map (OpenGL format)
layout(set = 0, binding = 7) uniform sampler2D uRoughnessMap;    // Roughness map
layout(set = 0, binding = 8) uniform sampler2D uDisplacementMap; // Displacement map (unused for now)
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;          // Environment Map (EXR)
layout(set = 0, binding = 10) uniform sampler2D uSSAOMap;       // SSAO Map

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[3];
    vec4 cascade_splits;
    vec4 shadow_texel_sizes;
} shadows;

layout(set = 0, binding = 3) uniform sampler2DArrayShadow uShadowMaps;
layout(set = 0, binding = 4) uniform sampler2DArray uShadowMapsRegular;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec3 color_override;
    float mask_radius;
} model_data;

// Poisson Disk for PCF
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

float interleavedGradientNoise(vec2 fragCoord) {
    vec3 magic = vec3(0.06711056, 0.00583715, 52.9829189);
    return fract(magic.z * fract(dot(fragCoord.xy, magic.xy)));
}

float findBlocker(vec2 uv, float zReceiver, int layer) {
    float blockerDepthSum = 0.0;
    int numBlockers = 0;
    float searchRadius = 0.0015;
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            vec2 offset = vec2(i, j) * searchRadius;
            float depth = texture(uShadowMapsRegular, vec3(uv + offset, float(layer))).r;
            if (depth > zReceiver + 0.0001) {
                blockerDepthSum += depth;
                numBlockers++;
            }
        }
    }
    if (numBlockers == 0) return -1.0;
    return blockerDepthSum / float(numBlockers);
}

float computeShadowFactor(vec3 fragPosWorld, vec3 N, vec3 L, int layer) {
    vec4 fragPosLightSpace = shadows.light_space_matrices[layer] * vec4(fragPosWorld, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    
    // Bounds check: if outside current cascade, return lit (0.0 shadow factor)
    if (projCoords.x < 0.0 || projCoords.x > 1.0 || projCoords.y < 0.0 || projCoords.y > 1.0 || projCoords.z < 0.0 || projCoords.z > 1.0) return 0.0;

    float currentDepth = projCoords.z;
    float texelSize = shadows.shadow_texel_sizes[layer];
    float baseTexelSize = shadows.shadow_texel_sizes[0];
    float cascadeScale = texelSize / max(baseTexelSize, 0.0001);
    
    float NdotL = max(dot(N, L), 0.001);
    float sinTheta = sqrt(1.0 - NdotL * NdotL);
    float tanTheta = sinTheta / NdotL;
    
    // Reverse-Z Bias: push fragment CLOSER to light (towards Near=1.0)
    const float BASE_BIAS = 0.0015;
    const float SLOPE_BIAS = 0.003;
    const float MAX_BIAS = 0.012;
    
    float bias = BASE_BIAS * cascadeScale + SLOPE_BIAS * min(tanTheta, 5.0) * cascadeScale;
    bias = min(bias, MAX_BIAS);
    if (vTileID < 0) bias = max(bias, 0.006 * cascadeScale);

    float angle = interleavedGradientNoise(gl_FragCoord.xy) * PI * 0.25;
    float s = sin(angle);
    float c = cos(angle);
    mat2 rot = mat2(c, s, -s, c);
    
    float shadow = 0.0;
    float radius = 0.0015 * cascadeScale;
    for (int i = 0; i < 16; i++) {
        vec2 offset = (rot * poissonDisk16[i]) * radius;
        // GREATER_OR_EQUAL comparison: returns 1.0 if (currentDepth + bias) >= mapDepth
        shadow += texture(uShadowMaps, vec4(projCoords.xy + offset, float(layer), currentDepth + bias));
    }
    // shadow factor: 1.0 (Shadowed) to 0.0 (Lit)
    return 1.0 - (shadow / 16.0);
}

float computeShadowCascades(vec3 fragPosWorld, vec3 N, vec3 L, float viewDepth, int layer) {
    float shadow = computeShadowFactor(fragPosWorld, N, L, layer);
    
    // Cascade blending transition
    if (layer < 2) {
        float nextSplit = shadows.cascade_splits[layer];
        float blendThreshold = nextSplit * 0.8;
        if (viewDepth > blendThreshold) {
            float blend = (viewDepth - blendThreshold) / (nextSplit - blendThreshold);
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
const float LEGACY_LIGHTING_INTENSITY = 2.5;  
const float LOD_LIGHTING_INTENSITY = 1.5;     
const float NON_PBR_ROUGHNESS = 0.5;          
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

vec3 computeLegacyDirect(vec3 albedo, float nDotL, float totalShadow, float skyLightIn, vec3 blockLightIn, float intensityFactor) {
    float directLight = nDotL * global.params.w * (1.0 - totalShadow) * intensityFactor;
    float skyLight = skyLightIn * (global.lighting.x + directLight * 1.0);
    float lightLevel = max(skyLight, max(blockLightIn.r, max(blockLightIn.g, blockLightIn.b)));
    lightLevel = max(lightLevel, global.lighting.x * 0.5);
    float shadowFactor = mix(1.0, 0.5, totalShadow);
    lightLevel = clamp(lightLevel * shadowFactor, 0.0, 1.0);
    return albedo * lightLevel;
}

vec3 computePBR(vec3 albedo, vec3 N, vec3 V, vec3 L, float roughness, float totalShadow, float skyLight, vec3 blockLight, float ao, float ssao) {
    vec3 brdf = computeBRDF(albedo, N, V, L, roughness);
    float NdotL_final = max(dot(N, L), 0.0);
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_RADIANCE_TO_IRRADIANCE / PI;
    vec3 Lo = brdf * sunColor * NdotL_final * (1.0 - totalShadow);
    vec3 envColor = computeIBLAmbient(N, roughness);
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 ambientColor = albedo * (max(min(envColor, IBL_CLAMP) * skyLight * 0.8, vec3(global.lighting.x * 0.8)) + blockLight) * ao * ssao * shadowAmbientFactor;
    return ambientColor + Lo;
}

vec3 computeNonPBR(vec3 albedo, vec3 N, float nDotL, float totalShadow, float skyLight, vec3 blockLight, float ao, float ssao) {
    vec3 envColor = computeIBLAmbient(N, NON_PBR_ROUGHNESS);
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 ambientColor = albedo * (max(min(envColor, IBL_CLAMP) * skyLight * 0.8, vec3(global.lighting.x * 0.8)) + blockLight) * ao * ssao * shadowAmbientFactor;
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_RADIANCE_TO_IRRADIANCE / PI;
    vec3 directColor = albedo * sunColor * nDotL * (1.0 - totalShadow);
    return ambientColor + directColor;
}

vec3 computeLOD(vec3 albedo, float nDotL, float totalShadow, float skyLightVal, vec3 blockLight, float ao, float ssao) {
    float shadowAmbientFactor = mix(1.0, 0.2, totalShadow);
    vec3 ambientColor = albedo * (max(vec3(skyLightVal * 0.8), vec3(global.lighting.x * 0.4)) + blockLight) * ao * ssao * shadowAmbientFactor;
    vec3 sunColor = global.sun_color.rgb * global.params.w * SUN_VOLUMETRIC_INTENSITY / PI;
    vec3 directColor = albedo * sunColor * nDotL * (1.0 - totalShadow);
    return ambientColor + directColor;
}

// Simple shadow sampler for volumetric points, optimized
float getVolShadow(vec3 p, float viewDepth) {
    int layer = 2;
    if (viewDepth < shadows.cascade_splits[0]) layer = 0;
    else if (viewDepth < shadows.cascade_splits[1]) layer = 1;
    vec4 lightSpacePos = shadows.light_space_matrices[layer] * vec4(p, 1.0);
    vec3 proj = lightSpacePos.xyz / lightSpacePos.w;
    proj.xy = proj.xy * 0.5 + 0.5;
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z > 1.0) return 1.0;
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
        float heightFactor = exp(-max(p.y, 0.0) * 0.05);
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
    const float LOD_TRANSITION_WIDTH = 24.0;
    const float AO_FADE_DISTANCE = 128.0;

    if (vTileID < 0 && vMaskRadius > 0.0) {
        float distFromMask = vDistance - vMaskRadius;
        float fade = clamp(distFromMask / LOD_TRANSITION_WIDTH, 0.0, 1.0);
        float ditherThreshold = bayerDither4x4(gl_FragCoord.xy);
        if (fade < ditherThreshold) discard;
    }
    
    vec2 tiledUV = fract(vTexCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    vec2 uv = (vec2(mod(float(vTileID), 16.0), floor(float(vTileID) / 16.0)) + tiledUV) * (1.0 / 16.0);

    vec3 N = normalize(vNormal);
    vec4 normalMapSample = vec4(0.5, 0.5, 1.0, 0.0);
    if (global.lighting.z > 0.5 && global.pbr_params.x > 1.5 && vTileID >= 0) {
        normalMapSample = texture(uNormalMap, uv);
        mat3 TBN = mat3(normalize(vTangent), normalize(vBitangent), N);
        N = normalize(TBN * (normalMapSample.rgb * 2.0 - 1.0));
    }

    vec3 L = normalize(global.sun_dir.xyz);
    float nDotL = max(dot(N, L), 0.0);
    int layer = vDistance < shadows.cascade_splits[0] ? 0 : (vDistance < shadows.cascade_splits[1] ? 1 : 2);
    float shadowFactor = computeShadowCascades(vFragPosWorld, N, L, vDistance, layer);
    
    float cloudShadow = (global.cloud_params.w > 0.5 && global.params.w > 0.05 && global.sun_dir.y > 0.05) ? getCloudShadow(vFragPosWorld, global.sun_dir.xyz) : 0.0;
    float totalShadow = min(shadowFactor + cloudShadow, 1.0);

    float ssao = mix(1.0, texture(uSSAOMap, gl_FragCoord.xy / global.viewport_size.xy).r, global.pbr_params.w);
    float ao = mix(1.0, vAO, mix(0.4, 0.05, clamp(vDistance / AO_FADE_DISTANCE, 0.0, 1.0)));
    
    if (global.lighting.y > 0.5 && vTileID >= 0) {
        vec4 texColor = texture(uTexture, uv);
        if (texColor.a < 0.1) discard;
        vec3 albedo = texColor.rgb * vColor;

        if (global.lighting.z > 0.5 && global.pbr_params.x > 0.5) {
            float roughness = texture(uRoughnessMap, uv).r;
            if (normalMapSample.a > 0.5 || roughness < 0.99) {
                vec3 V = normalize(global.cam_pos.xyz - vFragPosWorld);
                color = computePBR(albedo, N, V, L, clamp(roughness, 0.05, 1.0), totalShadow, vSkyLight * global.lighting.x, vBlockLight, ao, ssao);
            } else {
                color = computeNonPBR(albedo, N, nDotL, totalShadow, vSkyLight * global.lighting.x, vBlockLight, ao, ssao);
            }
        } else {
            color = computeLegacyDirect(albedo, nDotL, totalShadow, vSkyLight, vBlockLight, LEGACY_LIGHTING_INTENSITY) * ao * ssao;
        }
    } else {
        if (vTileID < 0) {
            color = computeLOD(vColor, nDotL, totalShadow, vSkyLight * global.lighting.x, vBlockLight, ao, ssao);
        } else {
            color = computeLegacyDirect(vColor, nDotL, totalShadow, vSkyLight, vBlockLight, LOD_LIGHTING_INTENSITY) * ao * ssao;
        }
    }

    if (global.volumetric_params.x > 0.5) {
        vec4 volumetric = computeVolumetric(vec3(0.0), vFragPosWorld, cloudHash(gl_FragCoord.xy + vec2(global.params.x)));
        color = color * volumetric.a + volumetric.rgb;
    }

    if (global.params.z > 0.5) {
        color = mix(color, global.fog_color.rgb, clamp(1.0 - exp(-vDistance * global.params.y), 0.0, 1.0));
    }

    if (global.viewport_size.z > 0.5) {
        color = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), totalShadow);
    }

    FragColor = vec4(color, 1.0);
}
