"""Assemble a fixture with this checkout's exporter, then compile it once."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parent.parent
hol = Path(sys.argv[1]).resolve() / "hol.sh"
if subprocess.check_output([str(hol), "-use-module"], text=True).strip() != "1":
    raise SystemExit("test-trace-sampling requires HOL Light built with HOLLIGHT_USE_MODULE=1")
build = repo / "tests" / "_trace_sampling"
build.mkdir(exist_ok=True)
wrapped = build / "trace_sampling_wrapped.ml"
wrapped.write_text(
    "open Hol_lib;;\nopen Hol_loader;;\n"
    + (repo / "exportTrace.ml").read_text()
    + "\n"
    + (repo / "tests" / "trace_sampling.ml").read_text()
)
obj = build / "trace_sampling.cmx"
subprocess.run([str(hol), "compile", str(wrapped), "-o", str(obj)], check=True)
subprocess.run([str(hol), "link", str(obj), "-o", str(build / "trace_sampling.native")], check=True)
