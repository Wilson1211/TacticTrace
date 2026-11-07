"""Stand in for a proof that reads sampling settings, without HOL Light."""

import json
from pathlib import Path
import sys


NAMES = {
    1: ["0+"],
    5: ["0", "1", "2", "3", "4+"],
}


def main():
    action = sys.argv[1]
    if action == "exit":
        return int(sys.argv[2])
    args = sys.argv[2:]
    assert args[-2] == "--tactictrace-config"
    config_path = Path(args[-1])
    header, output_dir, quotas_csv, backfill = config_path.read_text().splitlines()
    assert header == "tactictrace-sampling-config"
    # The runner keeps the settings next to the trace directory it names.
    root = config_path.parent
    target = Path(output_dir)
    assert target == root / "traces"
    # The sampling summary below must look exactly like a real one, so what this
    # stand-in received is reported separately for the tests to inspect.
    (root / "received.json").write_text(json.dumps(
        {"config": [header, output_dir, quotas_csv, backfill], "argv": args[:-2]}))
    if action != "unconfigured":
        Path(str(config_path) + ".accepted").write_text(
            "tactictrace-sampling-config\n")
    if action == "fail":
        (root / "partial.txt").write_text("partial output")
        return 7
    if action == "incomplete":
        (root / "traces.sampling.json").touch()
        return 0
    if action not in ("collect", "mismatch", "unconfigured"):
        raise ValueError(f"unknown fixture action: {action}")

    quotas = [int(q) for q in quotas_csv.split(",")] if quotas_csv else [4, 4, 4, 4, 4]
    names = NAMES[len(quotas)]
    target.mkdir()
    seen = [20] * len(quotas)
    retained = list(quotas)
    if args and args[0] == "sparse" and quotas == [2, 2, 2, 2, 2] and backfill == "1":
        seen = [0, 5, 20, 0, 0]
        retained = [0, 5, 5, 0, 0]
    tactics = {"sample": (seen, retained)}
    if args and args[0] == "unfilled" and quotas == [0, 2, 0, 0, 0]:
        # Records only in a bucket without places: nothing is kept, so a real
        # proof writes no file for this tactic.
        tactics["unfilled"] = ([3, 0, 0, 0, 0], [0, 0, 0, 0, 0])
    summary_tactics = {}
    for name, (tactic_seen, tactic_retained) in tactics.items():
        bucket_stats = [{"name": bucket, "eligible_seen": count, "retained": kept}
                        for bucket, count, kept in zip(names, tactic_seen, tactic_retained)]
        summary_tactics[name] = {"filtered": 0, "buckets": bucket_stats}
        if backfill == "1":
            summary_tactics[name]["effective_bucket_capacities"] = tactic_retained
        if sum(tactic_retained):
            # The same layout as a real trace file: a list with one object per record.
            (target / f"{name}.json").write_text(json.dumps(
                [{"tactic": name} for _ in range(sum(tactic_retained))]))
    data = {
        "backfill": backfill == "1",
        "total_capacity": sum(quotas),
        "bucket_names": names,
        "bucket_capacities": quotas,
        "output_dir": str(target),
        "tactics": summary_tactics,
    }
    if action == "mismatch":
        changes = json.loads(args[0])
        if "output_dir" in changes:
            changes["output_dir"] = str(root / changes["output_dir"])
        if "tactic_change" in changes:
            key, value = changes.pop("tactic_change")
            data["tactics"]["sample"][key] = value
        if "trace_count" in changes:
            # Write a different number of records than the summary reports.
            (target / "sample.json").write_text(json.dumps(
                [{"tactic": "sample"} for _ in range(changes.pop("trace_count"))]))
        if changes.pop("no_trace_file", False):
            (target / "sample.json").unlink()
        data.update(changes)
    (root / "traces.sampling.json").write_text(json.dumps(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
