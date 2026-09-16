#!/bin/bash

# Compares the traces produced by `make test` against the expected traces that
# are checked into this repository.
#
# For each examples/<name>.answer directory, the traces that `make test` wrote
# to examples/<name>.outdir must match file-for-file. The expected traces store
# the HOL Light directory as the literal string $HOLLIGHT_DIR, so that they do
# not depend on where HOL Light happens to be checked out; this script performs
# the substitution on the generated traces before comparing.

if [ ! -d "$HOLLIGHT_DIR" ]; then
  echo "HOLLIGHT_DIR is not set: $HOLLIGHT_DIR"
  echo "Please do 'export HOLLIGHT_DIR=<the path to your hol-light>'"
  exit 1
fi

# $HOLLIGHT_DIR may be non-canonical (the Makefile passes '<...>/TacticTrace//..'),
# but the traces contain canonical paths, so canonicalize before substituting.
holdir=$(cd "$HOLLIGHT_DIR" && pwd)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

status=0

for answer in examples/*.answer; do
  name=$(basename "$answer" .answer)
  outdir=examples/$name.outdir

  if [ ! -d "$outdir" ]; then
    echo "FAIL $name: $outdir does not exist."
    echo "     Run 'make test' first, and note that it is a no-op unless HOL"
    echo "     Light was built with HOLLIGHT_USE_MODULE=1."
    status=1
    continue
  fi

  mkdir -p "$tmpdir/$name"
  for json in "$outdir"/*.json; do
    if [ ! -e "$json" ]; then
      echo "FAIL $name: $outdir contains no .json trace"
      status=1
      continue 2
    fi
    sed "s|$holdir|\$HOLLIGHT_DIR|g" "$json" > "$tmpdir/$name/$(basename "$json")"
  done

  if diff -r -u "$answer" "$tmpdir/$name"; then
    echo "PASS $name"
  else
    echo "FAIL $name: the generated traces differ from $answer"
    status=1
  fi
done

if [ $status -eq 0 ]; then
  echo "All traces match the expected answers."
fi

exit $status
