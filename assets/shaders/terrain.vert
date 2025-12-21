#version 330 core
layout (location = 0) in vec3 aPos;
layout (location = 1) in vec3 aColor;
layout (location = 2) in vec3 aNormal;
layout (location = 3) in vec2 aTexCoord;
layout (location = 4) in float aTileID;
layout (location = 5) in float aSkyLight;
layout (location = 6) in float aBlockLight;
out vec3 vColor;
flat out vec3 vNormal;
out vec2 vTexCoord;
flat out int vTileID;
out float vDistance;
out float vSkyLight;
out float vBlockLight;
out vec3 vFragPosWorld;
out float vViewDepth;

uniform mat4 transform; // MVP
uniform mat4 uModel;

void main() {
    vec4 clipPos = transform * vec4(aPos, 1.0);
    gl_Position = clipPos;
    vColor = aColor;
    vNormal = aNormal;
    vTexCoord = aTexCoord;
    vTileID = int(aTileID);
    vDistance = length(aPos);
    vSkyLight = aSkyLight;
    vBlockLight = aBlockLight;
    
    vFragPosWorld = (uModel * vec4(aPos, 1.0)).xyz;
    vViewDepth = clipPos.w;
}
