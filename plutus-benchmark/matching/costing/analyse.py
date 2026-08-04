#!/usr/bin/env python3
"""Fit shallow Match calibration pairs using only the Python standard library."""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import sys
from collections import defaultdict


# One-sided 95% Student-t critical values.  Linear fits have n-2 degrees of freedom.
T95 = {
    1: 6.314,
    2: 2.920,
    3: 2.353,
    4: 2.132,
    5: 2.015,
    6: 1.943,
    7: 1.895,
    8: 1.860,
    9: 1.833,
    10: 1.812,
    11: 1.796,
    12: 1.782,
    15: 1.753,
    20: 1.725,
    30: 1.697,
    60: 1.671,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Join matching-costing metadata to Criterion CSV, fit each paired family, "
            "and recommend conservative CPU costs in picoseconds."
        )
    )
    parser.add_argument("metadata", type=pathlib.Path)
    parser.add_argument("criterion_csv", type=pathlib.Path)
    parser.add_argument(
        "--machine-costs",
        type=pathlib.Path,
        help="CEK JSON supplying the Case and LamAbs CPU costs used for subtraction",
    )
    parser.add_argument("--case-cost-ps", type=float)
    parser.add_argument("--lam-cost-ps", type=float)
    parser.add_argument("--min-r2", type=float, default=0.95)
    return parser.parse_args()


def read_csv(path: pathlib.Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def normalized(row: dict[str, str]) -> dict[str, str]:
    return {key.strip().lower().replace("_", ""): value for key, value in row.items()}


def number(row: dict[str, str], *names: str) -> float:
    normalized_row = normalized(row)
    for name in names:
        key = name.lower().replace("_", "")
        if key in normalized_row and normalized_row[key] != "":
            return float(normalized_row[key])
    raise ValueError(f"none of columns {names!r} occurs in row {row!r}")


def text_column(row: dict[str, str], name: str) -> str:
    normalized_row = normalized(row)
    key = name.lower().replace("_", "")
    if key not in normalized_row:
        raise ValueError(f"column {name!r} does not occur in row {row!r}")
    return normalized_row[key]


def load_known_costs(args: argparse.Namespace) -> tuple[float, float]:
    case_cost = args.case_cost_ps
    lam_cost = args.lam_cost_ps
    if args.machine_costs:
        with args.machine_costs.open(encoding="utf-8") as handle:
            costs = json.load(handle)
        if case_cost is None:
            case_cost = float(costs["cekCaseCost"]["exBudgetCPU"])
        if lam_cost is None:
            case_cost_key = "cekLamCost"
            lam_cost = float(costs[case_cost_key]["exBudgetCPU"])
    if case_cost is None or lam_cost is None:
        raise ValueError(
            "provide --machine-costs or both --case-cost-ps and --lam-cost-ps"
        )
    return case_cost, lam_cost


def timing_for_name(
    name: str, timing_rows: list[dict[str, str]]
) -> dict[str, str]:
    exact = [row for row in timing_rows if text_column(row, "name") == name]
    if len(exact) == 1:
        return exact[0]
    # Criterion can prepend a benchmark group.  Permit one unambiguous suffix match, but never
    # silently join two rows.
    suffix = [
        row
        for row in timing_rows
        if text_column(row, "name").endswith("/" + name)
    ]
    if len(suffix) == 1:
        return suffix[0]
    raise ValueError(f"expected one Criterion row for {name!r}, found {len(exact) or len(suffix)}")


def t95(df: int) -> float:
    if df in T95:
        return T95[df]
    lower_keys = [key for key in T95 if key <= df]
    if not lower_keys:
        return T95[1]
    if df > 60:
        return 1.645
    return T95[max(lower_keys)]


def linear_fit(points: list[dict[str, float]]) -> dict[str, float]:
    if len(points) < 3:
        raise ValueError("at least three paired sizes are required for a slope confidence bound")
    xs = [point["x"] for point in points]
    ys = [point["y_ps"] for point in points]
    x_mean = sum(xs) / len(xs)
    y_mean = sum(ys) / len(ys)
    sxx = sum((x - x_mean) ** 2 for x in xs)
    if sxx == 0:
        raise ValueError("paired family has no variation in charged units")
    slope = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / sxx
    intercept = y_mean - slope * x_mean
    residuals = [y - (intercept + slope * x) for x, y in zip(xs, ys)]
    sse = sum(residual * residual for residual in residuals)
    sst = sum((y - y_mean) ** 2 for y in ys)
    r_squared = 1.0 if sst == 0 and sse == 0 else (0.0 if sst == 0 else 1.0 - sse / sst)
    slope_se = math.sqrt((sse / (len(points) - 2)) / sxx)
    upper = slope + t95(len(points) - 2) * slope_se
    return {
        "slope_ps": slope,
        "intercept_ps": intercept,
        "r_squared": r_squared,
        "slope_standard_error_ps": slope_se,
        "upper_slope_ps": upper,
    }


def main() -> None:
    args = parse_args()
    case_cost, lam_cost = load_known_costs(args)
    metadata_rows = read_csv(args.metadata)
    timing_rows = read_csv(args.criterion_csv)

    paired: dict[tuple[str, int], dict[str, dict[str, str]]] = defaultdict(dict)
    for row in metadata_rows:
        family = text_column(row, "family")
        units = int(text_column(row, "units"))
        role = text_column(row, "role")
        paired[(family, units)][role] = row

    families: dict[str, list[dict[str, float]]] = defaultdict(list)
    targets: dict[str, str] = {}
    for (family, units), roles in sorted(paired.items()):
        if set(roles) != {"control", "work"}:
            raise ValueError(f"{family}/{units} does not have exactly control and work metadata")
        control_meta = roles["control"]
        work_meta = roles["work"]
        target = text_column(work_meta, "target")
        if target != text_column(control_meta, "target"):
            raise ValueError(f"{family}/{units} has inconsistent targets")
        targets.setdefault(family, target)
        if targets[family] != target:
            raise ValueError(f"{family} changes target between sizes")

        control_timing = timing_for_name(text_column(control_meta, "name"), timing_rows)
        work_timing = timing_for_name(text_column(work_meta, "name"), timing_rows)
        mean_delta_ps = (
            number(work_timing, "mean") - number(control_timing, "mean")
        ) * 1e12
        known_delta_ps = (
            (number(work_meta, "bcase") - number(control_meta, "bcase")) * case_cost
            + (number(work_meta, "blamabs") - number(control_meta, "blamabs"))
            * lam_cost
        )
        adjusted_ps = mean_delta_ps - known_delta_ps
        delta_match = number(work_meta, "bmatch") - number(control_meta, "bmatch")
        delta_work = number(work_meta, "bmatchwork") - number(control_meta, "bmatchwork")
        if target == "match":
            if delta_match <= 0 or delta_work != 0:
                raise ValueError(f"{family}/{units} is not a pure BMatch design row")
            x = delta_match
        elif target == "match_work":
            if delta_work <= 0 or delta_match != 0:
                raise ValueError(f"{family}/{units} is not a pure BMatchWork design row")
            x = delta_work
        elif target == "audit":
            x = float(units)
        else:
            raise ValueError(f"unknown target {target!r} in {family}/{units}")
        families[family].append(
            {
                "units": float(units),
                "x": x,
                "raw_delta_ps": mean_delta_ps,
                "known_step_delta_ps": known_delta_ps,
                "y_ps": adjusted_ps,
            }
        )

    fits = []
    accepted_by_target: dict[str, list[float]] = defaultdict(list)
    for family in sorted(families):
        points = sorted(families[family], key=lambda point: point["x"])
        fit = linear_fit(points)
        target = targets[family]
        accepted = (
            target in {"match", "match_work"}
            and fit["slope_ps"] >= 0
            and fit["upper_slope_ps"] >= 0
            and fit["r_squared"] >= args.min_r2
        )
        reason = None
        if target == "audit":
            reason = "audit-only"
        elif fit["slope_ps"] < 0 or fit["upper_slope_ps"] < 0:
            reason = "negative-slope"
        elif fit["r_squared"] < args.min_r2:
            reason = "r-squared-below-threshold"
        if accepted:
            accepted_by_target[target].append(fit["upper_slope_ps"])
        fits.append(
            {
                "family": family,
                "target": target,
                **fit,
                "accepted": accepted,
                "rejection_reason": reason,
                "points": points,
            }
        )

    recommendations = {}
    for target in ("match", "match_work"):
        uppers = accepted_by_target[target]
        recommendations[target] = math.ceil(max(uppers)) if uppers else None

    json.dump(
        {
            "units": "picoseconds",
            "known_costs": {"case": case_cost, "lam_abs": lam_cost},
            "minimum_r_squared": args.min_r2,
            "fits": fits,
            "recommendations": recommendations,
            "selection_rule": "ceil(max accepted one-sided-95%-upper slope)",
        },
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        print(f"analyse.py: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
