//
//  SleepPhrases.swift
//  Handsfree
//
//  Recognises the user ending the conversation ("stop listening", "go to
//  sleep", "that's all", "goodbye") from their own sentence, in the app. On
//  6 Nov the user said "stop listening" six times and it stayed awake, because
//  sleeping depended on the language model choosing to call a tool. The tool
//  stays as well; this rule makes it not depend on the model.
//
//  The rule is deliberately narrow: the sign-off must be the whole sentence,
//  give or take polite words ("thanks", "okay", "please", the wake name). So
//  "stop" alone and "stop the music" are untouched (the stop watcher and the
//  quick tools handle them as before), and "send Amma a message saying that's
//  all for today" is a request, not a sign-off. Pure, unit tested. New for Handsfree.
//

import Foundation

enum SleepPhrases {
    /// What remains once polite words are taken off, if it ends the conversation.
    static let signOffs: Set<String> = [
        "stop listening", "stop listening now", "you can stop listening", "please stop listening",
        "go to sleep", "go back to sleep", "you can go to sleep", "sleep", "sleep now", "go to sleep now",
        "thats all", "thats it", "that is all", "that is it", "that will be all", "thats all for now",
        "thats it for now", "thats everything", "nothing else", "nothing more", "no thats all", "no thats it",
        "goodbye", "good bye", "bye", "bye bye", "good night", "goodnight", "see you", "see you later",
        "were done", "we are done", "im done", "i am done", "all done",
    ]

    /// Words that may come before or after a sign-off without changing what it means.
    static let politeWords: Set<String> = [
        "thanks", "thank", "you", "thankyou", "okay", "ok", "please", "alright", "all", "right", "cheers",
        "great", "perfect", "so", "and", "now", "hey", "handsfree", "hands", "free", "for", "then", "yes", "yeah",
    ]

    /// True when the whole sentence ends the conversation.
    ///
    /// A bare "stop" or "be quiet" is never a sign-off: people say it to cut the agent off and then
    /// carry on, and during a task "stop" stops the task (the stop watcher), as before.
    static func isSignOff(_ sentence: String) -> Bool {
        let words = normalizedWords(sentence)
        guard !words.isEmpty, words.count <= 9 else { return false }
        // Try the sentence with polite words trimmed from either end, longest phrase first.
        for start in 0..<words.count {
            if start > 0, !politeWords.contains(words[start - 1]) { break }
            for end in stride(from: words.count, to: start, by: -1) {
                if end < words.count, !politeWords.contains(words[end]) { break }
                let phrase = words[start..<end].joined(separator: " ")
                guard signOffs.contains(phrase) else { continue }
                return true
            }
        }
        return false
    }

    /// Lower case, letters and digits only ("That's all, thanks!" -> ["thats", "all", "thanks"]).
    static func normalizedWords(_ sentence: String) -> [String] {
        sentence.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
