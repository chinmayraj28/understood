import Foundation

/// How the understanding layer runs. Each `use…` switch turns one stage off cleanly, so the
/// evaluation can measure what each stage adds (Scribe alone, then + keyterms, + examples,
/// + repair, + phrasebook).
public struct UnderstanderConfiguration: Sendable, Equatable {
    /// A recogniser slower than this counts as failed for this turn; the others go on.
    public var hearerTimeoutSeconds: Double = 4
    /// The repair call is abandoned after this, and the decider works without a reading.
    public var repairTimeoutSeconds: Double = 3
    /// Give recognisers likely words: the phrasebook's phrases, `extraKeyterms`, the screen
    /// labels and the expected answers.
    public var useKeyterms = true
    /// Give recognisers that learn from examples a few of this person's own clips.
    public var useExamples = true
    /// Ask the language model for a reading when the evidence alone is not enough.
    public var useRepair = true
    /// Look the transcripts up in the phrasebook.
    public var usePhrasebook = true
    /// Words from the app: contact names, app names. Put after the phrasebook's own phrases.
    public var extraKeyterms: [String] = []
    /// How many of this person's clips a recogniser is shown.
    public var exampleCount = 4
    /// At most this many keyterms are sent. Scribe takes up to 1,000; fewer keeps requests small.
    public var keytermLimit = 100
    /// BCP-47 language, such as "en-GB".
    public var languageCode = "en-GB"
    /// Post a short "working it out" caption to the companion while the slow path runs.
    /// The evaluation turns this off.
    public var postsActivity = true

    public init() {}
}
