# Sampling runner

`run-with-sampling.sh` launches an instrumented proof with an explicit sampling
configuration. The runner creates a new output root and a versioned data file;
`sampling_runtime.ml`, embedded by `modify-proof.sh`, reads that file and calls
`ExportTrace.configure_sampling` before proof code runs. No OCaml source is
built from the supplied settings. After the proof, the runner verifies the
adapter acknowledgement and each collector sidecar.

## Requirements

- Bash, Python 3, and a proof executable freshly built with the companion
  collector PR **and** this adapter. Rebuild the instrumented source; changing
  `exportTrace.ml` or `sampling_runtime.ml` does not update an old `.native`.
- A new absolute output directory for each run.

The runner does not compile proofs or invalidate cached `.correct` targets.
The normal `modify-proof.sh` flow embeds the adapter after `exportTrace.ml` and
before the instrumented proof. An invocation without `--tactictrace-config`
uses deterministic stratified sampling and the original dump path.

## Usage

Preview a deterministic stratified run:

```sh
bash /path/to/TacticTrace/run-with-sampling.sh \
  --trace-output-root /absolute/path/to/new-run \
  --dry-run -- /path/to/rebuilt-proof.native
```

Remove `--dry-run` to run it. For random reservoir selection, explicitly
select random and supply a seed:

```sh
bash /path/to/TacticTrace/run-with-sampling.sh \
  --selection-mode random --trace-sampling-seed 42 \
  --trace-output-root /absolute/path/to/random-run \
  -- /path/to/rebuilt-proof.native
```

| Option | Meaning |
| --- | --- |
| `--trace-sampling POLICY` | `stratified-reservoir` is the default and only accepted value; the flag is optional |
| `--selection-mode MODE` | `deterministic` (default) or explicitly selected `random` |
| `--trace-sampling-seed N` | Decimal integer in 0..2147483647, allowed only with random mode; default 0 |
| `--trace-success-quotas CSV` | Stratified group quotas: 1, 3, or 5 nonnegative integers with positive total; default `7,7,6` |
| `--trace-success-backfill` | Allow groups with eligible records to use unused quota at dump time |
| `--trace-output-root DIR` | Required new absolute directory; existing paths and dangling symlinks are refused |
| `--dry-run` | Print settings and shell-quoted command without creating files or executing the command |

One quota groups all records as `0+`; three use `0,1,2+`; five use
`0,1,2,3,4+` resulting subgoals. A zero quota disables its group. The
collector documentation defines deterministic selection and backfill order.

The command and its arguments follow `--`; argument boundaries are preserved.
The runner appends `--tactictrace-config PATH`. The data file holds seven lines:
protocol version, policy, seed, output root, quota CSV (empty means defaults),
backfill flag, and selection mode.

For Docker proofs, run the wrapper inside the container with paths visible
there. It does not enter containers or translate host paths.

## Output and failures

A completed run has this layout:

```text
<new-output-root>/
  .tactictrace-config             # Requested settings
  .tactictrace-config.accepted    # Adapter acknowledgement
  proof.ml/                       # Tactic/conversion JSON records
  proof.ml.sampling.json          # Selection settings and counters
```

The runner requires at least one sidecar. It checks policy version 2, the
stratified policy, mode, seed, quotas, backfill, tactic bucket counts,
and a matching trace directory directly under the root. The adapter writes
its acknowledgement before proof code, after accepting the config.

For a **direct** `.native` command, the runner scans the binary for the adapter
capability marker before execution; an old binary is refused without running a
proof as a probe. Indirect commands such as `bash wrapper.sh` are checked only
after they run, so verify the wrapped executable's provenance separately.
Neither check proves trace contents or proof coverage.

Invalid options return status 2 before output creation. A failed child keeps
its exit status. Missing or mismatched metadata returns status 1. Partial
output and settings remain on failure; choose a new root to retry.

## Focused tests

```sh
make test-sampling-runner
bash -n run-with-sampling.sh
```

The runner tests use a synthetic command; the adapter tests compile the real
OCaml parser against a small collector API stub. They do not execute real
proofs. The companion collector PR has separate HOL Light fixture tests.
