// A check beyond TORGO: sentences synthesised with macOS voices (several voices, slow and normal
// speed, some with background noise), heard the way the page hears an uploaded file with "Nobody
// in particular": no examples, no phrasebook, no hints. It is not impaired speech; it checks that
// the transcription pipeline works on audio it has never seen and does not damage clear speech.
//
//   npx tsx scripts/evalUploads.ts [--tag after]

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { UnderstandRequest } from "../shared/pipeline";
import { countErrors, errorRate, sameWords } from "../shared/wordErrors";
import { realDeps, type Env } from "../server/app";
import { understandTurn } from "../server/understand";
import { bestText, hearersOf, newTurn, reduceTurn } from "../src/model/turn";

const repo = (relative: string) => fileURLToPath(new URL(`../../${relative}`, import.meta.url));
const tag = process.argv.includes("--tag") ? process.argv[process.argv.indexOf("--tag") + 1] : "run";
const work = path.join(process.env.EVAL_OUT || path.join(tmpdir(), "understood-eval-out"), "uploads");
mkdirSync(work, { recursive: true });

const env: Env = {};
try {
  for (const line of readFileSync(repo(".env"), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
    if (m) (env as Record<string, string>)[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch {
  for (const k of ["ELEVENLABS_API_KEY", "OPENROUTER_API_KEY", "ANTHROPIC_API_KEY"]) (env as Record<string, string | undefined>)[k] = process.env[k];
}

const SENTENCES = [
  "Message Mum I'm running late",
  "Set a timer for ten minutes",
  "Can you turn the heating down a little",
  "Call Priya after lunch",
  "What time is my appointment on Thursday",
  "Please read me the last message from Sam",
  "Remind me to take my tablets at eight",
  "Turn off the lights in the kitchen",
  "I would like a cup of tea with milk",
  "The physiotherapist is coming tomorrow morning",
  "yes",
  "stop",
];
const VOICES = [
  { voice: "Daniel", rate: 90 },
  { voice: "Karen", rate: 120 },
  { voice: "Samantha", rate: 80 },
  { voice: "Moira", rate: 150 },
];

/** 16 kHz mono 16-bit WAV of `text`, optionally with white noise at about 15 dB SNR. */
function synthesise(text: string, voice: string, rate: number, noisy: boolean): string {
  const base = path.join(work, `${voice}-${rate}-${text.replace(/\W+/g, "_").slice(0, 40)}${noisy ? "-noise" : ""}`);
  if (!existsSync(`${base}.wav`)) {
    execFileSync("say", ["-v", voice, "-r", String(rate), "-o", `${base}.aiff`, text]);
    execFileSync("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", `${base}.aiff`, `${base}.wav`]);
    if (noisy) {
      const bytes = readFileSync(`${base}.wav`);
      // afconvert puts a padding chunk before the samples, so find the "data" chunk.
      const at = bytes.indexOf("data", 12) + 8;
      const pcm = new Int16Array(bytes.buffer.slice(bytes.byteOffset + at, bytes.byteOffset + bytes.length));
      let power = 0;
      for (const s of pcm) power += s * s;
      const rms = Math.sqrt(power / pcm.length);
      const noise = rms / Math.pow(10, 15 / 20);
      let seed = 7;
      for (let i = 0; i < pcm.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        const n = ((seed / 0x7fffffff) * 2 - 1) * noise * Math.sqrt(3);
        pcm[i] = Math.max(-32768, Math.min(32767, Math.round(pcm[i] + n)));
      }
      writeFileSync(`${base}.wav`, Buffer.concat([bytes.subarray(0, at), Buffer.from(pcm.buffer)]));
    }
  }
  return readFileSync(`${base}.wav`).toString("base64");
}

async function main() {
  const deps = realDeps(env);
  const cases = SENTENCES.flatMap((text, i) => {
    const v = VOICES[i % VOICES.length];
    return [{ text, ...v, noisy: false }, { text, ...VOICES[(i + 1) % VOICES.length], noisy: true }];
  });
  const rows: { text: string; voice: string; noisy: boolean; heard: Record<string, string>; final: string }[] = [];
  let next = 0;
  await Promise.all(
    Array.from({ length: 3 }, async () => {
      while (next < cases.length) {
        const c = cases[next++];
        const switches = { keyterms: true, gemini: true, examples: true, phrasebook: true, repair: true };
        const request: UnderstandRequest = {
          turnId: `${c.voice}-${next}`,
          wavBase64: synthesise(c.text, c.voice, c.rate, c.noisy),
          phrasebook: [],
          examples: [],
          keyterms: [],
          context: { recentTurns: [] },
          switches,
          purpose: "transcribe",
        };
        let turn = newTurn({ turnId: request.turnId, origin: "file", switches });
        await understandTurn(request, deps, (e) => (turn = reduceTurn(turn, e, 0)));
        const heard: Record<string, string> = {};
        for (const h of hearersOf(turn)) heard[h] = turn.lanes[h].text ?? `(${turn.lanes[h].failure ?? turn.lanes[h].status})`;
        rows.push({ text: c.text, voice: `${c.voice} ${c.rate} wpm`, noisy: c.noisy, heard, final: turn.failed ? "" : bestText(turn) });
        process.stdout.write(sameWords(c.text, rows.at(-1)!.final) ? "." : "x");
      }
    }),
  );
  console.log("");
  const score = (pick: (r: (typeof rows)[0]) => string, filter: (r: (typeof rows)[0]) => boolean = () => true) => {
    const sel = rows.filter(filter);
    const sum = sel.reduce((a, r) => {
      const c = countErrors(r.text, pick(r));
      return { errors: a.errors + c.errors, referenceWords: a.referenceWords + c.referenceWords };
    }, { errors: 0, referenceWords: 0 });
    return `${(errorRate(sum) * 100).toFixed(1)}%`;
  };
  console.log(`| ${tag} | n | Scribe | Gemini | Gemini 4 | pipeline | pipeline, noisy | exact |`);
  console.log(
    `| synthetic uploads | ${rows.length} | ${score((r) => r.heard.scribe ?? "")} | ${score((r) => r.heard.gemini ?? "")} | ${score((r) => r.heard.gemini4 ?? "")} | ${score((r) => r.final)} | ${score((r) => r.final, (r) => r.noisy)} | ${((rows.filter((r) => sameWords(r.text, r.final)).length / rows.length) * 100).toFixed(0)}% |`,
  );
  for (const r of rows.filter((x) => !sameWords(x.text, x.final))) console.log(`  "${r.text}" (${r.voice}${r.noisy ? ", noise" : ""}) -> "${r.final}"`);
  writeFileSync(path.join(work, `uploads-${tag}.json`), JSON.stringify(rows, null, 2));
}
main();
