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
  output_root = Some "/absolute/path/to/new-run";
};;
```

- `bucket_quotas` has either 1 entry (a single `0+` bucket) or 5 entries
  (buckets `0`, `1`, `2`, `3`, `4+`). Each entry is a nonnegative quota, and
  the entries must add up to at least 1.
- `backfill` turns borrowing on or off. It is on by default.
- `output_root`, when set, must be an absolute path to an existing directory,
  and redirects the dump into it. Use a fresh directory for each run. When it
  is `None`, the dump writes to the path the proof passed to `exptrace_dump`.

The settings are sealed once collection or dumping starts, so a later call
raises instead of changing a run that is already under way.

## Output

`exptrace_dump "/path/tactic.outdir"` writes one JSON file per tactic and per
conversion into `/path/tactic.outdir/`. Records are written shortest conclusion
first, and newest first among records of equal length.

With `output_root` set, the dump is redirected and also writes a **sampling
summary**: a JSON file next to the records directory that reports the settings
the run used and how many records it saw and kept. It sits outside the records
directory so that it is never mistaken for a tactic's records.

```text
/absolute/path/to/new-run/
  tactic.outdir/                # One JSON file per tactic and per conversion
  tactic.outdir.sampling.json   # The sampling summary
```

Both names come from the basename of the directory passed to `exptrace_dump`,
which `modify-proof.sh` compiles into the proof; `tactic.outdir` is the one
for `examples/tactic.ml`. A tactic that kept no records gets no file.

The sampling summary reports the borrowing flag, the total capacity, the bucket
names and quotas, the requested and actual output paths, and, for each tactic,
how many records a size filter rejected and how many each bucket saw and kept.
When borrowing is on it also reports the capacity each bucket ended up with.

A redirected dump refuses to replace an existing records directory or sampling
summary, so a finished run cannot be overwritten by a later one.

## Tests

```bash
make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light
```

This compiles the collector in this checkout into a synthetic fixture and
checks the defaults, explicit configuration and sealing, shortest-first
selection and arrival-order ties, one and five buckets, borrowing, lazy
arguments, conversion retention, the size filters, and the refusal to
overwrite output.
Each run keeps its build, sources, logs, and traces in a new
`tests/_trace_sampling/run-*` directory.

`make test` includes this suite, and GitHub CI runs it as its own step.
