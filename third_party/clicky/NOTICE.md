# Clicky in Handsfree

The Handsfree app (`Handsfree/`) is built on code from **Clicky** by Farza:

- Source: https://github.com/farzaa/clicky, cloned on 5 Nov 2026 at commit `e71105ce091d71dff4d89cf5d8d37ea1df460961` (28 Oct 2026).
- Licence: MIT. The full licence text and copyright notice are in `LICENSE` in this folder, as the licence requires. The author's README also says to do whatever you want with it.

Each file below starts with a comment saying it is adapted from Clicky and naming the Clicky file. "Adapted" means Clicky's code was the starting point and was changed. What was kept and what was changed is written at the top of each file and explained in `docs/research/clicky.md`.

## Files adapted from Clicky

| Handsfree file | Clicky file (in `leanring-buddy/`) | What came from Clicky |
|---|---|---|
| `Handsfree/App/HandsfreeApp.swift` | `leanring_buddyApp.swift` | Menu-bar-only app entry: SwiftUI `App` with an empty `Settings` scene and an app delegate that builds everything at launch. |
| `Handsfree/Companion/OverlayWindow.swift` | `OverlayWindow.swift` (`OverlayWindow`, `OverlayWindowManager`) | The full-screen, transparent, click-through, never-focused overlay window, one per screen. |
| `Handsfree/Companion/CompanionOverlayView.swift` | `OverlayWindow.swift` (`BlueCursorView`) | One view per screen showing the companion only where the pointer is; the companion offset beside the pointer and moved with a spring (response 0.2, damping 0.6); measuring the bubble to place it; cross-fading instead of removing views. |
| `Handsfree/Companion/CompanionGlyphs.swift` | `OverlayWindow.swift` (`BlueCursorWaveformView`, `BlueCursorSpinnerView`) | The five-bar waveform (bar profile, level easing, idle ripple, 36 fps) and the angular-gradient spinner (0.8 s per turn). |
| `Handsfree/Companion/PointerTracker.swift` | `OverlayWindow.swift` (`BlueCursorView.startTrackingCursor`) | Polling the pointer position about 60 times a second. |
| `Handsfree/Companion/OverlayGeometry.swift` | `OverlayWindow.swift` (`convertScreenPointToSwiftUICoordinates`, the smoothstep easing in `animateBezierFlightArc`) and `CompanionResponseOverlay.swift` (`repositionPanelNearCursor`) | The AppKit-to-overlay coordinate conversion, smoothstep easing, and flipping a bubble to the other side near a screen edge. |
| `Handsfree/Design/DesignSystem.swift` | `DesignSystem.swift` | The `DS` token namespace and its structure, layered dark surfaces, spacing, radius and duration scales, button style pattern, the hex colour helper and the pointer-cursor bridge. Colours are ours. |
| `Handsfree/Panel/MenuBarPanelManager.swift` | `MenuBarPanelManager.swift` | The menu bar status item and the borderless non-activating panel below it, its position (centred, 4 points below the menu bar, sized to content) and closing on an outside click after 0.3 s. Since 6 Nov the panel sits on the system material with the system shadow instead of Clicky's drawn dark card and two-layer shadow. |
| `Handsfree/Setup/PermissionChecker.swift` | `WindowPositionManager.swift` (the permission half) | Reading the three permissions and the rule of showing macOS's prompt once, then opening System Settings. |
| `Handsfree/Info.plist` (generated from `project.yml`) | `Info.plist` | `LSUIElement` (menu bar only); a copyright line credits Clicky. |

## Ideas from Clicky, code our own

These files contain no Clicky code but follow an approach Clicky used:

- `Handsfree/Design/BrandMarks.swift`: drawing the menu bar icon in code as a template image (Clicky's `makeClickyMenuBarIcon`). The shape is ours.
- `Handsfree/Companion/TargetMarkerView.swift`: new. It replaces Clicky's bezier flight to a target, because in Handsfree the real pointer travels.
- `Handsfree/Setup/SetupCheck.swift`: new. The wording is ours, written for a carer.

## Not taken

Clicky's voice pipeline (AssemblyAI, OpenAI and Apple speech providers, dictation manager, push-to-talk key monitor, ElevenLabs TTS client), its Claude and OpenAI clients, `ElementLocationDetector.swift`, the Cloudflare Worker proxy, PostHog analytics, the Sparkle updater, the login item, the onboarding video, music, images and copy, and Clicky's name, icon and blue branding. Handsfree's own app icon and menu bar icon are original.
