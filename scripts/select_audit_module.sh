#!/usr/bin/env bash

set -euo pipefail

source scripts/github_actions_common.sh

input_module="${INPUT_MODULE:-}"
modules=(
    "engine/graphics"
    "engine/core"
    "engine/math"
    "engine/input"
    "engine/ui"
    "engine/atmosphere"
    "engine/audio"
    "engine/ecs"
    "engine/physics"
    "world"
    "world/meshing"
    "world/worldgen"
    "game"
)

if [[ -n "$input_module" ]]; then
    selected="$input_module"
else
    day=$((10#$(date +%j)))
    index=$((day % ${#modules[@]}))
    selected="${modules[$index]}"
    printf 'Scheduled run: day=%s index=%s -> %s\n' "$day" "$index" "$selected"
fi

case "$selected" in
    engine/graphics|engine/core|engine/math|engine/input|engine/ui|engine/atmosphere|engine/audio|engine/ecs|engine/physics)
        path="modules/${selected//\//-}/src" ;;
    world) path="modules/world-core/src modules/world-runtime/src" ;;
    world/meshing) path="modules/world-meshing/src" ;;
    world/worldgen) path="modules/worldgen-overworld/src modules/worldgen-overworld-v2/src" ;;
    game) path="modules/game-core/src modules/game-ui/src src/game" ;;
    *) echo "Unknown audit module" >&2; exit 1 ;;
esac

write_output module "$selected"
write_output scan_paths "$path"
