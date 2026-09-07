#version 450

layout(location = 0) in vec3 vColor;
layout(location = 1) flat in vec3 vNormal;
layout(location = 2) in vec2 vTexCoord;
layout(location = 3) flat in int vTileID;
layout(location = 4) in float vDistance;
layout(location = 5) in float vSkyLight;
layout(location = 6) in vec3 vBlockLight;
layout(location = 7) in vec3 vFragPosWorld;
layout(location = 8) in float vViewDepth;
layout(location = 9) in vec3 vTangent;
layout(location = 10) in vec3 vBitangent;
layout(location = 11) in float vAO;
layout(location = 12) in vec4 vClipPosCurrent;
layout(location = 13) in vec4 vClipPosPrev;

layout(location = 0) out vec4 FragColor;

void main() {
    // Debug: output bright magenta for all terrain
    FragColor = vec4(1.0, 0.0, 1.0, 1.0);
}
