"""Transcribes clips with a base model or a saved run, writes each transcript, and scores them.

  python evaluate.py --model openai/whisper-large-v3-turbo --roles val,dev --out runs/base-whisper
  python evaluate.py --run runs/whisper-s1 --roles dev --out runs/whisper-s1
  python evaluate.py --per-speaker-runs runs/whisper-s2 --fallback-run runs/whisper-s1 --roles dev --out runs/whisper-s2

Writes <out>/predictions-<roles>.jsonl (one line per clip) and <out>/scores-<roles>.json.
The number that matters is "unseen": prompts no speaker said in the training clips.
"""
from __future__ import annotations

import argparse
import json
import time
from collections import defaultdict
from pathlib import Path

import torch

from asr import Clip, Listener, batches_by_length, bootstrap_interval, error_rate, load_clips, load_run, read_audio, word_errors


@torch.no_grad()
def transcribe_clips(listener: Listener, clips: list[Clip], audio_root: str, max_clips: int = 16, max_seconds: float = 240.0) -> dict[str, str]:
    listener.model.eval()
    texts: dict[str, str] = {}
    for batch in batches_by_length(clips, max_clips, max_seconds, None):
        waves = [read_audio(audio_root, c) for c in batch]
        with torch.autocast("cuda", dtype=torch.float16, enabled=listener.amp):
            heard = listener.transcribe(waves)
        for clip, text in zip(batch, heard):
            texts[clip.id] = text
    return texts


def score(clips: list[Clip], texts: dict[str, str]) -> dict:
    groups: dict[str, list[tuple[int, int]]] = defaultdict(list)
    exact = defaultdict(list)
    for c in clips:
        pair = word_errors(c.prompt, texts.get(c.id, ""))
        keys = ["all", "unseen" if not c.seen else "seen", c.kind, "dysarthric" if c.dysarthric else "control", f"speaker:{c.speaker}"]
        if c.dysarthric:
            keys += [f"dysarthric-{'unseen' if not c.seen else 'seen'}", f"dysarthric-{c.kind}"]
        if not c.seen:
            keys.append(f"unseen-{c.kind}")
        if c.strict_unseen:
            keys.append("unseen-strict")
        for key in keys:
            groups[key].append(pair)
            exact[key].append(pair[0] == 0)
    out = {}
    for key, pairs in sorted(groups.items()):
        low, high = bootstrap_interval(pairs)
        out[key] = {"clips": len(pairs), "wer": round(error_rate(pairs), 4), "low": round(low, 4), "high": round(high, 4), "exact": round(sum(exact[key]) / len(pairs), 4)}
    return out


def print_scores(scores: dict, title: str) -> None:
    print(f"\n{title}")
    for key in ("all", "unseen", "unseen-strict", "seen", "dysarthric", "dysarthric-unseen", "control", "word", "sentence", "unseen-word", "unseen-sentence"):
        if key in scores:
            s = scores[key]
            print(f"  {key:18} words wrong {s['wer']*100:5.1f}%  (95% {s['low']*100:4.1f}-{s['high']*100:4.1f})  all right {s['exact']*100:4.0f}%  n={s['clips']}")
    speakers = "  ".join(f"{k[8:]} {v['wer']*100:.0f}%" for k, v in scores.items() if k.startswith("speaker:"))
    print(f"  per speaker: {speakers}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--run")
    ap.add_argument("--per-speaker-runs", help="a folder with one run per speaker (stage 2)")
    ap.add_argument("--fallback-run", help="used for speakers with no run of their own")
    ap.add_argument("--clips", default="data/clips.jsonl")
    ap.add_argument("--audio", default="data/audio")
    ap.add_argument("--roles", default="val,dev")
    ap.add_argument("--limit", type=int, default=0, help="only the first N clips (for a quick check)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    roles = set(args.roles.split(","))
    if "holdout" in roles:
        print("NOTE: scoring the held-out clips. Do this once, for the final setup only.")
    clips = load_clips(args.clips, roles)
    if args.limit:
        clips = clips[: args.limit]
    started = time.time()
    texts: dict[str, str] = {}
    if args.per_speaker_runs:
        root = Path(args.per_speaker_runs)
        for speaker in sorted({c.speaker for c in clips}):
            run = root / speaker if (root / speaker / "config.json").exists() else Path(args.fallback_run)
            listener = load_run(run)
            texts.update(transcribe_clips(listener, [c for c in clips if c.speaker == speaker], args.audio))
            del listener
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
    else:
        listener = load_run(args.run) if args.run else Listener(args.model)
        texts = transcribe_clips(listener, clips, args.audio)
    seconds = time.time() - started

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tag = "-".join(sorted(roles))
    with (out / f"predictions-{tag}.jsonl").open("w") as f:
        for c in clips:
            f.write(json.dumps({"id": c.id, "speaker": c.speaker, "role": c.role, "seen": c.seen, "prompt": c.prompt, "heard": texts.get(c.id, "")}) + "\n")
    result = {"source": args.run or args.per_speaker_runs or args.model, "seconds_per_clip": round(seconds / max(len(clips), 1), 3)}
    for role in sorted(roles):
        result[role] = score([c for c in clips if c.role == role], texts)
        print_scores(result[role], f"{result['source']} on {role}")
    (out / f"scores-{tag}.json").write_text(json.dumps(result, indent=2))
    print(f"\n{len(clips)} clips in {seconds:.0f} s ({result['seconds_per_clip']} s per clip)")


if __name__ == "__main__":
    main()
