import Foundation
import HFCore

/// Sends one HTTP request. The live version is URLSession; tests pass a fake.
public protocol HTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession as `HTTPSending`.
public struct URLSessionHTTP: HTTPSending {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A failed ElevenLabs REST call. The message carries the status and the start of
/// the response body, which never contains our key.
public struct ElevenLabsAPIError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let message: String
    public var description: String { "ElevenLabs API error \(status): \(message)" }
}

/// The few ElevenLabs REST calls the voice layer needs: keep the agent in step
/// with the code, and get the credentials a conversation starts with.
public struct ElevenLabsAPI: Sendable {
    let apiKey: String
    let http: HTTPSending
    let baseURL: URL

    public init(apiKey: String, http: HTTPSending = URLSessionHTTP(), baseURL: URL = URL(string: "https://api.elevenlabs.io")!) {
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
    }

    /// The outcome of `createOrUpdateAgent`.
    public struct AgentSync: Equatable, Sendable {
        public let agentID: String
        /// True when a new agent was made; false when an existing one was updated.
        public let created: Bool
    }

    /// Makes the agent on ElevenLabs match `definition`, without ever making a second one.
    ///
    /// 1. If `knownAgentID` is set and exists, update it.
    /// 2. Otherwise, if an agent with the same name exists, update that one.
    /// 3. Otherwise create it.
    public func createOrUpdateAgent(definition: JSONValue, knownAgentID: String) async throws -> AgentSync {
        if !knownAgentID.isEmpty {
            do {
                _ = try await call("PATCH", "/v1/convai/agents/\(knownAgentID)", body: definition)
                return AgentSync(agentID: knownAgentID, created: false)
            } catch let error as ElevenLabsAPIError where error.status == 404 {
                // The stored id points at a deleted agent; fall back to finding it by name.
            }
        }
        if let name = definition["name"]?.stringValue, let existing = try await findAgent(named: name) {
            _ = try await call("PATCH", "/v1/convai/agents/\(existing)", body: definition)
            return AgentSync(agentID: existing, created: false)
        }
        let created = try await call("POST", "/v1/convai/agents/create", body: definition)
        guard let agentID = created["agent_id"]?.stringValue else {
            throw ElevenLabsAPIError(status: 200, message: "The create response had no agent_id.")
        }
        return AgentSync(agentID: agentID, created: true)
    }

    /// The id of the agent with exactly this name, if there is one.
    public func findAgent(named name: String) async throws -> String? {
        var query = URLComponents()
        query.queryItems = [.init(name: "search", value: name), .init(name: "page_size", value: "100")]
        let listing = try await call("GET", "/v1/convai/agents?\(query.percentEncodedQuery ?? "")")
        let agents = listing["agents"]?.arrayValue ?? []
        return agents.first { $0["name"]?.stringValue == name }?["agent_id"]?.stringValue
    }

    /// A short-lived token for a voice (WebRTC) conversation with a private agent.
    public func conversationToken(agentID: String) async throws -> String {
        let reply = try await call("GET", "/v1/convai/conversation/token?agent_id=\(agentID)")
        guard let token = reply["token"]?.stringValue else {
            throw ElevenLabsAPIError(status: 200, message: "The token response had no token.")
        }
        return token
    }

    /// A signed websocket URL for a text-only conversation with a private agent.
    public func signedURL(agentID: String) async throws -> String {
        let reply = try await call("GET", "/v1/convai/conversation/get-signed-url?agent_id=\(agentID)")
        guard let url = reply["signed_url"]?.stringValue else {
            throw ElevenLabsAPIError(status: 200, message: "The signed URL response had no signed_url.")
        }
        return url
    }

    /// The agent as stored on ElevenLabs.
    public func agent(id agentID: String, timeout: TimeInterval = 30) async throws -> JSONValue {
        try await call("GET", "/v1/convai/agents/\(agentID)", timeout: timeout)
    }

    @discardableResult
    func call(_ method: String, _ pathAndQuery: String, body: JSONValue? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let url = URL(string: pathAndQuery, relativeTo: baseURL) else {
            throw ElevenLabsAPIError(status: 0, message: "Bad path \(pathAndQuery)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(decoding: data.prefix(500), as: UTF8.self)
            throw ElevenLabsAPIError(status: response.statusCode, message: text)
        }
        if data.isEmpty { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
