# PR 1: Pipeline + Render Pass Extraction

**Status:** 🔄 In Progress  
**Branch:** `refactor/pr1-pipeline-renderpass`  
**Replaces:** Original "Device + Swapchain" plan (already modular)

## Overview

Extract pipeline and render pass management from `rhi_vulkan.zig` into dedicated managers. This is the first step in eliminating the god object anti-pattern.

**Note:** Device and swapchain are already well-modularized in `vulkan_device.zig` and `vulkan_swapchain.zig`. This PR focuses on the next layer: pipelines and render passes.

## Goals

1. ✅ Create `PipelineManager` to encapsulate all pipeline creation and management
2. ✅ Create `RenderPassManager` to encapsulate render pass and framebuffer management  
3. 🔄 Integrate managers into `rhi_vulkan.zig`
4. 🔄 Remove pipeline/renderpass fields from `VulkanContext`
5. 🔄 Reduce `rhi_vulkan.zig` by ~1,200 lines

## Files

### New Files (Created ✓)
- `src/engine/graphics/vulkan/pipeline_manager.zig` (~650 lines)
- `src/engine/graphics/vulkan/render_pass_manager.zig` (~550 lines)

### Modified Files
- `src/engine/graphics/rhi_vulkan.zig` (Integration in progress)

## Current Status

### ✅ Completed
- [x] Created `PipelineManager` with all pipeline types:
  - Terrain, wireframe, selection, line pipelines
  - G-Pass pipeline
  - Sky pipeline
  - UI pipelines (colored + textured)
  - Cloud pipeline
  - Debug shadow pipeline (conditional)
  - All pipeline layouts

- [x] Created `RenderPassManager` with:
  - HDR render pass (with MSAA support)
  - G-Pass render pass
  - Post-process render pass
  - UI swapchain render pass
  - Framebuffer management for all passes

### 🔄 In Progress
- [ ] Add manager fields to `VulkanContext`:
  ```zig
  pipeline_manager: PipelineManager,
  render_pass_manager: RenderPassManager,
  ```

- [ ] Replace inline creation calls:
  ```zig
  // Before:
  try createMainRenderPass(ctx);
  try createMainPipelines(ctx);
  
  // After:
  try ctx.render_pass_manager.createMainRenderPass(vk_device, extent, msaa_samples);
  try ctx.pipeline_manager.createMainPipelines(allocator, vk_device, render_pass, g_render_pass, msaa_samples);
  ```

- [ ] Update all field accesses:
  ```zig
  // Before:
  ctx.pipeline
  ctx.hdr_render_pass
  ctx.main_framebuffer
  
  // After:
  ctx.pipeline_manager.terrain_pipeline
  ctx.render_pass_manager.hdr_render_pass
  ctx.render_pass_manager.main_framebuffer
  ```

### 📋 Remaining
- [ ] Update cleanup code to use manager `deinit()` methods
- [ ] Remove old pipeline/renderpass fields from VulkanContext
- [ ] Remove old creation/destruction functions from rhi_vulkan.zig
- [ ] Run full test suite

## Fields to Remove from VulkanContext

### Pipeline Fields (~15 fields)
- `pipeline_layout` → Use `pipeline_manager.pipeline_layout`
- `pipeline` → Use `pipeline_manager.terrain_pipeline`
- `wireframe_pipeline` → Use `pipeline_manager.wireframe_pipeline`
- `selection_pipeline` → Use `pipeline_manager.selection_pipeline`
- `line_pipeline` → Use `pipeline_manager.line_pipeline`
- `sky_pipeline` → Use `pipeline_manager.sky_pipeline`
- `sky_pipeline_layout` → Use `pipeline_manager.sky_pipeline_layout`
- `ui_pipeline` → Use `pipeline_manager.ui_pipeline`
- `ui_pipeline_layout` → Use `pipeline_manager.ui_pipeline_layout`
- `ui_tex_pipeline` → Use `pipeline_manager.ui_tex_pipeline`
- `ui_tex_pipeline_layout` → Use `pipeline_manager.ui_tex_pipeline_layout`
- `ui_swapchain_pipeline` → Use `pipeline_manager.ui_swapchain_pipeline`
- `ui_swapchain_tex_pipeline` → Use `pipeline_manager.ui_swapchain_tex_pipeline`
- `cloud_pipeline` → Use `pipeline_manager.cloud_pipeline`
- `cloud_pipeline_layout` → Use `pipeline_manager.cloud_pipeline_layout`
- `g_pipeline` → Use `pipeline_manager.g_pipeline`
- `g_pipeline_layout` → Use `pipeline_manager.pipeline_layout` (shares main layout)

### Render Pass Fields (~8 fields)
- `hdr_render_pass` → Use `render_pass_manager.hdr_render_pass`
- `g_render_pass` → Use `render_pass_manager.g_render_pass`
- `post_process_render_pass` → Use `render_pass_manager.post_process_render_pass`
- `ui_swapchain_render_pass` → Use `render_pass_manager.ui_swapchain_render_pass`
- `main_framebuffer` → Use `render_pass_manager.main_framebuffer`
- `g_framebuffer` → Use `render_pass_manager.g_framebuffer`
- `post_process_framebuffers` → Use `render_pass_manager.post_process_framebuffers`
- `ui_swapchain_framebuffers` → Use `render_pass_manager.ui_swapchain_framebuffers`

**Total fields removed:** ~23 fields

## Testing Checklist

- [ ] `nix develop --command zig build` compiles
- [ ] `nix develop --command zig build test` passes
- [ ] `nix develop --command zig build test-integration` passes
- [ ] Manual test: Application runs and renders correctly
- [ ] Manual test: Window resize works (tests swapchain recreation)
- [ ] Manual test: MSAA toggle works (tests pipeline recreation)
- [ ] Manual test: All rendering features work (shadows, SSAO, bloom, FXAA)

## Migration Path

### Step 1: Add Managers
```zig
const VulkanContext = struct {
    // Existing subsystems (keep these):
    vulkan_device: VulkanDevice,
    swapchain: SwapchainPresenter,
    resources: ResourceManager,
    frames: FrameManager,
    descriptors: DescriptorManager,
    
    // NEW: Add managers
    pipeline_manager: PipelineManager,
    render_pass_manager: RenderPassManager,
    
    // ... other fields
};
```

### Step 2: Initialize Managers
```zig
fn initContext(...) !void {
    // Existing initialization:
    ctx.vulkan_device = try VulkanDevice.init(allocator, ctx.window);
    ctx.swapchain = try SwapchainPresenter.init(...);
    // ...
    
    // NEW: Initialize managers
    ctx.pipeline_manager = try PipelineManager.init(&ctx.vulkan_device, &ctx.descriptors, null);
    ctx.render_pass_manager = RenderPassManager.init(allocator);
}
```

### Step 3: Use Managers
```zig
// Creating resources:
try ctx.render_pass_manager.createMainRenderPass(vk_device, extent, msaa_samples);
try ctx.pipeline_manager.createMainPipelines(allocator, vk_device, 
    ctx.render_pass_manager.hdr_render_pass,
    ctx.render_pass_manager.g_render_pass,
    msaa_samples);

// Accessing resources:
const pipeline = ctx.pipeline_manager.terrain_pipeline;
const render_pass = ctx.render_pass_manager.hdr_render_pass;
```

## Related PRs

- PR 2: Post-Processing System Extraction (HDR, Bloom, FXAA consolidation)
- PR 3: UI Rendering System Extraction
- PR 4: Final Coordinator Refactor

## Estimated Impact

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| rhi_vulkan.zig lines | 5,228 | ~4,000 | -1,200 |
| VulkanContext fields | ~100 | ~77 | -23 |
| New module lines | 0 | ~1,200 | +1,200 |
| **Net change** | | | **~0** (reorganization) |

**Risk:** Medium (touches many rendering code paths, but changes are mechanical)

## Notes

- PipelineManager and RenderPassManager are already created and compile successfully
- Integration requires updating many references throughout rhi_vulkan.zig
- Each field access change is mechanical but there are many of them
- Consider using find/replace or refactoring tools for bulk changes

