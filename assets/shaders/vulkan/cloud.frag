#version 450

layout(location = 0) in vec3 vWorldPos;

layout(location = 0) out vec4 FragColor;

layout(push_constant) uniform CloudPC {
    mat4 view_proj;
    vec4 camera_pos;      // xyz = camera position, w = cloud_height
    vec4 cloud_params;    // x = coverage, y = scale, z = wind_offset_x, w = wind_offset_z
    vec4 sun_params;      // xyz = sun_dir, w = sun_intensity
    vec4 fog_params;      // xyz = fog_color, w = fog_density
} pc;

float hash(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

void main() {
    float cloudBlockSize = 12.0;
    float uCloudCoverage = pc.cloud_params.x;
    float uCloudScale = pc.cloud_params.y;
    float uWindOffsetX = pc.cloud_params.z;
    float uWindOffsetZ = pc.cloud_params.w;
    vec3 uSunDir = pc.sun_params.xyz;
    float uSunIntensity = pc.sun_params.w;
    vec3 uFogColor = pc.fog_params.xyz;
    float uFogDensity = pc.fog_params.w;
    vec3 uBaseColor = vec3(1.0, 1.0, 1.0); // Default to white
    float uCloudHeight = pc.camera_pos.w;
    vec3 uCameraPos = pc.camera_pos.xyz;

    vec2 worldXZ = vWorldPos.xz + vec2(uWindOffsetX, uWindOffsetZ);
    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    vec2 samplePos = pixelPos * uCloudScale;
    float cloudValue = fbm(samplePos, 3);
    float threshold = 1.0 - uCloudCoverage;
    if (cloudValue < threshold) discard;

    vec3 nightTint = pow(vec3(0.1, 0.12, 0.2), vec3(2.2));
    vec3 dayColor = vec3(0.85, 0.85, 0.9); // Slightly dimmer clouds
    vec3 cloudColor = mix(nightTint, dayColor, uSunIntensity);
    float lightFactor = clamp(uSunDir.y, 0.0, 1.0);
    // Reduce max brightness to prevent blowing out the sky
    cloudColor *= (0.5 + 0.3 * lightFactor);

    float vDistance = length(vWorldPos - uCameraPos);
    float fogFactor = 1.0 - exp(-vDistance * uFogDensity * 0.4);
    cloudColor = mix(cloudColor, uFogColor, fogFactor);

    float alpha = 1.0 * (1.0 - fogFactor * 0.8);
    float altitudeDiff = uCameraPos.y - uCloudHeight;
    if (altitudeDiff > 0.0) {
        alpha *= 1.0 - smoothstep(10.0, 400.0, altitudeDiff);
    }

    FragColor = vec4(cloudColor, alpha);
}
