#!/usr/bin/env python3
"""Validate an explicit TacticTrace run's acknowledgement and sidecars."""

import argparse
import json
from pathlib import Path
import sys


BUCKET_NAMES = {
    1: ["0+"],
    3: ["0", "1", "2+"],
    5: ["0", "1", "2", "3", "4+"],
}
CAPABILITY = "tactictrace-config-v2:explicit-noexec-probe\n"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def effective_quotas(quotas, seen):
    targets = [min(quota, count) for quota, count in zip(quotas, seen)]
    remaining = sum(quotas) - sum(targets)
    while remaining:
        active = [index for index, quota in enumerate(quotas)
                  if quota > 0 and targets[index] < seen[index]]
        if not active:
            break
        # Advance complete round-robin passes at once; metadata may report
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


def check_output(root, policy, seed, quotas, backfill, selection_mode):
    require(policy == "stratified-reservoir", "unsupported sampling policy")
    accepted = root / ".tactictrace-config.accepted"
    require(accepted.is_file() and accepted.read_text() == CAPABILITY,
            "native did not acknowledge explicit runtime configuration; rebuild it")
    sidecars = sorted(root.glob("*.sampling.json"))
    require(sidecars, "no sampling metadata was produced")
    for path in sidecars:
        data = json.loads(path.read_text())
        require(isinstance(data, dict), f"invalid sampling metadata: {path.name}")
        require(type(data["policy_version"]) is int and data["policy_version"] == 2 and
                data["policy"] == policy and type(data["seed"]) is int and
                data["seed"] == seed and data["selection_mode"] == selection_mode and
                type(data["backfill"]) is bool and data["backfill"] == backfill,
                f"sampling settings do not match: {path.name}")
        total = data["total_capacity"]
        require(type(total) is int and 1 <= total <= 2147483647,
                f"invalid total capacity: {path.name}")
        expected = quotas or [total // 3 + (index < total % 3) for index in range(3)]
        require(data["bucket_names"] == BUCKET_NAMES[len(expected)] and
                type(data["bucket_capacities"]) is list and
                all(type(value) is int for value in data["bucket_capacities"]) and
                data["bucket_capacities"] == expected and sum(expected) == total,
                f"success quota settings do not match: {path.name}")
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
        target = Path(data["actual_output_path"])
        require(target.parent == root and target.is_dir() and
                path == Path(str(target) + ".sampling.json"),
                f"invalid trace output path: {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_root", type=Path)
    parser.add_argument("policy", choices=("stratified-reservoir",))
    parser.add_argument("seed", type=int)
    parser.add_argument("quotas", help="comma-separated custom quotas, or empty for defaults")
    parser.add_argument("backfill", choices=("0", "1"))
    parser.add_argument("selection_mode", choices=("deterministic", "random"))
    args = parser.parse_args()
    try:
        quotas = [int(value) for value in args.quotas.split(",")] if args.quotas else None
        check_output(args.output_root, args.policy, args.seed, quotas,
                     args.backfill == "1", args.selection_mode)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Error: sampling completion check failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
