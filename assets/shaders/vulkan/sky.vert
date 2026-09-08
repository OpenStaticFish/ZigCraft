#version 450

layout(location = 0) out vec3 vWorldDir;

layout(push_constant) uniform SkyPC {
    vec4 cam_forward;
    vec4 cam_right;
    vec4 cam_up;
    vec4 sun_dir;
    vec4 sky_color;
    vec4 horizon_color;
    vec4 params; // aspect, tanHalfFov, sunIntensity, moonIntensity
    vec4 time;
} pc;

void main() {
    vec2 pos;
    if (gl_VertexIndex == 0) {
        pos = vec2(-1.0, -1.0);
    } else if (gl_VertexIndex == 1) {
        pos = vec2(3.0, -1.0);
    } else {
        pos = vec2(-1.0, 3.0);
    }

    // Use unflipped NDC for ray direction
    vec2 ndc = pos;

    // Flip Y for Vulkan clip space
    vec2 render_pos = pos;
    render_pos.y = -render_pos.y;

    // Reverse-Z far plane: only shade samples not covered by opaque geometry.
    gl_Position = vec4(render_pos, 0.0, 1.0);

    vec3 rayDir = pc.cam_forward.xyz
                + pc.cam_right.xyz * ndc.x * pc.params.x * pc.params.y
                + pc.cam_up.xyz * ndc.y * pc.params.y;
    vWorldDir = rayDir;
}
