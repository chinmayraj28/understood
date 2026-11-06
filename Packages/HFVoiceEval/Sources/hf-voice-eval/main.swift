import Foundation
import HFCore
import HFVoice

// hf-voice-eval: how does the voice agent behave? Text mode only; no microphone, no sound.
//
//   swift run hf-voice-eval models
//       the models ElevenLabs offers agents on this account
//   swift run hf-voice-eval run --model claude-sonnet-5-5 [options]
//       update the EVALUATION agent (never the user's) and run the labelled conversations
//
// Options for run:
//   --model NAME            the LLM (default claude-haiku-5-5)
//   --reasoning EFFORT      none | minimal | low | ... (default none; "default" sends nothing)
//   --prompt PATH           the prompt to try (default docs/prompts/voice_agent.md)
//   --skip-turn             turn on ElevenLabs' built-in skip_turn (silence for a turn)
//   --pre-tool-speech MODE  off | auto | force (default off, as the app)
//   --max-tokens N          the reply limit (default the app's)
//   --only id,id            run only these cases; --category NAME only this category
//   --label TEXT            a name for the saved results
//
// Results: a summary here, and every transcript under build/eval/ (git-ignored). The cases are
// synthetic sentences, never the user's own speech.

setvbuf(stdout, nil, _IOLBF, 0)

struct Arguments {
    var command = ""
    var values: [String: String] = [:]
    var flags: Set<String> = []
    init(_ list: [String]) {
        var iterator = list.makeIterator()
        command = iterator.next() ?? ""
        while let item = iterator.next() {
            guard item.hasPrefix("--") else { continue }
            let key = String(item.dropFirst(2))
            if ["skip-turn"].contains(key) { flags.insert(key) } else { values[key] = iterator.next() ?? "" }
        }
    }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

func repoRoot() -> URL {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("docs/prompts/voice_agent.md").path) { return directory }
        directory.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
func format(_ value: Double?) -> String { value.map { String(format: "%.2fs", $0) } ?? "n/a" }

@MainActor
func listModels() async -> Int32 {
    let settings = Settings.load()
    var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/convai/llm/list")!)
    request.setValue(settings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        let listing = try JSONDecoder().decode(JSONValue.self, from: data)
        let models = listing["llms"]?.arrayValue ?? listing.arrayValue ?? []
        for model in models {
            let name = model["llm"]?.stringValue ?? model["name"]?.stringValue ?? "\(model)"
            let deprecated = model["is_deprecated"]?.boolValue == true ? "  (deprecated)" : ""
            let reasoning = model["supports_reasoning"]?.boolValue == true ? "  reasoning" : ""
            print("\(name)\(reasoning)\(deprecated)")
        }
        if models.isEmpty { print(String(decoding: data.prefix(2000), as: UTF8.self)) }
        return 0
    } catch {
        print("Could not list models: \(error)")
        return 1
    }
}

@MainActor
func runEvaluation() async -> Int32 {
    var settings = Settings.load()
    guard !settings.elevenLabsAPIKey.isEmpty else { print("ELEVENLABS_API_KEY is not set."); return 1 }
    let root = repoRoot()
    let promptURL = arguments.values["prompt"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("docs/prompts/voice_agent.md")
    guard let prompt = try? String(contentsOf: promptURL, encoding: .utf8) else { print("Cannot read \(promptURL.path)"); return 1 }
    let casesURL = root.appendingPathComponent("Packages/HFVoiceEval/Cases/cases.json")
    var cases: [EvalCase]
    do { cases = try loadCases(from: casesURL) } catch { print("Cannot read the cases: \(error)"); return 1 }
    if let only = arguments.values["only"] {
        let wanted = Set(only.split(separator: ",").map(String.init))
        cases = cases.filter { wanted.contains($0.id) }
    }
    if let category = arguments.values["category"] { cases = cases.filter { $0.category == category } }

    let reasoning = arguments.values["reasoning"] ?? "none"
    let variant = EvalAgent.Variant(
        model: arguments.values["model"] ?? "claude-haiku-5-5",
        reasoningEffort: reasoning == "default" ? nil : reasoning,
        prompt: prompt,
        skipTurn: arguments.flags.contains("skip-turn"),
        preToolSpeech: arguments.values["pre-tool-speech"] ?? "off",
        maxTokens: arguments.values["max-tokens"].flatMap(Int.init))
    print("model \(variant.model), reasoning \(reasoning), skip_turn \(variant.skipTurn), pre_tool_speech \(variant.preToolSpeech), \(cases.count) cases, prompt \(promptURL.lastPathComponent)")

    let agentID: String
    do {
        agentID = try await EvalAgent.prepare(variant, tools: Harness.definitions(), settings: settings)
    } catch {
        print("Could not prepare the evaluation agent: \(error)")
        return 1
    }
    print("evaluation agent ready (the user's agent unchanged)")
    settings.elevenLabsAgentID = agentID
    var configuration = AgentConfiguration(prompt: prompt)
    configuration.name = EvalAgent.name
    configuration.llm = variant.model
    let harness = Harness(settings: settings, configuration: configuration, quiet: 2.5, longest: 20)

    var results: [CaseResult] = []
    for testCase in cases {
        let result = await harness.run(testCase)
        results.append(result)
        let mark = result.passed ? "PASS" : "FAIL"
        print("\(mark) \(testCase.id) [\(testCase.category)]")
        for event in result.events where event.text != "connected" {
            print(String(format: "      %5.2f %@: %@", event.at, event.kind, event.text))
        }
        for failure in result.failures { print("      ✗ \(failure)") }
    }

    // Summary.
    let passed = results.filter(\.passed).count
    print("---")
    print("\(passed)/\(results.count) passed with \(variant.model)")
    var byCategory: [String: (Int, Int)] = [:]
    for result in results {
        var entry = byCategory[result.category] ?? (0, 0)
        entry.1 += 1
        if result.passed { entry.0 += 1 }
        byCategory[result.category] = entry
    }
    for (category, entry) in byCategory.sorted(by: { $0.key < $1.key }) { print("  \(category): \(entry.0)/\(entry.1)") }
    let timings = results.flatMap(\.timings)
    print("time to tool call: median \(format(median(timings.compactMap(\.toolCall)))) over \(timings.compactMap(\.toolCall).count) turns")
    print("time to first words: median \(format(median(timings.compactMap(\.firstWords)))) over \(timings.compactMap(\.firstWords).count) turns")
    let onIt = results.flatMap(\.replies).filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("on it") }.count
    print("replies starting \"On it\": \(onIt) of \(results.flatMap(\.replies).count)")

    // Save.
    let folder = root.appendingPathComponent("build/eval")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let label = arguments.values["label"].map { "-\($0)" } ?? ""
    let file = folder.appendingPathComponent("\(stamp)-\(variant.model)\(label).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(results).write(to: file)
    print("saved \(file.path)")
    return 0
}

/// What the server kept on the evaluation agent: model, built-in tools, tool count.
@MainActor
func inspect() async -> Int32 {
    let settings = Settings.load()
    guard let id = EvalAgent.storedID() else { print("No evaluation agent yet."); return 1 }
    do {
        let agent = try await ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey).agent(id: id)
        let prompt = agent["conversation_config"]?["agent"]?["prompt"]
        print("name: \(agent["name"]?.stringValue ?? "?")")
        print("llm: \(prompt?["llm"]?.stringValue ?? "?"), reasoning: \(prompt?["reasoning_effort"]?.stringValue ?? "null")")
        let builtIns = prompt?["built_in_tools"]?.objectValue ?? [:]
        for (name, value) in builtIns.sorted(by: { $0.key < $1.key }) where value != .null { print("built-in on: \(name) = \(value)") }
        print("tools: \((prompt?["tools"]?.arrayValue ?? []).count), tool_ids: \((prompt?["tool_ids"]?.arrayValue ?? []).count)")
        let preSpeech = Set((prompt?["tools"]?.arrayValue ?? []).compactMap { $0["pre_tool_speech"]?.stringValue })
        print("pre_tool_speech: \(preSpeech.sorted())")
        return 0
    } catch {
        print("Could not read the evaluation agent: \(error)")
        return 1
    }
}

/// Sends a small JSON body as a PATCH to the evaluation agent and prints the reply. For finding
/// out how the API wants a setting (`--body '{"conversation_config": ...}'`).
@MainActor
func patchProbe() async -> Int32 {
    let settings = Settings.load()
    guard let id = EvalAgent.storedID(), let body = arguments.values["body"] else { print("need --body and an evaluation agent"); return 1 }
    do { try EvalAgent.refuseIfShared(id, settings: settings) } catch { print("\(error)"); return 1 }
    var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(id)")!)
    request.httpMethod = "PATCH"
    request.setValue(settings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? JSONDecoder().decode(JSONValue.self, from: data)
        let builtIns = reply?["conversation_config"]?["agent"]?["prompt"]?["built_in_tools"]
        print("status \(status); built_in_tools in reply: \(builtIns.map { "\($0)" } ?? String(decoding: data.prefix(600), as: UTF8.self))")
        return 0
    } catch {
        print("\(error)")
        return 1
    }
}

/// The evaluation agent's latest conversations as ElevenLabs recorded them, including system
/// tools such as skip_turn that the client never sees. Synthetic test sentences only.
@MainActor
func lastConversations() async -> Int32 {
    let settings = Settings.load()
    guard let id = EvalAgent.storedID() else { print("No evaluation agent yet."); return 1 }
    func get(_ path: String) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io\(path)")!)
        request.setValue(settings.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    do {
        let count = Int(arguments.values["count"] ?? "3") ?? 3
        let listing = try await get("/v1/convai/conversations?agent_id=\(id)&page_size=\(count)")
        for conversation in (listing["conversations"]?.arrayValue ?? []).reversed() {
            guard let conversationID = conversation["conversation_id"]?.stringValue else { continue }
            let detail = try await get("/v1/convai/conversations/\(conversationID)")
            print("=== \(conversationID)")
            for turn in detail["transcript"]?.arrayValue ?? [] {
                let tools = (turn["tool_calls"]?.arrayValue ?? []).compactMap { $0["tool_name"]?.stringValue }
                let message = turn["message"]?.stringValue ?? ""
                print("  \(turn["role"]?.stringValue ?? "?"): \(message.prefix(100))\(tools.isEmpty ? "" : "  [calls: \(tools.joined(separator: ", "))]")")
            }
        }
        return 0
    } catch {
        print("Could not read conversations: \(error)")
        return 1
    }
}

let status: Int32
switch arguments.command {
case "last": status = await lastConversations()
case "patch": status = await patchProbe()
case "inspect": status = await inspect()
case "models": status = await listModels()
case "run": status = await runEvaluation()
default:
    print("usage: hf-voice-eval models | run --model NAME [--skip-turn] [--only ids] (see main.swift)")
    status = 2
}
exit(status)
