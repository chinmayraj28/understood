import Foundation

// The part of the turn recorder that decides when a turn starts and ends. Pure code: it is fed
// sound levels and live transcripts with their times, and says what happened. No microphone,
// no clock of its own, so every rule here is tested with made-up numbers.
//
// Why it is patient: people with dysarthria pause for a long time inside a sentence. A voice
// agent that ends the turn after a second of quiet cuts them off (our own spike found a 3-second
// pause cut off). So a turn ends only after `endSilenceSeconds` of quiet (2.5 s by default), or
// when the person says "done", or at `maxTurnSeconds`.

/// The rules for finding the start and end of a turn. Every time is in seconds of audio.
public struct TurnEndSettings: Sendable, Equatable {
    /// Quiet this long ends the turn. Long, because pauses inside a sentence are normal here.
    public var endSilenceSeconds: Double
    /// A turn is cut off at this length, whatever is happening.
    public var maxTurnSeconds: Double
    /// Sound shorter than this (a cough, a click, a door) is not a turn.
    public var minimumSpeechSeconds: Double
    /// After "done" is heard as the last word, this much quiet ends the turn at once.
    public var doneSilenceSeconds: Double
    /// Speech must be this much louder than the room's noise floor.
    public var speechMarginDecibels: Double
    /// Never treat anything quieter than this as speech, however quiet the room is.
    public var quietestSpeechDecibels: Double
    /// Audio kept from just before the sound started, so the first sound of a word is not cut.
    public var preRollSeconds: Double
    /// Quiet kept after the last sound of the turn. The rest of the end silence is dropped.
    public var trailingSilenceKeptSeconds: Double
    /// Words that stop the agent the moment they appear in a live transcript.
    public var stopWords: Set<String>
    /// The word that ends a turn early when it is the last word.
    public var doneWord: String

    public init(
        endSilenceSeconds: Double = 2.5,
        maxTurnSeconds: Double = 30,
        minimumSpeechSeconds: Double = 0.3,
        doneSilenceSeconds: Double = 0.6,
        speechMarginDecibels: Double = 9,
        quietestSpeechDecibels: Double = -55,
        preRollSeconds: Double = 0.4,
        trailingSilenceKeptSeconds: Double = 0.4,
        stopWords: Set<String> = ["stop", "cancel", "wait"],
        doneWord: String = "done"
    ) {
        self.endSilenceSeconds = endSilenceSeconds
        self.maxTurnSeconds = maxTurnSeconds
        self.minimumSpeechSeconds = minimumSpeechSeconds
        self.doneSilenceSeconds = doneSilenceSeconds
        self.speechMarginDecibels = speechMarginDecibels
        self.quietestSpeechDecibels = quietestSpeechDecibels
        self.preRollSeconds = preRollSeconds
        self.trailingSilenceKeptSeconds = trailingSilenceKeptSeconds
        self.stopWords = stopWords
        self.doneWord = doneWord
    }
}

/// Why a turn ended.
public enum TurnEndReason: String, Sendable, Equatable {
    /// `endSilenceSeconds` of quiet after the person spoke.
    case silence
    /// The person said "done" as the last word.
    case saidDone
    /// The turn reached `maxTurnSeconds`.
    case maxLength
}

/// Where a finished turn sits in the audio, and what the live recogniser heard in it.
public struct TurnBoundary: Sendable, Equatable {
    /// Where to start cutting the audio (pre-roll included), in seconds of audio.
    public var audioStart: Double
    /// Where to stop cutting the audio, in seconds of audio. The end silence is not included.
    public var audioEnd: Double
    public var reason: TurnEndReason
    /// The live transcript of the turn, with a final "done" taken off.
    public var liveTranscript: String
}

/// What the detector noticed.
public enum TurnDetectorEvent: Sendable, Equatable {
    /// The person has been speaking for `minimumSpeechSeconds`: a turn is under way.
    case speechStarted(at: Double)
    /// How loud the person is right now, 0...1, while a turn is under way. For the waveform.
    case level(Double)
    /// A stop word appeared in a live transcript. Fired once for each time the word is said.
    case stopHeard(word: String, text: String)
    /// A short sound that was not speech was ignored.
    case blipIgnored(at: Double)
    /// The turn is over.
    case turnEnded(TurnBoundary)
}

/// Decides when turns start and end, from sound levels and live transcripts.
///
/// Feed it `audio(decibels:duration:)` for every chunk of microphone audio, in order, and
/// `transcript(key:segmentStart:text:)` whenever the live recogniser updates. Its clock is the
/// audio itself: `time` is the seconds of audio fed so far.
public struct TurnEndDetector: Sendable {
    public var settings: TurnEndSettings

    /// Seconds of audio fed so far.
    public private(set) var time: Double = 0
    /// The room's background level, learnt while nobody speaks.
    public private(set) var noiseFloorDecibels: Double?

    private enum Phase: Equatable {
        case idle
        /// Sound started at `start`; not yet long enough to be speech.
        case candidate(start: Double, voiced: Double, lastVoice: Double)
        /// A turn under way since `start`.
        case speaking(start: Double)
    }
    private var phase: Phase = .idle
    private var lastVoice: Double = 0
    /// Where the latest stretch of sound began, after a short gap. Used to cut off a spoken "done".
    private var lastRunStart: Double = 0
    private var levelsInTurn: [Double] = []

    /// The latest text of each live recogniser segment, and when the segment began (if known)
    /// and was last updated.
    private struct Segment { var text: String; var start: Double?; var updated: Double }
    private var segments: [Int: Segment] = [:]
    private var segmentOrder: [Int] = []
    /// For each segment, how many of each stop word have been seen, so a repeated partial
    /// result does not fire the same "stop" twice.
    private var stopCounts: [Int: [String: Int]] = [:]

    /// True while a turn is under way (speech confirmed, not yet ended).
    public var isInTurn: Bool { if case .speaking = phase { return true } else { return false } }

    public init(settings: TurnEndSettings = TurnEndSettings()) {
        self.settings = settings
    }

    /// The level above which sound counts as speech.
    public var speechThresholdDecibels: Double {
        max((noiseFloorDecibels ?? -70) + settings.speechMarginDecibels, settings.quietestSpeechDecibels)
    }

    // MARK: Audio

    /// One chunk of audio: its loudness (dBFS, 0 is the loudest possible) and its length.
    public mutating func audio(decibels: Double, duration: Double) -> [TurnDetectorEvent] {
        let chunkStart = time
        time += duration
        var events: [TurnDetectorEvent] = []
        if noiseFloorDecibels == nil { noiseFloorDecibels = decibels }
        let voiced = decibels >= speechThresholdDecibels

        switch phase {
        case .idle:
            learnNoiseFloor(decibels, duration: duration)
            if voiced {
                phase = .candidate(start: chunkStart, voiced: duration, lastVoice: time)
                startRun(at: chunkStart)
                lastVoice = time
                events += confirmIfLongEnough()
            }
        case .candidate(let start, let voicedSoFar, let candidateLastVoice):
            if voiced {
                if time - candidateLastVoice > duration + 0.0001 { startRun(at: chunkStart) }
                phase = .candidate(start: start, voiced: voicedSoFar + duration, lastVoice: time)
                lastVoice = time
                events += confirmIfLongEnough()
            } else if time - candidateLastVoice > settings.minimumSpeechSeconds {
                // Too short and now quiet again: a click or a cough.
                phase = .idle
                levelsInTurn = []
                events.append(.blipIgnored(at: start))
            }
        case .speaking:
            if voiced {
                if time - lastVoice > 0.2 + duration { startRun(at: chunkStart) }
                lastVoice = time
            }
        }

        if case .speaking(let start) = phase {
            levelsInTurn.append(decibels)
            events.append(.level(Self.waveformLevel(decibels, floor: noiseFloorDecibels ?? -70)))
            if let boundary = endIfDue(turnStart: start) { events.append(.turnEnded(boundary)) }
        } else if case .candidate = phase {
            levelsInTurn.append(decibels)
        }
        return events
    }

    private mutating func startRun(at start: Double) { lastRunStart = start }

    private mutating func confirmIfLongEnough() -> [TurnDetectorEvent] {
        guard case .candidate(let start, let voiced, _) = phase, voiced >= settings.minimumSpeechSeconds - 0.0001 else { return [] }
        phase = .speaking(start: start)
        return [.speechStarted(at: start)]
    }

    /// The floor follows the room down quickly and up slowly (over about ten seconds), so a
    /// burst of speech hardly moves it but a fan turned on is learnt.
    private mutating func learnNoiseFloor(_ decibels: Double, duration: Double) {
        guard let floor = noiseFloorDecibels else { noiseFloorDecibels = decibels; return }
        let rate = decibels < floor ? min(1, duration / 0.3) : min(1, duration / 10)
        noiseFloorDecibels = floor + (decibels - floor) * rate
    }

    private mutating func endIfDue(turnStart: Double) -> TurnBoundary? {
        let quiet = time - lastVoice
        if quiet >= settings.endSilenceSeconds {
            return finish(turnStart: turnStart, reason: .silence, audioEnd: lastVoice + settings.trailingSilenceKeptSeconds)
        }
        if quiet >= settings.doneSilenceSeconds, endsWithDone(turnTranscript(turnStart: turnStart)) {
            // Cut the audio where the word "done" began, when the last stretch of sound is
            // short enough to be that one word; otherwise keep it all.
            let lastRunLength = lastVoice - lastRunStart
            let end = lastRunLength < 1.2 && lastRunStart > turnStart ? lastRunStart : lastVoice + settings.trailingSilenceKeptSeconds
            return finish(turnStart: turnStart, reason: .saidDone, audioEnd: end)
        }
        if time - turnStart >= settings.maxTurnSeconds {
            return finish(turnStart: turnStart, reason: .maxLength, audioEnd: time)
        }
        return nil
    }

    private mutating func finish(turnStart: Double, reason: TurnEndReason, audioEnd: Double) -> TurnBoundary {
        var transcript = turnTranscript(turnStart: turnStart)
        if reason == .saidDone { transcript = Self.removingFinalWord(settings.doneWord, from: transcript) }
        if reason == .maxLength, !levelsInTurn.isEmpty {
            // Thirty seconds without a long pause is often a noise that started (a fan, a TV).
            // Learn it, so the next turn is not cut from the same noise.
            let quietest = levelsInTurn.sorted()[levelsInTurn.count / 10]
            if quietest > (noiseFloorDecibels ?? -70) { noiseFloorDecibels = quietest }
        }
        let boundary = TurnBoundary(
            audioStart: max(0, turnStart - settings.preRollSeconds),
            audioEnd: min(max(audioEnd, turnStart), time),
            reason: reason,
            liveTranscript: transcript)
        phase = .idle
        levelsInTurn = []
        // Segments that belong to this turn are done with; later turns start clean.
        let finishedKeys = segmentOrder.filter { belongsToTurn(segments[$0], turnStart: turnStart) }
        for key in finishedKeys { segments[key]?.text = "" }
        return boundary
    }

    // MARK: Live transcripts

    /// The live recogniser updated one segment. `key` names the segment; a later update with the
    /// same key replaces its text. `segmentStart` is where the segment begins in the audio, in
    /// seconds, if the recogniser says (SpeechAnalyzer does; the older recogniser does not).
    public mutating func transcript(key: Int, segmentStart: Double?, text: String) -> [TurnDetectorEvent] {
        if segments[key] == nil { segmentOrder.append(key) }
        segments[key] = Segment(text: text, start: segmentStart, updated: time)
        // Forget segments long past, so memory stays flat over a long conversation.
        if segmentOrder.count > 64 {
            let old = segmentOrder.removeFirst()
            segments[old] = nil
            stopCounts[old] = nil
        }
        var events: [TurnDetectorEvent] = []
        var counts = stopCounts[key] ?? [:]
        let words = Self.words(text)
        for stopWord in settings.stopWords.sorted() {
            let seen = words.filter { $0 == stopWord }.count
            if seen > (counts[stopWord] ?? 0) {
                events.append(.stopHeard(word: stopWord, text: text))
                counts[stopWord] = seen
            }
        }
        stopCounts[key] = counts
        // "done" followed by enough quiet ends the turn now, without waiting for the next chunk.
        if case .speaking(let start) = phase, let boundary = endIfDue(turnStart: start) {
            events.append(.turnEnded(boundary))
        }
        return events
    }

    /// The live transcript of the turn that started at `turnStart`, segments in order.
    private func turnTranscript(turnStart: Double) -> String {
        segmentOrder.compactMap { key -> String? in
            guard let segment = segments[key], belongsToTurn(segment, turnStart: turnStart) else { return nil }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.joined(separator: " ")
    }

    private func belongsToTurn(_ segment: Segment?, turnStart: Double) -> Bool {
        guard let segment else { return false }
        let earliest = turnStart - settings.preRollSeconds - 0.5
        if let start = segment.start { return start >= earliest }
        return segment.updated >= earliest
    }

    private func endsWithDone(_ text: String) -> Bool {
        Self.words(text).last == settings.doneWord
    }

    // MARK: Text helpers

    /// Lower-case words, punctuation dropped: "Stop, please." is ["stop", "please"].
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
    }

    /// Takes a final `word` off `text`, with the punctuation around it:
    /// "Message Mum, done." becomes "Message Mum".
    public static func removingFinalWord(_ word: String, from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, !last.isLetter, !last.isNumber { trimmed.removeLast() }
        guard trimmed.lowercased().hasSuffix(word.lowercased()) else { return text }
        let before = trimmed.dropLast(word.count)
        // Only a whole word: "abandoned" is not "done".
        if let previous = before.last, previous.isLetter { return text }
        var result = String(before)
        while let last = result.last, last.isWhitespace || ",;:-.".contains(last) { result.removeLast() }
        return result
    }

    /// 0 at the noise floor, 1 at 40 dB above it.
    static func waveformLevel(_ decibels: Double, floor: Double) -> Double {
        min(1, max(0, (decibels - floor) / 40))
    }
}
