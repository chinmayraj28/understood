# Waking and sleeping

Handsfree does not keep a conversation open all day. It sleeps, and while it sleeps it listens on the Mac itself for a wake phrase, "Hey Handsfree" by default. When it hears the phrase it opens a conversation with the ElevenLabs agent. When nobody has said anything for a while and no task is running, it closes the conversation and goes back to sleep.

There is no key to press at any point, because the people this is for cannot press one.

This document explains how that works, why it was built this way, what was measured on this Mac, and where its limits are. The code is in `Packages/HFWake`.

## Why it sleeps

The user decided this on 6 November: "Let's not have an always-on mic. Let there be a key word, so that way we don't use up all the minutes." Sleeping fixes three things:

1. **Cost.** ElevenLabs bills for every minute a conversation is open, whether or not anyone is speaking. A conversation that is open for eight hours a day would use up the plan's minutes.
2. **Privacy.** Earlier tests with an always-open conversation picked up people talking in the room and sent their words to ElevenLabs, which nobody had agreed to. While Handsfree is asleep, nothing it hears leaves the laptop.
3. **Other voices.** A bystander's sentence can only be acted on while a conversation is open. The wake phrase narrows the window in which that can happen.

## What happens, step by step

Here is what happens when Sam says "Hey Handsfree, open Spotify":

1. **Asleep.** The microphone is open and Apple's speech recogniser runs on the Mac. The companion shows that it is asleep (`.asleep(wakePhrase:)` on the activity bus). Nothing is sent anywhere.
2. **The phrase is heard.** The recogniser writes "Hey hands-free, open Spotify." The matcher finds the phrase in it and keeps "open Spotify" as the rest of the sentence.
3. **Waking.** `.waking` is posted, so the companion can show it heard. The listener stops and releases the microphone completely. The app then opens the ElevenLabs conversation and sends "open Spotify" as Sam's first message, so the one sentence is enough.
4. **Awake.** The conversation stays open while anyone is speaking, while a task runs, and while a task waits for Sam's answer. After that it stays open for `SLEEP_AFTER_IDLE_S` seconds (15 by default, changed from 25 on 6 November) after the last activity. If the wake was a mistake and nobody says anything at all, it sleeps after `SLEEP_AFTER_UNUSED_WAKE_S` (8 seconds) instead; anything the user says switches that conversation to the ordinary 15.
5. **Going back to sleep.** The conversation is closed and the listener starts again. Sam can also say "stop listening", "go to sleep", "that's all" or "goodbye". The app itself recognises these when they are the whole sentence (give or take "thanks" or "please"), without waiting for the voice agent, and asks the cycle to sleep once the agent has said a short reply. A sentence like "stop" or "stop the music" is not one of them, and "stop listening" never cancels a task. During a task it finishes the task, says the result, and only then sleeps.

Two rules protect the user here:

- **A task that is waiting for a yes is never put to sleep.** The pointer may be hovering over Send. That applies to the idle timer and to "that's all" alike: `requestSleep()` answers `.busy` until the task is finished or cancelled.
- **A failure never leaves the app awake and deaf, and never leaves it silent about it.** If the conversation cannot be opened (no network, ElevenLabs down), the app says so and goes back to listening, so saying the phrase again retries. If the listener itself cannot start (no microphone permission), the listener is retried every 2, 5, 10, 30, then 60 seconds. Every such problem is reported in two ways, once per distinct problem: to `onProblem`, for the app to say it, and on the activity bus as `.voiceDisconnected(reason:)`, for the companion and the panel to show it. `.asleep` is posted only once the listener is really running, so the companion never shows "asleep and listening" when it is not.

**Waking without the phrase.** Sometimes the app itself needs to wake: a task's question, confirmation or result can arrive just as the conversation is closing. `wakeNow()` does what hearing the phrase does, with nothing said yet. It does nothing if the cycle is already awake. If the cycle is in the middle of falling asleep, the close is finished first and the wake follows at once, so a sleep is never left half done.

With `WAKE_MODE=always` none of this happens: the conversation is opened at start and kept open. That is for demos and testing.

## Why the audio stays on the Mac

The listener uses **Apple's SpeechAnalyzer with the SpeechTranscriber module** (new in macOS 26). Apple's documentation says that SpeechAnalyzer's transcriber modules do not send the user's voice to Apple's servers. It is built for long-running audio. It also needs no Speech Recognition permission, only the Microphone.

Before macOS 26, or on a Mac where SpeechTranscriber is not available, the listener falls back to Apple's older `SFSpeechRecognizer`. It sets `requiresOnDeviceRecognition = true` and first checks `supportsOnDeviceRecognition`. If on-device recognition is not available for the language, `start()` fails with a spoken sentence ("Speech recognition on this Mac can't run offline for this language, so I won't listen for the wake phrase."). It never quietly falls back to Apple's servers.

The only network use is a one-time download of Apple's speech model for the language, done by macOS through `AssetInventory` if the model is missing. That download carries no audio.

What is kept or logged while asleep:

- No audio is saved.
- No transcript is printed, logged or stored. The listener's diagnostics say only that it started or restarted, that the phrase was heard (with the words taken as the phrase, such as "hey hands free"), and the rest of the sentence when it wakes. The conversation receives that rest anyway.
- Transcripts are available only through an opt-in flag (`revealTranscripts`). The app never sets it. The command-line tool sets it only while it plays its own synthetic test phrase.

## Which Apple API, and why

| Option | Chosen? | Why |
|---|---|---|
| SpeechAnalyzer + SpeechTranscriber (macOS 26) | **Yes, by default** | Always on-device. Made for long audio. No Speech Recognition permission. On this Mac it supports `en_IN`, the Mac's own language. |
| SFSpeechRecognizer with `requiresOnDeviceRecognition` | Fallback for older macOS | On-device when forced, but Apple's guidance is to plan for a one-minute limit per task. It needs the Speech Recognition permission. Asking for that permission ends the process when the host app's Info.plist lacks the usage key, and Orca, the terminal used here, lacks it. |
| A third-party wake-word engine | No | It would be a new dependency, and usually a new API key and licence. |

The package's minimum stays macOS 14. The SpeechAnalyzer code is marked `@available(macOS 26.0, *)` and chosen at run time.

## How the matcher decides

A recogniser does not write the phrase the way it is spelled. On this Mac, "Hey Handsfree" came back as "Hey hands-free", "Hey, hands free.", "Hey Hansfree", "Hey hands-f free" (a guess mid-word), "High hands-free" (for "Hi Handsfree"), "Pay hands free" and "Hey Hands 3" (both from a British voice), and "Oh, computer" (for "Okay computer").

`WakePhraseMatcher` is a pure function from text to an answer. It has no audio and no clock, and it is where most of the quality lives. Here is how it decides for "Hey Handsfree":

1. **Lead-in and name.** The first word is a lead-in if it is a greeting (hey, hi, hello, okay...). The rest is the name, here "handsfree". A phrase without a greeting, such as "Wake up Mac", is all name.
2. **Spacing does not matter.** The name is compared with the spaces taken out, across one to a few words of the transcript. So "hands free", "hands-free" and "handsfree" are the same thing.
3. **Sound, not spelling.** Each word is turned into a rough sound key. Vowels are merged, "ph" becomes "f", a silent "gh" or a trailing "h" is dropped, doubled letters are merged, and digits are spelled out ("3" becomes "three"). The name's key may differ by one sound edit at the default strictness, so "hans free", "hand free" and "hands three" match.
4. **Strong and weak lead-ins.**
   - A *strong* lead-in is the lead-in itself or a spelling of it ("hey", "hay"). It counts anywhere in the sentence.
   - A *weak* lead-in is a likely mishearing or another greeting: "a", "he", "high", "hi", "pay", or "oh" for "okay". It counts only when it starts a sentence **and** the name is followed by a pause mark (a comma or full stop) or by the end of the transcript.
   - This is how a recogniser writes someone being addressed: "High hands-free, open Safari." It is what separates "A hands free. Open Spotify." from "A hands-free kit is the law now."
5. **The name never spans a pause.** "Hey Hans, free on Friday?" is not the phrase.
6. **The rest of the sentence** is everything after the phrase, with the surrounding punctuation trimmed. "Hey Handsfree, hey Handsfree, open Mail" gives "open Mail".

Examples at the default strictness (all are unit tests):

| Transcript | Wakes? | Rest |
|---|---|---|
| Hey hands-free, open Spotify. | yes | open Spotify |
| High hands-free, open Safari. | yes | open Safari |
| Pay hands free. | yes | (none) |
| So I said hey handsfree turn the volume up | yes | turn the volume up |
| I use hands free in the car | no | |
| She bought a hands free kit | no | |
| A hands-free kit is the law now. | no | |
| Hi, hands free calling works. | no | |
| Hey Hans, free on Friday? | no | |
| Hey, have you seen my hands free headset? | no | |

### Where it sits between missing and false waking

The two mistakes cost different things:

- **A false wake** opens a paid conversation for about 15 seconds (8 if nobody says anything). It could also act on a sentence nobody meant as a command, although every risky action still needs a spoken yes.
- **A missed wake** leaves someone who cannot use their hands unable to get the computer's attention at all.

So the default leans towards hearing the phrase:

- It accepts mishearings of the lead-in.
- It accepts a name one sound off.
- It refuses the name on its own, and it refuses a mishearing in the middle of a sentence.

The strictness is a setting (`WakeStrictness`):

- **strict:** only the phrase as spelled, ignoring case, punctuation and spacing. Fewest false wakes, most misses.
- **balanced** (default): as described above.
- **lenient:** for speech the recogniser struggles with. Two sound edits on the name. Other greetings count anywhere. Any word one sound away from the lead-in counts at the start of a sentence. The lead-in may be left out when the name starts a sentence and is followed by a pause ("Hands free, open Spotify").

### Changing the phrase

Many people this is for have slow, quiet or atypical speech, and Apple's recogniser may do worse on it. Four settings in `.env` change what wakes it. All four are read through `Settings` and mapped by `WakeListener.Configuration(settings:)`.

| Setting | Example | What it does |
|---|---|---|
| `WAKE_PHRASE` | `Hey Handsfree` | The main phrase. |
| `WAKE_LANGUAGE` | `en_GB` | The language the recogniser listens in. Empty means the Mac's own. |
| `WAKE_ALTERNATIVES` | `Hello Sam's Mac, Computer listen` | Extra phrases that also wake it, separated by commas. |
| `WAKE_STRICTNESS` | `lenient` | `strict`, `balanced` (the default) or `lenient`. |

**When the phrase is not being heard, try these in this order**, restarting Handsfree after each change. The panel's count of "heard speech that was not the phrase" shows whether the Mac is hearing the person at all. If that count goes up when they say the phrase, it is hearing them but not recognising the phrase, and these steps help. If it stays at zero, look at the microphone instead.

1. **The language.** Set `WAKE_LANGUAGE` to the speaker's own English: `en_GB`, `en_US`, `en_IN`, `en_AU`, `en_IE`, `en_ZA`, `en_CA`, `en_NZ` or `en_SG` on this Mac. This comes first because it changes how *every* word is heard, and it made the biggest difference in testing. A language this Mac does not support stops listening with one sentence naming the supported ones. It never quietly listens in a different language.
2. **An alternative phrase.** Add a phrase the person can say clearly and the recogniser writes reliably to `WAKE_ALTERNATIVES`, such as "Hello Sam's Mac". The main phrase keeps working. A two-word phrase with a greeting first works best. A single common word such as "Computer" has no lead-in to separate addressing it from talking about it, so it will wake on ordinary speech.
3. **The strictness.** Set `WAKE_STRICTNESS=lenient` last. It accepts more mishearings and may drop the lead-in, so it also wakes by mistake more often.

The phrase's words are also passed to the recogniser as contextual strings, which nudges it to write "Handsfree" as a word.

## When exactly it wakes

Measured on this Mac, SpeechAnalyzer sends its guesses in bursts about 0.9 seconds apart. It sends a final transcript 0.3 to 1 second after the speech stops. The final is the best sign that the person has finished, so `WakeDetector` uses it:

- **The phrase and more words, finalised:** wake at once with those words.
- **The phrase alone, finalised:** wait 0.25 s in case the next words arrive in the same burst, then wake.
- **No final arrives** (a television keeps the recogniser busy): wake after 1.5 s with no new words after a bare phrase, or 2 s after a phrase followed by words. Both are longer than one burst. Changes in punctuation alone ("hands-free" becoming "hands-free.") do not count as new words.
- **At the latest,** 10 s after the phrase was first seen.
- **Revised guesses never wake it twice.** The detector wakes once and then ignores everything until the listener is started again. A revision that takes the phrase back out ("hey hands free" becoming "they handed three") cancels the wait.

These numbers are in `WakeTiming` and can be changed.

## Listening for hours

- **One microphone, many recognition sessions.** `StreamingTranscriber` keeps one microphone tap open and feeds it to one recognition session after another.
  - A session that ends by itself is replaced at once. That happens after a recognition timeout or an error, and with the older recogniser after every final result. The audio that arrives in between is held, up to 5 seconds, and handed to the new session first, so there is no gap in which the phrase could be missed.
  - A SpeechAnalyzer session is renewed every 10 minutes at a quiet moment, or after 20 minutes regardless. The old session keeps listening until the new one is ready.
  - A session that keeps ending the moment it starts is replaced more and more slowly, so it cannot spin the CPU.
- **The microphone changing.** Plugging in a headset, connecting AirPods or changing the default input stops the engine. The listener notices and restarts on the new device, retrying with back-off.
- **The cycle keeps watch too.** Every 5 seconds while asleep it checks that the listener is still running. If it has been down for two checks, it restarts the listener itself, which also reports why it cannot listen.
- **Memory is bounded.** The audio queue to the recogniser keeps at most 128 buffers. Held audio is at most 5 seconds. The speech model stays loaded for the life of the app (`modelRetention: .processLifetime`), so listening resumes at once after each conversation.

## Handing over the microphone

`stop()` removes the tap, stops the AVAudioEngine and throws it away before it returns. It first waits for any restart in progress to give up, so nothing of ours can reopen the microphone afterwards. The ElevenLabs SDK then opens the microphone with macOS voice processing switched on. When the conversation ends, `start()` builds a fresh engine.

This hand-over is covered by:

- unit tests with fakes,
- live replay tests that start and stop three times in a row through the real recogniser,
- a microphone test, `stopReleasesTheMicrophoneForAVoiceProcessingEngineAndListeningResumes`. It starts the listener, stops it, gives the microphone to a voice-processing AVAudioEngine and checks that engine receives audio, then starts the listener again. **It has not run yet**: see "Permissions" below.

## Measurements

All of these were made on this Mac (macOS 26.3.1, Apple Silicon), with SpeechAnalyzer set to `en_IN`, the Mac's language. **They use synthetic voices, not a person.** Each sentence was written to a sound file with `say -o`, and the file was fed into the real recogniser at normal speed in place of the microphone (`hf-wake replay`). Nothing was played aloud. A real voice in a real room will differ, and the microphone path itself has not been measured yet.

**Wakes and false wakes.** The test set is `Packages/HFWake/Fixtures/wake_corpus.txt`: 9 sentences that should wake and 11 that should not. Most of the 11 are ordinary sentences with "hands free" or "hey" in them. The set was run through 9 English voices and 3 slower speeds (final code, 6 November):

| Voice (accent) | Woke (of 9) | False wakes (of 11) | Delay after the audio ended, median (range) |
|---|---|---|---|
| default (US) | 9 | 1 | 1.35 s (0.96–1.54) |
| Samantha (US) | 9 | 0 | 1.53 s (1.02–1.78) |
| Daniel (UK) | 7 | 0 | 1.56 s (0.79–1.74) |
| Rishi (India) | 9 | 0 | 1.37 s (0.79–1.98) |
| Moira (Ireland) | 9 | 0 | 1.40 s (0.80–1.81) |
| Karen (Australia) | 9 | 0 | 1.52 s (0.83–1.71) |
| Tessa (South Africa) | 9 | 0 | 1.23 s |
| default, slow (110 words a minute) | 9 | 1 | 0.99 s (0.77–1.54) |
| Rishi, slow (110 words a minute) | 9 | 0 | 1.39 s (1.02–1.82) |
| default, very slow (80 words a minute) | 9 | 1 | 1.38 s (0.85–1.93) |
| Tara (India) | 5 | 0 | |
| Aman (India) | 7 | 0 | |

- **Totals.** 100 of 108 wakes were caught. Leaving out Tara and Aman, it was 88 of 90: the recogniser turned their speech into nonsense even on sentences without the phrase ("Pierre Chloe's thermal piece..."), so that is a voice or recogniser problem the matcher cannot fix.
- **Daniel's two misses.** One was "Payhand 3." (the words run together); the other was "High hand 3, open Safari." (two sounds off). With the recogniser set to British English (`--locale en_GB`), Daniel also woke 7 of 9.
- **The false wakes.** All 3 are the same sentence, "He hands free tickets out at the door". The recogniser itself wrote it as "Hey, hands free tickets out at the door."
- **Before and after the review fixes.** An earlier version of the matcher missed 7 of Daniel's 9, until digits and "pay" were handled. It also woke on that "He hands free" sentence from every voice.

**Background speech.** `Fixtures/background_speech.txt` is 114 seconds of ordinary conversation in the default voice. Most of it starts with "hey" or mentions "hands free". It caused **0 wakes**.

**Delay.** The delay from the end of the phrase to the wake is about **1.0 s** when words follow the phrase in the same breath, because it wakes on the final transcript. It is about **1.4 to 1.6 s** for a bare "Hey Handsfree": the final transcript, then 0.25 s. Most of that is the recogniser deciding the speech has ended. The conversation still has to connect after this.

**CPU while listening.** This counts Apple's `localspeechrecognition` service, which does the recognition, plus our own process, as a share of one core over 50 s:

| | localspeechrecognition | our process | total |
|---|---|---|---|
| Silence | 1.8% | 0.5% | **about 2.3%** |
| Continuous speech (the worst case) | 4.8% | 1.1% | **about 5.9%** |

The file test leaves out the cost of capturing audio from the microphone (in `coreaudiod`), which has not been measured.

## Permissions and Info.plist keys

| Permission | When it is needed | Owned by |
|---|---|---|
| Microphone | Always | Handsfree.app; for `hf-wake` and tests, the terminal's host app (Orca) |
| Speech Recognition | Only with the older recogniser (before macOS 26) | the same |

Handsfree.app's `project.yml` already has what is needed, and needs no change:

- `NSMicrophoneUsageDescription` is required.
- `NSSpeechRecognitionUsageDescription` is needed only for the older recogniser. It is there, which matters, because without it macOS would end the app the moment the older recogniser asked for permission.
- `com.apple.security.device.audio-input` is required by the hardened runtime. The app is not sandboxed.

Checking never changes a setting. By default `start()` does not ask for a permission. It fails with one sentence that says which permission is missing and where to turn it on, for example: "Handsfree isn't allowed to use the microphone, so I can't listen for the wake phrase. Someone can turn it on in System Settings, Privacy and Security, Microphone."

Two ways to show the system prompt instead:

- set `Configuration.requestPermissions = true`, which suits the first-run flow;
- call `WakePermissions.requestMicrophone()`.

Command-line runs from the development session have no Microphone permission. Its process has no terminal app above it, and the permission reads "not asked". Once, early on 6 November, `hf-wake permissions --request` asked for it and nobody answered within 90 seconds. Since then nothing asks again. `hf-wake listen` and `hf-wake handover` exit with the one-sentence reason, and the live microphone tests skip with it. The first real microphone run will be the built Handsfree.app, which has its own permissions.

**How the app should ask.**

1. In the setup flow, ask for the Microphone with `WakePermissions.requestMicrophone()` (or `AVCaptureDevice.requestAccess(for: .audio)`).
2. Ask for Speech Recognition only when `WakePermissions.needsSpeechRecognition` is true (before macOS 26), with `WakePermissions.requestSpeechRecognition()`.
3. Start the cycle once those are granted, with `requestPermissions` left false.

On macOS 26 no System Settings step is needed. Apple's speech model comes through `AssetInventory`, and `start()` downloads it if it is missing; on this Mac the English models were already installed. On older macOS, on-device recognition needs the Dictation language: "On older macOS, turn on Dictation once in System Settings, Keyboard, so the Mac can recognise speech offline."

## Choosing the recogniser's language

The recogniser's language does not have to be the Mac's. It is set by `WAKE_LANGUAGE`, which becomes `WakeListener.Configuration.locale`. The command-line tool also takes `--locale en_GB`. Left empty, it is the Mac's own language, or the nearest the recogniser supports; this Mac is Indian English (`en_IN`). Apple's on-device recogniser here supports `en_AU`, `en_CA`, `en_GB`, `en_IE`, `en_IN`, `en_NZ`, `en_SG`, `en_US` and `en_ZA`.

A language that is set must be supported exactly. If it is not, `start()` fails, and the cycle shows and says one sentence. On this Mac, with `WAKE_LANGUAGE=en_JM`, the sentence is: "The wake language en_JM isn't supported by on-device speech recognition on this Mac, so set WAKE_LANGUAGE to one of en_AU, en_CA, en_GB, en_IE, en_IN, en_NZ, en_SG, en_US, en_ZA."

This can decide whether the phrase works for a given speaker. A British synthetic voice was misheard far more than US or Indian ones while the recogniser was set to `en_IN`; before two matcher fixes it missed 7 of 9. The user and the Hiya reviewer may not share an accent setting with this Mac, so set `WAKE_LANGUAGE` for whoever is speaking.

## Checklist for the first real run (in Handsfree.app)

Nothing below has run on a real microphone yet. With the app built and Microphone granted to Handsfree.app:

1. **It starts listening.** The companion shows "asleep" (`.asleep` on the bus), the menu bar's orange microphone light comes on, and there is no `.voiceDisconnected`. If it shows a reason instead, that sentence says what is missing.
2. **The phrase wakes it.** Say "Hey Handsfree" at a normal distance and volume, five times, with pauses. Count the wakes. If one is missed, see whether a "heard speech that was not the phrase" count went up: if it did, the Mac heard you but the recogniser wrote something the matcher refused. That calls for a different strictness, an alternative phrase, or a different recogniser language.
3. **Time to wake.** From the end of the phrase to the `.waking` sound, expect about 1.5 s for the bare phrase and about 1 s after "Hey Handsfree, open Spotify". Much longer means the recogniser is slow to decide you have stopped. Then add the conversation's own connection time.
4. **The rest of the sentence.** "Hey Handsfree, open Spotify" in one breath should reach the agent as "open Spotify". Spotify should open without a second request.
5. **The hand-over.** After waking, the agent must hear you; that shows the voice-processing engine got the microphone. Then let it fall asleep, which takes 15 s of quiet, and say the phrase again. It must wake again. Do this three times in a row.
6. **Never asleep over a question.** Start a task that asks for confirmation ("send ... to the test contact") and stay silent at the question for more than 15 s. The conversation must stay open.
7. **Ordinary talk.** Talk normally near the Mac for a few minutes, mentioning "hands free" without "hey". There should be no wakes.
8. **CPU.** In Activity Monitor, while asleep, look at `localspeechrecognition` plus Handsfree. File tests gave about 2% of one core in silence; the microphone adds a little.

## How the app wires it

The `ListeningCycle` and `WakeListener` calls are the real API. The `voice` and `runner` names stand in for whatever the voice package and task runner provide.

```swift
let listener = WakeListener(configuration: .init(settings: settings))
let cycle = ListeningCycle(
    settings: settings,                       // wakeMode, wakePhrase, sleepAfterIdleSeconds
    listener: listener,
    openConversation: { firstUtterance in     // throws if it cannot open
        try await voice.open()
        if !firstUtterance.isEmpty { voice.sendText(firstUtterance) }
    },
    closeConversation: { await voice.close() },   // must be safe to call twice
    currentActivity: {
        ConversationActivity(
            someoneSpeaking: voice.isSomeoneSpeaking,
            taskRunning: runner.isRunning,
            awaitingAnswer: runner.isWaitingForAnswer)
    },
    onProblem: { problem in companion.show(problem.spokenMessage) })
await cycle.start()
// "That's all, thanks" tool: switch await cycle.requestSleep() { case .busy: say "a task is still waiting" ... }
// On quit: await cycle.stop()
```

The cycle also watches the activity bus. Anything the user, the agent or a task posts (speech, a click, task progress, a question) restarts the idle wait. `.listening` and `.voiceDisconnected` do not.

- **When a task event must be spoken and no conversation is open,** call `Task { await cycle.wakeNow() }`. It is harmless when already awake.
- **For the panel,** `WakeListener.onDiagnostic` reports `.started`, `.phraseHeard`, `.woke`, `.restarting`, `.restartFailed` and `.speechWithoutPhrase`. `.speechWithoutPhrase` carries nothing of what was said: it is sent once per finished utterance that had words but not the phrase. `.phraseHeard` names the configured phrase, not what the recogniser wrote. `.woke` carries the rest of the sentence, the same text the conversation receives, so do not store it.

## Trying it

```
cd Packages/HFWake
swift test                                             # 108 tests, no microphone (6 November)
HF_LIVE=1 swift test --filter Live                     # the real recogniser on synthetic speech files
swift run hf-wake status                               # permissions and the Mac's language
echo "Hey hands free, open Spotify" | swift run hf-wake match
swift run hf-wake replay --lines Fixtures/wake_corpus.txt --voice Daniel
swift run hf-wake listen --wakes 3                     # the microphone (needs the permission)
swift run hf-wake listen --say "Hey Handsfree" --times 3   # plays the phrase aloud; take the live lock
swift run hf-wake handover --say "Hey Handsfree"       # the microphone hand-over, then a wake
```

## Limits, said plainly

- **Synthetic voices only.** Every figure above comes from macOS voices fed in as files. What happens with a real person, a real microphone, room noise, distance and accents has not been measured. Neither has slow, quiet or atypical speech, which matters most for the people this is for. The slow-rate runs are synthetic speech slowed down, not dysarthric speech.
- **The microphone path has not run** on this Mac yet, because command-line runs from the development session have no Microphone permission. That covers listening, the hand-over to voice processing, CPU including audio capture, and the delay with a live voice. The tests for it are written and skip with the reason. The first real run will be in Handsfree.app; see the checklist above.
- **The Mac's language matters.** This Mac is set to Indian English. A British synthetic voice was misheard far more ("Pay hands free", "Hands 3") than US or Indian ones.
- **Some mishearings cannot be told apart from text.** The recogniser itself wrote "He hands free tickets out" as "Hey, hands free tickets out", and that sentence wakes it.
- **The microphone is on all day.** The audio stays on the Mac, but the menu bar's orange microphone light is on while Handsfree is asleep. With AirPods as the input, macOS switches them to the lower-quality headset mode while the microphone is open, which makes music sound worse.
- **Words spoken during the hand-over can be lost.** If the user pauses after the phrase and goes on talking while the conversation is opening, those words reach neither the listener nor ElevenLabs. Words in the same breath are kept, because they arrive with the phrase.
- **No speaker check.** Anyone in the room who says the phrase wakes it. The protection against acting on a bystander is the spoken yes that every risky action still needs.
