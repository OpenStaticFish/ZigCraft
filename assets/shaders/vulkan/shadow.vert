#version 450

layout(location = 0) in vec3 aPos;

layout(push_constant) uniform ModelUniforms {
    mat4 view_proj;
    mat4 model;
} pc;

void main() {
    vec4 worldPos = pc.model * vec4(aPos, 1.0);
    vec4 clipPos = pc.view_proj * worldPos;
    
    // Shadow maps: NO Y-flip here - keeps texel snapping consistent
    // The shadow map will be "upside down" but sampling is also not flipped,
    // so they cancel out and the CPU texel snapping works correctly.
    gl_Position = clipPos;
}
