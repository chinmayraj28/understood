//
//  SentenceRouting.swift
//  Handsfree
//
//  Where each finished sentence of the user's goes, and when a sign-off puts
//  the conversation to sleep. Pure, unit tested (HandsfreeTests/SentenceRoutingTests.swift).
//
//  The rules (6 Nov review):
//  - The stop watcher hears EVERY sentence, always. A sign-off is detected as
//    well, never instead: the stop watcher is one of the three things this
//    project never weakens.
//  - The wake phrase (and its alternatives, from settings) is taken off the
//    front first, so "Hey Handsfree stop" reaches the stop watcher as "stop":
//    an instant stop, with or without a comma, and with Jev down.
//  - "Stop listening" and the like stop a running or waiting task at once (the
//    stop watcher has them as instant stop phrases), then it sleeps.
//  - "That's all", "goodbye", "go to sleep": the task finishes and its result
//    is said, then it sleeps. With no task, any sign-off sleeps at once.
//  - Anything else said after a sign-off takes it back: "that's all", then
//    "actually, open my email after that" does not sleep over the new request.
//
//  New for Handsfree.
//

import Foundation

/// One sentence, worked out.
struct SentenceRoute: Equatable {
    enum SignOff: Equatable {
        /// "Stop listening": stops a task at once (through the stop watcher), then sleeps.
        case stopListening
        /// "That's all", "goodbye": lets a task finish, then sleeps.
        case finishThenSleep
    }

    /// What the stop watcher hears: the whole sentence, with a wake phrase taken off the front.
    let forStopWatcher: String
    let signOff: SignOff?
}

enum SentenceRouting {

    static func route(_ sentence: String, wakePhrases: [String]) -> SentenceRoute {
        let sentence = withoutWakePhrase(sentence, wakePhrases: wakePhrases)
        let signOff: SentenceRoute.SignOff?
        if SleepPhrases.isStopListening(sentence) {
            signOff = .stopListening
        } else if SleepPhrases.isSignOff(sentence) {
            signOff = .finishThenSleep
        } else {
            signOff = nil
        }
        return SentenceRoute(forStopWatcher: sentence, signOff: signOff)
    }

    /// Greetings that may come before the name in a wake phrase: "Hey Handsfree" also matches "Handsfree".
    static let greetings: Set<String> = ["hey", "hi", "hello", "ok", "okay", "oi"]

    /// The sentence with a wake phrase taken off its front, and the punctuation after it.
    /// "Hey Handsfree, stop" -> "stop"; "hey hands free stop" -> "stop"; "Handsfree stop" -> "stop".
    /// Spaces and punctuation inside the phrase do not matter ("hands free" is "handsfree").
    /// Anything that does not start with a wake phrase is returned unchanged.
    static func withoutWakePhrase(_ sentence: String, wakePhrases: [String]) -> String {
        var targets: Set<String> = []
        for phrase in wakePhrases {
            let words = letterWords(phrase)
            guard !words.isEmpty else { continue }
            targets.insert(words.joined())
            if words.count > 1, greetings.contains(words[0]) { targets.insert(words.dropFirst().joined()) }
        }
        guard !targets.isEmpty else { return sentence }

        // Walk the sentence word by word, gathering its letters; remember where the longest match ends.
        var gathered = ""
        var cut: String.Index?
        var index = sentence.startIndex
        while index < sentence.endIndex {
            while index < sentence.endIndex, !isWordCharacter(sentence[index]) { index = sentence.index(after: index) }
            guard index < sentence.endIndex else { break }
            while index < sentence.endIndex, isWordCharacter(sentence[index]) {
                let character = sentence[index]
                if character.isLetter || character.isNumber { gathered += character.lowercased() }
                index = sentence.index(after: index)
            }
            if targets.contains(gathered) { cut = index }
            guard targets.contains(where: { $0.hasPrefix(gathered) }) else { break }
        }
        guard let cut else { return sentence }
        let rest = sentence[cut...].drop { !isWordCharacter($0) }
        return String(rest)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    private static func letterWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// A request to sleep, held while a task finishes.
struct SleepRequest: Equatable {
    enum Action: Equatable {
        case none
        /// Nothing is going on: sleep once the agent's short reply is over.
        case sleepNow
        /// A task is running or waiting for an answer: sleep as soon as it has ended.
        case sleepWhenTaskEnds
    }

    private(set) var waitsForTask = false

    /// A sentence was heard. A sign-off asks to sleep; anything else takes back an earlier sign-off.
    mutating func heard(_ route: SentenceRoute, taskActive: Bool) -> Action {
        guard route.signOff != nil else {
            waitsForTask = false
            return .none
        }
        return asked(taskActive: taskActive)
    }

    /// A sign-off, or the agent's go_to_sleep tool. It never sleeps over a task.
    mutating func asked(taskActive: Bool) -> Action {
        guard taskActive else { return .sleepNow }
        waitsForTask = true
        return .sleepWhenTaskEnds
    }

    /// Checked every 2 s: true once the task a sign-off waited for has ended (and it is still awake).
    mutating func taskHasEnded(taskActive: Bool, conversationOpen: Bool) -> Bool {
        guard waitsForTask else { return false }
        guard conversationOpen else {
            waitsForTask = false
            return false
        }
        guard !taskActive else { return false }
        waitsForTask = false
        return true
    }
}
