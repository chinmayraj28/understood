import Foundation
import HFCore
import os

/// How long the quick tools wait for the Mac to react. The defaults were
/// measured on the development Mac; tests shrink them.
public struct QuickTiming: Sendable {
    /// Spotlight's panel normally appears within 0.2 s of Command+Space.
    public var spotlightAppears: TimeInterval = 1.5
    /// After Spotlight shows results, before Return: lets the top hit settle on the app.
    public var spotlightResults: TimeInterval = 0.35
    /// An app that isn't running can take a few seconds to launch and come forward.
    public var appComesForward: TimeInterval = 6
    /// A browser just launched may take a moment to show its first window.
    public var browserWindowAppears: TimeInterval = 5
    /// Pause after Command+T before typing the address.
    public var newTabReady: TimeInterval = 0.35
    /// Waiting for Command+C to reach the clipboard.
    public var clipboardUpdates: TimeInterval = 0.8
    /// macOS writes a screenshot file only after its floating thumbnail goes (about 5 s).
    public var screenshotSaved: TimeInterval = 8
    /// Between the steps of Command+Shift+4, Space, click.
    public var screenshotStep: TimeInterval = 0.35
    /// The safety guard must answer within this, or the action is refused.
    public var guardTimeout: TimeInterval = 3
    /// How often to look again while waiting.
    public var poll: TimeInterval = 0.05

    public init() {}
    public static let standard = QuickTiming()
}

/// A bad parameter or a refusal; the message is spoken.
struct Refusal: Error { let spokenMessage: String; init(_ message: String) { spokenMessage = message } }

enum QuickToolSupport {
    static let logger = Logger(subsystem: "com.handsfree", category: "HFHands.QuickTools")

    /// Wraps a handler so it never throws and always answers in a speakable sentence.
    static func spec(
        _ name: String, _ description: String, properties: JSONObject, required: [String] = [],
        timeout: Int = 15, doing: String, hands: Hands,
        _ body: @escaping @Sendable (JSONObject) async throws -> JSONObject
    ) -> ToolSpec {
        let parameters: JSONValue = [
            "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
        ]
        return ToolSpec(name: name, description: description, parameters: parameters, tier: .quick, timeoutSeconds: timeout) {
            params in
            // A quick tool is a fresh spoken command, so a stop said earlier no
            // longer applies: by now it has frozen whatever was in flight.
            if hands.isHalted { hands.resume() }
            let started = Date()
            let result: JSONObject
            do {
                result = try await body(params)
            } catch let refusal as Refusal {
                result = ToolResult.failure(refusal.spokenMessage)
            } catch let error as SpeakableError {
                result = ToolResult.failure(error.spokenMessage)
            } catch is Halted {
                result = ToolResult.failure("I stopped, as you asked.")
            } catch is CancellationError {
                result = ToolResult.failure("I stopped, as you asked.")
            } catch {
                logger.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                result = ToolResult.failure("Something went wrong while trying to \(doing).")
            }
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            logger.info("\(name, privacy: .public) took \(milliseconds) ms, ok=\(result["ok"]?.boolValue ?? false)")
            return result
        }
    }

    // MARK: Parameters. They come from an LLM that heard speech: accept "30", 30.0 and "30%".

    static func number(_ params: JSONObject, _ key: String, _ range: ClosedRange<Double>, _ what: String) throws -> Double? {
        guard let value = params[key], value != .null else { return nil }
        let number: Double?
        switch value {
        case .number(let raw): number = raw
        case .string(let raw):
            let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { return nil }
            number = Double(cleaned)
        default: number = nil
        }
        guard let number, number.isFinite else { throw Refusal("\(what) must be a number.") }
        guard range.contains(number) else {
            throw Refusal("\(what) must be between \(Int(range.lowerBound)) and \(Int(range.upperBound)).")
        }
        return number
    }

    static func flag(_ params: JSONObject, _ key: String) throws -> Bool? {
        guard let value = params[key], value != .null else { return nil }
        switch value {
        case .bool(let raw): return raw
        case .number(let raw) where raw == 0 || raw == 1: return raw == 1
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            case "": return nil
            default: break
            }
        default: break
        }
        throw Refusal("\(key.replacingOccurrences(of: "_", with: " ")) must be true or false.")
    }

    static func choice(
        _ params: JSONObject, _ key: String, _ choices: [String], default fallback: String?, _ what: String,
        synonyms: [String: String] = [:]
    ) throws -> String {
        // Only list the choices aloud when there are few enough to listen to.
        let listed = choices.count <= 6 ? choices.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ") : ""
        guard let raw = params[key]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let fallback { return fallback }
            throw Refusal("Tell me the \(what)" + (listed.isEmpty ? "." : ": \(listed)."))
        }
        var word = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        word = synonyms[word] ?? word
        guard choices.contains(word) else {
            throw Refusal("I don't know the \(what) \"\(raw.prefix(40))\"" + (listed.isEmpty ? "." : "; try \(listed)."))
        }
        return word
    }

    static func text(_ params: JSONObject, _ key: String, _ what: String, maxLength: Int) throws -> String {
        guard let value = params[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Refusal("Tell me the \(what).")
        }
        guard value.count <= maxLength else { throw Refusal("That \(what) is too long.") }
        return value
    }

    /// Waits until `condition` holds or the time runs out. Returns whether it held.
    /// A stop said meanwhile ends the wait at once with `Halted`.
    static func waitUntil(_ hands: Hands, _ timeout: TimeInterval, poll: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if hands.isHalted { throw Halted() }
            if condition() { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(min(max(0.005, poll), 0.05) * 1_000_000_000))
        }
    }

    /// Sleeps in short slices, ending at once with `Halted` if the user says stop.
    static func sleep(_ hands: Hands, _ seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if hands.isHalted { throw Halted() }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 0.01) * 1_000_000_000))
        }
    }
}

/// Plans key presses for volume and brightness, which macOS changes in steps.
///
/// Measured on macOS 26: a plain volume or brightness key moves 1/16 (6.25
/// points) and first snaps to that grid (from 19 one press up lands on 25, from
/// 90 one press down lands on 87.5). With Shift+Option held it moves 1/64
/// (1.5625 points), snapping to that finer grid. So any level can be reached
/// to within 0.8 points: coarse presses while far away, fine presses to land.
enum LevelSteps {
    static let coarse = 6.25
    static let fine = 1.5625

    enum Press: Equatable { case coarseUp, coarseDown, fineUp, fineDown }

    static func next(_ level: Double, step: Double, up: Bool) -> Double {
        let position = level / step
        let index = up ? (position + 1e-6).rounded(.down) + 1 : (position - 1e-6).rounded(.up) - 1
        return min(100, max(0, index * step))
    }

    /// The presses that take `current` to within half a fine step of `target`, as modelled.
    static func plan(from current: Double, to target: Double, limit: Int = 40) -> [Press] {
        var level = current
        var presses: [Press] = []
        while presses.count < limit {
            let difference = target - level
            if abs(difference) < fine / 2 { break }
            let up = difference > 0
            let coarseLanding = next(level, step: coarse, up: up)
            if up ? coarseLanding <= target + fine / 2 : coarseLanding >= target - fine / 2 {
                presses.append(up ? .coarseUp : .coarseDown)
                level = coarseLanding
            } else {
                let fineLanding = next(level, step: fine, up: up)
                if fineLanding == level { break }  // at 0 or 100 already
                presses.append(up ? .fineUp : .fineDown)
                level = fineLanding
            }
        }
        return presses
    }

    /// The key names for a plan, e.g. ["volume_up", "shift+option+volume_up"].
    static func keyNames(_ presses: [Press], up upKey: String, down downKey: String) -> [String] {
        presses.map { press in
            switch press {
            case .coarseUp: return upKey
            case .coarseDown: return downKey
            case .fineUp: return "shift+option+\(upKey)"
            case .fineDown: return "shift+option+\(downKey)"
            }
        }
    }
}
