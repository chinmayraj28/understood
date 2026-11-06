// hf-voice: try the voice layer on its own, and keep the ElevenLabs agent in step with the code.
//
//   swift run hf-voice setup   create or update the agent; store its id in the repo's .env
//   swift run hf-voice text    a typed conversation with a demo tool
//   swift run hf-voice talk    a spoken conversation with a demo tool (microphone and speakers)
//
// In `text` and `talk`, a line starting with "/push " pushes a pretend task question,
// for example "/push Priya Shah or Priya Patel?", to hear how the agent relays it.
// `text` and `talk` use a separate TEST agent (ELEVENLABS_TEST_AGENT_ID), never the app's own.

import Foundation
import HFCore
import HFVoice

@MainActor
func runSetup() async -> Int32 {
    let settings = Settings.load()
    guard !settings.elevenLabsAPIKey.isEmpty else {
        print("ELEVENLABS_API_KEY is not set in .env.")
        return 1
    }
    let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
    let configuration = AgentConfiguration()
    do {
        // Tools are left out: an update keeps the agent's tools, and the app sets them when it starts.
        let sync = try await api.createOrUpdateAgent(
            definition: configuration.definition(tools: nil), knownAgentID: settings.elevenLabsAgentID)
        print(sync.created ? "Created agent \(sync.agentID)." : "Updated agent \(sync.agentID).")
        if sync.agentID != settings.elevenLabsAgentID {
            guard let envFile = EnvFile.find() else {
                print("No .env found. Add this line to it: ELEVENLABS_AGENT_ID=\(sync.agentID)")
                return 1
            }
            try EnvFile.set("ELEVENLABS_AGENT_ID", to: sync.agentID, in: envFile)
            print("Wrote ELEVENLABS_AGENT_ID to \(envFile.path).")
        } else {
            print(".env already has this agent id.")
        }
        return 0
    } catch {
        print("Setup failed: \(error)")
        return 1
    }
}

/// Read only: the agent's tools as ElevenLabs has them, and their workspace tool ids.
/// `check` is the app's agent (ELEVENLABS_AGENT_ID); `check --test` is the test agent.
@MainActor
func runCheck(test: Bool) async -> Int32 {
    let settings = Settings.load()
    let agentID = test ? (TestAgent.storedID() ?? "") : settings.elevenLabsAgentID
    guard !agentID.isEmpty else {
        print(test ? "No test agent yet (\(TestAgent.envKey))." : "No agent yet. Run: swift run hf-voice setup")
        return 1
    }
    let api = ElevenLabsAPI(apiKey: settings.elevenLabsAPIKey)
    do {
        let agent = try await api.agent(id: agentID)
        let prompt = agent["conversation_config"]?["agent"]?["prompt"]
        let names = (prompt?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.sorted()
        let ids = (prompt?["tool_ids"]?.arrayValue ?? []).compactMap(\.stringValue).sorted()
        print("\(test ? "TEST" : "APP") agent \(agentID) \"\(agent["name"]?.stringValue ?? "")\": \(names.count) tools")
        print("tools: \(names.joined(separator: ", "))")
        print("tool_ids: \(ids.joined(separator: ", "))")
        return 0
    } catch {
        print("Could not read the agent: \(AgentSyncer.describe(error))")
        return 1
    }
}

@MainActor
func runConversation(mode: VoiceSession.Mode) async -> Int32 {
    let settings = Settings.load()
    // Never the app's own agent: `text` and `talk` put a demo tool on the agent they use.
    let agentID: String
    do {
        agentID = try await TestAgent.resolve(settings: settings)
    } catch {
        print("Could not find or create the test agent: \(error)")
        return 1
    }
    print("Using the TEST agent \(agentID) (\(TestAgent.envKey)), not the app's own.")
    let session = VoiceSession(settings: settings, agentID: agentID, mode: mode)
    session.addReplyListener { print("agent> \($0)") }
    let tools = DemoTools.make { name, parameters in print("  [tool \(name) called with \(parameters)]") }
    let bus = ActivityBus.shared
    Task {
        for await event in bus.events() {
            switch event {
            case .userSaid(let text): print("you>   \(text)")
            case .voiceDisconnected(let reason): print("  [disconnected: \(reason)]")
            default: break
            }
        }
    }
    await session.start(tools: tools, memorySummary: "Nothing yet.")
    guard await session.waitUntilConnected(timeout: 20) else {
        print("Could not connect.")
        return 1
    }
    print(mode == .text ? "Connected. Type a message, /push <question>, or /quit." : "Connected. Speak, or type /push <question> or /quit.")
    var questionNumber = 0
    while let line = await readLine(strippingNewline: true).map({ $0 }) {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text == "/quit" { break }
        if text.hasPrefix("/push ") {
            questionNumber += 1
            session.push(TaskEvent(taskID: "demo\(questionNumber)", kind: .question, status: .needsInput, text: String(text.dropFirst(6))))
        } else if !text.isEmpty, mode == .text {
            do { try await session.sendText(text) } catch { print("  [not sent: \(error)]") }
        }
    }
    await session.stop()
    return 0
}

/// `readLine` blocks, so it runs off the main actor.
func readLine(strippingNewline: Bool) async -> String? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: Swift.readLine(strippingNewline: strippingNewline)) }
    }
}

let command = CommandLine.arguments.dropFirst().first ?? ""
let status: Int32
switch command {
case "setup": status = await runSetup()
case "check": status = await runCheck(test: CommandLine.arguments.dropFirst(2).first == "--test")
case "text": status = await runConversation(mode: .text)
case "talk": status = await runConversation(mode: .voice)
default:
    print("Usage: hf-voice setup | check [--test] | text | talk")
    status = 2
}
exit(status)
