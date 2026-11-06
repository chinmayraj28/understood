import CoreGraphics
import Foundation
import HFCore

/// One thing Claude asked for in a turn: a computer action from the toolset, or
/// one of our own three tools. Parsed from a `tool_use` block.
///
/// The computer toolset (`computer_toolset_20260801`) sends each action as its
/// own `tool_use` block whose `name` is the action and whose `toolset_name` is
/// "computer". Coordinates are image pixels of the latest full screenshot.
enum AgentRequest: Equatable {
    case computer(ComputerAction)
    case askUser(question: String, options: [String])
    case reportProgress(String)
    /// Who the next send goes to, as read in the open chat's header.
    case prepareSend(recipient: String, expected: String)
    case finished(success: Bool, summary: String)
    /// A tool name or input we do not understand. Answered with an error result.
    case unknown(name: String, reason: String)
}

/// A computer action, with coordinates still in image pixels.
enum ComputerAction: Equatable {
    case screenshot
    case zoom(region: CGRect)
    /// `point` nil means "where the pointer is now".
    case click(button: MouseButton, count: Int, point: CGPoint?, modifiers: [KeyModifier])
    case drag(from: CGPoint, to: CGPoint)
    case move(to: CGPoint)
    case scroll(dx: Int, dy: Int, point: CGPoint?)
    case type(text: String)
    /// `combo` is already in HFHands' naming ("cmd+space", "return").
    case key(combo: String, repeatCount: Int)
    case wait(seconds: Double)
    case cursorPosition

    /// True when the action can change what is on screen, so a fresh screenshot is worth taking.
    var changesScreen: Bool {
        switch self {
        case .screenshot, .zoom, .cursorPosition: return false
        default: return true
        }
    }
}

/// A `tool_use` block as it arrives: its id, and what it asks for.
struct ToolCall: Equatable {
    let id: String
    let isComputer: Bool
    let request: AgentRequest
}

enum ToolCallParser {
    /// Members of the toolset we turn off in the request, because the hands have
    /// no way to hold a button or a key down on their own and we never want
    /// anything left held.
    static let disabledMembers = ["left_mouse_down", "left_mouse_up", "hold_key"]

    static func parse(_ block: JSONValue) -> ToolCall? {
        guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue,
            let name = block["name"]?.stringValue
        else { return nil }
        let input = block["input"]?.objectValue ?? [:]
        let isComputer = block["toolset_name"]?.stringValue == "computer"
        let request = isComputer ? parseComputer(name: name, input: input) : parseOwn(name: name, input: input)
        return ToolCall(id: id, isComputer: isComputer, request: request)
    }

    private static func parseOwn(name: String, input: JSONObject) -> AgentRequest {
        switch name {
        case "ask_user":
            guard let question = input["question"]?.stringValue, !question.isEmpty else {
                return .unknown(name: name, reason: "ask_user needs a question.")
            }
            let options = (input["options"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .askUser(question: question, options: options)
        case "prepare_send":
            let recipient = input["recipient"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !recipient.isEmpty else { return .unknown(name: name, reason: "prepare_send needs the recipient's name.") }
            let expected = input["expected_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .prepareSend(recipient: recipient, expected: expected)
        case "report_progress":
            return .reportProgress(input["message"]?.stringValue ?? "")
        case "task_finished":
            return .finished(
                success: input["success"]?.boolValue ?? false,
                summary: input["summary"]?.stringValue ?? ""
            )
        default:
            return .unknown(name: name, reason: "There is no tool called \(name).")
        }
    }

    private static func parseComputer(name: String, input: JSONObject) -> AgentRequest {
        let point = coordinate(input["coordinate"])
        let modifiers = parseModifiers(input["text"]?.stringValue ?? "")
        func click(_ button: MouseButton, _ count: Int) -> AgentRequest {
            .computer(.click(button: button, count: count, point: point, modifiers: modifiers))
        }
        switch name {
        case "screenshot": return .computer(.screenshot)
        case "cursor_position": return .computer(.cursorPosition)
        case "left_click": return click(.left, 1)
        case "double_click": return click(.left, 2)
        case "triple_click": return click(.left, 3)
        case "right_click": return click(.right, 1)
        case "middle_click": return click(.middle, 1)
        case "mouse_move":
            guard let point else { return .unknown(name: name, reason: "mouse_move needs a coordinate.") }
            return .computer(.move(to: point))
        case "left_click_drag":
            guard let start = coordinate(input["start_coordinate"]), let end = point else {
                return .unknown(name: name, reason: "left_click_drag needs start_coordinate and coordinate.")
            }
            return .computer(.drag(from: start, to: end))
        case "scroll":
            let amount = max(1, min(input["scroll_amount"]?.intValue ?? 3, 30))
            switch input["scroll_direction"]?.stringValue {
            case "down": return .computer(.scroll(dx: 0, dy: amount, point: point))
            case "up": return .computer(.scroll(dx: 0, dy: -amount, point: point))
            case "right": return .computer(.scroll(dx: amount, dy: 0, point: point))
            case "left": return .computer(.scroll(dx: -amount, dy: 0, point: point))
            default: return .unknown(name: name, reason: "scroll needs scroll_direction up, down, left or right.")
            }
        case "type":
            guard let text = input["text"]?.stringValue else { return .unknown(name: name, reason: "type needs text.") }
            return .computer(.type(text: text))
        case "key":
            guard let text = input["text"]?.stringValue, !text.isEmpty else {
                return .unknown(name: name, reason: "key needs text, such as \"Return\" or \"cmd+space\".")
            }
            let repeatCount = max(1, min(input["repeat"]?.intValue ?? 1, 20))
            return .computer(.key(combo: handsKeyName(text), repeatCount: repeatCount))
        case "wait":
            // Capped at 2 s: measured, Claude asked for 6.4 s of waiting in one short task,
            // while the settle pause and the next screenshot already cover a page load.
            return .computer(.wait(seconds: max(0, min(input["duration"]?.doubleValue ?? 1, 2))))
        case "zoom":
            guard let numbers = input["region"]?.arrayValue?.compactMap(\.doubleValue), numbers.count == 4 else {
                return .unknown(name: name, reason: "zoom needs region [x0, y0, x1, y1].")
            }
            let rect = CGRect(x: min(numbers[0], numbers[2]), y: min(numbers[1], numbers[3]),
                              width: abs(numbers[2] - numbers[0]), height: abs(numbers[3] - numbers[1]))
            guard rect.width >= 1, rect.height >= 1 else { return .unknown(name: name, reason: "zoom region is empty.") }
            return .computer(.zoom(region: rect))
        default:
            return .unknown(name: name, reason: "\(name) is not available on this Mac.")
        }
    }

    private static func coordinate(_ value: JSONValue?) -> CGPoint? {
        guard let numbers = value?.arrayValue?.compactMap(\.doubleValue), numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    /// The toolset names modifiers the xdotool way: shift, ctrl, alt, super.
    /// On a Mac, super is the Command key.
    static func parseModifiers(_ text: String) -> [KeyModifier] {
        var result: [KeyModifier] = []
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }) {
            let modifier: KeyModifier?
            switch part {
            case "super", "cmd", "command", "meta", "win": modifier = .command
            case "ctrl", "control": modifier = .control
            case "alt", "option", "opt": modifier = .option
            case "shift": modifier = .shift
            case "fn", "function": modifier = .function
            default: modifier = nil
            }
            if let modifier, !result.contains(modifier) { result.append(modifier) }
        }
        return result
    }

    /// Converts the model's key names (xdotool style: "Return", "super+space",
    /// "BackSpace", "Page_Down") into the names HFHands accepts ("return",
    /// "cmd+space", "backspace", "page_down").
    static func handsKeyName(_ text: String) -> String {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" is Command and the plus key: keep a trailing empty part as "+".
        return parts.enumerated().map { index, part -> String in
            if part.isEmpty { return index == parts.count - 1 ? "plus" : "" }
            switch part.lowercased() {
            case "super", "meta", "win", "command": return "cmd"
            case "control": return "ctrl"
            case "alt", "opt": return "option"
            case "kp_enter": return "enter"
            // xdotool's "Delete" is forward delete, but on a Mac the key labelled
            // delete is backspace, and that is what "cmd+Delete" (Move to Bin) means.
            case "delete", "backspace": return "delete"
            case "prior": return "page_up"
            case "next": return "page_down"
            default: return part.lowercased()
            }
        }.filter { !$0.isEmpty }.joined(separator: "+")
    }
}
