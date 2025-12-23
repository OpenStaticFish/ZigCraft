# Shader Architecture

This project maintains separate shaders for OpenGL and Vulkan due to fundamental API differences.

## Directory Structure

```
shaders/
├── terrain.vert/frag    # OpenGL 3.3 terrain shaders
├── vulkan/
│   ├── terrain.vert/frag  # Vulkan terrain shaders
│   ├── shadow.vert/frag   # Vulkan shadow pass
│   ├── sky.vert/frag      # Vulkan sky rendering
│   └── ui.vert/frag       # Vulkan UI rendering
│   └── *.spv              # Compiled SPIR-V bytecode
```

## Key Differences Between OpenGL and Vulkan Shaders

| Feature | OpenGL | Vulkan |
|---------|--------|--------|
| GLSL Version | `#version 330 core` | `#version 450` |
| Input/Output | `in/out` | `layout(location = X) in/out` |
| Uniforms | `uniform mat4 uName` | `layout(set=X, binding=Y) uniform { ... }` |
| Push Constants | N/A | `layout(push_constant) uniform { ... }` |
| Y-axis | Points up | Points down (flip in vertex shader) |
| Depth Range | [-1, 1] | [0, 1] |

## Compilation

Vulkan shaders must be compiled to SPIR-V before use:

```bash
# Single shader
glslangValidator -V shader.vert -o shader.vert.spv

# All shaders (from project root)
for f in assets/shaders/vulkan/*.vert assets/shaders/vulkan/*.frag; do
  glslangValidator -V "$f" -o "$f.spv"
done
```

## Shared Logic

The following shader logic is identical between backends and should be kept in sync:

1. **Shadow mapping** (`calculateShadow()`) - PCF filtering, cascade selection
2. **Lighting** - Diffuse, ambient, fog calculations
3. **Texture atlas** - Tile UV calculation from tile ID

When modifying shared logic, update both OpenGL and Vulkan versions.

## OpenGL Embedded Shaders

Some OpenGL shaders are embedded directly in Zig code for simplicity:
- `rhi_opengl.zig`: UI shaders (`ui_vertex_shader`, `ui_fragment_shader`)
- `rhi_opengl.zig`: Sky shaders (`sky_vertex_shader`, `sky_fragment_shader`)

These correspond to the Vulkan shaders in `vulkan/ui.*` and `vulkan/sky.*`.
