"""Compile sampling_runtime.ml against a small stub of the collector API."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ADAPTER = Path(__file__).resolve().parents[1] / "sampling_runtime.ml"
STUB = '''let unset_jrh_lexer = ();;
let set_jrh_lexer = ();;
module ExportTrace = struct
  type sampling_config = {
    output_dir: string option; bucket_quotas: int array; backfill: bool;
  }
  let default_sampling_config = {
    output_dir=None; bucket_quotas=[|4;4;4;4;4|]; backfill=true;
  }
  let selected = ref default_sampling_config
  let configure_sampling config =
    if not (List.mem (Array.length config.bucket_quotas) [1;5]) then
      invalid_arg "invalid quota count";
    selected := config
end;;
'''
FOOTER = '''let () =
  let config = !ExportTrace.selected in
  Printf.printf "%s\\n%b\\n"
    (match config.output_dir with None -> "<embedded>" | Some path -> path)
    config.backfill;
  print_endline (String.concat "," (Array.to_list (Array.map string_of_int config.bucket_quotas)));;
'''


class SamplingRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("ocamlc")
        if compiler is None:
            raise AssertionError(
                "ocamlc was not found on PATH. These tests compile sampling_runtime.ml, "
                "so install OCaml or put the HOL Light opam switch's bin directory on PATH.")
        cls.temp = tempfile.TemporaryDirectory(prefix="sampling-runtime-test-")
        directory = Path(cls.temp.name)
        source = directory / "runtime.ml"
        source.write_text(STUB + ADAPTER.read_text() + FOOTER)
        cls.runtime = directory / "runtime.byte"
        result = subprocess.run([compiler, "-o", str(cls.runtime), str(source)],
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.temp_run = tempfile.TemporaryDirectory(prefix="sampling-runtime-case-")
        self.addCleanup(self.temp_run.cleanup)
        self.config = Path(self.temp_run.name) / 'config with "quotes".txt'

    def invoke(self, lines, *extra):
        self.config.write_text("\n".join(lines) + "\n")
        result = subprocess.run([str(self.runtime), "an argument", "--tactictrace-config",
                                 str(self.config), *extra], text=True, capture_output=True)
        return result, Path(str(self.config) + ".accepted")

    def test_settings_are_passed_through_and_accepted(self):
        output_dir = '/tmp/a "quoted" path; no source execution'
        result, accepted = self.invoke(
            ["tactictrace-sampling-config", output_dir, "2,2,2,2,2", "0"],
            "last argument")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3],
                         [output_dir, "false", "2,2,2,2,2"])
        self.assertEqual(accepted.read_text(), "tactictrace-sampling-config\n")

    def test_output_directory_is_passed_on_as_written(self):
        # The collector's configure_sampling judges the path, not this file
        # reader, so it must reach configure_sampling unchanged.
        for output_dir in ("relative/traces", "/no/such/parent/traces",
                           "/tmp/.", "/tmp/..", "/tmp/traces/"):
            with self.subTest(output_dir=output_dir):
                Path(str(self.config) + ".accepted").unlink(missing_ok=True)
                result, accepted = self.invoke(
                    ["tactictrace-sampling-config", output_dir, "", "1"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[0], output_dir)
                self.assertTrue(accepted.is_file())

    def test_empty_settings_mean_the_collector_defaults(self):
        result, accepted = self.invoke(
            ["tactictrace-sampling-config", "", "", "1"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3],
                         ["<embedded>", "true", "4,4,4,4,4"])
        self.assertTrue(accepted.is_file())
        # Without the argument at all, the compiled-in settings are used.
        plain = subprocess.run([str(self.runtime)], capture_output=True, text=True)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertEqual(plain.stdout.splitlines()[:3], result.stdout.splitlines()[:3])

    def test_malformed_settings_are_rejected_before_the_proof(self):
        cases = [
            (0, "something-else"), (0, ""),
            (2, "01"), (2, "-1"), (2, "1; print_endline x"),
            (2, "1,,2,3,4"), (2, "1,2"), (2, "1,2,3"), (2, "1,2,3,4"),
            (3, "true"), (3, "bad"), (3, ""),
            (1, "bad\rdir"), (1, "bad\x00dir"),
        ]
        for index, value in cases:
            with self.subTest(index=index, value=value):
                lines = ["tactictrace-sampling-config", "", "", "1"]
                lines[index] = value
                result, accepted = self.invoke(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(accepted.exists())

    def test_wrong_line_count_is_rejected(self):
        for lines in (["tactictrace-sampling-config", "", "", "1", "extra"],
                      ["tactictrace-sampling-config", "", ""],
                      ["tactictrace-sampling-config"]):
            with self.subTest(lines=lines):
                result, accepted = self.invoke(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(accepted.exists())

    def test_duplicate_settings_argument_is_rejected(self):
        result, accepted = self.invoke(["tactictrace-sampling-config", "", "", "1"],
                                       "--tactictrace-config", "another")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", result.stderr)
        self.assertFalse(accepted.exists())


if __name__ == "__main__":
    unittest.main()
