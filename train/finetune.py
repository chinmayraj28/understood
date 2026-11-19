"""Fine-tunes one speech model on the training clips.

Stage 1, every speaker together:
  python finetune.py --model openai/whisper-large-v3-turbo --method lora --out runs/whisper-s1
Stage 2, one speaker, starting from a stage 1 run (a small new LoRA on top of it):
  python finetune.py --parent runs/whisper-s1 --speaker M02 --out runs/whisper-s2/M02

After each epoch the validation clips (prompts never trained on) are transcribed. The epoch with
the fewest words wrong is the one kept, and training stops when it has not improved for
`--patience` epochs. The test clips are never read here.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import subprocess
import time
from pathlib import Path

import torch

from asr import Listener, augment, batches_by_length, error_rate, load_clips, load_run, read_audio, save_run, set_seed, word_errors
from evaluate import transcribe_clips


def git_commit() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="a Hugging Face model id (stage 1)")
    ap.add_argument("--parent", help="a stage 1 run to personalise (stage 2)")
    ap.add_argument("--speaker", help="train on this speaker's clips only")
    ap.add_argument("--method", choices=["lora", "encoder"], default="lora", help="lora: small add-on layers in the encoder; encoder: all encoder weights")
    ap.add_argument("--clips", default="data/clips.jsonl")
    ap.add_argument("--audio", default="data/audio")
    ap.add_argument("--out", required=True)
    ap.add_argument("--lr", type=float)
    ap.add_argument("--epochs", type=int)
    ap.add_argument("--patience", type=int, default=2)
    ap.add_argument("--batch-clips", type=int, default=8)
    ap.add_argument("--batch-seconds", type=float, default=80.0, help="longest clip x clips in a batch stays under this")
    ap.add_argument("--accumulate", type=int, default=2)
    ap.add_argument("--lora-rank", type=int, default=16)
    ap.add_argument("--lora-alpha", type=int, default=32)
    ap.add_argument("--no-augment", action="store_true")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--limit", type=int, default=0, help="only N training clips (for a quick check)")
    args = ap.parse_args()
    if bool(args.model) == bool(args.parent):
        raise SystemExit("Give either --model (stage 1) or --parent (stage 2).")

    set_seed(args.seed)
    rng = random.Random(args.seed)
    stage2 = bool(args.parent)
    if stage2:
        listener = load_run(args.parent)
        listener.merge_lora()
        method = "lora"  # a per-speaker run is always a small add-on, so eight speakers stay small on disk
        rank, alpha = 8, 16
    else:
        listener = Listener(args.model)
        method, rank, alpha = args.method, args.lora_rank, args.lora_alpha
    if method == "lora":
        listener.add_lora(rank, alpha, dropout=0.05)
    else:
        listener.train_encoder()
    # Defaults from the research in docs/FINETUNE_PLAN.md: LoRA 1e-4, full encoder 1e-5. A per-speaker run
    # has only a few dozen steps and a new add-on that starts at zero, so it needs a larger rate (2e-4).
    lr = args.lr or (2e-4 if stage2 else 1e-4 if method == "lora" else 1e-5)
    epochs = args.epochs or (5 if stage2 else 8)

    speakers = {args.speaker} if args.speaker else None
    train = load_clips(args.clips, {"train"}, speakers)
    val = load_clips(args.clips, {"val"}, speakers)
    if args.limit:
        train, val = train[: args.limit], val[: max(4, args.limit // 4)]
    if not train:
        raise SystemExit("No training clips.")
    # With very few validation clips one word decides the score, so a per-speaker run keeps its last epoch.
    select_on_val = len(val) >= 30

    params = [p for p in listener.model.parameters() if p.requires_grad]
    optimiser = torch.optim.AdamW(params, lr=lr, weight_decay=0.0)
    steps_per_epoch = math.ceil(len(batches_by_length(train, args.batch_clips, args.batch_seconds, None)) / args.accumulate)
    total_steps = steps_per_epoch * epochs
    warmup = max(1, int(0.1 * total_steps))
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimiser, lambda s: (s + 1) / warmup if s < warmup else 0.5 * (1 + math.cos(math.pi * (s - warmup) / max(1, total_steps - warmup)))
    )
    use_amp = listener.amp
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    # done.json marks a run that reached its end. A run cut off midway has weights but no marker.
    (out / "done.json").unlink(missing_ok=True)
    config = {
        "model": listener.model_id, "family": listener.family, "method": method, "parent": args.parent, "speaker": args.speaker,
        "lr": lr, "epochs": epochs, "patience": args.patience, "batch_clips": args.batch_clips, "batch_seconds": args.batch_seconds,
        "accumulate": args.accumulate, "lora_rank": rank if method == "lora" else None, "lora_alpha": alpha if method == "lora" else None,
        "augment": not args.no_augment, "seed": args.seed, "train_clips": len(train), "val_clips": len(val),
        "trainable_parameters": sum(p.numel() for p in params), "git": git_commit(), "torch": torch.__version__, "device": str(listener.device),
    }
    print(json.dumps(config, indent=2))
    log = (out / "log.jsonl").open("w")

    best, best_epoch, stale, step = float("inf"), 0, 0, 0
    started = time.time()
    for epoch in range(1, epochs + 1):
        listener.model.train()
        for module in listener.model.modules():
            if isinstance(module, torch.nn.modules.batchnorm._BatchNorm):
                module.eval()  # their running averages are not saved with a run, so they stay fixed
        skipped = 0
        batches = batches_by_length(train, args.batch_clips, args.batch_seconds, rng)
        running, counted = 0.0, 0
        optimiser.zero_grad(set_to_none=True)
        for i, batch in enumerate(batches, 1):
            waves = [read_audio(args.audio, c) for c in batch]
            if not args.no_augment:
                waves = [augment(w, rng) for w in waves]
            with torch.autocast("cuda", dtype=torch.float16, enabled=use_amp):
                loss = listener.loss(waves, [c.prompt for c in batch])
            if not torch.isfinite(loss):
                print(f"  skipped a batch with a non-finite loss ({[c.id for c in batch][:3]}...)")
                optimiser.zero_grad(set_to_none=True)
                skipped += 1
                continue
            scaler.scale(loss / args.accumulate).backward()
            running, counted = running + float(loss), counted + 1
            if i % args.accumulate == 0 or i == len(batches):
                scaler.unscale_(optimiser)
                torch.nn.utils.clip_grad_norm_(params, 1.0)
                scaler.step(optimiser)
                scaler.update()
                optimiser.zero_grad(set_to_none=True)
                schedule.step()
                step += 1
        if skipped > 0.05 * len(batches):
            raise SystemExit(f"{skipped} of {len(batches)} batches had a non-finite loss: this run is broken, not finished.")
        train_loss = running / max(counted, 1)

        entry = {"epoch": epoch, "step": step, "train_loss": round(train_loss, 4), "minutes": round((time.time() - started) / 60, 1)}
        if val:
            texts = transcribe_clips(listener, val, args.audio)
            wer = error_rate([word_errors(c.prompt, texts[c.id]) for c in val])
            entry["val_wer"] = round(wer, 4)
        log.write(json.dumps(entry) + "\n")
        log.flush()
        print(entry)

        if not select_on_val:
            best_epoch = epoch
            continue
        if wer < best - 1e-6:
            best, best_epoch, stale = wer, epoch, 0
            save_run(listener, out, {**config, "best_epoch": epoch, "val_wer": round(wer, 4)})
        else:
            stale += 1
            if stale >= args.patience:
                print(f"No improvement for {args.patience} epochs: stopping. Best was epoch {best_epoch} ({best*100:.1f}% of words wrong).")
                break
    if not select_on_val:
        save_run(listener, out, {**config, "best_epoch": best_epoch, "val_wer": entry.get("val_wer")})
    (out / "done.json").write_text(json.dumps({"best_epoch": best_epoch}))
    print(f"Saved {out} (epoch {best_epoch}).")


if __name__ == "__main__":
    main()
