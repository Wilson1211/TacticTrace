"""Check the sampling wrapper without running HOL Light or real proofs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "run-with-sampling.sh"


class SamplingRunnerTests(unittest.TestCase):
    def setUp(self):
        # All output belongs to this test, never to an existing campaign.
        self.temp = tempfile.TemporaryDirectory(prefix="sampling-runner-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "new run"

    def run_wrapper(self, options=(), command=None, env=None):
        if command is None:
            command = [sys.executable, "-c", "raise SystemExit(99)"]
        return subprocess.run(
            ["bash", str(RUNNER), *options, "--", *command],
            text=True, capture_output=True, env=env,
        )

    @staticmethod
    def fake_collector():
        # Only emulate the interface; collector behavior has separate HOL tests.
        return [sys.executable, "-c", """
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TRACE_SAMPLING_OUTPUT_ROOT'])
data = {key: os.environ[key] for key in (
    'TRACE_SAMPLING_POLICY', 'TRACE_SAMPLING_SEED', 'TRACE_SAMPLING_OUTPUT_ROOT')}
data['argv'] = sys.argv[1:]
target = root / 'proof'
target.mkdir()
data.update(policy_version=1, policy=data['TRACE_SAMPLING_POLICY'],
            seed=int(data['TRACE_SAMPLING_SEED']), actual_output_path=str(target))
(root / 'proof.sampling.json').write_text(json.dumps(data))
""", "an argument with spaces", "$(not-a-shell-command)"]

    def test_preview_has_no_side_effects(self):
        root = self.root / "parent" / "run"
        result = self.run_wrapper([
            "--trace-sampling", "stratified-reservoir", "--trace-sampling-seed", "42",
            "--trace-output-root", str(root), "--dry-run",
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Policy: stratified-reservoir", result.stdout)
        self.assertFalse(self.root.exists())

    def test_legacy_default_overrides_inherited_configuration(self):
        env = dict(os.environ, TRACE_SAMPLING_POLICY="stratified-reservoir",
                   TRACE_SAMPLING_SEED="99", TRACE_SAMPLING_OUTPUT_ROOT="/unused")
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fake_collector(), env)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.root / "proof.sampling.json").read_text())
        self.assertEqual(data["TRACE_SAMPLING_POLICY"], "legacy")
        self.assertEqual(data["TRACE_SAMPLING_SEED"], "0")
        self.assertEqual(data["argv"], ["an argument with spaces", "$(not-a-shell-command)"])

    def test_stratified_flags_and_leading_zero_seed(self):
        result = self.run_wrapper([
            "--trace-sampling", "stratified-reservoir", "--trace-sampling-seed", "00042",
            "--trace-output-root", str(self.root),
        ], self.fake_collector())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.root / "proof.sampling.json").read_text())
        self.assertEqual(data["TRACE_SAMPLING_POLICY"], "stratified-reservoir")
        self.assertEqual(data["TRACE_SAMPLING_SEED"], "42")

    def test_invalid_options_do_not_create_output(self):
        cases = [
            ["--trace-sampling", "unknown"],
            ["--trace-sampling-seed", "-1"],
            ["--trace-sampling-seed", "2147483648"],
            ["--trace-sampling-seed", "999999999999999999999"],
            ["--trace-sampling-seed", "0x10"],
            ["--trace-sampling-seed", "1.5"],
            ["--unknown-option"],
        ]
        for flags in cases:
            with self.subTest(flags=flags):
                result = self.run_wrapper(["--trace-output-root", str(self.root), *flags])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.root.exists())

    def test_requires_absolute_new_output_root(self):
        for flags in ([], ["--trace-output-root", "relative"],
                      ["--trace-output-root", str(self.root) + "\n"]):
            result = self.run_wrapper(flags)
            self.assertEqual(result.returncode, 2)
        self.root.mkdir()
        marker = self.root / "keep.txt"
        marker.write_text("original")
        result = self.run_wrapper(["--trace-output-root", str(self.root)])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(marker.read_text(), "original")

    def test_dangling_symlink_is_not_an_available_output_root(self):
        self.root.symlink_to(Path(self.temp.name) / "missing")
        result = self.run_wrapper(["--trace-output-root", str(self.root)])
        self.assertEqual(result.returncode, 2)
        self.assertTrue(self.root.is_symlink())

    def test_failed_command_returns_its_status_and_keeps_output(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  [sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(result.returncode, 7)
        self.assertTrue(self.root.is_dir())

    def test_missing_collector_metadata_is_not_a_successful_run(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  [sys.executable, "-c", "pass"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("no sampling metadata", result.stderr)
        self.assertTrue(self.root.is_dir())

    def test_requires_command_separator_and_command(self):
        for args in ([], ["--trace-sampling"], ["--"]):
            result = subprocess.run(["bash", str(RUNNER), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_incomplete_metadata_is_not_a_successful_run(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  [sys.executable, "-c", """
import os, pathlib
(pathlib.Path(os.environ['TRACE_SAMPLING_OUTPUT_ROOT']) / 'proof.sampling.json').touch()
"""])
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion check failed", result.stderr)
        self.assertTrue((self.root / "proof.sampling.json").exists())

    def test_metadata_must_match_settings_and_real_output_path(self):
        cases = {
            "wrong-policy": {"policy": "stratified-reservoir"},
            "wrong-seed": {"seed": 99},
            "wrong-version": {"policy_version": 2},
            "missing-output": {"actual_output_path": "missing"},
            "wrong-sidecar-name": {"actual_output_path": "another"},
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                root = Path(self.temp.name) / name
                command = [sys.executable, "-c", """
import json, os, pathlib, sys
root = pathlib.Path(os.environ['TRACE_SAMPLING_OUTPUT_ROOT'])
(root / 'proof').mkdir()
(root / 'another').mkdir()
data = dict(policy_version=1, policy='legacy', seed=0,
            actual_output_path=str(root / 'proof'))
changes = json.loads(sys.argv[1])
if 'actual_output_path' in changes:
    changes['actual_output_path'] = str(root / changes['actual_output_path'])
data.update(changes)
(root / 'proof.sampling.json').write_text(json.dumps(data))
""", json.dumps(changes)]
                result = self.run_wrapper(["--trace-output-root", str(root)], command)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("completion check failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
