#!/usr/bin/env python3
"""Summarize latency harness runs (build/harness/runs/*.jsonl) by arm.

Latency uses every turn with a settled result. Headline word accuracy is pooled
(total word errors over total reference words) over English clips only;
code-switched and other-language clips vary legitimately in script and spelling,
so they are reported per language, with the share of transcripts that came back
romanized for a native-script reference. Each non-baseline arm is also compared with baseline
on paired turns: the same round and block position, so the same clip, gap, lead, and
tail. The confidence interval is a seeded bootstrap of the median paired difference.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNS = ROOT / "build" / "harness" / "runs"
BASELINE = "baseline"


def load(paths: list[Path]) -> list[dict]:
    rows = []
    for path in paths:
        for line in path.read_text().splitlines():
            if line.strip():
                rows.append(json.loads(line))
    return rows


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def numbers(rows: list[dict], key: str) -> list[float]:
    return [r[key] for r in rows if isinstance(r.get(key), (int, float))]


def settled(rows: list[dict]) -> list[dict]:
    return [r for r in rows if r.get("outcome") == "success"]


def is_english(row: dict) -> bool:
    return row.get("language", "en") == "en" and not row.get("code_switch")


def latin_share(text: str) -> float:
    letters = [ch for ch in text or "" if ch.isalpha()]
    if not letters:
        return 0.0
    return sum("LATIN" in unicodedata.name(ch, "") for ch in letters) / len(letters)


def romanized(row: dict) -> bool:
    return latin_share(row.get("hypothesis")) > 0.5 > latin_share(row.get("reference"))


def pooled_wer(rows: list[dict], english_only: bool = True) -> float | None:
    scored = [r for r in rows if r.get("accuracy") and (is_english(r) or not english_only)]
    words = sum(r["accuracy"]["reference_words"] for r in scored)
    if not words:
        return None
    errors = sum(r["accuracy"]["wer"] * r["accuracy"]["reference_words"] for r in scored)
    return errors / words


def miss_rate(rows: list[dict], key: str) -> float | None:
    scored = [r for r in rows if r.get("accuracy") and is_english(r)]
    if not scored:
        return None
    return sum(not r["accuracy"][key] for r in scored) / len(scored)


def arm_summary(rows: list[dict]) -> dict:
    ok = settled(rows)
    finalize = [r for r in ok if r.get("finalize_exit")]
    return {
        "turns": len(rows),
        "success": len(ok),
        "outcomes": dict(sorted(_count(r.get("outcome") or "-" for r in rows).items())),
        "total_median": median(numbers(ok, "total_ms")),
        "total_p95": percentile(numbers(ok, "total_ms"), 0.95),
        "roundtrip_median": median(numbers(ok, "roundtrip_ms")),
        "finalize_median": median(numbers(ok, "capture_finalize_ms")),
        "finalize_cap_share": (
            sum(r["finalize_exit"] == "cap" for r in finalize) / len(finalize) if finalize else None
        ),
        "capture_start_median": median(numbers(rows, "capture_start_ms")),
        "capture_start_p95": percentile(numbers(rows, "capture_start_ms"), 0.95),
        "warm_share": _share(rows, "mic_state_at_keydown", "warm"),
        "pooled_wer": pooled_wer(ok),
        "first_word_miss": miss_rate(ok, "first_word_hit"),
        "last_word_miss": miss_rate(ok, "last_word_hit"),
        "ambient_median": median(numbers(rows, "ambient_db")),
    }


def _count(values) -> dict:
    counts: dict = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return counts


def _share(rows: list[dict], key: str, value: str) -> float | None:
    known = [r for r in rows if r.get(key)]
    return sum(r[key] == value for r in known) / len(known) if known else None


def pair_key(row: dict) -> tuple:
    return (row["run_id"], row["round"], row["turn_in_block"])


def paired_deltas(rows: list[dict], arm: str, metric: str) -> list[float]:
    base = {pair_key(r): r for r in rows if r["arm"] == BASELINE and r.get("outcome") == "success"}
    deltas = []
    for row in rows:
        if row["arm"] != arm or row.get("outcome") != "success":
            continue
        other = base.get(pair_key(row))
        if other and isinstance(row.get(metric), (int, float)) and isinstance(
            other.get(metric), (int, float)
        ):
            deltas.append(row[metric] - other[metric])
    return deltas


def bootstrap_median_ci(values: list[float], resamples: int = 2000, seed: int = 38):
    if len(values) < 5:
        return None
    rng = random.Random(seed)
    medians = sorted(
        statistics.median(rng.choices(values, k=len(values))) for _ in range(resamples)
    )
    return medians[int(0.025 * resamples)], medians[int(0.975 * resamples) - 1]


def build_report(rows: list[dict]) -> dict:
    arms = sorted({r["arm"] for r in rows}, key=lambda a: (a != BASELINE, a))
    report = {
        "runs": sorted({r["run_id"] for r in rows}),
        "arms": {arm: arm_summary([r for r in rows if r["arm"] == arm]) for arm in arms},
        "capture_start_by_state": {},
        "paired": {},
        "wer_by_tts_model": {},
        "wer_by_accent": {},
        "by_language": {},
    }
    for arm in arms:
        for state in ("warm", "cold"):
            subset = [
                r for r in rows if r["arm"] == arm and r.get("mic_state_at_keydown") == state
            ]
            if subset:
                values = numbers(subset, "capture_start_ms")
                report["capture_start_by_state"][f"{arm}/{state}"] = {
                    "n": len(values),
                    "median": median(values),
                    "p95": percentile(values, 0.95),
                }
        if arm == BASELINE:
            continue
        for metric in ("total_ms", "capture_start_ms", "capture_finalize_ms", "roundtrip_ms"):
            deltas = paired_deltas(rows, arm, metric)
            if deltas:
                report["paired"][f"{arm}/{metric}"] = {
                    "pairs": len(deltas),
                    "median_delta": median(deltas),
                    "ci95": bootstrap_median_ci(deltas),
                }
    ok = settled(rows)
    for language in sorted({r.get("language", "en") for r in rows}):
        for switched in (False, True):
            subset = [r for r in rows if r.get("language", "en") == language
                      and bool(r.get("code_switch")) == switched]
            if not subset:
                continue
            done = settled(subset)
            label = f"{language}+code-switch" if switched else language
            report["by_language"][label] = {
                "turns": len(subset),
                "success": len(done),
                "total_median": median(numbers(done, "total_ms")),
                "pooled_wer": pooled_wer(done, english_only=False),
                "romanized_share": (
                    sum(romanized(r) for r in done) / len(done) if done else None
                ),
            }
    ok = [r for r in ok if is_english(r)]
    for key, target in (("tts_model", "wer_by_tts_model"), ("accent", "wer_by_accent")):
        for value in sorted({r.get(key) for r in ok if r.get(key)}):
            subset = [r for r in ok if r.get(key) == value]
            report[target][value] = {"turns": len(subset), "pooled_wer": pooled_wer(subset)}
    return report


def fmt(value, digits: int = 0, percent: bool = False) -> str:
    if value is None:
        return "-"
    if percent:
        return f"{value * 100:.1f}%"
    return f"{value:.{digits}f}"


def table(headers: list[str], rows: list[list[str]]) -> str:
    widths = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h)
              for i, h in enumerate(headers)]
    lines = ["  ".join(h.ljust(w) for h, w in zip(headers, widths)),
             "  ".join("-" * w for w in widths)]
    lines += ["  ".join(c.ljust(w) for c, w in zip(row, widths)) for row in rows]
    return "\n".join("  " + line for line in lines)


def render(report: dict) -> str:
    out = [f"Tok harness report: {len(report['runs'])} run(s)", ""]
    arms = report["arms"]
    out.append("Latency by arm (settled turns):")
    out.append(table(
        ["arm", "turns", "ok", "total med", "total p95", "roundtrip", "finalize", "cap %",
         "start med", "start p95", "warm %", "ambient"],
        [[a, str(s["turns"]), str(s["success"]), fmt(s["total_median"]), fmt(s["total_p95"]),
          fmt(s["roundtrip_median"]), fmt(s["finalize_median"]),
          fmt(s["finalize_cap_share"], percent=True), fmt(s["capture_start_median"]),
          fmt(s["capture_start_p95"]), fmt(s["warm_share"], percent=True),
          fmt(s["ambient_median"], 1)] for a, s in arms.items()]))
    out.append("")
    out.append("Word accuracy by arm (pooled, English clips only):")
    out.append(table(
        ["arm", "WER", "first word missed", "last word missed", "outcomes"],
        [[a, fmt(s["pooled_wer"], percent=True), fmt(s["first_word_miss"], percent=True),
          fmt(s["last_word_miss"], percent=True),
          " ".join(f"{k}={v}" for k, v in s["outcomes"].items())] for a, s in arms.items()]))
    out.append("")
    out.append("Capture start by microphone state at key-down:")
    out.append(table(
        ["arm/state", "n", "median", "p95"],
        [[k, str(v["n"]), fmt(v["median"]), fmt(v["p95"])]
         for k, v in report["capture_start_by_state"].items()]))
    if report["paired"]:
        out.append("")
        out.append("Paired against baseline (same clip, gap, lead, tail; arm minus baseline, ms):")
        out.append(table(
            ["arm/metric", "pairs", "median delta", "95% CI"],
            [[k, str(v["pairs"]), fmt(v["median_delta"]),
              "-" if not v["ci95"] else f"{v['ci95'][0]:.0f} to {v['ci95'][1]:.0f}"]
             for k, v in report["paired"].items()]))
    out.append("")
    if report["by_language"]:
        out.append("By language (all arms; WER in the reference script):")
        out.append(table(
            ["language", "turns", "ok", "total med", "WER", "romanized"],
            [[k, str(v["turns"]), str(v["success"]), fmt(v["total_median"]),
              fmt(v["pooled_wer"], percent=True), fmt(v["romanized_share"], percent=True)]
             for k, v in report["by_language"].items()]))
        out.append("")
    out.append("Pooled WER by TTS model and accent (English clips, all arms):")
    out.append(table(
        ["group", "turns", "WER"],
        [[k, str(v["turns"]), fmt(v["pooled_wer"], percent=True)]
         for k, v in {**report["wer_by_tts_model"], **report["wer_by_accent"]}.items()]))
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run", action="append", help="run id (repeatable); default all runs")
    parser.add_argument("--min-turns", type=int, default=0,
                        help="skip runs with fewer turns (drops smoke runs)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    paths = (
        [RUNS / f"{run}.jsonl" for run in args.run] if args.run else sorted(RUNS.glob("*.jsonl"))
    )
    missing = [p for p in paths if not p.exists()]
    if missing:
        sys.exit(f"missing run file: {missing[0]}")
    rows = []
    for path in paths:
        run_rows = load([path])
        if len(run_rows) >= args.min_turns:
            rows.extend(run_rows)
    if not rows:
        sys.exit("no harness rows found")
    report = build_report(rows)
    print(json.dumps(report, indent=2) if args.json else render(report), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
