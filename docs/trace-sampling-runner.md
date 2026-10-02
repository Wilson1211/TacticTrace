# Sampling runner

`run-with-sampling.sh` sets the sampling policy, seed, and output root for a
child command. When the command succeeds, `check-sampling-output.py` checks
the collector's completion metadata. Both files must stay in the same directory;
the runner can be called from any working directory.

## Requirements

- Bash and Python 3, using only the Python standard library.
- A proof executable rebuilt with the selectable sampling collector from the
  companion collector PR. The standalone runner PR does not include that
  collector change.
- A new absolute output directory for each run.

The runner does not compile proofs, install the collector, or invalidate
cached `.correct` targets. Check the executable's build provenance before
running it. An older binary can write to its original output location before
the runner detects missing sampling metadata.

## Usage

After rebuilding the proof with the selectable collector, preview a run:

```sh
bash /path/to/TacticTrace/run-with-sampling.sh \
  --trace-sampling stratified-reservoir \
  --trace-sampling-seed 42 \
  --trace-output-root /absolute/path/to/new-run \
  --dry-run -- /path/to/proof.native
```

Remove `--dry-run` to run the command. A preview prints the settings and
shell-quoted command without creating directories or starting the proof.
Put the command and its arguments after `--`; argument boundaries are preserved.

| Option | Meaning |
| --- | --- |
| `--trace-sampling POLICY` | `legacy` (default) or `stratified-reservoir` |
| `--trace-sampling-seed N` | Decimal integer from 0 to 2147483647 (default: 0); leading zeros are accepted |
| `--trace-output-root DIR` | Required new absolute directory; existing paths and dangling symlinks are refused |
| `--dry-run` | Print the run without creating files or executing the command |
| `--help` | Show usage |

The child receives `TRACE_SAMPLING_POLICY`, `TRACE_SAMPLING_SEED`, and
`TRACE_SAMPLING_OUTPUT_ROOT`. These override inherited values, including when
the default policy and seed are used. The caller's environment is unchanged.

For a proof in Docker, run the wrapper inside the container and use paths
visible there. The runner does not enter containers or translate host paths.

## Output and failures

The selectable collector writes a trace directory named after each original
dump basename and a sibling `<basename>.sampling.json` file under the output
root. The runner requires at least one metadata file. Each file must report
policy version 1, the requested policy and seed, and an existing trace directory
directly under the root with the matching sidecar name.

Invalid options return status 2 before the command starts. A failed child
command keeps its exit status. A successful command with missing, malformed,
or inconsistent metadata returns status 1. All created output is retained on
failure, including incomplete metadata files; choose a new root to retry.

The completion check detects a skipped proof target or an old collector that
produced no sampling metadata. It does not verify executable provenance,
trace contents, proof coverage, or whether sampling improves downstream results.

## Wrapper tests

```sh
make test-sampling-runner
bash -n run-with-sampling.sh
```

These tests use a small Python fixture to exercise command arguments,
configuration, output preservation, and metadata checks. They do not run
HOL Light or establish the collector's sampling behavior. `make test` also
includes them alongside the existing native tests.
