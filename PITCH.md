# Pitch: Hands-Free Laptop Agent

**Track:** Accessibility
**One-liner:** Tell your laptop what you want done, not which button to click. A voice agent that lets people who can't use their hands run their whole computer by speaking goals out loud.

---

## 1. The user and the moment

**Sam, 24, has a spinal cord injury and can't use a keyboard or mouse.**

Sam wants to reply to an email from his landlord. With today's built-in tools (macOS Voice Control, Windows Voice Access), that goes:

> "Open Mail." → "Show numbers." → "Click 14." → "Click Reply." → "Show numbers." → "Click 3." → dictate → "Click Send."

That's about 8 commands for one email. Every step needs him to read the screen, find the right number and say it exactly right. A form or a booking takes dozens. It's slow and tiring, and voice fatigue is a real problem for people who talk to their computer all day.

**With this product:**

> "Reply to my landlord's last email. Say I'll pay rent on Friday."
> Agent: "Here's the draft: 'Hi Mark, I'll pay rent on Friday. Thanks, Sam.' Send it?"
> "Send."

One sentence and one confirmation.

---

## 2. Why voice (and not a keyboard)

- **The hands are unavailable.** For the target users a keyboard isn't slower, it's impossible. Voice is the fastest input they have: speech runs at roughly 150 words per minute, while eye-gaze typing manages roughly 10–20.
- **It's a conversation, not a form.** The agent needs to ask things like "which Mark?" or "send it?" in the middle of a task. Talking back and forth is natural, and clicking a dialog box isn't an option for Sam.
- **Interrupting has to be instant.** If the agent starts doing the wrong thing, Sam has to stop it now. Saying "stop" is the only fast way to do that without hands.

---

## 3. What's new compared with what exists

| Tool | How it works | Gap |
|------|--------------|-----|
| macOS Voice Control / Windows Voice Access | One command per action ("click 14") | Very slow for multi-step tasks; you have to know the UI |
| Dragon, Talon Voice | Dictation and custom command scripts | Steep learning curve, aimed at power users |
| AI computer-use agents (Claude, Operator) | Type a goal, the agent does it | Text-first; not built for hands-free use, live voice confirmation or interruption |
| Microsoft UFO² | Desktop agent: accessibility tree + vision + app APIs | No voice; Windows only |
| Open Interpreter 01, VoiceUse | Voice + screen agent | Push-to-talk or hotkey, so unusable without hands; no safety design |
| Talon + LLM agent (research paper) | Computer-use agent inside Talon | Closest prior art; still command-driven, not conversational |
| Clicky (heyclicky.com) | A voice companion beside the cursor that sees the screen and points at the button you should press. Its open-source version is activated by holding Control+Option | The closest in feel, and the base I built on. It shows you where to click and needs a key held down, which assumes you have hands. This product does the clicking and has no key to press |

**This product:** the user speaks *goals*, an AI agent plans and carries out the steps, and it always confirms out loud before anything risky. That's the jump from **commands to intent**.

**The gap nobody has filled:** a *conversational* voice loop (confirm, clarify, interrupt, wait for slow speakers) wrapped around a general computer-use agent and designed for disabled users first. Full research notes are in [RESEARCH.md](RESEARCH.md).

---

## 4. How it works

**The agent uses the laptop the way a person does.** It looks at the screen, moves the real pointer, clicks, scrolls and presses keys, in the user's own apps and their own Chrome. Nothing is scripted behind the scenes. The user watches the pointer travel to the Send button, which is how they can trust it and stop it.

```
 ElevenLabs Agent (always-on mic, no button: the user has no hands)
   hears, talks, asks clarifying questions, handles barge-in
   │ calls local tools on the Mac
   ▼
 QUICK TOOLS   one action, done the way a person does it, about a second
               volume keys · scroll · Spotlight to open an app · keyboard shortcuts · typing
 SCREEN AGENT  any multi-step goal: works on whatever is on screen
               Claude looks at a screenshot → decides → the real pointer and keyboard act
               runs in the background of the conversation; can pause and ask a question
 MEMORY        who "Mum" is, which Priya, how a task was done last time

 ALWAYS ON
   Stop watcher  every sentence → Jev: cancel? → the pointer freezes mid-move
   Safety gate   before every click and every Return key press, code reads the name of the
                 control under the pointer ("button Send in WhatsApp") → Jev: risky? → ask out loud
```

**Built on:** Clicky's open-source app shell (the menu bar panel and the overlay beside the pointer, MIT licence, credited), ElevenLabs Agents (voice and conversation), Claude's computer use (seeing the screen and choosing actions), Jev (fast decisions) and macOS's own pointer, keyboard and accessibility interfaces. The new work is everything that makes a screen agent usable by voice alone: tasks that run in the background of a conversation and can ask questions, a stop that freezes the hands, a safety gate that checks the real button about to be clicked, and memory. Full plan in [BUILD_PLAN.md](BUILD_PLAN.md).

**Why Jev (a classifier) and not the LLM for these decisions:** they're picks from a fixed list, and the stop check runs on every sentence. Jev answers with a typed label and a confidence score. I measured it from my laptop on 5 Nov: **200 to 320ms per decision, at about $0.00002 each**. It also gets the tricky ones right. In my first test it labelled "stop" as cancel, "stop the music" as a command, "hang on" as cancel, "Click Send in WhatsApp" as needing confirmation and "Open Google Calendar" as safe.

**It learns the user.** The first time, the agent asks "Priya Shah or Priya Patel?". It remembers the answer, and after seeing it twice it stops asking. The user can say "remember that Mum is Amma on WhatsApp", "what do you know about me?" or "forget that". Memory is stored on the laptop only, never holds passwords, and can never make a risky action skip its spoken confirmation. This matters for this audience in particular: every repeated question costs a user who can only speak, and voice fatigue is real.

**Why "do anything" works:** if something is on screen, the agent can see it and click it, so no app needs its own integration. The quick tools make single actions fast, and remembered recipes ("to message someone on WhatsApp, click the search field first") stop it rediscovering the route each time.

**Safety rules built in:**
- **Confirms before anything irreversible.** Send, pay, delete and submit always need a spoken "yes".
- **Kill word.** "Stop" cancels the current action at once.
- **Plan on screen.** The agent shows what it's about to do, so the user can check it at a glance.

---

## 5. Prototype scope (what I'll build by 11 Nov)

- A native Swift macOS app that lives in the menu bar, with a companion beside the pointer that shows what it is doing. Its shell is built on Clicky's open-source code.
- Hands-free activation: the microphone is always on, with no button and no push-to-talk. A wake word is a later step (see section 7).
- Fast path: about 15 core commands (open app, scroll, switch window, type this, volume and so on).
- Smart path: works reliably on **3 demo tasks**:
  1. "WhatsApp Mum: running late, ten minutes." The agent drafts it, reads it back, and sends only after a spoken yes.
  2. "Set up a Google Meet with Priya tomorrow at 3." The agent asks which Priya, then confirms before sending the invite.
  3. "Open YouTube and play lo-fi music."
- Spoken confirmation before send/submit, plus the "stop" kill word.
- Memory: it remembers which Priya was meant, and can be told to remember or forget things by voice.

**Not in scope:** every app, Windows, offline mode.

---

## 6. Hard problems (and my plan for each)

| Problem | Plan |
|---------|------|
| **Speed.** AI agents take seconds per step | Fast path for simple commands; speak progress aloud so silence never feels broken. In the prototype a simple command takes about a second, because every sentence passes through the voice agent's LLM before the tool runs. The tool itself takes milliseconds. Routing with Jev before the LLM would remove most of that second |
| **Wrong action.** The agent clicks the wrong thing | Confirm risky actions; the "stop" word; show the plan on screen |
| **Atypical speech.** Many users with motor disabilities also have speech differences (e.g. ALS, cerebral palsy) | ElevenLabs patient turn-taking setting so slow speakers aren't cut off; next step: own pipeline with Jev end-of-turn detection, and per-user speech adaptation |
| **Jev is early access** | Fallbacks: a small LLM for routing, a fixed risky-word list for safety. Failing safe means asking for confirmation |
| **Privacy.** Mic and screen go to the cloud | Fast path runs locally; later, local speech models and an option to never send screenshots |

---

## 7. What I'd do with more time

- **Jev before the LLM.** Move to my own voice pipeline so Jev routes each sentence first. "Scroll down" would then run in about half a second with no LLM call, and Jev could also decide when a slow speaker has finished talking.
- **Personal speech models.** Adapt recognition to each user's voice, including slurred or atypical speech.
- **Wake word or speaker check.** So a television or another person in the room can't give commands.
- **Routines.** "Do my morning routine" opens email, calendar and news in one go.
- **Testing with real users.** Work with disability organisations to see where it breaks.

---

## 8. Questions to ask the Hiya engineer

1. For the demo, should I go **wide** (many simple commands) or **deep** (a few impressive multi-step goals)?
2. Do they see the **speed problem** as the main risk, or the **accuracy** one?
3. Would they rather see a **custom-built** speech pipeline, or a provider like ElevenLabs end to end?
4. How much does **handling atypical speech** matter for the Accessibility track in this round?
5. The prototype uses ElevenLabs' patient turn-taking setting to wait for slow speakers. With more time I'd use **Jev for end-of-turn detection** instead. Does that sound like the right place for it? Has Hiya seen turn-taking problems in its own voice products?

---

## 9. Questions they'll probably ask me

**"Isn't this just macOS Voice Control?"**
No. Voice Control is one command per click. This takes a goal and does all the steps. Voice Control is the keyboard; this is the assistant.

**"Why not use Claude computer use or Operator directly?"**
Those are built for typing a task and walking away. My users need hands-free activation, live spoken confirmation, instant interruption and a fast path for small commands. The agent is one part; the voice loop around it is the product.

**"Can it really do *anything*?"**
In principle, yes: if it's on screen, the agent can see it and click it, the same as a person. In practice, the prototype is tuned and tested on a few tasks, and looking and clicking takes several seconds per step. Being general is the design; being reliable is what the demo proves.

**"Why click through the screen when you could call the app directly?"**
Three reasons. It works on any app with no integration. The user can watch what it's doing, which is how they trust it and how they know when to say stop. And the safety check can read the actual button about to be clicked, so "confirm before sending" is enforced by code, not by hoping the model remembers. The cost is speed, and I say so.

**"Why Jev?"**
Three decisions in the loop are picks from a short list: is this a cancel? Is this action risky? Was that reply a yes? A classifier does each in about 200ms (measured) with a typed answer and a confidence score, and handles cases a keyword list gets wrong ("stop the music" isn't a cancel). On 245 labelled examples run live it missed no risky action and never read a reply as yes by mistake, at the cost of asking needlessly about one safe action in ten. The ElevenLabs LLM handles the conversation; Jev handles fast yes/no calls. If Jev is down or unsure, keyword rules take over, and the safety check always falls back to asking.

**"What if it does something destructive?"**
Irreversible actions always need a spoken yes, and "stop" always works.

**"How fast is it?"**
Measured on my laptop. A simple command reaches the Mac about 0.6 seconds after the sentence, then runs in milliseconds (a keyboard shortcut) to about a second (opening an app through Spotlight). A multi-step task takes several seconds per step: typing a line into a new document took 17 seconds in five steps. The agent shows what it's doing beside the pointer so the user is never left guessing. "Stop" freezes the pointer in under a tenth of a second.

**"Who exactly is this for?"**
First, people with motor impairments: spinal cord injury, ALS, severe RSI, cerebral palsy. It also helps anyone whose hands are busy, but disabled users come first.
