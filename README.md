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

This is also what GitHub Actions runs, on Ubuntu and on MacOS; see
`.github/workflows/`. `ci.yml` builds against a fixed HOL Light revision, so
that a red build always means a change here broke something rather than upstream
moving; bump the revision there when TacticTrace is updated for a newer HOL
Light. `upstream.yml` builds against HOL Light `master` weekly, to give early
warning when upstream drifts away from us. It is kept separate so that it does
not appear among the checks on a pull request.

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
