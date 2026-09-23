#!/usr/bin/env python3
"""Turn latency report over Tok's history.db.

Reads dictation turns from the local SQLite history database and prints
latency and outcome breakdowns. Every query is built only from an explicit
allow-list of metadata columns (timings, counters, enum labels, ids); no
free-text content column (transcript text, corrections, app identity, raw
error strings) is ever placed in a query or printed. The database is opened
read-only (sqlite URI mode=ro) and again marked query-only after opening.

Older databases may not have every metric or grouping column yet. The script
reads PRAGMA table_info(transcriptions) first and silently skips any metric
or grouping that references a missing column, printing one note line per
skip instead of failing.

Percentile and median definitions:
  - median: statistics.median (the mean of the two middle values for an
    even sample size).
  - p95: nearest-rank. Values are sorted ascending and the p95 is the value
    at rank ceil(0.95 * n), 1-indexed, so p95 always equals an observed
    value rather than an interpolation.
"""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

DEFAULT_DB = Path.home() / "Library/Application Support/Tok/history.db"

# Columns that must never be selected, printed, or embedded in a query,
# under any circumstance. This list is enforced twice: statically, by
# asserting it is disjoint from every allow-list below, and dynamically, by
# a test that captures every SQL string this module issues and checks none
# of these names appear in it.
DENIED_COLUMNS = frozenset(
    {
        "text",
        "wrong_text",
        "right_text",
        "app_name",
        "app_bundle_id",
        "input_device",
        "error",
        "post_process_error",
        "post_process_app_context",
        # A free-text description of why a Live turn fell back (can quote
        # transport errors), not a short enum. Never select it.
        "fallback_reason",
    }
)

# Every column the report may ever reference on the transcriptions table.
# Nothing outside this list is ever interpolated into a query. Filter and
# grouping columns are metadata (ids, timings, counters, short enum labels)
# only; no free-text content column belongs here.
TRANSCRIPTIONS_ALLOWED_COLUMNS = (
    "id",
    "ts_utc",
    "ts_epoch",
    "outcome",
    "is_live_route",
    "delivery_outcome",
    "post_process_status",
    "build_id",
    "experiment_tag",
    "audio_seconds",
    "total_ms",
    "roundtrip_ms",
    "capture_finalize_ms",
    "capture_start_ms",
    "inject_ms",
    "trail_wait_ms",
    "finalize_drain_ms",
    "commit_to_first_msg_ms",
    "commit_to_final_ms",
    "commit_to_turn_complete_ms",
    "commit_to_last_send_ms",
    "endpoint_aligned",
    "silence_flush_ms",
    "chunk_ms",
    "mic_state_at_keydown",
    "finalize_exit",
    "settle_path",
    "socket_state_at_keydown",
    "hedge_winner",
    "quiet_resets",
    "trail_peak_db",
    "noise_floor_db",
    "key_down_epoch",
    "key_up_epoch",
)

# Every column the report may ever reference on connection_events.
CONNECTION_EVENTS_ALLOWED_COLUMNS = (
    "kind",
    "ts_epoch",
    "ts_utc",
    "turn_open",
)

assert DENIED_COLUMNS.isdisjoint(TRANSCRIPTIONS_ALLOWED_COLUMNS)
assert DENIED_COLUMNS.isdisjoint(CONNECTION_EVENTS_ALLOWED_COLUMNS)

METRIC_COLUMNS = (
    "total_ms",
    "roundtrip_ms",
    "capture_finalize_ms",
    "capture_start_ms",
    "inject_ms",
    "trail_wait_ms",
    "finalize_drain_ms",
    "commit_to_first_msg_ms",
    "commit_to_final_ms",
    "commit_to_turn_complete_ms",
    "commit_to_last_send_ms",
)

GROUP_COLUMNS = (
    "build_id",
    "experiment_tag",
    "endpoint_aligned",
    "silence_flush_ms",
    "chunk_ms",
    "mic_state_at_keydown",
    "finalize_exit",
    "settle_path",
    "socket_state_at_keydown",
    "hedge_winner",
)

TAIL_COLUMNS = (
    "id",
    "total_ms",
    "capture_finalize_ms",
    "roundtrip_ms",
    "audio_seconds",
    "finalize_exit",
    "quiet_resets",
    "trail_peak_db",
    "noise_floor_db",
    "settle_path",
    "mic_state_at_keydown",
)

for _columns in (METRIC_COLUMNS, GROUP_COLUMNS, TAIL_COLUMNS):
    assert set(_columns) <= set(TRANSCRIPTIONS_ALLOWED_COLUMNS)
    assert DENIED_COLUMNS.isdisjoint(_columns)

WARM_WINDOW_THRESHOLDS_S = (60, 90, 300)
AUDIO_BUCKETS = ("<2s", "2-5s", "5-15s", "15+s")

# Every SQL string executed through open_db()'s connection lands here. A
# test scans this log for denied column names after driving the report
# end to end.
EXECUTED_SQL: list[str] = []


def reset_sql_log() -> None:
    EXECUTED_SQL.clear()


def open_db(path: Path) -> sqlite3.Connection:
    resolved = Path(path).resolve()
    # Percent-encode the path so a space (for example "Application
    # Support") or a "?"/"#" in a --db override cannot be misread as the
    # start of the URI's query string or fragment.
    uri = f"file:{quote(str(resolved))}?mode=ro"
    try:
        # mode=ro never creates the file, and an explicit timeout gives a
        # locked/busy database a bounded retry window instead of failing
        # (or hanging) immediately.
        conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    except sqlite3.OperationalError as error:
        raise SystemExit(f"Could not open {resolved} read-only: {error}") from error
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only = ON")
    conn.set_trace_callback(EXECUTED_SQL.append)
    return conn


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()
    return row is not None


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    if table not in ("transcriptions", "connection_events"):
        raise ValueError(f"Unsupported table: {table}")
    if not table_exists(conn, table):
        return set()
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {row["name"] for row in rows}


def nearest_rank_p95(values: list[float]) -> float:
    ordered = sorted(values)
    n = len(ordered)
    rank = max(1, min(n, math.ceil(0.95 * n)))
    return ordered[rank - 1]


def parse_since(value: str) -> float:
    try:
        day = datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            f"--since expects YYYY-MM-DD, got {value!r}"
        ) from error
    return day.timestamp()


def build_cohort_where(
    available: set[str], args: argparse.Namespace
) -> tuple[str, list[object], list[str]]:
    clauses: list[str] = []
    params: list[object] = []
    notes: list[str] = []

    if not args.all_outcomes:
        if "outcome" in available:
            clauses.append("outcome = ?")
            params.append("success")
        else:
            notes.append("Note: 'outcome' column missing; not filtering by outcome.")
        if "delivery_outcome" in available:
            clauses.append("delivery_outcome = ?")
            params.append("dispatched")
        else:
            notes.append(
                "Note: 'delivery_outcome' column missing; not filtering by delivery outcome."
            )
        if "is_live_route" in available:
            clauses.append("is_live_route = 1")
        else:
            notes.append(
                "Note: 'is_live_route' column missing; not filtering by live route."
            )
        if "post_process_status" in available:
            clauses.append("(post_process_status IS NULL OR post_process_status = ?)")
            params.append("off")
        else:
            notes.append(
                "Note: 'post_process_status' column missing; not filtering by post-process status."
            )

    if args.build:
        if "build_id" in available:
            clauses.append("build_id LIKE ?")
            params.append(args.build + "%")
        else:
            notes.append("Note: 'build_id' column missing; --build filter ignored.")

    if args.since is not None:
        if "ts_epoch" in available:
            clauses.append("ts_epoch >= ?")
            params.append(args.since)
        else:
            notes.append("Note: 'ts_epoch' column missing; --since filter ignored.")

    if args.tag:
        if "experiment_tag" in available:
            clauses.append("experiment_tag = ?")
            params.append(args.tag)
        else:
            notes.append("Note: 'experiment_tag' column missing; --tag filter ignored.")

    where_sql = " AND ".join(clauses) if clauses else "1 = 1"
    return where_sql, params, notes


def cohort_count(conn: sqlite3.Connection, where_sql: str, params: list[object]) -> int:
    row = conn.execute(
        f"SELECT COUNT(*) AS n FROM transcriptions WHERE {where_sql}", params
    ).fetchone()
    return row["n"]


def outcome_counts(
    conn: sqlite3.Connection,
    available: set[str],
    where_sql: str,
    params: list[object],
) -> tuple[dict[str, int] | None, list[str]]:
    if "outcome" not in available:
        return None, ["Note: 'outcome' column missing; cannot show outcome counts."]
    rows = conn.execute(
        "SELECT outcome, COUNT(*) AS n FROM transcriptions "
        f"WHERE {where_sql} GROUP BY outcome ORDER BY n DESC",
        params,
    ).fetchall()
    counts = {
        (row["outcome"] if row["outcome"] is not None else "(null)"): row["n"]
        for row in rows
    }
    return counts, []


def compute_metrics(
    conn: sqlite3.Connection,
    available: set[str],
    where_sql: str,
    params: list[object],
) -> tuple[dict[str, dict[str, object]], list[str]]:
    results: dict[str, dict[str, object]] = {}
    notes: list[str] = []
    for column in METRIC_COLUMNS:
        if column not in available:
            notes.append(f"Note: '{column}' column missing; skipping that metric.")
            continue
        rows = conn.execute(
            f"SELECT {column} AS value FROM transcriptions "
            f"WHERE {where_sql} AND {column} IS NOT NULL",
            params,
        ).fetchall()
        values = [row["value"] for row in rows]
        if not values:
            results[column] = {"n": 0}
            continue
        entry: dict[str, object] = {
            "n": len(values),
            "median": statistics.median(values),
            "p95": nearest_rank_p95(values),
            "min": min(values),
            "max": max(values),
        }
        if column == "total_ms":
            entry["share_under_500ms"] = (
                100.0 * sum(1 for v in values if v < 500) / len(values)
            )
        results[column] = entry
    return results, notes


def audio_bucket(seconds: float | None) -> str | None:
    if seconds is None:
        return None
    if seconds < 2:
        return AUDIO_BUCKETS[0]
    if seconds < 5:
        return AUDIO_BUCKETS[1]
    if seconds < 15:
        return AUDIO_BUCKETS[2]
    return AUDIO_BUCKETS[3]


def _summarize_bucket(rows: list[sqlite3.Row]) -> dict[str, object]:
    totals = [row["total_ms"] for row in rows if row["total_ms"] is not None]
    roundtrips = [
        row["roundtrip_ms"] for row in rows if row["roundtrip_ms"] is not None
    ]
    finalizes = [
        row["capture_finalize_ms"]
        for row in rows
        if row["capture_finalize_ms"] is not None
    ]
    return {
        "n": len(rows),
        "median_total_ms": statistics.median(totals) if totals else None,
        "p95_total_ms": nearest_rank_p95(totals) if totals else None,
        "median_roundtrip_ms": statistics.median(roundtrips) if roundtrips else None,
        "median_finalize_ms": statistics.median(finalizes) if finalizes else None,
    }


def compute_groups(
    conn: sqlite3.Connection,
    available: set[str],
    where_sql: str,
    params: list[object],
) -> tuple[dict[str, list[tuple[object, dict[str, object]]]], list[str]]:
    results: dict[str, list[tuple[object, dict[str, object]]]] = {}
    notes: list[str] = []
    need_metrics = {"total_ms", "roundtrip_ms", "capture_finalize_ms"} & available

    for group_column in GROUP_COLUMNS:
        if group_column not in available:
            notes.append(
                f"Note: '{group_column}' column missing; skipping that group-by."
            )
            continue
        columns = [group_column, *sorted(need_metrics)]
        select_sql = ", ".join(columns)
        rows = conn.execute(
            f"SELECT {select_sql} FROM transcriptions WHERE {where_sql}", params
        ).fetchall()
        buckets: dict[object, list[sqlite3.Row]] = defaultdict(list)
        for row in rows:
            buckets[row[group_column]].append(row)
        summary = [
            (key, _summarize_bucket(bucket_rows))
            for key, bucket_rows in buckets.items()
        ]
        summary.sort(key=lambda item: item[1]["n"], reverse=True)
        results[group_column] = summary

    if "audio_seconds" not in available:
        notes.append(
            "Note: 'audio_seconds' column missing; skipping audio length buckets."
        )
    else:
        columns = ["audio_seconds", *sorted(need_metrics)]
        select_sql = ", ".join(columns)
        rows = conn.execute(
            f"SELECT {select_sql} FROM transcriptions WHERE {where_sql}", params
        ).fetchall()
        buckets = defaultdict(list)
        for row in rows:
            bucket = audio_bucket(row["audio_seconds"])
            if bucket is not None:
                buckets[bucket].append(row)
        summary = [
            (bucket, _summarize_bucket(buckets[bucket]))
            for bucket in AUDIO_BUCKETS
            if bucket in buckets
        ]
        results["audio_length_bucket"] = summary

    return results, notes


def compute_tail(
    conn: sqlite3.Connection,
    available: set[str],
    where_sql: str,
    params: list[object],
    limit: int = 10,
) -> tuple[list[sqlite3.Row], list[str]]:
    if "total_ms" not in available:
        return [], ["Note: 'total_ms' column missing; skipping the tail table."]
    columns = [c for c in TAIL_COLUMNS if c in available]
    missing = [c for c in TAIL_COLUMNS if c not in available]
    notes = [
        f"Note: '{c}' column missing; omitted from the tail table." for c in missing
    ]
    select_sql = ", ".join(columns)
    rows = conn.execute(
        f"SELECT {select_sql} FROM transcriptions "
        f"WHERE {where_sql} AND total_ms IS NOT NULL "
        f"ORDER BY total_ms DESC LIMIT ?",
        [*params, limit],
    ).fetchall()
    return rows, notes


def compute_warm_window(
    conn: sqlite3.Connection,
    available: set[str],
    where_sql: str,
    params: list[object],
) -> tuple[dict[int, int] | None, list[str]]:
    needed = {"key_down_epoch", "key_up_epoch"}
    if not needed <= available:
        return None, [
            "Note: 'key_down_epoch'/'key_up_epoch' column missing; skipping warm-window eligibility."
        ]
    # The previous turn for a gap is the previous row in the whole table by
    # time (id order), not the previous row that happens to survive the
    # cohort filter. A turn the filter drops (a cancelled turn between two
    # cohort turns, for example) still occupied the microphone, so it must
    # still count as what the next cohort turn's key-down followed. The
    # cohort predicate is therefore evaluated per row (in_cohort) instead of
    # applied as a WHERE clause, and every row's key_up_epoch updates
    # previous_key_up regardless of cohort membership; only in-cohort rows
    # contribute a gap to the report.
    rows = conn.execute(
        "SELECT key_down_epoch, key_up_epoch, "
        f"({where_sql}) AS in_cohort FROM transcriptions ORDER BY id ASC",
        params,
    ).fetchall()
    gaps: list[float] = []
    previous_key_up: float | None = None
    for row in rows:
        key_down = row["key_down_epoch"]
        if row["in_cohort"] and previous_key_up is not None and key_down is not None:
            gaps.append(key_down - previous_key_up)
        if row["key_up_epoch"] is not None:
            previous_key_up = row["key_up_epoch"]
    counts = {
        threshold: sum(1 for gap in gaps if 0 <= gap <= threshold)
        for threshold in WARM_WINDOW_THRESHOLDS_S
    }
    return counts, []


def compute_connection_events(
    conn: sqlite3.Connection,
) -> tuple[dict[str, object] | None, list[str]]:
    if not table_exists(conn, "connection_events"):
        return None, ["Note: 'connection_events' table not present; skipping."]
    available = table_columns(conn, "connection_events") & set(
        CONNECTION_EVENTS_ALLOWED_COLUMNS
    )
    notes: list[str] = []
    result: dict[str, object] = {}

    if "kind" in available and ("ts_epoch" in available or "ts_utc" in available):
        time_column = "ts_utc" if "ts_utc" in available else "ts_epoch"
        rows = conn.execute(
            f"SELECT kind, {time_column} AS moment FROM connection_events"
        ).fetchall()
        by_day: dict[tuple[str, str], int] = defaultdict(int)
        for row in rows:
            moment = row["moment"]
            if moment is None:
                continue
            if time_column == "ts_utc":
                day = str(moment)[:10]
            else:
                day = datetime.fromtimestamp(moment, tz=timezone.utc).date().isoformat()
            by_day[(day, row["kind"])] += 1
        result["by_day_and_kind"] = sorted(by_day.items())
    else:
        notes.append(
            "Note: connection_events missing 'kind' or a timestamp column; skipping the daily breakdown."
        )

    if "turn_open" in available:
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM connection_events WHERE turn_open = 1"
        ).fetchone()
        result["turn_open_count"] = row["n"]
    else:
        notes.append(
            "Note: connection_events missing 'turn_open'; skipping that count."
        )

    return result, notes


def format_number(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.1f}"
    return str(value)


def render_table(headers: list[str], rows: list[list[object]]) -> str:
    if not rows:
        return "  (no rows)\n"
    str_rows = [[format_number(cell) for cell in row] for row in rows]
    widths = [len(h) for h in headers]
    for row in str_rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    lines = []
    header_line = "  " + "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    lines.append(header_line)
    lines.append("  " + "  ".join("-" * widths[i] for i in range(len(headers))))
    for row in str_rows:
        lines.append(
            "  " + "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row))
        )
    return "\n".join(lines) + "\n"


def render_text(report: dict[str, object]) -> str:
    out: list[str] = []
    out.append("Tok turn report")
    out.append(f"Database: {report['db']}")
    out.append(f"Cohort rows: {report['cohort_count']}")
    if report.get("outcome_counts") is not None:
        out.append("")
        out.append("Outcome counts (--all-outcomes):")
        rows = [[k, v] for k, v in report["outcome_counts"].items()]
        out.append(render_table(["outcome", "n"], rows))

    notes = report.get("notes") or []
    if notes:
        out.append("Notes:")
        for note in notes:
            out.append(f"  {note}")
        out.append("")

    out.append("Latency metrics:")
    headers = ["metric", "n", "median", "p95", "min", "max", "% < 500ms"]
    rows = []
    for column, stats in report["metrics"].items():
        rows.append(
            [
                column,
                stats.get("n", 0),
                stats.get("median"),
                stats.get("p95"),
                stats.get("min"),
                stats.get("max"),
                stats.get("share_under_500ms"),
            ]
        )
    out.append(render_table(headers, rows))

    for group_name, summary in report["groups"].items():
        out.append(f"By {group_name}:")
        headers = [
            "value",
            "n",
            "median total",
            "p95 total",
            "median roundtrip",
            "median finalize",
        ]
        rows = [
            [
                key,
                stats["n"],
                stats["median_total_ms"],
                stats["p95_total_ms"],
                stats["median_roundtrip_ms"],
                stats["median_finalize_ms"],
            ]
            for key, stats in summary
        ]
        out.append(render_table(headers, rows))

    out.append("Slowest 10 turns:")
    if report["tail"]:
        headers = list(report["tail"][0].keys())
        rows = [[row[h] for h in headers] for row in report["tail"]]
        out.append(render_table(headers, rows))
    else:
        out.append("  (no rows)\n")

    if report.get("warm_window") is not None:
        out.append("Warm-window eligibility (idle gap before key-down):")
        rows = [
            [f"<= {threshold}s", count]
            for threshold, count in report["warm_window"].items()
        ]
        out.append(render_table(["window", "n turns"], rows))

    if report.get("connection_events") is not None:
        ce = report["connection_events"]
        out.append("connection_events summary:")
        if "by_day_and_kind" in ce:
            rows = [[day, kind, n] for (day, kind), n in ce["by_day_and_kind"]]
            out.append(render_table(["day", "kind", "n"], rows))
        if "turn_open_count" in ce:
            out.append(f"  turn_open = 1: {ce['turn_open_count']}\n")

    return "\n".join(out)


def build_report(
    conn: sqlite3.Connection, args: argparse.Namespace
) -> dict[str, object]:
    available = table_columns(conn, "transcriptions")
    where_sql, params, notes = build_cohort_where(available, args)

    report: dict[str, object] = {
        "db": str(args.db),
        "notes": list(notes),
    }

    report["cohort_count"] = cohort_count(conn, where_sql, params)

    if args.all_outcomes:
        counts, extra_notes = outcome_counts(conn, available, where_sql, params)
        report["outcome_counts"] = counts
        report["notes"].extend(extra_notes)
    else:
        report["outcome_counts"] = None

    metrics, extra_notes = compute_metrics(conn, available, where_sql, params)
    report["metrics"] = metrics
    report["notes"].extend(extra_notes)

    groups, extra_notes = compute_groups(conn, available, where_sql, params)
    report["groups"] = groups
    report["notes"].extend(extra_notes)

    tail_rows, extra_notes = compute_tail(conn, available, where_sql, params)
    report["tail"] = [dict(row) for row in tail_rows]
    report["notes"].extend(extra_notes)

    warm_window, extra_notes = compute_warm_window(conn, available, where_sql, params)
    report["warm_window"] = warm_window
    report["notes"].extend(extra_notes)

    connection_events, extra_notes = compute_connection_events(conn)
    report["connection_events"] = connection_events
    report["notes"].extend(extra_notes)

    return report


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--db", type=Path, default=DEFAULT_DB, help="Path to history.db"
    )
    parser.add_argument("--build", help="Filter to build_id starting with this prefix")
    parser.add_argument(
        "--since",
        type=parse_since,
        help="Only turns on/after this UTC date (YYYY-MM-DD)",
    )
    parser.add_argument("--tag", help="Filter to this experiment_tag")
    parser.add_argument(
        "--all-outcomes",
        action="store_true",
        help="Show outcome counts instead of the fixed success/dispatched/live cohort",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of tables",
    )
    return parser.parse_args(argv)


def run_report(args: argparse.Namespace) -> dict[str, object]:
    """Open the database and build the report, turning a locked/busy database
    (or any other operational failure) into the same clean SystemExit that
    open_db() raises for an unopenable file, instead of an unhandled
    traceback."""
    conn = open_db(args.db)
    try:
        try:
            return build_report(conn, args)
        finally:
            conn.close()
    except sqlite3.OperationalError as error:
        raise SystemExit(f"Database error while reading {args.db}: {error}") from error


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    report = run_report(args)

    if args.json:
        print(json.dumps(report, indent=2, default=str))
    else:
        print(render_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
