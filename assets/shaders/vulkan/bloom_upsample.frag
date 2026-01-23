#version 450
// Bloom Upsample Shader
// 9-tap tent filter for smooth upsampling
// Progressively accumulates bloom from lowest mip to highest

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uBloomMip;      // Current mip being upsampled
layout(set = 0, binding = 1) uniform sampler2D uPreviousMip;   // Higher-resolution mip to blend with

layout(push_constant) uniform BloomParams {
    vec2 texelSize;       // 1.0 / source texture dimensions
    float filterRadius;   // Tent filter radius (default: 1.0)
    float bloomIntensity; // Intensity multiplier for this level
} params;

// 9-tap tent filter for smooth upsampling
// Creates a nice 3x3 weighted blur centered on the sample
vec3 upsampleTent(sampler2D tex, vec2 uv) {
    vec2 texel = params.texelSize * params.filterRadius;
    
    // 3x3 grid with tent filter weights
    // 1 2 1
    // 2 4 2  -> normalized by /16
    // 1 2 1
    
    vec3 result = vec3(0.0);
    
    // Corners (weight 1)
    result += texture(tex, uv + vec2(-1.0, -1.0) * texel).rgb * 1.0;
    result += texture(tex, uv + vec2( 1.0, -1.0) * texel).rgb * 1.0;
    result += texture(tex, uv + vec2(-1.0,  1.0) * texel).rgb * 1.0;
    result += texture(tex, uv + vec2( 1.0,  1.0) * texel).rgb * 1.0;
    
    // Edges (weight 2)
    result += texture(tex, uv + vec2( 0.0, -1.0) * texel).rgb * 2.0;
    result += texture(tex, uv + vec2(-1.0,  0.0) * texel).rgb * 2.0;
    result += texture(tex, uv + vec2( 1.0,  0.0) * texel).rgb * 2.0;
    result += texture(tex, uv + vec2( 0.0,  1.0) * texel).rgb * 2.0;
    
    // Center (weight 4)
    result += texture(tex, uv).rgb * 4.0;
    
    return result / 16.0;
}

void main() {
    // Upsample the bloom mip with tent filter
    vec3 bloom = upsampleTent(uBloomMip, inUV);
    
    // Sample the higher resolution mip
    vec3 previous = texture(uPreviousMip, inUV).rgb;
    
    // Blend upsampled bloom with previous mip
    // The intensity controls how much bloom is added at each level
    vec3 result = previous + bloom * params.bloomIntensity;
    
    outColor = vec4(result, 1.0);
}
