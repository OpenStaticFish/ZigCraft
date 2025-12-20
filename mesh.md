# meshing.md — Chunk Meshing (16×256×16) with Face Culling + Greedy Meshing

This document specifies the meshing system for a voxel engine with chunks sized **16 (X) × 256 (Y) × 16 (Z)**.
It covers:
- Face visibility (culling)
- Greedy meshing (rectangle merging)
- Subchunk strategy (16×16×16) for smooth updates
- Opaque vs transparent passes
- Chunk-boundary neighbor handling
- Data structures, state, and rebuild triggers

---

## 1) Goals

- Minimize triangles/draw calls via:
  - **Face culling** (don’t emit internal faces)
  - **Greedy meshing** (merge adjacent coplanar faces into large quads)
- Support smooth streaming and edits:
  - Mesh rebuilds should be limited to affected regions, not entire 256-high chunks.
- Deterministic output given same chunk/block data.

---

## 2) Chunk Layout & Subchunks

### 2.1 Storage
- Chunk dimensions: `CX=16`, `CY=256`, `CZ=16`
- Total blocks: 65,536
- Block storage can remain as a single array:
  - index: `idx = x + z*CX + y*CX*CZ`
  - memory order: X fastest, then Z, then Y

### 2.2 Meshing granularity: subchunks
Mesh in vertical sections:
- Subchunk size: `16×16×16`
- Subchunk count: `CY / 16 = 16`

Benefits:
- Block edits rebuild only 1–2 subchunks.
- Streaming can cull and upload smaller pieces.

### 2.3 Rendering options
- Option A (recommended): draw per subchunk (opaque + transparent)
  - Pros: simple, good rebuild granularity, good culling.
  - Cons: more draw calls (up to 16 per chunk per pass).
- Option B: merge subchunk meshes into one chunk mesh (optional later).

---

## 3) Mesh Data Model

### 3.1 Passes
Maintain separate meshes:
- **Opaque mesh**: solid blocks, depth-write on
- **Transparent mesh**: water/glass/leaves if needed, depth-write off (typical)

Do not mix opaque and transparent in the same mesh.

### 3.2 Vertex format (minimal v1)
Per vertex:
- `vec3 position`
- `vec3 normal` (or packed normal)
- `vec2 uv`
Optional later:
- AO/light (packed u8), biome tint, etc.

### 3.3 GPU resources
Per subchunk per pass:
- VBO + IBO (+ VAO)
- Or a single VBO with interleaved + glDrawElements

Upload budget is managed elsewhere (see chunk streaming spec).

---

## 4) Face Visibility (Culling)

A face is visible if:
- The current block is renderable for this pass, and
- The neighbor block in that face direction is NOT occluding this pass.

Definitions:
- `isOpaque(id)` — true for solid blocks
- `isTransparent(id)` — true for blocks rendered in transparent pass
- `occludesOpaque(neighbor)` — neighbor blocks that hide opaque faces (typically opaque blocks)
- `occludesTransparent(neighbor)` — neighbor blocks that hide transparent faces (often anything non-air, depends on your water/glass rules)

### 4.1 Opaque pass visibility rule (recommended)
Emit face if:
- `isOpaque(cur) == true`
- `isOpaque(nei) == false` (treat air, water, etc. as non-opaque)

### 4.2 Transparent pass visibility rule (simple v1)
Emit face if:
- `isTransparent(cur) == true`
- `nei` is air OR `nei` is not the same transparent “fluid group”
  - For water: don’t render faces between adjacent water blocks.
  - For glass: often don’t render internal glass-to-glass faces either.

---

## 5) Neighbor Sampling (Chunk Borders)

Meshing requires neighbor blocks for boundary faces:
- If neighbor chunk exists: sample real neighbor block.
- If neighbor chunk missing: treat neighbor as air, emit faces.
  - When neighbor later loads, mark border subchunks dirty and remesh.

### 5.1 Border invalidation rules
When a chunk at `(cx,cz)` loads or changes:
- It must notify its 4 neighbors (N/E/S/W) to remesh the touching border subchunks:
  - Example: if east neighbor loads, current chunk’s `x=15` border subchunks become dirty.
- If you have vertical subchunks: only mark those overlapping the changed y-range.

---

## 6) Greedy Meshing Overview

Greedy meshing merges many 1×1 quads into fewer large rectangles.

You run greedy meshing for each of the 3 axes:
- Faces perpendicular to X: ±X
- Faces perpendicular to Y: ±Y
- Faces perpendicular to Z: ±Z

Greedy meshing operates on a 2D “mask” per slice boundary.

### 6.1 Face Material Key
To merge, faces must match a key:
- `key = (blockId, faceDir, passType[, textureId])`
If texture differs per face, include faceDir or faceTextureId.

If lighting/AO differs per vertex, merging may need to be limited (v1 can ignore).

---

## 7) Per-Subchunk Meshing Procedure

Given a subchunk:
- X range: `[0..15]`
- Z range: `[0..15]`
- Y range: `[y0..y0+15]` where `y0 = subchunkIndex * 16`

For each pass (Opaque then Transparent):

1. Clear mesh builders (CPU vertex/index arrays).
2. Run greedy for X faces (±X) for boundaries inside the subchunk and across borders.
3. Run greedy for Y faces (±Y).
4. Run greedy for Z faces (±Z).
5. Output CPU mesh buffers.
6. Queue GPU upload (main thread).

---

## 8) Greedy Meshing Details (per axis)

This section defines the exact masks and loops for each axis.

### 8.1 Common concepts
- A “slice boundary” is between two adjacent blocks.
- For each boundary, build a 2D mask of faces to emit.
- Merge rectangles of identical face keys.

Mask cells store either:
- Empty
- `FaceCell { key, direction }`

### 8.2 Axis X (faces perpendicular to X)
For X boundaries, the 2D mask is over **(Y,Z)**.

Loop:
- `xBoundary` in `[0..16]` (inclusive; boundaries count is 17)
- mask size: `H = 16` for Y within the subchunk, `W = 16` for Z

At boundary `xBoundary`, for each `(y,z)` in the subchunk:
- `left  = block(xBoundary - 1, y, z)` (if xBoundary==0 -> neighbor chunk west)
- `right = block(xBoundary,     y, z)` (if xBoundary==16 -> neighbor chunk east)

Decide faces:
- If `left` is renderable for pass and `right` occludes == false => emit **+X face** for `left`
- If `right` is renderable for pass and `left` occludes == false => emit **-X face** for `right`

Store the chosen face (if any) in mask cell at (y,z).

Then greedy-merge rectangles in the (Y,Z) mask.

### 8.3 Axis Y (faces perpendicular to Y)
For Y boundaries, the 2D mask is over **(X,Z)**.

Loop:
- `yBoundary` in `[y0..y0+16]`
- mask size: X=16, Z=16

At boundary `yBoundary`, for each `(x,z)`:
- `below = block(x, yBoundary - 1, z)` (if yBoundary==0 -> treat as solid bedrock or air per world rules)
- `above = block(x, yBoundary,     z)` (if yBoundary==256 -> air)

Decide faces:
- If `below` renderable and `above` not occluding => emit **+Y face** for `below`
- If `above` renderable and `below` not occluding => emit **-Y face** for `above`

Greedy-merge rectangles in (X,Z).

### 8.4 Axis Z (faces perpendicular to Z)
For Z boundaries, the 2D mask is over **(X,Y)**.

Loop:
- `zBoundary` in `[0..16]`
- mask size: X=16, Y=16 (within subchunk)

At boundary `zBoundary`, for each `(x,y)`:
- `back  = block(x, y, zBoundary - 1)` (if zBoundary==0 -> neighbor chunk north)
- `front = block(x, y, zBoundary)`     (if zBoundary==16 -> neighbor chunk south)

Decide faces:
- If `back` renderable and `front` not occluding => emit **+Z face** for `back`
- If `front` renderable and `back` not occluding => emit **-Z face** for `front`

Greedy-merge rectangles in (X,Y).

---

## 9) Rectangle Merge Algorithm (Greedy Step)

Given a 2D mask `mask[u][v]` with dimensions `U×V`:

1. Scan cells in a fixed order (u then v).
2. When a non-empty cell is found at `(u0,v0)`:
   - Let `k = mask[u0][v0].key`.
3. Find max width:
   - `w` = largest such that for all `du in [0..w-1]`, `mask[u0+du][v0]` has key `k`.
4. Find max height:
   - `h` = largest such that for all `dv in [0..h-1]` and all `du in [0..w-1]`,
     `mask[u0+du][v0+dv]` has key `k`.
5. Emit one quad for the rectangle (size w×h).
6. Clear those cells to empty.
7. Continue scanning.

Merging requirements:
- keys must match exactly, including direction and texture/material.

---

## 10) Quad Emission Rules

### 10.1 Vertex positions
Each rectangle produces one quad (4 vertices, 6 indices).

You compute quad corners based on:
- axis (X/Y/Z)
- boundary coordinate (xBoundary, yBoundary, zBoundary)
- rectangle extents in the mask dimensions

Example: for X faces, rectangle spans:
- y range: `[yStart .. yStart + h]`
- z range: `[zStart .. zStart + w]`
- x constant: `xBoundary` (for -X or +X depends on which block is emitting)

### 10.2 Normals
- +X, -X, +Y, -Y, +Z, -Z are constant normals.

### 10.3 UVs
Two common approaches:

**Tiled UVs (recommended for block textures)**
- u spans `[0..w]`, v spans `[0..h]`
- In shader, sample atlas using block face texture + fractional part if you want repeats.

**Atlas-per-face UVs**
- For each block face texture:
  - base UV rect in atlas
  - scale by w/h if repeating
  - or keep fixed and accept stretching (not recommended)

Pick one and ensure it is consistent across all faces.

---

## 11) Dirty Flags & Remeshing

### 11.1 When to mark a subchunk dirty
- Any block change within its y-range.
- Any block change in a neighboring chunk that touches one of its faces:
  - x=0 or x=15 border
  - z=0 or z=15 border
- For Y boundaries:
  - if your world supports stacked chunks, handle vertical neighbors similarly.

### 11.2 Remesh scheduling
- Dirty subchunks are queued for meshing.
- Queue priority can be based on distance to player.

### 11.3 Cancelling / invalidating jobs
Use a `meshVersion` or `jobToken` per subchunk:
- Increment token when:
  - the subchunk is dirtied again
  - the subchunk is unloaded
- Worker jobs capture token; results are discarded if token mismatches.

---

## 12) Performance Notes (for 16×256×16)

- Reuse mask buffers to avoid allocations:
  - For X and Z masks: 16×16
  - For Y masks: 16×16
- Use compact keys (32-bit):
  - `key = blockId | (faceDir<<16) | (pass<<20) | (texId<<22)`
- Separate opaque and transparent meshes to simplify ordering and reduce overdraw.
- For v1, greedy meshing on opaque is the biggest win.
  - Transparent can be naive first, then greedy later.

---

## 13) Acceptance Criteria

- Adjacent solid blocks do not produce internal faces.
- A 2×2 flat area of visible identical faces produces **2 triangles** (one quad), not 8 triangles.
- Chunk borders render correctly:
  - If neighbor missing: faces visible.
  - When neighbor loads: border subchunks remesh and internal faces disappear.
- Editing one block only remeshes the affected subchunk(s), not the entire 256 height.
- Opaque and transparent geometry are not mixed in one draw call/mesh.

---

