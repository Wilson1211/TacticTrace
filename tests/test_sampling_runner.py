"""Check the sampling wrapper without running HOL Light or real proofs."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "run-with-sampling.sh"
FIXTURE = Path(__file__).resolve().with_name("sampling_runner_fixture.py")


class SamplingRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sampling-runner-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "new run"

    def run_wrapper(self, options=(), command=None, env=None, runner=RUNNER, cwd=None):
        if command is None:
            command = self.fixture("exit", "99")
        return subprocess.run(
            ["bash", str(runner), *options, "--", *command],
            text=True, capture_output=True, env=env, cwd=cwd,
        )

    @staticmethod
    def fixture(*args):
        return [sys.executable, str(FIXTURE), *args]

    def fake_collector(self):
        return self.fixture("collect", "an argument with spaces", "$(not-a-shell-command)")

    def metadata(self, root=None):
        return json.loads(((root or self.root) / "proof.sampling.json").read_text())

    def test_preview_has_no_side_effects(self):
        root = self.root / "parent" / "run"
        result = self.run_wrapper([
            "--trace-sampling", "stratified-reservoir", "--selection-mode", "random",
            "--trace-sampling-seed", "42", "--trace-output-root", str(root), "--dry-run",
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Selection mode: random", result.stdout)
        self.assertIn("Policy: stratified-reservoir", result.stdout)
        self.assertFalse(self.root.exists())

    def test_default_is_deterministic_stratified(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fake_collector())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.metadata()
        self.assertEqual(data["config"][:3], ["tactictrace-config-v2", "stratified-reservoir", "0"])
        self.assertEqual(data["config"][5:], ["0", "deterministic"])
        self.assertEqual(data["bucket_capacities"], [7, 7, 6])
        self.assertEqual(data["argv"], ["an argument with spaces", "$(not-a-shell-command)"])
        self.assertEqual((self.root / ".tactictrace-config.accepted").read_text(),
                         "tactictrace-config-v2:explicit-noexec-probe\n")

    def test_deterministic_stratified_defaults_and_random_seed(self):
        result = self.run_wrapper([
            "--trace-sampling", "stratified-reservoir",
            "--trace-output-root", str(self.root),
        ], self.fake_collector())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.metadata()["config"][2::4], ["0", "deterministic"])
        self.assertEqual(self.metadata()["bucket_capacities"], [7, 7, 6])
        second = Path(self.temp.name) / "random run"
        result = self.run_wrapper([
            "--selection-mode", "random",
            "--trace-sampling-seed", "00042", "--trace-output-root", str(second),
        ], self.fake_collector())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.metadata(second)["config"][2], "42")
        self.assertEqual(self.metadata(second)["selection_mode"], "random")

    def test_custom_quotas_and_backfill(self):
        for values in ("20", "2,2,2", "1,2,3,4,5"):
            with self.subTest(values=values):
                root = Path(self.temp.name) / values.replace(",", "-")
                result = self.run_wrapper([
                    "--trace-success-quotas", values,
                    "--trace-success-backfill", "--trace-output-root", str(root),
                ], self.fake_collector())
                self.assertEqual(result.returncode, 0, result.stderr)
                data = self.metadata(root)
                self.assertEqual(data["bucket_capacities"], [int(q) for q in values.split(",")])
                self.assertTrue(data["backfill"])

    def test_backfill_uses_empty_group_quota(self):
        result = self.run_wrapper([
            "--trace-sampling", "stratified-reservoir", "--trace-success-quotas", "2,2,2",
            "--trace-success-backfill", "--trace-output-root", str(self.root),
        ], self.fixture("collect", "sparse"))
        self.assertEqual(result.returncode, 0, result.stderr)
        stats = self.metadata()["tactics"]["sample"]
        self.assertEqual(stats["effective_bucket_capacities"], [0, 3, 3])

    def test_invalid_options_do_not_create_output(self):
        cases = [
            ["--trace-sampling", "unknown"],
            ["--trace-sampling", "legacy"],
            ["--selection-mode", "unknown"],
            ["--trace-sampling-seed", "3"],
            ["--trace-sampling", "stratified-reservoir", "--trace-sampling-seed", "0"],
            ["--trace-sampling", "stratified-reservoir", "--selection-mode", "random",
             "--trace-sampling-seed", "-1"],
            ["--trace-sampling", "stratified-reservoir", "--selection-mode", "random",
             "--trace-sampling-seed", "2147483648"],
            ["--trace-sampling", "stratified-reservoir", "--trace-success-quotas", "1,,2"],
            ["--trace-sampling", "stratified-reservoir", "--trace-success-quotas", "0,0,0"],
            ["--trace-sampling", "stratified-reservoir", "--trace-success-quotas", "1,2"],
            ["--trace-sampling", "stratified-reservoir", "--trace-success-quotas", "2147483648"],
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

    def test_old_native_is_rejected_without_execution(self):
        native = Path(self.temp.name) / "old.native"
        marker = Path(self.temp.name) / "executed"
        native.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
        native.chmod(0o755)
        result = self.run_wrapper(["--trace-output-root", str(self.root)], [str(native)])
        self.assertEqual(result.returncode, 2)
        self.assertIn("unsupported native", result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(self.root.exists())

    def test_reserved_argument_is_rejected_before_execution(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("exit", "0", "--tactictrace-config", "fake"))
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.root.exists())

    def test_failed_command_returns_its_status_and_keeps_output(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("fail"))
        self.assertEqual(result.returncode, 7)
        self.assertEqual((self.root / "partial.txt").read_text(), "partial output")
        self.assertTrue((self.root / ".tactictrace-config").is_file())

    def test_missing_metadata_is_not_success(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("exit", "0"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not acknowledge", result.stderr)
        self.assertTrue(self.root.is_dir())

    def test_old_script_with_fabricated_sidecar_is_not_success(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("old"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not acknowledge", result.stderr)
        self.assertTrue((self.root / "proof.sampling.json").is_file())

    def test_requires_command_separator_and_command(self):
        for args in ([], ["--trace-sampling"], ["--"]):
            result = subprocess.run(["bash", str(RUNNER), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_incomplete_metadata_is_not_a_successful_run(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("incomplete"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion check failed", result.stderr)

    def test_metadata_must_match_settings_and_output(self):
        cases = {
            "wrong-policy": {"policy": "legacy"},
            "wrong-seed": {"seed": 99},
            "wrong-version": {"policy_version": 1},
            "wrong-mode": {"selection_mode": "random"},
            "wrong-backfill": {"backfill": True},
            "wrong-quotas": {"bucket_capacities": [1, 1, 1]},
            "missing-output": {"actual_output_path": "missing"},
            "wrong-sidecar-name": {"actual_output_path": "another"},
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                root = Path(self.temp.name) / name
                command = self.fixture("mismatch", json.dumps(changes))
                result = self.run_wrapper([
                    "--trace-sampling", "stratified-reservoir", "--trace-output-root", str(root),
                ], command)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("completion check failed", result.stderr)

    def test_validator_is_found_beside_runner_from_another_working_directory(self):
        runner_dir = Path(self.temp.name) / "runner copy"
        runner_dir.mkdir()
        for name in ("run-with-sampling.sh", "check-sampling-output.py"):
            shutil.copyfile(RUNNER.with_name(name), runner_dir / name)
        cwd = Path(self.temp.name) / "working directory"
        cwd.mkdir()
        result = self.run_wrapper(
            ["--trace-output-root", str(self.root)], self.fake_collector(),
            runner=Path("..") / runner_dir.name / RUNNER.name, cwd=cwd,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "proof.sampling.json").is_file())

    def test_missing_validator_fails_before_creating_output(self):
        runner = Path(self.temp.name) / RUNNER.name
        shutil.copyfile(RUNNER, runner)
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fake_collector(), runner=runner)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("validator is missing", result.stderr)
        self.assertFalse(self.root.exists())


if __name__ == "__main__":
    unittest.main()
