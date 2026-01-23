#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aColor;
layout(location = 2) in vec3 aNormal;
layout(location = 3) in vec2 aTexCoord;
layout(location = 4) in float aTileID;
layout(location = 5) in float aSkyLight;
layout(location = 6) in vec3 aBlockLight;
layout(location = 7) in float aAO;

layout(location = 0) out vec3 vColor;
layout(location = 1) flat out vec3 vNormal;
layout(location = 2) out vec2 vTexCoord;
layout(location = 3) flat out int vTileID;
layout(location = 4) out float vDistance;
layout(location = 5) out float vSkyLight;
layout(location = 6) out vec3 vBlockLight;
layout(location = 7) out vec3 vFragPosWorld;
layout(location = 8) out float vViewDepth;
layout(location = 9) out vec3 vTangent;
layout(location = 10) out vec3 vBitangent;
layout(location = 11) out float vAO;
layout(location = 12) out vec4 vClipPosCurrent;
layout(location = 13) out vec4 vClipPosPrev;

layout(set = 0, binding = 0) uniform GlobalUniforms {
    mat4 view_proj;
    mat4 view_proj_prev; // Previous frame's view-projection for velocity buffer
    vec4 cam_pos;
    vec4 sun_dir;
    vec4 sun_color;
    vec4 fog_color;
    vec4 cloud_wind_offset; // xy = offset, z = scale, w = coverage
    vec4 params; // x = time, y = fog_density, z = fog_enabled, w = sun_intensity
    vec4 lighting; // x = ambient, y = use_texture, z = pbr_enabled, w = cloud_shadow_strength
    vec4 cloud_params; // x = cloud_height, y = shadow_samples, z = shadow_blend, w = cloud_shadows
    vec4 pbr_params; // x = pbr_quality, y = exposure, z = saturation, w = ssao_strength
    vec4 volumetric_params; // x = enabled, y = density, z = steps, w = scattering
    vec4 viewport_size; // xy = width/height
} global;

layout(push_constant) uniform ModelUniforms {
    mat4 model;
    vec3 color_override;
    float mask_radius;
} model_data;

void main() {
    vec4 worldPos = model_data.model * vec4(aPos, 1.0);
    vec4 clipPos = global.view_proj * worldPos;
    vec4 clipPosPrev = global.view_proj_prev * worldPos;
    
    // Vulkan has inverted Y in clip space compared to OpenGL
    gl_Position = clipPos;
    gl_Position.y = -gl_Position.y;
    
    // Store clip positions for velocity buffer calculation (with Y inverted)
    vClipPosCurrent = vec4(clipPos.x, -clipPos.y, clipPos.z, clipPos.w);
    vClipPosPrev = vec4(clipPosPrev.x, -clipPosPrev.y, clipPosPrev.z, clipPosPrev.w); 

    vColor = aColor * model_data.color_override;
    vNormal = aNormal;
    vTexCoord = aTexCoord;
    vTileID = int(aTileID);
    vDistance = length(worldPos.xyz);
    vSkyLight = aSkyLight;
    vBlockLight = aBlockLight;
    
    vFragPosWorld = worldPos.xyz;
    vViewDepth = clipPos.w;
    vAO = aAO;

    // Compute tangent and bitangent from the normal for TBN matrix
    // This works for axis-aligned block faces
    vec3 absNormal = abs(aNormal);
    if (absNormal.y > 0.9) {
        // Top/bottom face
        vTangent = vec3(1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 0.0, aNormal.y > 0.0 ? 1.0 : -1.0);
    } else if (absNormal.x > 0.9) {
        // East/west face
        vTangent = vec3(0.0, 0.0, aNormal.x > 0.0 ? -1.0 : 1.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    } else {
        // North/south face
        vTangent = vec3(aNormal.z > 0.0 ? 1.0 : -1.0, 0.0, 0.0);
        vBitangent = vec3(0.0, 1.0, 0.0);
    }
}
