"""Emulate the collector interface for wrapper tests, without HOL Light."""

import json
import os
from pathlib import Path
import sys


def main():
    action = sys.argv[1]
    if action == "exit":
        return int(sys.argv[2])

    root = Path(os.environ["TRACE_SAMPLING_OUTPUT_ROOT"])
    if action == "fail":
        (root / "partial.txt").write_text("partial output")
        return 7
    if action == "incomplete":
        (root / "proof.sampling.json").touch()
        return 0
    if action not in ("collect", "mismatch"):
        raise ValueError(f"unknown fixture action: {action}")

    data = {key: os.environ[key] for key in (
        "TRACE_SAMPLING_POLICY", "TRACE_SAMPLING_SEED", "TRACE_SAMPLING_OUTPUT_ROOT")}
    data["argv"] = sys.argv[2:]
    target = root / "proof"
    target.mkdir()
    data.update(policy_version=1, policy=data["TRACE_SAMPLING_POLICY"],
                seed=int(data["TRACE_SAMPLING_SEED"]), actual_output_path=str(target))
    if action == "mismatch":
        (root / "another").mkdir()
        changes = json.loads(sys.argv[2])
        if "actual_output_path" in changes:
            changes["actual_output_path"] = str(root / changes["actual_output_path"])
        data.update(changes)
    (root / "proof.sampling.json").write_text(json.dumps(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
