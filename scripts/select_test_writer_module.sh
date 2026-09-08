#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

input_module="${INPUT_MODULE:-}"
base_branch="${BASE_BRANCH:-dev}"

graphics_modules=(
    "graphics/vulkan-device"
    "graphics/vulkan-resources"
    "graphics/vulkan-pipelines"
    "graphics/vulkan-swapchain"
    "graphics/vulkan-frame"
    "graphics/rhi-types"
    "graphics/shadows"
    "graphics/post-process"
)

other_modules=(
    "engine/core"
    "engine/math"
    "engine/input"
    "world"
    "world/meshing"
    "world/worldgen"
    "engine/ecs"
    "game"
)

if [[ -n "$input_module" ]]; then
    if ! [[ "$input_module" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
        printf "ERROR: Invalid module input: '%s'\n" "$input_module" >&2
        exit 1
    fi
    selected="$input_module"
    printf 'Manual dispatch: writing tests for %s\n' "$selected"
else
    graphics_count=${#graphics_modules[@]}
    other_count=${#other_modules[@]}
    slot=$(($(date +%s) / 28800))
    parity=$((slot % 2))

    if [[ "$parity" -eq 0 ]]; then
        index=$((slot % graphics_count))
        selected="${graphics_modules[$index]}"
        printf 'Graphics slot: parity=%s index=%s -> %s\n' "$parity" "$index" "$selected"
    else
        index=$((slot % other_count))
        selected="${other_modules[$index]}"
        printf 'Other slot: parity=%s index=%s -> %s\n' "$parity" "$index" "$selected"
    fi
fi

branch_name="test/$(printf '%s' "$selected" | tr '/' '-')"

case "$selected" in
    graphics/vulkan-device)
        scan_paths="modules/engine-graphics/src/vulkan_device.zig modules/engine-graphics/src/vulkan/device.zig modules/engine-graphics/src/vulkan/rhi_state_control.zig"
        ;;
    graphics/vulkan-resources)
        scan_paths="modules/engine-graphics/src/vulkan/resource_manager.zig modules/engine-graphics/src/vulkan/resource_texture_ops.zig modules/engine-graphics/src/vulkan/rhi_resource_lifecycle.zig modules/engine-graphics/src/vulkan/rhi_resource_setup.zig"
        ;;
    graphics/vulkan-pipelines)
        scan_paths="modules/engine-graphics/src/vulkan/pipeline_manager.zig modules/engine-graphics/src/vulkan/pipeline_specialized.zig modules/engine-graphics/src/vulkan/shader_registry.zig modules/engine-graphics/src/vulkan/descriptor_manager.zig modules/engine-graphics/src/vulkan/descriptor_bindings.zig"
        ;;
    graphics/vulkan-swapchain)
        scan_paths="modules/engine-graphics/src/vulkan/swapchain_presenter.zig modules/engine-graphics/src/vulkan_swapchain.zig"
        ;;
    graphics/vulkan-frame)
        scan_paths="modules/engine-graphics/src/vulkan/frame_manager.zig modules/engine-graphics/src/vulkan/rhi_frame_orchestration.zig modules/engine-graphics/src/vulkan/render_pass_manager.zig modules/engine-graphics/src/vulkan/rhi_pass_orchestration.zig"
        ;;
    graphics/rhi-types)
        scan_paths="modules/engine-rhi/src/rhi.zig modules/engine-rhi/src/rhi_types.zig modules/engine-graphics/src/rhi_vulkan.zig modules/engine-graphics/src/rhi_tests.zig"
        ;;
    graphics/shadows)
        scan_paths="modules/engine-graphics/src/shadow_system.zig modules/engine-graphics/src/csm.zig modules/engine-graphics/src/vulkan/rhi_shadow_bridge.zig modules/engine-graphics/src/shadow_scene.zig"
        ;;
    graphics/post-process)
        scan_paths="modules/engine-graphics/src/vulkan/bloom_system.zig modules/engine-graphics/src/vulkan/fxaa_system.zig modules/engine-graphics/src/vulkan/taa_system.zig modules/engine-graphics/src/vulkan/ssao_system.zig modules/engine-graphics/src/vulkan/post_process_system.zig"
        ;;
    engine/core)
        scan_paths="modules/engine-core/src/job_system.zig modules/engine-core/src/ring_buffer.zig modules/engine-core/src/time.zig modules/engine-core/src/log.zig modules/engine-core/src/window.zig"
        ;;
    engine/math)
        scan_paths="modules/engine-math/src/vec3.zig modules/engine-math/src/mat4.zig modules/engine-math/src/frustum.zig modules/engine-math/src/utils.zig"
        ;;
    engine/input)
        scan_paths="modules/engine-input/src/input.zig modules/engine-input/src/interfaces.zig"
        ;;
    world)
        scan_paths="modules/world-core/src/chunk.zig modules/world-core/src/block.zig modules/world-core/src/block_registry.zig modules/world-meshing/src/chunk_storage.zig modules/world-meshing/src/chunk_allocator.zig modules/world-meshing/src/chunk_mesh.zig"
        ;;
    world/meshing)
        scan_paths="modules/world-meshing/src/meshing/greedy_mesher.zig modules/world-meshing/src/meshing/ao_calculator.zig modules/world-meshing/src/meshing/lighting_sampler.zig modules/world-meshing/src/meshing/biome_color_sampler.zig modules/world-meshing/src/meshing/boundary.zig"
        ;;
    world/worldgen)
        scan_paths="modules/world-worldgen/src/overworld_generator.zig modules/world-worldgen/src/biome.zig modules/world-worldgen/src/caves.zig modules/world-worldgen/src/terrain_shape_generator.zig modules/world-worldgen/src/coastal_generator.zig modules/world-worldgen/src/noise_sampler.zig modules/world-worldgen/src/height_sampler.zig modules/world-worldgen/src/surface_builder.zig"
        ;;
    engine/ecs)
        scan_paths="modules/engine-ecs/src/storage.zig modules/engine-ecs/src/manager.zig modules/engine-ecs/src/entity.zig modules/engine-ecs/src/components.zig"
        ;;
    game)
        scan_paths="src/game/player.zig src/game/screen.zig src/game/inventory.zig src/game/settings/ src/game/input_mapper.zig src/game/session.zig"
        ;;
    *)
        scan_paths="src/${selected}"
        ;;
esac

write_output module "$selected"
write_output branch "$branch_name"
write_output base_branch "$base_branch"
write_output scan_paths "$scan_paths"
