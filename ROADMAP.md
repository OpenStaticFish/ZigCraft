# OpenGL Engine Roadmap

This roadmap is derived from The Cherno’s OpenGL series and translated into **engine-level milestones**.  
Use this as a checklist and progression guide while building your engine.

---

## Phase 0 — Foundations
**Goal:** Window + context + sanity

- [ ] Window creation abstraction (GLFW / SDL)
- [ ] OpenGL context creation (core profile)
- [ ] Swap buffers
- [ ] VSync enable / disable
- [ ] OpenGL loader (GLAD / GLEW)
- [ ] Runtime OpenGL version & capability checks

---

## Phase 1 — Modern OpenGL Basics
**Goal:** Draw *something* correctly, the modern way

- [ ] Core-profile OpenGL only (no fixed pipeline)
- [ ] Vertex Buffer (VBO) abstraction
- [ ] Index Buffer (EBO / IBO) abstraction
- [ ] Vertex Array Object (VAO) abstraction
- [ ] Vertex attribute specification
- [ ] Interleaved vertex layouts
- [ ] Static vs dynamic buffer usage

---

## Phase 2 — Shaders
**Goal:** Full control of the GPU pipeline

- [ ] Shader compilation system
- [ ] Shader linking & validation
- [ ] Error reporting for shaders
- [ ] Shader abstraction class
- [ ] Uniform upload API
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
- [ ] Engine-level logging system

---

## Phase 4 — Renderer Architecture
**Goal:** Hide OpenGL behind a clean engine API

- [ ] Renderer API layer
- [ ] Render command abstraction
- [ ] Draw call encapsulation
- [ ] Renderer statistics (draw calls, vertices)
- [ ] Render state isolation
- [ ] Multiple object rendering

---

## Phase 5 — Textures & Materials
**Goal:** Real assets, not hardcoded colors

- [ ] Texture loading system
- [ ] Texture abstraction class
- [ ] Texture parameter configuration
- [ ] Texture unit / slot management
- [ ] Multi-texture rendering
- [ ] Texture atlases
- [ ] Material system (shader + textures + params)

---

## Phase 6 — Blending & Transparency
**Goal:** UI, sprites, and transparency

- [ ] Alpha blending
- [ ] Blend mode abstraction
- [ ] Premultiplied alpha support
- [ ] Transparent object ordering (basic)

---

## Phase 7 — Math & Transforms
**Goal:** Cameras, movement, real scenes

- [ ] Math library (vec2/3/4, mat4)
- [ ] Transform component
- [ ] Projection matrices (ortho & perspective)
- [ ] View matrices (camera)
- [ ] Model matrices
- [ ] MVP pipeline
- [ ] Camera abstraction

---

## Phase 8 — Batch Rendering (Performance)
**Goal:** Reduce draw calls, scale scenes

- [ ] Batch renderer architecture
- [ ] Batched colored geometry
- [ ] Batched textured geometry
- [ ] Texture slot management
- [ ] Dynamic geometry batching
- [ ] Draw-call minimisation strategy

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
- [ ] Renderer stats overlay
- [ ] Live shader reload toggle
- [ ] Runtime render mode toggles (wireframe, etc.)

---

## Phase 11 — Testing Framework
**Goal:** Don’t break rendering accidentally

- [ ] Render test framework
- [ ] Isolated render tests
- [ ] Texture rendering tests
- [ ] Regression test scenes

---

## Engine v1 “Done” Definition
You can call this a **real engine** when you have:

- [ ] Clean renderer API
- [ ] Shader + material system
- [ ] Texture & asset loading
- [ ] Camera & transform system
- [ ] Batch renderer
- [ ] Debug UI
- [ ] Measured performance metrics

---

## Optional Future Directions
- Vulkan backend
- Deferred rendering
- ECS integration
- Scene graph
- Asset pipeline
- Editor tooling

---
