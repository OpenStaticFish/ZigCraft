#ifndef LOD_WATER_APPEARANCE_GLSL
#define LOD_WATER_APPEARANCE_GLSL

vec4 lodWaterAppearance(vec3 resolvedColor, vec3 surfaceNormal, vec3 cameraRelativePos, float skyLight, vec3 blockLight) {
    // Both LOD formats supply CPU atlas-resolved color, not another atlas multiplier.
    // Neither supplies water thickness: never infer it from the detail-only G-pass.
    vec3 N = normalize(surfaceNormal);
    if (N.y < 0.0) N = -N;
    vec3 V = normalize(-cameraRelativePos);
    vec3 L = normalize(global.sun_dir.xyz);
    float sky = clamp(skyLight, 0.0, 1.0);
    float direct = max(dot(N, L), 0.0) * global.params.w * 0.7;
    float lightLevel = clamp(max(sky * (global.lighting.x + direct * 0.5),
                                max(blockLight.r, max(blockLight.g, blockLight.b))), 0.0, 1.05);
    // Static surface normals avoid camera-relative waves and unstable distant highlights.
    float fresnel = clamp((0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0)) * 0.55, 0.01, 0.28);
    vec3 color = mix(resolvedColor, global.fog_color.rgb, fresnel * 0.16 * sky) * lightLevel;
    vec3 halfVector = V + L;
    vec3 H = halfVector / max(length(halfVector), 0.0001);
    float specular = pow(max(dot(N, H), 0.0), 96.0);
    color += global.sun_color.rgb * global.params.w * specular * 0.22 * sky;
    if (global.params.z > 0.5) {
        float fog = atmosphericFogFactor(length(cameraRelativePos), global.params.y, sky);
        color = mix(color, global.fog_color.rgb, fog);
    }
    // Deliberate depth-free far-water opacity; the caller owns the existing overlap mask.
    return vec4(color, 0.93);
}

#endif
