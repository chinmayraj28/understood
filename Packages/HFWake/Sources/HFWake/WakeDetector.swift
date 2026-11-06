import Foundation

/// One transcript from the recogniser.
///
/// Recognisers revise themselves: while you speak they send a guess for the current stretch of
/// speech (a *segment*), then better guesses for the same segment, then a final one. `segment`
/// says which stretch a transcript belongs to, so a revision replaces the earlier guess instead of
/// being counted as new speech.
struct TranscriptUpdate: Sendable, Equatable {
    var segment: Int
    var text: String
    var isFinal: Bool
}

/// How long to wait for the rest of the sentence after the phrase is heard.
///
/// Measured on this Mac: SpeechAnalyzer sends its guesses in bursts about 0.9 s apart, and a
/// final transcript 0.3 to 1 s after the speech stops. The final is the best sign that the person
/// has finished, so it is what normally triggers the wake; the quiet times are a fallback for when
/// no final comes (a television keeps the recogniser busy) and must be longer than one burst.
public struct WakeTiming: Sendable, Equatable {
    /// After a final transcript holding only the phrase, wait this long in case the next words
    /// arrive in the same burst. Short, so a bare "Hey Handsfree" does not feel slow.
    public var afterFinalBarePhrase: Double
    /// When no final comes: wake after a bare phrase once nothing new has been heard for this long.
    public var quietAfterBarePhrase: Double
    /// When no final comes: after "Hey Handsfree, open...", wake once nothing new has been heard
    /// for this long. Longer, because people pause mid-sentence, and slow speech pauses more.
    public var quietMidSentence: Double
    /// Wake at the latest this long after the phrase was first heard, even if words keep coming
    /// (a long sentence, or a television in the background).
    public var longestWait: Double

    public init(
        afterFinalBarePhrase: Double = 0.25, quietAfterBarePhrase: Double = 1.5, quietMidSentence: Double = 2.0,
        longestWait: Double = 10
    ) {
        self.afterFinalBarePhrase = afterFinalBarePhrase
        self.quietAfterBarePhrase = quietAfterBarePhrase
        self.quietMidSentence = quietMidSentence
        self.longestWait = longestWait
    }
}

/// Turns a stream of revised transcripts into exactly one wake.
///
/// Fed with every transcript and with the time, it says when to wake and with what. It holds no
/// timer and no audio, so it is tested by handing it transcripts and times. Once it has woken it
/// ignores everything until `reset()`: the listener is quiet until the caller starts it again.
///
/// It wakes, with the rest of the sentence, as soon as one of these holds:
/// - the phrase and some words after it have been heard, and the recogniser has finalised them
///   (the sentence is complete);
/// - the phrase alone has been finalised, and `afterFinalBarePhrase` has passed with no new words;
/// - no final has come, and nothing new has been heard for `quietAfterBarePhrase` (bare phrase)
///   or `quietMidSentence` (words after it);
/// - `longestWait` has passed since the phrase was first heard.
/// If a revision takes the phrase back out ("hey hands free" revised to "they handed three"),
/// it does not wake.
struct WakeDetector {
    let matcher: WakePhraseMatcher
    let timing: WakeTiming

    /// The phrase has been heard and the detector is waiting for the rest of the sentence.
    private struct Pending {
        var segment: Int
        var segmentText: String
        var rest: String
        var segmentIsFinal: Bool
        /// Later segments, in order of arrival: the user paused, and the recogniser started a new one.
        var laterSegments: [(segment: Int, text: String, isFinal: Bool)] = []
        let firstHeardAt: Double
        var lastChangeAt: Double
        /// When the phrase's own segment was finalised.
        var finalisedAt: Double?

        var restOfSentence: String {
            ([rest] + laterSegments.map(\.text))
                .map { WakePhraseMatcher.clean($0) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        var everythingFinal: Bool { segmentIsFinal && laterSegments.allSatisfy(\.isFinal) }
    }

    private var pending: Pending?
    /// The last finalised segment, kept briefly in case the phrase was split across two
    /// ("Hey." then "Handsfree, open Spotify").
    private var previousFinal: (segment: Int, text: String, at: Double)?
    private(set) var hasWoken = false

    init(matcher: WakePhraseMatcher, timing: WakeTiming = WakeTiming()) {
        self.matcher = matcher
        self.timing = timing
    }

    /// Ready for the next wake.
    mutating func reset() {
        pending = nil
        previousFinal = nil
        hasWoken = false
    }

    /// True while the phrase has been heard and the detector is waiting for the rest.
    var isWaitingForRestOfSentence: Bool { pending != nil && !hasWoken }

    /// What the detector decided: wake now, with this.
    struct Wake: Equatable {
        var restOfSentence: String
        /// When the phrase was first seen in a transcript, and when the last new words arrived,
        /// in the same clock as the `now` passed in. For measuring how long waking took.
        var phraseFirstHeardAt: Double
        var lastWordsAt: Double
    }

    /// Takes one transcript. Returns a wake when it is time to wake.
    mutating func receive(_ update: TranscriptUpdate, at now: Double) -> Wake? {
        guard !hasWoken else { return nil }
        if var current = pending {
            if update.segment == current.segment {
                guard let match = matchInSegment(update.text, now: now) else {
                    // The revision took the phrase back out.
                    pending = nil
                    remember(update, at: now)
                    return nil
                }
                if Self.differentWords(update.text, current.segmentText) { current.lastChangeAt = now }
                if update.isFinal && !current.segmentIsFinal { current.finalisedAt = now }
                current.segmentText = update.text
                current.rest = match.restOfSentence
                current.segmentIsFinal = update.isFinal
            } else if current.laterSegments.isEmpty, update.isFinal, let match = matcher.match(update.text) {
                // A final whose stretch starts slightly differently from the guesses before it:
                // it is the same words, so it replaces the phrase's segment rather than adding to it.
                if Self.differentWords(update.text, current.segmentText) { current.lastChangeAt = now }
                current.segment = update.segment
                current.segmentText = update.text
                current.rest = match.restOfSentence
                if !current.segmentIsFinal { current.finalisedAt = now }
                current.segmentIsFinal = true
            } else if let index = current.laterSegments.firstIndex(where: { $0.segment == update.segment }) {
                if Self.differentWords(current.laterSegments[index].text, update.text) { current.lastChangeAt = now }
                current.laterSegments[index] = (update.segment, update.text, update.isFinal)
            } else {
                current.laterSegments.append((update.segment, update.text, update.isFinal))
                current.lastChangeAt = now
            }
            pending = current
            if !current.restOfSentence.isEmpty && current.everythingFinal { return wake() }
            return check(at: now)
        }

        if let match = matchInSegment(update.text, now: now) {
            pending = Pending(
                segment: update.segment, segmentText: update.text, rest: match.restOfSentence,
                segmentIsFinal: update.isFinal, firstHeardAt: now, lastChangeAt: now,
                finalisedAt: update.isFinal ? now : nil)
            if !match.restOfSentence.isEmpty && update.isFinal { return wake() }
            return nil
        }
        remember(update, at: now)
        return nil
    }

    /// Called when a deadline passes. Returns the rest of the sentence when it is time to wake.
    mutating func check(at now: Double) -> Wake? {
        guard !hasWoken, let current = pending else { return nil }
        let rest = current.restOfSentence
        let quietFor = now - current.lastChangeAt
        if now - current.firstHeardAt >= timing.longestWait { return wake() }
        if let finalBare = Self.finalBareDeadline(current, timing), now >= finalBare { return wake() }
        if rest.isEmpty, quietFor >= timing.quietAfterBarePhrase { return wake() }
        if !rest.isEmpty, quietFor >= timing.quietMidSentence { return wake() }
        return nil
    }

    /// When `check(at:)` should next be called, or nil when nothing is pending.
    var nextDeadline: Double? {
        guard !hasWoken, let current = pending else { return nil }
        let quiet = current.restOfSentence.isEmpty ? timing.quietAfterBarePhrase : timing.quietMidSentence
        var deadline = min(current.lastChangeAt + quiet, current.firstHeardAt + timing.longestWait)
        if let finalBare = Self.finalBareDeadline(current, timing) { deadline = min(deadline, finalBare) }
        return deadline
    }

    /// New words, not just new punctuation or capitals: "Hey hands-free" revised to "Hey, hands free."
    /// is not someone speaking.
    static func differentWords(_ first: String, _ second: String) -> Bool {
        WakePhraseMatcher.words(of: first).joined() != WakePhraseMatcher.words(of: second).joined()
    }

    /// The phrase alone, finalised, with nothing after it yet: wake shortly unless words follow.
    private static func finalBareDeadline(_ pending: Pending, _ timing: WakeTiming) -> Double? {
        guard pending.restOfSentence.isEmpty, pending.everythingFinal, let finalisedAt = pending.finalisedAt else { return nil }
        return max(finalisedAt, pending.lastChangeAt) + timing.afterFinalBarePhrase
    }

    private mutating func wake() -> Wake {
        let wake = Wake(
            restOfSentence: pending?.restOfSentence ?? "",
            phraseFirstHeardAt: pending?.firstHeardAt ?? 0,
            lastWordsAt: pending?.lastChangeAt ?? 0)
        hasWoken = true
        pending = nil
        return wake
    }

    private mutating func remember(_ update: TranscriptUpdate, at now: Double) {
        if update.isFinal { previousFinal = (update.segment, update.text, now) }
    }

    /// Matches this segment on its own, or joined to the segment just before it when that one
    /// ended moments ago, so a phrase split by a short pause still counts.
    private func matchInSegment(_ text: String, now: Double) -> WakeMatch? {
        if let match = matcher.match(text) { return match }
        if let previous = previousFinal, now - previous.at <= 2.5 {
            // The join is a sentence break, so the matcher's start-of-sentence rules still apply.
            return matcher.match(previous.text + ". " + text)
        }
        return nil
    }
}
