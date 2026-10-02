#!/usr/bin/env bash
# Run an instrumented proof with an explicit Stage 1 retention policy.
# Examples (the proof must be rebuilt with the selectable collector first):
#   bash run-with-sampling.sh --trace-output-root /tmp/legacy-run1 \
#     -- /path/to/proof.native
#   bash run-with-sampling.sh --trace-sampling stratified-reservoir \
#     --trace-sampling-seed 42 --trace-output-root /tmp/stratified-run1 \
#     -- /path/to/proof.native
# Add --dry-run before -- to check the command without creating files.
set -eu

usage() {
    cat <<'USAGE'
Usage: bash run-with-sampling.sh [OPTIONS] -- COMMAND [ARG...]

  --trace-sampling POLICY     legacy (default) or stratified-reservoir
  --trace-sampling-seed N     Decimal integer from 0 to 2147483647 (default: 0)
  --trace-output-root DIR    New absolute directory for this run (required)
  --dry-run                  Show settings without running or creating files
  --help                     Show this help

The new collector writes DIR/<original-dump-basename>/ and a sibling
<original-dump-basename>.sampling.json. An existing destination is refused.
This wrapper does not build proofs or change make's .correct cache rules.
Run it inside the container if the proof executable lives inside Docker.
Python 3 is used to validate the collector's completion metadata.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

# Defaults are explicit so an old exported policy cannot change a plain run.
policy=legacy
seed=0
output_root=
dry_run=false
separator=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace-sampling|--trace-sampling-seed|--trace-output-root)
            [[ $# -ge 2 ]] || fail "$1 requires a value"
            case "$1" in
                --trace-sampling) policy=$2 ;;
                --trace-sampling-seed) seed=$2 ;;
                --trace-output-root) output_root=$2 ;;
            esac
            shift 2
            ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        --) separator=true; shift; break ;;
        *) fail "unknown option: $1 (put the command after --)" ;;
    esac
done
[[ "$separator" == true && $# -gt 0 ]] || fail 'provide -- COMMAND [ARG...]'

# Validate before creating any directory or starting the proof.
case "$policy" in
    legacy|stratified-reservoir) ;;
    *) fail "unknown sampling policy: $policy" ;;
esac
[[ "$seed" =~ ^[0-9]+$ ]] || fail 'the seed must be a nonnegative decimal integer'
# Remove leading zeros before comparison; Bash otherwise treats them as octal.
while [[ ${#seed} -gt 1 && "$seed" == 0* ]]; do seed=${seed#0}; done
if [[ ${#seed} -gt 10 ]] ||
   { [[ ${#seed} -eq 10 ]] && (( 10#$seed > 2147483647 )); }; then
    fail 'the seed must not exceed 2147483647'
fi
[[ "$output_root" == /* ]] || fail '--trace-output-root must be an absolute path'
case "$output_root" in
    *$'\n'*|*$'\r'*) fail 'the output root must not contain newline or carriage-return characters' ;;
esac
while [[ "$output_root" != / && "$output_root" == */ ]]; do
    output_root=${output_root%/}
done
[[ ! -e "$output_root" && ! -L "$output_root" ]] ||
    fail "output root already exists; choose a new directory: $output_root"
case "$(basename -- "$output_root")" in
    .|..) fail 'the output root must name a new directory, not . or ..' ;;
esac

# A preview is safe even when the output parent has not been created yet.
printf 'Policy: %s\nSeed: %s\nOutput root: %s\nCommand:' "$policy" "$seed" "$output_root"
printf ' %q' "$@"
printf '\n'
if [[ "$dry_run" == true ]]; then exit 0; fi
command -v python3 >/dev/null || fail 'Python 3 is required to validate sampling metadata'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
validator="$script_dir/check-sampling-output.py"
[[ -f "$validator" ]] || fail "sampling metadata validator is missing: $validator"

# Reserve the root exclusively. Failed or interrupted runs are kept for review.
mkdir -p -- "$(dirname -- "$output_root")"
mkdir -- "$output_root"
output_root=$(cd -- "$output_root" && pwd -P)

# Override all three variables together, without changing the caller's shell.
# The command's failure is preserved, and no partial output is deleted.
code=0
env TRACE_SAMPLING_POLICY="$policy" TRACE_SAMPLING_SEED="$seed" \
    TRACE_SAMPLING_OUTPUT_ROOT="$output_root" "$@" || code=$?
if [[ "$code" -ne 0 ]]; then
    printf 'Command failed (%s). Partial output remains at %s\n' "$code" "$output_root" >&2
    exit "$code"
fi

# An old executable or a skipped make target must not look like a new experiment.
# Parse the sidecars too: a failed dump may have left an empty reservation file.
if ! python3 "$validator" "$output_root" "$policy" "$seed"; then
    printf '%s\n' \
        'Use a proof rebuilt with the selectable collector; check for skipped targets or dump errors.' \
        "The output root has been kept: $output_root" >&2
    exit 1
fi
printf 'Sampling output saved under %s\n' "$output_root"
