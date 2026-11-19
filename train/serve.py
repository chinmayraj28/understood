"""Keeps the fine-tuned Whisper in memory and transcribes one short clip per request, for the live demo page.

  cd train && uv run python serve.py                 # http://127.0.0.1:8791
  cd train && uv run python serve.py --port 8792 --runs /path/to/runs

The stage 1 run (every speaker together) is loaded and merged into the model once. Each finished
per-speaker run (stage 2, a small add-on trained on top of that merged model) is then attached to the
same model under the speaker's name, so changing speaker switches a few small layers instead of
loading 800 million weights again. With no speaker, the add-ons are switched off and the merged
stage 1 model answers: that is "all speakers".

  GET  /health      {"ok": true, "model": "...", "speakers": ["F01", ...], "device": "mps"}
  POST /transcribe  {"wavBase64": "<16 kHz mono 16-bit PCM WAV>", "speaker": "M02" | null}
                    -> {"text": "...", "seconds": 0.42, "voice": "M02"}

Only the local Node server calls this: it listens on 127.0.0.1, answers only requests addressed to
127.0.0.1 or localhost, and sends no CORS headers, so a web page in a browser cannot call it.

Research tooling only. It is not part of the product and nothing in web/ imports it.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import io
import json
import sys
import threading
import time
import traceback
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import torch

from asr import SAMPLE_RATE, Listener, load_run, pick_device, prepare_for_peft

MAX_BODY_BYTES = 4 * 1024 * 1024
MIN_SECONDS, MAX_SECONDS = 0.2, 30.0  # Whisper reads at most 30 seconds at a time
ALL_SPEAKERS = "all speakers"


class BadRequest(Exception):
    """A request we refuse with a 400; the message is a plain sentence shown to the caller."""


# ── the model ─────────────────────────────────────────────────────────────────────────────────


def finished_speaker_runs(stage2: Path, stage1: Path) -> dict[str, Path]:
    """Speaker name -> adapter folder, for each per-speaker run that reached its end (has done.json)."""
    runs: dict[str, Path] = {}
    if not stage2.is_dir():
        return runs
    for run in sorted(p for p in stage2.iterdir() if p.is_dir()):
        if not ((run / "done.json").exists() and (run / "adapter").is_dir() and (run / "config.json").exists()):
            continue
        # A per-speaker add-on only makes sense on the model it was trained on top of. The saved parent
        # path is from another machine, so only its folder name can be compared.
        parent = json.loads((run / "config.json").read_text()).get("parent") or ""
        if Path(parent).name != stage1.name:
            print(f"Skipping {run.name}: trained on top of {parent!r}, not {stage1.name}.", file=sys.stderr)
            continue
        runs[run.name] = run / "adapter"
    return runs


class TunedWhisper:
    """The merged stage 1 model with every per-speaker add-on attached by name. One clip at a time."""

    def __init__(self, stage1: Path, stage2: Path):
        from peft import PeftModel

        # Weights stay in float32, as Listener loads them and as training and evaluation ran them. Half
        # precision on MPS would halve memory, but nothing in the installed libraries shows Whisper's
        # generate is numerically safe there, and a demo that drifts from the measured results is worse
        # than one that uses 3 GB of memory.
        self.listener: Listener = load_run(stage1, pick_device())
        self.listener.merge_lora()  # the same starting point finetune.py used for every stage 2 run
        self.speakers = finished_speaker_runs(stage2, stage1)
        if self.speakers:
            names = list(self.speakers)
            prepare_for_peft(self.listener.model)
            model = PeftModel.from_pretrained(self.listener.model, str(self.speakers[names[0]]), adapter_name=names[0])
            for name in names[1:]:
                model.load_adapter(str(self.speakers[name]), adapter_name=name)
            self.listener.model = model
        self.listener.model.to(self.listener.device).eval()
        self.lock = threading.Lock()  # one pointer to one model: a second request waits its turn

    def transcribe(self, wave_: np.ndarray, speaker: str | None) -> tuple[str, str]:
        """(text, the voice that listened). An unknown or missing speaker gets the all-speakers model."""
        voice = speaker if speaker in self.speakers else ALL_SPEAKERS
        with self.lock, torch.inference_mode():
            if voice != ALL_SPEAKERS:
                # inference_mode=True keeps the add-on frozen; the default would mark it trainable.
                self.listener.model.set_adapter(voice, inference_mode=True)
                text = self.listener.transcribe([wave_])[0]
            elif self.speakers:
                # Switches every add-on off for this one call, leaving the merged stage 1 model.
                with self.listener.model.disable_adapter():
                    text = self.listener.transcribe([wave_])[0]
            else:
                text = self.listener.transcribe([wave_])[0]
        return text, voice


# ── requests ──────────────────────────────────────────────────────────────────────────────────


def read_wav(data: bytes) -> np.ndarray:
    """A 16 kHz mono 16-bit PCM WAV as float32 samples in [-1, 1]."""
    try:
        with wave.open(io.BytesIO(data), "rb") as w:
            rate, channels, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
            frames = w.readframes(w.getnframes())
    except (wave.Error, EOFError, ValueError) as error:
        raise BadRequest(f"The audio is not a readable PCM WAV file ({error}).") from None
    if (rate, channels, width) != (SAMPLE_RATE, 1, 2):
        raise BadRequest(f"The WAV must be 16 kHz mono 16-bit; this one is {rate} Hz, {channels} channel(s), {8 * width}-bit.")
    # WAV samples are little-endian. A truncated file can end mid-sample, so the odd byte is dropped.
    samples = np.frombuffer(frames[: len(frames) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
    seconds = len(samples) / SAMPLE_RATE
    if not MIN_SECONDS <= seconds <= MAX_SECONDS:
        raise BadRequest(f"The audio is {seconds:.2f} seconds long; it must be between {MIN_SECONDS} and {MAX_SECONDS:.0f} seconds.")
    return samples


def parse_transcribe_body(body: bytes) -> tuple[np.ndarray, str | None]:
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BadRequest("The body is not valid JSON.") from None
    if not isinstance(request, dict) or not isinstance(request.get("wavBase64"), str):
        raise BadRequest("The body needs a wavBase64 string.")
    speaker = request.get("speaker")
    if speaker is not None and not isinstance(speaker, str):
        raise BadRequest("speaker must be a speaker name or null.")
    try:
        data = base64.b64decode(request["wavBase64"], validate=True)
    except (binascii.Error, ValueError):
        raise BadRequest("wavBase64 is not valid base64.") from None
    return read_wav(data), speaker


def make_handler(model: TunedWhisper, port: int) -> type[BaseHTTPRequestHandler]:
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
    health = {"ok": True, "model": f"{model.listener.model_id}, tuned", "speakers": list(model.speakers), "device": str(model.listener.device)}

    class Handler(BaseHTTPRequestHandler):
        def send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def addressed_to_us(self) -> bool:
            # A web page could make a browser send a request here under another name (DNS rebinding):
            # the Host header shows which name was used, so only the two local names are answered.
            if self.headers.get("Host", "") in allowed_hosts:
                return True
            self.send_json(403, {"error": "This service only answers requests addressed to 127.0.0.1 or localhost."})
            return False

        def do_GET(self) -> None:
            if not self.addressed_to_us():
                return
            if self.path == "/health":
                self.send_json(200, health)
            else:
                self.send_json(404, {"error": f"There is nothing at {self.path}."})

        def do_POST(self) -> None:
            if not self.addressed_to_us():
                return
            if self.path != "/transcribe":
                self.send_json(404, {"error": f"There is nothing at {self.path}."})
                return
            try:
                wave_, speaker = parse_transcribe_body(self.read_body())
                started = time.perf_counter()
                text, voice = model.transcribe(wave_, speaker)
                self.send_json(200, {"text": text, "seconds": round(time.perf_counter() - started, 2), "voice": voice})
            except BadRequest as error:
                self.send_json(400, {"error": str(error)})
            except Exception:
                traceback.print_exc()  # the details go to the terminal, never to the caller
                self.send_json(500, {"error": "The model failed on this clip; the details are in the server's log."})

        def read_body(self) -> bytes:
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                raise BadRequest("The request needs a Content-Length header.") from None
            if length < 0:
                raise BadRequest("The Content-Length header is not valid.")
            if length > MAX_BODY_BYTES:
                raise BadRequest("The body is larger than 4 MB.")  # refused before it is read
            return self.rfile.read(length)

    return Handler


# ── start ─────────────────────────────────────────────────────────────────────────────────────


def main() -> None:
    ap = argparse.ArgumentParser(description="Serve the fine-tuned Whisper on 127.0.0.1 for the live demo page.")
    ap.add_argument("--runs", default=str(Path(__file__).resolve().parent / "runs"), help="the folder holding the saved runs")
    ap.add_argument("--stage1", default="whisper-s1", help="the all-speakers run, inside --runs")
    ap.add_argument("--stage2", default="whisper-s2", help="the folder of per-speaker runs, inside --runs")
    ap.add_argument("--port", type=int, default=8791)
    args = ap.parse_args()

    runs = Path(args.runs)
    stage1 = runs / args.stage1
    if not (stage1 / "config.json").exists():
        raise SystemExit(f"No stage 1 run at {stage1} (expected config.json and adapter/).")
    model = TunedWhisper(stage1, runs / args.stage2)

    # The first call on a device sets up its kernels and takes seconds; a second of silence takes that
    # hit now rather than on the first real clip. Whisper pads every clip to 30 seconds, so the shapes match.
    model.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), None)

    # Loaded before listening, so a refused connection means "not ready yet" rather than a hang.
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(model, args.port))
    count = f"{len(model.speakers)} speakers" if model.speakers else "stage 1 only, no per-speaker runs"
    print(f"Tuned model ready on http://127.0.0.1:{args.port} ({count})", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
