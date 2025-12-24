Here is a comprehensive `decouple.md` file designed for an AI agent or a developer. It outlines the architectural shift from a hard-coded OpenGL renderer to an API-agnostic **Render Hardware Interface (RHI)** while preserving your existing greedy meshing and game logic.

***

# Technical Specification: Decoupling Renderer for Vulkan/OpenGL RHI

## 1. Objective
The goal is to move from a direct OpenGL implementation to a **Render Hardware Interface (RHI)**. This allows the engine to support multiple backends (Vulkan via `mach-gpu` and a legacy OpenGL fallback) while keeping the game logic, world generation, and greedy meshing code 100% agnostic of the graphics API.

## 2. Core Architecture: The "Frontend/Backend" Split
We will divide the engine into two distinct layers:
1.  **Frontend (Game Logic):** Manages the world, chunk data, greedy meshing, and camera. It produces "Render Commands" and "Vertex Data."
2.  **Backend (RHI):** Consumes data and commands to interface with the GPU (Vulkan/OpenGL).

## 3. The RHI Interface
Create a Zig `Interface` or a `struct` with function pointers to abstract the following operations:

```zig
const RHI = struct {
    // Lifecycle
    init: *const fn (allocator: Allocator) anyerror!void,
    deinit: *const fn () void,

    // Resource Management
    createBuffer: *const fn (data: []const u8, usage: BufferUsage) BufferHandle,
    destroyBuffer: *const fn (handle: BufferHandle) void,
    
    // Command Recording
    beginFrame: *const fn () void,
    endFrame: *const fn () void,
    
    // Draw Calls
    drawMesh: *const fn (handle: BufferHandle, count: u32, camera: CameraUniform) void,
};
```

## 4. Migration Steps

### Step A: Isolate the Vertex Format
Currently, your vertices are likely uploaded directly. We must define a fixed, byte-compatible layout.
- **Action:** Define a `Vertex` struct in a shared module.
- **Action:** Ensure the Greedy Mesher outputs a `std.ArrayList(Vertex)` or a raw `[]u8` buffer.
- **Constraint:** The Mesher must NOT call `glBufferData`. It must return the data to a "Renderer Manager."

### Step B: The "Buffer Handle" System
Vulkan and OpenGL handle IDs differently (pointers vs. integers). 
- **Action:** Implement a `Handle` system (integers or UUIDs) to reference GPU resources. 
- The Game Logic holds a `ChunkMeshHandle`. The RHI maps that handle to either a `GLuint` (VAO/VBO) or a `VkBuffer`.

### Step C: Decouple Shaders (SPIR-V Pipeline)
Vulkan uses SPIR-V; OpenGL uses GLSL.
- **Action:** Move shaders to external files.
- **Action:** Use `glslangValidator` to compile GLSL to SPIR-V for the Vulkan backend.
- **Optimization:** Use `#version 450` in GLSL and ensure `layout(set=..., binding=...)` is used, as Vulkan requires explicit descriptor sets.

### Step D: The Upload Queue (Multiplayer Optimization)
To prevent the "stuttering" during high-view-distance chunk loading:
- **Action:** Create a `TransferQueue`. 
- When a chunk is meshed, the Frontend calls `RHI.uploadAsync(mesh_data)`.
- **OpenGL Backend:** Will likely execute this on the main thread (driver limitation).
- **Vulkan Backend:** Will use a dedicated `VkTransferQueue` and Fences to upload in the background without dropping frames.

## 5. View Distance & Performance Targets
- **Indirect Drawing:** The RHI should support "Draw Indirect." This allows the CPU to send a list of 1,000 chunk handles, and the GPU culls them.
- **Uniform Management:** Replace `glUniformMatrix4fv` with a "Global Uniform Buffer" that is updated once per frame.

## 6. Implementation Notes for Agent
1.  **Memory:** Use `Zig` allocators for all CPU-side staging buffers.
2.  **Threading:** The Greedy Mesher should run on a thread pool (e.g., `zig-threadpool`).
3.  **Stability:** On NixOS, ensure the RHI backend looks for `vulkan-loader` and `libX11` via the environment variables defined in the project's `flake.nix` or `shell.nix`.
4.  **Fallback:** If `RHI.init(.vulkan)` fails (e.g., old drivers/NixOS config issues), the engine must automatically attempt `RHI.init(.opengl)`.

## 7. Data Flow Diagram
`World Data` -> `Greedy Mesher` -> `Raw Vertex Buffer` -> `RHI Upload` -> `GPU Memory` -> `RHI Draw Call`

*** 

**Next Action:** Begin by refactoring the `Chunk` struct to remove all `gl` prefixed calls, replacing them with `BufferHandle`.
