#version 450
// Frozen pre-optimization FXAA reference. Keep independent of the runtime shader.
layout(location = 0) in vec2 inUV;
layout(location = 0) out vec4 outColor;
layout(set = 0, binding = 0) uniform sampler2D uColorBuffer;
layout(push_constant) uniform FXAAParams {
    vec2 texelSize;
    float fxaaSpanMax;
    float fxaaReduceMul;
} params;
#define FXAA_REDUCE_MIN (1.0 / 128.0)
float luminance(vec3 color) {
    return dot(color, vec3(0.299, 0.587, 0.114));
}
void main() {
    vec2 texelSize = params.texelSize;
    vec3 rgbNW = texture(uColorBuffer, inUV + vec2(-1.0, -1.0) * texelSize).rgb;
    vec3 rgbNE = texture(uColorBuffer, inUV + vec2( 1.0, -1.0) * texelSize).rgb;
    vec3 rgbSW = texture(uColorBuffer, inUV + vec2(-1.0,  1.0) * texelSize).rgb;
    vec3 rgbSE = texture(uColorBuffer, inUV + vec2( 1.0,  1.0) * texelSize).rgb;
    vec3 rgbM  = texture(uColorBuffer, inUV).rgb;
    float lumaNW = luminance(rgbNW);
    float lumaNE = luminance(rgbNE);
    float lumaSW = luminance(rgbSW);
    float lumaSE = luminance(rgbSE);
    float lumaM  = luminance(rgbM);
    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
    vec2 dir;
    dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
    float dirReduce = max(
        (lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * params.fxaaReduceMul),
        FXAA_REDUCE_MIN
    );
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = min(vec2(params.fxaaSpanMax), max(vec2(-params.fxaaSpanMax), dir * rcpDirMin)) * texelSize;
    vec3 rgbA = 0.5 * (
        texture(uColorBuffer, inUV + dir * (1.0 / 3.0 - 0.5)).rgb +
        texture(uColorBuffer, inUV + dir * (2.0 / 3.0 - 0.5)).rgb
    );
    vec3 rgbB = rgbA * 0.5 + 0.25 * (
        texture(uColorBuffer, inUV + dir * -0.5).rgb +
        texture(uColorBuffer, inUV + dir *  0.5).rgb
    );
    float lumaB = luminance(rgbB);
    if (lumaB < lumaMin || lumaB > lumaMax) {
        outColor = vec4(rgbA, 1.0);
    } else {
        outColor = vec4(rgbB, 1.0);
    }
}
