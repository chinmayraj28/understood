# What makes Clicky feel good, and what Handsfree took from it

Clicky (github.com/farzaa/clicky, MIT licence, copyright 2026 Farza) is a macOS menu bar companion. A small blue triangle follows your pointer. You hold Control+Option and talk. It takes a screenshot, asks Claude, speaks the answer, and can fly across the screen to point at the button you should press. Handsfree is built on its code. This note explains, in plain words, how Clicky is put together and why it feels polished, with the real numbers from its source, so it is clear what we took and why it works.

The source read for this note is the copy cloned on 5 Nov 2026. File names below are Clicky's (its source folder is called `leanring-buddy`).

---

## 1. The overlay window: floating over everything without getting in the way

The blue companion is not drawn inside an app window. Clicky puts one transparent window over each whole screen (`OverlayWindow.swift`, class `OverlayWindow`) and draws the companion inside it. Six settings make that safe:

| Setting | Value | What it does |
|---|---|---|
| `styleMask` | `.borderless` | No title bar, no frame. |
| `isOpaque`, `backgroundColor` | `false`, `.clear` | Everything not drawn is see-through. |
| `level` | `.screenSaver` | Sits above normal windows, menus, pop-ups and the Dock, so the companion is never hidden. |
| `ignoresMouseEvents` | `true` | Every click passes straight through to the app underneath. This is what makes a window covering the whole screen harmless. |
| `collectionBehavior` | `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` | Shows on every desktop Space, is not moved by Mission Control, and is allowed over full-screen apps. |
| `hidesOnDeactivate` | `false` | A menu bar app is almost never the "active" app; without this the overlay would vanish. |

It also overrides `canBecomeKey` and `canBecomeMain` to return `false`, so the overlay can never take keyboard focus from the app you are typing in.

**Example:** you are typing in Mail with Clicky running. The overlay covers the screen, but your typing still goes to Mail and your clicks still land on Mail's buttons, because the overlay can neither take focus nor receive clicks.

The response bubble (`CompanionResponseOverlay.swift`) uses the same idea in a smaller window: an `NSPanel` with `[.borderless, .nonactivatingPanel]`, level `.statusBar`, click-through, and the same collection behaviour. A *non-activating* panel is a window that can appear without making its app the active one.

**What Handsfree kept:** all of it, unchanged, in `Handsfree/Companion/OverlayWindow.swift`. **What we added:** `sharingType = .none`, which keeps the overlay out of screenshots (Section 9), `.ignoresCycle` so it is skipped by window cycling, and rebuilding the overlays when a display is plugged in or rearranged (Clicky creates them once).

## 2. Following the pointer, and how the motion is tuned

`BlueCursorView` (the SwiftUI view inside each overlay) reads the pointer position on a timer every **0.016 s** (about 60 times a second) with `NSEvent.mouseLocation`. It places the triangle **35 points right and 25 points below** the pointer tip, so it trails the arrow like a shadow and never covers the tip you aim with.

The trick that makes it feel alive rather than glued on is that the position is not set directly. It is animated with a spring:

```swift
.animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
```

- `response: 0.2` means the spring settles in about a fifth of a second: fast enough to feel attached.
- `dampingFraction: 0.6` is under-damped, so it overshoots a little and settles back. That small wobble is what makes it feel like a living companion and not a sticker.

Other motion details from the same file:

- **Appearing:** on first launch the triangle fades in with `.easeIn(duration: 2.0)`.
- **Changing state:** the triangle, waveform and spinner are all kept in the view at once and cross-faded by opacity (`.easeIn(duration: 0.25)` for the triangle, `0.15` for the others). The comment explains why: removing and re-inserting views made the cursor visibly "pop".
- **Text bubbles** stream in one character at a time, with a random **30 to 60 ms** between characters (the welcome text uses a steady 30 ms). That rhythm reads like speech.
- **Bubble entrance:** the pointing bubble starts at **0.5×** scale and springs to 1× (`.spring(response: 0.4, dampingFraction: 0.6)`), with a glow that starts bright (shadow radius 6 + 16) and settles to radius 6.
- **Fades out:** bubbles fade with `.easeOut(duration: 0.5)`; the response panel holds for **6 s** after speech ends, then fades over **0.4 s**.

**The flight to a target.** When Claude's answer contains `[POINT:x,y:label]`, the triangle leaves the pointer and flies to the target (`animateBezierFlightArc`):

- The path is a quadratic bezier curve. The control point is the midpoint lifted by `min(distance × 0.2, 80)` points, so it travels in a gentle arc rather than a straight line.
- The duration grows with distance: `distance / 800` seconds, clamped to **0.6 to 1.4 s**.
- It is stepped by its own **60 fps** timer (no SwiftUI animation during flight), with smoothstep easing `3t² − 2t³`, so it starts and ends gently.
- The triangle rotates to face its direction of travel (the tangent of the curve), grows to **1.3×** at the middle of the flight (`1 + sin(πt) × 0.3`), and its glow grows with it.
- On arrival it rotates back to **−35°**, shows a short bubble ("right here!", "this one!"), holds it for **3 s**, fades for **0.5 s**, and flies back. If you move the mouse more than **100 points** while it flies back, it gives up and snaps to the pointer.

**What Handsfree kept:** the 60 Hz polling, the spring `(0.2, 0.6)` for following, the offset-beside-the-tip idea, keeping views in the tree and cross-fading, and smoothstep easing (we use it for the simulated pointer in demo mode). **What we changed, and why:** our companion never flies away. Clicky points at what *you* should click. Our agent does the clicking with the real pointer, so the real pointer travels and the companion rides along with it. Instead of a flight, we draw a ring at the target that closes in as the pointer arrives, then a halo when the click lands (`TargetMarkerView.swift`). We also read the user's pointer size setting and push the companion further out when the pointer is enlarged, which many people with low vision do.

## 3. How Clicky shows its voice states

Clicky has four states (`CompanionVoiceState`): idle, listening, processing and responding.

| State | What you see | Details from the code |
|---|---|---|
| Idle | The blue triangle | 16 by 16 points, rotated −35°, blue `#3380FF` with a glow of radius 8. |
| Listening (key held) | A small waveform replaces the triangle | 5 bars, 2 points wide, 2 apart, heights shaped `[0.4, 0.7, 1.0, 0.7, 0.4]`, redrawn at 36 fps. Height = `3 + level × 10 × shape + idle ripple`, with the level eased by `pow(min(level × 2.85, 1), 0.76)` so quiet speech still moves the bars. |
| Processing | A spinner | A circle trimmed from 15% to 85%, stroked with an angular gradient from clear to blue, 14 points, spinning once every **0.8 s**. |
| Responding | The triangle again, while the voice plays | The text is spoken, not shown, in the current version. |

The waveform's idle ripple (`sin(time × 3.6 + bar × 0.35)`) keeps the bars moving slightly even in silence, which tells you the microphone is live.

**What Handsfree kept:** the waveform formula and bar shape, and the spinner (both in `CompanionGlyphs.swift`), drawn larger (1.7× the bar height) in white on a dark disc so they read on any background. **What we added:** our user cannot hold a key, so there is no push-to-talk. The microphone is always on, so "listening" is the resting state: a small breathing iris dot. Then there are the states an acting agent needs: thinking (spinner with an eye), moving, clicking, typing, scrolling, a question, an action held for a yes, stopped, done, failed and disconnected.

## 4. The menu bar panel

`MenuBarPanelManager.swift` builds the menu bar icon and the panel under it.

- **The icon** is an `NSStatusItem` whose image is the same triangle drawn in code (18 points, 70% fill, rotated 35°), marked as a *template* image so macOS tints it for light and dark menu bars.
- **The panel** is a custom `NSPanel` subclass that overrides `canBecomeKey` (so its text field can take typing) while staying `.nonactivatingPanel` (so opening it does not take focus from the app in front). It is borderless, clear, `.floating` level, with no system shadow; the SwiftUI content draws its own rounded background and two-layer shadow (`black 0.5, radius 20, y 10` and `black 0.3, radius 4, y 2`).
- **Position:** centred under the icon, **4 points** below the menu bar, sized to the content's `fittingSize` so it hugs what it shows. It is **320 points** wide.
- **Closing:** a global mouse monitor closes it when you click anywhere else, like a popover. It waits **0.3 s** first, so a permission dialog opened from the panel does not close it straight away.
- **The content** (`CompanionPanelView.swift`): a header with a glowing 8-point status dot, the name and a status word, and a close button; sections separated by hairlines; permission rows (icon, name, then a green "Granted" dot or a "Grant" button); and a footer with Quit.

**What Handsfree kept:** the status item and panel pattern exactly, the 4-point gap, sizing to content, the click-outside closing with its 0.3 s delay, the header and row layout, and the two-layer shadow. **What we changed:** our own icon (a pointer arrow with two sound waves), width 372 for longer transcript lines, and new content: setup items written for a carer, the live transcript, the current task and its steps, what memory has learned, and which parts are real. **Removed:** the email form, model picker, onboarding video and "DM Farza" button. Nothing in our panel is needed to use the product.

## 5. The permission flow

Clicky needs Microphone, Accessibility, Screen Recording, and a fourth "screen content" check (a test screenshot through ScreenCaptureKit). The helpers are in `WindowPositionManager.swift`:

- **Reading** state: `AXIsProcessTrusted()` for Accessibility, `CGPreflightScreenCaptureAccess()` for Screen Recording, `AVCaptureDevice.authorizationStatus(for: .audio)` for the microphone.
- **Asking:** the first press of "Grant" shows macOS's own one-time prompt (`AXIsProcessTrustedWithOptions` with the prompt option, or `CGRequestScreenCaptureAccess()`). Later presses open the right page of System Settings instead (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, `...?Privacy_ScreenCapture`, `...?Privacy_Microphone`). This means a person never gets the prompt and the Settings page at the same time.
- **Polling:** `CompanionManager` re-checks every permission every **1.5 s**, so the panel turns green the moment a switch is flipped in System Settings.
- **Screen Recording quirk:** Clicky remembers in UserDefaults that Screen Recording was once granted, because `CGPreflightScreenCaptureAccess()` sometimes reports a false "no". It also tells the user "Quit and reopen after granting", because macOS only applies that permission after a restart.
- **Finding the app:** a "Find App" button reveals the app in Finder so it can be dragged into the Accessibility list if it does not appear.
- At launch, the panel opens by itself if onboarding is not done or a permission is missing.

**What Handsfree kept:** the same three checks, the prompt-once-then-Settings rule (and we remember "asked before" across launches), the polling (every 2 s), and opening the panel at launch when something is missing. **What we changed:** every sentence is written for whoever is helping, because our user cannot click (`SetupCheck.swift`). Example: "Handsfree needs Accessibility to move the pointer, click and type for them. Click Ask macOS, then Open System Settings in the box that appears, and switch Handsfree on."

## 6. Multiple displays

- **One overlay per screen.** `OverlayWindowManager.showOverlay` makes one `OverlayWindow` per `NSScreen`, each with its own `BlueCursorView` given that screen's frame.
- **Only one companion visible.** Each view checks whether the pointer is on *its* screen (`screenFrame.contains(mouseLocation)`) and hides the triangle otherwise. While one screen's buddy is flying to a target, the others hide theirs, so there is never a duplicate.
- **Coordinates.** AppKit measures from the bottom left of the main display with y going up; SwiftUI measures from the top left of each window. The conversion is `x − screen.minX`, `screen.maxY − y` (`convertScreenPointToSwiftUICoordinates`).
- **Screenshots** (`CompanionScreenCaptureUtility.swift`): every display is captured, the one with the pointer first and labelled "primary focus". Clicky maps ScreenCaptureKit's display IDs back to `NSScreen` frames, because ScreenCaptureKit uses top-left coordinates and secondary displays would otherwise be placed wrong.

**What Handsfree kept:** one overlay per screen, showing the companion only on the pointer's screen, and the same conversion (`OverlayGeometry.canvasPoint`). **What we added:** HFCore's points are top-left on the main display, so there is one more conversion (`appKitPoint(fromTopLeft:)`), and target rings are drawn on whichever screen the target is on, even if the pointer is on another one. The overlays are rebuilt when displays change. The screen agent itself only works on the main display for now (an HFEyes decision).

## 7. Design tokens

`DesignSystem.swift` puts every colour, size and duration under one namespace, `DS`, so nothing is hard-coded in views.

- **Surfaces**, deepest to most raised: `#101211`, `#171918`, `#202221`, `#272A29`, `#2E3130`. Higher means lighter, which gives depth on a dark UI without borders everywhere.
- **Borders** `#373B39` (subtle) and `#444947` (strong). **Text** `#ECEEED`, `#ADB5B2`, `#6B736F`.
- **Accent:** Tailwind blue 600 `#2563eb` for buttons (white text on it is about 5.1:1, WCAG AA). The overlay uses its own blue `#3380FF`.
- **Meanings:** red `#E5484D` for destructive, green `#34D399` for success and "granted", amber `#FFB224` for warnings.
- **Scales:** spacing 4, 8, 12, 16, 20, 24, 32; radii 6, 8, 10, 12; durations 0.15 (fast), 0.25 (normal), 0.4 (slow).
- **Buttons:** primary, secondary, tertiary, text, outlined, destructive and icon styles, each with hover and press states (press shrinks to 0.97×). The primary button even has a slow "breathing" glow while hovered (a 2.5 s loop).
- **Pointer cursor bridge:** a tiny AppKit view that registers a cursor rectangle, because SwiftUI's `onHover` with `NSCursor.push/pop` proved unreliable.

**What Handsfree kept:** the `DS` namespace and its structure, the layered surfaces, the scales, the hex helper and the cursor bridge (`Handsfree/Design/DesignSystem.swift`). **What we changed:** our own palette. The accent is iris (violet, `#8B66FF` for the companion, `#6B47F5` behind white text, about 5.7:1). Most Mac apps are blue, so a blue companion disappears into the app it is working in, and violet does not. Amber now means only "waiting for you", red only "stop or failed", and green only "done", so each colour has one meaning that can be read at a glance. We added a `DS.Companion` section with larger type (15 pt captions, 20 pt for a confirmation question, against Clicky's 11 pt bubbles) and a near-black caption surface at 93% opacity with a light edge, so white text reads on light and dark apps alike.

## 8. The app's shape

- The entry point (`leanring_buddyApp.swift`) is a SwiftUI `App` whose only scene is an empty `Settings`, with an `NSApplicationDelegate` that builds everything at launch. `LSUIElement = true` in Info.plist removes the Dock icon and the app menu.
- `CompanionManager` is the central state object: it owns the push-to-talk monitor (a listen-only `CGEvent` tap for Control+Option), dictation (AssemblyAI streaming, with OpenAI and Apple Speech fallbacks), screenshots, the Claude call, ElevenLabs speech, and the overlay.
- API keys are kept off the Mac behind a Cloudflare Worker proxy. PostHog does analytics, Sparkle does updates, and the app registers itself as a login item.
- Its notes say not to build from the terminal with `xcodebuild` because permissions are lost. We tested this ourselves; see docs/APP.md. In short: what loses permissions is an ad-hoc signature, which changes with every build. A stable signing certificate keeps the same identity from build to build.

**What Handsfree kept:** the entry point pattern and `LSUIElement`. **Removed:** push-to-talk and its key monitor, Clicky's whole voice pipeline (AssemblyAI, OpenAI and Apple speech providers, dictation manager, ElevenLabs TTS client), the Worker proxy, PostHog, Sparkle, the login item, the onboarding video, music and images, and Clicky's Claude client and element detector (the screen agent package used the latter as a reference). Our composition root (`AppCoordinator`) wires our packages together instead.

## 9. One thing Clicky does that we had to do differently: staying out of screenshots

Clicky leaves its own windows out of the screenshots it sends to Claude by passing them to ScreenCaptureKit's filter (`SCContentFilter(display:excludingWindows:)` with every window whose bundle ID is Clicky's). That works for captures Clicky takes itself. We need the overlay to be invisible to *any* capture the screen agent takes, so we do two things:

1. The overlay and panel windows set `sharingType = .none`, which asks the window server to leave them out of other processes' captures.
2. HFEyes' `ScreenEyes` leaves every window of our own process out of its ScreenCaptureKit filter, Clicky's method.

docs/APP.md records the capture test that checked this.
