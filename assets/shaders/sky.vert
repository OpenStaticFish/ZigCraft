#version 330 core
layout (location = 0) in vec2 aPos;
out vec3 vWorldDir;
uniform vec3 uCamForward;
uniform vec3 uCamRight;
uniform vec3 uCamUp;
uniform float uAspect;
uniform float uTanHalfFov;
void main() {
    gl_Position = vec4(aPos, 0.9999, 1.0);
    vec3 rayDir = uCamForward
                + uCamRight * aPos.x * uAspect * uTanHalfFov
                + uCamUp * aPos.y * uTanHalfFov;
    vWorldDir = rayDir;
}
