# Tactic sampling

A proof can run the same tactic thousands of times, so the collector keeps only
a bounded number of records per tactic. This document describes how it chooses
them and how to change the choice.

## Buckets

TacticTrace groups the records of one tactic by the number of resulting
subgoals. Each group is a **bucket** with its own capacity, called its
*quota*. The goal of grouping is to increase the diversity of the sampled
records.

| Quota entries | Buckets, by number of resulting subgoals |
| --- | --- |
| 1 | 0+ |
| 5 | 0, 1, 2, 3, 4+ |

The last bucket also takes every larger number of subgoals, so `4+` holds four
or more, and a single bucket holds everything. By default there are five
buckets, which share `max_num_records` evenly: four records each.

## What each bucket keeps

Within a bucket, the collector keeps the records whose printed input
conclusions are shortest, because short goals are the easiest to read. When two
records print to the same length, the one collected earlier wins. Arguments are
not rendered until the record is dumped, so a record that loses its place costs
nothing to render.

## Borrowing

A bucket that sees fewer records than its quota leaves places unused. By
default those places are **borrowed** by the buckets that still have records
left over, and each borrowed place takes the shortest record its bucket had to
give up. The places are shared evenly; when they cannot be, the buckets with
fewer subgoals get the extra ones.

For example, a tactic that always leaves one subgoal puts all its records in
one bucket. With the default quotas that bucket keeps 4 records on its own, and
with borrowing it keeps all 20, because the other four buckets have nothing to
put in their places.

## Configuring a run

Call `ExportTrace.configure_sampling` before the first record is collected and
before the dump:

```ocaml
ExportTrace.configure_sampling {
  ExportTrace.default_sampling_config with
  bucket_quotas = [|4; 4; 4; 4; 4|];
  backfill = false;
  output_dir = Some "/absolute/path/to/new-run/traces";
};;
```

- `bucket_quotas` has either 1 entry (a single `0+` bucket) or 5 entries
  (buckets `0`, `1`, `2`, `3`, `4+`). Each entry is a nonnegative quota, and
  the entries must add up to at least 1.
- `backfill` turns borrowing on or off. It is on by default.
- `output_dir`, when set, is the directory the dump writes the traces to. It
  must be an absolute path that ends in a directory name, with no empty, `.`
  or `..` components, and its parent must be an existing directory. Neither
  the directory nor its sampling summary may exist yet: this is checked here,
  before the proof runs, and again by the dump, which creates the directory
  itself. Use a new one for each run.
  When it is `None`, the dump writes to the default output directory.

The settings are sealed once collection or dumping starts, so a later call
raises instead of changing a run that is already under way.

## Output

`exptrace_dump ()` writes one JSON file per tactic and per conversion into the
output directory. Records are written shortest conclusion first, and newest
first among records of equal length. A tactic that kept no records gets no file.

There is one output directory per run. It is `output_dir` when the
configuration sets it. Otherwise it is the default output directory, which is
the third argument of `modify-proof.sh`: the script adds a call to
`exptrace_set_default_dir` before the proof, and `exptrace_dump ()` as the last
line. A dump with neither raises `Invalid_argument`. The default may be set
again with the same directory but not changed to another one, and without
`output_dir` it must not already exist.

The dump is an explicit call at the end of the proof, not an `at_exit`
handler. A proof that fails with an exception never reaches it, so it writes no
traces and no sampling summary.

With `output_dir` set, the dump also writes a **sampling summary**: a JSON file
next to the output directory, named after it with `.sampling.json` added, that
reports the settings the run used and how many records it saw and kept. It sits
outside the output directory so that it is never mistaken for a tactic's
records. Without `output_dir` no summary is written.

```text
/absolute/path/to/new-run/
  traces/                  # One JSON file per tactic and per conversion
  traces.sampling.json     # The sampling summary
```

The sampling summary reports the borrowing flag, the total capacity, the bucket
names and quotas, the output directory, and, for each tactic, how many records
a size filter rejected and how many each bucket saw and kept. When borrowing is
on it also reports the capacity each bucket ended up with.

The dump refuses to replace an existing output directory or, when `output_dir`
is set, an existing sampling summary, so a finished run cannot be overwritten
by a later one. If the dump fails after creating the sampling summary, it
removes that summary so that it does not block the next run.

## Tests

```bash
make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light
```

This compiles the collector in this checkout into a synthetic fixture and
checks the defaults, explicit configuration and sealing, the output location,
failed proofs, shortest-first
selection and arrival-order ties, one and five buckets, borrowing, lazy
arguments, conversion retention, the size filters, and the refusal to
overwrite output.
Each run keeps its build, sources, logs, and traces in a new
`tests/_trace_sampling/run-*` directory.

`make test` includes this suite, and GitHub CI runs it as its own step.
