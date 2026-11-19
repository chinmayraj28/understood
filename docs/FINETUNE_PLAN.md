# Fine-tuning plan: a personalised extra listener

19 November 2026. Research tooling in `train/`; nothing in `web/` depends on it yet.

## The question

Does a speech model **trained on the speaker's own recordings** make the pipeline more accurate
than prompting alone? Today nothing is trained: Gemini is shown five of the speaker's clips each
time, and Claude merges the listeners. The pipeline gets 20.6% of words wrong on 220 held-out
TORGO clips (`docs/TRANSCRIPTION.md`).

The tuned model is **one more listener**, not a replacement. It is kept only if it lowers the
whole pipeline's words-wrong figure.

## What "better" means, fixed before any training

| Role | Clips | Minutes | Used for |
|---|---|---|---|
| train | 1,393 | 78 | Training. The enrolment clips, minus the validation prompts |
| val | 118 | 6 | Stopping point and settings. Prompts **no speaker** trains on |
| dev | 1,199 | 74 | Comparing models. Same hash rule as `web/scripts/evalTranscription.ts` |
| holdout | 1,155 | 70 | Scored **once**, at the end |

Built by `train/prepare_data.py`. 32 clips shorter than 0.3 s or longer than 30 s are dropped.

**The trap.** TORGO speakers read the same prompts, so 1,567 of the 2,385 test clips say a prompt
that is somewhere in the training clips. A model can learn the prompts instead of the voice, and
most published TORGO numbers are inflated this way (arXiv 2411.00980: mild speakers went from
about 4% to about 45% of words wrong once the overlap was removed). So every score is reported
twice, and the **headline is prompts never trained on** (432 dev clips, 425 held-out). A single
word that appears inside a training sentence counts as trained on. A stricter column also leaves
out prompts used for validation (378 and 379 clips).

Scoring is `web/shared/wordErrors.ts` ported line for line, with a 95% interval from resampling
clips.

## Candidates

No published result exists for any current open model on TORGO with honest splits, so three are
compared rather than guessed at.

| Model | Type | Why it is in |
|---|---|---|
| `nvidia/parakeet-tdt-0.6b-v3` | Transducer, 600M | The Parakeet family won the 2025 Speech Accessibility Project challenge (8.1% against 10.0% for the best Whisper, arXiv 2507.22047). Decodes frame by frame, so it drops a word rather than inventing a sentence |
| `openai/whisper-large-v3-turbo` | Encoder-decoder, 809M | The most evidence on dysarthric speech. Known to invent text on short clips and pauses |
| `ibm-granite/granite-speech-5.0-470m-turboctc` | CTC, 470M | Cannot invent fluent text, cheapest to run. Released Oct 2026, no dysarthric results yet |

Parakeet v3 is the multilingual version, because the English-only v2 has no weights in the format
the training library loads. Untuned, it answered some single words in French or Russian in a
12-clip check; tuning on English is expected to fix that, and the comparison will show.

## Method

**Stage 1: every speaker together.**
- Only the **encoder** (the part that hears) is trained. The decoder (the part that predicts likely
  words) stays frozen. On a prompt-disjoint TORGO split, encoder-only tuning got 32.6% of words
  wrong and tuning the decoder too got 47.0% (arXiv 2509.16718): a trained decoder learns the
  prompts.
- Whisper and Parakeet: LoRA (small add-on layers, rank 16, alpha 32, dropout 0.05) on every
  encoder linear layer, learning rate 1e-4. LoRA including the feed-forward layers came within
  0.7 points of full fine-tuning (arXiv 2609.02735).
- Granite: all encoder weights, learning rate 1e-5, in full 32-bit precision. It ships in a 16-bit
  format where an update this small rounds away to nothing.
- AdamW, cosine schedule with 10% warm-up, effective batch 16, gradients clipped at 1.0, weights
  in 32-bit with 16-bit mixed precision for Whisper and Parakeet. No 4-bit or 8-bit loading (worse, and saves nothing here).
- Up to 8 epochs. After each, the validation clips are transcribed; the best epoch is kept and
  training stops after 2 epochs without improvement.
- Augmentation: speed 0.9x, 1x or 1.1x, and white noise on 3 clips in 10. SpecAugment is off (it
  hurt LoRA in arXiv 2505.12991).

**Stage 2: one speaker.** Start from the stage 1 model, add a small LoRA (rank 8), train 3 epochs on
that speaker's clips at 2e-4 for 5 epochs (a speaker has only a few dozen training steps, and a
new add-on starts at zero, so a smaller rate changes almost nothing). Pooled-then-personal beat personal-only in two studies
(arXiv 2509.16718, 2603.15261). Each speaker has 3 to 9 minutes, right at the floor the literature
gives, so this is kept **only if** it does not hurt unseen prompts on dev.

**Decoding.** Greedy, no sampling fallback (so a rerun gives the same text), no repeated three-word
runs, at most 64 new tokens.

## Order of work (all in `train/colab.ipynb`, "Run all")

0. Quick check: each model trains on 16 clips, reloads and transcribes, so a broken path shows in
   five minutes, not after an hour.
1. Score the three untuned models on val and dev.
2. Stage 1 for each; score on dev.
3. Pick the one with the fewest words wrong on **unseen dev prompts**.
4. Stage 2 for that one; keep it or not by the rule above.
5. Score the final choice **once** on held-out, next to the same model untuned.
6. Write `runs/RESULTS.md`.

Each finished step is saved to Drive and skipped on a rerun, so a Colab disconnect loses nothing. A
step that fails is reported and the others go on.

## After Colab

1. Add the tuned model's transcripts as a fifth listener in `web/scripts/evalTranscription.ts` and
   rerun the 220 held-out clips with and without it. **This is the decision.** It costs paid API
   calls for the other listeners, because the old cache is gone.
2. If it helps: three seeds for the final setup, then decide how to host it (it cannot run on
   Cloudflare Workers).
3. If it does not: record that prompting matched training at this data size, and stop.

## What would make the result wrong

- **Leakage.** Guarded by the fixed split, selection on val only, and the unseen column.
- **Noise.** Validation is 118 clips, so one seed can mislead. Intervals are reported, and a
  difference smaller than the interval is not a result.
- **Recording conditions.** TORGO's control and dysarthric speakers were recorded differently
  (arXiv 2211.08833), so the gap between them is partly microphones.
- **Eleven speakers.** A model tuned here may not help a twelfth. The Speech Accessibility Project
  data (430 speakers) is the real next step; applying takes weeks.

## Rules

- TORGO is used under its academic, non-profit terms and cited. Audio and trained weights stay in
  the owner's private Drive and are never published: a model can memorise its training speech.
- Nothing trains on dev or held-out clips. Held-out is scored once.
- Python lives only in `train/`. The product in `web/` stays TypeScript.
