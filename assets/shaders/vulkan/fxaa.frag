#version 450
// FXAA 3.11 Implementation - Quality Preset 39
// Based on NVIDIA FXAA 3.11 by Timothy Lottes

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uColorBuffer;

layout(push_constant) uniform FXAAParams {
    vec2 texelSize;      // 1.0 / viewport dimensions
    float fxaaSpanMax;   // Maximum edge search span (default: 8.0)
    float fxaaReduceMul; // Reduction multiplier (default: 1.0/8.0)
} params;

#define FXAA_REDUCE_MIN (1.0 / 128.0)

// Compute luminance from RGB using perceptual weights
float luminance(vec3 color) {
    return dot(color, vec3(0.299, 0.587, 0.114));
}

void main() {
    vec2 texelSize = params.texelSize;
    
    // Sample center and 4 neighbors
    vec3 rgbNW = texture(uColorBuffer, inUV + vec2(-1.0, -1.0) * texelSize).rgb;
    vec3 rgbNE = texture(uColorBuffer, inUV + vec2( 1.0, -1.0) * texelSize).rgb;
    vec3 rgbSW = texture(uColorBuffer, inUV + vec2(-1.0,  1.0) * texelSize).rgb;
    vec3 rgbSE = texture(uColorBuffer, inUV + vec2( 1.0,  1.0) * texelSize).rgb;
    vec3 rgbM  = texture(uColorBuffer, inUV).rgb;
    
    // Convert to luminance
    float lumaNW = luminance(rgbNW);
    float lumaNE = luminance(rgbNE);
    float lumaSW = luminance(rgbSW);
    float lumaSE = luminance(rgbSE);
    float lumaM  = luminance(rgbM);
    
    // Find min/max luminance
    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
    
    // Compute edge direction
    vec2 dir;
    dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
    
    // Compute direction reduce factor
    float dirReduce = max(
        (lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * params.fxaaReduceMul),
        FXAA_REDUCE_MIN
    );
    
    // Scale direction based on intensity
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = min(vec2(params.fxaaSpanMax), max(vec2(-params.fxaaSpanMax), dir * rcpDirMin)) * texelSize;
    
    // Sample along the edge direction
    vec3 rgbA = 0.5 * (
        texture(uColorBuffer, inUV + dir * (1.0 / 3.0 - 0.5)).rgb +
        texture(uColorBuffer, inUV + dir * (2.0 / 3.0 - 0.5)).rgb
    );
    
    vec3 rgbB = rgbA * 0.5 + 0.25 * (
        texture(uColorBuffer, inUV + dir * -0.5).rgb +
        texture(uColorBuffer, inUV + dir *  0.5).rgb
    );
    
    float lumaB = luminance(rgbB);
    
    // Choose between rgbA and rgbB based on edge detection quality
    if (lumaB < lumaMin || lumaB > lumaMax) {
        outColor = vec4(rgbA, 1.0);
    } else {
        outColor = vec4(rgbB, 1.0);
    }
}
