# PR 2: Migrate to Pipeline and Render Pass Managers

**Status:** 🔄 Draft (Incremental Commits)  
**Branch:** `refactor/pr2-manager-migration`  
**Depends on:** PR 1 (merged)  

## Overview

Migrate `rhi_vulkan.zig` to actually **use** the PipelineManager and RenderPassManager created in PR1. This PR eliminates the duplication between the old inline functions and the new manager modules.

## Goals

1. Replace inline render pass creation with manager calls
2. Replace inline pipeline creation with manager calls  
3. Update all field references to use managers
4. Remove ~800 lines of old code
5. Remove ~25 fields from VulkanContext

## Incremental Commit Plan

### Commit 1: Migrate HDR Render Pass Creation
- Replace `createMainRenderPass()` call with `ctx.render_pass_manager.createMainRenderPass()`
- Update `hdr_render_pass` references to use manager
- Remove old `createMainRenderPass()` function

### Commit 2: Migrate G-Pass Render Pass Creation
- Replace G-Pass render pass creation in `createGPassResources()`
- Update `g_render_pass` references to use manager

### Commit 3: Migrate Main Pipeline Creation  
- Replace `createMainPipelines()` with `ctx.pipeline_manager.createMainPipelines()`
- Update terrain, wireframe, selection, line pipeline references
- Remove old `createMainPipelines()` function

### Commit 4: Migrate UI and Cloud Pipeline Creation
- Update UI pipeline creation to use manager
- Update cloud pipeline creation to use manager
- Update swapchain UI pipeline creation

### Commit 5: Cleanup Old Fields and Functions
- Remove old pipeline fields from VulkanContext
- Remove old render pass fields from VulkanContext
- Remove old creation/destruction functions
- Update any remaining references

### Commit 6: Testing and Fixes
- Run full test suite
- Fix any regressions
- Final polish

## Field Migration Map

### Render Passes (moving to RenderPassManager)
```zig
// Before:
ctx.hdr_render_pass → ctx.render_pass_manager.hdr_render_pass
ctx.g_render_pass → ctx.render_pass_manager.g_render_pass
ctx.post_process_render_pass → ctx.render_pass_manager.post_process_render_pass
ctx.ui_swapchain_render_pass → ctx.render_pass_manager.ui_swapchain_render_pass

// Framebuffers:
ctx.main_framebuffer → ctx.render_pass_manager.main_framebuffer
ctx.g_framebuffer → ctx.render_pass_manager.g_framebuffer
ctx.post_process_framebuffers → ctx.render_pass_manager.post_process_framebuffers
ctx.ui_swapchain_framebuffers → ctx.render_pass_manager.ui_swapchain_framebuffers
```

### Pipelines (moving to PipelineManager)
```zig
// Before:
ctx.pipeline → ctx.pipeline_manager.terrain_pipeline
ctx.wireframe_pipeline → ctx.pipeline_manager.wireframe_pipeline
ctx.selection_pipeline → ctx.pipeline_manager.selection_pipeline
ctx.line_pipeline → ctx.pipeline_manager.line_pipeline
ctx.sky_pipeline → ctx.pipeline_manager.sky_pipeline
ctx.g_pipeline → ctx.pipeline_manager.g_pipeline
ctx.ui_pipeline → ctx.pipeline_manager.ui_pipeline
ctx.ui_tex_pipeline → ctx.pipeline_manager.ui_tex_pipeline
ctx.cloud_pipeline → ctx.pipeline_manager.cloud_pipeline
ctx.ui_swapchain_pipeline → ctx.pipeline_manager.ui_swapchain_pipeline
ctx.ui_swapchain_tex_pipeline → ctx.pipeline_manager.ui_swapchain_tex_pipeline

// Layouts:
ctx.pipeline_layout → ctx.pipeline_manager.pipeline_layout
ctx.sky_pipeline_layout → ctx.pipeline_manager.sky_pipeline_layout
ctx.ui_pipeline_layout → ctx.pipeline_manager.ui_pipeline_layout
ctx.ui_tex_pipeline_layout → ctx.pipeline_manager.ui_tex_pipeline_layout
ctx.cloud_pipeline_layout → ctx.pipeline_manager.cloud_pipeline_layout
```

## Testing Checklist

Each commit must:
- [ ] `nix develop --command zig build` compiles
- [ ] `nix develop --command zig build test` passes
- [ ] Manual test: Application runs and renders

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| rhi_vulkan.zig lines | 5,238 | ~4,400 |
| VulkanContext fields | ~100 | ~75 |
| Creation functions | 4 | 0 (all in managers) |

## Related

- PR 1: Created PipelineManager and RenderPassManager modules
- Issue #244: RHI Vulkan refactoring
