import Foundation
import HFCore
import HFVoice  // deliberately not @testable: this file uses only what other packages can see
import Testing

/// A fake of the ElevenLabs SDK built from the public API alone, as another package would.
@MainActor
private final class OutsideFake: ConversationDriving {
    var sent: [String] = []
    func start(_ start: ConversationStart, onSignal: @escaping @MainActor @Sendable (ConversationSignal) -> Void) async throws {}
    func sendUserMessage(_ text: String) async throws { sent.append(text) }
    func sendContext(_ text: String) async throws {}
    func sendToolResult(callID: String, text: String, isError: Bool) async throws {}
    func end() async {}
}

@Suite @MainActor struct PublicSeamTests {
    @Test func anotherPackageCanFakeTheSDK() async {
        let fake = OutsideFake()
        let session = VoiceSession(
            agentID: "agent_1", mode: .text, bus: ActivityBus(), tuning: VoiceSession.Tuning(),
            makeDriver: { fake }, clock: { ProcessInfo.processInfo.systemUptime },
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) }, syncAgent: nil)
        await session.start(tools: [], memorySummary: "")
        #expect(session.isConnected)
        try? await session.sendText("Hello.")
        #expect(fake.sent == ["Hello."])
        await session.stop()
    }
}
