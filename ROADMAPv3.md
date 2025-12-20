# Chunk Streaming Spec: Loading, Meshing, Rendering, and Unloading (Smooth View Distance)

This document specifies a **chunk streaming system** for a voxel engine that:
- Loads chunks around the player smoothly based on **view distance** and **settings**
- Generates + meshes chunks asynchronously
- Prioritizes nearby chunks
- Unloads far chunks safely
- Avoids frame spikes via budgets and staged pipelines

---

## 1) Goals

- Smooth gameplay while moving: no long stalls.
- Deterministic chunk generation (seeded).
- Configurable:
  - `viewDistanceChunks` (radius in chunks)
  - `maxLoadedChunks` (memory cap)
  - `meshDistanceChunks` (optional separate radius for rendering meshes)
  - per-frame budgets (generation, meshing, uploads)
- Correctness:
  - No rendering holes caused by missing neighbors (or handled gracefully).
  - Unloading never races with jobs still using chunk data.

---

## 2) Terminology & Definitions

- **Chunk coords**: `(cx, cz)` in 2D, optional `(cy)` if vertical chunking.
- **Chunk size**: e.g. `16x16x256`.
- **World position to chunk**:
  - `cx = floor(x / CHUNK_SIZE_X)`
  - `cz = floor(z / CHUNK_SIZE_Z)`
- **Chunk radius**:
  - view distance radius `R = viewDistanceChunks`
  - region of interest = all chunks with `dx*dx + dz*dz <= R*R` (circle) OR square if simpler.
- **Load distance** vs **render distance**:
  - `loadDistance` determines which chunks must exist in memory.
  - `meshDistance` determines which chunks must have a mesh uploaded and rendered.
  - Often: `meshDistance <= loadDistance` for perf.

---

## 3) Chunk States and Lifecycle

### 3.1 Chunk State Machine
A chunk should progress through explicit states:

- `Missing` (not in memory)
- `QueuedForLoad`
- `LoadingFromDisk`
- `Generating` (procedural)
- `Generated` (blocks available)
- `QueuedForMesh`
- `Meshing` (CPU mesh build)
- `MeshReadyCPU`
- `UploadingGPU`
- `Renderable` (GPU buffers ready)
- `Unloading` (release resources)
- `Unloaded` (removed from map)

### 3.2 Chunk Object Contents
Store:
- coords `(cx, cz[, cy])`
- block storage pointer / compressed array
- flags:
  - `dirtyBlocks` (needs remesh)
  - `needsNeighborRemesh` (when neighbors arrive)
- mesh handles:
  - opaque mesh GPU buffers
  - transparent mesh GPU buffers (optional)
- job handles / refcounts:
  - `generationJobId`
  - `meshJobId`
- last used timestamp (for LRU unloading)
- `pinCount` (prevent unloading while referenced)

---

## 4) Settings

### 4.1 User Settings
- `viewDistanceChunks` (int)  
  Example defaults: 8–12
- `loadDistanceChunks` (int)  
  Usually `viewDistance + 2` (preload ring)
- `meshDistanceChunks` (int)  
  Usually equal to viewDistance; can be smaller.
- `maxLoadedChunks` (int)  
  Hard cap to avoid memory blowups, e.g. 2048
- `maxMeshedChunks` (int)  
  Cap how many chunks may keep GPU meshes (optional)
- `chunkUploadBudgetPerFrame` (int)  
  e.g. 1–4 chunk meshes per frame
- `meshBuildBudgetPerFrameMs` (float)  
  e.g. 2–6 ms (or N tasks)
- `generationBudgetPerFrameMs` (float)
- `threads_generation` / `threads_meshing`

### 4.2 Derived Distances
- `preloadRadius = loadDistanceChunks`
- `renderRadius = meshDistanceChunks`
- `keepAliveRadius = preloadRadius + 1` (optional ring to prevent thrash)

---

## 5) Core Streaming Algorithm

### 5.1 High-level Update Loop (per frame)
Inputs:
- player position
- camera view (optional frustum)
- settings

Steps:
1. Determine `playerChunk = (pcx, pcz)`.
2. Build the **target set** of chunks to load (within `preloadRadius`).
3. Build the **target set** of chunks to mesh/render (within `renderRadius`).
4. Enqueue missing chunks for load/generation.
5. Prioritize and run jobs within budgets:
   - disk load/generate tasks
   - mesh build tasks
   - GPU uploads
6. Unload chunks outside `keepAliveRadius` and/or past caps.

### 5.2 Target Set Computation
Prefer circle (less total chunks than square for same radius):

For `dx in [-R..R]`, `dz in [-R..R]`:
- if `dx*dx + dz*dz <= R*R`, include `(pcx+dx, pcz+dz)`.

Optionally order by distance for priority queue.

### 5.3 Prioritization
Use priority key:
1. smaller `dist2` first
2. within camera forward cone first (optional)
3. within frustum first (optional)

This ensures nearby chunks appear first.

---

## 6) Asynchronous Pipeline (Jobs)

### 6.1 Worker Threads
Recommended separation:
- **Generation thread pool**: noise + block fill (CPU heavy)
- **Meshing thread pool**: greedy meshing/culled meshing (CPU heavy)
- **Main thread**: OpenGL calls only (upload buffers, create VAOs, etc.)

### 6.2 Job Types
- `Job_LoadOrGenerateChunk(cx,cz)`
  - if chunk exists on disk -> load
  - else -> generate deterministically
  - output: block data + metadata
- `Job_BuildChunkMesh(cx,cz)`
  - needs chunk + neighbors (at least for face culling)
  - output: CPU vertex/index buffers (opaque & transparent)
- `Job_UploadChunkMesh(cx,cz)` (main thread)
  - create/update VBO/IBO/VAO
  - swap mesh handles atomically

### 6.3 Neighbor Dependency
Meshing typically needs neighbor blocks to cull faces at boundaries.
Options:

**Option A (strict)**: only mesh when all 4 neighbors exist (N/E/S/W) (and vertical neighbors if applicable).  
- Pros: no seams / no missing faces.
- Cons: slower visible appearance.

**Option B (optimistic)**: mesh immediately with whatever neighbors exist; when a missing neighbor arrives, mark edges dirty and remesh.  
- Pros: chunks appear quickly.
- Cons: extra remesh work.

Recommended for smoothness: **Option B**.

Implementation detail:
- Meshing treats missing neighbor as "air" for boundary culling.
- When neighbor loads, both chunks mark `dirtyBlocks=true` for boundary remesh.

---

## 7) Smoothness Budgets (Avoid Frame Spikes)

### 7.1 Budgets to Apply
Per frame, cap:
- number of generation completions applied
- number of mesh builds started / completed
- number of GPU uploads

Suggested defaults:
- generate: up to 1–2 chunks/frame (or 2–4ms)
- mesh build: up to 1–2 chunks/frame (or 2–6ms)
- upload: up to 1 chunk/frame (more if small meshes)

### 7.2 Work Queues
Maintain queues:
- `genQueue`: prioritized by dist2
- `meshQueue`: prioritized by dist2 (and only if generated)
- `uploadQueue`: FIFO or prioritized by dist2

Each queue holds chunk coords + priority. Use a heap.

---

## 8) Caching & Unloading

### 8.1 Unload Rules
A chunk is a candidate for unloading if:
- outside `keepAliveRadius`
- not pinned (`pinCount==0`)
- no active jobs (or jobs can be canceled safely)
- not in a “grace period” (optional)

### 8.2 LRU / Memory Cap
Maintain:
- `loadedChunksCount`
- if `loadedChunksCount > maxLoadedChunks`:
  - unload farthest or least-recently-used chunks first (prefer farthest).

### 8.3 Safe Unload with Jobs
You need job-safe ownership:
- chunks have a `generationVersion` or `jobToken`.
- when a job is queued, it captures the token.
- if the chunk is unloaded/recycled, token changes, job result is discarded.

This prevents writing results into freed memory.

---

## 9) Rendering Integration

### 9.1 Render List
Each frame:
- build a list of chunks in `Renderable` state within `renderRadius`.
Optional:
- frustum cull chunk AABBs.
- sort by distance for transparency pass.

### 9.2 Opaque vs Transparent Pass
Recommended:
- Render opaque chunk meshes front-to-back (better depth rejection).
- Render transparent chunk meshes back-to-front.

### 9.3 Chunk Boundary Pop-in Mitigation
Techniques:
- Preload ring: `loadDistance = viewDistance + 2`
- Mesh ring: build mesh slightly beyond viewDistance (optional)
- Fade-in (advanced): per-chunk alpha ramp after upload (requires shader support)

---

## 10) Disk IO (Optional v1, but recommended)

### 10.1 Save Strategy
- Save modified chunks asynchronously.
- Use a region file system (like Minecraft) or per-chunk files:
  - `chunks/cx_cz.bin`
- On load:
  - schedule disk read; if missing -> generate.

### 10.2 Throttling Disk
- Limit concurrent IO tasks.
- Avoid blocking the main thread.

---

## 11) Debug/Developer Tools

- [ ] Show current `(cx,cz)` in HUD
- [ ] Show loaded chunk count
- [ ] Show queued gen/mesh/upload counts
- [ ] Render chunk borders (wireframe)
- [ ] Toggle viewDistance live (rebuild target set)
- [ ] Visualize “priority rings” (optional)

---

## 12) Suggested Data Structures

### 12.1 Chunk Map
- `unordered_map<ChunkKey, Chunk*> loadedChunks`
- `ChunkKey` packs `(cx,cz[,cy])` into 64-bit key.

### 12.2 Priority Queues
- `genQueue: min-heap by dist2`
- `meshQueue: min-heap by dist2`
- `uploadQueue: queue/heap`

### 12.3 State Tracking
- Bitsets or flags for:
  - inTargetLoadSet
  - inTargetMeshSet
  - queuedForGen
  - queuedForMesh

---

## 13) Acceptance Criteria (v1)

- Moving quickly across terrain does not freeze the game.
- Chunks load nearest-first, then outward.
- View distance is respected:
  - beyond `viewDistanceChunks`, chunks do not render
- Changing view distance in settings smoothly updates loaded/meshed sets.
- Chunks outside keepAlive/unload radius are eventually unloaded.
- No crashes or corruption when unloading while jobs are running.

---

## 14) Implementation Order (Recommended)

1. Chunk coordinate conversion + target set
2. Chunk state machine + chunk map
3. Generation job queue + worker threads + apply results
4. Meshing job queue + apply CPU meshes
5. GPU upload queue + per-frame upload budget
6. Unloading + LRU + safe job token discard
7. Frustum culling + opaque/transparent passes
8. Debug overlay + live settings changes

---

