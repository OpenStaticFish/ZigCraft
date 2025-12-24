# shadows.md — Shadow System for Voxel Engine (OpenGL)

This spec defines a practical shadow system for a voxel engine with:
- Sun (directional light) shadows
- Optional moon shadows (v2)
- Chunked world, large render distances
- Performance constraints typical of voxel terrain

Primary approach: **Cascaded Shadow Maps (CSM)** for the sun.

---

## 1) Goals

- Stable sun shadows across large outdoor scenes.
- Reasonable performance with configurable quality.
- Minimal shimmering (“shadow swimming”) while camera moves.
- Works with chunk streaming and camera-relative rendering.

Non-goals (v1):
- Perfect contact-hardening / soft shadows
- Ray-traced GI
- Voxel cone tracing

---

## 2) Shadowing Approach

### 2.1 Directional Light => Cascaded Shadow Maps (CSM)
Directional light (sun) requires shadowing over large distances.
CSM splits the camera frustum into multiple ranges (cascades), each with its own shadow map.

Default:
- 3 cascades (good)
Optional:
- 4 cascades (better)

---

## 3) Settings

Expose these in graphics settings:

- `shadows_enabled` (bool)
- `shadow_map_resolution` (1024 / 2048 / 4096)
- `shadow_cascades` (2 / 3 / 4)
- `shadow_distance` (e.g. 80m / 150m / 250m in world units)
- `shadow_bias` (float)
- `shadow_normal_bias` (float)
- `pcf_kernel` (1 / 2 / 3) (filter radius)
- `cascade_split_lambda` (0..1) (split distribution)

---

## 4) Pipeline Overview

Per frame:
1. Compute `sunDir` from time-of-day.
2. Compute camera frustum splits for cascades.
3. For each cascade:
   - compute light-space ortho projection covering that frustum slice
   - render shadow caster geometry into shadow map (depth-only)
4. Render main scene:
   - sample correct cascade shadow map per fragment
   - apply PCF filtering
   - apply shadow factor to sun lighting term only

---

## 5) Cascade Splits

Let:
- camera near = `n`
- camera farShadow = `f` (shadow_distance, not camera far plane)
- cascades = `C`

Compute split distances using a blend of:
- linear splits
- logarithmic splits

Standard formula:
- `split_i = lerp( n + (f-n) * (i/C),
                   n * pow(f/n, i/C),
                   lambda )`
Where `lambda` controls distribution:
- 0.0 = linear
- 1.0 = logarithmic
Default:
- `lambda = 0.6`

Store:
- `cascadeSplits[i]` in view-space depth

---

## 6) Light-space Matrix for Each Cascade

### 6.1 Compute Frustum Corners for Cascade Slice
- Take the 8 corners of the camera frustum slice between split_i and split_{i+1}
- Convert to world-space (camera-relative world, consistent with floating origin)

### 6.2 Create Light View Matrix
Directional light view:
- `lightPos = cameraPos - sunDir * lightDistance`
- `lightView = lookAt(lightPos, cameraPos, worldUp)`
Note: position is arbitrary for directional lights, but needed for matrix.

### 6.3 Fit Orthographic Projection
Transform frustum corners into light space.
Compute AABB bounds:
- `minX..maxX`, `minY..maxY`, `minZ..maxZ`
Build ortho projection:
- `lightOrtho = ortho(minX, maxX, minY, maxY, -maxZ - margin, -minZ + margin)`
(Ensure correct handedness conventions for your math lib.)

### 6.4 Stabilize to Prevent Shadow Shimmer (Mandatory)
Shimmering occurs when the ortho projection “slides” with camera movement.

Fix: **texel snapping**
- Compute world units per texel:
  - `texelSizeX = (maxX - minX) / shadowRes`
  - `texelSizeY = (maxY - minY) / shadowRes`
- Snap the ortho bounds (or light-space origin) to texel grid:
  - `minX = floor(minX / texelSizeX) * texelSizeX`
  - `minY = floor(minY / texelSizeY) * texelSizeY`
  - recompute max from snapped min + extent
This makes shadows stable as camera moves.

---

## 7) Shadow Map Rendering

### 7.1 Depth-only Pass
For each cascade:
- bind shadow FBO with depth texture
- set viewport to shadow resolution
- clear depth
- render only shadow casters

Use a minimal vertex shader that outputs `lightSpaceMatrix * worldPos`.
Fragment shader can be empty (depth only).

### 7.2 What Geometry to Render
Render:
- Opaque chunk meshes only
- Do not render transparent blocks into shadow maps (v1)

Optional v2:
- alpha-tested foliage (leaves) as caster (requires alpha test in shadow pass)

### 7.3 Culling for Performance
For each cascade:
- render only chunks within shadow distance AND intersecting cascade frustum slice
- chunk-level culling is enough

---

## 8) Sampling Shadows in Main Render

### 8.1 Cascade Selection
In main fragment shader:
- Compute fragment view-space depth
- Select cascade index where depth < cascadeSplit[i]
- Use that cascade’s lightSpaceMatrix and depth texture

### 8.2 Shadow Test
- Transform world position into light clip space
- Project to UV
- Sample shadow depth
- Compare with current depth (with bias)

### 8.3 Bias (Fixes Shadow Acne)
Use slope-scaled bias:
- `bias = max(shadow_bias * (1 - dot(normal, lightDir)), shadow_min_bias)`
Plus optional normal offset:
- offset position along normal by `shadow_normal_bias`

Expose both to settings.

### 8.4 PCF Filtering (v1)
Use a small PCF kernel (3×3 or 5×5):
- Sample neighbor texels around UV
- Average comparisons
Configurable radius.

---

## 9) Integration with Day/Night

### 9.1 Sun Shadows
Only apply when `sunIntensity > threshold` (e.g. 0.05)
At night:
- skip shadow rendering entirely (big perf win)

### 9.2 Moon Shadows (optional v2)
- Usually very subtle
- Could reuse same CSM pipeline at lower resolution
Not required for v1.

---

## 10) Interaction with Floating Origin

Rule:
- All world positions used in shadow matrices must be in the same coordinate space as the main render.
Recommended:
- Use **camera-relative** world positions for both:
  - shadow caster rendering
  - main scene rendering
This prevents precision issues.

---

## 11) Debug Tools (Required)

- Toggle: show cascade boundaries overlay
- Toggle: visualize shadow map depth for each cascade
- Toggle: freeze cascades (stability testing)
- Sliders: bias, normalBias, lambda, shadowDistance
- Display: current cascade index under crosshair

---

## 12) Performance Targets

Defaults:
- 3 cascades
- 2048 shadow maps
- render shadow pass only during day
- chunk-level culling per cascade

Expected:
- Shadow pass cost proportional to visible chunks + cascades

---

## 13) Known Issues & Fixes

### 13.1 Shadow shimmering
Fix:
- texel snapping (mandatory)
- stable cascade splits (don’t change shadowDistance every frame)

### 13.2 Peter panning (detached shadows)
Fix:
- reduce bias
- reduce normalBias
- increase resolution or improve PCF

### 13.3 Shadow acne
Fix:
- increase bias or slope-scale bias
- ensure normals are correct (flat shading helps)

### 13.4 Swimming with greedy meshing
Usually caused by unstable world coords:
- ensure floating origin + camera-relative rendering is applied

---

## 14) Implementation Order

1. Single shadow map (no cascades) to validate pipeline
2. Add cascade splits + multiple depth textures
3. Cascade selection in shader
4. Bias controls + PCF
5. Texel snapping stabilization
6. Chunk culling per cascade
7. Day-only rendering optimisation
8. Debug views and tuning UI

---

## 15) Acceptance Criteria

- Sun casts stable shadows during day.
- Shadows do not noticeably shimmer when camera moves.
- Bias is tunable; acne and peter panning can be balanced.
- Shadow rendering is skipped at night.
- Performance remains acceptable at target render distance.

---

