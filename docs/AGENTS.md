# AGENTS.md - Zig OpenGL Voxel Engine

## Build Commands
```bash
nix develop        # Enter dev shell (provides zig, SDL3, GLEW, OpenGL)
zig build          # Build the project
zig build run      # Build and run
nix build          # Production build (outputs to ./result/bin/)
```
No tests - this is a graphics/game project. Verify changes by running `zig build run`.

## Code Style
- **Zig 0.14** (master/nightly), uses SDL3 + GLEW + OpenGL 3.3
- **Imports**: `@import("std")` first, then local modules, then `c.zig` for C bindings
- **Naming**: `snake_case` for vars/functions, `PascalCase` for types/structs
- **Errors**: Return error unions (`!void`), propagate with `try`, use `defer` for cleanup
- **C Interop**: Access C via `c.` prefix (see `src/c.zig`), explicit C types (c.GLuint)
- **Constants**: Prefer `const`, use `\\` for multiline GLSL shader strings
- **Structure**: Engine code in `src/engine/`, world/voxel code in `src/world/`
