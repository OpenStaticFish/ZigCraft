# Benchmarking

The benchmark harness records ordinary renderer performance in schema-v4 JSON.
It runs headless with a deterministic world seed and a bounded camera scenario.

Run a single diagnostic benchmark:

```bash
devenv shell zig build benchmark -Doptimize=ReleaseFast \
  -Dbenchmark-preset=low -Dbenchmark-scenario=traversal \
  -Dbenchmark-duration=60 -Dbenchmark-output=zig-out/benchmark-low.json
```

For a bounded matrix, use the wrapper. It applies an external timeout and
validates every emitted artifact:

```bash
scripts/run_benchmark.sh --duration 5 --presets low,medium,high \
  --scenarios stationary,traversal,rapid-turn,teleport-eviction \
  --benchmark-world overworld --output-dir benchmark-results
```

Results are written as `<output-dir>/<preset>/<scenario>.json`. The supported
scenarios are `stationary`, `traversal`, `rapid-turn`, and
`teleport-eviction`.

To assemble a matching benchmark baseline from a complete low/medium/high
matrix:

```bash
python3 scripts/benchmark_baseline.py assemble --overwrite \
  --output docs/benchmarks/baseline.json benchmark-results/*/*.json
```

`scripts/compare_benchmarks.sh` compares a result with the selected baseline
preset and scenario. It warns at a 5% regression and fails at 10% for p1 FPS,
average total GPU time, and average draw calls.

The harness enforces absolute preset limits for p1 FPS, worst frame time, draw
calls, vertices, and GPU resource memory before writing a successful result.
