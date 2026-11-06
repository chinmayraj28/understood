//
//  DemoScript.swift
//  Handsfree
//
//  A scripted sequence of ActivityBus events that walks the companion through
//  every state: asleep, waking on the phrase, listening, the user speaking, a heard sentence, thinking,
//  progress, the pointer travelling, clicks, typing, a question, an action held
//  for a yes, done, stop, a dropped connection and a failure. No network and
//  no permissions, so the look and motion can be reviewed and recorded before
//  the other packages exist. Pure data, unit tested. New for Handsfree.
//

import CoreGraphics
import Foundation
import HFCore

/// Where the controls of the practice backdrop are, as fractions of the screen,
/// so the demo's pointer targets land on the controls the backdrop draws.
enum DemoLayout {
    /// The mock chat window, as fractions of the screen size.
    static let windowFraction = CGRect(x: 0.17, y: 0.14, width: 0.66, height: 0.70)
    static let sidebarWidthFraction: CGFloat = 0.32  // of the window width
    static let titleBarHeight: CGFloat = 44
    static let searchFieldHeight: CGFloat = 34
    static let chatRowHeight: CGFloat = 58
    static let composerHeight: CGFloat = 56

    static func windowRect(screen: CGSize) -> CGRect {
        CGRect(
            x: (windowFraction.minX * screen.width).rounded(),
            y: (windowFraction.minY * screen.height).rounded(),
            width: (windowFraction.width * screen.width).rounded(),
            height: (windowFraction.height * screen.height).rounded())
    }

    static func sidebarRect(screen: CGSize) -> CGRect {
        let window = windowRect(screen: screen)
        return CGRect(x: window.minX, y: window.minY + titleBarHeight, width: (window.width * sidebarWidthFraction).rounded(), height: window.height - titleBarHeight)
    }

    static func searchFieldRect(screen: CGSize) -> CGRect {
        let sidebar = sidebarRect(screen: screen)
        return CGRect(x: sidebar.minX + 14, y: sidebar.minY + 12, width: sidebar.width - 28, height: searchFieldHeight)
    }

    /// Row `index` of the chat list (0 is the first chat).
    static func chatRowRect(screen: CGSize, index: Int) -> CGRect {
        let search = searchFieldRect(screen: screen)
        let sidebar = sidebarRect(screen: screen)
        return CGRect(x: sidebar.minX, y: search.maxY + 14 + CGFloat(index) * chatRowHeight, width: sidebar.width, height: chatRowHeight)
    }

    static func composerRect(screen: CGSize) -> CGRect {
        let window = windowRect(screen: screen)
        let sidebar = sidebarRect(screen: screen)
        return CGRect(x: sidebar.maxX + 16, y: window.maxY - composerHeight + 10, width: window.maxX - sidebar.maxX - 32 - 84, height: composerHeight - 20)
    }

    static func sendButtonRect(screen: CGSize) -> CGRect {
        let composer = composerRect(screen: screen)
        return CGRect(x: composer.maxX + 10, y: composer.minY, width: 74, height: composer.height)
    }

    /// Where the simulated pointer starts.
    static func pointerStart(screen: CGSize) -> CGPoint {
        CGPoint(x: (screen.width * 0.56).rounded(), y: (screen.height * 0.46).rounded())
    }

    /// A spot in the empty conversation area, used by the scene that is stopped mid-glide.
    static func farTarget(screen: CGSize) -> CGPoint {
        let window = windowRect(screen: screen)
        return CGPoint(x: window.maxX - 60, y: window.minY + titleBarHeight / 2)
    }
}

/// One timed step of the demo.
struct DemoStep: Equatable {
    /// Seconds from the start of the demo.
    let time: Double
    /// The event to post, if any.
    let event: ActivityEvent?
    /// A named moment, for `--freeze <name>`: the demo stops just after this step.
    let moment: String?
}

enum DemoScript {

    /// Every moment the script names, in order. `--freeze` accepts any of these.
    static let moments = [
        "asleep", "waking",
        "listening", "speaking", "heard", "thinking", "progress", "moving", "clicked", "typing",
        "asking", "holding", "answering", "done", "stopped", "disconnected", "reconnected", "failed",
        "asleep-again",
    ]

    /// The phrase the demo pretends to hear.
    static let wakePhrase = "Hey Handsfree"
    /// Seconds the opening wake scene takes; the rest of the script starts after it.
    static let wakeSceneSeconds = 4.0

    /// The whole script for a screen of the given size (in points). Positions are
    /// HFCore screen points (origin top left), as the real hands would post them.
    static func steps(screen: CGSize) -> [DemoStep] {
        var steps: [DemoStep] = []
        // Times below are written from the start of each part; this moves them along.
        var offset = 0.0
        func at(_ time: Double, _ event: ActivityEvent?, moment: String? = nil) {
            steps.append(DemoStep(time: offset + time, event: event, moment: moment))
        }
        func speech(from start: Double, to end: Double, moment: String? = nil, momentAt: Double? = nil) {
            var time = start
            while time < end {
                at(time, .userSpeaking(level: speechLevel(at: time)), moment: (momentAt != nil && abs(time - momentAt!) < 0.026) ? moment : nil)
                time += 0.05
            }
        }
        func typing(from start: Double, to end: Double, moment: String? = nil) {
            var time = start
            var isFirst = true
            while time < end {
                at(time, .typing, moment: isFirst ? moment : nil)
                isFirst = false
                time += 0.14
            }
        }
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX.rounded(), y: rect.midY.rounded()) }

        let searchField = center(DemoLayout.searchFieldRect(screen: screen))
        let ammaRow = center(DemoLayout.chatRowRect(screen: screen, index: 0))
        let composer = center(DemoLayout.composerRect(screen: screen))
        let sendButton = center(DemoLayout.sendButtonRect(screen: screen))

        // Scene 0: asleep, until the phrase is heard. While asleep nothing leaves the Mac, so the
        // user's voice is not drawn (the voice service is not hearing it). The phrase was heard at
        // 2.0 s; the conversation is ready about a second later, when the rising chime plays.
        at(0.0, .asleep(wakePhrase: wakePhrase), moment: "asleep")
        at(2.0, .waking, moment: "waking")
        offset = wakeSceneSeconds

        // Scene 1: a message, with a question and a held Send.
        at(-0.9, .listening, moment: "listening")
        speech(from: 1.2, to: 3.4, moment: "speaking", momentAt: 2.0)
        at(3.45, .userSaid("Message Amma: running late, ten minutes"), moment: "heard")
        at(4.2, .agentSpeaking("Okay, messaging Amma."))
        at(5.2, .taskStarted(goal: "Message Amma: running late, ten minutes"))
        at(5.3, .thinking(caption: "Looking at the screen"), moment: "thinking")
        at(6.8, .progress("Finding Amma"), moment: "progress")
        at(7.0, .pointerMoving(to: searchField, duration: 0.9))
        at(7.45, nil, moment: "moving")
        at(7.95, .clicked(at: searchField), moment: "clicked")
        typing(from: 8.5, to: 9.6, moment: "typing")
        at(9.9, .scrolled)
        at(10.6, .thinking(caption: "Two chats match"))
        at(11.2, .waitingForAnswer(question: "Amma, or Amma Work?"), moment: "asking")
        at(11.3, .agentSpeaking("I can see two chats, Amma and Amma Work. Which one?"))
        speech(from: 13.4, to: 14.2)
        at(14.25, .userSaid("Just Amma"))
        at(14.8, .progress("Opening the chat with Amma"))
        at(15.0, .pointerMoving(to: ammaRow, duration: 0.8))
        at(15.85, .clicked(at: ammaRow))
        at(16.4, .progress("Writing the message"))
        at(16.6, .pointerMoving(to: composer, duration: 0.7))
        at(17.35, .clicked(at: composer))
        typing(from: 17.8, to: 19.4)
        at(19.6, .pointerMoving(to: sendButton, duration: 0.9))
        at(20.55, .heldForConfirmation(action: "Click button \u{201C}Send\u{201D} in Messages, window \u{201C}Amma\u{201D}"))
        at(20.6, .waitingForAnswer(question: "Send \u{201C}running late, ten minutes\u{201D} to Amma?"), moment: "holding")
        at(20.7, .agentSpeaking("Send \u{201C}running late, ten minutes\u{201D} to Amma?"))
        speech(from: 24.0, to: 24.9, moment: "answering", momentAt: 24.4)
        at(24.95, .userSaid("Yes, send it"))
        at(25.4, .clicked(at: sendButton))
        at(26.1, .taskEnded(status: .done, summary: "Sent to Amma."), moment: "done")
        at(26.3, .agentSpeaking("Done. I sent it to Amma."))

        // Scene 2: the user says stop in the middle of a glide.
        speech(from: 30.0, to: 31.4)
        at(31.45, .userSaid("Play some lo-fi on YouTube"))
        at(32.0, .taskStarted(goal: "Play lo-fi music on YouTube"))
        at(32.1, .thinking(caption: "Looking at the screen"))
        at(33.4, .progress("Opening YouTube"))
        at(33.6, .pointerMoving(to: DemoLayout.farTarget(screen: screen), duration: 1.6))
        speech(from: 33.9, to: 34.2)
        at(34.25, .userSaid("Stop"))
        at(34.3, .halted, moment: "stopped")
        at(34.5, .taskEnded(status: .cancelled, summary: "Stopped. Nothing else was done."))

        // Scene 3: the connection drops and comes back.
        at(38.5, .voiceDisconnected(reason: "The network connection was lost."), moment: "disconnected")
        at(42.5, .listening, moment: "reconnected")

        // Scene 4: a task that cannot be finished.
        at(44.0, .taskStarted(goal: "Find the invoice from March"))
        at(44.1, .thinking(caption: "Looking at the screen"))
        at(46.0, .taskEnded(status: .failed, summary: "I couldn\u{2019}t find an invoice from March."), moment: "failed")
        at(53.0, .listening)

        // Scene 5: nothing more is said, so it goes back to sleep (in the app, after 25 s of quiet).
        at(54.5, .asleep(wakePhrase: wakePhrase), moment: "asleep-again")
        return steps
    }

    /// When the script ends, in seconds.
    static func duration(screen: CGSize) -> Double {
        (steps(screen: screen).map(\.time).max() ?? 0) + 1
    }

    /// The step after which a moment holds still, or nil for an unknown name.
    static func indexOfMoment(_ moment: String, in steps: [DemoStep]) -> Int? {
        steps.firstIndex(where: { $0.moment == moment })
    }

    /// A believable speaking level: syllable-like bumps, never quite silent.
    static func speechLevel(at time: Double) -> Double {
        let syllables = abs(sin(time * 9.1)) * 0.45
        let words = abs(sin(time * 2.3 + 0.7)) * 0.35
        return min(max(0.12 + syllables + words, 0), 1)
    }
}
