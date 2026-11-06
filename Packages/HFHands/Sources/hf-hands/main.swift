import CoreGraphics
import Foundation
import HFCore
import HFHands

// hf-hands: try the hands and the quick tools on the real Mac, without the voice agent.
//
//   swift run hf-hands --list
//   swift run hf-hands set_volume '{"percent": 30}'
//   swift run hf-hands where_am_i
//   swift run hf-hands --key "volume_up"          press one key or shortcut
//   swift run hf-hands --type "hello"             type text into the front app
//   swift run hf-hands --state                    print volume, brightness, front app, Spotlight
//   swift run hf-hands --permissions
//   swift run hf-hands --dump-tools > ../../Fixtures/quick_tools.json
//
// Every run prints the result and how long it took.

let arguments = Array(CommandLine.arguments.dropFirst())
// The real hands are created only by commands that act: creating them releases
// any stuck key, which posts events, and --state and --permissions only read.
nonisolated(unsafe) var createdHands: SystemHands?
func makeHands() -> SystemHands {
    if let createdHands { return createdHands }
    let hands = SystemHands()
    // For experiments: HF_TYPING_INTERVAL=0.008 swift run hf-hands open_app ...
    if let interval = ProcessInfo.processInfo.environment["HF_TYPING_INTERVAL"].flatMap(Double.init) { hands.typingInterval = interval }
    createdHands = hands
    return hands
}
let system = LiveSystem()

func printState() {
    let volume = system.outputVolume()
    let front = system.frontApp()
    print("volume: \(volume.map { String(format: "%.2f muted=%@", $0.percent, $0.muted ? "yes" : "no") } ?? "unreadable")")
    print("brightness: \(system.displayBrightness().map { String(format: "%.2f", $0) } ?? "unreadable")")
    print("front: \(front?.name ?? "?") (\(front?.bundleID ?? "")) window: \(front.map { system.windowTitle(pid: $0.pid) } ?? "")")
    let focus = system.keyboardFocus()
    print("keyboard: \(focus.map { "\($0.appName) \($0.role) \($0.identifier)" } ?? "unknown")")
    print("spotlight open: \(system.spotlightIsOpen())  pointer: \(CGEvent(source: nil)?.location ?? .zero)")
}

func run() async -> Int32 {
    guard let first = arguments.first, first != "--help", first != "-h" else {
        print("usage: hf-hands <tool> ['<json>'] | --list | --key <combo> | --type <text> | --state | --permissions")
        return 0
    }
    let started = Date()
    defer { if first != "--dump-tools" { print(String(format: "took %.1f ms", Date().timeIntervalSince(started) * 1000)) } }
    switch first {
    case "--state":
        printState()
        return 0
    case "--permissions":
        print("host app: \(Permissions.hostAppName)")
        for status in Permissions.checkAll() { print("  \(status.name): \(status.state.rawValue) \(status.detail)") }
        return 0
    case "--key", "--type":
        guard arguments.count > 1 else { print("missing argument"); return 2 }
        do {
            if first == "--key" { try await makeHands().key(arguments[1]) } else { try await makeHands().typeText(arguments[1]) }
            return 0
        } catch let error as SpeakableError {
            print("error: \(error.spokenMessage)")
            return 1
        } catch {
            print("error: \(error)")
            return 1
        }
    default:
        break
    }
    let tools = QuickTools.make(hands: makeHands(), system: system)
    if first == "--list" {
        for tool in tools { print(tool.name) }
        return 0
    }
    if first == "--dump-tools" {
        // The tool definitions as JSON, for Fixtures/quick_tools.json.
        let definitions: JSONValue = .array(tools.map { tool in
            ["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters,
             "timeout_seconds": .number(Double(tool.timeoutSeconds))]
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try! encoder.encode(definitions), encoding: .utf8)!)
        return 0
    }
    guard let tool = tools.first(where: { $0.name == first }) else {
        print("No quick tool called \(first). Try --list.")
        return 2
    }
    var parameters: JSONObject = [:]
    if arguments.count > 1 {
        guard let data = arguments[1].data(using: .utf8),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data), let object = decoded.objectValue
        else { print("Parameters must be a JSON object."); return 2 }
        parameters = object
    }
    let result = await tool.handler(parameters)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(JSONValue.object(result)), let text = String(data: data, encoding: .utf8) { print(text) }
    return result["ok"]?.boolValue == true ? 0 : 1
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    exitCode = await run()
    // Keys posted just before exit can be lost (measured with the volume keys), so linger briefly.
    try? await Task.sleep(nanoseconds: 150_000_000)
    semaphore.signal()
}
semaphore.wait()
exit(exitCode)
