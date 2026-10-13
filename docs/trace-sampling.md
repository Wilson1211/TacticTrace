# Select a Stage 1 tactic sampling policy

The default remains **legacy**. It keeps the original tactic retention algorithm
and output path. Without an explicit output root, it creates no sampling
sidecar. The size filters, conversion retention, and trace record format do not
change.

**stratified-reservoir** groups successful tactic records by the number of
resulting subgoals. Despite the historical policy name, its default selection
mode is now **deterministic**: within each group it keeps the candidates with
the shortest printed input conclusions. Earlier arrivals win equal-length
ties. Arguments remain lazy until dump. The optional **random** selection mode
uses the previous private reservoir streams for historical comparisons;
changing its seed can change which eligible records survive.

## Group quotas and borrowing

Set one, three, or five quota entries:

| Quota entries | Groups |
| --- | --- |
| 1 | 0+ |
| 3 | 0, 1, 2+ |
| 5 | 0, 1, 2, 3, 4+ |

The default three-group quotas are 7, 7, and 6 with this checkout's compiled
max_num_records = 20. Configured quotas may have another positive total. A
zero quota disables that group, including borrowing. With backfill off, an
underfilled group leaves its unused quota empty.

Setting backfill to true opts into the same borrowing rule used by the s2n
experiment patch. At dump, each group first receives up to its own quota.
Remaining places up to the configured total go round-robin in group order to
groups with positive quotas and eligible records beyond their initial
allotment. A deterministic run takes the next shortest candidates, with
earlier arrivals winning ties. A random run uses separate overflow reservoirs
and a private shuffle. Backfill never changes which records were eligible and
does not alter the global HOL Light random state.

This rule fills spare capacity at dump time; it does not evict one old record
when a new group first appears. For example, with quotas 2/2/2 and four
zero-subgoal records followed by one record in each other group, this rule can
retain 4/1/1. An immediate-reclamation policy would end at 2/1/1. The
implementation here follows the already tested s2n experiment behavior. Choose a separate policy if immediate reclamation becomes
an experimental requirement.

The capacity is per tactic name for the collector's lifetime, which may span
multiple theorems. Dumping does not reset the collector.

## Configure a rebuilt proof

The caller must configure the exporter explicitly, before the first tactic
record, conversion record, or dump. The exporter does not read
TRACE_SAMPLING_* environment variables. For example, in proof startup code:

~~~ocaml
let trace_sampling = {
  ExportTrace.default_sampling_config with
  policy = "stratified-reservoir";
  output_root = Some "/tmp/new-trace-run";
  bucket_quotas = [|3; 3; 3; 3; 3|];
  backfill = true;
};;
ExportTrace.configure_sampling trace_sampling;;
~~~

The root must be an existing absolute directory. Use a new root per run.
To reproduce the former random reservoir behavior, also set
selection_mode = "random" and, if desired, seed = 42L.
The allowed seed range is 0 through 2147483647. Legacy mode can use an
explicit output root for a redirected dump and sidecar, but custom quotas and
backfill require stratified mode. Configuration is sealed at the first
collection or dump. The exporter copies the quota array when configured, so
later mutation by the caller cannot change a run.

The collector is copied into instrumented proof source by modify-proof.sh.
Changing exportTrace.ml does not rebuild an existing .native proof.
Regenerate instrumented source and compile/link a fresh executable in an
isolated build directory. A kernel-wrapper rebuild alone is not enough.
Preserve existing .native, .correct, and trace artifacts.

The build scripts expect the deployed collector under
$HOLLIGHT_DIR/TacticTrace. A separate development checkout does not
automatically replace it. Use an isolated deployment/build when testing real
proofs and record the exporter revision and executable identity.

## Output and provenance

If a proof calls exptrace_dump "/old/traces/proof.ml" with
output_root = Some "/tmp/new-trace-run", the exporter writes:

~~~text
/tmp/new-trace-run/
  proof.ml/                  # Original tactic and conversion JSON files
  proof.ml.sampling.json    # Configuration and counts
~~~

The exporter refuses an existing dump directory or sidecar instead of
overwriting it. Partial outputs from failed runs remain for inspection. The
sidecar is outside the record directory so record readers do not mistake it
for a tactic record.

The sidecar records the policy, selection mode, backfill flag, seed, compiled
or configured total, group names/quotas, original and actual output paths,
and per-tactic filtered, eligible, and retained counts. With backfill it also
records each tactic's effective group capacities at dump. The version is 1
for legacy and 2 for stratified sampling. The explicit random mode with the
default three quotas retains the old version-1 reservoir stream, but its
sidecar uses version 2 because the configurable policy contract has changed.

Keep the build commit, HOL Light version, executable identity, input proofs,
and invocation with an experiment record. The sidecar cannot recover these
from a compiled binary. Record dumps are sorted by input conclusion length;
the retained set and output order are separate facts.

## Focused tests

The tests compile this checkout's collector directly into a synthetic
fixture. They do not run s2n-bignum proofs or change a campaign. Python 3 and
a module-mode HOL Light build are required:

~~~bash
make test-trace-sampling HOLLIGHT_DIR=/home/tong-nong/hol-light
~~~

The target is also included in make test. It checks legacy retention and
output compatibility, explicit configuration and sealing, deterministic
shortest-first selection and first-arrival ties, one/three/five groups,
optional backfill, the old random stream, private RNG behavior, lazy
arguments, conversion compatibility, size filters, and output collisions.

Each run builds in a new tests/_trace_sampling/run-* directory and preserves
its sources, compiler logs, test logs, and traces. To rerun Python checks
against a specific fresh fixture, set TRACE_SAMPLING_TEST_NATIVE to its
absolute path and run python3 -B tests/test_trace_sampling.py. That variable
only selects the test executable; the exporter does not consume it.
