#!/usr/bin/env python3
"""Generate the latency harness clip bank with Gemini TTS.

Reads Tools/Harness/phrases.json, renders each phrase in several accent, voice, and
model variants (Gemini 3.8 Flash TTS and Flash-Lite TTS alternate), trims and
peak-normalizes the audio, and validates each clip by transcribing it once over REST.
A clip whose validation transcript misses too many words is regenerated, so a TTS
mistake is never scored later as an engine mistake.

Output: build/harness/clips/<clip_id>.wav and build/harness/clips/manifest.json.
The API key is read from GEMINI_API_KEY or the repo .env by key name. It is never
printed.
"""

from __future__ import annotations

import argparse
import array
import base64
import io
import json
import math
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHRASES = ROOT / "Tools" / "Harness" / "phrases.json"
OUT = ROOT / "build" / "harness" / "clips"
API = "https://generativelanguage.googleapis.com/v1beta/models"

TTS_MODELS = ("gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts")
VOICES = (
    "Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr",
    "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba",
    "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
    "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
    "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat",
)
# Weighted toward Indian English, the owner's own accent and Tok's default locale.
ACCENTS = (
    ("Indian English, from Pune", 4),
    ("Indian English, from Bangalore", 2),
    ("Indian English, from Delhi", 2),
    ("General American", 2),
    ("British, Received Pronunciation", 1),
    ("Scottish", 1),
    ("Irish", 1),
    ("Australian", 1),
    ("Nigerian English", 1),
    ("South African English", 1),
    ("Singaporean English", 1),
    ("Canadian", 1),
)
CODE_SWITCH_ACCENTS = (
    ("Indian English, from Pune, code-switching with Hindi and Marathi", 1),
)
STYLES = (
    ("conversational", "conversational pace", 4),
    ("brisk", "brisk, busy engineer dictating a quick note", 2),
    ("deliberate", "slow and deliberate", 1),
    ("mid_pause", "one short thinking pause mid-sentence", 1),
    ("trailing", "trailing off, a little quieter on the last words", 1),
)

FRAME_S = 0.01
ONSET_BELOW_PEAK_DB = 40.0
TRIM_LEAD_S = 0.03
TRIM_TAIL_S = 0.12
TARGET_PEAK_DBFS = -3.0
MAX_VALIDATION_WER = 0.2
MIN_WORDS_PER_S, MAX_WORDS_PER_S = 1.0, 5.0


def api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY", "")
    env = ROOT / ".env"
    if not key and env.exists():
        for line in env.read_text().splitlines():
            name, sep, value = line.partition("=")
            if sep and name.strip() == "GEMINI_API_KEY":
                key = value.strip().strip("'\"")
    if not key:
        sys.exit("GEMINI_API_KEY is not set in the environment or .env.")
    return key


def env_value(name: str, default: str) -> str:
    env = ROOT / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() == name and value.strip():
                return value.strip().strip("'\"")
    return default


def post(model: str, body: dict, key: str, timeout: float = 120) -> dict:
    request = urllib.request.Request(
        f"{API}/{model}:generateContent",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": key},
    )
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code in (429, 500, 503) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            detail = error.read()[:300].decode(errors="replace")
            raise RuntimeError(f"{model} HTTP {error.code}: {detail}") from None
        except (urllib.error.URLError, TimeoutError):
            if attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def decode_audio(part: dict) -> tuple[array.array, int]:
    """Returns mono int16 samples and the sample rate from a TTS inlineData part."""
    raw = base64.b64decode(part["data"])
    mime = part.get("mimeType", "")
    if raw[:4] == b"RIFF":
        with wave.open(io.BytesIO(raw)) as audio:
            if audio.getsampwidth() != 2:
                raise RuntimeError(f"unsupported sample width {audio.getsampwidth()}")
            rate, channels = audio.getframerate(), audio.getnchannels()
            samples = array.array("h", audio.readframes(audio.getnframes()))
    else:
        match = re.search(r"rate=(\d+)", mime)
        if not match:
            raise RuntimeError(f"unsupported audio mime type {mime!r}")
        rate, channels = int(match.group(1)), 1
        samples = array.array("h", raw)
    if sys.byteorder == "big":
        samples.byteswap()
    if channels > 1:
        samples = array.array("h", samples[::channels])
    return samples, rate


def speech_bounds(samples: array.array, rate: int) -> tuple[int, int]:
    """First and last sample of frames within ONSET_BELOW_PEAK_DB of the loudest frame."""
    frame = max(1, int(rate * FRAME_S))
    levels = []
    for start in range(0, len(samples), frame):
        chunk = samples[start : start + frame]
        rms = math.sqrt(sum(s * s for s in chunk) / len(chunk)) if chunk else 0.0
        levels.append(20 * math.log10(rms / 32768) if rms > 0 else -120.0)
    if not levels:
        raise RuntimeError("empty audio")
    floor = max(levels) - ONSET_BELOW_PEAK_DB
    loud = [i for i, level in enumerate(levels) if level > floor]
    return loud[0] * frame, min(len(samples), (loud[-1] + 1) * frame)


def normalize_words(text: str) -> list[str]:
    text = text.lower().replace("-", " ")
    return re.findall(r"[\w']+", text)


def word_error_rate(reference: str, hypothesis: str) -> float:
    ref, hyp = normalize_words(reference), normalize_words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    previous = list(range(len(hyp) + 1))
    for i, word in enumerate(ref, 1):
        current = [i] + [0] * len(hyp)
        for j, other in enumerate(hyp, 1):
            current[j] = min(
                previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (word != other)
            )
        previous = current
    return previous[-1] / len(ref)


def weighted(rng: random.Random, options):
    return rng.choices([o[:-1] for o in options], weights=[o[-1] for o in options])[0]


def plan(phrases: list[dict], variants: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    clips = []
    index = 0
    for phrase in phrases:
        for variant in range(variants):
            code_switch = bool(phrase.get("code_switch"))
            (accent,) = weighted(rng, CODE_SWITCH_ACCENTS if code_switch else ACCENTS)
            style_id, style = weighted(rng, STYLES)
            clips.append({
                "clip_id": f"{phrase['id']}-{variant}",
                "phrase_id": phrase["id"],
                "text": phrase["text"],
                "code_switch": code_switch,
                "tts_model": TTS_MODELS[index % len(TTS_MODELS)],
                "voice": rng.choice(VOICES),
                "accent": accent,
                "style": style_id,
                "style_prompt": style,
            })
            index += 1
    return clips


def render(clip: dict, key: str, validate_model: str) -> dict:
    # The 3.8 TTS models speak any plain-text instruction aloud and reject
    # systemInstruction, but treat a leading bracketed tag as direction.
    prompt = f"[{clip['accent']} accent, {clip['style_prompt']}] {clip['text']}"
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": clip["voice"]}}},
        },
    }
    started = time.monotonic()
    response = post(clip["tts_model"], body, key)
    tts_s = time.monotonic() - started
    part = response["candidates"][0]["content"]["parts"][0]["inlineData"]
    samples, rate = decode_audio(part)
    onset, offset = speech_bounds(samples, rate)
    start = max(0, onset - int(TRIM_LEAD_S * rate))
    end = min(len(samples), offset + int(TRIM_TAIL_S * rate))
    trimmed = samples[start:end]
    peak = max(1, max(abs(s) for s in trimmed))
    gain = (32768 * 10 ** (TARGET_PEAK_DBFS / 20)) / peak
    scaled = array.array("h", (max(-32768, min(32767, int(s * gain))) for s in trimmed))
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        pcm = array.array("h", scaled)
        if sys.byteorder == "big":
            pcm.byteswap()
        audio.writeframes(pcm.tobytes())
    wav = buffer.getvalue()

    validation = post(
        validate_model,
        {
            "contents": [{"parts": [
                {"text": "Transcribe this audio verbatim. Output only the transcript."},
                {"inlineData": {"mimeType": "audio/wav", "data": base64.b64encode(wav).decode()}},
            ]}],
            "generationConfig": {"temperature": 0},
        },
        key,
    )
    heard = "".join(
        p.get("text", "") for p in validation["candidates"][0]["content"].get("parts", [])
    ).strip()
    speech_s = (offset - onset) / rate
    return {
        **clip,
        "wav": wav,
        "sample_rate": rate,
        "duration_s": round(len(scaled) / rate, 3),
        "speech_onset_s": round((onset - start) / rate, 3),
        "speech_offset_s": round((offset - start) / rate, 3),
        "speech_s": round(speech_s, 3),
        "words": len(normalize_words(clip["text"])),
        "tts_request_s": round(tts_s, 2),
        "validation_model": validate_model,
        "validation_text": heard,
        "validation_wer": round(word_error_rate(clip["text"], heard), 3),
    }


def acceptable(result: dict) -> str | None:
    rate = result["words"] / max(0.1, result["speech_s"])
    if not MIN_WORDS_PER_S <= rate <= MAX_WORDS_PER_S:
        return f"speech rate {rate:.1f} words/s"
    if not result["code_switch"] and result["validation_wer"] > MAX_VALIDATION_WER:
        return f"validation WER {result['validation_wer']:.2f}"
    return None


def build_clip(clip: dict, key: str, validate_model: str, attempts: int) -> dict:
    last = None
    for attempt in range(attempts):
        result = render(clip, key, validate_model)
        problem = acceptable(result)
        if problem is None:
            result["attempts"] = attempt + 1
            return result
        last = problem
    raise RuntimeError(f"{clip['clip_id']} rejected after {attempts} attempts: {last}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--variants", type=int, default=2, help="clips per phrase")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--seed", type=int, default=38)
    parser.add_argument("--limit", type=int, help="only the first N clips (smoke test)")
    parser.add_argument("--force", action="store_true", help="regenerate existing clips")
    args = parser.parse_args(argv)

    key = api_key()
    validate_model = env_value("GEMINI_MODEL", "gemini-3.5-flash-lite")
    clips = plan(json.loads(PHRASES.read_text()), args.variants, args.seed)
    if args.limit:
        clips = clips[: args.limit]
    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "manifest.json"
    existing = {}
    if manifest_path.exists() and not args.force:
        existing = {c["clip_id"]: c for c in json.loads(manifest_path.read_text())["clips"]}
    todo = [c for c in clips if c["clip_id"] not in existing
            or not (OUT / f"{c['clip_id']}.wav").exists()]
    print(f"{len(clips)} clips planned, {len(todo)} to generate, validation by {validate_model}")

    failures = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(build_clip, c, key, validate_model, args.attempts): c for c in todo}
        for done, future in enumerate(as_completed(futures), 1):
            clip = futures[future]
            try:
                result = future.result()
            except Exception as error:  # noqa: BLE001 - report and continue with the rest
                failures.append(f"{clip['clip_id']}: {error}")
                print(f"[{done}/{len(todo)}] {clip['clip_id']} FAILED: {error}", flush=True)
                continue
            (OUT / f"{result['clip_id']}.wav").write_bytes(result.pop("wav"))
            existing[result["clip_id"]] = result
            print(
                f"[{done}/{len(todo)}] {result['clip_id']} {result['tts_model']} "
                f"{result['speech_s']:.1f}s wer={result['validation_wer']:.2f} "
                f"attempts={result['attempts']}",
                flush=True,
            )
    ordered = [existing[c["clip_id"]] for c in clips if c["clip_id"] in existing]
    manifest_path.write_text(json.dumps({"clips": ordered}, indent=2) + "\n")
    print(f"manifest: {len(ordered)} clips, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
