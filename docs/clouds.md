````md
# clouds.md — Cloud System Specification (Voxel Engine)

This document defines a **v1 cloud system** that:
- Looks good from ground and high altitude
- Moves naturally with time and wind
- Integrates with sun/moon lighting
- Works with large render distances
- Avoids heavy volumetric cost (but leaves a path to v2)

The design is **tiered**:
- v1: 2D/2.5D clouds (cheap, stable, Minecraft-like)
- v2: optional volumetric upgrade later

---

## 1) Goals

- Visually readable clouds at all altitudes
- Clouds move consistently with wind
- Clouds react to time-of-day (lighting + color)
- Minimal shimmer or popping
- No coupling to terrain/worldgen logic

Non-goals (v1):
- True volumetric scattering
- Cloud self-shadowing on other clouds
- Weather simulation (rain, storms)

---

## 2) Cloud Types (v1)

### 2.1 Primary: Layered 2D Clouds (Recommended)
- Single horizontal cloud layer at fixed altitude
- Rendered as a large projected plane or sky-domain sampling
- Noise-based coverage and shape

This is:
- Cheap
- Stable
- Easy to tune
- Matches voxel aesthetic well

### 2.2 Optional Secondary: Low Fog/Cloud Mist
- Very low-opacity fog band near cloud height
- Enhances depth and scale
- Optional, can be skipped in v1

---

## 3) Cloud Coordinate Space (Critical)

Clouds must be:
- **Camera-relative**
- Independent of world origin
- Sampled in **world XZ**, but rendered relative to camera

Rule:
```text
cloudSamplePos = (worldXZ + windOffset)
renderPos = cameraRelative
````

This prevents:

* Precision shimmer
* “Sliding” when far from origin

---

## 4) Cloud Layer Parameters

### 4.1 Base Settings

* `cloudHeight` (world Y): e.g. 140–180
* `cloudThickness`: e.g. 8–20 units
* `cloudCoverage`: 0..1 (global density)
* `cloudScale`: noise scale (controls cloud size)

Suggested defaults:

* height: 160
* thickness: 12
* scale: 1 / 800 .. 1 / 1200

### 4.2 Wind

* Wind direction: normalized vec2 (XZ)
* Wind speed: units per second (e.g. 0.5..3.0)

Maintain:

* `windOffset += windDir * windSpeed * deltaTime`

---

## 5) Noise Model (Key to “not samey”)

### 5.1 Base Shape Noise

Use 2D noise (OpenSimplex / Perlin):

```text
N1 = fbm2(seed + C1, (x+wind)*s1, (z+wind)*s1, oct=4)
```

Low frequency, large shapes.

### 5.2 Detail Noise

Add higher-frequency breakup:

```text
N2 = fbm2(seed + C2, (x+wind)*s2, (z+wind)*s2, oct=3)
```

### 5.3 Final Coverage

```text
cloudValue = N1 * 0.7 + N2 * 0.3
cloudMask = smoothstep(thresholdLow, thresholdHigh, cloudValue)
```

Adjust thresholds using `cloudCoverage`.

---

## 6) Rendering Approaches

### 6.1 Option A — Projected Cloud Plane (Recommended v1)

Render a large quad at `cloudHeight` centered on camera.

Vertex shader:

* Quad in local space
* Offset to camera XZ
* Fixed Y = cloudHeight

Fragment shader:

* Sample noise using world XZ
* Alpha = cloudMask
* Apply lighting

Pros:

* Very simple
* Stable
* Works with shadows/fog easily

Cons:

* Clouds always flat (acceptable for v1)

---

### 6.2 Option B — Sky-Space Raymarch (Optional)

Sample clouds in sky shader using view ray intersection with cloud slab.

More complex, but:

* No geometry
* Natural horizon blending

Not required for v1.

---

## 7) Lighting & Time-of-Day Integration

### 7.1 Sun Lighting

Cloud brightness depends on sun angle:

* `lightFactor = clamp(dot(sunDir, up), 0..1)`
* Brightest at noon
* Dimmer at sunrise/sunset

Apply:

```text
cloudColor = baseCloudColor * mix(nightTint, dayTint, sunIntensity)
```

### 7.2 Sunset / Sunrise Tint

Near horizon:

* Add warm tint when sun is low
* Blend based on sun elevation

This gives:

* Orange/pink clouds at dusk/dawn
* White clouds at noon

### 7.3 Moon Lighting (Optional v1)

At night:

* Very subtle moonlight contribution
* Cool blue tint
* Low intensity

---

## 8) Shadows (v1 Simple, v2 Optional)

### 8.1 v1: Fake Cloud Shadows (Cheap & Effective)

Project cloud noise onto terrain:

* Sample same cloud noise in terrain fragment shader
* Offset by sun direction
* Darken terrain slightly where cloudMask > threshold

This gives:

* Moving cloud shadows
* Zero shadow-map cost

Control strength:

* `cloudShadowStrength = 0.05 .. 0.15`

### 8.2 v2: Real Shadow Maps (Not required)

* Clouds rendered into shadow map
* Expensive, complex
* Skip for now

---

## 9) Fog & Depth Integration

Clouds should blend with fog:

* Clouds fade into horizon fog
* At high altitude, clouds below camera fade smoothly

Rules:

* If camera Y > cloudHeight:

  * fade cloud opacity as camera rises above layer
* If camera Y < cloudHeight:

  * clouds appear overhead only

---

## 10) Performance Considerations

* One draw call for clouds
* No per-chunk work
* No lighting recompute
* Noise computed per fragment (cheap)

Avoid:

* Per-voxel clouds
* 3D raymarching in v1
* Cloud geometry tied to chunks

---

## 11) Debug & Tuning Tools

Required:

* Toggle clouds on/off
* Sliders:

  * coverage
  * scale
  * speed
  * height
* Visualize cloudMask (grayscale)
* Freeze wind (for stability testing)

---

## 12) Failure Modes & Fixes

### Clouds shimmer at distance

* Ensure camera-relative rendering
* Avoid world-space vertex positions
* Clamp noise precision

### Clouds slide incorrectly with camera

* Ensure sampling uses world XZ + wind, not view-space

### Clouds look tiled/repeating

* Increase noise scale
* Add domain warp (small)
* Blend two noise layers with different scales

---

## 13) Implementation Order

1. Time-of-day + sun direction hookup
2. Single cloud quad rendered above world
3. Noise-based alpha mask
4. Wind movement
5. Day/night color blending
6. Fake cloud shadows on terrain
7. Fog/horizon blending
8. Debug UI

---

## 14) Acceptance Criteria

* Clouds move smoothly across the sky
* Clouds respond to time-of-day
* No jitter when flying far or rotating camera
* Terrain subtly darkens under clouds
* Performance impact negligible

---

## 15) Future Extensions (v2+)

* Volumetric clouds (raymarching)
* Weather systems (rain, storms)
* Thunderhead clouds
* Cloud self-shadowing
* Lightning flashes

---

End of spec.

```
```

