import Foundation
import HFCore
import os

/// One gate verdict, for the app's panel and for debugging.
public struct GateAuditEntry: Sendable, Equatable {
    public let at: Date
    /// The action's description (built in HFCore, so it never holds message text), trimmed to 200 characters.
    public let action: String
    public let verdict: Risk
    public let source: DecisionSource
    public let latencyMilliseconds: Double
    public let reason: String
}

/// The safety gate: before every click and every Return, decide whether to ask the user.
///
/// 1. The fixed rules (`RiskRules.alwaysAsk`), read from the action's structured
///    fields: paying or buying, deleting, sending to people, account changes,
///    Return or a line break in a message or form, Space or Return on a focused
///    risky control, saving a calendar event, drags onto the Bin or a sending app,
///    and an unnamed or unknown control where sending is possible. These always ask; the classifier is not
///    consulted.
/// 2. The risk classifier, which only lets an action through when it is sure.
///
/// Nothing learned in memory is consulted, so memory can never make a risky action
/// skip confirmation. It never throws and never fails open.
public final class SafetyGate: SafetyGating, @unchecked Sendable {
    private let classifier: RiskClassifying
    private let auditCapacity: Int
    private let lock = NSLock()
    private var audit: [GateAuditEntry] = []
    private static let logger = Logger(subsystem: "com.handsfree", category: "HFDecisions")

    public init(classifier: RiskClassifying, auditCapacity: Int = 50) {
        self.classifier = classifier
        self.auditCapacity = auditCapacity
    }

    public func check(_ action: ScreenAction) async -> Decision<Risk> {
        let started = ContinuousClock.now
        var decision: Decision<Risk>
        if let category = RiskRules.alwaysAsk(action) {
            decision = Decision(label: .needsConfirmation, confidence: 1, source: .rule, reason: "always ask: \(category)")
        } else {
            decision = await classifier.classifyRisk(action)
        }
        decision = decision.timed(from: started)
        record(action.description, decision)
        Self.logger.info(
            "gate: \(decision.label.rawValue, privacy: .public) (\(decision.source.rawValue, privacy: .public), \(Int(decision.latencyMilliseconds)) ms) \(decision.reason, privacy: .public)")
        return decision
    }

    /// The most recent verdicts, newest first.
    public func recent(_ count: Int = 10) -> [GateAuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(audit.suffix(count).reversed())
    }

    private func record(_ action: String, _ decision: Decision<Risk>) {
        let entry = GateAuditEntry(
            at: Date(), action: String(action.prefix(200)), verdict: decision.label, source: decision.source,
            latencyMilliseconds: decision.latencyMilliseconds, reason: decision.reason)
        lock.lock()
        audit.append(entry)
        if audit.count > auditCapacity { audit.removeFirst(audit.count - auditCapacity) }
        lock.unlock()
    }
}
