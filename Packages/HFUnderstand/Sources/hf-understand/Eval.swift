import Foundation
import HFCore
import HFUnderstand

// `hf-understand eval`: runs the chosen setups over a manifest's test clips and writes
// results.json and results.md. See eval/README.md for how to read them.

func runEval(_ args: Arguments) async throws {
    guard let manifestPath = args.positional.first else { fail(usage) }
    let manifestURL = absoluteURL(manifestPath)
    let manifest = try EvaluationManifest.load(from: manifestURL)
    let settings = Settings.load()

    let chosen = args.list("setups") ?? Setups.names
    let unknown = chosen.filter { !Setups.names.contains($0) }
    if !unknown.isEmpty { fail("Unknown setup(s): \(unknown.joined(separator: ", ")). Known: \(Setups.names.joined(separator: ", "))") }
    let setups = Setups.all(settings: settings).filter { chosen.contains($0.name) }
    if setups.isEmpty { fail("No setups to run.") }

    let runner = EvaluationRunner(
        manifest: manifest,
        manifestFolder: manifestURL.deletingLastPathComponent(),
        enrolmentLimit: args.int("enrol-limit") ?? 20,
        clipTimeLimitSeconds: Double(args.options["clip-limit"] ?? "") ?? 30,
        loadTurn: { try WAV.load(contentsOf: $0) },
        log: { print($0) })
    let tests = runner.selectTestClips(limit: args.int("limit"), speakers: args.list("speakers"))
    if tests.isEmpty { fail("No test clips selected.") }

    let speakers = Set(tests.map(\.speaker)).sorted()
    print("Running \(setups.count) setup(s) on \(tests.count) test clips from \(speakers.joined(separator: ", ")).")
    print("Enrolment: up to \(runner.enrolmentLimit.map(String.init) ?? "all") clips per speaker.")

    let started = Date()
    let records = await runner.run(setups: setups, testClips: tests)

    let stamp: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }()
    let folder = absoluteURL(args.options["out"] ?? "eval/results/\(stamp)")
    let out = try EvaluationReport.write(
        records: records, setups: setups, manifest: manifest,
        manifestName: manifestURL.lastPathComponent, folder: folder)

    print("")
    for setup in setups {
        let summary = EvaluationReport.summarise(records.filter { $0.setup == setup.name }, setup: setup.name, scope: "all")
        print(String(
            format: "%-22@ final WER %3.0f%%  exact %3.0f%%  wrong action %3.0f%%  asked %3.0f%%  mean %.1f s",
            setup.name as NSString, summary.finalWER * 100, summary.exactMatchRate * 100,
            summary.wrongActionRate * 100, summary.askRate * 100, summary.meanSeconds))
    }
    print("\nTook \(Int(Date().timeIntervalSince(started))) s. Wrote \(out.markdown.path) and \(out.json.lastPathComponent).")
}
