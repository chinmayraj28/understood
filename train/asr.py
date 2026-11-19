"""Shared pieces for fine-tuning a speech recogniser as an extra listener: data, models, scoring.

Three model families are supported through one interface (`Listener`), so the same training and
evaluation code runs each candidate:
  whisper   openai/whisper-large-v3-turbo           encoder-decoder
  parakeet  nvidia/parakeet-tdt-0.6b-v3             transducer (TDT)
  granite   ibm-granite/granite-speech-5.0-470m-turboctc   CTC

Research tooling only. It is not part of the product and nothing in web/ imports it.
"""
from __future__ import annotations

import json
import random
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

SAMPLE_RATE = 16_000

# ── data ──────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Clip:
    id: str
    speaker: str
    kind: str  # "word" or "sentence"
    prompt: str
    audio: str  # path relative to the audio root
    seconds: float
    role: str  # train | val | dev | holdout
    seen: bool
    dysarthric: bool
    strict_unseen: bool = False  # unseen, and not a validation prompt either


def load_clips(path: str | Path, roles: set[str] | None = None, speakers: set[str] | None = None) -> list[Clip]:
    clips = []
    for line in Path(path).read_text().splitlines():
        r = json.loads(line)
        if roles and r["role"] not in roles:
            continue
        if speakers and r["speaker"] not in speakers:
            continue
        clips.append(Clip(r["id"], r["speaker"], r["kind"], r["prompt"], r["audio"], r["seconds"], r["role"], r["seen"], r["dysarthric"], r.get("strict_unseen", False)))
    return clips


def read_audio(root: str | Path, clip: Clip) -> np.ndarray:
    wave, rate = sf.read(str(Path(root) / clip.audio), dtype="float32", always_2d=False)
    if wave.ndim > 1:
        wave = wave.mean(axis=1)
    if rate != SAMPLE_RATE:
        raise ValueError(f"{clip.id}: expected {SAMPLE_RATE} Hz, got {rate}")
    return wave


def augment(wave: np.ndarray, rng: random.Random) -> np.ndarray:
    """Speed change (0.9x, 1x or 1.1x) and, for 3 clips in 10, white noise 10 to 25 dB below the speech."""
    import torchaudio.functional as AF

    factor = rng.choice([0.9, 1.0, 1.1])
    if factor != 1.0:
        # Reading the samples as if recorded at rate*factor and resampling back plays them faster or slower.
        wave = AF.resample(torch.from_numpy(wave), int(SAMPLE_RATE * factor), SAMPLE_RATE).numpy()
    if rng.random() < 0.3:
        # Measured over the speech, not the silence around it, so the stated level holds for short words.
        loud = wave[np.abs(wave) > 0.02 * (np.abs(wave).max() + 1e-10)]
        power = float(np.mean((loud if len(loud) else wave) ** 2)) + 1e-10
        snr_db = rng.uniform(10, 25)
        noise = np.random.default_rng(rng.getrandbits(32)).standard_normal(len(wave)).astype("float32")
        wave = wave + noise * np.sqrt(power / (10 ** (snr_db / 10)))
    return np.clip(wave, -1.0, 1.0).astype("float32")


def batches_by_length(clips: list[Clip], max_clips: int, max_seconds: float, rng: random.Random | None) -> list[list[Clip]]:
    """Clips of similar length together, so little of a batch is padding. Shuffled when rng is given."""
    # A little randomness in the order when training, so the same clips do not share a batch every epoch.
    order = sorted(clips, key=lambda c: c.seconds * (1 + 0.05 * rng.random()) if rng else c.seconds)
    out, current, longest = [], [], 0.0
    for clip in order:
        longest_next = max(longest, clip.seconds)
        if current and (len(current) >= max_clips or longest_next * (len(current) + 1) > max_seconds):
            out.append(current)
            current, longest_next = [], clip.seconds
        current.append(clip)
        longest = longest_next
    if current:
        out.append(current)
    if rng:
        rng.shuffle(out)
    return out


# ── scoring: a port of web/shared/wordErrors.ts, so numbers compare with the evaluation ─────────

_ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def _number_words(value: int, digits: str) -> list[str]:
    if value >= 10_000:
        return [digits]
    if value < 20:
        return [_ONES[value]]
    if value < 100:
        return [_TENS[value // 10]] if value % 10 == 0 else [_TENS[value // 10], _ONES[value % 10]]
    if value < 1000:
        rest = value % 100
        return [_ONES[value // 100], "hundred"] + ([] if rest == 0 else _number_words(rest, str(rest)))
    rest = value % 1000
    return _number_words(value // 1000, str(value // 1000)) + ["thousand"] + ([] if rest == 0 else _number_words(rest, str(rest)))


def scoring_words(text: str) -> list[str]:
    """Lower case, apostrophes dropped, everything that is not a letter or digit a space, digits as words."""
    cleaned = "".join(c if unicodedata.category(c)[0] in "LMN" else " " for c in text.lower() if c not in "'’")
    spaced = re.sub(r"([0-9])(?=[^0-9\s])|([^0-9\s])(?=[0-9])", lambda m: (m.group(1) or m.group(2)) + " ", cleaned)
    words: list[str] = []
    for token in spaced.split():
        words += _number_words(int(token), token) if re.fullmatch(r"[0-9]+", token) else [token]
    return words


def word_errors(reference: str, hypothesis: str) -> tuple[int, int]:
    """(errors, reference words): the fewest insertions, deletions and substitutions."""
    ref, hyp = scoring_words(reference), scoring_words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        previous, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            previous, row[j] = row[j], min(previous + (r != h), row[j] + 1, row[j - 1] + 1)
    return row[-1], len(ref)


def error_rate(pairs: list[tuple[int, int]]) -> float:
    """Corpus level: total errors over total reference words."""
    words = sum(n for _, n in pairs)
    return sum(e for e, _ in pairs) / words if words else 0.0


def bootstrap_interval(pairs: list[tuple[int, int]], seed: int = 0, rounds: int = 1000) -> tuple[float, float]:
    """95% interval of the error rate, resampling clips with replacement."""
    if not pairs:
        return 0.0, 0.0
    rng = np.random.default_rng(seed)
    arr = np.array(pairs, dtype=np.float64)
    picks = rng.integers(0, len(arr), size=(rounds, len(arr)))
    sums = arr[picks].sum(axis=1)
    rates = np.sort(sums[:, 0] / np.maximum(sums[:, 1], 1))
    return float(rates[int(0.025 * rounds)]), float(rates[int(0.975 * rounds) - 1])


# ── models ────────────────────────────────────────────────────────────────────────────────────

WHISPER_LORA_LEAVES = ("q_proj", "k_proj", "v_proj", "out_proj", "fc1", "fc2")


def pick_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def family_of(model_id: str) -> str:
    name = model_id.lower()
    for family in ("whisper", "parakeet", "granite"):
        if family in name:
            return family
    raise ValueError(f"Unknown model family for {model_id}")


def encoder_linear_names(model: torch.nn.Module, family: str) -> list[str]:
    """The encoder's linear layers: where LoRA goes. The decoder stays frozen, so it cannot learn the prompts."""
    names = []
    for name, module in model.named_modules():
        # ".encoder_attn." is the decoder looking at the encoder: part of the decoder, so left alone.
        if not isinstance(module, torch.nn.Linear) or "encoder" not in name or "lora_" in name or ".encoder_attn." in name:
            continue
        if family == "whisper" and name.rsplit(".", 1)[-1] not in WHISPER_LORA_LEAVES:
            continue
        names.append(name)
    return names


def prepare_for_peft(model: torch.nn.Module) -> None:
    """PEFT asks a model for its text-embedding layer, to hook it and to look for tied weights. A
    speech model without one (Granite) raises there. Neither applies here, so both are switched off."""
    try:
        model.get_input_embeddings()
    except (NotImplementedError, AttributeError):
        model.enable_input_require_grads = lambda: None
        model.config.tie_word_embeddings = False


class Listener:
    """One speech model with what training and evaluation need: features, loss, transcripts."""

    def __init__(self, model_id: str, device: torch.device | None = None):
        from transformers import AutoProcessor

        self.model_id = model_id
        self.family = family_of(model_id)
        self.device = device or pick_device()
        self.processor = AutoProcessor.from_pretrained(model_id)
        if self.family == "whisper":
            from transformers import WhisperForConditionalGeneration

            self.model = WhisperForConditionalGeneration.from_pretrained(model_id, dtype=torch.float32)
            self.processor.tokenizer.set_prefix_tokens(language="en", task="transcribe", predict_timestamps=False)
        elif self.family == "parakeet":
            from transformers import AutoModelForTDT

            self.model = AutoModelForTDT.from_pretrained(model_id, dtype=torch.float32)
        else:
            from transformers import AutoModelForCTC

            self.model = AutoModelForCTC.from_pretrained(model_id, dtype=torch.float32)
        self.model.to(self.device)
        # 16-bit maths on a GPU halves memory. Not for Granite: it was trained in another 16-bit
        # format and can overflow in this one.
        self.amp = self.device.type == "cuda" and self.family != "granite"

    # -- which weights train --

    def freeze_all(self) -> None:
        for p in self.model.parameters():
            p.requires_grad_(False)

    def add_lora(self, rank: int, alpha: int, dropout: float) -> None:
        from peft import LoraConfig, get_peft_model

        self.freeze_all()
        targets = encoder_linear_names(self.model, self.family)
        if not targets:
            raise RuntimeError("No encoder linear layers found for LoRA.")
        prepare_for_peft(self.model)
        self.model = get_peft_model(self.model, LoraConfig(r=rank, lora_alpha=alpha, lora_dropout=dropout, target_modules=targets, bias="none"))

    def train_encoder(self) -> None:
        """Full fine-tuning of the encoder (and a CTC output layer); the decoder stays frozen."""
        self.freeze_all()
        for name, p in self.model.named_parameters():
            if ("encoder" in name and ".encoder_attn." not in name) or (self.family == "granite" and ("ctc" in name or "lm_head" in name or "head" in name)):
                p.requires_grad_(True)

    def trainable_state(self) -> dict[str, torch.Tensor]:
        return {n: p.detach().to("cpu", torch.float32) for n, p in self.model.named_parameters() if p.requires_grad}

    def merge_lora(self) -> None:
        if hasattr(self.model, "merge_and_unload"):
            self.model = self.model.merge_and_unload()

    # -- features, loss, transcripts --

    def features(self, waves: list[np.ndarray], texts: list[str] | None = None) -> dict[str, torch.Tensor]:
        if self.family == "whisper":
            fe = self.processor.feature_extractor(waves, sampling_rate=SAMPLE_RATE, return_tensors="pt", return_attention_mask=True)
            batch = {"input_features": fe.input_features, "attention_mask": fe.attention_mask}
            if texts is not None:
                # Whisper writes its first word with a leading space; the labels must match what the frozen decoder produces.
                ids = self.processor.tokenizer([" " + t.strip() for t in texts], return_tensors="pt", padding=True)
                labels = ids.input_ids.masked_fill(ids.attention_mask.ne(1), -100)
                # The model adds the start token itself when it shifts the labels right.
                if (labels[:, 0] == self.model.config.decoder_start_token_id).all():
                    labels = labels[:, 1:]
                batch["labels"] = labels
        else:
            kwargs = {"text": texts} if texts is not None else {}
            enc = self.processor(audio=waves, sampling_rate=SAMPLE_RATE, return_tensors="pt", padding=True, **kwargs)
            batch = {k: v for k, v in enc.items() if isinstance(v, torch.Tensor)}
            if texts is not None and "labels" not in batch:
                raise RuntimeError(f"The {self.family} processor returned no labels; keys: {list(enc.keys())}")
        return {k: v.to(self.device) for k, v in batch.items()}

    def loss(self, waves: list[np.ndarray], texts: list[str]) -> torch.Tensor:
        return self.model(**self.features(waves, texts)).loss

    @torch.no_grad()
    def transcribe(self, waves: list[np.ndarray]) -> list[str]:
        batch = self.features(waves)
        if self.family == "whisper":
            # Greedy, no sampling fallback (so a rerun gives the same text), and no repeated
            # three-word runs: the loop Whisper falls into on short or unclear clips.
            ids = self.model.generate(
                input_features=batch["input_features"], attention_mask=batch["attention_mask"], language="en", task="transcribe",
                max_new_tokens=64, num_beams=1, do_sample=False, no_repeat_ngram_size=3,
            )
            return [t.strip() for t in self.processor.tokenizer.batch_decode(ids, skip_special_tokens=True)]
        out = self.model.generate(**batch)
        ids = out.sequences if hasattr(out, "sequences") else out
        return [t.strip() for t in self.processor.batch_decode(ids, skip_special_tokens=True)]


# ── saved runs ────────────────────────────────────────────────────────────────────────────────


def save_run(listener: Listener, run_dir: Path, config: dict) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    if config["method"] == "lora":
        listener.model.save_pretrained(str(run_dir / "adapter"))
    else:
        from safetensors.torch import save_file

        save_file(listener.trainable_state(), str(run_dir / "encoder.safetensors"))
    (run_dir / "config.json").write_text(json.dumps(config, indent=2))


def load_run(run_dir: str | Path, device: torch.device | None = None) -> Listener:
    """A listener with a saved run's weights applied (and its parent's first, for a per-speaker run)."""
    run_dir = Path(run_dir)
    config = json.loads((run_dir / "config.json").read_text())
    if config.get("parent"):
        parent = Path(config["parent"])
        if not parent.exists():  # the runs folder was moved (Drive to a laptop): look beside and above this run
            parent = next((p / parent.name for p in run_dir.parents if (p / parent.name / "config.json").exists()), parent)
        listener = load_run(parent, device)
        listener.merge_lora()
    else:
        listener = Listener(config["model"], device)
    if config["method"] == "lora":
        from peft import PeftModel

        prepare_for_peft(listener.model)
        listener.model = PeftModel.from_pretrained(listener.model, str(run_dir / "adapter"))
    else:
        from safetensors.torch import load_file

        state = {k: v.float() for k, v in load_file(str(run_dir / "encoder.safetensors")).items()}
        missing = [k for k in state if k not in dict(listener.model.named_parameters())]
        if missing:
            raise RuntimeError(f"Saved weights do not match the model: {missing[:3]}")
        listener.model.load_state_dict(state, strict=False)
    listener.model.to(listener.device).eval()
    return listener


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
