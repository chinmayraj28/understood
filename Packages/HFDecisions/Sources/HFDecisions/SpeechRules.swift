import Foundation
import HFCore

/// Turning a spoken sentence into a comparable phrase.
public enum SpeechText {
    /// Hesitation sounds. Always dropped.
    public static let hesitations: Set<String> = ["uh", "uhh", "um", "umm", "er", "erm", "ah", "hmm", "mm"]
    /// Hesitation plus politeness and discourse words. Dropped when matching stop phrases only:
    /// "okay, please stop" is "stop". Not dropped for confirmation replies, where "okay" matters.
    public static let stopFillers: Set<String> = hesitations.union(["oh", "okay", "ok", "hey", "please", "just", "like", "so", "oi"])

    /// Lower-case words (letters, digits, apostrophes), punctuation dropped, fillers dropped, repeats collapsed.
    ///
    /// "Stop... stop it!" -> "stop it", "uh, wait" -> "wait", "STOP STOP STOP" -> "stop".
    public static func normalise(_ text: String, dropping fillers: Set<String> = stopFillers) -> String {
        let words = self.words(text, dropping: fillers)
        var collapsed: [String] = []
        for word in words where collapsed.last != word { collapsed.append(word) }
        // "stop it stop it" -> "stop it": drop a leading phrase that is said again at once.
        for size in 1...3 where collapsed.count > size && collapsed.count >= 2 * size {
            if Array(collapsed[size..<(2 * size)]) == Array(collapsed[0..<size]) {
                collapsed.removeFirst(size)
                break
            }
        }
        return collapsed.joined(separator: " ")
    }

    /// Lower-case words in order, punctuation and fillers dropped, repeats kept ("no no" stays two words).
    public static func words(_ text: String, dropping fillers: Set<String> = stopFillers) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        var words: [String] = []
        var current = ""
        for character in lowered {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter {
            !$0.isEmpty && !fillers.contains($0)
        }
    }

    /// Splits a sentence into clauses on punctuation: "stop, that's the wrong file" -> two clauses.
    static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",.!?;:…—–-")).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// The word rules for "does this sentence mean stop what you are doing?".
public enum UtteranceRules {
    /// Whole sentences that mean stop while the assistant is working.
    ///
    /// While a question is open most of these are answers instead: "Send 'running
    /// late' to Amma?" "No, don't" declines the action and keeps the task alive, so
    /// the user can follow with a correction ("no, don't, say fifteen minutes").
    /// Only `endTaskPhrases` cancel then.
    public static let hardCancel: Set<String> = Set([
        "stop", "stop it", "stop that", "stop this", "stop now", "stop right now", "stop right there",
        "stop everything", "stop stop", "no stop", "stop no", "cancel", "cancel it", "cancel that",
        "cancel this", "cancel everything", "cancel the task", "abort", "abort it", "abort that",
        "halt", "quit", "quit it", "enough", "that's enough", "thats enough", "never mind", "nevermind",
        "forget it", "forget about it", "forget that", "scrap that", "don't", "dont",
        "don't do that", "don't do it", "dont do that", "no don't", "no dont", "no wait don't",
        "no wait dont", "wait don't", "wait dont", "stop stop it", "can you stop", "could you stop",
        "stop doing that", "stop what you're doing", "stop what youre doing", "i said stop",
        "i said cancel", "i said no", "stop all of it", "stop the task", "stop the whole thing",
        "cancel the whole thing", "cancel all of it", "abort the task", "abort everything",
        "never mind forget it", "never mind forget about it", "nevermind forget it", "forget it all",
        "forget the whole thing",
    ]).union(stopListening)

    /// "Stop listening" and the like. Someone watching the pointer who says this mid-task almost
    /// certainly means "stop everything": a wrong cancel costs a retry, a wrong carry-on can finish a
    /// send they were trying to halt. So it stops a running task at once, even while a question is
    /// open, and the app then puts the conversation to sleep. With no task running it only sleeps.
    /// ("please" and "okay" are dropped before matching, so "okay, please stop listening" is here too.)
    public static let stopListening: Set<String> = [
        "stop listening", "stop listening now", "stop listening to me", "stop listening to me now",
        "you can stop listening", "you can stop listening now",
    ]

    /// Whole sentences that unmistakably end the whole task, even while a question
    /// is open. Everything else in `hardCancel` and `softCancel` is then an answer.
    public static let endTaskPhrases: Set<String> = Set([
        "stop", "stop it", "stop stop", "stop stop it", "stop everything", "stop all of it",
        "stop the task", "stop the whole thing", "stop right now", "stop now", "cancel the task",
        "cancel everything", "cancel the whole thing", "cancel all of it", "abort", "abort it",
        "abort the task", "abort everything", "halt", "quit", "never mind forget it",
        "never mind forget about it", "nevermind forget it", "forget it all", "forget the whole thing",
        "i said stop", "stop what you're doing", "stop what youre doing",
    ]).union(stopListening)

    /// Pause words. They stop a running task, but not while a question is open:
    /// then the task is already paused, and "wait" is the user thinking.
    /// A bare "no" is deliberately in neither list. The voice agent itself often
    /// asks "Anything else?", and "no" to that must not kill the task, so Jev
    /// judges a bare "no" with the context.
    public static let softCancel: Set<String> = [
        "wait", "wait wait", "no wait", "wait no", "hang on", "hold on", "hold it", "hold up",
        "one sec", "one second", "a sec", "a second", "wait a sec", "wait a second", "wait a minute",
        "hang on a second", "hang on a sec", "hold on a second", "hold on a sec", "whoa", "woah",
        "leave it",
    ]

    /// First words that make a sentence a new instruction (fallback only).
    public static let commandVerbs: Set<String> = [
        "open", "close", "play", "pause", "stop", "resume", "skip", "next", "previous", "mute", "unmute",
        "turn", "set", "volume", "scroll", "go", "search", "find", "look", "show", "read", "send",
        "message", "text", "call", "email", "write", "type", "create", "make", "schedule", "start",
        "join", "launch", "quit", "switch", "take", "book", "add", "remove", "delete", "copy", "paste",
        "save", "check", "tell", "reply", "put", "move", "lower", "raise", "increase", "decrease",
        "zoom", "click", "select", "remind", "draft", "restart", "shut", "lock", "minimise",
        "minimize", "maximise", "maximize", "dim", "brighten",
    ]

    /// Words that, said first while the pointer is acting, are the user's brake.
    public static let brakeOpeners: [[String]] = [
        ["no", "no"], ["hold", "on"], ["hang", "on"], ["hold", "up"], ["hold", "it"], ["wait"], ["whoa"], ["woah"],
    ]
    /// Words after a wait-like opener that make it an instruction about waiting, not a
    /// brake: "wait for the page to load, then scroll", "wait five seconds and click Next".
    public static let waitingInstructionWords: Set<String> = [
        "for", "until", "till", "til", "while", "before", "after", "to", "then", "and", "about", "on",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "fifteen", "twenty",
        "thirty", "few", "couple", "several",
    ]
    /// Words after "stop" that are not its object: "stop, that's wrong", "stop it now".
    /// Anything else after "stop" is an object ("stop the music") and goes to Jev.
    public static let stopNonObjects: Set<String> = [
        "it", "that", "this", "now", "stop", "no", "wait", "everything", "right", "there", "immediately",
        "that's", "thats", "you're", "youre", "wrong", "not", "i", "you", "don't", "dont", "please",
    ]

    /// The leading-brake rule: while a task is working and nothing is being asked, a
    /// sentence that opens with an unmistakable brake ("wait", "hold on", "hang on",
    /// "no no", or "stop" with no object) is a cancel, without asking Jev.
    ///
    /// Why: a person watching the pointer do the wrong thing says "wait" first and
    /// explains second. Missing "wait, wrong chat" costs a message in the wrong chat;
    /// cancelling on "wait, also add Sam" costs a restart.
    public static func leadingBrake(_ text: String) -> Decision<Intent>? {
        // With punctuation: the first clause alone is a stop or pause phrase.
        if let firstClause = SpeechText.clauses(text).first {
            let phrase = SpeechText.normalise(firstClause)
            if hardCancel.contains(phrase) || softCancel.contains(phrase) {
                return Decision(label: .cancel, confidence: 1, source: .rule, reason: "opens with the brake '\(phrase)'")
            }
        }
        // Without punctuation: the first words.
        let words = SpeechText.words(text)
        guard let opener = brakeOpeners.first(where: { words.starts(with: $0) }) else {
            guard words.first == "stop" else { return nil }
            if let next = words.dropFirst().first, !stopNonObjects.contains(next) { return nil }  // "stop the music"
            return Decision(label: .cancel, confidence: 1, source: .rule, reason: "opens with the brake 'stop'")
        }
        let next = words.dropFirst(opener.count).first
        if opener != ["no", "no"], let next, waitingInstructionWords.contains(next) || next.allSatisfy(\.isNumber) {
            return nil  // an instruction about waiting: let Jev read it
        }
        return Decision(label: .cancel, confidence: 1, source: .rule,
                        reason: "opens with the brake '\(opener.joined(separator: " "))'")
    }

    /// The instant local check, with no network: cancel for an exact stop phrase,
    /// other for a pause word while a question is open, nil when Jev should decide.
    ///
    /// A stop at the END of a sentence ("okay stop listening to him and stop") is deliberately not
    /// an instant rule: "don't stop", "it won't stop" and "make the music stop" end in "stop" too.
    /// Jev decides those, and the fallback below checks each clause when Jev is down. The app takes
    /// the wake phrase off the front first, so "Hey Handsfree stop" arrives here as "stop".
    public static func instantDecision(_ text: String, awaitingAnswer: Bool) -> Decision<Intent>? {
        let phrase = SpeechText.normalise(text)
        if awaitingAnswer {
            if endTaskPhrases.contains(phrase) {
                return Decision(label: .cancel, confidence: 1, source: .rule, reason: "'\(phrase)' ends the task even while asked")
            }
            if hardCancel.contains(phrase) || softCancel.contains(phrase) {
                return Decision(label: .other, confidence: 1, source: .rule,
                                reason: "'\(phrase)' while a question is open is an answer, not a cancel")
            }
            return nil
        }
        if hardCancel.contains(phrase) {
            return Decision(label: .cancel, confidence: 1, source: .rule, reason: "exact stop phrase '\(phrase)'")
        }
        if softCancel.contains(phrase) {
            return Decision(label: .cancel, confidence: 1, source: .rule, reason: "exact pause phrase '\(phrase)'")
        }
        return leadingBrake(text)
    }

    /// The keyword fallback, used when Jev is disabled, failing or unsure.
    ///
    /// While a task runs, a stop phrase as one clause cancels ("stop, that's the
    /// wrong file"). While a question is open, anything else is an answer. Otherwise
    /// a command verb followed by an object is a command ("stop the music").
    public static func fallback(_ text: String, context: UtteranceContext, why: String) -> Decision<Intent> {
        if context.taskRunning {
            for clause in SpeechText.clauses(text) {
                if let ruled = instantDecision(clause, awaitingAnswer: context.awaitingAnswer), ruled.label == .cancel {
                    return Decision(label: .cancel, confidence: 0.7, source: .keywords,
                                    reason: "\(why); clause '\(SpeechText.normalise(clause))' is a stop phrase")
                }
            }
        }
        if context.awaitingAnswer {
            return Decision(label: .other, confidence: 0.6, source: .keywords, reason: "\(why); a question is open")
        }
        var phrase = SpeechText.normalise(text)
        for prefix in ["can you ", "could you ", "would you ", "will you "] where phrase.hasPrefix(prefix) {
            phrase.removeFirst(prefix.count)
        }
        let words = phrase.split(separator: " ")
        if let first = words.first, commandVerbs.contains(String(first)), words.count > 1 {
            return Decision(label: .command, confidence: 0.6, source: .keywords, reason: "\(why); starts with '\(first)'")
        }
        return Decision(label: .other, confidence: 0.5, source: .keywords, reason: why)
    }
}

/// The word rules for reading a reply to a confirmation ("Send 'running late' to Amma?").
///
/// A wrong yes is the worst error in the product: it is the last check before a
/// message is sent or a file is deleted. So yes needs an unmistakable phrase (or a
/// very confident Jev) and is vetoed by anything that hints at a change, a
/// condition, doubt or a question.
public enum AnswerRules {
    /// Whole replies that are an unmistakable yes (after hesitation is dropped).
    public static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "yes please", "yeah please", "yes do it", "yeah do it",
        "yes send it", "yeah send it", "yes go ahead", "yeah go ahead", "go ahead", "go for it",
        "yes go for it", "yeah go for it", "do it", "send it", "that's right", "thats right", "correct",
        "yes that's right", "yes correct", "sure", "sure go ahead", "okay go ahead", "ok go ahead",
        "please do", "yes please do", "affirmative", "absolutely", "yes absolutely",
    ]
    /// Whole replies that are an unmistakable no.
    public static let noPhrases: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "don't", "dont", "do not", "don't send it",
        "don't do it", "don't do that", "not yet", "not now", "cancel", "cancel that", "cancel it", "stop",
        "no don't", "no stop", "no not yet", "never mind", "nevermind", "no no", "no cancel",
        "no don't send it", "definitely not", "absolutely not",
    ]
    /// Words that make a yes impossible: a change, a condition, doubt or a question.
    /// "yes but change the time", "did you say yes?", "not yes", "send it tomorrow instead".
    public static let yesVetoWords: Set<String> = [
        "but", "except", "change", "instead", "wait", "not", "don't", "dont", "no", "nope", "actually",
        "hold", "hang", "first", "before", "after", "if", "unless", "wrong", "other", "different", "edit",
        "fix", "rather", "maybe", "think", "later", "tomorrow", "tonight", "also", "plus", "add",
        "what", "which", "who", "why", "how", "did", "does", "should", "could", "would", "can",
        "make", "only", "cancel", "stop", "sorry", "mean", "guess", "probably", "perhaps",
    ]

    /// Normalised reply: hesitation dropped, "okay" kept.
    public static func normalise(_ reply: String) -> String {
        SpeechText.normalise(reply, dropping: SpeechText.hesitations)
    }

    /// Why this reply can never count as yes, or nil when nothing vetoes it.
    public static func yesVeto(_ reply: String) -> String? {
        if reply.contains("?") { return "it is a question" }
        let words = Set(normalise(reply).split(separator: " ").map(String.init))
        if let word = words.intersection(yesVetoWords).sorted().first { return "contains '\(word)'" }
        return nil
    }

    /// The fallback when Jev is unavailable: an exact yes or no phrase, else unclear.
    public static func fallback(_ reply: String, why: String) -> Decision<Answer> {
        let phrase = normalise(reply)
        if yesPhrases.contains(phrase), yesVeto(reply) == nil {
            return Decision(label: .yes, confidence: 0.9, source: .keywords, reason: "\(why); exact yes '\(phrase)'")
        }
        if noPhrases.contains(phrase) {
            return Decision(label: .no, confidence: 0.9, source: .keywords, reason: "\(why); exact no '\(phrase)'")
        }
        return Decision(label: .unclear, confidence: 0.5, source: .keywords, reason: "\(why); not an exact yes or no")
    }
}
