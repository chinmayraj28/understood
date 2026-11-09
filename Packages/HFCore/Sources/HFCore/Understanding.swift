import Foundation

// The shared types for understanding impaired speech (HFUnderstand).
//
// One turn of speech goes through five stages: record it, hear it with several recognisers,
// repair the text with context, decide in code whether to act or ask, and learn from what the
// person confirmed. These types are what the stages hand each other, and what the app and the
// command-line tool see. See docs/SPEECH_PLAN.md for the reasons behind each stage.

/// One turn of the person's speech, recorded on the Mac.
public struct RecordedTurn: Sendable, Equatable {
    /// The audio as a WAV file: 16 kHz, mono, 16-bit. Every recogniser accepts this.
    public var wav: Data
    /// Seconds of audio.
    public var durationSeconds: Double
    /// What Apple's on-device recogniser heard live while the person spoke, if it ran.
    /// Empty when the turn came from a file.
    public var liveTranscript: String
    /// Where the audio came from, for logs and evaluation ("mic", or a file name).
    public var source: String

    public init(wav: Data, durationSeconds: Double, liveTranscript: String = "", source: String) {
        self.wav = wav
        self.durationSeconds = durationSeconds
        self.liveTranscript = liveTranscript
        self.source = source
    }
}

/// Which recogniser produced a transcript.
public enum HearerName: String, Sendable, Codable, CaseIterable {
    /// ElevenLabs Scribe, batch, with keyterms.
    case scribe
    /// Gemini Flash with audio, shown a few of this person's own clips.
    case gemini
    /// Apple's on-device recogniser (SpeechAnalyzer), with the keyterms as hints.
    case apple
}

/// One of this person's earlier recordings with what they meant. Shown to a recogniser
/// as an example of how this person sounds.
public struct SpeechExample: Sendable, Equatable {
    public var wav: Data
    public var text: String

    public init(wav: Data, text: String) {
        self.wav = wav
        self.text = text
    }
}

/// What a recogniser is told before it listens.
public struct HearingHints: Sendable, Equatable {
    /// Words and short phrases likely in this turn: names, app names, the person's usual
    /// commands, labels on screen. Most likely first; a recogniser may use only the first N.
    public var keyterms: [String]
    /// This person's own clips, for recognisers that can learn from examples. Few (3 to 5).
    public var examples: [SpeechExample]
    /// BCP-47 language, such as "en-GB".
    public var languageCode: String

    public init(keyterms: [String] = [], examples: [SpeechExample] = [], languageCode: String = "en-GB") {
        self.keyterms = keyterms
        self.examples = examples
        self.languageCode = languageCode
    }
}

/// One recogniser's result for one turn.
public struct Hypothesis: Sendable, Equatable, Codable {
    public var hearer: HearerName
    /// The transcript. Empty when the recogniser heard nothing or failed.
    public var text: String
    /// How long the recogniser took.
    public var seconds: Double
    /// Set when the recogniser failed or timed out; the text is then empty.
    public var failure: String?

    public init(hearer: HearerName, text: String, seconds: Double, failure: String? = nil) {
        self.hearer = hearer
        self.text = text
        self.seconds = seconds
        self.failure = failure
    }
}

/// A recogniser: audio in, text out.
public protocol Hearing: Sendable {
    var name: HearerName { get }
    /// Throws a `SpeakableError` on failure. The caller applies the time limit.
    func hear(_ turn: RecordedTurn, hints: HearingHints) async throws -> String
}

/// What is going on around the turn, used to repair it.
public struct UnderstandingContext: Sendable, Equatable {
    /// The app in front, such as "WhatsApp".
    public var frontApp: String
    /// Names of controls on screen, from the accessibility tree (read only).
    public var screenLabels: [String]
    /// The last few turns of the conversation, oldest first, each prefixed "User: " or "Agent: ".
    public var recentTurns: [String]
    /// The question the agent just asked, if the person is answering one.
    public var pendingQuestion: String?
    /// When the question has fixed answers ("yes", "no", or "Mum", "Sam"), they are listed here.
    public var expectedAnswers: [String]

    public init(
        frontApp: String = "",
        screenLabels: [String] = [],
        recentTurns: [String] = [],
        pendingQuestion: String? = nil,
        expectedAnswers: [String] = []
    ) {
        self.frontApp = frontApp
        self.screenLabels = screenLabels
        self.recentTurns = recentTurns
        self.pendingQuestion = pendingQuestion
        self.expectedAnswers = expectedAnswers
    }
}

/// How sure the repair stage is about a reading.
public enum ReadingConfidence: String, Sendable, Codable, Comparable {
    case low, medium, high

    private var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A phrasebook entry that matched what was heard.
public struct PhrasebookMatch: Sendable, Equatable, Codable {
    /// What the person meant when this was heard before.
    public var meant: String
    /// What a recogniser heard that time.
    public var heard: String
    /// 0...1, how close the new transcript is to `heard`.
    public var similarity: Double
    /// How many times this pair was confirmed.
    public var timesConfirmed: Int

    public init(meant: String, heard: String, similarity: Double, timesConfirmed: Int) {
        self.meant = meant
        self.heard = heard
        self.similarity = similarity
        self.timesConfirmed = timesConfirmed
    }
}

/// The best guess at what the person said.
public struct Reading: Sendable, Equatable, Codable {
    public var text: String
    public var confidence: ReadingConfidence
    /// Up to two other likely readings, most likely first.
    public var alternatives: [String]
    /// One short sentence on why, for logs and the evaluation report. Never spoken.
    public var reason: String

    public init(text: String, confidence: ReadingConfidence, alternatives: [String] = [], reason: String = "") {
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
        self.reason = reason
    }
}

/// What to do with a turn. Decided in code from the reading, the agreement between
/// recognisers and the phrasebook, never by a model alone.
public enum UnderstandingDecision: Sendable, Equatable {
    /// Pass the text to the voice agent as the person's turn.
    case act(text: String)
    /// Ask one yes/no question first: "Message Mum?". A yes passes `reading` on.
    case confirm(question: String, reading: String)
    /// Offer choices: "Mum or Sam?".
    case choose(question: String, options: [String])
    /// Ask for one part again: "Say just the name."
    case askAgain(question: String)
    /// Nothing usable was heard, or every recogniser failed. Say `message`.
    case cannotHear(message: String)
}

/// Everything that happened to one turn, for the app, the companion and the evaluation.
public struct UnderstandingResult: Sendable, Equatable {
    public var hypotheses: [Hypothesis]
    public var phrasebookMatch: PhrasebookMatch?
    /// Nil when the repair stage was skipped (fast path) or failed.
    public var reading: Reading?
    public var decision: UnderstandingDecision
    /// Seconds from the end of the turn to the decision.
    public var seconds: Double

    public init(
        hypotheses: [Hypothesis],
        phrasebookMatch: PhrasebookMatch?,
        reading: Reading?,
        decision: UnderstandingDecision,
        seconds: Double
    ) {
        self.hypotheses = hypotheses
        self.phrasebookMatch = phrasebookMatch
        self.reading = reading
        self.decision = decision
        self.seconds = seconds
    }
}

/// How a turn ended, which is what the learning stage needs.
public enum TurnOutcome: Sendable, Equatable {
    /// The person said yes to the reading, or picked it from offered choices. An action that
    /// simply went ahead without being corrected is NOT a confirmation: the person may not be
    /// able to undo or object, and learning from it would turn one mistake into a habit.
    case confirmed(meant: String)
    /// The person corrected it ("no, Sam"); `meant` is the corrected text.
    case corrected(meant: String)
    /// The person said no and gave no correction. Nothing is learned.
    case rejected
}

/// The whole understanding layer, as the app sees it.
public protocol Understanding: Sendable {
    /// Runs every stage on one turn. Never throws: failures become `.cannotHear` or a question.
    func understand(_ turn: RecordedTurn, context: UnderstandingContext) async -> UnderstandingResult
    /// Records how a turn ended so the phrasebook and the examples improve.
    func learn(from turn: RecordedTurn, result: UnderstandingResult, outcome: TurnOutcome) async
}
