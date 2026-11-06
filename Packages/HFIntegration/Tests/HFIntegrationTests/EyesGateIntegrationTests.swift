import CoreGraphics
import Foundation
import HFCore
import HFDecisions
import HFEyes
import HFScreenAgent
import HFTasks
import Testing

// What the eyes say a control is, judged by the real safety gate. The real
// AccessibilityLabels runs over a fake accessibility tree, so nothing here reads
// the user's screen or touches their apps.

/// A fixed accessibility tree. Optionally slow, like an app that has stopped answering.
final class FakeAccessibilitySource: AccessibilitySource, @unchecked Sendable {
    let hits: [AccessibilityHit]
    let focusedHit: AccessibilityHit?
    let frontApp: (app: String, window: String)
    let delaySeconds: Double

    init(hits: [AccessibilityHit], focused: AccessibilityHit? = nil, front: (app: String, window: String), delaySeconds: Double = 0) {
        self.hits = hits
        self.focusedHit = focused
        self.frontApp = front
        self.delaySeconds = delaySeconds
    }

    private func pause() { if delaySeconds > 0 { Thread.sleep(forTimeInterval: delaySeconds) } }
    func hit(at point: CGPoint) -> AccessibilityHit? { pause(); return hits.first { $0.node.frame.contains(point) } }
    func focused() -> AccessibilityHit? { pause(); return focusedHit }
    func front() -> (app: String, window: String) { frontApp }
    func controls(limit: Int) -> [AccessibilityHit] { Array(hits.prefix(limit)) }
    func enableWebContent() -> [String] { [] }
    func restoreWebContentSwitches() -> [String] { [] }
}

func axHit(_ role: String, title: String = "", identifier: String = "", placeholder: String = "",
           frame: CGRect, app: String, window: String) -> AccessibilityHit {
    AccessibilityHit(
        node: AccessibilityNode(role: role, title: title, identifier: identifier, placeholder: placeholder, frame: frame),
        app: app, window: window)
}

@Suite(.serialized) struct EyesGateIntegrationTests {

    static let gate = SafetyGate(classifier: Classifiers(client: nil))

    static func judgeClick(_ hit: AccessibilityHit?, front: (app: String, window: String), delaySeconds: Double = 0) async
        -> (ScreenAction, Decision<Risk>)
    {
        let source = FakeAccessibilitySource(hits: hit.map { [$0] } ?? [], front: front, delaySeconds: delaySeconds)
        let labels = AccessibilityLabels(source: source, timeout: 0.1)
        let point = hit.map { CGPoint(x: $0.node.frame.midX, y: $0.node.frame.midY) } ?? CGPoint(x: 10, y: 10)
        let action = await labels.clickAction(at: point)
        return (action, await gate.check(action))
    }

    @Test("A labelled Send button is held by a fixed rule")
    func sendButton() async {
        let (action, decision) = await Self.judgeClick(
            axHit("AXButton", title: "Send", frame: CGRect(x: 1300, y: 850, width: 40, height: 40), app: "WhatsApp", window: "WhatsApp"),
            front: ("WhatsApp", "WhatsApp"))
        #expect(action.description == "Click button \"Send\" in WhatsApp, window \"WhatsApp\"")
        #expect(decision.label == .needsConfirmation)
        #expect(decision.source == .rule, "reason: \(decision.reason)")
    }

    @Test("An icon-only Send button named only by its identifier is held by a fixed rule")
    func identifierOnlySend() async {
        let (action, decision) = await Self.judgeClick(
            axHit("AXButton", identifier: "ChatBar_SendButton", frame: CGRect(x: 1300, y: 850, width: 40, height: 40),
                  app: "WhatsApp", window: "WhatsApp"),
            front: ("WhatsApp", "WhatsApp"))
        #expect(action.description.contains("identifier \"ChatBar_SendButton\""))
        #expect(decision.label == .needsConfirmation)
        #expect(decision.source == .rule, "reason: \(decision.reason)")
    }

    @Test("A search field is plainly safe by rule")
    func searchField() async {
        let (_, decision) = await Self.judgeClick(
            axHit("AXTextField", placeholder: "Search or start a new chat", frame: CGRect(x: 20, y: 80, width: 300, height: 30),
                  app: "WhatsApp", window: "WhatsApp"),
            front: ("WhatsApp", "WhatsApp"))
        #expect(decision.label == .safe && decision.source == .rule, "reason: \(decision.reason)")
    }

    @Test("Unlabelled or unknown targets are never safe", arguments: ["AXGroup", "AXImage", "AXLink", "AXButton"])
    func unlabelled(role: String) async {
        let (action, decision) = await Self.judgeClick(
            axHit(role, frame: CGRect(x: 600, y: 400, width: 50, height: 50), app: "Google Chrome", window: "Inbox - Gmail"),
            front: ("Google Chrome", "Inbox - Gmail"))
        #expect(action.description.contains("unlabelled"), "\(action.description)")
        #expect(decision.label == .needsConfirmation, "\(action.description): \(decision.reason)")
    }

    @Test("When the eyes time out, the click is held: unknown is never safe")
    func lookupTimeout() async {
        let (action, decision) = await Self.judgeClick(
            axHit("AXButton", title: "Archive", frame: CGRect(x: 600, y: 400, width: 50, height: 50), app: "Mail", window: "Inbox"),
            front: ("Mail", "Inbox"), delaySeconds: 1.0)
        #expect(action.isTargetUnknown, "a 1 s lookup with a 0.1 s timeout must give no target")
        #expect(decision.label == .needsConfirmation)
    }

    @Test("Return in a chat message box is held by a fixed rule; Return in a search field is not")
    func returnKey() async {
        let messageBox = axHit("AXTextArea", placeholder: "Type a message", frame: CGRect(x: 400, y: 850, width: 800, height: 40),
                               app: "WhatsApp", window: "WhatsApp")
        let search = axHit("AXTextField", placeholder: "Search", frame: CGRect(x: 20, y: 80, width: 300, height: 30),
                           app: "WhatsApp", window: "WhatsApp")
        for (hit, expectSafe) in [(messageBox, false), (search, true)] {
            let source = FakeAccessibilitySource(hits: [hit], focused: hit, front: ("WhatsApp", "WhatsApp"))
            let action = await AccessibilityLabels(source: source, timeout: 0.1).keyAction(KeyChord("return")!)
            let decision = await Self.gate.check(action)
            #expect(decision.label == (expectSafe ? .safe : .needsConfirmation), "\(action.description): \(decision.reason)")
            #expect(decision.source == .rule, "\(action.description): \(decision.reason)")
        }
    }

    @Test("Full chain with the real eyes' labels and the real gate: Send is held, the guests field is not")
    func fullChainWithRealLabelsAndGate() async throws {
        let window = InviteFlowExecutor.window
        let guests = axHit("AXTextField", placeholder: "Add guests", frame: CGRect(x: 300, y: 280, width: 200, height: 40),
                           app: "Google Chrome", window: window)
        let send = axHit("AXButton", title: "Send", frame: CGRect(x: 870, y: 105, width: 60, height: 30),
                         app: "Google Chrome", window: window)
        let labels = AccessibilityLabels(
            source: FakeAccessibilitySource(hits: [guests, send], focused: guests, front: ("Google Chrome", window)), timeout: 0.2)
        let classifiers = Classifiers(client: nil)
        let gate = RecordingGate(SafetyGate(classifier: classifiers))
        let model = ScriptedModel(turns: ScriptedModel.inviteFlow())
        let rig = Rig(gate: gate, classifier: classifiers) { hands in
            ScreenAgent(hands: hands, eyes: FakeEyes(), labels: labels, client: model,
                        configuration: ScreenAgentConfiguration(model: "claude-sonnet-5-5", settleSeconds: 0))
        }
        await rig.call("start_task", ["goal": .string(TaskFlowTests.goal)])
        _ = try #require(await rig.recorder.waitFor(.question, timeout: 5))
        await rig.call("answer_task", ["answer": "Priya Shah"])
        let confirmation = try #require(await rig.recorder.waitFor(.confirmation, timeout: 5))
        #expect(rig.recorder.events.filter { $0.kind == .confirmation }.count == 1, "only Send needs a yes")
        #expect(confirmation.text.hasPrefix("Send \"Priya Shah\""))
        await rig.call("answer_task", ["answer": "yes"])
        #expect(await rig.recorder.waitFor(.result, timeout: 5)?.status == .done)
        #expect(rig.hands.actions.items.filter { $0.hasPrefix("click") } == ["click 400,300", "click 900,120"])
        #expect(gate.asked.items.count == 2)
    }
}
