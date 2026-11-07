# TacticTrace

This tool detects definitions of HOL Light tactics/conversions as well as their users,
and patches proof files so that

* Tactics log the input and output goals
* Conversions log the input term and output theorem

in the JSON format.

Also, this tool provides a tool for collecting top-level theorems that are defined
as `let <theorem> = prove(<goal>, <proof>);;` and dumping in the JSON format.

## Prerequisite

This project does not need patching HOL Light.
Instead, HOL Light must be built with OCaml 5.4.0 (the `make switch-5` as of
Sep. 16, 2026) and compiled with `HOLLIGHT_USE_MODULE=1`:

```sh
git clone https://github.com/jrh13/hol-light.git
cd hol-light
make switch-5
eval $(opam env)
HOLLIGHT_USE_MODULE=1 make
```

**Location.**
TacticTrace's scripts locate each other, `hol_lib_inlined.mli` and
`kernel_wrapper.ml` through `$HOLLIGHT_DIR/TacticTrace`, so this repository has
to be checked out inside the HOL Light directory:

```sh
git clone https://github.com/hol-light/TacticTrace.git <the HOL Light dir>/TacticTrace
```

**Operating System.**
TacticTrace is tested on Ubuntu and MacOS, both of which are covered by
continuous integration.

## 1. Building trace-generating tactic/conv wrappers of the HOL Light kernel

```sh
export HOLLIGHT_DIR=<the HOL Light dir>
eval $(opam env --set-switch --switch=${HOLLIGHT_DIR})

make

./build-hol-kernel.sh
```

This will create `kernel_wrapper.ml` which will be used in the next step.

## 2. Collecting the traces of tactic/conversion

Let's assume that you want have a HOL Light proof file `a.ml`.
You will need to inline `loadt`/`loads`/`needs` invocations in `a.ml` through the following
OCaml script which is provided by HOL Light:

```sh
${HOLLIGHT_DIR}/hol.sh inline-load a.ml a_inlined.ml
```

The next step is to modify the definitions of tactics/conversions as well as their
users in `a_inlined.ml` so that they emit the inputs and outputs to a JSON file.

```sh
${HOLLIGHT_DIR}/TacticTrace/modify-proof.sh a_inlined.ml a_inlined_wrapped.ml /home/your/output/dir
```

The last argument is the default directory the collected traces are written to.

You can run the `a_inlined_wrapped.ml` by loading it on top of HOL Light REPL (`hol.sh`), or
building it using the OCaml compiler. The following commands show how to build it using the OCaml
native compiler.

```sh
${HOLLIGHT_DIR}/hol.sh compile a_inlined_wrapped.ml -o a_inlined_wrapped.cmx
${HOLLIGHT_DIR}/hol.sh link a_inlined_wrapped.cmx -o a_inlined_wrapped.native
```

## 3. Collecting top-level theorems

Given an inlined HOL Light proof `a_inlined.ml`, you can use `tracer collect-top-level-thms` to
collect information of the top-level theorems.

For example, if `a_inlined.ml` contains:

```
...
let MY_THM = prove(
  `forall x, x + 1 = 1 + x`,
  ARITH_TAC);;
```

Running the following commands will save a JSON file that contains the line number
informations of theorems including `MY_THM`.

```
${HOLLIGHT_DIR}/TacticTrace/get-ast.sh a_inlined.ml # This creates a_inlined.marshalled.bin
${HOLLIGHT_DIR}/TacticTrace/tracer collect-toplevel-thms a_inlined.marshalled.bin output.json
```

### Known limitations

**Correctness of line/column number information of the goal.**
If the goal term of a theorem consists of multiple lines, e.g.,

```
prove(`forall x,
x + 1 = 1 + x`,
    (my tac))
```

You will observe that the column number and line number does not exactly match.
This is because the source code preprocessor of HOL Light first replaces line breaks
in a term with spaces, as follows:

```
prove(`forall x, x + 1 = 1 + x`,
    (blank line)
    (my tac))
```

Therefore, if you want to extract the string representation of goal from the source code,
`goal_linenum_end` and `goal_colnum_end` should be properly adjusted.

**Theorems inside modules.**
TacticTrace will not catch tactics that are defined inside a module.

## Tactic sampling

A tactic can run thousands of times in one proof, so the collector keeps only a
bounded number of records for it. It groups a tactic's records into buckets by
the number of resulting subgoals, and each bucket keeps the records with the
shortest printed input conclusions, preferring the earlier record when two
print to the same length. Places that a bucket cannot fill are borrowed by the
buckets that have more records than they can keep.

By default there are five buckets, for zero through four or more subgoals, and
they share `max_num_records` evenly. `ExportTrace.configure_sampling` changes
the quotas, collapses them to a single bucket, turns borrowing off, and can
write a run to a chosen output directory together with a summary of what it
collected. The third argument of `modify-proof.sh` is the default output
directory. The proof ends with an explicit `exptrace_dump ()`, so a proof that
fails writes no traces. See [tactic sampling](docs/trace-sampling.md).

## Testing

`make test` runs the proofs in `examples/` through the full pipeline of steps 1
and 2 above, writing the collected traces to `examples/<name>.outdir` and the
HOL Light output to `examples/<name>.hollog`, and then compares the collected
traces against the expected traces in `examples/<name>.answer`:

```sh
export HOLLIGHT_DIR=<the HOL Light dir>
eval $(opam env --set-switch --switch=${HOLLIGHT_DIR})

make
./build-hol-kernel.sh
make test
```

It also runs a focused regression test for lazy tactic argument rendering. The
test checks that arguments are not rendered while records are added, retained
arguments are rendered once during the dump, and a discarded candidate is
never rendered. It covers tactic records only; conversion argument rendering
remains eager and is covered by the existing conversion answer tests.

The sampling tests also run as part of `make test`. They compile this
checkout's collector into a synthetic fixture and keep the build, logs, and
test outputs under `tests/_trace_sampling/`:

```sh
make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light
```

`make test` fails if HOL Light was not built with `HOLLIGHT_USE_MODULE=1`, since
no traces can be collected without it.

The expected traces record the HOL Light directory as the literal string
`$HOLLIGHT_DIR` so that they do not depend on where HOL Light is checked out;
`check-answers.sh` substitutes the real path before comparing.

If you change the trace format, `make test` will report the difference and fail.
To accept the new traces as expected, run:

```sh
./check-answers.sh --update
make test
```

`--update` writes the traces that the failing `make test` already collected in
`examples/<name>.outdir` over `examples/<name>.answer`, normalizing them the same
way the comparison does. Review the resulting diff before committing it, and run
`make test` again to confirm it now passes.

GitHub Actions runs the example checks, the lazy-argument regression, the
sampling suite, the sampling runner tests, and a run of the sampling runner on
`examples/tactic.native` as separate steps on Ubuntu and macOS. The HOL Light
revision is pinned in `.github/workflows/build-and-test.yml`. Build and test
logs are uploaded even when a test fails.

## Sampling runner

`run-with-sampling.sh` runs an instrumented proof with sampling settings chosen
on the command line — the bucket quotas (1 or 5 of them), whether borrowing is
on, and a new directory for the output — rather than the settings compiled into
the proof. It passes them to the proof in a file. `modify-proof.sh` embeds
`sampling_runtime.ml` in the proof, and it reads that file before any proof
code runs. After the run, the runner checks the collected output against the
settings. It needs Bash and Python 3, and does
not build proofs.

See [the sampling runner](docs/trace-sampling-runner.md) for the options and
the output layout and exit statuses. `make test-sampling-runner` runs its unit
tests without HOL Light, and `make test-sampling-runner-e2e` runs it on the real
`examples/tactic.native`. `make test` includes both, and GitHub CI runs each as
its own step.

## Versioning and releases

Releases are tagged `ocaml-<version>/v<n>`, where `<version>` is the OCaml
version that HOL Light must be built with and `<n>` counts the releases made
against it:

```
ocaml-5.4/v1
ocaml-5.4/v2
ocaml-5.4/v3
  |
ocaml-5.5/v1
```

TacticTrace tracks OCaml and HOL Light internals closely enough that the
supported compiler is the most important thing a user needs to know about a
release, so it is named in the tag rather than left to a changelog. Updates for
the currently supported compiler bump `<n>`; when HOL Light supports a new OCaml
version well, that becomes a new `ocaml-<version>/v1`. The two series can be
maintained in parallel from `release/ocaml-5.4`-style branches if a fix is
needed for an older compiler after `main` has moved on.

## History

TacticTrace was developed inside the HOL Light repository, as its `TacticTrace`
directory, from September 2025 until it moved to this repository. HOL Light's
`holtest.mk` used to test it through the `TacticTrace/make-test` target; that is
now covered by this repository's GitHub Actions workflows.

## Author and contact

Juneyoung Lee, aqjune@gmail.com
