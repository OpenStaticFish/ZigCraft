#!/usr/bin/env python3
"""CPU-only wire-format and real shell harness tests; only devenv is mocked."""

import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

from canonical_saved_blocks import compare, manifest


ROOT = Path(__file__).resolve().parents[1]


def write_regions(directory, chunks, light=0):
    directory.mkdir(parents=True, exist_ok=True)
    regions = {}
    for (cx, cz), blocks in chunks.items():
        region = regions.setdefault((cx // 32, cz // 32), bytearray(4096))
        payload = blocks + bytes([light]) * 131072 + bytes(256 + 512)
        raw = struct.pack("<IBBIii", 0x5A434B00, 3, 15, zlib.crc32(payload), cx, cz) + payload
        compressed = zlib.compress(raw)
        encoded = struct.pack(">I", len(compressed) + 1) + b"\x02" + compressed
        count = (len(encoded) + 4095) // 4096
        index = (cz % 32 * 32 + cx % 32) * 4
        struct.pack_into(">I", region, index, ((len(region) // 4096) << 8) | count)
        region.extend(encoded + bytes(count * 4096 - len(encoded)))
    for (rx, rz), data in regions.items():
        (directory / f"r.{rx}.{rz}.mca").write_bytes(data)


def mock_capture():
    options = dict(arg[2:].split("=", 1) for arg in sys.argv[1:] if arg.startswith("-D") and "=" in arg)
    scene, run = options["phase5-visual-scene"], options["phase5-visual-run-id"]
    screenshot = Path(options["screenshot-path"])
    label = screenshot.stem
    case = os.environ.get("CAPTURE_TEST_CASE", "")
    save = Path(os.environ["ZIGCRAFT_SAVE_DIR"])
    summaries = save / "summaries/v1/r.0.0"
    if label == "repair":
        if list((save / "summaries").rglob("*.zsum")):
            raise RuntimeError("repair did not start with all summaries absent")
        print("MOCK_RECONSTRUCTION: summaries_absent=1")
    blocks = {(0, 0): bytes([1]) * 65536, (1, 0): bytes(65536), (-1, -1): bytes([2]) * 65536}
    if label != "create":
        blocks[(10, 10)] = bytes(65536)
    if case == f"mutation-{label}":
        # Not one of the nine probes, nor even in the target region.
        blocks[(-1, -1)] = blocks[(-1, -1)][:-1] + b"\x03"
    if case == f"missing-{label}":
        del blocks[(1, 0)]
    write_regions(save / "regions", blocks, light={"create": 0, "intact": 1, "repair": 2}[label])
    summaries.mkdir(parents=True, exist_ok=True)
    for cx in (0, 1):
        if not (case == "no-repaired-summary" and label == "repair" and cx == 1):
            (summaries / f"c.{cx}.0.zsum").write_bytes(b"mock-summary")
    screenshot.write_bytes(b"mock-screenshot")
    reload = int(label != "create")
    resident = 16 if not reload else int(case == "resident-repair" and label == "repair")
    features = 2 if case == "partial-create" and label == "create" else 9
    current = "false" if case == "stale-create" and label == "create" else "true"
    if case == "wrong-run" and label == "intact":
        run += "-wrong"
    target = f"canonical_enabled=true grid_known_area=4096 grid_total_area=4096 grid_complete=true source_epoch=17 source_current={current} mesh_ready=true projected=true drawn=true saved_features={features}"
    print(f"LOD_CANONICAL_TARGET: run={run} scene={scene} {target}")
    player = "160.0,106.0,160.0" if reload else "8.0,110.0,-32.0"
    print(f"CANONICAL_SAVED_READINESS: run={run} scene={scene} scope=saved_source qualified=0 ready=1 stable_frames=180 required_frames=180 target=0,0 target_lod=1 target_source_resident={resident} required_nonresident={reload} saved_features={features} canonical_enabled=true mesh_ready=true source_current={current} projected=true drawn=true chunks_rendered=20 player={player} warmup_visit=0 compact_qualification=0")
    if not (case == "no-ready" and label == "intact"):
        print(f"CANONICAL_SAVED_READY: run={run} scene={scene} scope=saved_source qualified=0 stable_frames=180 reload={reload} target_source_resident={resident} saved_features={features} compact_qualification=0")
    if not reload:
        print(f"CANONICAL_SAVE_FLUSH: run={run} scene={scene} saved=1 failures=0 committed_epoch=3 source_chunks=0,0;1,0")
    if case == "error-log" and label == "intact":
        print("[ERROR] injected runtime failure")
    if case == "fail-intact" and label == "intact":
        sys.exit(23)  # Valid evidence must not hide pipeline failure through tee.


class SavedCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="canonical-saved-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_complete_blocks_allow_only_nonblock_changes_and_additions(self):
        chunks = {(0, 0): bytes(65536), (-1, -1): bytes([2]) * 65536}
        before_dir, after_dir = self.root / "before", self.root / "after"
        write_regions(before_dir, chunks)
        write_regions(after_dir, chunks | {(32, 32): bytes(65536)}, light=15)
        before, after = manifest(before_dir), manifest(after_dir)
        self.assertNotEqual((before_dir / "r.0.0.mca").read_bytes(), (after_dir / "r.0.0.mca").read_bytes())
        self.assertTrue(compare(before, after)["original_blocks_preserved"])
        self.assertEqual(compare(before, after)["added_chunks"], ["32,32"])
        chunks[(-1, -1)] = chunks[(-1, -1)][:-1] + b"\x03"
        write_regions(after_dir, chunks)
        self.assertEqual(compare(before, manifest(after_dir))["changed_chunks"], ["-1,-1"])
        del after["chunks"]["-1,-1"]
        self.assertEqual(compare(before, after)["missing_chunks"], ["-1,-1"])

    def test_wire_format_rejects_corrupt_truncated_and_mislocated_chunks(self):
        directory = self.root / "regions"
        write_regions(directory, {(0, 0): bytes(65536)})
        path = directory / "r.0.0.mca"
        original = path.read_bytes()
        bad_location = bytearray(original)
        bad_location[4:8] = bad_location[0:4]
        bad_location[0:4] = bytes(4)
        for bad in (original[:4000], original[:-1], bytes(bad_location), original[:4101] + b"bad" + original[4104:]):
            path.write_bytes(bad)
            with self.assertRaises((ValueError, zlib.error)):
                manifest(directory)
        # A valid zlib stream with a broken inner checksum must also fail.
        length = int.from_bytes(original[4096:4100], "big")
        raw = bytearray(zlib.decompress(original[4101:4100 + length]))
        raw[-1] ^= 1
        compressed = zlib.compress(raw)
        payload = struct.pack(">I", len(compressed) + 1) + b"\x02" + compressed
        path.write_bytes(original[:4096] + payload + bytes(4096 - len(payload)))
        with self.assertRaisesRegex(ValueError, "checksum"):
            manifest(directory)
        with self.assertRaises(ValueError):
            manifest(self.root / "missing")

    def test_wire_format_rejects_invalid_biomes_even_with_valid_crc(self):
        directory = self.root / "regions"
        write_regions(directory, {(0, 0): bytes(65536)})
        path = directory / "r.0.0.mca"
        original = path.read_bytes()
        length = int.from_bytes(original[4096:4100], "big")
        raw = bytearray(zlib.decompress(original[4101:4100 + length]))
        for biome in (44, 45, 255):
            raw[18 + 65536 + 131072] = biome
            struct.pack_into("<I", raw, 6, zlib.crc32(raw[18:]))
            compressed = zlib.compress(raw)
            payload = struct.pack(">I", len(compressed) + 1) + b"\x02" + compressed
            path.write_bytes(original[:4096] + payload + bytes(4096 - len(payload)))
            if biome == 44:
                self.assertEqual(len(manifest(directory)["chunks"]), 1)
            else:
                with self.assertRaisesRegex(ValueError, "invalid biome"):
                    manifest(directory)

    def run_harness(self, case="", mode="both"):
        root = self.root / (case or mode)
        root.mkdir()
        (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        (root / "modules").symlink_to(ROOT / "modules", target_is_directory=True)
        binary = root / "bin"
        binary.mkdir()
        mock = binary / "devenv"
        mock.write_text(f"#!{sys.executable}\nimport runpy, sys\nsys.dont_write_bytecode = True\nsys.path.insert(0, {str(ROOT / 'scripts')!r})\nrunpy.run_path({str(Path(__file__).resolve())!r}, run_name='__capture_mock__')\n")
        mock.chmod(0o755)
        env = os.environ | {"PATH": f"{binary}:{os.environ['PATH']}", "CAPTURE_TEST_CASE": case}
        result = subprocess.run(["bash", str(ROOT / "scripts/run_canonical_saved_capture.sh"), mode], cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        runs = list((root / "screenshots/canonical-saved").glob("run-*"))
        self.assertEqual(len(runs), 1, result.stdout)
        return result, runs[0]

    def test_both_reaches_reconstruction_and_preserves_full_evidence(self):
        result, run = self.run_harness()
        self.assertEqual(result.returncode, 0, result.stdout)
        for label in ("before", "after-intact", "after-repair"):
            self.assertTrue((run / f"regions-{label}/r.-1.-1.mca").is_file())
        comparison = json.loads((run / "blocks-after-repair-comparison.json").read_text())
        self.assertEqual(comparison["original_chunks"], 3)
        self.assertTrue(comparison["original_blocks_preserved"])
        self.assertIn("MOCK_RECONSTRUCTION: summaries_absent=1", (run / "repair.log").read_text())
        self.assertEqual((run / "regions-before-cache-loss.sha256").read_bytes(), (run / "regions-after-cache-loss.sha256").read_bytes())
        self.assertTrue((run / "summaries-before-cache-loss/v1/r.0.0/c.1.0.zsum").is_file())
        self.assertIn("summaries_repaired=1 target_source_resident=0", (run / "metadata.log").read_text())

    def test_individual_modes(self):
        for mode, absent in (("intact", "repair"), ("repair", "intact")):
            result, run = self.run_harness(mode=mode)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertFalse((run / f"{absent}.log").exists())

    def test_pipeline_and_readiness_failures_stop_without_losing_evidence(self):
        for case in ("fail-intact", "error-log", "no-ready", "wrong-run", "partial-create", "stale-create"):
            with self.subTest(case=case):
                result, run = self.run_harness(case)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                if case == "fail-intact":
                    self.assertEqual(result.returncode, 23)
                self.assertIn("CANONICAL_SAVED_FAILURE:", (run / "metadata.log").read_text())
                self.assertTrue((run / "create.log").is_file())
                self.assertTrue((run / "save/regions/r.0.0.mca").is_file())
                self.assertFalse((run / "repair.log").exists())

    def test_repair_requires_nonresident_sources_and_rebuilt_sidecars(self):
        for case in ("resident-repair", "no-repaired-summary"):
            with self.subTest(case=case):
                result, run = self.run_harness(case)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                metadata = (run / "metadata.log").read_text()
                self.assertIn("stage=repair", metadata)
                self.assertNotIn("summaries_repaired=1", metadata)

    def test_block_mutation_or_loss_fails_with_comparison_and_snapshots(self):
        for case in ("mutation-intact", "missing-intact", "mutation-repair"):
            with self.subTest(case=case):
                result, run = self.run_harness(case)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                label = case.split("-")[1]
                comparison = json.loads((run / f"blocks-after-{label}-comparison.json").read_text())
                self.assertFalse(comparison["original_blocks_preserved"])
                self.assertTrue((run / "regions-before/r.-1.-1.mca").is_file())
                self.assertTrue((run / f"regions-after-{label}/r.-1.-1.mca").is_file())
                if label == "intact":
                    self.assertFalse((run / "repair.log").exists())


if __name__ == "__capture_mock__":
    mock_capture()
elif __name__ == "__main__":
    unittest.main()
