#version 450

layout(location = 0) in vec3 vWorldDir;
layout(location = 0) out vec4 FragColor;

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

float cloudHash(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

float cloudNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = cloudHash(i);
    float b = cloudHash(i + vec2(1.0, 0.0));
    float c = cloudHash(i + vec2(0.0, 1.0));
    float d = cloudHash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float cloudFbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * cloudNoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

float hash21(vec2 p) {
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
    float n = hash21(p);
    return vec2(n, hash21(p + n));
}

float stars(vec3 dir) {
    float theta = atan(dir.z, dir.x);
    float phi = asin(clamp(dir.y, -1.0, 1.0));

    vec2 gridCoord = vec2(theta * 15.0, phi * 30.0);
    vec2 cell = floor(gridCoord);
    vec2 cellFrac = fract(gridCoord);

    float brightness = 0.0;

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec2 neighbor = cell + vec2(float(dx), float(dy));

            float starChance = hash21(neighbor);
            if (starChance > 0.92) {
                vec2 starPos = hash22(neighbor * 1.7);
                vec2 offset = vec2(float(dx), float(dy)) + starPos - cellFrac;
                float dist = length(offset);

                float starBright = smoothstep(0.08, 0.0, dist);
                starBright *= 0.5 + 0.5 * hash21(neighbor * 3.14);
                float twinkle = 0.7 + 0.3 * sin(hash21(neighbor) * 50.0 + pc.time.x * 8.0);
                starBright *= twinkle;

                brightness = max(brightness, starBright);
            }
        }
    }

    return brightness;
}

void main() {
    vec3 dir = normalize(vWorldDir);

    float horizon = 1.0 - abs(dir.y);
    horizon = pow(horizon, 1.5);
    vec3 sky = mix(pc.sky_color.xyz, pc.horizon_color.xyz, horizon);

    float sunDot = dot(dir, normalize(pc.sun_dir.xyz));
    float sunDisc = smoothstep(0.9995, 0.9999, sunDot);
    vec3 sunColor = vec3(1.0, 0.95, 0.8);

    float sunGlow = pow(max(sunDot, 0.0), 8.0) * 0.5;
    sunGlow += pow(max(sunDot, 0.0), 64.0) * 0.3;

    float moonDot = dot(dir, -normalize(pc.sun_dir.xyz));
    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    vec3 moonColor = vec3(0.9, 0.9, 1.0);

    float starIntensity = 0.0;
    if (pc.params.z < 0.3 && dir.y > 0.0) {
        float nightFactor = 1.0 - pc.params.z * 3.33;
        starIntensity = stars(dir) * nightFactor * 1.5;
    }

    vec3 finalColor = sky;
    
    // Clouds
    if (dir.y > 0.0) {
        float cloudHeight = 160.0;
        float cloudCoverage = 0.5;
        float cloudScale = 1.0 / 64.0;
        float cloudBlockSize = 12.0;
        
        vec3 camPos = pc.time.yzw;
        
        // Ray-plane intersection
        float t = (cloudHeight - camPos.y) / dir.y;
        if (t > 0.0 && t < 3000.0) {
            vec3 worldPos = camPos + dir * t;
            vec2 worldXZ = worldPos.xz + vec2(pc.time.x * 2.0, pc.time.x * 0.4);
            vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
            vec2 samplePos = pixelPos * cloudScale;
            
            // Reusing hash from stars for simplicity or adding cloud noise
            float n1 = cloudFbm(samplePos * 0.5);
            float n2 = cloudFbm(samplePos * 2.0 + vec2(100.0, 200.0)) * 0.3;
            float cloudValue = n1 * 0.7 + n2;
            
            float threshold = 1.0 - cloudCoverage;
            if (cloudValue > threshold) {
                float distFade = 1.0 - smoothstep(800.0, 2500.0, t);
                float shadow = 0.8 + 0.2 * smoothstep(threshold, threshold + 0.2, cloudValue);
                
                vec3 nightTint = vec3(0.1, 0.12, 0.2);
                vec3 dayColor = vec3(1.0);
                vec3 cloudColor = mix(nightTint, dayColor, pc.params.z);
                cloudColor *= (0.7 + 0.3 * pc.params.z) * shadow;
                
                finalColor = mix(finalColor, cloudColor, distFade * 0.9);
            }
        }
    }

    finalColor += sunGlow * pc.params.z * vec3(1.0, 0.8, 0.4);
    finalColor += sunDisc * sunColor * pc.params.z;
    finalColor += moonDisc * moonColor * pc.params.w * 3.0;
    finalColor += vec3(starIntensity);

    FragColor = vec4(finalColor, 1.0);
}
