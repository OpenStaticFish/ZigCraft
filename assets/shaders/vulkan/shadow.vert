#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;

layout(push_constant) uniform ShadowModelUniforms {
    mat4 mvp;
    vec4 bias_params; // x=normalBias, y=slopeBias, z=cascadeIndex, w=texelSize
} pc;

void main() {
    vec3 worldNormal = aNormal; 
    float normalBias = pc.bias_params.x * pc.bias_params.w;
    vec3 biasedPos = aPos + worldNormal * normalBias;
    
    gl_Position = pc.mvp * vec4(biasedPos, 1.0);
}
