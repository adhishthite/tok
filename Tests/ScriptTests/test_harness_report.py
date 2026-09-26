# Copyright 2026 Adhish Thite
# SPDX-License-Identifier: Apache-2.0

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))

import harness_clips  # noqa: E402
import harness_report  # noqa: E402


def row(arm, round_, position, total, start, wer=0.0, words=10, **extra):
    return {
        "run_id": "r1", "round": round_, "turn_in_block": position, "arm": arm,
        "outcome": "success", "total_ms": total, "capture_start_ms": start,
        "accuracy": {"wer": wer, "reference_words": words, "first_word_hit": True,
                     "last_word_hit": wer == 0.0},
        **extra,
    }


class HarnessReportTests(unittest.TestCase):
    def test_pooled_wer_weights_by_reference_words(self):
        rows = [row("baseline", 0, 0, 500, 200, wer=1.0, words=2),
                row("baseline", 0, 1, 500, 200, wer=0.0, words=18)]
        self.assertAlmostEqual(harness_report.pooled_wer(rows), 2 / 20)

    def test_code_switched_clips_do_not_count_toward_wer(self):
        rows = [row("baseline", 0, 0, 500, 200, wer=1.0, code_switch=True),
                row("baseline", 0, 1, 500, 200, wer=0.0)]
        self.assertEqual(harness_report.pooled_wer(rows), 0.0)

    def test_other_languages_stay_out_of_the_headline_wer(self):
        rows = [row("baseline", 0, 0, 500, 200, wer=1.0, language="mr"),
                row("baseline", 0, 1, 500, 200, wer=0.0)]
        self.assertEqual(harness_report.pooled_wer(rows), 0.0)
        self.assertEqual(harness_report.pooled_wer(rows, english_only=False), 0.5)

    def test_romanized_transcript_of_devanagari_is_flagged(self):
        self.assertTrue(harness_report.romanized(
            {"reference": "मी थोड्या वेळात पोहोचतो.", "hypothesis": "Mi thodya velat pohochto."}))
        self.assertFalse(harness_report.romanized(
            {"reference": "मी थोड्या वेळात पोहोचतो.", "hypothesis": "मी थोड्या वेळात पोहोचतो."}))

    def test_paired_deltas_match_round_and_position(self):
        rows = [row("baseline", 0, 0, 600, 200), row("baseline", 0, 1, 700, 210),
                row("warm90", 0, 0, 550, 3), row("warm90", 0, 1, 690, 2),
                row("warm90", 1, 0, 100, 1)]
        self.assertEqual(sorted(harness_report.paired_deltas(rows, "warm90", "total_ms")),
                         [-50, -10])

    def test_direct_and_acoustic_rows_are_not_pooled(self):
        rows = [row("baseline", 0, i, 600, 200, run_id="a", mode="acoustic") for i in range(6)]
        rows += [row("baseline", 0, i, None, None, run_id="d", mode="direct",
                     roundtrip_ms=400) for i in range(6)]
        rows += [row("flush0", 0, i, None, None, run_id="d", mode="direct",
                     roundtrip_ms=320) for i in range(6)]
        report = harness_report.build_report(rows)
        self.assertEqual(set(report["arms"]),
                         {"baseline [acoustic]", "baseline [direct]", "flush0 [direct]"})
        self.assertEqual(report["paired"]["flush0 [direct]/roundtrip_ms"]["median_delta"], -80)

    def test_unsettled_turns_are_not_paired(self):
        rows = [row("baseline", 0, 0, 600, 200), {**row("aligned", 0, 0, 400, 200),
                                                   "outcome": "empty"}]
        self.assertEqual(harness_report.paired_deltas(rows, "aligned", "total_ms"), [])

    def test_report_renders_with_every_section(self):
        rows = [row("baseline", 0, i, 600 + i, 200, mic_state_at_keydown="cold")
                for i in range(6)]
        rows += [row("warm90", 0, i, 590 + i, 3, mic_state_at_keydown="warm") for i in range(6)]
        text = harness_report.render(harness_report.build_report(rows))
        for heading in ("Latency by arm", "Word accuracy", "Capture start", "Paired against"):
            self.assertIn(heading, text)


class HarnessClipTests(unittest.TestCase):
    def test_word_error_rate_ignores_case_and_punctuation(self):
        self.assertEqual(harness_clips.word_error_rate("Ship it.", "ship it"), 0.0)
        self.assertEqual(harness_clips.word_error_rate("Ship it.", "Shipment."), 1.0)

    def test_speech_bounds_skip_leading_and_trailing_silence(self):
        import array
        rate = 1000
        samples = array.array("h", [0] * 200 + [8000] * 300 + [0] * 500)
        onset, offset = harness_clips.speech_bounds(samples, rate)
        self.assertEqual((onset, offset), (200, 500))

    def test_plan_alternates_tts_models(self):
        clips = harness_clips.plan([{"id": "a", "text": "one two"}], variants=4, seed=1)
        self.assertEqual([c["tts_model"] for c in clips],
                         list(harness_clips.TTS_MODELS) * 2)

    def test_adding_phrases_does_not_change_planned_clips(self):
        first = harness_clips.plan([{"id": "a", "text": "one two"}], None, 38)
        more = harness_clips.plan(
            [{"id": "a", "text": "one two"}, {"id": "b", "text": "x", "language": "hi"}],
            None, 38)
        self.assertEqual(first, more[: len(first)])

    def test_devanagari_words_are_not_split_at_vowel_signs(self):
        self.assertEqual(harness_clips.normalize_words("मी थोड्या वेळात.", "mr"),
                         ["मी", "थोड्या", "वेळात"])

    def test_romanized_validation_skips_the_wer_gate(self):
        result = {"language": "mr", "code_switch": False, "words": 3, "speech_s": 1.5,
                  "text": "मी थोड्या वेळात.", "validation_text": "Mi thodya velat.",
                  "validation_wer": 1.0}
        self.assertIsNone(harness_clips.acceptable(result))


if __name__ == "__main__":
    unittest.main()
