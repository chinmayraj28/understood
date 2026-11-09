import Foundation
import HFCore

/// The numbers for one group of clips (one setup, optionally one speaker or one prompt kind).
public struct EvaluationSummary: Codable, Sendable, Equatable {
    public var setup: String
    /// "all", "speaker F01", "seen", "unseen", "word", "sentence", "dysarthric", "control".
    public var scope: String
    public var clips: Int
    /// Word error rate of each recogniser's raw transcript (a failed recogniser counts as empty).
    public var hearerWER: [String: Double]
    /// How many times each recogniser failed or timed out.
    public var hearerFailures: [String: Int]
    /// Word error rate of the final reading.
    public var finalWER: Double
    /// Share of clips whose final reading equals the prompt after normalising: the "meaning" proxy.
    public var exactMatchRate: Double
    /// Share of clips where the layer acted without asking and the acted text was wrong.
    /// This is the number that must stay near zero.
    public var wrongActionRate: Double
    /// Share of clips acted on without asking, correctly.
    public var correctActionRate: Double
    /// Share of clips where a question was asked first (confirm, choose or ask again).
    public var askRate: Double
    public var cannotHearRate: Double
    /// Clips cut off by the runner's time cap (counted inside cannotHearRate too).
    public var timedOut: Int
    public var meanSeconds: Double
    public var p90Seconds: Double
}

/// Scores clip records and writes them as JSON and a Markdown table.
public enum EvaluationReport {
    /// One summary for a group of records.
    public static func summarise(_ records: [ClipRecord], setup: String, scope: String) -> EvaluationSummary {
        var hearerCounts: [HearerName: WordErrorRate.Count] = [:]
        var failures: [String: Int] = [:]
        var final = WordErrorRate.Count.zero
        var exact = 0, wrong = 0, correct = 0, asked = 0, cannot = 0
        for record in records {
            for hypothesis in record.hypotheses {
                hearerCounts[hypothesis.hearer, default: .zero] =
                    hearerCounts[hypothesis.hearer, default: .zero]
                    + WordErrorRate.count(reference: record.prompt, hypothesis: hypothesis.text)
                if hypothesis.failure != nil { failures[hypothesis.hearer.rawValue, default: 0] += 1 }
            }
            final = final + WordErrorRate.count(reference: record.prompt, hypothesis: record.finalText)
            let matches = WordErrorRate.matches(record.finalText, record.prompt)
            if matches { exact += 1 }
            switch record.decision {
            case "act": if matches { correct += 1 } else { wrong += 1 }
            case "confirm", "choose", "askAgain": asked += 1
            default: cannot += 1
            }
        }
        let n = Double(max(records.count, 1))
        let seconds = records.map(\.seconds).sorted()
        return EvaluationSummary(
            setup: setup, scope: scope, clips: records.count,
            hearerWER: Dictionary(uniqueKeysWithValues: hearerCounts.map { ($0.key.rawValue, $0.value.rate) }),
            hearerFailures: failures,
            finalWER: final.rate,
            exactMatchRate: Double(exact) / n,
            wrongActionRate: Double(wrong) / n,
            correctActionRate: Double(correct) / n,
            askRate: Double(asked) / n,
            cannotHearRate: Double(cannot) / n,
            timedOut: records.filter { $0.timedOut == true }.count,
            meanSeconds: seconds.isEmpty ? 0 : seconds.reduce(0, +) / Double(seconds.count),
            p90Seconds: percentile(seconds, 0.9))
    }

    /// Every summary: per setup overall, then by seen/unseen prompt, kind, group and speaker.
    public static func summaries(_ records: [ClipRecord], setups: [String], manifest: EvaluationManifest) -> [EvaluationSummary] {
        var result: [EvaluationSummary] = []
        let speakers = Array(Set(records.map(\.speaker))).sorted()
        for setup in setups {
            let mine = records.filter { $0.setup == setup }
            result.append(summarise(mine, setup: setup, scope: "all"))
            let groups: [(String, (ClipRecord) -> Bool)] = [
                ("seen", { $0.promptSeen }),
                ("unseen", { !$0.promptSeen }),
                ("word", { $0.kind == "word" }),
                ("sentence", { $0.kind == "sentence" }),
                ("dysarthric", { manifest.speaker($0.speaker)?.group == "dysarthric" }),
                ("control", { manifest.speaker($0.speaker)?.group == "control" }),
            ]
            for (scope, keep) in groups {
                let subset = mine.filter(keep)
                if !subset.isEmpty { result.append(summarise(subset, setup: setup, scope: scope)) }
            }
            for speaker in speakers {
                let subset = mine.filter { $0.speaker == speaker }
                if !subset.isEmpty { result.append(summarise(subset, setup: setup, scope: "speaker \(speaker)")) }
            }
        }
        return result
    }

    /// The full result file: when, on what, the split rule, every summary and every clip.
    public struct File: Codable, Sendable {
        public var date: String
        public var manifest: String
        public var splitRule: String
        public var setups: [String: String]
        public var summaries: [EvaluationSummary]
        public var records: [ClipRecord]
    }

    /// Writes `results.json` and `results.md` into `folder`.
    public static func write(
        records: [ClipRecord], setups: [EvaluationSetup], manifest: EvaluationManifest,
        manifestName: String, folder: URL, date: Date = Date()
    ) throws -> (json: URL, markdown: URL) {
        let summaries = summaries(records, setups: setups.map(\.name), manifest: manifest)
        let dateText = ISO8601DateFormatter().string(from: date)
        let file = File(
            date: dateText, manifest: manifestName, splitRule: manifest.splitRule,
            setups: Dictionary(uniqueKeysWithValues: setups.map { ($0.name, $0.summary) }),
            summaries: summaries, records: records)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = folder.appendingPathComponent("results.json")
        try encoder.encode(file).write(to: json, options: .atomic)
        let markdown = folder.appendingPathComponent("results.md")
        try self.markdown(file: file, setups: setups, manifest: manifest).write(to: markdown, atomically: true, encoding: .utf8)
        return (json, markdown)
    }

    /// The report as Markdown tables.
    public static func markdown(file: File, setups: [EvaluationSetup], manifest: EvaluationManifest) -> String {
        func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        func sec(_ value: Double) -> String { String(format: "%.1f", value) }
        func hearer(_ s: EvaluationSummary, _ h: HearerName) -> String { s.hearerWER[h.rawValue].map(pct) ?? "–" }
        let header = "| Setup | Clips | Scribe WER | Gemini WER | Apple WER | Final WER | Exact match | Wrong action | Correct action | Asked | Mean s | p90 s |\n|---|---|---|---|---|---|---|---|---|---|---|---|"
        func row(_ s: EvaluationSummary) -> String {
            "| \(s.setup) | \(s.clips) | \(hearer(s, .scribe)) | \(hearer(s, .gemini)) | \(hearer(s, .apple)) | \(pct(s.finalWER)) | \(pct(s.exactMatchRate)) | \(pct(s.wrongActionRate)) | \(pct(s.correctActionRate)) | \(pct(s.askRate)) | \(sec(s.meanSeconds)) | \(sec(s.p90Seconds)) |"
        }
        func table(_ scope: String) -> String {
            let rows = file.summaries.filter { $0.scope == scope }.map(row)
            return rows.isEmpty ? "_No clips._\n" : ([header] + rows).joined(separator: "\n") + "\n"
        }
        var out = "# Evaluation results\n\nRun \(file.date) on `\(file.manifest)`.\n\n"
        out += "WER is word error rate (lower is better). Exact match is the share of clips whose final reading equals the prompt after normalising. Wrong action is the share acted on without asking whose text was wrong (must be near zero). Asked is the share where a question would be asked first.\n\n"
        out += "**Split rule.** \(file.splitRule)\n\n## Setups\n\n"
        for setup in setups { out += "- **\(setup.name)**: \(setup.summary)\n" }
        out += "\n## All test clips\n\n" + table("all")
        out += "\n## Prompt seen in enrolment (repeated everyday phrase)\n\n" + table("seen")
        out += "\n## Prompt not seen in enrolment\n\n" + table("unseen")
        out += "\n## Dysarthric speakers only\n\n" + table("dysarthric")
        out += "\n## Control speakers only\n\n" + table("control")
        out += "\n## Single words\n\n" + table("word")
        out += "\n## Sentences\n\n" + table("sentence")
        out += "\n## By speaker (final WER / exact match / wrong action)\n\n"
        let speakerScopes = Array(Set(file.summaries.map(\.scope).filter { $0.hasPrefix("speaker ") })).sorted()
        out += "| Speaker | Severity | " + setups.map(\.name).joined(separator: " | ") + " |\n"
        out += "|---|---|" + setups.map { _ in "---|" }.joined() + "\n"
        for scope in speakerScopes {
            let id = String(scope.dropFirst("speaker ".count))
            let severity = manifest.speaker(id)?.severity ?? "?"
            let cells = setups.map { setup -> String in
                guard let s = file.summaries.first(where: { $0.setup == setup.name && $0.scope == scope }) else { return "–" }
                return "\(pct(s.finalWER)) / \(pct(s.exactMatchRate)) / \(pct(s.wrongActionRate)) (n=\(s.clips))"
            }
            out += "| \(id) | \(severity) | " + cells.joined(separator: " | ") + " |\n"
        }
        return out
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(index, sorted.count - 1)]
    }
}
