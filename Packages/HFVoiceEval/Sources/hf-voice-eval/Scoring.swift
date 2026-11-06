import Foundation
import HFCore

/// Automatic checks. What they cannot judge (does it sound natural, did it understand) is read
/// by a person from the transcript in the report.
enum Scoring {
    /// Words that must never reach the user: the agent's machinery.
    static let machineWords = #"\b(tool|tools|function|functions|function call|tool call|api)\b"#
    /// Internal names, and text meant for the app, that must never be spoken.
    static let internalNames = #"start_task|answer_task|cancel_task|task_status|go_to_sleep|open_url|open_app|set_volume|media_control|skip_turn|\[APP\]|\bt\d+\b"#
    /// A bracketed stage direction ("[No response. Waiting for the user.]"), which would be read aloud.
    static let stageDirection = #"\[[^\]]{3,}\]"#

    static func failures(_ testCase: EvalCase, events: [CaseResult.Event]) -> [String] {
        var failures: [String] = []
        let replies = events.filter { $0.kind == "agent" }.map(\.text)
        let calls: [(name: String, args: JSONObject)] = events.filter { $0.kind == "tool" }.map { event in
            let name = String(event.text.prefix { $0 != " " })
            let json = String(event.text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            let args = (try? JSONDecoder().decode(JSONObject.self, from: Data(json.utf8))) ?? [:]
            return (name, args)
        }
        let expect = testCase.expect

        // Every case.
        for reply in replies {
            if matches(machineWords, reply) { failures.append("spoke machine words: \"\(reply)\"") }
            if matches(internalNames, reply) { failures.append("spoke an internal name: \"\(reply)\"") }
            if matches(stageDirection, reply) { failures.append("spoke a stage direction: \"\(reply)\"") }
            if let limit = expect.maxWords, wordCount(reply) > limit {
                failures.append("reply over \(limit) words (\(wordCount(reply))): \"\(reply)\"")
            }
        }

        // Tools.
        if expect.noCalls == true, !calls.isEmpty {
            failures.append("called \(calls.map(\.name).joined(separator: ", ")) when nothing should be called")
        }
        for forbidden in expect.forbid ?? [] where calls.contains(where: { $0.name == forbidden }) {
            failures.append("called \(forbidden), which it must not")
        }
        for (tool, limit) in expect.max ?? [:] {
            let count = calls.filter { $0.name == tool }.count
            if count > limit { failures.append("called \(tool) \(count) times (at most \(limit))") }
        }
        if let first = expect.first, calls.first?.name != first {
            failures.append("first call was \(calls.first?.name ?? "nothing"), not \(first)")
        }
        for wanted in expect.calls ?? [] {
            let found = calls.contains { call in
                call.name == wanted.tool && (wanted.args ?? [:]).allSatisfy { key, pattern in
                    let value = call.args[key].map(text) ?? ""
                    return matches(pattern, value)
                }
            }
            if !found {
                let args = (wanted.args ?? [:]).map { "\($0.key)~/\($0.value)/" }.joined(separator: " ")
                failures.append("no \(wanted.tool) call \(args)")
            }
        }

        // Speech.
        for pattern in expect.say ?? [] where !replies.contains(where: { matches(pattern, $0) }) {
            failures.append("never said /\(pattern)/")
        }
        for pattern in expect.notSay ?? [] {
            for reply in replies where matches(pattern, reply) { failures.append("said /\(pattern)/: \"\(reply)\"") }
        }
        if expect.silent == true, !replies.isEmpty {
            failures.append("should have said nothing, said: \(replies.map { "\"\($0)\"" }.joined(separator: " "))")
        }
        if let limit = expect.maxWordsBeforeFirstCall {
            let firstCallAt = events.first { $0.kind == "tool" }?.at ?? .infinity
            // A reply logged at the same moment as the call is the words spoken with it.
            let before = events.filter { $0.kind == "agent" && $0.at <= firstCallAt + 0.05 }.map(\.text)
            let words = before.map(wordCount).reduce(0, +)
            if words > limit { failures.append("said \(words) words before acting (at most \(limit)): \(before.map { "\"\($0)\"" }.joined(separator: " "))") }
        }
        if let pattern = expect.answerOnlyAfterSaying {
            let saidAt = events.first { $0.kind == "agent" && matches(pattern, $0.text) }?.at ?? .infinity
            for event in events where event.kind == "tool" && event.text.hasPrefix("answer_task") && event.at < saidAt {
                failures.append("passed an answer on before the question was said aloud: \(event.text)")
            }
        }
        if let patterns = expect.notBeforeResult {
            let resultAt = events.first { $0.kind == "push" && $0.text.hasPrefix("result") }?.at ?? .infinity
            for event in events where event.kind == "agent" && event.at < resultAt {
                for pattern in patterns where matches(pattern, event.text) {
                    failures.append("claimed /\(pattern)/ before the task's result: \"\(event.text)\"")
                }
            }
        }
        if expect.quietOrOneShortQuestion == true {
            let acceptable = replies.isEmpty || (replies.count == 1 && wordCount(replies[0]) <= 12 && replies[0].contains("?"))
            if !acceptable { failures.append("should be silent or ask one short question, said: \(replies.map { "\"\($0)\"" }.joined(separator: " "))") }
        }
        return failures
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func wordCount(_ text: String) -> Int { text.split { $0.isWhitespace }.count }

    static func text(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
