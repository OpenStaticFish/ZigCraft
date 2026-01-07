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

layout(location = 0) out vec4 FragColor;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 fog_color;
    vec4 cloud_wind_offset; // xy = offset, z = scale, w = coverage
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    vec4 cloud_params; // x = cloud_height, y = shadow_samples, z = shadow_blend, w = cloud_shadows
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation, w = unused
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
    for (int i = 0; i < 2; i++) { // Optimized: 2 octaves instead of 4
        v += a * cloudNoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

float getCloudShadow(vec3 worldPos, vec3 sunDir) {
    // Project position along sun direction to cloud plane
    vec2 shadowOffset = sunDir.xz * (global.cloud_params.x - worldPos.y) / max(sunDir.y, 0.1);
    vec2 samplePos = (worldPos.xz + shadowOffset + global.cloud_wind_offset.xy) * global.cloud_wind_offset.z;
    
    float cloudValue = cloudFbm(samplePos * 0.5); // Optimized: single FBM call
    
    float threshold = 1.0 - global.cloud_wind_offset.w;
    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    
    return cloudMask * global.lighting.w;
}

layout(set = 0, binding = 1) uniform sampler2D uTexture;         // Diffuse/albedo
layout(set = 0, binding = 6) uniform sampler2D uNormalMap;       // Normal map (OpenGL format)
layout(set = 0, binding = 7) uniform sampler2D uRoughnessMap;    // Roughness map
layout(set = 0, binding = 8) uniform sampler2D uDisplacementMap; // Displacement map (unused for now)
layout(set = 0, binding = 9) uniform sampler2D uEnvMap;          // Environment Map (EXR)

layout(set = 0, binding = 2) uniform ShadowUniforms {
    mat4 light_space_matrices[3];
    vec4 cascade_splits;
    vec4 shadow_texel_sizes;
} shadows;

layout(set = 0, binding = 3) uniform sampler2DArrayShadow uShadowMaps;

layout(push_constant) uniform ModelUniforms {
    mat4 view_proj;
    mat4 model;
    float mask_radius;
    float _pad0;
    float _pad1;
    float _pad2;
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

    // Adjusted bias for hardware PCF
    float bias = max(0.0005 * (1.0 - nDotL), 0.0001);
    if (layer == 1) bias *= 2.0;
    if (layer == 2) bias *= 4.0;

    float shadow = 0.0;
    vec2 texelSize = 1.0 / vec2(textureSize(uShadowMaps, 0));

    const int MAX_SAMPLES = 16;
    int sampleCount = int(global.cloud_params.y);
    if (sampleCount > MAX_SAMPLES) sampleCount = MAX_SAMPLES;
    if (sampleCount < 1) sampleCount = 1;

    // For low sample counts (<=4), use simple grid PCF without rotation
    // This avoids Moire patterns from rotated sparse sampling
    if (sampleCount <= 4) {
        // Simple 2x2 grid PCF - clean and fast
        for (int x = -1; x <= 1; x += 2) {
            for (int y = -1; y <= 1; y += 2) {
                vec2 offset = vec2(float(x), float(y)) * texelSize * 0.5;
                vec4 shadowCoord = vec4(projCoords.xy + offset, float(layer), currentDepth + bias);
                shadow += texture(uShadowMaps, shadowCoord);
            }
        }
        return 1.0 - (shadow / 4.0);
    }

    // Stable 3x3 Box PCF for higher quality (removes rotation noise/moire)
    float shadowSum = 0.0;
    for (int x = -1; x <= 1; ++x) {
        for (int y = -1; y <= 1; ++y) {
            vec2 offset = vec2(float(x), float(y)) * texelSize;
            vec4 shadowCoord = vec4(projCoords.xy + offset, float(layer), currentDepth + bias);
            shadowSum += texture(uShadowMaps, shadowCoord);
        }
    }
    return 1.0 - (shadowSum / 9.0);
}

// PBR functions
const float PI = 3.14159265359;

// Normal Distribution Function (GGX/Trowbridge-Reitz)
float DistributionGGX(vec3 N, vec3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    
    float nom = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    
    return nom / max(denom, 0.0001);
}

// Geometry function (Schlick-GGX)
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    
    float nom = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    
    return nom / max(denom, 0.0001);
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    
    return ggx1 * ggx2;
}

// Fresnel (Schlick approximation)
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// AgX Tone Mapping (from Blender 4.0+)
// Superior color preservation compared to ACES - doesn't desaturate highlights
// Reference: https://github.com/sobotka/AgX

// AgX Log2 encoding for HDR input
vec3 agxDefaultContrastApprox(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

vec3 agx(vec3 val) {
    const mat3 agx_mat = mat3(
        0.842479062253094, 0.0423282422610123, 0.0423756549057051,
        0.0784335999999992, 0.878468636469772, 0.0784336,
        0.0792237451477643, 0.0791661274605434, 0.879142973793104
    );
    
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    
    // Input transform (sRGB to AgX working space)
    val = agx_mat * val;
    
    // Log2 encoding
    val = clamp(log2(val), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    
    // Apply sigmoid contrast curve
    val = agxDefaultContrastApprox(val);
    
    return val;
}

vec3 agxEotf(vec3 val) {
    const mat3 agx_mat_inv = mat3(
        1.19687900512017, -0.0528968517574562, -0.0529716355144438,
        -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
        -0.0990297440797205, -0.0989611768448433, 1.15107367264116
    );
    
    // Inverse input transform
    val = agx_mat_inv * val;
    
    // sRGB IEC 61966-2-1 2.2 Exponent Reference EOTF Display
    return pow(val, vec3(2.2));
}

// Optional: Add punch/saturation to AgX output
vec3 agxLook(vec3 val, float saturation, float contrast) {
    float luma = dot(val, vec3(0.2126, 0.7152, 0.0722));
    
    // Saturation adjustment
    val = luma + saturation * (val - luma);
    
    // Contrast adjustment around mid-gray
    val = 0.5 + contrast * (val - 0.5);
    
    return val;
}

// Complete AgX pipeline with optional look adjustment
vec3 agxToneMap(vec3 color, float exposure, float saturation) {
    // Apply exposure
    color *= exposure;
    
    // Ensure no negative values
    color = max(color, vec3(0.0));
    
    // AgX transform
    color = agx(color);
    
    // Apply look (subtle saturation boost to counter any desaturation)
    color = agxLook(color, saturation, 1.0);
    
    // Inverse EOTF (linearize for display)
    color = agxEotf(color);
    
    // Clamp output
    return clamp(color, 0.0, 1.0);
}

vec2 SampleSphericalMap(vec3 v) {
    // Clamp the normal to avoid precision issues at poles
    vec3 n = normalize(v);
    // Use a more stable formula that avoids singularities
    float phi = atan(n.z, n.x);  // Azimuth angle
    float theta = acos(clamp(n.y, -1.0, 1.0));  // Polar angle (more stable than asin)
    
    vec2 uv;
    uv.x = phi / (2.0 * PI) + 0.5;
    uv.y = theta / PI;
    return uv;
}

void main() {
    // Calculate UV coordinates in atlas
    vec2 atlasSize = vec2(16.0, 16.0);
    vec2 tileSize = 1.0 / atlasSize;
    vec2 tilePos = vec2(mod(float(vTileID), atlasSize.x), floor(float(vTileID) / atlasSize.x));
    vec2 tiledUV = fract(vTexCoord);
    tiledUV = clamp(tiledUV, 0.001, 0.999);
    vec2 uv = (tilePos + tiledUV) * tileSize;

    // Get normal for lighting
    vec3 N = normalize(vNormal);
    
    // PBR: Sample normal map and transform to world space
    vec4 normalMapSample = vec4(0.5, 0.5, 1.0, 0.0);
    // Optimized: Only sample normal map if PBR is enabled AND quality is high enough
    if (global.lighting.z > 0.5 && global.pbr_params.x > 1.5 && vTileID >= 0) {
        normalMapSample = texture(uNormalMap, uv);
        
        vec3 normalMapValue = normalMapSample.rgb * 2.0 - 1.0; // Convert from [0,1] to [-1,1]
        
        // Build TBN matrix
        vec3 T = normalize(vTangent);
        vec3 B = normalize(vBitangent);
        mat3 TBN = mat3(T, B, N);
        
        // Transform normal from tangent space to world space
        N = normalize(TBN * normalMapValue);
    }

    float nDotL = max(dot(N, global.sun_dir.xyz), 0.0);

    int layer = 2;
    float depth = vViewDepth;
    if (depth < shadows.cascade_splits.x) {
        layer = 0;
    } else if (depth < shadows.cascade_splits.y) {
        layer = 1;
    }

    float shadow = calculateShadow(vFragPosWorld, nDotL, layer);

    float blendThreshold = 0.9;
    if (global.cloud_params.z > 0.5 && layer < 2) {
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
    if (global.cloud_params.w > 0.5 && global.params.w > 0.05 && global.sun_dir.y > 0.05) {
        cloudShadow = getCloudShadow(vFragPosWorld, global.sun_dir.xyz);
    }
    
    float totalShadow = min(shadow + cloudShadow, 1.0);

    // Circular masking for LODs (Issue #119: Seamless transition)
    if (vTileID < 0 && model_data.mask_radius > 0.0) {
        float horizontalDist = length(vFragPosWorld.xz);
        if (horizontalDist < model_data.mask_radius * 16.0) discard;
    }

    vec3 color;
    if (global.lighting.y > 0.5 && vTileID >= 0) {
        vec4 texColor = texture(uTexture, uv);
        if (texColor.a < 0.1) discard;

        // Albedo is already in linear space (VK_FORMAT_R8G8B8A8_SRGB does hardware decode)
        // vColor is also in linear space (vertex colors)
        vec3 albedo = texColor.rgb * vColor;

        // PBR lighting - Only calculate if maps are present and it's enabled
        if (global.lighting.z > 0.5 && global.pbr_params.x > 0.5) {
            bool hasNormalMap = normalMapSample.a > 0.5;
            
            // Sample roughness (now packed: R=roughness, G=displacement)
            vec4 packedPBR = texture(uRoughnessMap, uv);
            float roughness = packedPBR.r;
            bool hasPBR = hasNormalMap || (roughness < 0.99);

            if (hasPBR) {
                roughness = clamp(roughness, 0.05, 1.0);
                
                // For blocks, we use a low metallic value (non-metals)
                float metallic = 0.0;
                
                // Use the normal calculated earlier (already includes normal mapping if quality > 1.5)
                // Calculate view direction
                vec3 V = normalize(global.cam_pos.xyz - vFragPosWorld);
                vec3 L = normalize(global.sun_dir.xyz);
                vec3 H = normalize(V + L);
                
                // Calculate reflectance at normal incidence (F0)
                vec3 F0 = vec3(0.04);
                F0 = mix(F0, albedo, metallic);
                
                // Cook-Torrance BRDF
                float NDF = DistributionGGX(N, H, roughness);
                float G = GeometrySmith(N, V, L, roughness);
                vec3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);
                
                vec3 numerator = NDF * G * F;
                float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
                vec3 specular = numerator / denominator;
                
                vec3 kS = F;
                vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
                
                float NdotL = max(dot(N, L), 0.0);
                vec3 sunColor = vec3(1.0, 0.98, 0.95) * global.params.w;
                vec3 Lo = (kD * albedo / PI + specular) * sunColor * NdotL * (1.0 - totalShadow);
                
                // Ambient lighting (IBL)
                vec2 envUV = SampleSphericalMap(normalize(N));
                vec3 envColor = texture(uEnvMap, envUV).rgb;
                
                float skyLight = vSkyLight * global.lighting.x;
                vec3 blockLight = vBlockLight;
                // IBL intensity 0.8 - more visible effect from HDRI
                // Clamp envColor to prevent HDR values from blowing out
                // Apply AO to ambient lighting (darkens corners and crevices)
                vec3 ambientColor = albedo * (min(envColor, vec3(3.0)) * skyLight * 0.8 + blockLight) * vAO;
                
                color = ambientColor + Lo;
            } else {
                // Non-PBR blocks with PBR enabled: use simplified IBL-aware lighting
                float directLight = nDotL * global.params.w * (1.0 - totalShadow);
                vec3 blockLight = vBlockLight;
                
                // Sample IBL for ambient (even for non-PBR blocks)
                vec2 envUV = SampleSphericalMap(normalize(N));
                vec3 envColor = texture(uEnvMap, envUV).rgb;
                
                // IBL ambient with intensity 0.8 for non-PBR blocks
                float skyLight = vSkyLight * global.lighting.x;
                // Apply AO to ambient lighting
                vec3 ambientColor = albedo * (min(envColor, vec3(3.0)) * skyLight * 0.8 + blockLight) * vAO;
                
                // Direct lighting
                vec3 sunColor = vec3(1.0, 0.98, 0.95) * global.params.w;
                vec3 directColor = albedo * sunColor * nDotL * (1.0 - totalShadow);
                
                color = ambientColor + directColor;
            }
        } else {
            // Legacy lighting (PBR disabled)
            float directLight = nDotL * global.params.w * (1.0 - totalShadow);
            float skyLight = vSkyLight * (global.lighting.x + directLight * 0.8);
            vec3 blockLight = vBlockLight;
            float lightLevel = max(skyLight, max(blockLight.r, max(blockLight.g, blockLight.b)));
            lightLevel = max(lightLevel, global.lighting.x * 0.5);
            lightLevel = clamp(lightLevel, 0.0, 1.0);
            
            // Apply AO to legacy lighting
            color = albedo * lightLevel * vAO;
        }
    } else {
        // Vertex color only mode
        float directLight = nDotL * global.params.w * (1.0 - totalShadow);
        float skyLight = vSkyLight * (global.lighting.x + directLight * 0.8);
        vec3 blockLight = vBlockLight;
        float lightLevel = max(skyLight, max(blockLight.r, max(blockLight.g, blockLight.b)));
        lightLevel = max(lightLevel, global.lighting.x * 0.5);
        lightLevel = clamp(lightLevel, 0.0, 1.0);
        
        // Apply AO to vertex color mode
        color = vColor * lightLevel * vAO;
    }

    // Fog
    if (global.params.z > 0.5) {
        float fogFactor = 1.0 - exp(-vDistance * global.params.y);
        fogFactor = clamp(fogFactor, 0.0, 1.0);
        color = mix(color, global.fog_color.rgb, fogFactor);
    }

    // Tone mapping (AgX - superior color preservation from Blender 4.0+)
    if (global.lighting.z > 0.5) {
        // Use exposure and saturation from uniforms (pbr_params.y and pbr_params.z)
        float exposure = global.pbr_params.y;
        float saturation = global.pbr_params.z;
        
        // Ensure valid defaults if uniforms are zero
        if (exposure <= 0.0) exposure = 1.0;
        if (saturation <= 0.0) saturation = 1.1;
        
        color = agxToneMap(color, exposure, saturation);
        // Gamma correction (AgX outputs linear, we need sRGB for display)
        color = pow(color, vec3(1.0 / 2.2));
    }

    FragColor = vec4(color, 1.0);
}
