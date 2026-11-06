import AVFoundation
import Foundation
import HFCore

@testable import HFWake

/// Waits (in real time, briefly) until `condition` holds. For letting actors and tasks catch up.
func eventually(timeout: Double = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Lets queued tasks run.
func settle() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// A box with a lock, for values changed from several tasks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// A clock that only moves when the test moves it. `sleep` suspends until the clock passes the
/// deadline.
final class ManualClock: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var time: Double = 1000
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var cancelledBeforeWaiting: Set<Int> = []

    var now: Double { lock.withLock { time } }

    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if cancelledBeforeWaiting.remove(id) != nil { return true }
                    waiters.append(Waiter(id: id, deadline: time + seconds, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> Waiter? in
                if let index = waiters.firstIndex(where: { $0.id == id }) { return waiters.remove(at: index) }
                cancelledBeforeWaiting.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward in small steps, waking sleepers as their deadlines pass.
    func advance(by seconds: Double, step: Double = 0.25) async {
        let target = now + seconds
        while now < target - 1e-9 {
            let due = lock.withLock { () -> [Waiter] in
                time = min(time + step, target)
                let due = waiters.filter { $0.deadline <= time + 1e-9 }
                waiters.removeAll { $0.deadline <= time + 1e-9 }
                return due
            }
            for waiter in due { waiter.continuation.resume() }
            // Let the woken tasks run before time moves again. Only needed when someone woke.
            if due.isEmpty {
                await Task.yield()
            } else {
                await settle()
            }
        }
    }
}

/// A wake listener that wakes when the test says so.
final class FakeWakeListener: WakeListening, @unchecked Sendable {
    let starts = Locked(0)
    let stops = Locked(0)
    /// Each start pops one error from the front; an empty list means start succeeds.
    let startErrors = Locked<[Error]>([])
    let listening = Locked(false)
    private let handler = Locked<(@Sendable (String) -> Void)?>(nil)

    func start(onWake: @escaping @Sendable (String) -> Void) async throws {
        starts.update { $0 += 1 }
        var error: Error?
        startErrors.update { errors in if !errors.isEmpty { error = errors.removeFirst() } }
        if let error { throw error }
        handler.value = onWake
        listening.value = true
    }

    /// Real seconds that stop() takes, to widen race windows.
    let stopDelay = Locked(0.0)

    func stop() async {
        stops.update { $0 += 1 }
        handler.value = nil
        listening.value = false
        if stopDelay.value > 0 { try? await Task.sleep(nanoseconds: UInt64(stopDelay.value * 1_000_000_000)) }
    }

    var isListening: Bool { listening.value }

    /// The user said the phrase, then `rest`.
    func hear(_ rest: String) { handler.value?(rest) }
}

/// Collects everything posted to a bus.
final class BusRecorder: @unchecked Sendable {
    let events = Locked<[ActivityEvent]>([])
    private var task: Task<Void, Never>?
    init(_ bus: ActivityBus) {
        let stream = bus.events()
        task = Task { [events] in
            for await event in stream { events.update { $0.append(event) } }
        }
    }
    deinit { task?.cancel() }
}

/// A transcript source driven by the test.
final class FakeTranscriptSource: TranscriptSource, @unchecked Sendable {
    let name = "fake recogniser"
    let starts = Locked(0)
    let stops = Locked(0)
    let startErrors = Locked<[Error]>([])
    private let callbacks = Locked<(update: @Sendable (TranscriptUpdate) -> Void, interrupted: @Sendable (String) -> Void)?>(nil)

    func start(
        onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) async throws {
        starts.update { $0 += 1 }
        var error: Error?
        startErrors.update { errors in if !errors.isEmpty { error = errors.removeFirst() } }
        if let error { throw error }
        // Like the real one: the microphone is opened before start returns.
        callbacks.value = (onUpdate, onInterrupted)
        if startDelay.value > 0 { try? await Task.sleep(nanoseconds: UInt64(startDelay.value * 1_000_000_000)) }
    }

    /// Real seconds that start() takes after opening, to widen race windows.
    let startDelay = Locked(0.0)

    func stop() async {
        stops.update { $0 += 1 }
        callbacks.value = nil
    }

    var isRunning: Bool { callbacks.value != nil }

    func say(_ text: String, segment: Int = 1, final: Bool = false) {
        callbacks.value?.update(TranscriptUpdate(segment: segment, text: text, isFinal: final))
    }

    func interrupt(_ reason: String = "recognition timed out") { callbacks.value?.interrupted(reason) }
}

// MARK: Fakes for the streaming transcriber

let testFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

func testBuffer(marker: Float) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: testFormat, frameCapacity: 160)!
    buffer.frameLength = 160
    buffer.floatChannelData![0][0] = marker
    return buffer
}

final class FakeAudioInput: AudioInput, @unchecked Sendable {
    let prepares = Locked(0)
    let stops = Locked(0)
    let running = Locked(false)
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onInterrupted: ((String) -> Void)?
    let permissionError = Locked<Error?>(nil)

    func checkPermission(request: Bool) async throws {
        if let error = permissionError.value { throw error }
    }

    func prepare() throws -> AVAudioFormat {
        prepares.update { $0 += 1 }
        return testFormat
    }
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onInterrupted: @escaping (String) -> Void) throws {
        self.onBuffer = onBuffer
        self.onInterrupted = onInterrupted
        running.value = true
    }
    func stop() {
        stops.update { $0 += 1 }
        running.value = false
        onBuffer = nil
    }
    func deliver(marker: Float) { onBuffer?(testBuffer(marker: marker)) }
}

final class FakeRecognitionSession: RecognitionSession, @unchecked Sendable {
    let index: Int
    let callbacks: RecognitionCallbacks
    let received = Locked<[Float]>([])
    let cancelled = Locked(false)
    init(index: Int, callbacks: RecognitionCallbacks) {
        self.index = index
        self.callbacks = callbacks
    }
    func append(_ buffer: AVAudioPCMBuffer) { received.update { $0.append(buffer.floatChannelData![0][0]) } }
    func cancel() async { cancelled.value = true }
    /// The recogniser timing out or finishing by itself.
    func end(error: Error? = nil) { callbacks.onEnded(error) }
    func transcript(_ text: String, segment: Int = 0, final: Bool = false) {
        callbacks.onTranscript(segment, text, final)
    }
}

final class FakeRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let name = "fake engine"
    let preferredSessionSeconds: Double
    let sessions = Locked<[FakeRecognitionSession]>([])
    let prepareError = Locked<Error?>(nil)
    init(preferredSessionSeconds: Double = 600) { self.preferredSessionSeconds = preferredSessionSeconds }
    func prepare(requestPermission: Bool) async throws {
        if let error = prepareError.value { throw error }
    }
    /// Real seconds that making a session takes.
    let makeDelay = Locked(0.0)

    func makeSession(inputFormat: AVAudioFormat, callbacks: RecognitionCallbacks) async throws -> RecognitionSession {
        if makeDelay.value > 0 { try? await Task.sleep(nanoseconds: UInt64(makeDelay.value * 1_000_000_000)) }
        let session = FakeRecognitionSession(index: sessions.value.count, callbacks: callbacks)
        sessions.update { $0.append(session) }
        return session
    }
}
