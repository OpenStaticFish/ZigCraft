#version 330 core
layout (location = 0) in vec2 aPos;
out vec3 vWorldPos;
out float vDistance;
uniform vec3 uCameraPos;
uniform float uCloudHeight;
uniform mat4 uViewProj;
void main() {
    vec3 relPos = vec3(
        aPos.x,
        uCloudHeight - uCameraPos.y,
        aPos.y
    );
    vWorldPos = vec3(aPos.x + uCameraPos.x, uCloudHeight, aPos.y + uCameraPos.z);
    vDistance = length(relPos);
    gl_Position = uViewProj * vec4(relPos, 1.0);
}
