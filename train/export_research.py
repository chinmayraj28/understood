"""Writes web/public/research/results.json from the saved runs: numbers only, safe to publish.

  python3 export_research.py            (standard library only)

No prompt, transcript or audio goes into the file. The page reads it on the hosted site too.
"""
import json
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
RUNS = HERE / "runs"
OUT = HERE.parent / "web" / "public" / "research" / "results.json"

LABELS = {
    "unseen": "Prompts never trained on",
    "dysarthric-unseen": "Never trained on, speakers with dysarthria",
    "unseen-word": "Single words, never trained on",
    "unseen-sentence": "Sentences, never trained on",
    "unseen-strict": "Never trained on, and not a validation prompt",
    "all": "All held-out clips",
    "seen": "Prompts also in training",
    "dysarthric": "Speakers with dysarthria",
    "control": "Speakers without dysarthria",
}
NAMES = {"whisper": "Whisper large-v3-turbo", "granite": "Granite Speech 5.0 TurboCTC", "parakeet": "Parakeet TDT 0.6B v3"}


def load(path: Path) -> dict | None:
    return json.loads(path.read_text()) if path.exists() else None


def rate(s: dict) -> dict:
    return {"wer": s["wer"], "low": s["low"], "high": s["high"]}


def dev_row(model: str, stage: str, s: dict) -> dict:
    return {"model": model, "name": NAMES[model], "stage": stage, "unseen": s["unseen"]["wer"], "all": s["all"]["wer"], "words": s["word"]["wer"], "sentences": s["sentence"]["wer"]}


def main() -> None:
    best = load(RUNS / "choice.json")["best"]
    personalised = (RUNS / f"final-tuned-{best}-s2" / "scores-holdout.json").exists()
    tuned_file = load(RUNS / f"final-tuned-{best}-{'s2' if personalised else 's1'}" / "scores-holdout.json")
    untuned, tuned = load(RUNS / f"final-untuned-{best}" / "scores-holdout.json")["holdout"], tuned_file["holdout"]

    clips = [json.loads(line) for line in (HERE / "data" / "clips.jsonl").read_text().splitlines()]
    by_role = defaultdict(list)
    for c in clips:
        by_role[c["role"]].append(c)
    split = [{"role": role, "clips": len(by_role[role]), "minutes": round(sum(c["seconds"] for c in by_role[role]) / 60, 1),
              "neverTrained": sum(not c["seen"] for c in by_role[role]) if role != "train" else 0} for role in ("train", "val", "dev", "holdout")]

    dev = []
    for model in ("whisper", "granite", "parakeet"):
        base = load(RUNS / f"base-{model}" / "scores-dev-val.json")
        s1 = load(RUNS / f"{model}-s1" / "scores-dev.json")
        s2 = load(RUNS / f"{model}-s2" / "scores-dev.json")
        if base:
            dev.append(dev_row(model, "untuned", base["dev"]))
        if s1:
            dev.append(dev_row(model, "tuned", s1["dev"]))
        if s2:
            dev.append(dev_row(model, "personalised", s2["dev"]))

    dysarthric = {c["speaker"]: c["dysarthric"] for c in clips}
    speakers = sorted((k[8:] for k in tuned if k.startswith("speaker:")), key=lambda s: (not dysarthric[s], s))
    config = load(RUNS / f"{best}-s1" / "config.json")
    results = {
        "date": "2026-11-19",
        "model": config["model"],
        "personalised": personalised,
        "speakers": len(speakers),
        "secondsPerClip": tuned_file["seconds_per_clip"],
        "trainingMinutes": next(s["minutes"] for s in split if s["role"] == "train"),
        "split": split,
        "heldOut": [{"key": k, "label": label, "clips": tuned[k]["clips"], "untuned": rate(untuned[k]), "tuned": rate(tuned[k])} for k, label in LABELS.items() if k in tuned and k in untuned],
        "dev": dev,
        "perSpeaker": [{"speaker": s, "dysarthric": dysarthric[s], "untuned": untuned[f"speaker:{s}"]["wer"], "tuned": tuned[f"speaker:{s}"]["wer"]} for s in speakers],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(results, indent=2) + "\n")
    print(f"Wrote {OUT} ({len(results['heldOut'])} held-out rows, {len(dev)} dev rows, {len(speakers)} speakers)")


if __name__ == "__main__":
    main()
