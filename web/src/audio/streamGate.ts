// Decides which microphone audio leaves the browser for the live transcript.
//
// Only a turn goes out: nothing while the room is quiet, and from the first loud chunk the
// half second before it (so the first sound of a word is not cut) and then the turn itself.
// Room audio between turns never reaches ElevenLabs.

export class StreamGate {
  private open = false;

  /** `prerollChunks`: how many chunks from just before the sound to send when it starts. */
  constructor(private prerollChunks: number) {}

  /**
   * Called once per chunk. `active` is whether there is sound or a turn right now; `recent` is
   * the audio kept so far, ending with the newest chunk. Returns what to send, and whether the
   * gate has just closed (the sound ended).
   */
  next(active: boolean, recent: Int16Array[]): { send: Int16Array[]; closed: boolean } {
    if (active && !this.open) {
      this.open = true;
      return { send: recent.slice(-(this.prerollChunks + 1)), closed: false };
    }
    if (active) return { send: recent.length ? [recent[recent.length - 1]] : [], closed: false };
    if (this.open) {
      this.open = false;
      return { send: [], closed: true };
    }
    return { send: [], closed: false };
  }

  get isOpen() {
    return this.open;
  }
}
