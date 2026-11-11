// Turns any audio file the browser can play (WAV, MP3, M4A, OGG, WebM, FLAC) into the 16 kHz
// mono 16-bit samples every request carries. Decoding and resampling happen in this browser;
// nothing is uploaded until the turn itself is sent to be heard.

import { SAMPLE_RATE } from "./wav";

/** The server accepts about a minute of 16 kHz audio per turn (2 MB). */
export const MAX_FILE_SECONDS = 60;

export class AudioFileError extends Error {}

export interface DecodedAudio {
  pcm: Int16Array;
  seconds: number;
}

export async function decodeAudioFile(data: ArrayBuffer): Promise<DecodedAudio> {
  const context = new AudioContext();
  let decoded: AudioBuffer;
  try {
    decoded = await context.decodeAudioData(data.slice(0));
  } catch {
    throw new AudioFileError("This file could not be read as audio. Try a WAV, MP3, M4A or OGG file.");
  } finally {
    void context.close();
  }
  if (decoded.duration > MAX_FILE_SECONDS) {
    throw new AudioFileError(`This recording is ${Math.round(decoded.duration)} seconds long. Trim it to ${MAX_FILE_SECONDS} seconds or less.`);
  }
  if (decoded.duration < 0.2) throw new AudioFileError("This recording is too short to hear anything in.");

  // Mix to mono and resample to 16 kHz in one offline render.
  const frames = Math.ceil(decoded.duration * SAMPLE_RATE);
  const offline = new OfflineAudioContext(1, frames, SAMPLE_RATE);
  const source = offline.createBufferSource();
  source.buffer = decoded;
  source.connect(offline.destination);
  source.start();
  const rendered = await offline.startRendering();
  return { pcm: floatToPcm(rendered.getChannelData(0)), seconds: rendered.duration };
}

export function floatToPcm(samples: Float32Array): Int16Array {
  const out = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    out[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
  }
  return out;
}

/** Reads the samples out of a 16 kHz mono 16-bit WAV (the TORGO format); anything else is decoded. */
export async function readRecording(data: ArrayBuffer): Promise<DecodedAudio> {
  const pcm = plainWavSamples(data);
  if (!pcm) return decodeAudioFile(data);
  const seconds = pcm.length / SAMPLE_RATE;
  if (seconds > MAX_FILE_SECONDS) throw new AudioFileError(`This recording is ${Math.round(seconds)} seconds long. Trim it to ${MAX_FILE_SECONDS} seconds or less.`);
  return { pcm, seconds };
}

function plainWavSamples(data: ArrayBuffer): Int16Array | null {
  const view = new DataView(data);
  if (data.byteLength < 44 || view.getUint32(0, false) !== 0x52494646 || view.getUint32(8, false) !== 0x57415645) return null;
  let offset = 12;
  let ok = false;
  while (offset + 8 <= data.byteLength) {
    const id = view.getUint32(offset, false);
    const size = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === 0x666d7420 /* "fmt " */) {
      if (size < 16 || body + 16 > data.byteLength) return null; // too short to be a format block
      ok = view.getUint16(body, true) === 1 && view.getUint16(body + 2, true) === 1 && view.getUint32(body + 4, true) === SAMPLE_RATE && view.getUint16(body + 14, true) === 16;
      if (!ok) return null;
    } else if (id === 0x64617461 /* "data" */) {
      if (!ok) return null;
      const length = Math.floor(Math.min(size, data.byteLength - body) / 2);
      return new Int16Array(data.slice(body, body + length * 2));
    }
    offset = body + size + (size % 2);
  }
  return null;
}
