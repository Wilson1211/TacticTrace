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

    def run_fixture(self, *, configure=False, quotas=None, backfill=True,
                    scenario="standard", redirect=True, extra_env=None,
                    existing=None, root_override=None):
        self.counter += 1
        case = self.base / str(self.counter)
        case.mkdir()
        original = case / "original"
        original.mkdir()
        # These legal path characters must be escaped in the sampling summary.
        root = case / 'output "quoted" \\ path'
        root.mkdir()
        requested = original / "proof.outdir"
        target = (root if redirect else original) / requested.name
        summary_path = Path(str(target) + ".sampling.json")
        if existing == "directory":
            target.mkdir()
            (target / "sentinel").write_text("keep directory")
        elif existing == "summary":
            summary_path.write_text("keep summary")
        args = [str(NATIVE), scenario, str(requested), str(original / "oracle.outdir")]
        if configure:
            args.extend(["" if quotas is None else ",".join(map(str, quotas)),
                         str(backfill).lower(),
                         str(root) if root_override is None and redirect
                         else (root_override or "")])
        env = dict(os.environ)
        env.update(extra_env or {})
        result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=120)
        (case / "stdout.log").write_text(result.stdout)
        (case / "stderr.log").write_text(result.stderr)
        return result, target, summary_path, requested

    def successful(self, **kwargs):
        result, target, summary_path, requested = self.run_fixture(**kwargs)
        self.assertEqual(result.returncode, 0, result.stdout[-2000:] + result.stderr)
        traces = {path.name: path.read_bytes() for path in target.glob("*.json")}
        for content in traces.values():
            self.assertIsInstance(json.loads(content), list)
        summary = json.loads(summary_path.read_text()) if summary_path.exists() else None
        return traces, summary, target, requested

    @staticmethod
    def records(traces, name):
        return json.loads(traces[f"{name}.json"])

    @classmethod
    def ids(cls, traces, name):
        return {record["user_line_number"]["line"] for record in cls.records(traces, name)}

    def test_defaults_need_no_configuration_call(self):
        # Without configure_sampling: five buckets of four, borrowing on.
        default, summary, target, requested = self.successful(redirect=False)
        self.assertIsNone(summary)
        self.assertEqual(target, requested)
        expected = ({1000 + 3*j for j in range(7)} |
                    {1001 + 3*j for j in range(7)} |
                    {1002 + 3*j for j in range(6)})
        self.assertEqual(self.ids(default, "balanced"), expected)
        # "rare" has one 0-subgoal and one 3-subgoal record, so its 1-subgoal
        # bucket borrows the 14 places the other buckets cannot fill.
        self.assertEqual(self.ids(default, "rare"),
                         {2200, 2201} | set(range(2000, 2018)))
        self.assertEqual(len(self.ids(default, "short")), 20)
        explicit, summary, _, _ = self.successful(configure=True, redirect=False)
        self.assertIsNone(summary)
        self.assertEqual(default, explicit)
        redirected, summary, _, _ = self.successful(configure=True)
        self.assertEqual(default, redirected)
        self.assertIs(summary["backfill"], True)
        self.assertEqual(summary["bucket_capacities"], [4, 4, 4, 4, 4])
        self.assertEqual(summary["bucket_names"], ["0", "1", "2", "3", "4+"])

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

    def test_shortest_first_seen_wins_and_summary(self):
        # Borrowing off, so each bucket keeps exactly its own quota.
        traces, summary, target, requested = self.successful(
            configure=True, backfill=False)
        self.assertEqual(set(summary), {
            "backfill", "total_capacity", "bucket_names", "bucket_capacities",
            "original_output_path", "actual_output_path", "tactics"})
        self.assertIs(summary["backfill"], False)
        self.assertEqual(summary["bucket_capacities"], [4, 4, 4, 4, 4])
        self.assertEqual(summary["bucket_names"], ["0", "1", "2", "3", "4+"])
        self.assertEqual(summary["total_capacity"], 20)
        self.assertEqual(summary["actual_output_path"], str(target))
        self.assertEqual(summary["original_output_path"], str(requested))
        self.assertFalse(requested.exists())
        # "balanced" spreads over the first three buckets, which each keep the
        # four earliest of their own records; the last two buckets stay empty.
        expected_balanced = ({1000 + 3*j for j in range(4)} |
                             {1001 + 3*j for j in range(4)} |
                             {1002 + 3*j for j in range(4)})
        self.assertEqual(self.ids(traces, "balanced"), expected_balanced)
        # "long" prints shorter goals the later it is collected, so each bucket
        # keeps its four last records rather than its four first.
        expected_long = ({3000 + 3*j for j in range(16, 20)} |
                         {3001 + 3*j for j in range(16, 20)} |
                         {3002 + 3*j for j in range(16, 20)})
        self.assertEqual(self.ids(traces, "long"), expected_long)
        # "ties" prints every goal to the same length, so each bucket keeps its
        # four earliest records, and they are written newest first.
        self.assertEqual(
            [r["user_line_number"]["line"] for r in self.records(traces, "ties")],
            list(range(4011, 3999, -1)))
        self.assertEqual([b["eligible_seen"] for b in
                          summary["tactics"]["balanced"]["buckets"]],
                         [60, 60, 60, 0, 0])
        self.assertEqual([b["retained"] for b in
                          summary["tactics"]["balanced"]["buckets"]],
                         [4, 4, 4, 0, 0])
        self.assertEqual(summary["tactics"]["filtered"]["filtered"], 4)
        # "rare": one 0-subgoal record, four of its hundred 1-subgoal records,
        # and one 3-subgoal record.
        self.assertEqual(self.ids(traces, "rare"),
                         {2200, 2201} | set(range(2000, 2004)))

    def test_one_and_five_bucket_quotas(self):
        for quotas, names, expected in (
            ((3,), ["0+"], [3]),
            ((1, 2, 3, 4, 5), ["0", "1", "2", "3", "4+"], [1, 2, 3, 4, 5]),
            ((2, 2, 2, 2, 2), ["0", "1", "2", "3", "4+"], [2, 2, 2, 2, 2]),
        ):
            with self.subTest(quotas=quotas):
                traces, summary, _, _ = self.successful(
                    configure=True, quotas=quotas, backfill=False)
                self.assertEqual(summary["bucket_names"], names)
                self.assertEqual(summary["bucket_capacities"], list(quotas))
                self.assertEqual(summary["total_capacity"], sum(quotas))
                counts = [b["retained"] for b in
                          summary["tactics"]["five"]["buckets"]]
                self.assertEqual(counts, expected)
                self.assertEqual(len(self.records(traces, "five")), sum(expected))
        # A zero quota disables its bucket, so nothing from it is kept and it
        # takes no part in borrowing.
        traces, summary, _, _ = self.successful(
            configure=True, quotas=(0, 4, 0, 0, 0), backfill=True)
        self.assertEqual(summary["tactics"]["five"]["effective_bucket_capacities"],
                         [0, 4, 0, 0, 0])
        self.assertEqual({r["num_subgoals"] for r in self.records(traces, "five")}, {1})

    def test_borrowing_reclaims_unused_quotas_without_duplication(self):
        traces, summary, _, _ = self.successful(configure=True, backfill=True)
        self.assertEqual(summary["tactics"]["rare"]["effective_bucket_capacities"],
                         [1, 18, 0, 1, 0])
        self.assertEqual([b["retained"] for b in summary["tactics"]["rare"]["buckets"]],
                         [1, 18, 0, 1, 0])
        self.assertEqual(self.ids(traces, "rare"),
                         {2200, 2201} | set(range(2000, 2018)))
        self.assertEqual(len(self.ids(traces, "rare")), 20)
        # "balanced" fills only three buckets, which share the other two quotas
        # a place at a time, so one of them ends up one place short.
        self.assertEqual(summary["tactics"]["balanced"]["effective_bucket_capacities"],
                         [7, 7, 6, 0, 0])
        traces, summary, _, _ = self.successful(
            configure=True, quotas=(3, 3, 3, 3, 3), backfill=True)
        self.assertEqual(summary["tactics"]["rare"]["effective_bucket_capacities"],
                         [1, 13, 0, 1, 0])
        self.assertEqual(len(self.ids(traces, "rare")), 15)

    def test_borrowing_gives_a_one_bucket_tactic_the_whole_capacity(self):
        # Every "only_one" record lands in the same bucket, so with borrowing
        # it keeps the whole capacity, exactly as a single bucket would.
        one, _, _, _ = self.successful(
            configure=True, quotas=(20,), backfill=True)
        five, _, _, _ = self.successful(
            configure=True, quotas=(4, 4, 4, 4, 4), backfill=True)
        single = [r["user_line_number"]["line"]
                  for r in self.records(one, "only_one")]
        spread = [r["user_line_number"]["line"]
                  for r in self.records(five, "only_one")]
        # The twenty earliest records are kept and written newest first.
        self.assertEqual(single, list(range(8019, 7999, -1)))
        self.assertEqual(single, spread)

    def test_repeated_runs_select_the_same_records(self):
        # What a tactic keeps depends only on its own records, so collecting
        # another tactic alongside it must not change the selection.
        for backfill in (False, True):
            with self.subTest(backfill=backfill):
                kwargs = dict(configure=True, backfill=backfill)
                first, _, _, _ = self.successful(**kwargs)
                repeat, _, _, _ = self.successful(**kwargs)
                self.assertEqual(first, repeat)
                noisy, _, _, _ = self.successful(**kwargs, scenario="noise")
                for name in first:
                    self.assertEqual(first[name], noisy[name], name)
                default, _, _, _ = self.successful(redirect=False)
                self.assertEqual(first["conversion.json"], default["conversion.json"])

    def test_config_sealed_after_collection(self):
        self.successful(configure=True, scenario="late-config")

    def test_reject_invalid_configuration(self):
        cases = [
            {"quotas": (1, 2)},
            {"quotas": (1, 2, 3)},
            {"quotas": (1, 2, 3, 4)},
            {"quotas": (-1, 2, 2, 2, 2)},
            {"quotas": (0, 0, 0, 0, 0)},
            {"root_override": "relative"},
        ]
        for case in cases:
            with self.subTest(case=case):
                result, target, summary_path, _ = self.run_fixture(
                    scenario="dump-only", configure=True, **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(target.exists())
                self.assertFalse(summary_path.exists())

    def test_output_collisions_never_overwrite(self):
        for redirect in (False, True):
            for existing in ("directory", "summary"):
                if not redirect and existing == "summary":
                    continue  # A sampling summary is only written for an explicit output root.
                with self.subTest(redirect=redirect, existing=existing):
                    result, target, summary_path, _ = self.run_fixture(
                        configure=True, redirect=redirect,
                        scenario="dump-only", existing=existing)
                    self.assertNotEqual(result.returncode, 0)
                    if existing == "directory":
                        self.assertEqual((target / "sentinel").read_text(), "keep directory")
                        self.assertEqual(list(target.iterdir()), [target / "sentinel"])
                    else:
                        self.assertEqual(summary_path.read_text(), "keep summary")
                        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
