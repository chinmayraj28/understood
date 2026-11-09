import Foundation
import HFCore
import HFUnderstand

// hf-understand: runs the understanding layer on audio files, with no app and no permissions.
// Keys come from .env through Settings.load() and are never printed.
//
//   hf-understand manifest <torgo-raw-dir> --out <manifest.json>
//   hf-understand hear <file.wav> [--keyterms "a,b,c"]
//   hf-understand eval <manifest.json> [--setups a,b] [--limit N] [--enrol-limit N]
//                       [--speakers F01,M02] [--out dir]
//
// See eval/README.md.

let usage = """
    hf-understand: understanding impaired speech, from audio files.

      manifest <torgo-raw-dir> --out <manifest.json>
          Build an evaluation manifest from extracted TORGO folders (eval/scripts/fetch_torgo.sh does this).
      hear <file.wav> [--keyterms "word,word"]
          Run each recogniser, then the full pipeline, on one file and print every stage.
      eval <manifest.json> [--setups name,name] [--limit N] [--enrol-limit N] [--speakers id,id] [--out dir]
          Run the evaluation. Setups: \(Setups.names.joined(separator: ", ")) (default: all).
          --limit caps test clips (spread across speakers), --enrol-limit caps enrolment clips per speaker.
    """

/// Plain argument parsing: positional values, and "--name value" options.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[key] = raw[index + 1]
                    index += 2
                } else {
                    options[key] = ""
                    index += 1
                }
            } else {
                positional.append(item)
                index += 1
            }
        }
    }

    func int(_ key: String) -> Int? { options[key].flatMap(Int.init) }
    func list(_ key: String) -> [String]? {
        options[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func absoluteURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

// MARK: - manifest

func runManifest(_ args: Arguments) throws {
    guard let rootPath = args.positional.first else { fail(usage) }
    let out = absoluteURL(args.options["out"] ?? "manifest.json")
    let manifest = try TorgoManifestBuilder.build(root: absoluteURL(rootPath), manifestFolder: out.deletingLastPathComponent())
    try manifest.write(to: out)
    print("Wrote \(out.path)")
    for speaker in manifest.speakers {
        let enrol = manifest.clips(of: speaker.id, split: .enrolment).count
        let test = manifest.clips(of: speaker.id, split: .test).count
        print("  \(speaker.id) (\(speaker.group), \(speaker.severity ?? "severity unknown")): \(enrol) enrolment, \(test) test clips")
    }
}

// MARK: - hear

func runHear(_ args: Arguments) async throws {
    guard let path = args.positional.first else { fail(usage) }
    let settings = Settings.load()
    let turn = try WAV.load(contentsOf: absoluteURL(path))
    let hints = HearingHints(keyterms: args.list("keyterms") ?? [])
    print("\(turn.source): \(String(format: "%.1f", turn.durationSeconds)) s")
    let hearers: [any Hearing] = [
        ScribeHearer(apiKey: settings.elevenLabsAPIKey),
        GeminiHearer(apiKey: settings.openRouterAPIKey),
        AppleHearer(),
    ]
    for hearer in hearers {
        let start = Date()
        do {
            let text = try await hearer.hear(turn, hints: hints)
            print("  \(hearer.name.rawValue): \"\(text)\" (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
        } catch {
            print("  \(hearer.name.rawValue): failed: \(error)")
        }
    }
    if let full = Setups.fullPipeline(settings: settings, keyterms: hints.keyterms) {
        let result = await full.understand(turn, context: UnderstandingContext())
        print("  full pipeline: \(Setups.describe(result))")
    }
}

// MARK: - main

let args = Arguments(Array(CommandLine.arguments.dropFirst(2)))
let command = CommandLine.arguments.dropFirst().first ?? ""
do {
    switch command {
    case "manifest": try runManifest(args)
    case "hear": try await runHear(args)
    case "eval": try await runEval(args)
    default: print(usage)
    }
} catch {
    fail("hf-understand: \(error)")
}
