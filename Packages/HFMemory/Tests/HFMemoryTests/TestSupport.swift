import Foundation
import HFCore
@testable import HFMemory

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: Double) {
        lock.lock()
        current += seconds
        lock.unlock()
    }

    var function: @Sendable () -> Date { { self.now } }
}

/// A fresh store in its own temporary folder.
struct TestStore {
    let folder: URL
    let clock = TestClock()
    let store: MemoryStore

    init(seedBuiltIns: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hfmemory-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        store = try MemoryStore(fileURL: folder.appendingPathComponent("memory.db"), clock: clock.function)
        if seedBuiltIns { try store.seedBuiltInRecipes(BuiltInRecipe.bundled()) }
    }

    var fileURL: URL { folder.appendingPathComponent("memory.db") }
}

/// A language model that returns canned answers and records what it was asked.
final class FakeModel: StructuredLanguageModel, @unchecked Sendable {
    struct Call { let instructions: String; let input: String; let schema: JSONValue }
    struct Failure: Error {}

    private let lock = NSLock()
    private var replies: [JSONValue?]
    private var recorded: [Call] = []

    /// Each call takes the next reply; nil means "throw". The last reply repeats.
    init(_ replies: [JSONValue?]) { self.replies = replies }
    convenience init(reply: JSONValue?) { self.init([reply]) }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue {
        lock.lock()
        recorded.append(Call(instructions: instructions, input: input, schema: schema))
        let reply = replies.count > 1 ? replies.removeFirst() : replies.first ?? nil
        lock.unlock()
        guard let reply else { throw Failure() }
        return reply
    }
}

/// Paths into the repo, for checking the bundled copies against their masters.
enum Repo {
    /// …/Packages/HFMemory/Tests/HFMemoryTests/TestSupport.swift → the repo root.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static func file(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }
}

/// A canned "lasting" answer from the exchange prompt.
func lastingReply(kind: String = "preference", key: String = "google account", value: String = "work",
                  scope: String = "") -> JSONValue {
    ["lasting": true, "kind": .string(kind), "key": .string(key), "value": .string(value), "scope": .string(scope),
     "reason": "standing choice"]
}

/// A canned reply from the reflect prompt.
func reflectReply(save: Bool = true, task: String = "start an instant google meet", app: String = "chrome",
                  how: String = "Press Cmd+T, type meet.new and press Return; the link is in the address bar.",
                  pitfall: String = "", preferences: [JSONValue] = []) -> JSONValue {
    ["save_recipe": .bool(save), "task": .string(task), "app": .string(app), "how": .string(how),
     "pitfall": .string(pitfall), "preferences": .array(preferences)]
}
