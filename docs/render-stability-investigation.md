# render-stability-investigation.md  
## Terrain Shimmering / Morphing at High Altitude & Large Render Distance

This document is a **handoff spec for investigation and fixes** related to terrain appearing to *morph, shimmer, crawl, or lose smoothness* when flying high and increasing render distance.

This is **not a worldgen logic bug**. It is almost certainly a **rendering precision + depth issue**, possibly compounded by meshing or shading choices.

The goal is to **identify the exact cause(s)** and **implement industry-standard fixes** used by voxel engines (Minecraft, Minetest, etc.).

---

## 1) Observed Symptoms

- Terrain appears to subtly move or shimmer as the camera moves.
- Effect increases:
  - with higher altitude
  - with larger render distance / far plane
- Most visible on:
  - large flat areas
  - sloped terrain
  - distant mountains
- Looks like “shader movement”, but geometry is static.

---

## 2) Primary Root Causes (Ranked by Likelihood)

### 2.1 Floating-Point Precision Loss (Very Likely)
**Problem**
- Rendering uses large absolute world-space coordinates.
- GPU uses 32-bit floats.
- Precision drops as values grow larger.
- Small vertex differences become unstable frame-to-frame.

**Symptoms**
- Shimmering terrain
- “Crawling” edges
- Motion that looks like shader artifacts

**Industry solution**
➡ **Floating Origin / Camera-relative rendering**

---

### 2.2 Depth Buffer Precision Collapse (Very Likely)
**Problem**
- Large far plane (e.g. 20k–100k+ units)
- Standard depth buffer is non-linear
- Precision concentrated near camera
- Far geometry loses depth resolution

**Symptoms**
- Z-fighting-like shimmer
- Surfaces flicker or lose smoothness
- Artifacts worsen as render distance increases

**Industry solution**
➡ **Reverse-Z + floating-point depth buffer + sane near plane**

---

### 2.3 Shader-side Noise or Continuous LOD (Possible)
**Problem**
- Terrain noise or displacement sampled in shaders
- Or continuous LOD morphing without snapping
- Small camera movements alter sampled values

**Symptoms**
- Terrain shape subtly changes as camera moves
- Adjacent chunks disagree slightly

**Rule**
➡ Terrain noise must be **CPU-only**, baked into meshes.

---

### 2.4 Normal / Lighting Instability (Possible)
**Problem**
- Greedy meshing + averaged normals
- Or normals reconstructed in shader
- Interpolation causes lighting shifts

**Symptoms**
- Brightness changes with camera movement
- Looks like surface “rippling”

**Fix**
➡ Flat shading or strict per-face normals.

---

### 2.5 Aggressive Frustum Culling (Lower probability)
**Problem**
- Precision errors near frustum edges
- Chunks popping in/out rapidly

**Fix**
➡ Conservative chunk AABBs, chunk-level culling only.

---

## 3) Mandatory Fixes to Implement

### 3.1 Floating Origin (Required)

**Rule**
- Never send large absolute world coordinates to the GPU.

**Implementation**
- Keep camera near `(0,0,0)`
- All chunk/world positions are computed relative to camera

**Example**
```cpp
vec3 relativePos = worldPos - cameraWorldPos;

