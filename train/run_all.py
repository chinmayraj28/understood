"""Runs the whole experiment in order (the same steps as colab.ipynb, as one script).

  python run_all.py --runs /content/drive/MyDrive/understood-finetune/runs

Every finished step leaves a file and is skipped on a rerun. A step that fails is reported and
the others go on.
"""
import argparse
import json
import os
import subprocess
import sys

MODELS = {
    # Whisper always works on 30-second windows, so it needs small batches on a T4 (2 x 8 = 16 clips a step).
    "whisper": dict(id="openai/whisper-large-v3-turbo", method="lora", extra="--batch-clips 2 --accumulate 8"),
    "parakeet": dict(id="nvidia/parakeet-tdt-0.6b-v3", method="lora", extra=""),
    # Granite trains in full 32-bit precision (see asr.py), so its batches are smaller too.
    "granite": dict(id="ibm-granite/granite-speech-5.0-470m-turboctc", method="encoder", extra="--batch-clips 4 --accumulate 4 --batch-seconds 40"),
}
SEED = 0
failed: list[str] = []


def step(name: str, done_file: str, command: str, stale: tuple[str, ...] = ()) -> bool:
    if os.path.exists(done_file):
        print(f"[skip] {name}: already done", flush=True)
        return True
    for path in stale:
        if os.path.exists(path):
            os.remove(path)
    print(f"\n===== {name} =====\n{command}", flush=True)
    code = subprocess.run(command, shell=True).returncode
    if code != 0 or not os.path.exists(done_file):
        failed.append(name)
        print(f"[FAILED] {name} (exit {code})", flush=True)
        return False
    return True


def scores(path: str, role: str = "dev") -> dict:
    return json.load(open(path))[role]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True)
    ap.add_argument("--quick", default="/content/quick")
    args = ap.parse_args()
    RUNS, QUICK = args.runs, args.quick
    os.makedirs(RUNS, exist_ok=True)
    py = sys.executable

    print("##### 0. Quick check", flush=True)
    for name, m in list(MODELS.items()):
        q = f"{QUICK}/{name}"
        ok = step(f"quick train {name}", f"{q}/done.json", f"{py} finetune.py --model {m['id']} --method {m['method']} {m['extra']} --limit 16 --epochs 1 --out {q}")
        ok = ok and step(f"quick reload {name}", f"{q}/scores-val.json", f"{py} evaluate.py --run {q} --roles val --limit 8 --out {q}")
        ok = ok and step(f"quick personalise {name}", f"{q}-s2/F01/done.json", f"{py} finetune.py --parent {q} --speaker F01 {m['extra']} --limit 8 --epochs 1 --out {q}-s2/F01")
        ok = ok and step(f"quick personalised reload {name}", f"{q}-s2/scores-val.json", f"{py} evaluate.py --per-speaker-runs {q}-s2 --fallback-run {q} --roles val --limit 8 --out {q}-s2")
        if not ok:
            print(f">>> {name} is left out of this run", flush=True)
            MODELS.pop(name)
    if not MODELS:
        raise SystemExit("Every model failed the quick check.")
    print("Models going ahead:", list(MODELS), flush=True)

    print("##### 1. Untuned models", flush=True)
    for name, m in MODELS.items():
        step(f"baseline {name}", f"{RUNS}/base-{name}/scores-dev-val.json", f"{py} evaluate.py --model {m['id']} --roles val,dev --out {RUNS}/base-{name}")

    print("##### 2. Fine-tune each model on all speakers", flush=True)
    for name, m in MODELS.items():
        ok = step(f"train {name}", f"{RUNS}/{name}-s1/done.json",
                  f"{py} finetune.py --model {m['id']} --method {m['method']} --seed {SEED} {m['extra']} --out {RUNS}/{name}-s1",
                  stale=(f"{RUNS}/{name}-s1/scores-dev.json",))
        if ok:
            step(f"score {name}", f"{RUNS}/{name}-s1/scores-dev.json", f"{py} evaluate.py --run {RUNS}/{name}-s1 --roles dev --out {RUNS}/{name}-s1")

    print("##### 3. Compare on the dev clips and pick one", flush=True)
    rows = []
    for name in MODELS:
        for tag, path in (("untuned", f"{RUNS}/base-{name}/scores-dev-val.json"), ("tuned", f"{RUNS}/{name}-s1/scores-dev.json")):
            if os.path.exists(path) and (tag == "untuned" or os.path.exists(f"{RUNS}/{name}-s1/done.json")):
                s = scores(path)
                rows.append((name, tag, s["unseen"]["wer"], s["all"]["wer"], s.get("dysarthric-unseen", {}).get("wer"), s["word"]["wer"], s["sentence"]["wer"]))
    print(f"{'model':10}{'':9}{'unseen':>8}{'all':>8}{'dys-unseen':>12}{'words':>8}{'sentences':>11}")
    for r in rows:
        print(f"{r[0]:10}{r[1]:9}" + "".join(f"{(x or 0)*100:>{w}.1f}" for x, w in zip(r[2:], (8, 8, 12, 8, 11))))
    tuned = [r for r in rows if r[1] == "tuned"]
    if not tuned:
        raise SystemExit("No model finished training. See the errors above.")
    BEST = min(tuned, key=lambda r: r[2])[0]  # fewest words wrong on unseen prompts
    json.dump({"best": BEST, "rows": rows}, open(f"{RUNS}/choice.json", "w"), indent=2)
    print("\nChosen:", BEST, flush=True)

    print("##### 4. Personalise the chosen model per speaker", flush=True)
    speakers = sorted({json.loads(line)["speaker"] for line in open("data/clips.jsonl")})
    s2_scores = f"{RUNS}/{BEST}-s2/scores-dev.json"
    for sp in speakers:
        step(f"personalise {sp}", f"{RUNS}/{BEST}-s2/{sp}/done.json",
             f"{py} finetune.py --parent {RUNS}/{BEST}-s1 --speaker {sp} --seed {SEED} {MODELS[BEST]['extra']} --out {RUNS}/{BEST}-s2/{sp}", stale=(s2_scores,))
    # A speaker whose run did not finish is heard by the all-speakers model instead.
    for sp in speakers:
        base = f"{RUNS}/{BEST}-s2/{sp}"
        if not os.path.exists(f"{base}/done.json") and os.path.exists(f"{base}/config.json"):
            os.remove(f"{base}/config.json")
    step("score personalised", s2_scores, f"{py} evaluate.py --per-speaker-runs {RUNS}/{BEST}-s2 --fallback-run {RUNS}/{BEST}-s1 --roles dev --out {RUNS}/{BEST}-s2")
    s1 = scores(f"{RUNS}/{BEST}-s1/scores-dev.json")
    s2 = scores(s2_scores) if os.path.exists(s2_scores) else None
    print("dev, unseen prompts: all speakers together", s1["unseen"]["wer"], " personalised", s2 and s2["unseen"]["wer"])
    print("dev, all prompts:    all speakers together", s1["all"]["wer"], " personalised", s2 and s2["all"]["wer"])
    # Personalising is kept only if it does not hurt unseen prompts and helps overall.
    USE_S2 = bool(s2) and s2["unseen"]["wer"] <= s1["unseen"]["wer"] + 0.005 and s2["all"]["wer"] < s1["all"]["wer"]
    print("Keep personalised models:", USE_S2, flush=True)

    print("##### 5. Final score on the held-out clips (once)", flush=True)
    m = MODELS[BEST]
    TAG = f"{BEST}-{'s2' if USE_S2 else 's1'}"  # the folders name the setup, so a different choice is never mixed up with this one
    FU, FT = f"{RUNS}/final-untuned-{BEST}", f"{RUNS}/final-tuned-{TAG}"
    step("held-out, untuned", f"{FU}/scores-holdout.json", f"{py} evaluate.py --model {m['id']} --roles holdout --out {FU}")
    final_cmd = f"{py} evaluate.py --per-speaker-runs {RUNS}/{BEST}-s2 --fallback-run {RUNS}/{BEST}-s1" if USE_S2 else f"{py} evaluate.py --run {RUNS}/{BEST}-s1"
    step("held-out, tuned", f"{FT}/scores-holdout.json", f"{final_cmd} --roles holdout --out {FT}")

    lines = ["# Fine-tuning result", "", f"Chosen model: **{m['id']}** ({'personalised per speaker' if USE_S2 else 'one model for all speakers'}).", ""]
    paths = [f"{FU}/scores-holdout.json", f"{FT}/scores-holdout.json"]
    if all(os.path.exists(p) for p in paths):
        a, b = (scores(p, "holdout") for p in paths)
        lines += ["Share of words wrong on the held-out clips (95% interval). Lower is better.", "", "| Clips | Untuned | Tuned |", "|---|---|---|"]
        label = {"unseen": "Prompts never trained on", "unseen-strict": "Never trained on, and not a validation prompt", "dysarthric-unseen": "Never trained on, speakers with dysarthria",
                 "all": "All held-out clips", "seen": "Prompts also in training", "dysarthric": "Speakers with dysarthria", "control": "Speakers without",
                 "unseen-word": "Single words, never trained on", "unseen-sentence": "Sentences, never trained on"}
        fmt = lambda s: f"{s['wer']*100:.1f}% ({s['low']*100:.1f}-{s['high']*100:.1f})"
        for k, name in label.items():
            if k in a and k in b:
                lines.append(f"| {name} ({a[k]['clips']}) | {fmt(a[k])} | {fmt(b[k])} |")
        lines += ["", "Per speaker, tuned: " + ", ".join(f"{k[8:]} {v['wer']*100:.0f}%" for k, v in b.items() if k.startswith("speaker:")),
                  "", f"Speed: {json.load(open(paths[1]))['seconds_per_clip']} s per clip on this GPU."]
    else:
        lines += ["The held-out scoring did not finish. See the failed steps."]
    lines += ["", "Dev comparison: see choice.json.", "", "Failed steps: " + (", ".join(failed) or "none")]
    open(f"{RUNS}/RESULTS.md", "w").write("\n".join(lines))
    print("\n".join(lines))
    print("##### ALL DONE", flush=True)


if __name__ == "__main__":
    main()
