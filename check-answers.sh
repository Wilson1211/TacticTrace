#!/bin/bash

# Compares the traces produced by `make test` against the expected traces that
# are checked into this repository.
#
# For each examples/<name>.answer directory, the traces that `make test` wrote
# to examples/<name>.outdir must match file-for-file. The expected traces store
# the HOL Light directory as the literal string $HOLLIGHT_DIR, so that they do
# not depend on where HOL Light happens to be checked out; this script performs
# the substitution on the generated traces before comparing.
#
# With --update, the collected traces are normalized the same way but written
# over examples/<name>.answer instead of compared against it, to accept an
# intended change in the trace format. Review the resulting diff before
# committing it.

update=0
case "${1:-}" in
  --update|-u) update=1 ;;
  '') ;;
  *)
    echo "usage: check-answers.sh [--update]" >&2
    exit 2
    ;;
esac

# The Makefile passes $HOLLIGHT_DIR in, but this script is also run by hand. Fall
# back to the same default the Makefile uses: this script lives in
# $HOLLIGHT_DIR/TacticTrace .
if [ -z "${HOLLIGHT_DIR:-}" ]; then
  HOLLIGHT_DIR=$(cd "$(dirname "$0")/.." && pwd)
fi

if [ ! -d "$HOLLIGHT_DIR" ]; then
  echo "HOLLIGHT_DIR is not a directory: $HOLLIGHT_DIR"
  echo "Please do 'export HOLLIGHT_DIR=<the path to your hol-light>'"
  exit 1
fi

# Collecting traces at all needs HOL Light built with HOLLIGHT_USE_MODULE=1.
# Without it there is nothing to compare, which is a failure rather than a pass.
if [ "$("$HOLLIGHT_DIR"/hol.sh -use-module)" != "1" ]; then
  echo "Error: HOL Light at $HOLLIGHT_DIR was not built with HOLLIGHT_USE_MODULE=1,"
  echo "       so no traces can be collected. Rebuild it with"
  echo "         HOLLIGHT_USE_MODULE=1 make"
  exit 1
fi

# $HOLLIGHT_DIR may be non-canonical (the Makefile passes '<...>/TacticTrace//..'),
# but the traces contain canonical paths, so canonicalize before substituting.
# Substitute both the logical and the physical form, since the two differ when
# the path to HOL Light goes through a symlink and it is not obvious which one
# ends up in the traces.
holdir=$(cd "$HOLLIGHT_DIR" && pwd)
holdir_physical=$(cd "$HOLLIGHT_DIR" && pwd -P)

# A template is given explicitly because BSD mktemp, as on MacOS, requires one.
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tactictrace.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

status=0

for answer in examples/*.answer; do
  name=$(basename "$answer" .answer)
  outdir=examples/$name.outdir

  if [ ! -d "$outdir" ]; then
    echo "FAIL $name: $outdir does not exist. Run 'make test' first."
    status=1
    continue
  fi

  # Normalize into the answer directory itself when updating, so that both modes
  # go through exactly one copy of the substitution.
  if [ $update -eq 1 ]; then
    dest=$answer
    rm -rf "$dest"
  else
    dest=$tmpdir/$name
  fi
  mkdir -p "$dest"

  for json in "$outdir"/*.json; do
    if [ ! -e "$json" ]; then
      echo "FAIL $name: $outdir contains no .json trace"
      status=1
      continue 2
    fi
    sed -e "s|$holdir_physical|\$HOLLIGHT_DIR|g" \
        -e "s|$holdir|\$HOLLIGHT_DIR|g" \
        "$json" > "$dest/$(basename "$json")"
  done

  if [ $update -eq 1 ]; then
    echo "UPDATED $answer"
  elif diff -r -u "$answer" "$dest"; then
    echo "PASS $name"
  else
    echo "FAIL $name: the generated traces differ from $answer"
    status=1
  fi
done

if [ $status -ne 0 ]; then
  :
elif [ $update -eq 1 ]; then
  echo "Expected traces updated. Review the diff before committing it."
else
  echo "All traces match the expected answers."
fi

exit $status
