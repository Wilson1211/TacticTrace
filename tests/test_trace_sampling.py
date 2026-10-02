"""Run one compiled exporter under each runtime configuration."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


NATIVE_PATH = os.environ.get("TRACE_SAMPLING_TEST_NATIVE")
NATIVE = Path(NATIVE_PATH).resolve() if NATIVE_PATH else None
SAMPLING_ENV = ("TRACE_SAMPLING_POLICY", "TRACE_SAMPLING_SEED", "TRACE_SAMPLING_OUTPUT_ROOT")


class TraceSamplingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if NATIVE is None or not NATIVE.is_file():
            raise RuntimeError("Set TRACE_SAMPLING_TEST_NATIVE to a freshly built fixture, "
                               "or run make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light")

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix=self._testMethodName + "-",
                         dir=os.environ.get("TRACE_SAMPLING_TEST_OUTPUT_ROOT")))
        print(f"Preserved test outputs: {self.base}", flush=True)
        self.counter = 0

    def run_fixture(self, policy=None, seed=None, scenario="standard", redirect=True,
                    extra_env=None, existing=None):
        self.counter += 1
        case = self.base / str(self.counter)
        case.mkdir()
        original = case / "original"
        original.mkdir()
        # These legal path characters must be escaped in the metadata JSON.
        root = case / 'output "quoted" \\ path'
        root.mkdir()
        requested = original / "proof.outdir"
        target = (root if redirect else original) / requested.name
        sidecar = Path(str(target) + ".sampling.json")
        if existing == "directory":
            target.mkdir()
            (target / "sentinel").write_text("keep directory")
        elif existing == "sidecar":
            sidecar.write_text("keep sidecar")
        env = {key: value for key, value in os.environ.items() if key not in SAMPLING_ENV}
        if policy is not None:
            env["TRACE_SAMPLING_POLICY"] = policy
        if seed is not None:
            env["TRACE_SAMPLING_SEED"] = str(seed)
        if redirect:
            env["TRACE_SAMPLING_OUTPUT_ROOT"] = str(root)
        env.update(extra_env or {})
        result = subprocess.run(
            [str(NATIVE), scenario, str(requested), str(original / "oracle.outdir")],
            env=env, text=True, capture_output=True, timeout=120,
        )
        (case / "stdout.log").write_text(result.stdout)
        (case / "stderr.log").write_text(result.stderr)
        return result, target, sidecar, requested

    def successful(self, **kwargs):
        result, target, sidecar, requested = self.run_fixture(**kwargs)
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr)
        traces = {path.name: path.read_bytes() for path in target.glob("*.json")}
        for content in traces.values():
            self.assertIsInstance(json.loads(content), list)
        manifest = json.loads(sidecar.read_text()) if sidecar.exists() else None
        return traces, manifest, target, requested

    def test_legacy_default_and_explicit_match_old_policy(self):
        default, default_manifest, target, _ = self.successful(scenario="legacy", redirect=False)
        self.assertIsNone(default_manifest)
        oracle = target.parent / "oracle.outdir"
        self.assertEqual(default, {p.name: p.read_bytes() for p in oracle.glob("*.json")})
        explicit, manifest, target, requested = self.successful(policy="legacy", scenario="legacy")
        self.assertEqual(default, explicit)
        self.assertEqual(explicit, {p.name: p.read_bytes() for p in (target.parent / "oracle.outdir").glob("*.json")})
        self.assertEqual(manifest["policy"], "legacy")
        self.assertIsNone(manifest["bucket_capacities"])
        self.assertEqual(manifest["original_output_path"], str(requested))
        self.assertFalse(requested.exists())

    def test_fixed_buckets_metadata_and_late_candidates(self):
        late = set()
        samples = set()
        for seed in (0, 1, 2, 17):
            traces, manifest, target, requested = self.successful(policy="stratified-reservoir", seed=seed)
            self.assertEqual(manifest["policy_version"], 1)
            self.assertEqual(manifest["policy"], "stratified-reservoir")
            self.assertEqual(manifest["seed"], seed)
            capacity = manifest["total_capacity"]
            expected = [capacity // 3 + (i < capacity % 3) for i in range(3)]
            self.assertEqual(manifest["bucket_names"], ["0", "1", "2+"])
            self.assertEqual(manifest["bucket_capacities"], expected)
            self.assertEqual(sum(expected), capacity)
            self.assertEqual(manifest["actual_output_path"], str(target))
            self.assertEqual(manifest["original_output_path"], str(requested))
            self.assertFalse(requested.exists())
            records = json.loads(traces["balanced.json"])
            samples.add(tuple(r["user_line_number"]["line"] for r in records))
            self.assertEqual(len(records), capacity)
            counts = [sum(min(r["num_subgoals"], 2) == i for r in records) for i in range(3)]
            self.assertEqual(counts, expected)
            buckets = manifest["tactics"]["balanced"]["buckets"]
            self.assertEqual([b["eligible_seen"] for b in buckets], [60, 60, 60])
            self.assertEqual([b["retained"] for b in buckets], expected)
            self.assertEqual(manifest["tactics"]["filtered"]["filtered"], 4)
            self.assertEqual([b["eligible_seen"] for b in manifest["tactics"]["filtered"]["buckets"]], [0, 0, 0])
            rare = json.loads(traces["rare.json"])
            rare_ids = {r["user_line_number"]["line"] for r in rare}
            self.assertTrue({2200, 2201}.issubset(rare_ids))
            self.assertEqual(len(rare), expected[1] + 2)
            late.update(r["user_line_number"]["line"] for r in records if r["user_line_number"]["line"] >= 1150)
        self.assertTrue(late, "Later eligible candidates must have a chance to survive")
        self.assertGreater(len(samples), 1, "Changing the seed must affect sampling")

    def test_determinism_private_rng_and_conversion_compatibility(self):
        first, _, _, _ = self.successful(policy="stratified-reservoir", seed=12345)
        repeat, _, _, _ = self.successful(policy="stratified-reservoir", seed=12345)
        self.assertEqual(first, repeat)
        noisy, _, _, _ = self.successful(policy="stratified-reservoir", seed=12345, scenario="noise")
        for name in first:
            self.assertEqual(first[name], noisy[name], name)
        legacy, _, _, _ = self.successful(policy="legacy")
        self.assertEqual(first["conversion.json"], legacy["conversion.json"])

    def test_policy_v1_seed_zero_retained_ids(self):
        # Lock the v1 stream contract for this ordered fixture and the default
        # compiled capacity. Repeatability alone would miss accidental RNG drift.
        traces, manifest, _, _ = self.successful(policy="stratified-reservoir", seed=0)
        self.assertEqual(manifest["policy_version"], 1)
        self.assertEqual(manifest["total_capacity"], 20)
        retained = sorted(record["user_line_number"]["line"]
                          for record in json.loads(traces["balanced.json"]))
        self.assertEqual(retained, [
            1003, 1006, 1009, 1011, 1020, 1029, 1033, 1040, 1046, 1049,
            1065, 1108, 1112, 1124, 1151, 1152, 1156, 1162, 1170, 1172,
        ])

    def test_reject_invalid_configuration(self):
        cases = [
            {"policy": "unknown"}, {"policy": ""},
            {"seed": "-1"}, {"seed": "2147483648"},
            {"seed": "1.5"}, {"seed": "abc"}, {"seed": ""},
            {"seed": " 1"}, {"seed": "+1"},
            {"policy": "stratified-reservoir", "redirect": False},
        ]
        for case in cases:
            with self.subTest(case=case):
                result, target, sidecar, _ = self.run_fixture(scenario="dump-only", **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(target.exists())
                self.assertFalse(sidecar.exists())
        self.successful(policy="stratified-reservoir", seed=2147483647, scenario="dump-only")

    def test_output_collisions_never_overwrite(self):
        for policy in ("legacy", "stratified-reservoir"):
            for existing in ("directory", "sidecar"):
                with self.subTest(policy=policy, existing=existing):
                    result, target, sidecar, _ = self.run_fixture(
                        policy=policy, scenario="dump-only", existing=existing)
                    self.assertNotEqual(result.returncode, 0)
                    if existing == "directory":
                        self.assertEqual((target / "sentinel").read_text(), "keep directory")
                        self.assertEqual(list(target.iterdir()), [target / "sentinel"])
                    else:
                        self.assertEqual(sidecar.read_text(), "keep sidecar")
                        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
