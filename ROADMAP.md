# OpenGL Engine Roadmap

This roadmap is derived from The Cherno's OpenGL series and translated into **engine-level milestones**.  
Use this as a checklist and progression guide while building your engine.

---

## Phase 0 — Foundations
**Goal:** Window + context + sanity

- [x] Window creation abstraction (GLFW / SDL)
- [x] OpenGL context creation (core profile)
- [x] Swap buffers
- [x] VSync enable / disable
- [x] OpenGL loader (GLAD / GLEW)
- [x] Runtime OpenGL version & capability checks

---

## Phase 1 — Modern OpenGL Basics
**Goal:** Draw *something* correctly, the modern way

- [x] Core-profile OpenGL only (no fixed pipeline)
- [x] Vertex Buffer (VBO) abstraction
- [ ] Index Buffer (EBO / IBO) abstraction
- [x] Vertex Array Object (VAO) abstraction
- [x] Vertex attribute specification
- [x] Interleaved vertex layouts
- [x] Static vs dynamic buffer usage

---

## Phase 2 — Shaders
**Goal:** Full control of the GPU pipeline

- [x] Shader compilation system
- [x] Shader linking & validation
- [x] Error reporting for shaders
- [x] Shader abstraction class
- [x] Uniform upload API
- [ ] Uniform location caching
- [ ] Shader source hot-reloading
- [ ] Central shader library / registry

---

## Phase 3 — Error Handling & Debugging
**Goal:** Fail loudly, debug easily

- [ ] OpenGL debug context
- [ ] KHR_debug callback
- [ ] GL call error macros
- [ ] Assertions around GPU calls
- [x] Engine-level logging system

---

## Phase 4 — Renderer Architecture
**Goal:** Hide OpenGL behind a clean engine API

- [x] Renderer API layer
- [ ] Render command abstraction
- [x] Draw call encapsulation
- [x] Renderer statistics (draw calls, vertices)
- [x] Render state isolation
- [x] Multiple object rendering

---

## Phase 5 — Textures & Materials
**Goal:** Real assets, not hardcoded colors

- [x] Texture loading system
- [x] Texture abstraction class
- [x] Texture parameter configuration
- [x] Texture unit / slot management
- [ ] Multi-texture rendering
- [x] Texture atlases
- [ ] Material system (shader + textures + params)

---

## Phase 6 — Blending & Transparency
**Goal:** UI, sprites, and transparency

- [x] Alpha blending
- [x] Blend mode abstraction
- [ ] Premultiplied alpha support
- [ ] Transparent object ordering (basic)

---

## Phase 7 — Math & Transforms
**Goal:** Cameras, movement, real scenes

- [x] Math library (vec2/3/4, mat4)
- [ ] Transform component
- [x] Projection matrices (ortho & perspective)
- [x] View matrices (camera)
- [x] Model matrices
- [x] MVP pipeline
- [x] Camera abstraction
- [x] Frustum culling

---

## Phase 8 — Batch Rendering (Performance)
**Goal:** Reduce draw calls, scale scenes

- [ ] Batch renderer architecture
- [ ] Batched colored geometry
- [ ] Batched textured geometry
- [x] Texture slot management
- [ ] Dynamic geometry batching
- [x] Draw-call minimisation strategy (frustum culling)

---

## Phase 9 — Uniform Optimisation
**Goal:** Stop hammering the driver

- [ ] Uniform Buffer Objects (UBOs)
- [ ] Frame-level uniform buffers
- [ ] Per-object vs per-frame separation
- [ ] Persistent mapped buffers (optional)

---

## Phase 10 — Tooling & Engine UX
**Goal:** Developer-friendly engine

- [ ] ImGui integration
- [ ] Debug panels
- [x] Renderer stats overlay
- [ ] Live shader reload toggle
- [x] Runtime render mode toggles (wireframe, etc.)

---

## Phase 11 — Testing Framework
**Goal:** Don't break rendering accidentally

- [ ] Render test framework
- [ ] Isolated render tests
- [ ] Texture rendering tests
- [ ] Regression test scenes

---

## Engine v1 "Done" Definition
You can call this a **real engine** when you have:

- [x] Clean renderer API
- [ ] Shader + material system
- [x] Texture & asset loading
- [x] Camera & transform system
- [ ] Batch renderer
- [ ] Debug UI
- [x] Measured performance metrics

---

## Optional Future Directions
- Vulkan backend
- Deferred rendering
- ECS integration
- Scene graph
- Asset pipeline
- Editor tooling

---
