import Foundation
import HFCore
import Testing

@testable import HFVoice

/// Answers requests from a script and records them.
final class FakeHTTP: HTTPSending, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    let respond: @Sendable (URLRequest) -> (Int, String)
    init(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) { self.respond = respond }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    var calls: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
    private func record(_ request: URLRequest) { lock.lock(); log.append(request); lock.unlock() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (status, body) = respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct ElevenLabsAPITests {
    let definition: JSONValue = ["name": "Hands-Free Laptop Agent", "conversation_config": [:]]

    @Test func aKnownAgentIsUpdatedNotRecreated() async throws {
        let http = FakeHTTP { _ in (200, "{}") }
        let api = ElevenLabsAPI(apiKey: "test-key", http: http)
        let sync = try await api.createOrUpdateAgent(definition: definition, knownAgentID: "agent_1")
        #expect(sync == .init(agentID: "agent_1", created: false))
        #expect(http.calls == ["PATCH /v1/convai/agents/agent_1"])
        #expect(http.requests.first?.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        let body = try JSONDecoder().decode(JSONValue.self, from: http.requests.first?.httpBody ?? Data())
        #expect(body["name"]?.stringValue == "Hands-Free Laptop Agent")
    }

    @Test func withoutAnIdTheAgentIsFoundByName() async throws {
        let http = FakeHTTP { request in
            request.httpMethod == "GET"
                ? (200, #"{"agents":[{"agent_id":"agent_other","name":"Something else"},{"agent_id":"agent_7","name":"Hands-Free Laptop Agent"}]}"#)
                : (200, "{}")
        }
        let sync = try await ElevenLabsAPI(apiKey: "k", http: http).createOrUpdateAgent(definition: definition, knownAgentID: "")
        #expect(sync == .init(agentID: "agent_7", created: false))
        #expect(http.calls == ["GET /v1/convai/agents", "PATCH /v1/convai/agents/agent_7"])
    }

    @Test func aStaleIdFallsBackToTheName() async throws {
        let http = FakeHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("PATCH", "/v1/convai/agents/agent_gone"): return (404, #"{"detail":"not found"}"#)
            case ("GET", _): return (200, #"{"agents":[{"agent_id":"agent_7","name":"Hands-Free Laptop Agent"}]}"#)
            default: return (200, "{}")
            }
        }
        let sync = try await ElevenLabsAPI(apiKey: "k", http: http).createOrUpdateAgent(definition: definition, knownAgentID: "agent_gone")
        #expect(sync.agentID == "agent_7")
    }

    @Test func noAgentAnywhereCreatesOne() async throws {
        let http = FakeHTTP { request in
            request.httpMethod == "GET" ? (200, #"{"agents":[]}"#) : (200, #"{"agent_id":"agent_new"}"#)
        }
        let sync = try await ElevenLabsAPI(apiKey: "k", http: http).createOrUpdateAgent(definition: definition, knownAgentID: "")
        #expect(sync == .init(agentID: "agent_new", created: true))
        #expect(http.calls.last == "POST /v1/convai/agents/create")
    }

    @Test func otherErrorsAreReportedNotHidden() async {
        let http = FakeHTTP { _ in (400, #"{"detail":"bad"}"#) }
        await #expect(throws: ElevenLabsAPIError.self) {
            _ = try await ElevenLabsAPI(apiKey: "k", http: http).createOrUpdateAgent(definition: definition, knownAgentID: "agent_1")
        }
    }

    @Test func conversationCredentials() async throws {
        let http = FakeHTTP { request in
            request.url?.path.hasSuffix("token") == true
                ? (200, #"{"token":"jwt","conversation_id":"c"}"#) : (200, #"{"signed_url":"wss://x?agent_id=a"}"#)
        }
        let api = ElevenLabsAPI(apiKey: "k", http: http)
        #expect(try await api.conversationToken(agentID: "a") == "jwt")
        #expect(try await api.signedURL(agentID: "a") == "wss://x?agent_id=a")
        #expect(http.requests.first?.url?.query == "agent_id=a")
    }
}

@Suite struct EnvFileTests {
    func tempFile(_ text: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    @Test func replacesTheLineAndKeepsTheRest() throws {
        let file = try tempFile("ELEVENLABS_API_KEY=secret\nELEVENLABS_AGENT_ID=\n# note\nOTHER=1\n")
        try EnvFile.set("ELEVENLABS_AGENT_ID", to: "agent_1", in: file)
        try EnvFile.set("ELEVENLABS_AGENT_ID", to: "agent_1", in: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "ELEVENLABS_API_KEY=secret\nELEVENLABS_AGENT_ID=agent_1\n# note\nOTHER=1\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func appendsWhenMissingAndRemovesDuplicates() throws {
        let missing = try tempFile("A=1")
        try EnvFile.set("ELEVENLABS_AGENT_ID", to: "x", in: missing)
        #expect(try String(contentsOf: missing, encoding: .utf8) == "A=1\nELEVENLABS_AGENT_ID=x\n")
        let doubled = try tempFile("ELEVENLABS_AGENT_ID=a\nELEVENLABS_AGENT_ID=b\n")
        try EnvFile.set("ELEVENLABS_AGENT_ID", to: "c", in: doubled)
        #expect(try String(contentsOf: doubled, encoding: .utf8) == "ELEVENLABS_AGENT_ID=c\n")
        let absent = try tempFile(nil)
        try EnvFile.set("K", to: "v", in: absent)
        #expect(try String(contentsOf: absent, encoding: .utf8) == "K=v\n")
    }
}
