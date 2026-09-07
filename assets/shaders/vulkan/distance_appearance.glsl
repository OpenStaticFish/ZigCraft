#ifndef DISTANCE_APPEARANCE_GLSL
#define DISTANCE_APPEARANCE_GLSL

float atmosphericFogFactor(float distanceToCamera, float density, float skyLight) {
    // Open sky converges to the horizon color; enclosed surfaces retain visibility attenuation.
    float visibility = smoothstep(0.05, 0.25, clamp(skyLight, 0.0, 1.0));
    return (1.0 - exp(-max(distanceToCamera, 0.0) * max(density, 0.0))) * visibility;
}

#endif
