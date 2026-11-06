# Research: How Voice Computer Control Has Been Built

Background notes for the Hands-Free Laptop Agent (see [PITCH.md](PITCH.md)). Researched 5 Nov 2026.

---

## 1. What Jev is

**Jev** is a **classifier model from TypeSafe AI**, launched 15 Sep 2026 and currently in early access. It doesn't write text. You give it a list of labels, each with a short description, and it picks one and returns a confidence score.

- **Speed:** about 150ms per decision; other reports give 70–500ms. That's much faster than a full LLM call.
- **No training needed:** describe the categories, optionally add a few examples, and it works.
- **Price:** reported at about $0.042 per million input tokens, with output free.
- **Voice agent results (vendor-adjacent, preliminary):**
  - In a simulated test, using Jev for **end-of-turn detection** cut interruptions of the caller from 52% of turns to 11%.
  - In a Japanese intent benchmark of 1,000 utterances, Jev scored 99.6% against 86.3% for a local 35B model. The 8B model did better on short, ambiguous remarks.
- **Caveats:** the claims come mostly from blog posts, not official docs. It's an external API, so it adds a network hop and a dependency. Build a fallback in case it's down.

**Why it fits this product:** most of what a voice laptop agent decides is a choice from a fixed list. Is this a command or a goal? Is the user finished speaking? Is this action safe, or does it need a confirmation? Jev answers those fast without paying for a full LLM call.

---

## 2. Prior art

| Project | How it sees the screen | How it acts | Voice? | What we take from it |
|---------|------------------------|-------------|--------|---------------------|
| **Talon Voice** | Doesn't. Commands are fixed phrases in `.talon` files, scoped per app | Python actions, keystrokes | Yes, its own speech engine. Modes: command, dictation, sleep. About 0.3s pause before running a command | The **fast path** and **modes** idea. Proof that disabled users depend on voice control daily |
| **Talon + LLM computer-use agent** (Forristal & Shapiro, research paper) | LLM computer-use agent built inside Talon | GUI actions through the agent | Yes, via Talon | **Closest prior art.** Same accessibility goal. Our difference: a conversational loop (spoken confirmations, turn handling, interruption) instead of command grammar |
| **Microsoft UFO²** (Windows) | **Accessibility tree** (Windows UI Automation) first, **vision** (OmniParser) for custom controls | **Hybrid:** app APIs where they exist, GUI clicks otherwise. A HostAgent orchestrates, with one AppAgent per app. Predicts several actions at once to cut LLM calls | No | **Main architecture template.** Accessibility tree first, vision as fallback, APIs where possible |
| **Microsoft OmniParser** | Pure vision: a YOLO model finds clickable elements, Florence-2 describes them | The model picks an **element ID** from numbered boxes ("Set-of-Marks"), not raw pixel coordinates | No | When using vision, have the model choose an ID, not coordinates. It's more reliable |
| **Open Interpreter OS mode + 01 app** | Screenshots | Mouse and keyboard control | Yes, but **push-to-talk** | Push-to-talk **excludes our users**. Activation must be fully hands-free |
| **VoiceUse** (PyPI package) | Vision through Anthropic Computer Use or Codex | OS control, also exposed as an MCP server | Yes, wake word or hotkey | Proof that the stack can be built today. Not focused on accessibility; no safety or confirmation design |
| **ElevenLabs Agents** | n/a | **Client tools:** register local Python functions with `ClientTools.register(name, fn)` and the agent calls them | Yes: speech-to-text, text-to-speech and turn-taking in one | The bridge to the laptop. There's **no official desktop-control example**, so we build that bridge ourselves |

---

## 3. Lessons

1. **Don't send everything through an AI agent.** Every system that feels fast (Talon, UFO²'s API calls) handles common actions directly. AI screen agents take seconds per step.
2. **Accessibility tree before screenshots.** The OS already knows every button's name and position, which is cheaper and more exact than vision. Use vision only when the tree is missing or useless (custom-drawn apps, canvases, games).
3. **Use app APIs when they exist.** "Open Spotify", "new email to X" and "go to youtube.com" are one-line calls through AppleScript, the shell or a browser controller. Don't click through menus for them.
4. **Pick element IDs, not pixels.** When vision is needed, number the elements and have the model choose a number.
5. **No buttons, ever.** Every voice product above that uses push-to-talk is unusable for someone without hands.
6. **The gap nobody has filled:** a *conversational* voice loop (confirm, clarify, interrupt, wait for slow speakers) wrapped around a general computer-use agent and **designed for disabled users first**. That's this project.

---

## 4. Recommended architecture: "do anything"

Being able to "do anything" comes from the **vision fallback**: if something is on screen, the agent can see it and click it. Being *fast and safe* comes from the layers in front of it.

```
 ┌─────────────────────────── HEAR ───────────────────────────┐
 │ Always-on mic → ElevenLabs speech-to-text (streaming)       │
 │ Jev: "Is the user finished speaking?" (waits for slow       │
 │      or paused speech instead of cutting them off)          │
 └─────────────────────────────┬───────────────────────────────┘
                               ▼
 ┌────────────────────────── DECIDE ──────────────────────────┐
 │ Jev labels each utterance (~150ms):                         │
 │   STOP │ SIMPLE_COMMAND │ GOAL │ DICTATION │ YES │ NO │ CHAT │
 └──┬──────────┬──────────────┬───────────┬────────────────────┘
    │ STOP     │ SIMPLE       │ GOAL      │ DICTATION
    ▼          ▼              ▼           ▼
  cancel    direct action   AI agent    type text into
  everything (no LLM)       (see ACT)   focused field
                               │
 ┌─────────────────────────── ACT ────────────────────────────┐
 │ Agent loop. For each step, try in order:                    │
 │   1. App API / shell / AppleScript / browser control (fast) │
 │   2. macOS accessibility tree: click element by name        │
 │   3. Vision fallback: screenshot + numbered elements →      │
 │      model picks one  ← this is what makes "anything" work  │
 └─────────────────────────────┬───────────────────────────────┘
                               ▼
 ┌────────────────────────── GUARD ───────────────────────────┐
 │ Jev labels each planned action: SAFE │ NEEDS_CONFIRMATION   │
 │ (send, pay, delete, submit, post → ask out loud first)      │
 └─────────────────────────────┬───────────────────────────────┘
                               ▼
 ┌────────────────────────── SPEAK ───────────────────────────┐
 │ ElevenLabs text-to-speech: progress ("opening Gmail…"),     │
 │ confirmations ("send it?"), results                         │
 └─────────────────────────────────────────────────────────────┘
```

### Jev's four jobs

| Job | Labels | Why a classifier, not an LLM |
|-----|--------|------------------------------|
| **Router** | STOP, SIMPLE_COMMAND, GOAL, DICTATION, YES, NO, CHAT | Runs on every utterance, so it must be fast. "Scroll down" shouldn't wait 1–2s for an LLM |
| **End-of-turn** | DONE, STILL_SPEAKING | Users with ALS or cerebral palsy often speak slowly with long pauses, and a plain silence timer cuts them off. **This is a strong accessibility point** |
| **Safety gate** | SAFE, NEEDS_CONFIRMATION | Checked before every action. It must be cheap and give a typed answer, never free text |
| **Confirmation reader** | YES, NO, CHANGE | "Yeah go for it", "nah", "wait, change the time" should all be understood |

**Fallback:** if Jev is slow or down, the router falls back to a small LLM call, and the safety gate falls back to a fixed list of risky words (send, pay, delete…). Failing safe means asking for confirmation.

### Two build options

> **Update:** [BUILD_PLAN.md](BUILD_PLAN.md) goes with **option A**: the ElevenLabs Agent drives, because it already handles clarifying questions and interruption. Option B is the "with more time" upgrade.

| | **A. ElevenLabs Agent drives** | **B. Own pipeline (recommended)** |
|---|---|---|
| How | ElevenLabs Agent handles the conversation and calls local `ClientTools` such as `run_on_computer(goal)` | ElevenLabs speech-to-text → Jev router → executors → ElevenLabs text-to-speech |
| Speed for simple commands | Slower: every turn goes through the ElevenLabs LLM | Fast: speech-to-text + Jev + direct action, no LLM |
| Where Jev fits | Only inside tools (safety gate) | Central: router, end-of-turn, safety, confirmation |
| Build effort | Lower | Higher |
| Use when | Running out of time | Default plan |

### Example latency budget, "open Spotify" (fast path, option B)

| Step | Target |
|------|--------|
| Speech-to-text final result | ~200–300ms after speech ends |
| Jev router | ~150ms |
| `open -a Spotify` | ~50ms to start |
| **Total** | **under ~0.5s** |

Goal tasks ("reply to my landlord…") take several seconds, so the agent speaks progress to fill the silence.

---

## 5. What to verify before building

- [ ] Jev API access works, and its real latency from London
- [ ] ElevenLabs streaming speech-to-text: latency and how well it handles slow or paused speech
- [ ] macOS accessibility permissions for a Python process (needed for reading the accessibility tree and for clicking)
- [ ] Which vision/computer-use model to use for the fallback, and its cost per step
- [ ] Wake word option (e.g. Porcupine or openWakeWord) vs. always listening with Jev filtering out background chatter

---

## Sources

- Jev: [Medium: Jev vs fine-tuned RoBERTa](https://tuanatran.medium.com/jev-vs-fine-tuned-roberta-0f6647c6dad5), [Substack: JEV 101](https://vpkprasanna.substack.com/p/jev-101-understanding-decision-models), [orca forge: Japanese intent benchmark](https://note.com/orcaforge/n/n799dff71d24d?hl=en), [Veris: Jev turn detection benchmark](https://veris.ai/blog/jev-turn-detection), [Evalgent: Jev for voice agents](https://www.evalgent.com/blog/jev-for-voice-agents), [Evalgent: Jev model routing](https://www.evalgent.com/blog/jev-model-routing-voice-agents), [DEV: Jev-like models in voice bots](https://dev.to/vsamukov/how-jev-like-models-improve-llm-voice-bots-4hd)
- Talon: [Talon docs](https://talonvoice.com/docs/), [Talon wiki: basic usage](https://scour.ing/@abnv/p/https://talon.wiki/Basic%20Usage/basic_usage), [Forristal & Shapiro: computer-use agent in Talon (PDF)](https://ilanashapiro.github.io/files/talon.pdf)
- UFO²: [Official docs](https://microsoft.github.io/UFO/ufo2/overview), [arXiv paper 2504.14603](https://arxiv.org/html/2504.14603v2), [Microsoft Research page](https://www.microsoft.com/en-us/research/publication/ufo2-the-desktop-agentos/)
- OmniParser: [arXiv 2408.00203](https://arxiv.org/html/2408.00203v1), [GitHub](https://github.com/microsoft/OmniParser)
- VoiceUse: [PyPI](https://pypi.org/project/voice-computer-use-agent/)
- Open Interpreter: [Overview](https://vantaige.io/ai-tool/open-interpreter), [01 project](https://www.gamecloud-ltd.com/exploring-the-open-interpreter-01-project-a-new-era-of-ai-devices/)
- ElevenLabs: [Agents tools docs](https://elevenlabs.io/docs/conversational-ai/customization/tools), [Python SDK](https://github.com/fern-api/elevenlabs-python), [PyPI](https://pypi.org/project/elevenlabs/2.76.0/)
