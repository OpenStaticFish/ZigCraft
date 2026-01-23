#version 450
// Bloom Downsample Shader
// First pass: threshold extraction + Karis average to prevent fireflies
// Subsequent passes: 13-tap filter for smooth downsampling

layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D uSourceTexture;

layout(push_constant) uniform BloomParams {
    vec2 texelSize;      // 1.0 / source texture dimensions
    float threshold;     // Brightness threshold for extraction
    float softThreshold; // Soft knee for threshold (0-1)
    int mipLevel;        // 0 = first pass with threshold, >0 = subsequent passes
} params;

// Compute luminance for brightness detection
float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Karis average to prevent fireflies in bright areas
// Weights samples by inverse luminance to reduce contribution of very bright pixels
vec3 karisAverage(vec3 c0, vec3 c1, vec3 c2, vec3 c3) {
    float w0 = 1.0 / (1.0 + luminance(c0));
    float w1 = 1.0 / (1.0 + luminance(c1));
    float w2 = 1.0 / (1.0 + luminance(c2));
    float w3 = 1.0 / (1.0 + luminance(c3));
    return (c0 * w0 + c1 * w1 + c2 * w2 + c3 * w3) / (w0 + w1 + w2 + w3);
}

// Soft threshold function with knee
vec3 applyThreshold(vec3 color) {
    float brightness = luminance(color);
    float knee = params.threshold * params.softThreshold;
    float soft = brightness - params.threshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.00001);
    float contribution = max(soft, brightness - params.threshold) / max(brightness, 0.00001);
    return color * max(contribution, 0.0);
}

// 13-tap downsample filter (CoD Advanced Warfare / Unreal Engine 4 style)
// Provides good quality with box + tent filter combination
vec3 downsample13Tap(vec2 uv) {
    vec2 texel = params.texelSize;
    
    // A B C
    //  D E
    // F G H
    //  I J
    // K L M
    
    vec3 a = texture(uSourceTexture, uv + vec2(-2.0, -2.0) * texel).rgb;
    vec3 b = texture(uSourceTexture, uv + vec2( 0.0, -2.0) * texel).rgb;
    vec3 c = texture(uSourceTexture, uv + vec2( 2.0, -2.0) * texel).rgb;
    
    vec3 d = texture(uSourceTexture, uv + vec2(-1.0, -1.0) * texel).rgb;
    vec3 e = texture(uSourceTexture, uv + vec2( 1.0, -1.0) * texel).rgb;
    
    vec3 f = texture(uSourceTexture, uv + vec2(-2.0,  0.0) * texel).rgb;
    vec3 g = texture(uSourceTexture, uv).rgb;
    vec3 h = texture(uSourceTexture, uv + vec2( 2.0,  0.0) * texel).rgb;
    
    vec3 i = texture(uSourceTexture, uv + vec2(-1.0,  1.0) * texel).rgb;
    vec3 j = texture(uSourceTexture, uv + vec2( 1.0,  1.0) * texel).rgb;
    
    vec3 k = texture(uSourceTexture, uv + vec2(-2.0,  2.0) * texel).rgb;
    vec3 l = texture(uSourceTexture, uv + vec2( 0.0,  2.0) * texel).rgb;
    vec3 m = texture(uSourceTexture, uv + vec2( 2.0,  2.0) * texel).rgb;
    
    // Apply weighted filter
    // Center diamond (weight 0.5)
    vec3 downsample = (d + e + i + j) * 0.25 * 0.5;
    
    // Corner boxes (weight 0.125 each = 0.5 total)
    downsample += (a + b + d + g) * 0.25 * 0.125;
    downsample += (b + c + e + g) * 0.25 * 0.125;
    downsample += (d + g + i + f) * 0.25 * 0.125;
    downsample += (g + e + j + h) * 0.25 * 0.125;
    
    // Edge centers (weight 0.125 total from remaining pattern)
    // This creates a nice gaussian-like falloff
    downsample += (g + k + l + i) * 0.25 * 0.0625;
    downsample += (g + l + m + j) * 0.25 * 0.0625;
    
    return downsample;
}

void main() {
    vec3 color;
    
    if (params.mipLevel == 0) {
        // First downsample: apply threshold and use Karis average
        vec2 texel = params.texelSize;
        
        // Sample 4 pixels in a box pattern
        vec3 c0 = texture(uSourceTexture, inUV + vec2(-1.0, -1.0) * texel).rgb;
        vec3 c1 = texture(uSourceTexture, inUV + vec2( 1.0, -1.0) * texel).rgb;
        vec3 c2 = texture(uSourceTexture, inUV + vec2(-1.0,  1.0) * texel).rgb;
        vec3 c3 = texture(uSourceTexture, inUV + vec2( 1.0,  1.0) * texel).rgb;
        
        // Apply threshold to each sample
        c0 = applyThreshold(c0);
        c1 = applyThreshold(c1);
        c2 = applyThreshold(c2);
        c3 = applyThreshold(c3);
        
        // Use Karis average to prevent fireflies
        color = karisAverage(c0, c1, c2, c3);
    } else {
        // Subsequent passes: use 13-tap filter
        color = downsample13Tap(inUV);
    }
    
    outColor = vec4(color, 1.0);
}
