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
    // A two-pole low-pass at 7 kHz (a standard "biquad") before dropping samples, so sounds
    // above 8 kHz do not fold back down into the speech band of the 16 kHz audio.
    const w = (2 * Math.PI * 7000) / sampleRate;
    const alpha = Math.sin(w) / (2 * Math.SQRT1_2);
    const a0 = 1 + alpha;
    this.b0 = (1 - Math.cos(w)) / 2 / a0;
    this.b1 = (1 - Math.cos(w)) / a0;
    this.b2 = this.b0;
    this.a1 = (-2 * Math.cos(w)) / a0;
    this.a2 = (1 - alpha) / a0;
    this.x1 = 0;
    this.x2 = 0;
    this.y1 = 0;
    this.y2 = 0;
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
      const x = mono[i];
      const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
      this.x2 = this.x1;
      this.x1 = x;
      this.y2 = this.y1;
      this.y1 = y;
      mono[i] = y;
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
