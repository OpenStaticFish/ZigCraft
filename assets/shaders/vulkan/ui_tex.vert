#version 450

layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aTexCoord;

layout(location = 0) out vec2 vTexCoord;

layout(push_constant) uniform PushConstants {
    mat4 projection;
} pc;

void main() {
    gl_Position = pc.projection * vec4(aPos, 0.0, 1.0);
    gl_Position.y = -gl_Position.y;
    vTexCoord = aTexCoord;
}
