#!/usr/bin/env python3
"""Aggregate isolated shallow-versus-nested Match CPU and budget measurements."""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import statistics
import sys
from collections import defaultdict


IMPLEMENTATIONS = ("shallow", "nested")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("cpu_csv", type=pathlib.Path)
    parser.add_argument("budget_csv", type=pathlib.Path)
    parser.add_argument("--cases-out", required=True, type=pathlib.Path)
    return parser.parse_args()


def read_csv(path: pathlib.Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def geometric_mean(values: list[float]) -> float:
    if not values or any(value <= 0 for value in values):
        raise ValueError("geometric means require non-empty positive inputs")
    return math.exp(sum(math.log(value) for value in values) / len(values))


def float_text(value: float) -> str:
    return format(value, ".12g")


def integer(row: dict[str, str], name: str) -> int:
    return int(row[name])


def validate_metadata(rows: list[dict[str, str]], case_id: str) -> tuple[str, int, int]:
    metadata = {(row["family"], integer(row, "depth"), integer(row, "width")) for row in rows}
    if len(metadata) != 1:
        raise ValueError(f"inconsistent metadata for {case_id}: {sorted(metadata)!r}")
    return next(iter(metadata))


def main() -> None:
    args = parse_args()
    cpu_rows = read_csv(args.cpu_csv)
    budget_rows = read_csv(args.budget_csv)

    cpu_by_case: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in cpu_rows:
        cpu_by_case[(row["implementation"], row["case_id"])].append(row)

    budget_by_case: dict[tuple[str, str], dict[str, str]] = {}
    for row in budget_rows:
        key = (row["implementation"], row["case_id"])
        if key in budget_by_case:
            raise ValueError(f"duplicate budget row for {key!r}")
        budget_by_case[key] = row

    case_ids = sorted({case_id for _, case_id in cpu_by_case})
    if len(case_ids) != 27:
        raise ValueError(f"expected 27 cases, found {len(case_ids)}")

    cases: list[dict[str, object]] = []
    for case_id in case_ids:
        cpu: dict[str, dict[str, object]] = {}
        budgets: dict[str, dict[str, str]] = {}
        all_rows: list[dict[str, str]] = []
        for implementation in IMPLEMENTATIONS:
            rows = cpu_by_case.get((implementation, case_id), [])
            if len(rows) != 5:
                raise ValueError(
                    f"expected five CPU rows for {(implementation, case_id)!r}, found {len(rows)}"
                )
            repeats = {integer(row, "repeat") for row in rows}
            if repeats != {1, 2, 3, 4, 5}:
                raise ValueError(f"wrong repeats for {(implementation, case_id)!r}: {repeats!r}")
            means = [float(row["mean_seconds"]) for row in rows]
            cpu[implementation] = {
                "median": statistics.median(means),
                "minimum": min(means),
                "maximum": max(means),
            }
            all_rows.extend(rows)
            try:
                budgets[implementation] = budget_by_case[(implementation, case_id)]
            except KeyError as exc:
                raise ValueError(f"missing budget row for {(implementation, case_id)!r}") from exc

        family, depth, width = validate_metadata(all_rows + list(budgets.values()), case_id)
        shallow_time = float(cpu["shallow"]["median"])
        nested_time = float(cpu["nested"]["median"])
        shallow_budget_cpu = integer(budgets["shallow"], "cpu")
        nested_budget_cpu = integer(budgets["nested"], "cpu")
        shallow_budget_memory = integer(budgets["shallow"], "memory")
        nested_budget_memory = integer(budgets["nested"], "memory")
        cases.append(
            {
                "case_id": case_id,
                "family": family,
                "depth": depth,
                "width": width,
                "shallow_cpu_median_seconds": shallow_time,
                "nested_cpu_median_seconds": nested_time,
                "shallow_cpu_min_seconds": float(cpu["shallow"]["minimum"]),
                "shallow_cpu_max_seconds": float(cpu["shallow"]["maximum"]),
                "nested_cpu_min_seconds": float(cpu["nested"]["minimum"]),
                "nested_cpu_max_seconds": float(cpu["nested"]["maximum"]),
                "cpu_time_ratio_shallow_over_nested": shallow_time / nested_time,
                "cpu_speedup_shallow_over_nested": nested_time / shallow_time,
                "shallow_budget_cpu": shallow_budget_cpu,
                "nested_budget_cpu": nested_budget_cpu,
                "budget_cpu_ratio_shallow_over_nested": shallow_budget_cpu / nested_budget_cpu,
                "shallow_budget_memory": shallow_budget_memory,
                "nested_budget_memory": nested_budget_memory,
                "budget_memory_ratio_shallow_over_nested": (
                    shallow_budget_memory / nested_budget_memory
                ),
                "shallow_match_steps": integer(budgets["shallow"], "match_steps"),
                "shallow_match_work_steps": integer(
                    budgets["shallow"], "match_work_steps"
                ),
                "nested_match_steps": integer(budgets["nested"], "match_steps"),
                "nested_pattern_steps": integer(budgets["nested"], "pattern_steps"),
                "nested_structural_steps": integer(
                    budgets["nested"], "structural_steps"
                ),
                "nested_next_steps": integer(budgets["nested"], "next_steps"),
            }
        )

    cases.sort(key=lambda row: (str(row["family"]), int(row["depth"]), int(row["width"])))
    fieldnames = list(cases[0])
    with args.cases_out.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        for row in cases:
            writer.writerow(
                {
                    key: float_text(value) if isinstance(value, float) else value
                    for key, value in row.items()
                }
            )

    def group_summary(group_cases: list[dict[str, object]]) -> dict[str, object]:
        time_ratios = [float(row["cpu_time_ratio_shallow_over_nested"]) for row in group_cases]
        cpu_budget_ratios = [
            float(row["budget_cpu_ratio_shallow_over_nested"]) for row in group_cases
        ]
        memory_budget_ratios = [
            float(row["budget_memory_ratio_shallow_over_nested"]) for row in group_cases
        ]
        return {
            "case_count": len(group_cases),
            "shallow_faster_case_count": sum(ratio < 1 for ratio in time_ratios),
            "cpu_time_ratio_geometric_mean_shallow_over_nested": geometric_mean(time_ratios),
            "cpu_speedup_geometric_mean_shallow_over_nested": 1 / geometric_mean(time_ratios),
            "budget_cpu_ratio_geometric_mean_shallow_over_nested": geometric_mean(
                cpu_budget_ratios
            ),
            "budget_memory_ratio_geometric_mean_shallow_over_nested": geometric_mean(
                memory_budget_ratios
            ),
        }

    def grouped(name: str) -> dict[str, dict[str, object]]:
        values: dict[str, list[dict[str, object]]] = defaultdict(list)
        for row in cases:
            values[str(row[name])].append(row)
        return {key: group_summary(values[key]) for key in sorted(values)}

    def extreme(name: str, pick_maximum: bool) -> dict[str, object]:
        selected = (max if pick_maximum else min)(cases, key=lambda row: float(row[name]))
        return {"case_id": selected["case_id"], "value": selected[name]}

    summary = {
        "method": {
            "cpu_repeats_per_implementation_case": 5,
            "per_case_cpu_statistic": "median of Criterion Mean",
            "cross_case_statistic": "geometric mean of per-case ratios",
            "ratio_direction": "shallow / nested; values below 1 favor shallow",
        },
        "overall": group_summary(cases),
        "by_family": grouped("family"),
        "by_depth": grouped("depth"),
        "by_width": grouped("width"),
        "extremes": {
            "best_shallow_cpu_time_ratio": extreme(
                "cpu_time_ratio_shallow_over_nested", False
            ),
            "worst_shallow_cpu_time_ratio": extreme(
                "cpu_time_ratio_shallow_over_nested", True
            ),
            "lowest_shallow_budget_cpu_ratio": extreme(
                "budget_cpu_ratio_shallow_over_nested", False
            ),
            "highest_shallow_budget_cpu_ratio": extreme(
                "budget_cpu_ratio_shallow_over_nested", True
            ),
            "lowest_shallow_budget_memory_ratio": extreme(
                "budget_memory_ratio_shallow_over_nested", False
            ),
            "highest_shallow_budget_memory_ratio": extreme(
                "budget_memory_ratio_shallow_over_nested", True
            ),
        },
    }
    json.dump(summary, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        print(f"analyse.py: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
