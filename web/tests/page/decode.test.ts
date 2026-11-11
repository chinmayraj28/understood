// TORGO clips are 16 kHz mono 16-bit WAV, so their samples are read straight out of the file;
// only other formats need the browser's decoder.
import { describe, expect, it } from "vitest";
import { floatToPcm, readRecording } from "../../src/audio/decode";
import { encodeWav } from "../../src/audio/wav";

describe("reading a recording", () => {
  it("reads 16 kHz mono 16-bit WAV samples directly", async () => {
    const samples = Int16Array.from([0, 100, -100, 32767, -32768]);
    const wav = encodeWav(samples);
    const { pcm, seconds } = await readRecording(wav.buffer.slice(0) as ArrayBuffer);
    expect([...pcm]).toEqual([...samples]);
    expect(seconds).toBeCloseTo(5 / 16000);
  });

  it("skips chunks before the samples, such as a LIST chunk", async () => {
    const samples = Int16Array.from([1, 2, 3, 4]);
    const plain = encodeWav(samples);
    const list = new Uint8Array([0x4c, 0x49, 0x53, 0x54, 3, 0, 0, 0, 7, 7, 7, 0]); // "LIST", 3 bytes, padded
    const withList = new Uint8Array(plain.length + list.length);
    withList.set(plain.subarray(0, 36));
    withList.set(list, 36);
    withList.set(plain.subarray(36), 36 + list.length);
    const { pcm } = await readRecording(withList.buffer);
    expect([...pcm]).toEqual([1, 2, 3, 4]);
  });

  it("turns float samples into 16-bit, clipping anything out of range", () => {
    expect([...floatToPcm(Float32Array.from([0, 1, -1, 2, -2]))]).toEqual([0, 32767, -32768, 32767, -32768]);
  });
});
