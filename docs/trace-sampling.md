# Tactic sampling

Successful tactic records are always grouped by the number of resulting
subgoals. The default selection is **deterministic**: each group keeps the
candidates with the shortest printed input conclusions; earlier arrivals win
equal-length ties. Arguments remain lazy until dump. The size filters,
conversion retention, and tactic JSON fields are unchanged.

No configuration call is needed to collect with the default three groups and
quotas 7/7/6. The policy identifier is `stratified-reservoir`; the selection mode
is a separate setting. **random** mode explicitly enables seeded reservoir
selection, using a private stream for each tactic and group. It does not alter
HOL Light's global random state.

## Group quotas and borrowing

| Quota entries | Groups |
| --- | --- |
| 1 | 0+ |
| 3 | 0, 1, 2+ |
| 5 | 0, 1, 2, 3, 4+ |

Default quotas divide `max_num_records = 20` across three groups. Configured
quotas may have another positive total. A zero quota disables that group,
including borrowing. With backfill off, an underfilled group leaves its quota
unused. Capacity is per tactic name over the collector's lifetime; dumping does
not reset collection.

With `backfill = true`, each group first receives up to its own quota at dump.
Remaining places go round-robin in group order to enabled groups with more
eligible records. Deterministic mode takes the next shortest candidates, with
earlier arrivals winning ties. Random mode uses separate overflow reservoirs
and a private shuffle. Eligibility and the total capacity do not change.

For example, quotas 2/2/2 and available counts 4/1/1 retain 4/1/1 with backfill,
and 2/1/1 without backfill. Borrowing is finalized at dump, rather than evicting
a record immediately when a previously empty group receives its first record.

## Configure a rebuilt proof

To override the defaults, call `ExportTrace.configure_sampling` before the first
tactic record, conversion record, or dump:

```ocaml
let trace_sampling = {
  ExportTrace.default_sampling_config with
  output_root = Some "/tmp/new-trace-run";
  bucket_quotas = [|3; 3; 3; 3; 3|];
  backfill = true;
};;
ExportTrace.configure_sampling trace_sampling;;
```

An explicit root must be an existing absolute directory. Use a new root per
run. With `output_root = None`, `exptrace_dump` uses the path supplied by the
proof. To enable random selection, set `selection_mode = "random"` and, for
example, `seed = 42L`. The seed range is 0 through 2147483647.

Configuration is sealed at the first collection or dump. The exporter copies
the quota array so later changes by the caller cannot change the run. The only
accepted `policy` value is `"stratified-reservoir"`.

`modify-proof.sh` copies the collector into instrumented proof source.
Changing `exportTrace.ml` does not change existing `.native` executables.
Regenerate instrumented source and compile/link a fresh executable in an
isolated build directory. Preserve existing `.native`, `.correct`, and trace
artifacts. The build scripts use `$HOLLIGHT_DIR/TacticTrace`; a separate
development checkout does not automatically replace that deployed copy.

## Output and provenance

An ordinary `exptrace_dump "/path/proof.ml"` writes tactic and conversion JSON
there. No sidecar is written without an explicit output root. With
`output_root = Some "/tmp/new-trace-run"`, the same dump writes:

```text
/tmp/new-trace-run/
  proof.ml/                # Tactic and conversion JSON
  proof.ml.sampling.json   # Configuration and counts
```

For redirected dumps, an existing directory or sidecar is refused. Partial
outputs remain for inspection. The sidecar lives outside the records directory
so record readers do not mistake it for a tactic record.

The version-2 sidecar records the policy, selection mode, backfill flag, seed,
total capacity, group names and quotas, original and actual paths, and
per-tactic filtered, eligible, and retained counts. With backfill, it also
records the effective group capacities at dump. Record output is sorted by
input conclusion length; the retained set and output order are separate facts.

Keep the build commit, HOL Light version, executable identity, input proofs,
and invocation with the experiment. The sidecar cannot recover these facts
from a compiled executable.

## Tests and CI

```bash
make test-trace-sampling HOLLIGHT_DIR=/path/to/hol-light
```

The target compiles this checkout's collector into a fresh synthetic fixture.
It checks unconfigured deterministic defaults, explicit configuration and
sealing, shortest-first selection and first-arrival ties, one/three/five
groups, backfill, seeded reservoir selection, private RNG behavior, lazy
arguments, unchanged conversion retention, size filters, and output collisions.
These are collector tests, not a real s2n proof or description-quality experiment.

Each invocation preserves its build, sources, logs, and traces in a new
`tests/_trace_sampling/run-*` directory. `TRACE_SAMPLING_TEST_NATIVE` can point
the Python tests to one of these fresh fixtures; it is a test-harness setting.

`make test` includes the example, lazy-argument, and sampling suites. GitHub CI
runs them as explicit separate steps on Ubuntu and macOS and uploads sampling
logs even after a failure.
