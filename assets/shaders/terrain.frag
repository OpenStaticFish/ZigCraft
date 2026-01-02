#version 330 core
in vec3 vColor;
flat in vec3 vNormal;
in vec2 vTexCoord;
flat in int vTileID;
in float vDistance;
in float vSkyLight;
in float vBlockLight;
in vec3 vFragPosWorld;
in float vViewDepth;
out vec4 FragColor;

uniform sampler2D uTexture;
uniform bool uUseTexture;
uniform vec3 uSunDir;
uniform float uSunIntensity;
uniform float uAmbient;
uniform vec3 uFogColor;
uniform float uFogDensity;
uniform bool uFogEnabled;

// CSM
uniform sampler2D uShadowMap0;
uniform sampler2D uShadowMap1;
uniform sampler2D uShadowMap2;
uniform mat4 uLightSpaceMatrices[3];
uniform float uCascadeSplits[3];
uniform float uShadowTexelSizes[3];

// Cloud shadows
uniform float uCloudWindOffsetX;
uniform float uCloudWindOffsetZ;
uniform float uCloudScale;
uniform float uCloudCoverage;
uniform float uCloudShadowStrength;
uniform float uCloudHeight;

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
    // This creates moving shadows that follow the sun
    vec2 shadowOffset = sunDir.xz * (uCloudHeight - worldPos.y) / max(sunDir.y, 0.1);
    vec2 samplePos = (worldPos.xz + shadowOffset + vec2(uCloudWindOffsetX, uCloudWindOffsetZ)) * uCloudScale;
    
    float n1 = cloudFbm(samplePos * 0.5);
    float n2 = cloudFbm(samplePos * 2.0 + vec2(100.0, 200.0)) * 0.3;
    float cloudValue = n1 * 0.7 + n2;
    
    float threshold = 1.0 - uCloudCoverage;
    float cloudMask = smoothstep(threshold - 0.1, threshold + 0.1, cloudValue);
    
    return cloudMask * uCloudShadowStrength;
}

float calculateShadow(vec3 fragPosWorld, float nDotL, int layer) {
    vec4 fragPosLightSpace = uLightSpaceMatrices[layer] * vec4(fragPosWorld, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;

    // XY [-1,1]->[0,1]. Z is mapped if OpenGL (Vulkan already [0,1])
    projCoords.xy = projCoords.xy * 0.5 + 0.5;
    
    // In OpenGL (without glClipControl), Z is in [-1, 1].
    // If the matrix was built for [-1, 1], we map it to [0, 1] to match texture.
    projCoords.z = projCoords.z * 0.5 + 0.5;
    
    if (projCoords.z > 1.0 || projCoords.z < 0.0) return 0.0;
    
    float currentDepth = projCoords.z;
    
    // Revert to stable normalized bias, but scaled by layer
    float bias = max(0.002 * (1.0 - nDotL), 0.0005);
    if (layer == 1) bias *= 2.0;
    if (layer == 2) bias *= 4.0;

    float shadow = 0.0;
    // Use dynamic texel size for PCF
    vec2 texelSize = 1.0 / vec2(textureSize(uShadowMap0, 0));
    
    for(int x = -1; x <= 1; ++x) {
        for(int y = -1; y <= 1; ++y) {
            float pcfDepth;
            if (layer == 0) pcfDepth = texture(uShadowMap0, projCoords.xy + vec2(x, y) * texelSize).r;
            else if (layer == 1) pcfDepth = texture(uShadowMap1, projCoords.xy + vec2(x, y) * texelSize).r;
            else pcfDepth = texture(uShadowMap2, projCoords.xy + vec2(x, y) * texelSize).r;
            
            shadow += currentDepth > pcfDepth + bias ? 1.0 : 0.0;
        }
    }
    shadow /= 9.0;
    return shadow;
}

void main() {
    float nDotL = max(dot(vNormal, uSunDir), 0.0);
    
    // Select cascade layer using VIEW-SPACE depth (vViewDepth is clipPos.w = linear depth)
    int layer = 2;
    float depth = vViewDepth;
    if (depth < uCascadeSplits[0]) layer = 0;
    else if (depth < uCascadeSplits[1]) layer = 1;
    
    // Fade out shadows at high altitude to avoid CSM artifacts
    // When vViewDepth is very large (camera high up looking down), shadows become unreliable
    float shadowFadeStart = 400.0;
    float shadowFadeEnd = 600.0;
    float shadowFade = 1.0 - clamp((depth - shadowFadeStart) / (shadowFadeEnd - shadowFadeStart), 0.0, 1.0);
    
    float shadow = calculateShadow(vFragPosWorld, nDotL, layer) * shadowFade;

    // Cascade Blending
    float blendThreshold = 0.9; // Start blending at 90% of cascade range
    if (layer < 2) {
        float splitDist = uCascadeSplits[layer];
        float prevSplit = (layer == 0) ? 0.0 : uCascadeSplits[layer-1];
        float range = splitDist - prevSplit;
        float distInto = depth - prevSplit;
        float normDist = distInto / range;

        if (normDist > blendThreshold) {
            float blend = (normDist - blendThreshold) / (1.0 - blendThreshold);
            float nextShadow = calculateShadow(vFragPosWorld, nDotL, layer + 1);
            shadow = mix(shadow, nextShadow, blend);
        }
    }
    
    // Cloud shadow (only when sun is up)
    float cloudShadow = 0.0;
    if (uSunIntensity > 0.05 && uSunDir.y > 0.05) {
        cloudShadow = getCloudShadow(vFragPosWorld, uSunDir);
    }
    
    // Combine terrain shadow and cloud shadow
    float totalShadow = min(shadow + cloudShadow, 1.0);
    
    float directLight = nDotL * uSunIntensity * (1.0 - totalShadow);
    float skyLight = vSkyLight * (uAmbient + directLight * 0.8);
    
    float blockLight = vBlockLight;
    float lightLevel = max(skyLight, blockLight);
    
    lightLevel = max(lightLevel, uAmbient * 0.5);
    lightLevel = clamp(lightLevel, 0.0, 1.0);
    
    vec3 color;
    if (uUseTexture && vTileID >= 0) {
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
    
    if (uFogEnabled) {
        float fogFactor = 1.0 - exp(-vDistance * uFogDensity);
        fogFactor = clamp(fogFactor, 0.0, 1.0);
        color = mix(color, uFogColor, fogFactor);
    }
    
    FragColor = vec4(color, 1.0);
}
