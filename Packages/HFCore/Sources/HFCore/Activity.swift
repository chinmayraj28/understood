import CoreGraphics
import Foundation

/// Everything the on-screen companion needs to show what the agent is doing.
/// The hands, the task runner and the voice session post these; the overlay
/// and the menu bar listen.
public enum ActivityEvent: Sendable, Equatable {
    // Asleep and waking
    /// No conversation is open. The Mac is listening, on the Mac only, for the wake phrase.
    case asleep(wakePhrase: String)
    /// The wake phrase was heard; a conversation is being opened.
    case waking

    // Voice
    case listening  // the microphone is open and the agent is waiting for speech
    case userSpeaking(level: Double)  // 0...1, for the waveform
    case userSaid(String)
    case agentSpeaking(String)
    case voiceDisconnected(reason: String)

    // Thinking
    case thinking(caption: String)  // the screen agent is deciding its next step

    // Hands
    case pointerMoving(to: CGPoint, duration: Double)
    case clicked(at: CGPoint)
    case typing
    case scrolled

    // Tasks
    case taskStarted(goal: String)
    case progress(String)
    case waitingForAnswer(question: String)
    case taskEnded(status: TaskStatus, summary: String)

    // Safety
    case heldForConfirmation(action: String)
    case halted  // the user said stop
}

/// A small broadcaster: anyone can post, and each listener gets every event in order.
public final class ActivityBus: @unchecked Sendable {
    public static let shared = ActivityBus()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ActivityEvent>.Continuation] = [:]

    public init() {}

    public func post(_ event: ActivityEvent) {
        lock.lock()
        let listeners = Array(continuations.values)
        lock.unlock()
        for listener in listeners { listener.yield(event) }
    }

    /// A stream of every event posted from now on. Ends when the consumer stops iterating.
    public func events() -> AsyncStream<ActivityEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }
}
