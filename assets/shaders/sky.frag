#version 330 core
in vec3 vWorldDir;
out vec4 FragColor;

uniform vec3 uSunDir;
uniform vec3 uSkyColor;
uniform vec3 uHorizonColor;
uniform float uSunIntensity;
uniform float uMoonIntensity;
uniform float uTime;

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

                float twinkle = 0.7 + 0.3 * sin(hash21(neighbor) * 50.0 + uTime * 8.0);
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
    vec3 sky = mix(uSkyColor, uHorizonColor, horizon);

    float sunDot = dot(dir, uSunDir);
    float sunDisc = smoothstep(0.9995, 0.9999, sunDot);
    vec3 sunColor = vec3(1.0, 0.95, 0.8);

    float sunGlow = pow(max(sunDot, 0.0), 8.0) * 0.5;
    sunGlow += pow(max(sunDot, 0.0), 64.0) * 0.3;

    float moonDot = dot(dir, -uSunDir);
    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    vec3 moonColor = vec3(0.9, 0.9, 1.0);

    float starIntensity = 0.0;
    if (uSunIntensity < 0.3 && dir.y > 0.0) {
        float nightFactor = 1.0 - uSunIntensity * 3.33;
        starIntensity = stars(dir) * nightFactor * 1.5;
    }

    vec3 finalColor = sky;
    finalColor += sunGlow * uSunIntensity * vec3(1.0, 0.8, 0.4);
    finalColor += sunDisc * sunColor * uSunIntensity;
    finalColor += moonDisc * moonColor * uMoonIntensity * 3.0;
    finalColor += vec3(starIntensity);

    FragColor = vec4(finalColor, 1.0);
}
