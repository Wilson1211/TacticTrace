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
            "--trace-success-quotas", "2,2,2", "--trace-success-backfill",
            "--trace-output-root", str(root), "--dry-run",
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Success quotas: 2,2,2", result.stdout)
        self.assertIn("Success backfill: 1", result.stdout)
        self.assertIn(f"Output root: {root}", result.stdout)
        self.assertFalse(self.root.exists())

    def test_default_is_deterministic_stratified(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fake_collector())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.metadata()
        self.assertEqual(data["config"][0], "tactictrace-config-v3")
        self.assertEqual(data["config"][2:], ["", "0"])
        self.assertEqual(data["bucket_capacities"], [7, 7, 6])
        self.assertEqual(data["argv"], ["an argument with spaces", "$(not-a-shell-command)"])
        self.assertEqual((self.root / ".tactictrace-config.accepted").read_text(),
                         "tactictrace-config-v3:explicit-noexec-probe\n")

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
            "--trace-success-quotas", "2,2,2",
            "--trace-success-backfill", "--trace-output-root", str(self.root),
        ], self.fixture("collect", "sparse"))
        self.assertEqual(result.returncode, 0, result.stderr)
        stats = self.metadata()["tactics"]["sample"]
        self.assertEqual(stats["effective_bucket_capacities"], [0, 3, 3])

    def test_invalid_options_do_not_create_output(self):
        cases = [
            ["--trace-success-quotas", "1,,2"],
            ["--trace-success-quotas", "0,0,0"],
            ["--trace-success-quotas", "1,2"],
            ["--trace-success-quotas", "2147483648"],
            ["--trace-success-quotas"],
            ["--unknown-option"],
            # Withdrawn random-mode options are now unknown options.
            ["--trace-sampling", "stratified-reservoir"],
            ["--selection-mode", "deterministic"],
            ["--selection-mode", "random"],
            ["--trace-sampling-seed", "42"],
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
        # A version-2 adapter does not satisfy the version-3 protocol either.
        for name, capability in (("unmarked", ""),
                                 ("v2", "tactictrace-config-v2:explicit-noexec-probe")):
            with self.subTest(name=name):
                native = Path(self.temp.name) / f"{name}.native"
                marker = Path(self.temp.name) / f"executed-{name}"
                native.write_text(f"#!/bin/sh\n# {capability}\ntouch '{marker}'\n")
                native.chmod(0o755)
                result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                          [str(native)])
                self.assertEqual(result.returncode, 2)
                self.assertIn("unsupported native", result.stderr)
                self.assertFalse(marker.exists())
                self.assertFalse(self.root.exists())

    def test_marked_native_passes_the_capability_gate(self):
        native = Path(self.temp.name) / "rebuilt.native"
        native.write_text("#!/bin/sh\n"
                          "# tactictrace-config-v3:explicit-noexec-probe\nexit 0\n")
        native.chmod(0o755)
        result = self.run_wrapper(["--trace-output-root", str(self.root)], [str(native)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not acknowledge", result.stderr)
        self.assertTrue(self.root.is_dir())

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
        for args in ([], ["--trace-success-backfill"], ["--"]):
            result = subprocess.run(["bash", str(RUNNER), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_incomplete_metadata_is_not_a_successful_run(self):
        result = self.run_wrapper(["--trace-output-root", str(self.root)],
                                  self.fixture("incomplete"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion check failed", result.stderr)

    def test_metadata_must_match_settings_and_output(self):
        cases = {
            "wrong-version": {"policy_version": 2},
            "wrong-backfill": {"backfill": True},
            "wrong-quotas": {"bucket_capacities": [1, 1, 1]},
            "missing-output": {"actual_output_path": "missing"},
            "wrong-sidecar-name": {"actual_output_path": "another"},
            # A version-3 sidecar must not carry the withdrawn settings.
            "withdrawn-policy": {"policy": "stratified-reservoir"},
            "withdrawn-seed": {"seed": 0},
            "withdrawn-mode": {"selection_mode": "deterministic"},
        }
        for name, changes in cases.items():
            with self.subTest(name=name):
                root = Path(self.temp.name) / name
                command = self.fixture("mismatch", json.dumps(changes))
                result = self.run_wrapper(["--trace-output-root", str(root)], command)
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
