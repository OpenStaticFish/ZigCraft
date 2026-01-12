#version 450

layout(location = 0) in vec3 aPos;

struct InstanceData {
    mat4 view_proj;
    mat4 model;
    float mask_radius;
    float _pad0;
    float _pad1;
    float _pad2;
};

layout(std430, set = 0, binding = 5) readonly buffer Instances {
    InstanceData data[];
} instances;

void main() {
    InstanceData inst = instances.data[gl_InstanceIndex];
    vec4 worldPos = inst.model * vec4(aPos, 1.0);
    vec4 clipPos = inst.view_proj * worldPos;
    
    // Shadow maps: NO Y-flip here - keeps texel snapping consistent
    // The shadow map will be "upside down" but sampling is also not flipped,
    // so they cancel out and the CPU texel snapping works correctly.
    gl_Position = clipPos;
}
