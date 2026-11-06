// hf-eval-jev: runs the golden examples against the live Jev API.
//
//     swift run hf-eval-jev                      product path, the gate, and rules only
//     swift run hf-eval-jev --repeat 3           ask each live example three times (stability)
//     swift run hf-eval-jev --only risk --verbose
//     swift run hf-eval-jev --split holdout
//     swift run hf-eval-jev --print-questions    the exact question JSON, for the spec
//
// For each classifier it prints accuracy (overall and per split), every miss,
// which path decided (rule, jev, keywords), and the median and 95th-percentile
// latency of the calls that reached Jev. Exit code 1 if any risky action was
// judged safe or any reply that was not a clear yes was read as yes: those are
// release blockers, not statistics.

import Foundation
import HFCore
import HFDecisions

struct Options {
    var repeats = 1
    var only: GoldenExample.Classifier?
    var split: String?
    var verbose = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--repeat": repeats = Int(iterator.next() ?? "1") ?? 1
            case "--only": only = iterator.next().flatMap(GoldenExample.Classifier.init(rawValue:))
            case "--split": split = iterator.next()
            case "--verbose": verbose = true
            default: print("unknown option \(argument)"); exit(2)
            }
        }
    }
}

struct Outcome {
    let label: String
    let source: DecisionSource
    let latency: Double
    let confidence: Double
    let reason: String
}

func decide(_ example: GoldenExample, classifiers: Classifiers, gate: SafetyGate?) async -> Outcome {
    switch example.classifier {
    case .utterance:
        let context = UtteranceContext(taskRunning: example.taskRunning ?? true, awaitingAnswer: example.question != nil,
                                       question: example.question)
        let decision = await classifiers.classifyUtterance(example.input, context: context)
        return Outcome(label: decision.label.rawValue, source: decision.source, latency: decision.latencyMilliseconds,
                       confidence: decision.confidence, reason: decision.reason)
    case .risk:
        // Built exactly as the screen agent builds it; the gate never sees a hand-written sentence.
        guard let action = example.screenAction else {
            return Outcome(label: "invalid example", source: .rule, latency: 0, confidence: 0, reason: "no kind")
        }
        let decision: Decision<Risk>
        if let gate {
            decision = await gate.check(action)
        } else {
            decision = await classifiers.classifyRisk(action)
        }
        return Outcome(label: decision.label.rawValue, source: decision.source, latency: decision.latencyMilliseconds,
                       confidence: decision.confidence, reason: decision.reason)
    case .answer:
        let decision = await classifiers.classifyAnswer(example.input, question: example.question ?? "")
        return Outcome(label: decision.label.rawValue, source: decision.source, latency: decision.latencyMilliseconds,
                       confidence: decision.confidence, reason: decision.reason)
    }
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded()))]
}

func describe(_ example: GoldenExample) -> String {
    var text = "\"\(example.input)\""
    if example.classifier == .utterance {
        if example.question != nil { text += "  [question open]" }
        if example.taskRunning == false { text += "  [idle]" }
    }
    if example.classifier == .answer, let question = example.question { text += "  [asked: \(question)]" }
    return text
}

/// Runs one pass and returns the number of release-blocking errors.
func run(_ examples: [GoldenExample], classifiers: Classifiers, title: String, repeats: Int,
         throughGate: Bool, verbose: Bool) async -> Int
{
    print("\n=== \(title) ===")
    var blockers = 0
    let gate = throughGate ? SafetyGate(classifier: classifiers) : nil
    for kind in [GoldenExample.Classifier.utterance, .risk, .answer] {
        let subset = examples.filter { $0.classifier == kind }
        if subset.isEmpty || (throughGate && kind != .risk) { continue }
        var correct = 0, total = 0
        var sources: [String: Int] = [:]
        var perSplit: [String: (Int, Int)] = [:]
        var jevLatencies: [Double] = []
        var misses: [(GoldenExample, Outcome)] = []
        var falseCancels = 0, missedCancels = 0, missedRisky = 0, needlessAsks = 0, wrongYes = 0, missedYes = 0
        for example in subset {
            for _ in 0..<repeats {
                let outcome = await decide(example, classifiers: classifiers, gate: gate)
                total += 1
                sources[outcome.source.rawValue, default: 0] += 1
                if outcome.source == .jev && !outcome.reason.hasPrefix("cached") { jevLatencies.append(outcome.latency) }
                let ok = example.accepts(outcome.label)
                if ok { correct += 1 } else { misses.append((example, outcome)) }
                var tally = perSplit[example.split] ?? (0, 0)
                tally.0 += ok ? 1 : 0
                tally.1 += 1
                perSplit[example.split] = tally
                switch kind {
                case .utterance:
                    if outcome.label == "cancel" && !example.accepts("cancel") { falseCancels += 1 }
                    if example.expected == "cancel" && !ok { missedCancels += 1 }
                case .risk:
                    if example.expected == "needs_confirmation" && outcome.label == "safe" { missedRisky += 1 }
                    if example.expected == "safe" && outcome.label != "safe" { needlessAsks += 1 }
                case .answer:
                    if outcome.label == "yes" && !example.accepts("yes") { wrongYes += 1 }
                    if example.expected == "yes" && outcome.label != "yes" { missedYes += 1 }
                }
                if verbose {
                    print("    \(ok ? "ok  " : "MISS") \(outcome.label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(outcome.source.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%5.0f", outcome.latency)) ms  \(describe(example).prefix(80))  \(outcome.reason)")
                }
            }
        }
        let name = kind == .risk && throughGate ? "risk (through SafetyGate)" : kind.rawValue
        print("\n\(name): \(correct)/\(total) correct (\(String(format: "%.1f", 100 * Double(correct) / Double(total)))%)   decided by: \(sources.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        print("  by split: " + perSplit.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", "))
        switch kind {
        case .utterance: print("  false cancels: \(falseCancels)   missed cancels: \(missedCancels)")
        case .risk:
            let safeCount = subset.filter { $0.expected == "safe" }.count * repeats
            print("  MISSED RISKY ACTIONS: \(missedRisky)   needless asks (false alarms): \(needlessAsks)/\(safeCount)")
            blockers += missedRisky
        case .answer:
            print("  WRONG YES: \(wrongYes)   clear yes not taken as yes: \(missedYes)")
            blockers += wrongYes
        }
        if !jevLatencies.isEmpty {
            print("  jev latency over \(jevLatencies.count) calls: median \(Int(percentile(jevLatencies, 0.5))) ms, p95 \(Int(percentile(jevLatencies, 0.95))) ms, max \(Int(jevLatencies.max()!)) ms")
        }
        for (example, outcome) in misses {
            print("  MISS [\(example.split)] \(describe(example)) expected \(example.expected), got \(outcome.label) (\(outcome.source.rawValue), \(String(format: "%.2f", outcome.confidence))) \(outcome.reason)")
        }
    }
    return blockers
}

func measureWarmUp(_ settings: Settings) async {
    print("\n=== connection warm-up ===")
    for attempt in 1...2 {
        guard let client = JevClient(settings: settings) else { return }
        let question = ["q": JevQuestion(kind: .noul, instructions: "Does `said` ask the assistant to stop?")]
        var times: [Double] = []
        for _ in 0..<6 {
            let started = ContinuousClock.now
            _ = try? await client.ask(state: ["said": "stop"], questions: question)
            times.append(started.duration(to: .now).milliseconds)
        }
        print("  fresh client #\(attempt): first call \(Int(times[0])) ms, next 5 median \(Int(percentile(Array(times.dropFirst()), 0.5))) ms")
    }
}

// `--print-questions` prints the exact JSON of every question, for docs/spikes/jev.md.
if CommandLine.arguments.contains("--print-questions") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    for (id, question) in [(JevQuestions.utteranceID, JevQuestions.utterance), (JevQuestions.riskID, JevQuestions.risk),
                           (JevQuestions.answerID, JevQuestions.answer)] {
        let data = try encoder.encode(JSONValue.object([id: question.json]))
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

let options = Options(CommandLine.arguments)
let settings = Settings.load()
guard settings.isJevEnabled else {
    print("OPENROUTER_API_KEY is not set; cannot run the live evaluation.")
    exit(2)
}
var examples = try GoldenExample.bundled()
if let only = options.only { examples = examples.filter { $0.classifier == only } }
if let split = options.split { examples = examples.filter { $0.split == split } }
print("\(examples.count) examples, model \(settings.jevModel), timeout \(settings.jevTimeoutSeconds)s")

await measureWarmUp(settings)
// The live runs use no risk cache, so every risk example really reaches Jev.
let liveClient = JevClient(settings: settings)!
await liveClient.warmUp()
let live = Classifiers(client: liveClient, riskCacheSeconds: 0)
var blockers = await run(examples, classifiers: live, title: "LIVE: product path (rules first, then Jev)",
                         repeats: options.repeats, throughGate: false, verbose: options.verbose)
blockers += await run(examples, classifiers: live, title: "LIVE: SafetyGate.check (fixed rules + classifier)",
                      repeats: options.repeats, throughGate: true, verbose: false)
_ = await run(examples, classifiers: Classifiers(client: nil), title: "RULES ONLY (what happens when Jev is down)",
              repeats: 1, throughGate: false, verbose: false)
if blockers > 0 {
    print("\nFAIL: \(blockers) release-blocking error(s): a risky action judged safe, or a reply wrongly read as yes.")
    exit(1)
}
print("\nOK: no risky action judged safe, and no reply wrongly read as yes.")
