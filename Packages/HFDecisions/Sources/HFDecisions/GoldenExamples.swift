import CoreGraphics
import Foundation
import HFCore

/// A control as written in the golden file: `{"role": "button", "label": "Send", "identifier": "",
/// "app": "WhatsApp", "window": "WhatsApp", "enabled": true}`.
public struct GoldenElement: Decodable, Sendable, Equatable {
    public let role: ScreenRole
    public let label: String
    public let identifier: String
    public let app: String
    public let window: String
    public let enabled: Bool
    public let bundleIdentifier: String

    enum CodingKeys: String, CodingKey {
        case role, label, identifier, app, window, enabled
        case bundleIdentifier = "bundle_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(ScreenRole.self, forKey: .role)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? ""
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? ""
        window = try container.decodeIfPresent(String.self, forKey: .window) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
    }

    public var element: UIElementInfo {
        UIElementInfo(role: role, label: label, identifier: identifier, app: app, appBundleIdentifier: bundleIdentifier,
                      window: window, frame: .zero, isEnabled: enabled)
    }
}

/// One labelled example from `jev_golden.jsonl`.
///
/// The master copy is `Fixtures/jev_golden.jsonl` at the repo root. The package
/// carries a copy as a resource (`Sources/HFDecisions/Resources/jev_golden.jsonl`),
/// and a unit test fails if the two differ; to update, edit the master and copy it over.
public struct GoldenExample: Decodable, Sendable, Equatable {
    public enum Classifier: String, Decodable, Sendable { case utterance, risk, answer }

    public let classifier: Classifier
    /// "tune": used while writing the questions and thresholds. "holdout": written
    /// afterwards and never tuned on, so its score is the honest estimate.
    public let split: String
    public let expected: String
    /// Other labels that are also acceptable for a genuinely ambiguous example.
    public let alsoOK: [String]
    public let note: String?

    // utterance
    public let text: String?
    public let taskRunning: Bool?
    /// For an utterance: the question the assistant had open, if any (only its presence
    /// reaches the classifier today). For an answer: the confirmation that was asked.
    public let question: String?
    // risk: the structured action, exactly what the screen agent hands the gate
    public let kind: ScreenAction.Kind?
    public let key: String?
    /// Nil (JSON null or absent) means the target could not be determined.
    public let target: GoldenElement?
    public let destination: GoldenElement?
    public let frontApp: String?
    public let frontWindow: String?
    public let frontBundleIdentifier: String?
    // answer
    public let reply: String?

    enum CodingKeys: String, CodingKey {
        case classifier, split, expected, note, text, question, reply, kind, key, target, destination
        case frontApp = "front_app"
        case frontWindow = "front_window"
        case frontBundleIdentifier = "front_bundle_id"
        case alsoOK = "also_ok"
        case taskRunning = "task_running"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        classifier = try container.decode(Classifier.self, forKey: .classifier)
        split = try container.decodeIfPresent(String.self, forKey: .split) ?? "tune"
        expected = try container.decode(String.self, forKey: .expected)
        alsoOK = try container.decodeIfPresent([String].self, forKey: .alsoOK) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        taskRunning = try container.decodeIfPresent(Bool.self, forKey: .taskRunning)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        kind = try container.decodeIfPresent(ScreenAction.Kind.self, forKey: .kind)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        target = try container.decodeIfPresent(GoldenElement.self, forKey: .target)
        destination = try container.decodeIfPresent(GoldenElement.self, forKey: .destination)
        frontApp = try container.decodeIfPresent(String.self, forKey: .frontApp)
        frontWindow = try container.decodeIfPresent(String.self, forKey: .frontWindow)
        frontBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .frontBundleIdentifier)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)
    }

    /// True when `label` is the expected label or one of the acceptable alternatives.
    public func accepts(_ label: String) -> Bool { label == expected || alsoOK.contains(label) }

    /// The action a risk example describes, built exactly as the product builds one.
    public var screenAction: ScreenAction? {
        guard let kind else { return nil }
        return ScreenAction(
            kind: kind, key: key.flatMap(KeyChord.init), target: target?.element, destination: destination?.element,
            frontApp: frontApp ?? "", frontWindow: frontWindow ?? "", frontAppBundleIdentifier: frontBundleIdentifier ?? "")
    }

    /// The text being classified, whichever classifier this is for (for a risk example,
    /// the action's description).
    public var input: String { text ?? reply ?? screenAction?.description ?? "" }

    /// Where the bundled copy lives.
    public static var bundledURL: URL? { Bundle.module.url(forResource: "jev_golden", withExtension: "jsonl") }

    /// The examples bundled with this package.
    public static func bundled() throws -> [GoldenExample] {
        guard let url = bundledURL else { throw CocoaError(.fileNoSuchFile) }
        return try parse(Data(contentsOf: url))
    }

    /// Parses JSON Lines: one example per line, blank lines ignored.
    public static func parse(_ data: Data) throws -> [GoldenExample] {
        let decoder = JSONDecoder()
        return try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(GoldenExample.self, from: Data($0.utf8)) }
    }
}
