# Fine-tuning result

19 November 2026. One run, one seed, on a Colab T4 (2 hours 40 minutes). Plan and method: `docs/FINETUNE_PLAN.md`. Every step finished; none failed.

## Headline

A Whisper large-v3-turbo model, tuned on 78 minutes of TORGO enrolment clips and then per speaker, gets **24.6%** of words wrong on held-out prompts it never trained on, against **35.6%** untuned. The 95% intervals do not overlap (20.9 to 28.9 against 30.2 to 41.6).

This is the model on its own. Whether it improves the full pipeline (20.6% on its 220-clip sample) is **not tested yet**.

## Held-out clips (scored once)

Share of words wrong, with 95% interval. Lower is better.

| Clips | Untuned | Tuned |
|---|---|---|
| Prompts never trained on (425) | 35.6% (30.2-41.6) | 24.6% (20.9-28.9) |
| Never trained on, and not a validation prompt (379) | 34.2% (28.4-40.9) | 24.6% (20.5-29.1) |
| Never trained on, speakers with dysarthria (356) | 40.8% (34.0-48.3) | 28.5% (23.8-33.5) |
| All held-out clips (1155) | 40.0% (36.3-43.8) | 22.7% (20.3-25.1) |
| Prompts also in training (730) | 43.9% (39.4-48.9) | 21.1% (18.2-24.2) |
| Speakers with dysarthria (940) | 46.3% (42.0-50.8) | 26.9% (24.0-29.8) |
| Speakers without (215) | 11.1% (8.0-14.7) | 3.7% (2.1-5.5) |
| Single words, never trained on (260) | 78.1% (67.7-90.8) | 45.4% (37.7-53.5) |
| Sentences, never trained on (165) | 25.6% (19.3-32.2) | 19.8% (15.4-24.4) |

Per speaker, tuned: F01 47%, F03 24%, F04 8%, M01 39%, M02 55%, M03 2%, M04 46%, M05 21%; controls FC01 2%, FC02 5%, MC01 3%.

Speed: 0.31 s per clip on the T4.

## How the model was chosen (dev clips)

| Model | | Never-trained prompts | All | Single words | Sentences |
|---|---|---|---|---|---|
| Whisper large-v3-turbo | untuned | 29.2% | 37.6% | 65.8% | 25.8% |
| | tuned, all speakers | **23.2%** | 27.7% | 42.5% | 21.5% |
| | tuned per speaker | 21.2% | 22.2% | 30.2% | 18.8% |
| Granite Speech 5.0 TurboCTC | untuned | 29.2% | 37.4% | 68.5% | 24.3% |
| | tuned, all speakers | 24.2% | 27.0% | 40.0% | 21.5% |
| Parakeet TDT 0.6B v3 | untuned | 35.6% | 46.5% | 84.2% | 30.7% |
| | tuned, all speakers | 27.2% | 31.7% | 44.3% | 26.5% |

Whisper was picked by the rule set beforehand (fewest words wrong on never-trained dev prompts). Whisper and Granite are inside each other's margin; Granite trained in 6 minutes against 43 and is the smaller model.

## What it means

- **Training on the voice works at this data size.** About a third of the errors on never-trained prompts are gone, and the gain is on new prompts, not memorised ones.
- **Single words gain most** (78% to 45% on never-trained words) and are still the weak spot.
- **Severe speakers stay hard**: F01, M01, M02 and M04 are between 39% and 55%.
- **Parakeet, the pick from the literature, came last.** The comparison was worth running.

## Limits

- One seed. Validation is 118 clips, and every model's best epoch was 1 to 3 of 8, then validation got worse: they overfit quickly, so a lower learning rate is the first thing to try.
- Per-speaker tuning helped never-trained prompts only slightly on dev (23.2% to 21.2%, inside the margin); most of its gain is on prompts the speaker also said in training.
- 11 speakers, one dataset, and control and dysarthric speakers were recorded differently.
- The held-out clips here (1,155) are not the pipeline's 220-clip sample, so 22.7% and 20.6% are not directly comparable.

## Next

1. Add the tuned model's transcripts as a fifth listener and rerun the pipeline's held-out sample with and without it. This decides whether it earns a place.
2. A local page in the web app to try never-trained clips live.
3. A lower learning rate and three seeds for the chosen setup.

Weights and per-clip transcripts are in the owner's private Drive (`understood-finetune/runs`), not in this repository.
