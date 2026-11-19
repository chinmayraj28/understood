"""Builds the training manifest from the TORGO bundle manifest.

Roles (fixed here, before any training, so no result can leak into a choice):
  train    enrolment clips, minus the validation prompts
  val      enrolment clips whose prompt is in a held-back 10% of prompts (never trained on, by any
           speaker): used for early stopping and for choosing settings
  dev      the "dev" half of the test clips (same hash rule as web/scripts/evalTranscription.ts)
  holdout  the other half: scored once, at the end

Each dev/holdout clip is marked `seen` when its prompt is among the train prompts of ANY speaker.
The honest number is the one on unseen prompts.
"""
import collections
import hashlib
import json
import re
import sys
from pathlib import Path

MIN_SECONDS, MAX_SECONDS = 0.3, 30.0
VAL_PROMPT_PERCENT = 10


def norm(text: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", text.lower()).split())


def h(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:24]


def split_of(clip_id: str) -> str:  # identical to evalTranscription.ts
    return "dev" if int(h(f"split:{clip_id}")[:8], 16) % 2 == 0 else "holdout"


def main(manifest_path: str, out_path: str) -> None:
    manifest = json.loads(Path(manifest_path).read_text())
    clips = next(v for v in manifest.values() if isinstance(v, list))
    rows, dropped = [], collections.Counter()
    for c in clips:
        if not (MIN_SECONDS <= c["seconds"] <= MAX_SECONDS):
            dropped["length"] += 1
            continue
        if not norm(c["prompt"]):
            dropped["empty prompt"] += 1
            continue
        key = norm(c["prompt"])
        if c["split"] == "enrolment":
            role = "val" if int(h(f"val:{key}")[:8], 16) % 100 < VAL_PROMPT_PERCENT else "train"
        else:
            role = split_of(c["id"])
        rows.append({**c, "role": role, "key": key})
    train_keys = {r["key"] for r in rows if r["role"] == "train"}
    # A single word that appears inside a training sentence has been heard in training too.
    train_words = {w for r in rows if r["role"] == "train" for w in r["key"].split()}
    val_keys = {r["key"] for r in rows if r["role"] == "val"}
    own = collections.defaultdict(set)
    for r in rows:
        if r["role"] == "train":
            own[r["speaker"]].add(r["key"])
    for r in rows:
        r["seen"] = r["key"] in train_keys or (r["kind"] == "word" and r["key"] in train_words)
        # Validation picks the stopping point, so its prompts are not perfectly unseen either.
        r["strict_unseen"] = not r["seen"] and r["key"] not in val_keys
        r["seen_same_speaker"] = r["key"] in own[r["speaker"]]
        r["dysarthric"] = "C" not in r["speaker"]
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    Path(out_path).write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    print("dropped", dict(dropped))
    for role in ("train", "val", "dev", "holdout"):
        rs = [r for r in rows if r["role"] == role]
        print(f"{role:8} clips {len(rs):5}  minutes {sum(r['seconds'] for r in rs)/60:6.1f}  "
              f"unseen {sum(not r['seen'] for r in rs):5}  strict {sum(r['strict_unseen'] for r in rs):5}  words {sum(r['kind']=='word' for r in rs):5}  speakers {len({r['speaker'] for r in rs})}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
