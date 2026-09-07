#!/usr/bin/env python3
"""Validate and assemble ordinary benchmark result artifacts."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 4
PRESETS = ("low", "medium", "high")
SCENARIOS = ("stationary", "traversal", "rapid-turn", "teleport-eviction")


def load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: JSON root must be an object")
    return value


def require(value: dict[str, Any], path: str, source: str) -> Any:
    current: Any = value
    try:
        for part in path.split("."):
            current = current[part]
    except (KeyError, TypeError) as exc:
        raise ValueError(f"{source}: missing {path}") from exc
    return current


def require_number(value: dict[str, Any], path: str, source: str) -> None:
    number = require(value, path, source)
    if not isinstance(number, (int, float)) or isinstance(number, bool):
        raise ValueError(f"{source}: {path} must be numeric")
    if not math.isfinite(number):
        raise ValueError(f"{source}: {path} must be finite")


def validate_result(value: dict[str, Any], source: str) -> None:
    if value.get("schema_version") != SCHEMA_VERSION or value.get("artifact_type") != "benchmark-result":
        raise ValueError(f"{source}: requires benchmark-result schema_version {SCHEMA_VERSION}")
    if value.get("preset") not in (*PRESETS, "ultra", "extreme"):
        raise ValueError(f"{source}: unknown preset")
    if value.get("scenario") not in SCENARIOS:
        raise ValueError(f"{source}: unknown scenario")
    for path in (
        "world_seed",
        "render_distance",
        "frames",
        "duration_s",
        "fps.avg",
        "fps.p1",
        "frame_ms.avg",
        "frame_ms.p99",
        "gpu_ms.total.avg",
        "draw_calls_avg",
        "vertices_avg",
        "chunks_rendered_avg",
        "gpu_memory_mb_max",
        "completion.sampled_duration_s",
        "completion.requested_duration_s",
        "completion.sampled_frame_count",
    ):
        require_number(value, path, source)
    if require(value, "frames", source) <= 0 or require(value, "duration_s", source) <= 0:
        raise ValueError(f"{source}: benchmark has no sampled frames or duration")
    completion = require(value, "completion", source)
    if not isinstance(completion, dict) or completion.get("scenario_completed") is not True or completion.get("warmup_ready") is not True or completion.get("warmup_timed_out") is not False:
        raise ValueError(f"{source}: benchmark completion evidence is incomplete")
    if completion["sampled_duration_s"] < completion["requested_duration_s"] or completion["sampled_frame_count"] != value["frames"]:
        raise ValueError(f"{source}: benchmark completion evidence does not match samples")
    for path in ("build.mode", "build.world", "provenance.gpu_adapter", "provenance.gpu_driver", "provenance.runner", "provenance.zig_toolchain"):
        if not isinstance(require(value, path, source), str):
            raise ValueError(f"{source}: {path} must be a string")
    legacy_fixture = value.get("build", {}).get("fixture")
    if legacy_fixture not in (None, ""):
        raise ValueError(f"{source}: benchmark fixture metadata is no longer supported")
    if require(value, "build.headless", source) is not True:
        raise ValueError(f"{source}: benchmark results must be headless")
    resolution = require(value, "build.resolution", source)
    if not isinstance(resolution, list) or len(resolution) != 2 or not all(isinstance(entry, int) and entry > 0 for entry in resolution):
        raise ValueError(f"{source}: build.resolution must contain two positive dimensions")


def validate_baseline(value: dict[str, Any], source: str) -> None:
    if value.get("schema_version") != SCHEMA_VERSION or value.get("artifact_type") != "benchmark-baseline":
        raise ValueError(f"{source}: requires benchmark-baseline schema_version {SCHEMA_VERSION}")
    results = require(value, "results", source)
    if not isinstance(results, dict):
        raise ValueError(f"{source}: results must be an object")
    for preset in PRESETS:
        for scenario in SCENARIOS:
            validate_result(require(results, f"{preset}.{scenario}", source), f"{source}:{preset}/{scenario}")


def assemble(paths: list[Path], output: Path, overwrite: bool) -> None:
    if output.exists() and not overwrite:
        raise ValueError(f"refusing to overwrite {output}; pass --overwrite")
    results: dict[str, dict[str, dict[str, Any]]] = {preset: {} for preset in PRESETS}
    for path in paths:
        value = load(path)
        validate_result(value, str(path))
        preset, scenario = value["preset"], value["scenario"]
        if preset in results:
            if scenario in results[preset]:
                raise ValueError(f"duplicate benchmark result for {preset}/{scenario}: {path}")
            results[preset][scenario] = value
    missing = [f"{preset}/{scenario}" for preset in PRESETS for scenario in SCENARIOS if scenario not in results[preset]]
    if missing:
        raise ValueError("missing benchmark results: " + ", ".join(missing))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"schema_version": SCHEMA_VERSION, "artifact_type": "benchmark-baseline", "results": results}, indent=2) + "\n", encoding="utf-8")


def compatibility(baseline: Path, result: Path, preset: str, scenario: str) -> None:
    baseline_value = load(baseline)
    validate_baseline(baseline_value, str(baseline))
    result_value = load(result)
    validate_result(result_value, str(result))
    expected = require(baseline_value, f"results.{preset}.{scenario}", str(baseline))
    if result_value["preset"] != preset or result_value["scenario"] != scenario:
        raise ValueError(f"{result}: does not match requested {preset}/{scenario}")
    for path in ("preset", "scenario", "world_seed", "render_distance", "duration_s", "build.mode", "build.world", "build.headless", "build.resolution", "provenance.gpu_adapter", "provenance.gpu_driver", "provenance.runner", "provenance.zig_toolchain"):
        if require(expected, path, str(baseline)) != require(result_value, path, str(result)):
            raise ValueError(f"benchmark provenance differs for {path}")


def self_test() -> None:
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "artifact_type": "benchmark-result", "preset": "low", "scenario": "stationary", "world_seed": 12345, "render_distance": 6, "frames": 2, "duration_s": 1.0,
        "fps": {"avg": 60.0, "p1": 58.0}, "frame_ms": {"avg": 16.0, "p99": 18.0}, "gpu_ms": {"total": {"avg": 8.0}}, "draw_calls_avg": 4.0, "vertices_avg": 12.0, "chunks_rendered_avg": 1.0, "gpu_memory_mb_max": 64.0,
        "build": {"mode": "ReleaseFast", "world": "normal", "headless": True, "resolution": [1920, 1080]},
        "provenance": {"gpu_adapter": "test-gpu", "gpu_driver": "test-driver", "runner": "self-test", "zig_toolchain": "zig-test"},
        "completion": {"scenario_completed": True, "sampled_duration_s": 1.0, "requested_duration_s": 1.0, "sampled_frame_count": 2, "warmup_ready": True, "warmup_timed_out": False},
    }
    validate_result(result, "self-test")
    result["fps"]["avg"] = float("nan")
    try:
        validate_result(result, "self-test")
    except ValueError:
        return
    raise AssertionError("non-finite metrics must be rejected")


def main() -> None:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    assemble_parser = subcommands.add_parser("assemble")
    assemble_parser.add_argument("--output", type=Path, required=True)
    assemble_parser.add_argument("--overwrite", action="store_true")
    assemble_parser.add_argument("inputs", nargs="+", type=Path)
    validate_parser = subcommands.add_parser("validate")
    validate_parser.add_argument("path", type=Path)
    result_parser = subcommands.add_parser("validate-result")
    result_parser.add_argument("path", type=Path)
    compatibility_parser = subcommands.add_parser("compatibility")
    compatibility_parser.add_argument("baseline", type=Path)
    compatibility_parser.add_argument("result", type=Path)
    compatibility_parser.add_argument("--preset", required=True)
    compatibility_parser.add_argument("--scenario", required=True)
    subcommands.add_parser("self-test")
    args = parser.parse_args()
    if args.command == "assemble":
        assemble(args.inputs, args.output, args.overwrite)
    elif args.command == "validate":
        validate_baseline(load(args.path), str(args.path))
    elif args.command == "validate-result":
        validate_result(load(args.path), str(args.path))
    elif args.command == "compatibility":
        compatibility(args.baseline, args.result, args.preset, args.scenario)
    else:
        self_test()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"benchmark baseline validation failed: {error}")
