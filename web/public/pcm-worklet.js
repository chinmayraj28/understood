// Runs on the browser's audio thread. Takes the microphone at whatever rate the device uses
// (usually 48 kHz), mixes it to mono, resamples it to 16 kHz, and posts 20 ms chunks of 16-bit
// samples with their loudness in dBFS. Plain JavaScript because worklets load as separate files.

const TARGET_RATE = 16000;
const CHUNK = 320; // 20 ms at 16 kHz

class PcmResampler extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / TARGET_RATE;
    this.position = 0; // where the next output sample falls, in input samples
    this.previous = 0; // the last input sample of the previous block, for interpolation
    this.out = new Int16Array(CHUNK);
    this.filled = 0;
    this.sumSquares = 0;
    // A gentle low-pass before dropping samples, so high sounds do not fold into speech.
    this.smoothed = 0;
    this.alpha = Math.min(1, (2 * Math.PI * 7000) / sampleRate / (1 + (2 * Math.PI * 7000) / sampleRate));
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0 || input[0].length === 0) return true;
    const length = input[0].length;
    const mono = new Float32Array(length);
    for (let c = 0; c < input.length; c++) {
      const channel = input[c];
      for (let i = 0; i < length; i++) mono[i] += channel[i] / input.length;
    }
    for (let i = 0; i < length; i++) {
      this.smoothed += this.alpha * (mono[i] - this.smoothed);
      mono[i] = this.smoothed;
    }

    while (this.position < length) {
      const index = Math.floor(this.position);
      const fraction = this.position - index;
      const a = index === 0 ? this.previous : mono[index - 1];
      const b = mono[index];
      const sample = a + (b - a) * fraction;
      const clipped = Math.max(-1, Math.min(1, sample));
      this.out[this.filled++] = clipped < 0 ? clipped * 0x8000 : clipped * 0x7fff;
      this.sumSquares += clipped * clipped;
      if (this.filled === CHUNK) {
        const rms = Math.sqrt(this.sumSquares / CHUNK);
        const db = rms > 0 ? 20 * Math.log10(rms) : -120;
        this.port.postMessage({ pcm: this.out, db }, [this.out.buffer]);
        this.out = new Int16Array(CHUNK);
        this.filled = 0;
        this.sumSquares = 0;
      }
      this.position += this.ratio;
    }
    this.position -= length;
    this.previous = mono[length - 1];
    return true;
  }
}

registerProcessor("pcm-resampler", PcmResampler);
