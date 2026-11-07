#!/usr/bin/env bash
# Run an instrumented proof with sampling settings given on the command line.
set -eu

usage() {
    cat <<'USAGE'
Usage: bash run-with-sampling.sh [OPTIONS] -- COMMAND [ARG...]

  --trace-success-quotas CSV     Bucket quotas: 1 or 5 nonnegative entries
                                 with a positive total (default: 4,4,4,4,4)
  --trace-success-no-backfill    Stop buckets from borrowing each other's
                                 unused places (borrowing is on by default)
  --trace-output-root DIR        New absolute directory for this run (required)
  --dry-run                      Show the settings without running anything
  --help                         Show this help

COMMAND receives --tactictrace-config PATH, the file holding these settings.
It must be built from source that includes sampling_runtime.ml, which reads
that file before any proof code runs. After the command, the settings and the
collected output are checked against each other. DIR must not already exist.

Exit status:
  64      The runner rejected the options, DIR, COMMAND or its own setup;
          the command was not run
  1       The command ran, but its output does not match the settings
  other   The command failed; this is its own exit status
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 64
}

quotas=
quotas_set=false
backfill=1
output_root=
dry_run=false
separator=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace-success-quotas|--trace-output-root)
            [[ $# -ge 2 ]] || fail "$1 requires a value"
            case "$1" in
                --trace-success-quotas) quotas=$2; quotas_set=true ;;
                --trace-output-root) output_root=$2 ;;
            esac
            shift 2
            ;;
        --trace-success-no-backfill) backfill=0; shift ;;
        --dry-run) dry_run=true; shift ;;
        --help|-h) usage; exit 0 ;;
        --) separator=true; shift; break ;;
        *) fail "unknown option: $1 (put the command after --)" ;;
    esac
done
[[ "$separator" == true && $# -gt 0 ]] || fail 'provide -- COMMAND [ARG...]'

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
    if len(values) not in (1, 5) or sum(values) < 1:
        raise ValueError
except ValueError:
    sys.exit(1)
print(",".join(map(str, values)))
PYQUOTAS
    ) || fail 'quotas require 1 or 5 nonnegative integers with a positive total'
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
# Find the closest part of the path that exists; mkdir -p cannot go through a file.
ancestor=$(dirname -- "$output_root")
while [[ ! -e "$ancestor" && ! -L "$ancestor" ]]; do
    ancestor=$(dirname -- "$ancestor")
done
[[ -d "$ancestor" ]] ||
    fail "cannot create the output root: $ancestor is not a directory"

printf 'Bucket quotas: %s\nBorrowing: %s\n' "${quotas:-4,4,4,4,4 (default)}" \
    "$([[ "$backfill" == 1 ]] && echo on || echo off)"
printf 'Output root: %s\nCommand:' "$output_root"
printf ' %q' "$@"
printf '\n'
if [[ "$dry_run" == true ]]; then exit 0; fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
validator="$script_dir/check-sampling-output.py"
[[ -f "$validator" ]] || fail "sampling summary validator is missing: $validator"

# Look for the settings protocol inside a .native command before running it,
# so an executable that would ignore the settings and dump to its built-in path
# is refused rather than run. Other command forms can only be checked after.
python3 - "$1" "${@:2}" <<'PYGATE' || fail 'rebuild the proof with sampling_runtime.ml included'
from pathlib import Path
import shutil
import sys

if "--tactictrace-config" in sys.argv[2:]:
    raise SystemExit("--tactictrace-config is reserved for the runner")
command = Path(shutil.which(sys.argv[1]) or sys.argv[1])
if command.name.endswith(".native"):
    marker = b"tactictrace-sampling-config"
    try:
        with command.open("rb") as stream:
            overlap = b""
            while chunk := stream.read(1024 * 1024):
                data = overlap + chunk
                if marker in data:
                    break
                overlap = data[-len(marker):]
            else:
                raise SystemExit("native cannot read sampling settings")
    except OSError as exc:
        raise SystemExit(f"cannot inspect native: {exc}")
PYGATE

# mkdir is exclusive; failed runs retain their settings and partial output.
mkdir -p -- "$(dirname -- "$output_root")" && mkdir -- "$output_root" ||
    fail "cannot create the output root: $output_root"
output_root=$(cd -- "$output_root" && pwd -P)
config_file="$output_root/.tactictrace-config"
(umask 077; printf '%s\n' 'tactictrace-sampling-config' "$output_root" \
    "$quotas" "$backfill" > "$config_file")

code=0
"$@" --tactictrace-config "$config_file" || code=$?
if [[ "$code" -ne 0 ]]; then
    printf 'Command failed (%s). Partial output remains at %s\n' "$code" "$output_root" >&2
    exit "$code"
fi
if ! python3 "$validator" "$output_root" "$quotas" "$backfill"; then
    printf '%s\n' \
        'Use a proof rebuilt with the sampling collector; check for skipped targets or dump errors.' \
        "The output root has been kept: $output_root" >&2
    exit 1
fi
printf 'Sampling output saved under %s\n' "$output_root"
