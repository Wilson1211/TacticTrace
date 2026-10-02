# Select a Stage 1 tactic sampling policy

This feature changes which successful tactic applications the collector keeps.
It does not change which tactics run, the size filters, conversion retention,
or the sampling in a later description or judge prompt.

The default is `legacy`. It keeps the original retention algorithm: fill the
capacity, then prefer shorter input conclusions, and stop replacing records
once all retained input conclusions are shorter than the existing cutoff.
Running a rebuilt proof without any sampling environment variables keeps its
old dump path and does not add sampling metadata.

`stratified-reservoir` is an experimental alternative, not a claim of better
descriptions. It groups records by the resulting subgoal count: `0`, `1`, and
`2+`. Each group has its own fixed-capacity reservoir. Once full, an eligible
arrival number `n` gets a uniformly drawn position in `0..n-1`; it replaces a
stored record only if the position is inside that group's capacity. This avoids
always keeping the earliest records within a group.

The total capacity remains `ExportTrace.max_num_records`. With this checkout's
upstream default of 20, the group capacities are 7, 7, and 6. With other compiled
capacities, integer division allocates an equal share and any remainder goes to
the lower-index groups. Empty or small groups leave capacity unused; it is not
transferred to another group. A total below 3 gives some groups zero capacity.
The capacity is per tactic name per collector lifetime, not necessarily per
individual theorem within that run. The dump does not reset the collector.

## Build prerequisite: do not reuse old proof executables

The collector is copied into instrumented proof source by `modify-proof.sh`.
An existing `.native` does not gain this feature when this file is edited.
Regenerate the instrumented source with this collector, then compile and link
it in a separate build directory. A kernel-wrapper rebuild alone is not enough.
Do not delete old `.native`, `.correct`, or trace files to force a rebuild.

Changing an environment variable does not rebuild a proof, bypass a `.correct`
make target, or retrofit an old executable. An old executable may ignore these
variables and use its original dump path. Verify the build's provenance before
running it.

The original build scripts expect the deployed collector under
`$HOLLIGHT_DIR/TacticTrace`. A separate development checkout does not automatically
replace that copy. Use an isolated deployment/build when testing real proofs;
do not overwrite a configured campaign checkout just to try this feature.

## Runtime environment settings

The collector reads its settings at the first tactic collection or dump and
keeps them for that collector's lifetime.

| Variable | Default | Meaning |
| --- | --- | --- |
| `TRACE_SAMPLING_POLICY` | `legacy` | `legacy` or `stratified-reservoir` |
| `TRACE_SAMPLING_SEED` | `0` | Canonical decimal integer from 0 to 2147483647 |
| `TRACE_SAMPLING_OUTPUT_ROOT` | Unset | Absolute existing directory for redirected dumps and metadata |

An explicit empty or unknown policy, invalid seed, or invalid root is rejected.
Canonical decimal has no leading sign or zeros, except for the value `0`.
Stratified sampling requires an output root; legacy can run without one.

The following examples assume the proof was rebuilt with this collector.
The `mkdir` must succeed before the proof runs, so an old run root is not reused.
Replace the executable placeholder and choose new roots for each experiment.

```bash
# Compare the existing policy with metadata and a separate output directory.
mkdir /tmp/tactic-legacy-run1 && \
  env TRACE_SAMPLING_POLICY=legacy TRACE_SAMPLING_SEED=0 \
    TRACE_SAMPLING_OUTPUT_ROOT=/tmp/tactic-legacy-run1 \
    /path/to/rebuilt-proof.native

# Use separate reservoirs for 0, 1, and 2+ subgoals.
mkdir /tmp/tactic-stratified-run1 && \
  env TRACE_SAMPLING_POLICY=stratified-reservoir TRACE_SAMPLING_SEED=42 \
    TRACE_SAMPLING_OUTPUT_ROOT=/tmp/tactic-stratified-run1 \
    /path/to/rebuilt-proof.native
```

The direct collector requires an existing root, but each individual dump
directory and its sidecar must be new. It does not create the root or delete
old data. Use paths visible to the proof process. If using Docker, explicitly
pass these variables into the container and use mounted container paths;
setting a host variable alone does not ensure the container receives it.

## Output and provenance

If the proof originally calls `exptrace_dump "/old/traces/proof.ml"`, setting an
output root redirects that dump to:

```text
<new-output-root>/
  proof.ml/                  # Original tactic/conversion JSON format
  proof.ml.sampling.json    # Sampling settings and counters
```

The original directory is not used when this output override is active. Two
dumps with the same final directory name in one root are refused rather than
merged or overwritten. Choose separate roots for such runs. Failed runs keep
their partial output, including any empty metadata reservation, for inspection.

The sidecar is outside the proof's record directory so record readers do not
mistake it for tactic records. It includes:

- Policy version, policy name, seed, and compiled total capacity.
- Bucket names and capacities (`null` capacities for legacy, which has no quotas).
- Original and actual output paths.
- Per-tactic counts rejected by size filters.
- Per-tactic, per-bucket eligible arrival counts and final retained counts.

Keep the build commit, local source changes, HOL Light version, executable
identity, input proofs, and invocation with the experiment record as well.
The sidecar does not automatically recover those details from a compiled binary.

## Reproducibility and limitations

Each tactic and bucket has a private pseudo-random stream derived from the seed
and tactic name (FNV-1a followed by SplitMix64). It does not consume HOL Light's
global random state. Bounded draws reject the incomplete remainder range rather
than introducing modulo bias. The same policy version, seed, and ordered input
records produce the same retained set. Different seeds may produce the same set
on small streams, especially when all records fit.

The new sampler decides acceptance before printing a candidate's conclusion and
keeps argument rendering lazy until dump. The existing dump order still favors
short inputs; it is an output order, not the new retention rule. A downstream
reader that takes only the first few records can still lose diversity.

Arguments use the printer state at dump time, as in the existing lazy collector.
Changing pretty-printer settings during a proof can therefore change their text
compared with an older collector that rendered arguments immediately.

More even bucket counts are not the same as complete semantic coverage. A tactic
that always leaves one subgoal needs other features to distinguish its behavior.
The sample also does not reflect original outcome frequencies: use the eligible
arrival counts for that. Pre-filtered large goals and unrecorded failures cannot
be recovered by this sampler.

## Focused tests

These tests compile this checkout's collector directly into a small synthetic
fixture. They do not run s2n-bignum proofs, overwrite a campaign, or make API calls.
Python 3 and a module-mode HOL Light build are required. The helper uses HOL
Light's `inline-load`, `compile`, and `link` commands with this checkout's source;
it does not use or change the collector inside the HOL Light directory.

```bash
make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light
```

The focused target is also included in `make test`, so the normal CI test command
covers the sampler. Coverage includes the legacy retention oracle, lazy argument
rendering, conversion compatibility, size filters, bucket counts, independent
random streams, output collisions, and a fixed retained-ID contract for policy
version 1 with the default capacity.

Every invocation builds in a new `tests/_trace_sampling/run-*` directory, so a
different HOL Light path or rebuilt library cannot silently reuse an old test
executable. Generated source, compiler outputs, logs, and test traces are kept
there on success and failure. The helper prints the directory before building.
It does not remove earlier test outputs.

To rerun the Python checks against a specific freshly built fixture, set
`TRACE_SAMPLING_TEST_NATIVE` to its absolute path and run
`python3 -B tests/test_trace_sampling.py`. Without that variable the tests fail
with setup instructions; they are never silently skipped. The normal make
target supplies it automatically. Direct Python runs preserve their output in
new temporary directories and print those locations.

Before deploying to a campaign, compare legacy retention against its existing
baseline under that campaign's compiled limits and establish a separate rebuild
and run plan. The tests here use the upstream defaults, not a local relaxed
campaign configuration.
