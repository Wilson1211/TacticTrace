"""Build this checkout's collector in a fresh directory, optionally testing it."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parent.parent


def ocaml_path(path):
    # HOL Light's inline loader does not decode escapes in loadt filenames.
    if any(char in str(path) for char in ('"', "\\", "\n", "\r")):
        raise ValueError(f"HOL inline-load cannot safely parse this path: {path}")
    return '"' + str(path) + '"'


def run_logged(command, build, name, *, env=None):
    log = build / f"{name}.log"
    with log.open("x") as stream:
        result = subprocess.run(command, cwd=build, env=env,
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text(), file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)


def build_fixture(hol_light_dir):
    hol = (Path(hol_light_dir).resolve(strict=True) / "hol.sh").resolve(strict=True)
    exporter = REPO / "exportTrace.ml"
    fixture = REPO / "tests" / "trace_sampling.ml"
    entry = f"loadt {ocaml_path(exporter)};;\nloadt {ocaml_path(fixture)};;\n"
    parent = REPO / "tests" / "_trace_sampling"
    ocaml_path(parent)
    if subprocess.check_output([str(hol), "-use-module"], text=True).strip() != "1":
        raise ValueError("HOL Light must be built with HOLLIGHT_USE_MODULE=1")

    parent.mkdir(exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    print(f"Sampling build and outputs: {build}", flush=True)
    with (build / "fixture.ml").open("x") as stream:
        stream.write(entry)
    for args in (
        ("inline-load", "fixture.ml", "trace_sampling.ml"),
        ("compile", "trace_sampling.ml", "-o", "trace_sampling.cmx"),
        ("link", "trace_sampling.cmx", "-o", "trace_sampling.native"),
    ):
        run_logged([str(hol), *args], build, args[0])
    return build / "trace_sampling.native"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hol_light_dir", type=Path)
    parser.add_argument("--test", action="store_true", help="Run the native collector tests")
    args = parser.parse_args()
    try:
        native = build_fixture(args.hol_light_dir)
        print(f"Sampling fixture: {native}", flush=True)
        if args.test:
            output = native.parent / "test-results"
            output.mkdir()
            env = dict(os.environ, TRACE_SAMPLING_TEST_NATIVE=str(native),
                       TRACE_SAMPLING_TEST_OUTPUT_ROOT=str(output))
            run_logged([sys.executable, "-B", str(REPO / "tests" / "test_trace_sampling.py")],
                       native.parent, "tests", env=env)
            print((native.parent / "tests.log").read_text(), end="")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Sampling fixture failed; partial output was preserved: {exc}\n")


if __name__ == "__main__":
    main()
