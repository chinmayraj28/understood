import Foundation
import HFCore
import Testing
@testable import HFDecisions

/// A transport that never touches the network: it answers with a handler and counts calls.
final class FakeTransport: JevTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let handler: Handler
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }

    private func note(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        note(request)
        return try await handler(request)
    }

    // MARK: Canned behaviours

    static func respond(status: Int = 200, json: Any) -> FakeTransport {
        FakeTransport { request in
            let data = try JSONSerialization.data(withJSONObject: json)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func respond(status: Int, text: String) -> FakeTransport {
        FakeTransport { request in
            (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    /// Answers one choice question with these probabilities.
    static func choice(_ questionID: String, _ probabilities: [String: Double]) -> FakeTransport {
        let top = probabilities.max { $0.value < $1.value }!.key
        return respond(json: ["answers": [questionID: [
            "type": "choice", "choice": top, "probabilities": probabilities,
            "confidence": probabilities.values.max()!,
        ]]])
    }

    static func slow(seconds: Double) -> FakeTransport {
        FakeTransport { request in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    static let failing = respond(status: 500, text: "upstream error")
    static let brokenNetwork = FakeTransport { _ in throw URLError(.cannotConnectToHost) }
    /// For decisions that must be made without asking Jev at all.
    static let mustNotBeCalled = FakeTransport { _ in
        Issue.recordIfPossible("this decision should not have needed the network")
        throw URLError(.cancelled)
    }
}

extension Issue {
    /// Swift Testing's `Issue.record` is only callable from inside a test; this keeps the fake reusable.
    static func recordIfPossible(_ message: String) { Issue.record(Comment(rawValue: message)) }
}

let fakeKey = "sk-or-test-not-a-real-key"

func makeClient(_ transport: FakeTransport, timeoutSeconds: Double = 0.5) -> JevClient {
    JevClient(apiKey: fakeKey, model: "jev-latest", url: URL(string: "https://jev.test/v1/systemone")!,
              timeoutSeconds: timeoutSeconds, transport: transport)
}

func classifiers(_ transport: FakeTransport?, timeoutSeconds: Double = 0.5) -> Classifiers {
    Classifiers(client: transport.map { makeClient($0, timeoutSeconds: timeoutSeconds) })
}

/// An utterance answer from Jev with these probabilities (missing options are 0).
func utteranceSays(cancel: Double = 0, command: Double = 0, answer: Double = 0, other: Double = 0) -> FakeTransport {
    .choice(JevQuestions.utteranceID, ["cancel": cancel, "command": command, "answer": answer, "other": other])
}

func riskSays(safe: Double) -> FakeTransport {
    .choice(JevQuestions.riskID, ["safe": safe, "needs_confirmation": 1 - safe])
}

func answerSays(yes: Double = 0, no: Double = 0, unclear: Double = 0) -> FakeTransport {
    .choice(JevQuestions.answerID, ["yes": yes, "no": no, "unclear": unclear])
}

let working = UtteranceContext(taskRunning: true)
let awaiting = UtteranceContext(taskRunning: true, awaitingAnswer: true)

func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double { start.duration(to: .now).milliseconds }

// MARK: - Building screen actions the way the screen agent does

func element(_ role: ScreenRole, _ label: String = "", identifier: String = "", app: String, bundle: String = "",
             window: String = "", enabled: Bool = true) -> UIElementInfo {
    UIElementInfo(role: role, label: label, identifier: identifier, app: app, appBundleIdentifier: bundle,
                  window: window, frame: .zero, isEnabled: enabled)
}

func click(_ role: ScreenRole, _ label: String = "", identifier: String = "", app: String, bundle: String = "",
           window: String = "", enabled: Bool = true) -> ScreenAction {
    ScreenAction(kind: .click, target: element(role, label, identifier: identifier, app: app, bundle: bundle,
                                               window: window, enabled: enabled))
}

func clickUnknown(in app: String, window: String = "") -> ScreenAction {
    ScreenAction(kind: .click, target: nil, frontApp: app, frontWindow: window)
}

func press(_ key: String, _ role: ScreenRole, _ label: String = "", app: String, window: String = "") -> ScreenAction {
    ScreenAction(kind: .pressKey, key: KeyChord(key), target: element(role, label, app: app, window: window))
}

func pressWithUnknownFocus(_ key: String, in app: String, window: String = "") -> ScreenAction {
    ScreenAction(kind: .pressKey, key: KeyChord(key), target: nil, frontApp: app, frontWindow: window)
}

func lineBreak(_ role: ScreenRole?, _ label: String = "", app: String, window: String = "") -> ScreenAction {
    ScreenAction(kind: .typeLineBreak, target: role.map { element($0, label, app: app, window: window) },
                 frontApp: app, frontWindow: window)
}

func drag(_ item: UIElementInfo, to destination: UIElementInfo?) -> ScreenAction {
    ScreenAction(kind: .drag, target: item, destination: destination)
}

/// WhatsApp as verified on this Mac: the window title is always "WhatsApp".
let whatsAppSend = click(.button, "Send", app: "WhatsApp", window: "WhatsApp")
let whatsAppBox = element(.textArea, "Compose message", app: "WhatsApp", window: "WhatsApp")
