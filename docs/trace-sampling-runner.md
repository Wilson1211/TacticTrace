# Sampling runner

`run-with-sampling.sh` runs an instrumented proof with sampling settings chosen
on the command line, instead of the settings compiled into the proof. It writes
the settings to a file, passes the path to the proof, and checks afterwards
that the proof read them and produced matching output.

See [tactic sampling](trace-sampling.md) for what the settings mean.

## Requirements

- Bash and Python 3.
- A proof executable built from instrumented source that includes
  `sampling_runtime.ml`. `modify-proof.sh` adds it after `exportTrace.ml`, so
  the normal build already does. Editing `exportTrace.ml` or
  `sampling_runtime.ml` does not update an executable that is already built.
- A new absolute directory for the run's output.

The runner does not build proofs, so rebuild first if the collector changed.

## Usage

Print the settings without running anything:

```sh
bash run-with-sampling.sh \
  --trace-output-root /absolute/path/to/new-run \
  --dry-run -- /path/to/proof.native
```

Drop `--dry-run` to run the proof. To raise the quotas and switch borrowing
off:

```sh
bash run-with-sampling.sh \
  --trace-success-quotas 8,8,8,8,8 --trace-success-no-backfill \
  --trace-output-root /absolute/path/to/new-run \
  -- /path/to/proof.native
```

| Option | Meaning |
| --- | --- |
| `--trace-success-quotas CSV` | 1 or 5 nonnegative bucket quotas with a positive total; default `4,4,4,4,4` |
| `--trace-success-no-backfill` | Stop buckets from borrowing each other's unused places; borrowing is on by default |
| `--trace-output-root DIR` | Required. A new absolute directory for this run; an existing path or a dangling symlink is refused |
| `--dry-run` | Print the settings and the command without creating anything or running it |

The command to run follows `--`, and its arguments are passed through
unchanged. The runner appends `--tactictrace-config PATH` to it.

That file holds four lines: `tactictrace-sampling-config`, the output root, the
quotas as comma-separated values (empty means the defaults), and `1` or `0` for
borrowing. `sampling_runtime.ml` parses it and calls
`ExportTrace.configure_sampling` before any proof code runs. The file is data,
never OCaml source, so nothing in it is evaluated.

To run a proof inside a container, run the script inside the container too,
with paths that exist there. It does not enter containers or translate paths.

## Output

A finished run leaves:

```text
<output-root>/
  .tactictrace-config           # The settings the runner passed in
  .tactictrace-config.accepted  # Written by the proof once it accepts them
  tactic.outdir/                # One JSON file per tactic and per conversion
  tactic.outdir.sampling.json   # The sampling summary: settings and per-tactic counts
```

The name `tactic.outdir` is the basename of the dump directory compiled into the
proof (here, from `examples/tactic.ml`); a proof built from another file uses
its own name.

The runner then checks that the proof accepted the settings and that every
sampling summary matches them: the quotas, the borrowing flag, the per-bucket counts,
and a records directory in the right place. It also counts the records in each
`<tactic>.json` and compares the number with the retained total in the summary.
A tactic that kept no records has no file, so a missing file is accepted only
when the summary reports zero retained records for it. A proof built without
`sampling_runtime.ml` cannot write the acceptance file, so it cannot be
mistaken for a configured run.

Before running a command that is directly a `.native` file, the runner looks
for `tactictrace-sampling-config` inside it and refuses to start if it is
absent. This avoids running a whole proof just to discover it ignores the
settings. A command given in another form, such as `bash wrapper.sh`, can only
be checked after it runs.

## Failures

| Situation | Exit status |
| --- | --- |
| The runner rejects something and runs nothing: bad options, an output root that is not new and absolute or cannot be created, a `.native` that cannot read the settings, a missing checker | 64 |
| Settings or output missing or not matching | 1 |
| The command itself failed | the command's own status |

The runner's own errors use 64 because other statuses are taken: an OCaml
program that dies from an uncaught exception exits with 2, which would be
indistinguishable from a runner error. Whatever status the checker uses
internally, the runner reports 1 when it fails. A command that happens to exit
with 64 or 1 cannot be told apart from a runner error by status alone; the
message on standard error says which one it was.

Nothing is created for an invalid invocation. When a run fails after starting,
its directory is left in place to inspect; pick a new one to retry.

## Tests

```sh
make test-sampling-runner
make test-sampling-runner-e2e
```

The first runs the script against a stand-in command and compiles
`sampling_runtime.ml` against a small stub of the collector API, so it needs
neither HOL Light nor a real proof. It needs `ocamlc` on `PATH` and fails
without it.

The second runs the real `examples/tactic.native` through the runner with
quotas `1,1,1,1,1`, writing under `tests/_sampling_runner/`, so the checker
sees output from the actual collector. It needs the HOL Light build described
in the README. `make test` includes both, and GitHub CI runs each as its own
step.
