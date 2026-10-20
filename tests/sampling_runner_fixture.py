"""Emulate an adapter-equipped collector for runner tests, without HOL Light."""

import json
from pathlib import Path
import sys


NAMES = {
    1: ["0+"],
    3: ["0", "1", "2+"],
    5: ["0", "1", "2", "3", "4+"],
}


def main():
    action = sys.argv[1]
    if action == "exit":
        return int(sys.argv[2])
    args = sys.argv[2:]
    assert args[-2] == "--tactictrace-config"
    config_path = Path(args[-1])
    version, policy, seed, output_root, quotas_csv, backfill, mode = config_path.read_text().splitlines()
    assert version == "tactictrace-config-v2"
    assert policy == "stratified-reservoir"
    root = Path(output_root)
    if action != "old":
        Path(str(config_path) + ".accepted").write_text(
            "tactictrace-config-v2:explicit-noexec-probe\n")
    if action == "fail":
        (root / "partial.txt").write_text("partial output")
        return 7
    if action == "incomplete":
        (root / "proof.sampling.json").touch()
        return 0
    if action not in ("collect", "mismatch", "old"):
        raise ValueError(f"unknown fixture action: {action}")

    quotas = [int(q) for q in quotas_csv.split(",")] if quotas_csv else [7, 7, 6]
    names = NAMES[len(quotas)]
    target = root / "proof"
    target.mkdir()
    seen = [20] * len(quotas)
    retained = list(quotas)
    if args and args[0] == "sparse" and quotas == [2, 2, 2] and backfill == "1":
        seen = [0, 5, 20]
        retained = [0, 3, 3]
    bucket_stats = [{"name": name, "eligible_seen": count, "retained": kept}
                    for name, count, kept in zip(names, seen, retained)]
    tactic_stats = {"filtered": 0, "buckets": bucket_stats}
    if backfill == "1":
        tactic_stats["effective_bucket_capacities"] = retained
    data = {
        "config": [version, policy, seed, output_root, quotas_csv, backfill, mode],
        "argv": args[:-2],
        "policy_version": 2,
        "policy": policy,
        "seed": int(seed),
        "selection_mode": mode,
        "backfill": backfill == "1",
        "total_capacity": sum(quotas),
        "bucket_names": names,
        "bucket_capacities": quotas,
        "actual_output_path": str(target),
        "tactics": {"sample": tactic_stats},
    }
    if action == "mismatch":
        changes = json.loads(args[0])
        if "actual_output_path" in changes:
            changes["actual_output_path"] = str(root / changes["actual_output_path"])
        if "tactic_change" in changes:
            key, value = changes.pop("tactic_change")
            data["tactics"]["sample"][key] = value
        data.update(changes)
    (root / "proof.sampling.json").write_text(json.dumps(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
