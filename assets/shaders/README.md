# Shader Architecture

This project uses Vulkan-style GLSL shaders.

## Directory Structure

```
shaders/
├── vulkan/
│   ├── terrain.vert/frag  # Vulkan terrain shaders
│   ├── shadow.vert/frag   # Vulkan shadow pass
│   ├── sky.vert/frag      # Vulkan sky rendering
│   └── ui.vert/frag       # Vulkan UI rendering
│   └── *.spv              # Compiled SPIR-V bytecode
```

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

## Shader Logic

The shaders handle the following core features:

1. **Shadow mapping** (`calculateShadow()`) - PCF filtering, cascade selection
2. **Lighting** - Diffuse, ambient, fog calculations
3. **Texture atlas** - Tile UV calculation from tile ID

