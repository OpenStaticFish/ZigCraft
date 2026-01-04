#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
layout(location = 2) in vec3 aNormal;
layout(location = 3) in vec2 aTexCoord;
layout(location = 4) in float aTileID;
layout(location = 5) in float aSkyLight;
layout(location = 6) in float aBlockLight;

layout(location = 0) out vec3 vColor;
layout(location = 1) flat out vec3 vNormal;
layout(location = 2) out vec2 vTexCoord;
layout(location = 3) flat out int vTileID;
layout(location = 4) out float vDistance;
layout(location = 5) out float vSkyLight;
layout(location = 6) out float vBlockLight;
layout(location = 7) out vec3 vFragPosWorld;
layout(location = 8) out float vViewDepth;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 fog_color;
    float time;
    float fog_density;
    float fog_enabled;
    float sun_intensity;
    float ambient;
    float use_texture;
    vec2 cloud_wind_offset;
    float cloud_scale;
    float cloud_coverage;
    float cloud_shadow_strength;
    float cloud_height;
    float padding[2];
} global;

layout(push_constant) uniform ModelUniforms {
    mat4 view_proj;
    mat4 model;
    float mask_radius;
    vec3 padding;
} pc;

void main() {
    vec4 worldPos = pc.model * vec4(aPos, 1.0);
    // Use the view_proj from push constants to avoid UBO race conditions
    vec4 clipPos = pc.view_proj * worldPos;
    
    // Vulkan has inverted Y in clip space compared to OpenGL
    gl_Position = clipPos;
    gl_Position.y = -gl_Position.y; 

    vColor = aColor;
    vNormal = aNormal;
    vTexCoord = aTexCoord;
    vTileID = int(aTileID);
    vDistance = length(worldPos.xyz);
    vSkyLight = aSkyLight;
    vBlockLight = aBlockLight;
    
    vFragPosWorld = worldPos.xyz;
    vViewDepth = clipPos.w;
}
