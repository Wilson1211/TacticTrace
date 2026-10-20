"""Run one compiled exporter under explicit runtime sampling configurations."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


NATIVE_PATH = os.environ.get("TRACE_SAMPLING_TEST_NATIVE")
NATIVE = Path(NATIVE_PATH).resolve() if NATIVE_PATH else None


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

    def run_fixture(self, *, policy=None, selection_mode="deterministic",
                    quotas=None, backfill=False, seed=0, scenario="standard",
                    redirect=True, extra_env=None, existing=None, root_override=None):
        self.counter += 1
        case = self.base / str(self.counter)
        case.mkdir()
        original = case / "original"
        original.mkdir()
        # These legal path characters must be escaped in metadata JSON.
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
        args = [str(NATIVE), scenario, str(requested), str(original / "oracle.outdir")]
        if policy is not None:
            args.extend([policy, selection_mode, str(seed),
                         "" if quotas is None else ",".join(map(str, quotas)),
                         str(backfill).lower(),
                         str(root) if root_override is None and redirect
                         else (root_override or "")])
        env = dict(os.environ)
        env.update(extra_env or {})
        result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=120)
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

    @staticmethod
    def records(traces, name):
        return json.loads(traces[f"{name}.json"])

    @classmethod
    def ids(cls, traces, name):
        return {record["user_line_number"]["line"] for record in cls.records(traces, name)}

    def test_unconfigured_default_uses_stratified_deterministic_sampling(self):
        # No configure_sampling call, output root, or environment is required.
        ignored = {"TRACE_SAMPLING_POLICY": "invalid",
                   "TRACE_SAMPLING_SEED": "-1",
                   "TRACE_SAMPLING_OUTPUT_ROOT": "/missing"}
        default, manifest, target, requested = self.successful(
            redirect=False, extra_env=ignored)
        self.assertIsNone(manifest)
        self.assertEqual(target, requested)
        expected = ({1000 + 3*j for j in range(7)} |
                    {1001 + 3*j for j in range(7)} |
                    {1002 + 3*j for j in range(6)})
        self.assertEqual(self.ids(default, "balanced"), expected)
        self.assertEqual(self.ids(default, "rare"),
                         {2200, 2201} | set(range(2000, 2007)))
        self.assertEqual(len(self.ids(default, "short")), 7)
        explicit, manifest, _, _ = self.successful(
            policy="stratified-reservoir", redirect=False)
        self.assertIsNone(manifest)
        self.assertEqual(default, explicit)
        redirected, manifest, _, _ = self.successful(policy="stratified-reservoir")
        self.assertEqual(default, redirected)
        self.assertEqual(manifest["policy"], "stratified-reservoir")

    def test_record_json_schema_and_lazy_arguments(self):
        traces, _, _, _ = self.successful(redirect=False)
        fields = {"tactic", "definition_line_number", "user_line_number",
                  "arg_names", "arg_types", "arg_values", "arg_exprs",
                  "goal_before", "goals_after", "num_subgoals"}
        for record in self.records(traces, "balanced"):
            self.assertEqual(set(record), fields)
            line = record["user_line_number"]["line"]
            self.assertEqual(record["arg_names"], ["id"])
            self.assertEqual(record["arg_types"], ["int"])
            self.assertEqual(record["arg_values"], [str(line)])
            self.assertEqual(record["arg_exprs"], [str(line)])
            self.assertEqual(len(record["goals_after"]), record["num_subgoals"])
            for goal in record["goals_after"]:
                self.assertEqual(set(goal), {"goal", "added_assumptions",
                                             "removed_assumptions"})

    def test_deterministic_shortest_first_seen_and_metadata(self):
        traces, manifest, target, requested = self.successful(policy="stratified-reservoir")
        self.assertEqual(manifest["policy_version"], 2)
        self.assertEqual(manifest["selection_mode"], "deterministic")
        self.assertIs(manifest["backfill"], False)
        self.assertEqual(manifest["bucket_capacities"], [7, 7, 6])
        self.assertEqual(manifest["bucket_names"], ["0", "1", "2+"])
        self.assertEqual(manifest["total_capacity"], 20)
        self.assertEqual(manifest["actual_output_path"], str(target))
        self.assertEqual(manifest["original_output_path"], str(requested))
        self.assertFalse(requested.exists())
        expected_balanced = (
            {1000 + 3*j for j in range(7)} |
            {1001 + 3*j for j in range(7)} |
            {1002 + 3*j for j in range(6)})
        self.assertEqual(self.ids(traces, "balanced"), expected_balanced)
        expected_long = (
            {3000 + 3*j for j in range(13, 20)} |
            {3001 + 3*j for j in range(13, 20)} |
            {3002 + 3*j for j in range(14, 20)})
        self.assertEqual(self.ids(traces, "long"), expected_long)
        expected_ties = (
            {4000 + 3*j for j in range(7)} |
            {4001 + 3*j for j in range(7)} |
            {4002 + 3*j for j in range(6)})
        self.assertEqual(self.ids(traces, "ties"), expected_ties)
        self.assertEqual(
            [r["user_line_number"]["line"] for r in self.records(traces, "ties")],
            ([4000 + 3*j for j in range(7)] +
             [4001 + 3*j for j in range(7)] +
             [4002 + 3*j for j in range(6)]))
        self.assertEqual([b["eligible_seen"] for b in
                          manifest["tactics"]["balanced"]["buckets"]], [60, 60, 60])
        self.assertEqual([b["retained"] for b in
                          manifest["tactics"]["balanced"]["buckets"]], [7, 7, 6])
        self.assertEqual(manifest["tactics"]["filtered"]["filtered"], 4)
        self.assertEqual(len(self.ids(traces, "rare")), 9)

    def test_one_three_and_five_group_quotas(self):
        for mode in ("deterministic", "random"):
            for quotas, names, expected in (
                ((3,), ["0+"], [3]),
                ((2, 3, 4), ["0", "1", "2+"], [2, 3, 4]),
                ((1, 2, 3, 4, 5), ["0", "1", "2", "3", "4+"], [1, 2, 3, 4, 5]),
            ):
                with self.subTest(mode=mode, quotas=quotas):
                    traces, manifest, _, _ = self.successful(
                        policy="stratified-reservoir", selection_mode=mode, quotas=quotas)
                    self.assertEqual(manifest["bucket_names"], names)
                    self.assertEqual(manifest["bucket_capacities"], list(quotas))
                    self.assertEqual(manifest["total_capacity"], sum(quotas))
                    counts = [b["retained"] for b in
                              manifest["tactics"]["five"]["buckets"]]
                    self.assertEqual(counts, expected)
                    self.assertEqual(len(self.records(traces, "five")), sum(expected))
        traces, manifest, _, _ = self.successful(
            policy="stratified-reservoir", quotas=(0, 4, 0), backfill=True)
        self.assertEqual(manifest["tactics"]["five"]["effective_bucket_capacities"],
                         [0, 4, 0])
        self.assertEqual({r["num_subgoals"] for r in self.records(traces, "five")}, {1})

    def test_backfill_reclaims_unused_quotas_without_duplication(self):
        traces, manifest, _, _ = self.successful(
            policy="stratified-reservoir", backfill=True)
        self.assertEqual(manifest["tactics"]["rare"]["effective_bucket_capacities"],
                         [1, 18, 1])
        self.assertEqual([b["retained"] for b in manifest["tactics"]["rare"]["buckets"]],
                         [1, 18, 1])
        self.assertEqual(self.ids(traces, "rare"),
                         {2200, 2201} | set(range(2000, 2018)))
        self.assertEqual(len(self.ids(traces, "rare")), 20)
        self.assertEqual(manifest["tactics"]["balanced"]["effective_bucket_capacities"],
                         [7, 7, 6])
        traces, manifest, _, _ = self.successful(
            policy="stratified-reservoir", quotas=(3, 3, 3, 3, 3), backfill=True)
        self.assertEqual(manifest["tactics"]["rare"]["effective_bucket_capacities"],
                         [1, 13, 0, 1, 0])
        self.assertEqual(len(self.ids(traces, "rare")), 15)

    def test_random_backfill_counts_and_uniqueness(self):
        for quotas, expected in (((7, 7, 6), [1, 18, 1]),
                                 ((3, 3, 3, 3, 3), [1, 13, 0, 1, 0])):
            with self.subTest(quotas=quotas):
                traces, manifest, _, _ = self.successful(
                    policy="stratified-reservoir", selection_mode="random",
                    seed=17, quotas=quotas, backfill=True)
                stats = manifest["tactics"]["rare"]
                self.assertEqual(stats["effective_bucket_capacities"], expected)
                self.assertEqual([b["retained"] for b in stats["buckets"]], expected)
                self.assertEqual(len(self.records(traces, "rare")), sum(quotas))
                self.assertEqual(len(self.ids(traces, "rare")), sum(quotas))
                self.assertTrue({2200, 2201} <= self.ids(traces, "rare"))

    def test_one_goal_backfill_three_vs_five_selected_set(self):
        three, _, _, _ = self.successful(
            policy="stratified-reservoir", quotas=(7, 7, 6), backfill=True)
        five, _, _, _ = self.successful(
            policy="stratified-reservoir", quotas=(4, 4, 4, 4, 4), backfill=True)
        first = [r["user_line_number"]["line"]
                 for r in self.records(three, "only_one")]
        second = [r["user_line_number"]["line"]
                  for r in self.records(five, "only_one")]
        self.assertEqual(set(first), set(range(8000, 8020)))
        self.assertEqual(first, second)

    def test_explicit_random_preserves_reservoir_stream(self):
        late = set()
        samples = set()
        for seed in (0, 1, 2, 17):
            traces, manifest, _, _ = self.successful(
                policy="stratified-reservoir", selection_mode="random", seed=seed)
            self.assertEqual(manifest["policy_version"], 2)
            self.assertEqual(manifest["selection_mode"], "random")
            self.assertEqual([b["retained"] for b in
                              manifest["tactics"]["balanced"]["buckets"]], [7, 7, 6])
            records = self.records(traces, "balanced")
            samples.add(tuple(r["user_line_number"]["line"] for r in records))
            late.update(r["user_line_number"]["line"] for r in records
                        if r["user_line_number"]["line"] >= 1150)
            if seed == 0:
                self.assertEqual(sorted(self.ids(traces, "balanced")), [
                    1003, 1006, 1009, 1011, 1020, 1029, 1033, 1040, 1046, 1049,
                    1065, 1108, 1112, 1124, 1151, 1152, 1156, 1162, 1170, 1172,
                ])
        self.assertTrue(late)
        self.assertGreater(len(samples), 1)

    def test_repeatability_private_rng_backfill_and_conversion(self):
        for mode in ("deterministic", "random"):
            for backfill in (False, True):
                with self.subTest(mode=mode, backfill=backfill):
                    kwargs = dict(policy="stratified-reservoir", selection_mode=mode,
                                  seed=12345, backfill=backfill)
                    first, _, _, _ = self.successful(**kwargs)
                    repeat, _, _, _ = self.successful(**kwargs)
                    self.assertEqual(first, repeat)
                    noisy, _, _, _ = self.successful(**kwargs, scenario="noise")
                    for name in first:
                        self.assertEqual(first[name], noisy[name], name)
                    default, _, _, _ = self.successful(redirect=False)
                    self.assertEqual(first["conversion.json"], default["conversion.json"])

    def test_config_sealed_after_collection(self):
        self.successful(policy="stratified-reservoir", scenario="late-config")

    def test_reject_invalid_configuration(self):
        cases = [
            {"policy": "unknown"}, {"policy": ""}, {"policy": "legacy"},
            {"policy": "stratified-reservoir", "selection_mode": "unknown"},
            {"policy": "stratified-reservoir", "seed": -1},
            {"policy": "stratified-reservoir", "seed": 2147483648},
            {"policy": "stratified-reservoir", "quotas": (1, 2)},
            {"policy": "stratified-reservoir", "quotas": (-1, 2, 2)},
            {"policy": "stratified-reservoir", "quotas": (0, 0, 0)},
            {"policy": "stratified-reservoir", "quotas": (2147483647, 1, 0)},
            {"policy": "stratified-reservoir", "root_override": "relative"},
        ]
        for case in cases:
            with self.subTest(case=case):
                result, target, sidecar, _ = self.run_fixture(
                    scenario="dump-only", **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(target.exists())
                self.assertFalse(sidecar.exists())

    def test_output_collisions_never_overwrite(self):
        for redirect in (False, True):
            for existing in ("directory", "sidecar"):
                if not redirect and existing == "sidecar":
                    continue  # Sidecars are only emitted for an explicit output root.
                with self.subTest(redirect=redirect, existing=existing):
                    result, target, sidecar, _ = self.run_fixture(
                        policy="stratified-reservoir", redirect=redirect,
                        scenario="dump-only", existing=existing)
                    self.assertNotEqual(result.returncode, 0)
                    if existing == "directory":
                        self.assertEqual((target / "sentinel").read_text(), "keep directory")
                        self.assertEqual(list(target.iterdir()), [target / "sentinel"])
                    else:
                        self.assertEqual(sidecar.read_text(), "keep sidecar")
                        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
