#!/usr/bin/env python3
"""Validate completion metadata for run-with-sampling.sh."""

import argparse
import json
from pathlib import Path
import sys


def check_output(root, policy, seed):
    sidecars = sorted(root.glob("*.sampling.json"))
    if not sidecars:
        raise ValueError("no sampling metadata was produced")
    for path in sidecars:
        data = json.loads(path.read_text())
        if data["policy_version"] != 1 or data["policy"] != policy or data["seed"] != seed:
            raise ValueError(f"sampling settings do not match: {path.name}")
        target = Path(data["actual_output_path"])
        if (target.parent != root or not target.is_dir()
                or path != Path(str(target) + ".sampling.json")):
            raise ValueError(f"invalid trace output path: {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_root", type=Path)
    parser.add_argument("policy", choices=("legacy", "stratified-reservoir"))
    parser.add_argument("seed", type=int)
    args = parser.parse_args()
    try:
        check_output(args.output_root, args.policy, args.seed)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Error: sampling completion check failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
