#!/usr/bin/env python3
"""Check that a sampling run accepted its settings and matches its output."""

import argparse
import json
from pathlib import Path
import sys


BUCKET_NAMES = {
    1: ["0+"],
    5: ["0", "1", "2", "3", "4+"],
}
ACCEPTANCE = "tactictrace-sampling-config\n"
SUMMARY_KEYS = {"backfill", "total_capacity", "bucket_names", "bucket_capacities",
                "output_dir", "tactics"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def effective_quotas(quotas, seen):
    """Mirror the collector's borrowing, independently of the collector."""
    targets = [min(quota, count) for quota, count in zip(quotas, seen)]
    remaining = sum(quotas) - sum(targets)
    while remaining:
        active = [index for index, quota in enumerate(quotas)
                  if quota > 0 and targets[index] < seen[index]]
        if not active:
            break
        # Advance complete round-robin passes at once; a sampling summary may report
        # very large counts, so validation must not loop once per record.
        rounds = min(remaining // len(active),
                     min(seen[index] - targets[index] for index in active))
        if rounds:
            for index in active:
                targets[index] += rounds
            remaining -= rounds * len(active)
        else:
            for index in active[:remaining]:
                targets[index] += 1
                remaining -= 1
    return targets


def count_records(path):
    """Count the records in a trace file: one object per entry of its list."""
    text = path.read_text()
    try:
        records = json.loads(text)
    except ValueError:
        # OCaml's String.escaped can write escapes that JSON does not have.
        # Each record opens with a line holding only "  {" at the top level.
        return text.splitlines().count("  {")
    require(isinstance(records, list), f"invalid trace file: {path.name}")
    return len(records)


def check_output(root, quotas, backfill):
    accepted = root / ".tactictrace-config.accepted"
    require(accepted.is_file() and accepted.read_text() == ACCEPTANCE,
            "the command did not accept the sampling settings; rebuild it with "
            "sampling_runtime.ml included")
    # The runner sends the traces to <root>/traces and nowhere else.
    path = root / "traces.sampling.json"
    require(path.is_file(), "no sampling summary was produced")
    require(sorted(root.glob("*.sampling.json")) == [path],
            "expected exactly one sampling summary, traces.sampling.json")
    data = json.loads(path.read_text())
    require(isinstance(data, dict), f"invalid sampling summary: {path.name}")
    require(set(data) == SUMMARY_KEYS,
            f"unexpected sampling summary fields: {path.name}")
    require(type(data["backfill"]) is bool and data["backfill"] == backfill,
            f"sampling settings do not match: {path.name}")
    total = data["total_capacity"]
    require(type(total) is int and total >= 1,
            f"invalid total capacity: {path.name}")
    expected = quotas or [total // 5 + (index < total % 5) for index in range(5)]
    require(data["bucket_names"] == BUCKET_NAMES[len(expected)] and
            type(data["bucket_capacities"]) is list and
            all(type(value) is int for value in data["bucket_capacities"]) and
            data["bucket_capacities"] == expected and sum(expected) == total,
            f"bucket quota settings do not match: {path.name}")
    target = Path(data["output_dir"])
    require(target == root / "traces" and target.is_dir(),
            f"invalid trace output directory: {path.name}")
    tactics = data["tactics"]
    require(isinstance(tactics, dict), f"invalid tactic counters: {path.name}")
    for name, stats in tactics.items():
        buckets = stats["buckets"]
        require(type(buckets) is list and len(buckets) == len(expected),
                f"invalid bucket counters: {path.name}:{name}")
        seen = []
        retained = []
        for bucket, bucket_name in zip(buckets, BUCKET_NAMES[len(expected)]):
            require(bucket["name"] == bucket_name and
                    type(bucket["eligible_seen"]) is int and
                    bucket["eligible_seen"] >= 0 and
                    type(bucket["retained"]) is int and bucket["retained"] >= 0,
                    f"invalid bucket counters: {path.name}:{name}")
            seen.append(bucket["eligible_seen"])
            retained.append(bucket["retained"])
        targets = effective_quotas(expected, seen) if backfill else [
            min(quota, count) for quota, count in zip(expected, seen)]
        require(retained == targets,
                f"retention counts do not match: {path.name}:{name}")
        if backfill:
            require(stats["effective_bucket_capacities"] == targets,
                    f"effective quotas do not match: {path.name}:{name}")
        # The dump writes <tactic>.json only for a tactic that kept at
        # least one record, so a missing file means zero records.
        trace_file = target / f"{name}.json"
        records = count_records(trace_file) if trace_file.is_file() else 0
        require(records == sum(retained),
                f"{trace_file} has {records} records, "
                f"but the summary reports {sum(retained)} retained")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="the runner's output directory")
    parser.add_argument("quotas", help="comma-separated custom quotas, or empty for defaults")
    parser.add_argument("backfill", choices=("0", "1"))
    args = parser.parse_args()
    try:
        quotas = [int(value) for value in args.quotas.split(",")] if args.quotas else None
        check_output(args.root, quotas, args.backfill == "1")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Error: sampling completion check failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
