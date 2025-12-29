#version 330 core
in vec3 vWorldPos;
in float vDistance;
out vec4 FragColor;
uniform vec3 uCameraPos;
uniform float uCloudHeight;
uniform float uCloudCoverage;
uniform float uCloudScale;
uniform float uWindOffsetX;
uniform float uWindOffsetZ;
uniform vec3 uSunDir;
uniform float uSunIntensity;
uniform vec3 uBaseColor;
uniform vec3 uFogColor;
uniform float uFogDensity;
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
    vec2 worldXZ = vWorldPos.xz + vec2(uWindOffsetX, uWindOffsetZ);
    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    vec2 samplePos = pixelPos * uCloudScale;
    float cloudValue = fbm(samplePos, 3);
    float threshold = 1.0 - uCloudCoverage;
    if (cloudValue < threshold) discard;
    vec3 nightTint = vec3(0.1, 0.12, 0.2);
    vec3 dayColor = uBaseColor;
    vec3 cloudColor = mix(nightTint, dayColor, uSunIntensity);
    float lightFactor = clamp(uSunDir.y, 0.0, 1.0);
    cloudColor *= (0.7 + 0.3 * lightFactor);
    float fogFactor = 1.0 - exp(-vDistance * uFogDensity * 0.4);
    cloudColor = mix(cloudColor, uFogColor, fogFactor);
    float alpha = 1.0 * (1.0 - fogFactor * 0.8);
    float altitudeDiff = uCameraPos.y - uCloudHeight;
    if (altitudeDiff > 0.0) {
        alpha *= 1.0 - smoothstep(10.0, 400.0, altitudeDiff);
    }
    FragColor = vec4(cloudColor, alpha);
}
