#!/usr/bin/env bash
# Run an instrumented proof with explicit, versioned collector settings.
set -eu

usage() {
    cat <<'USAGE'
Usage: bash run-with-sampling.sh [OPTIONS] -- COMMAND [ARG...]

  --trace-sampling POLICY     stratified-reservoir (default and only policy)
  --selection-mode MODE       deterministic (default) or random
  --trace-sampling-seed N     Random-mode seed, 0..2147483647 (default: 0)
  --trace-success-quotas CSV  Stratified quotas: 1, 3, or 5 nonnegative entries
                             (default: 7,7,6 with this collector)
  --trace-success-backfill    Reuse unused quota in nonempty groups
  --trace-output-root DIR    New absolute directory for this run (required)
  --dry-run                  Show settings without running or creating files
  --help                     Show this help

COMMAND receives --tactictrace-config PATH. Rebuild the proof with the updated
collector and sampling_runtime.ml adapter; old .native files are rejected before
execution. A successful proof must acknowledge the config and write matching
sampling metadata under DIR. Existing destinations are refused.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 2
}

policy=stratified-reservoir
selection_mode=deterministic
seed=0
seed_set=false
quotas=
quotas_set=false
backfill=0
output_root=
dry_run=false
separator=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace-sampling|--selection-mode|--trace-sampling-seed|--trace-success-quotas|--trace-output-root)
            [[ $# -ge 2 ]] || fail "$1 requires a value"
            case "$1" in
                --trace-sampling) policy=$2 ;;
                --selection-mode) selection_mode=$2 ;;
                --trace-sampling-seed) seed=$2; seed_set=true ;;
                --trace-success-quotas) quotas=$2; quotas_set=true ;;
                --trace-output-root) output_root=$2 ;;
            esac
            shift 2
            ;;
        --trace-success-backfill) backfill=1; shift ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        --) separator=true; shift; break ;;
        *) fail "unknown option: $1 (put the command after --)" ;;
    esac
done
[[ "$separator" == true && $# -gt 0 ]] || fail 'provide -- COMMAND [ARG...]'

case "$policy" in
    stratified-reservoir) ;;
    *) fail "unknown sampling policy: $policy" ;;
esac
case "$selection_mode" in
    deterministic|random) ;;
    *) fail "unknown selection mode: $selection_mode" ;;
esac
if [[ "$seed_set" == true && "$selection_mode" != random ]]; then
    fail '--trace-sampling-seed requires --selection-mode random'
fi
[[ "$seed" =~ ^[0-9]+$ ]] || fail 'the seed must be a nonnegative decimal integer'
while [[ ${#seed} -gt 1 && "$seed" == 0* ]]; do seed=${seed#0}; done
if [[ ${#seed} -gt 10 ]] ||
   { [[ ${#seed} -eq 10 ]] && (( 10#$seed > 2147483647 )); }; then
    fail 'the seed must not exceed 2147483647'
fi
command -v python3 >/dev/null || fail 'Python 3 is required for validation'
if [[ "$quotas_set" == true ]]; then
    quotas=$(python3 - "$quotas" <<'PYQUOTAS'
import re
import sys
try:
    source = sys.argv[1]
    if not re.fullmatch(r"[0-9]+(?:,[0-9]+)*", source):
        raise ValueError
    values = [int(part) for part in source.split(",")]
    if len(values) not in (1, 3, 5) or any(value > 2147483647 for value in values):
        raise ValueError
    if not 1 <= sum(values) <= 2147483647:
        raise ValueError
except ValueError:
    sys.exit(1)
print(",".join(map(str, values)))
PYQUOTAS
    ) || fail 'quotas require 1, 3, or 5 nonnegative integers with total in 1..2147483647'
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

printf 'Policy: %s\nSelection mode: %s\nSeed: %s\n' "$policy" "$selection_mode" "$seed"
printf 'Success quotas: %s\nSuccess backfill: %s\n' "${quotas:-7,7,6 (default)}" "$backfill"
printf 'Output root: %s\nCommand:' "$output_root"
printf ' %q' "$@"
printf '\n'
if [[ "$dry_run" == true ]]; then exit 0; fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
validator="$script_dir/check-sampling-output.py"
[[ -f "$validator" ]] || fail "sampling metadata validator is missing: $validator"

# A capability probe must never execute an old native: that could run its whole
# proof and write the original trace path. Inspect direct .native commands only;
# other command forms must still acknowledge the protocol after execution.
python3 - "$1" "${@:2}" <<'PYGATE' || fail 'unsupported native: rebuild with the explicit sampling runtime adapter'
from pathlib import Path
import shutil
import sys

if "--tactictrace-config" in sys.argv[2:]:
    raise SystemExit("--tactictrace-config is reserved for the runner")
command = Path(shutil.which(sys.argv[1]) or sys.argv[1])
if command.name.endswith(".native"):
    marker = b"tactictrace-config-v2:explicit-noexec-probe"
    try:
        with command.open("rb") as stream:
            overlap = b""
            while chunk := stream.read(1024 * 1024):
                data = overlap + chunk
                if marker in data:
                    break
                overlap = data[-len(marker):]
            else:
                raise SystemExit("native lacks tactictrace-config-v2 support")
    except OSError as exc:
        raise SystemExit(f"cannot inspect native: {exc}")
PYGATE

# mkdir is exclusive; failed runs retain their settings and partial output.
mkdir -p -- "$(dirname -- "$output_root")"
mkdir -- "$output_root"
output_root=$(cd -- "$output_root" && pwd -P)
config_file="$output_root/.tactictrace-config"
(umask 077; printf '%s\n' 'tactictrace-config-v2' "$policy" "$seed" "$output_root" \
    "$quotas" "$backfill" "$selection_mode" > "$config_file")

code=0
"$@" --tactictrace-config "$config_file" || code=$?
if [[ "$code" -ne 0 ]]; then
    printf 'Command failed (%s). Partial output remains at %s\n' "$code" "$output_root" >&2
    exit "$code"
fi
if ! python3 "$validator" "$output_root" "$policy" "$seed" "$quotas" "$backfill" "$selection_mode"; then
    printf '%s\n' \
        'Use a proof rebuilt with the sampling collector; check for skipped targets or dump errors.' \
        "The output root has been kept: $output_root" >&2
    exit 1
fi
printf 'Sampling output saved under %s\n' "$output_root"
