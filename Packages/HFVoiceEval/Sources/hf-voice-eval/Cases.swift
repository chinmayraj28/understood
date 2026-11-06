import Foundation
import HFCore

/// One labelled conversation. Loaded from Cases/cases.json.
struct EvalCase: Decodable, Sendable {
    let id: String
    let category: String
    /// What the case is about, for the report.
    let note: String?
    /// The rest of the wake sentence ("Hey Handsfree, open Spotify" → "open Spotify"), if any.
    let firstUtterance: String?
    /// What the agent knows about the user (the `user_memory` dynamic variable).
    let memory: String?
    let turns: [Turn]
    /// What start_task does in this case.
    let task: TaskScript?
    /// Results to return instead of the default stub results, by tool name.
    let toolResults: [String: StubResult]?
    let expect: Expect

    enum Turn: Decodable, Sendable {
        case say(String)
        case wait(Double)

        private enum Keys: String, CodingKey { case say, wait }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let text = try container.decodeIfPresent(String.self, forKey: .say) { self = .say(text); return }
            self = .wait(try container.decode(Double.self, forKey: .wait))
        }
    }

    struct TaskScript: Decodable, Sendable {
        /// done | question | confirm | fails | long
        let kind: String
        /// Seconds of work before it finishes (done) or before it asks (question, confirm).
        let delay: Double?
        /// The result summary; "{answer}" is replaced with the user's answer.
        let summary: String?
        let question: String?
        let options: [String]?
    }

    struct StubResult: Decodable, Sendable {
        let error: String?
        let fields: [String: String]?
    }

    struct Expect: Decodable, Sendable {
        /// Calls that must happen: the tool, and for each argument a case-insensitive pattern it must match.
        let calls: [ExpectedCall]?
        /// No tool at all may be called.
        let noCalls: Bool?
        /// Tools that must not be called.
        let forbid: [String]?
        /// The most times a tool may be called.
        let max: [String: Int]?
        /// The first tool called must be this one.
        let first: String?
        /// Every pattern must match at least one thing the agent said.
        let say: [String]?
        /// No pattern may match anything the agent said.
        let notSay: [String]?
        /// The longest any one reply may be, in words.
        let maxWords: Int?
        /// The agent says nothing at all.
        let silent: Bool?
        /// Nothing, or at most one short question ("Was that for me?").
        let quietOrOneShortQuestion: Bool?
        /// No pattern may be said before the task's result has arrived ("it's done", "sent").
        let notBeforeResult: [String]?
        /// The most words the agent may say before its first action (its few words, no narration).
        let maxWordsBeforeFirstCall: Int?
    }

    struct ExpectedCall: Decodable, Sendable {
        let tool: String
        let args: [String: String]?
    }
}

/// What happened in one case.
struct CaseResult: Encodable, Sendable {
    struct Event: Encodable, Sendable {
        let at: Double  // seconds since the conversation connected
        let kind: String  // user | agent | tool | result | push | note
        let text: String
    }
    struct Timing: Encodable, Sendable {
        let turn: String
        let firstWords: Double?
        let toolCall: Double?
    }
    let id: String
    let category: String
    var passed: Bool
    var failures: [String]
    var events: [Event]
    var timings: [Timing]
    var replies: [String]
    var calls: [String]
}

func loadCases(from url: URL) throws -> [EvalCase] {
    try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
}
