# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

import importlib.util
import json
import re
import sqlite3
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "turn_report", Path(__file__).resolve().parents[2] / "Scripts/turn_report.py"
)
turn_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(turn_report)

SENTINELS = {
    "text": "SENTINEL_TEXT_DO_NOT_LEAK",
    "wrong_text": "SENTINEL_WRONG_DO_NOT_LEAK",
    "right_text": "SENTINEL_RIGHT_DO_NOT_LEAK",
    "app_name": "SENTINEL_APP_NAME_DO_NOT_LEAK",
    "app_bundle_id": "SENTINEL_BUNDLE_DO_NOT_LEAK",
    "input_device": "SENTINEL_DEVICE_DO_NOT_LEAK",
    "error": "SENTINEL_ERROR_DO_NOT_LEAK",
    "post_process_error": "SENTINEL_PP_ERROR_DO_NOT_LEAK",
    "post_process_app_context": 12345,
    "fallback_reason": "SENTINEL_FALLBACK_REASON_DO_NOT_LEAK",
}

FULL_SCHEMA_SQL = """
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT,
    ts_epoch REAL,
    outcome TEXT,
    is_live_route INTEGER,
    delivery_outcome TEXT,
    post_process_status TEXT,
    build_id TEXT,
    experiment_tag TEXT,
    audio_seconds REAL,
    total_ms REAL,
    roundtrip_ms REAL,
    capture_finalize_ms REAL,
    capture_start_ms REAL,
    inject_ms REAL,
    trail_wait_ms REAL,
    finalize_drain_ms REAL,
    endpoint_aligned INTEGER,
    silence_flush_ms INTEGER,
    chunk_ms INTEGER,
    mic_state_at_keydown TEXT,
    finalize_exit TEXT,
    settle_path TEXT,
    quiet_resets INTEGER,
    trail_peak_db REAL,
    noise_floor_db REAL,
    key_down_epoch REAL,
    key_up_epoch REAL,
    fallback_reason TEXT,
    text TEXT,
    wrong_text TEXT,
    right_text TEXT,
    app_name TEXT,
    app_bundle_id TEXT,
    input_device TEXT,
    error TEXT,
    post_process_error TEXT,
    post_process_app_context INTEGER
);
"""


def make_db(path, rows, extra_sql=""):
    conn = sqlite3.connect(path)
    conn.execute(FULL_SCHEMA_SQL)
    conn.execute(extra_sql) if extra_sql else None
    columns = list(rows[0].keys())
    placeholders = ", ".join("?" for _ in columns)
    conn.executemany(
        f"INSERT INTO transcriptions ({', '.join(columns)}) VALUES ({placeholders})",
        [tuple(row[c] for c in columns) for row in rows],
    )
    conn.commit()
    conn.close()


def base_row(**overrides):
    row = {
        "ts_utc": "2026-09-01T00:00:00Z",
        "ts_epoch": 1_700_000_000.0,
        "outcome": "success",
        "is_live_route": 1,
        "delivery_outcome": "dispatched",
        "post_process_status": None,
        "build_id": "bb2362f",
        "experiment_tag": "control",
        "audio_seconds": 3.0,
        "total_ms": 400.0,
        "roundtrip_ms": 300.0,
        "capture_finalize_ms": 80.0,
        "capture_start_ms": 10.0,
        "inject_ms": 15.0,
        "trail_wait_ms": 20.0,
        "finalize_drain_ms": 5.0,
        "endpoint_aligned": 0,
        "silence_flush_ms": 700,
        "chunk_ms": 100,
        "mic_state_at_keydown": "warm",
        "finalize_exit": "silence",
        "settle_path": "ws",
        "quiet_resets": 0,
        "trail_peak_db": -40.0,
        "noise_floor_db": -60.0,
        "key_down_epoch": 1_700_000_000.0,
        "key_up_epoch": 1_700_000_001.0,
        "fallback_reason": SENTINELS["fallback_reason"],
        "text": SENTINELS["text"],
        "wrong_text": SENTINELS["wrong_text"],
        "right_text": SENTINELS["right_text"],
        "app_name": SENTINELS["app_name"],
        "app_bundle_id": SENTINELS["app_bundle_id"],
        "input_device": SENTINELS["input_device"],
        "error": SENTINELS["error"],
        "post_process_error": SENTINELS["post_process_error"],
        "post_process_app_context": SENTINELS["post_process_app_context"],
    }
    row.update(overrides)
    return row


class SentinelPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.db_path = None

    def _build(self, tmp_path, rows):
        db_path = tmp_path / "history.db"
        make_db(db_path, rows)
        return db_path

    def test_sentinels_never_appear_in_text_output(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = self._build(
                Path(tmp), [base_row(total_ms=x) for x in (100, 900, 5000)]
            )
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            text = turn_report.render_text(report)
            for name, value in SENTINELS.items():
                self.assertNotIn(
                    str(value), text, f"sentinel for {name} leaked into text output"
                )

    def test_sentinels_never_appear_in_json_output(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = self._build(
                Path(tmp), [base_row(total_ms=x) for x in (100, 900, 5000)]
            )
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            blob = json.dumps(report, default=str)
            for name, value in SENTINELS.items():
                self.assertNotIn(
                    str(value), blob, f"sentinel for {name} leaked into json output"
                )

    def test_no_denied_column_name_appears_in_issued_sql(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = self._build(
                Path(tmp), [base_row(total_ms=x) for x in (100, 900, 5000)]
            )
            turn_report.reset_sql_log()
            args = turn_report.parse_args(
                ["--db", str(db_path), "--all-outcomes", "--json"]
            )
            conn = turn_report.open_db(args.db)
            turn_report.build_report(conn, args)
            conn.close()
            self.assertTrue(turn_report.EXECUTED_SQL, "no SQL was captured")
            for sql in turn_report.EXECUTED_SQL:
                for denied in turn_report.DENIED_COLUMNS:
                    self.assertIsNone(
                        re.search(rf"\b{re.escape(denied)}\b", sql),
                        f"denied column {denied!r} appeared in SQL: {sql}",
                    )

    def test_allow_lists_are_disjoint_from_denied_columns(self):
        self.assertTrue(
            turn_report.DENIED_COLUMNS.isdisjoint(
                turn_report.TRANSCRIPTIONS_ALLOWED_COLUMNS
            )
        )
        self.assertTrue(
            turn_report.DENIED_COLUMNS.isdisjoint(
                turn_report.CONNECTION_EVENTS_ALLOWED_COLUMNS
            )
        )
        self.assertTrue(
            turn_report.DENIED_COLUMNS.isdisjoint(turn_report.METRIC_COLUMNS)
        )
        self.assertTrue(
            turn_report.DENIED_COLUMNS.isdisjoint(turn_report.GROUP_COLUMNS)
        )
        self.assertTrue(turn_report.DENIED_COLUMNS.isdisjoint(turn_report.TAIL_COLUMNS))


class PercentileMathTests(unittest.TestCase):
    def test_median_is_statistics_median(self):
        import statistics

        values = [1.0, 2.0, 3.0, 4.0]
        self.assertEqual(statistics.median(values), 2.5)

    def test_nearest_rank_p95_matches_hand_computation(self):
        # 20 values 1..20: ceil(0.95 * 20) = 19th smallest value = 19.
        values = [float(i) for i in range(1, 21)]
        self.assertEqual(turn_report.nearest_rank_p95(values), 19.0)

    def test_nearest_rank_p95_single_value(self):
        self.assertEqual(turn_report.nearest_rank_p95([42.0]), 42.0)

    def test_nearest_rank_p95_small_sample_rounds_up(self):
        # n=3: ceil(0.95*3) = 3, so p95 is the max.
        self.assertEqual(turn_report.nearest_rank_p95([10.0, 20.0, 30.0]), 30.0)


class MissingColumnToleranceTests(unittest.TestCase):
    def test_missing_metric_column_is_skipped_with_a_note(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            conn = sqlite3.connect(db_path)
            # A legacy schema: no roundtrip_ms, capture_finalize_ms, key_down_epoch, etc.
            conn.execute(
                """
                CREATE TABLE transcriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts_utc TEXT,
                    ts_epoch REAL,
                    outcome TEXT,
                    is_live_route INTEGER,
                    delivery_outcome TEXT,
                    total_ms REAL
                )
                """
            )
            conn.execute(
                "INSERT INTO transcriptions "
                "(ts_utc, ts_epoch, outcome, is_live_route, delivery_outcome, total_ms) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    "2026-09-01T00:00:00Z",
                    1_700_000_000.0,
                    "success",
                    1,
                    "dispatched",
                    400.0,
                ),
            )
            conn.commit()
            conn.close()

            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()

            self.assertIn("total_ms", report["metrics"])
            self.assertNotIn("roundtrip_ms", report["metrics"])
            self.assertTrue(
                any("roundtrip_ms" in note for note in report["notes"]),
                "expected a note about the missing roundtrip_ms column",
            )
            self.assertIsNone(report["warm_window"])
            self.assertTrue(
                any("key_down_epoch" in note for note in report["notes"]),
                "expected a note about the missing key_down_epoch column",
            )

    def test_missing_connection_events_table_is_noted(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = self._make_minimal_db(Path(tmp))
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            self.assertIsNone(report["connection_events"])
            self.assertTrue(
                any("connection_events" in note for note in report["notes"])
            )

    def _make_minimal_db(self, tmp_path):
        db_path = tmp_path / "history.db"
        make_db(db_path, [base_row()])
        return db_path


class GroupingAndFilteringTests(unittest.TestCase):
    def test_all_outcomes_reports_outcome_counts(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            rows = [
                base_row(outcome="success"),
                base_row(outcome="success"),
                base_row(outcome="cancelled"),
            ]
            make_db(db_path, rows)
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path), "--all-outcomes"])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            self.assertEqual(report["outcome_counts"], {"success": 2, "cancelled": 1})

    def test_build_prefix_filter(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            rows = [base_row(build_id="bb2362f"), base_row(build_id="cc9999a")]
            make_db(db_path, rows)
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path), "--build", "bb2362f"])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            self.assertEqual(report["cohort_count"], 1)

    def test_audio_length_bucket_grouping(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            rows = [
                base_row(audio_seconds=1.0, total_ms=100.0),
                base_row(audio_seconds=4.0, total_ms=200.0),
                base_row(audio_seconds=10.0, total_ms=300.0),
                base_row(audio_seconds=20.0, total_ms=400.0),
            ]
            make_db(db_path, rows)
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()
            buckets = dict(report["groups"]["audio_length_bucket"])
            self.assertEqual(set(buckets.keys()), {"<2s", "2-5s", "5-15s", "15+s"})
            for stats in buckets.values():
                self.assertEqual(stats["n"], 1)


class WarmWindowOrderingTests(unittest.TestCase):
    def test_gap_uses_previous_row_in_whole_table_not_previous_cohort_row(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            # Three cohort (success) turns with a cancelled turn sitting
            # between the first two. The cancelled turn's key_up_epoch is
            # only 10s before the second cohort turn's key_down_epoch, but
            # the first cohort turn's key_up_epoch is 200s before it: if the
            # cancelled row were skipped when finding "the previous turn",
            # the gap would be wrongly computed as 200s (making the turn
            # falsely ineligible for a 90s warm window) instead of 10s.
            rows = [
                base_row(
                    outcome="success",
                    key_down_epoch=0.0,
                    key_up_epoch=5.0,
                ),
                base_row(
                    outcome="cancelled",
                    key_down_epoch=10.0,
                    key_up_epoch=195.0,
                ),
                base_row(
                    outcome="success",
                    key_down_epoch=205.0,
                    key_up_epoch=210.0,
                ),
            ]
            make_db(db_path, rows)
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()

            # Gap for the third row (a cohort turn) is 205 - 195 = 10s, so it
            # is eligible under every threshold, including the tightest 60s
            # window. The first cohort row has no prior turn and contributes
            # no gap.
            self.assertEqual(report["warm_window"][60], 1)
            self.assertEqual(report["warm_window"][90], 1)
            self.assertEqual(report["warm_window"][300], 1)

    def test_non_cohort_row_never_itself_counted_but_still_anchors_gaps(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            rows = [
                base_row(outcome="success", key_down_epoch=0.0, key_up_epoch=5.0),
                base_row(
                    outcome="cancelled", key_down_epoch=1000.0, key_up_epoch=1005.0
                ),
                base_row(
                    outcome="success", key_down_epoch=1006.0, key_up_epoch=1010.0
                ),
            ]
            make_db(db_path, rows)
            turn_report.reset_sql_log()
            args = turn_report.parse_args(["--db", str(db_path)])
            conn = turn_report.open_db(args.db)
            report = turn_report.build_report(conn, args)
            conn.close()

            # Only the two cohort (success) rows can ever contribute a gap,
            # so there is exactly one gap value (1006 - 1005 = 1s), not two.
            self.assertEqual(report["warm_window"][60], 1)


class ReadOnlyOpenTests(unittest.TestCase):
    def test_missing_db_fails_clearly_without_creating_it(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "does-not-exist.db"
            with self.assertRaises(SystemExit):
                turn_report.open_db(missing)
            self.assertFalse(missing.exists())

    def test_db_path_with_space_opens_read_only(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            spacey_dir = Path(tmp) / "Application Support"
            spacey_dir.mkdir()
            db_path = spacey_dir / "history.db"
            make_db(db_path, [base_row()])
            conn = turn_report.open_db(db_path)
            try:
                row = conn.execute("SELECT COUNT(*) AS n FROM transcriptions").fetchone()
                self.assertEqual(row["n"], 1)
            finally:
                conn.close()

    def test_locked_database_raises_a_clean_exit_not_a_traceback(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "history.db"
            make_db(db_path, [base_row()])

            locker = sqlite3.connect(db_path, isolation_level=None)
            locker.execute("BEGIN EXCLUSIVE")
            try:
                args = turn_report.parse_args(["--db", str(db_path)])
                with self.assertRaises(SystemExit):
                    turn_report.run_report(args)
            finally:
                locker.execute("ROLLBACK")
                locker.close()


if __name__ == "__main__":
    unittest.main()
