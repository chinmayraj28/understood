import Foundation
import HFCore
import HFUnderstand

/// The setups `hf-understand eval` compares. Each adds one stage to the one before, so the table
/// shows what each stage is worth. See eval/README.md section 3.
///
/// Every setup is built fresh for each speaker, from that speaker's enrolment clips only.
enum Setups {
    static let names = ["scribe", "keyterms", "gemini", "repair", "phrasebook"]

    static func all(settings: Settings) -> [EvaluationSetup] {
        let scribe = ScribeHearer(apiKey: settings.elevenLabsAPIKey)
        let gemini = GeminiHearer(apiKey: settings.openRouterAPIKey)
        let apple = AppleHearer()
        let repairKey = settings.anthropicAPIKey

        return [
            EvaluationSetup(name: "scribe", summary: "ElevenLabs Scribe alone, no hints; decision code only") { _, _ in
                understander(hearers: [scribe], repair: false, keyterms: [], examples: false, phrasebook: false)
            },
            EvaluationSetup(name: "keyterms", summary: "+ the speaker's enrolment prompts as Scribe keyterms") { _, enrolment in
                understander(hearers: [scribe], repair: false, keyterms: EvaluationRunner.keyterms(from: enrolment),
                             examples: false, phrasebook: false)
            },
            EvaluationSetup(name: "gemini", summary: "+ Gemini Flash hearing the clip, shown the speaker's own enrolment clips") { _, enrolment in
                await enrolled(hearers: [scribe, gemini], repairKey: nil, enrolment: enrolment, usePhrasebook: false)
            },
            EvaluationSetup(name: "repair", summary: "+ Apple on-device as a third vote, and Claude repairing the text") { _, enrolment in
                await enrolled(hearers: [scribe, gemini, apple], repairKey: repairKey, enrolment: enrolment, usePhrasebook: false)
            },
            EvaluationSetup(name: "phrasebook", summary: "+ the phrasebook learned from the speaker's enrolment clips") { _, enrolment in
                await enrolled(hearers: [scribe, gemini, apple], repairKey: repairKey, enrolment: enrolment, usePhrasebook: true)
            },
        ]
    }

    /// One Understander with the given stages switched on and an empty phrasebook.
    static func understander(
        hearers: [any Hearing], repair: Bool, repairKey: String = "", keyterms: [String], examples: Bool,
        phrasebook: Bool, book: Phrasebook? = nil
    ) -> any Understanding {
        var configuration = UnderstanderConfiguration()
        configuration.useKeyterms = !keyterms.isEmpty
        configuration.extraKeyterms = keyterms
        configuration.useExamples = examples
        configuration.useRepair = repair
        configuration.usePhrasebook = phrasebook
        configuration.postsActivity = false
        let model: StructuredLanguageModel? = repair ? AnthropicStructuredModel(apiKey: repairKey) : nil
        // An in-memory phrasebook cannot fail to open; if it ever did, nothing could be measured.
        let store = book ?? (try! Phrasebook.inMemory())
        let settled = configuration
        return FreshEachTurn {
            Understander(hearers: hearers, repairModel: model, phrasebook: store, configuration: settled)
        }
    }

    /// Teaches a fresh phrasebook this speaker the way the app would (each enrolment clip is heard by
    /// the same recognisers, then confirmed with its prompt), then returns the layer to test with.
    /// The enrolment pass never calls Claude and never matches against the phrasebook, so it only
    /// records what the recognisers heard. The stored clips become Gemini's examples.
    static func enrolled(hearers: [any Hearing], repairKey: String?, enrolment: [EnrolmentClip], usePhrasebook: Bool) async -> any Understanding {
        let book = try! Phrasebook.inMemory()
        let keyterms = EvaluationRunner.keyterms(from: enrolment)
        let learner = understander(hearers: hearers, repair: false, keyterms: keyterms, examples: true, phrasebook: false, book: book)
        await EvaluationRunner.enrol(learner, with: enrolment)
        return understander(
            hearers: hearers, repair: repairKey != nil, repairKey: repairKey ?? "", keyterms: keyterms,
            examples: true, phrasebook: usePhrasebook, book: book)
    }

    /// The whole pipeline with an empty phrasebook, for `hf-understand hear`.
    static func fullPipeline(settings: Settings, keyterms: [String]) -> (any Understanding)? {
        understander(
            hearers: [ScribeHearer(apiKey: settings.elevenLabsAPIKey), GeminiHearer(apiKey: settings.openRouterAPIKey), AppleHearer()],
            repair: !settings.anthropicAPIKey.isEmpty, repairKey: settings.anthropicAPIKey,
            keyterms: keyterms, examples: false, phrasebook: true)
    }

    /// Every stage of one result, one per line.
    static func describe(_ result: UnderstandingResult) -> String {
        var lines: [String] = []
        for hypothesis in result.hypotheses {
            let text = hypothesis.failure.map { "failed: \($0)" } ?? "\"\(hypothesis.text)\""
            lines.append("    heard by \(hypothesis.hearer.rawValue): \(text)")
        }
        if let match = result.phrasebookMatch {
            lines.append("    phrasebook: \"\(match.heard)\" meant \"\(match.meant)\" (similarity \(String(format: "%.2f", match.similarity)))")
        }
        if let reading = result.reading {
            lines.append("    reading: \"\(reading.text)\" (\(reading.confidence.rawValue)) \(reading.reason)")
        } else {
            lines.append("    reading: none (repair skipped or off)")
        }
        lines.append("    decision: \(result.decision) after \(String(format: "%.1f", result.seconds)) s")
        return "\n" + lines.joined(separator: "\n")
    }
}

/// Builds a new Understander for every turn, all sharing one phrasebook. The Understander counts
/// failed tries in a row (after two it only asks yes/no questions); in the evaluation each test clip
/// is a separate first try, so that count must not carry from one clip to the next.
struct FreshEachTurn: Understanding {
    let make: @Sendable () -> Understander

    func understand(_ turn: RecordedTurn, context: UnderstandingContext) async -> UnderstandingResult {
        await make().understand(turn, context: context)
    }

    func learn(from turn: RecordedTurn, result: UnderstandingResult, outcome: TurnOutcome) async {
        await make().learn(from: turn, result: result, outcome: outcome)
    }
}
