"""Compile the real OCaml runtime adapter against a small collector API stub."""

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
    output_root: string option; bucket_quotas: int array; backfill: bool;
  }
  let default_sampling_config = {
    output_root=None; bucket_quotas=[|7;7;6|]; backfill=false;
  }
  let selected = ref default_sampling_config
  let configure_sampling config =
    if not (List.mem (Array.length config.bucket_quotas) [1;3;5]) then
      invalid_arg "invalid quota count";
    selected := config
end;;
'''
FOOTER = '''let () =
  let config = !ExportTrace.selected in
  Printf.printf "%s\\n%b\\n"
    (match config.output_root with None -> "<embedded>" | Some path -> path)
    config.backfill;
  print_endline (String.concat "," (Array.to_list (Array.map string_of_int config.bucket_quotas)));
  Array.iter print_endline sampling_runtime_arguments;;
'''


class SamplingRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("ocamlc")
        if compiler is None:
            raise unittest.SkipTest("OCaml compiler is not installed")
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

    def test_explicit_config_passes_data_and_acknowledges(self):
        root = '/tmp/a "quoted" path; no source execution'
        result, accepted = self.invoke(["tactictrace-config-v3", root, "2,2,2", "1"],
                                       "last argument")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3], [root, "true", "2,2,2"])
        self.assertEqual(result.stdout.splitlines()[4:], ["an argument", "last argument"])
        self.assertEqual(accepted.read_text(),
                         "tactictrace-config-v3:explicit-noexec-probe\n")

    def test_default_quotas_and_direct_proof_without_config(self):
        result, accepted = self.invoke(["tactictrace-config-v3", "", "", "0"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[:3],
                         ["<embedded>", "false", "7,7,6"])
        self.assertTrue(accepted.is_file())
        plain = subprocess.run([str(self.runtime)], capture_output=True, text=True)
        self.assertEqual(plain.returncode, 0, plain.stderr)
        self.assertEqual(plain.stdout.splitlines()[:3], result.stdout.splitlines()[:3])

    def test_malformed_config_fails_before_proof_and_acknowledgement(self):
        cases = [
            (0, "tactictrace-config-v1"), (0, "tactictrace-config-v2"),
            (2, "01"), (2, "-1"), (2, "2147483648"), (2, "1; print_endline x"),
            (2, "1,,2"), (2, "1,2"), (3, "true"), (3, "bad"), (3, ""),
            (1, "bad\rroot"), (1, "bad\x00root"),
        ]
        for index, value in cases:
            with self.subTest(index=index, value=value):
                lines = ["tactictrace-config-v3", "", "", "0"]
                lines[index] = value
                result, accepted = self.invoke(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(accepted.exists())

    def test_wrong_line_count_is_rejected(self):
        # The withdrawn version-2 layout must not be accepted under any header.
        for lines in (["tactictrace-config-v3", "", "", "0", "extra"],
                      ["tactictrace-config-v3", "", ""],
                      ["tactictrace-config-v3", "stratified-reservoir", "0", "",
                       "", "0", "deterministic"]):
            with self.subTest(lines=lines):
                result, accepted = self.invoke(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(accepted.exists())

    def test_duplicate_config_argument_is_rejected(self):
        result, accepted = self.invoke(["tactictrace-config-v3", "", "", "0"],
                                       "--tactictrace-config", "another")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate", result.stderr)
        self.assertFalse(accepted.exists())


if __name__ == "__main__":
    unittest.main()
