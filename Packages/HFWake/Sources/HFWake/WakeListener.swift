import Foundation
import HFCore

/// Something the listener did, for the command-line tool and for logs.
///
/// None of these carries what was heard while asleep, except `.transcript`, which is only sent
/// when `revealTranscripts` is switched on (the command-line tool does that only while it is
/// playing its own test phrase).
public enum WakeDiagnostic: Sendable, Equatable {
    /// Listening started, with this recogniser.
    case started(recognizer: String)
    /// The phrase was seen in a transcript; waiting for the rest of the sentence. `heardAs` is
    /// the configured phrase, or, only when `revealTranscripts` is on, the words taken as it.
    case phraseHeard(heardAs: String)
    /// The recogniser finished an utterance that had words in it but not the phrase. Carries
    /// nothing of what was said, so the app can tell "it can't hear me" from "it heard me but
    /// not the phrase" without keeping anyone's words.
    case speechWithoutPhrase
    /// Woke. Times are seconds from the phrase first being seen, and from the last new words.
    case woke(restOfSentence: String, afterPhraseSeen: Double, afterLastWords: Double)
    /// The microphone or recogniser stopped by itself and listening is being restarted.
    case restarting(reason: String)
    /// Listening could not be restarted; it will try again after `retryInSeconds`.
    case restartFailed(SpeakableError, retryInSeconds: Double)
    /// What the recogniser wrote. Only when `revealTranscripts` is on.
    case transcript(String, isFinal: Bool)
}

/// Listens on the Mac for the wake phrase, with Apple's on-device speech recognition.
///
/// While it runs, the microphone is open but no audio leaves the laptop: recognition happens on
/// the device (SpeechAnalyzer on macOS 26, or the older recogniser forced on-device), and if
/// on-device recognition is not available `start` fails instead of using Apple's servers.
///
/// It wakes once per `start`: after `onWake` it stays quiet until the caller calls `stop()`, hands
/// the microphone to the conversation, and calls `start` again when the conversation ends.
public final class WakeListener: WakeListening, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// The main phrase, e.g. "Hey Handsfree".
        public var phrase: String
        /// Other phrases that also wake it.
        public var alternatives: [String]
        public var strictness: WakeStrictness
        public var timing: WakeTiming
        /// The language to recognise. Defaults to the Mac's own.
        public var locale: Locale
        public var recognizer: WakeRecognizer
        /// When a permission has never been asked for, ask (the system shows a prompt) instead of
        /// failing with a message. The first-run flow wants this; a background restart does not.
        public var requestPermissions: Bool

        public init(
            phrase: String = "Hey Handsfree",
            alternatives: [String] = [],
            strictness: WakeStrictness = .balanced,
            timing: WakeTiming = WakeTiming(),
            locale: Locale = .current,
            recognizer: WakeRecognizer = .automatic,
            requestPermissions: Bool = false
        ) {
            self.phrase = phrase
            self.alternatives = alternatives
            self.strictness = strictness
            self.timing = timing
            self.locale = locale
            self.recognizer = recognizer
            self.requestPermissions = requestPermissions
        }

        /// The phrase from `Settings.wakePhrase`, everything else at its default.
        public init(settings: Settings) {
            self.init(phrase: settings.wakePhrase)
        }

        /// Words the recogniser is told to expect, so the name is written as one word.
        /// For "Hey Handsfree": "Hey Handsfree" and "Handsfree".
        var contextualStrings: [String] {
            var strings: [String] = []
            for phrase in [phrase] + alternatives {
                strings.append(phrase)
                for word in phrase.split(separator: " ")
                where !WakePhraseMatcher.greetings.contains(WakePhraseMatcher.normalize(String(word))) {
                    strings.append(String(word))
                }
            }
            var seen = Set<String>()
            return strings.filter { seen.insert($0.lowercased()).inserted }
        }
    }

    public let configuration: Configuration
    /// Called with what the listener is doing. Set it before `start`.
    public var onDiagnostic: (@Sendable (WakeDiagnostic) -> Void)? {
        get { lock.withLock { diagnosticHandler } }
        set { lock.withLock { diagnosticHandler = newValue } }
    }
    /// Sends what the recogniser writes as `.transcript` diagnostics. Off by default and never on
    /// in the app: what is heard while asleep is not printed or stored. The command-line tool
    /// switches it on only while it plays its own test phrase.
    public var revealTranscripts: Bool {
        get { lock.withLock { reveal } }
        set { lock.withLock { reveal = newValue } }
    }

    private let makeSource: () throws -> TranscriptSource
    private let now: @Sendable () -> Double
    private let queue = DispatchQueue(label: "com.handsfree.wake.listener")
    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var source: TranscriptSource?
    private var detector: WakeDetector
    private var wanted = false
    private var running = false
    private var generation = 0
    private var onWake: (@Sendable (String) -> Void)?
    private var deadline: DispatchWorkItem?
    private var restartTask: Task<Void, Never>?
    /// The generation whose restart is in progress, so only one runs per generation.
    private var restartingGeneration: Int?
    private var diagnosticHandler: (@Sendable (WakeDiagnostic) -> Void)?
    private var reveal = false
    private var phraseAnnounced = false
    /// start() and stop() run one at a time, in the order they were called.
    private var lastOperation: Task<Void, Never>?

    /// The real listener, on the Mac's microphone.
    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration) {
            let engine = try RecognitionEngines.make(
                configuration.recognizer, locale: configuration.locale,
                contextualStrings: configuration.contextualStrings)
            return StreamingTranscriber(
                input: MicrophoneInput(), engine: engine, requestPermission: configuration.requestPermissions)
        }
    }

    /// For tests: any transcript source, any clock.
    init(
        configuration: Configuration,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        makeSource: @escaping () throws -> TranscriptSource
    ) {
        self.configuration = configuration
        self.makeSource = makeSource
        self.now = now
        self.detector = WakeDetector(
            matcher: WakePhraseMatcher(
                phrase: configuration.phrase, alternatives: configuration.alternatives,
                strictness: configuration.strictness),
            timing: configuration.timing)
    }

    /// True while the microphone is open and the recogniser is running.
    public var isListening: Bool { lock.withLock { running } }

    public func start(onWake: @escaping @Sendable (String) -> Void) async throws {
        try await serialized { try await self.performStart(onWake: onWake) }
    }

    public func stop() async {
        try? await serialized { await self.performStop() }
    }

    // MARK: Start and stop

    private func performStart(onWake: @escaping @Sendable (String) -> Void) async throws {
        if lock.withLock({ wanted }) { await performStop() }
        let source = try makeSource()
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            self.wanted = true
            self.onWake = onWake
            self.source = source
            self.detector.reset()
            self.phraseAnnounced = false
            return self.generation
        }
        do {
            try await startSource(source, generation: generation)
        } catch {
            lock.withLock {
                if self.generation == generation {
                    wanted = false
                    self.source = nil
                    self.onWake = nil
                }
            }
            throw Self.speakable(error)
        }
        diagnose(.started(recognizer: source.name))
    }

    /// Starts the source for this generation. Returns false, with the source stopped again, when
    /// the listener was stopped while it was starting: the microphone must not stay open then.
    @discardableResult
    private func startSource(_ source: TranscriptSource, generation: Int) async throws -> Bool {
        try await source.start(
            onUpdate: { [weak self] update in
                self?.queue.async { self?.handle(update, generation: generation) }
            },
            onInterrupted: { [weak self] reason in
                self?.queue.async { self?.restart(reason: reason, generation: generation) }
            })
        let stillWanted = lock.withLock { () -> Bool in
            guard self.generation == generation, wanted else { return false }
            running = true
            return true
        }
        if !stillWanted { await source.stop() }
        return stillWanted
    }

    private func performStop() async {
        let (source, restart) = lock.withLock { () -> (TranscriptSource?, Task<Void, Never>?) in
            generation += 1
            wanted = false
            running = false
            onWake = nil
            deadline?.cancel()
            deadline = nil
            let source = self.source
            self.source = nil
            let restart = restartTask
            restartTask = nil
            return (source, restart)
        }
        // Wait for a restart in progress to give up, so it cannot open the microphone after we
        // have closed it, and so the source is never started and stopped at the same time.
        restart?.cancel()
        await restart?.value
        await source?.stop()
    }

    private func serialized(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        // Read the previous operation and register this one in one step, so two callers can
        // never both follow the same predecessor and then run at the same time.
        let task: Task<Void, Error> = lock.withLock {
            let previous = lastOperation
            let task = Task {
                await previous?.value
                try await operation()
            }
            lastOperation = Task { _ = try? await task.value }
            return task
        }
        try await task.value
    }

    // MARK: Transcripts, on `queue`

    private func handle(_ update: TranscriptUpdate, generation: Int) {
        let (wake, reveal, announce, noPhrase): (WakeDetector.Wake?, Bool, String?, Bool) = lock.withLock {
            guard self.generation == generation, wanted else { return (nil, false, nil, false) }
            let wasWoken = detector.hasWoken
            let wake = detector.receive(update, at: now())
            var announce: String?
            if detector.isWaitingForRestOfSentence, !phraseAnnounced {
                phraseAnnounced = true
                announce = self.reveal ? (detector.matcher.match(update.text)?.heardAs ?? configuration.phrase) : configuration.phrase
            }
            // A finished utterance with words, and no phrase in it or waiting on it.
            let noPhrase =
                update.isFinal && wake == nil && !wasWoken && !detector.hasWoken
                && !detector.isWaitingForRestOfSentence
                && update.text.contains(where: { $0.isLetter || $0.isNumber })
            scheduleDeadline(generation: generation)
            return (wake, self.reveal, announce, noPhrase)
        }
        if reveal { diagnose(.transcript(update.text, isFinal: update.isFinal)) }
        if let announce { diagnose(.phraseHeard(heardAs: announce)) }
        if noPhrase { diagnose(.speechWithoutPhrase) }
        if let wake { deliver(wake, generation: generation) }
    }

    /// Wakes up the detector when its next deadline passes, so a bare phrase wakes without
    /// waiting for another transcript. Called with `lock` held.
    private func scheduleDeadline(generation: Int) {
        deadline?.cancel()
        deadline = nil
        guard let next = detector.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in self?.deadlinePassed(generation: generation) }
        deadline = item
        queue.asyncAfter(deadline: .now() + max(0, next - now()) + 0.01, execute: item)
    }

    private func deadlinePassed(generation: Int) {
        let wake: WakeDetector.Wake? = lock.withLock {
            guard self.generation == generation, wanted else { return nil }
            let wake = detector.check(at: now())
            scheduleDeadline(generation: generation)
            return wake
        }
        if let wake { deliver(wake, generation: generation) }
    }

    private func deliver(_ wake: WakeDetector.Wake, generation: Int) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard self.generation == generation else { return nil }
            deadline?.cancel()
            deadline = nil
            return onWake
        }
        guard let handler else { return }
        let time = now()
        diagnose(.woke(
            restOfSentence: wake.restOfSentence,
            afterPhraseSeen: time - wake.phraseFirstHeardAt,
            afterLastWords: time - wake.lastWordsAt))
        handler(wake.restOfSentence)
    }

    // MARK: Restarting after the microphone or recogniser stops

    private func restart(reason: String, generation: Int) {
        let source: TranscriptSource? = lock.withLock {
            guard self.generation == generation, wanted, restartingGeneration != generation else { return nil }
            restartingGeneration = generation
            running = false
            // The new session numbers its segments afresh, so a half-heard phrase from before
            // the restart must not be compared with them. A wake already given stays given.
            if !detector.hasWoken {
                detector.reset()
                phraseAnnounced = false
                deadline?.cancel()
                deadline = nil
            }
            return self.source
        }
        guard let source else { return }
        diagnose(.restarting(reason: reason))
        let task = Task { [weak self] in
            defer {
                self?.lock.withLock { if self?.restartingGeneration == generation { self?.restartingGeneration = nil } }
            }
            await source.stop()
            var delay = 0.5
            while !Task.isCancelled {
                guard let self, self.lock.withLock({ self.generation == generation && self.wanted }) else { return }
                do {
                    guard try await self.startSource(source, generation: generation) else { return }
                    self.diagnose(.started(recognizer: source.name))
                    return
                } catch {
                    self.diagnose(.restartFailed(Self.speakable(error), retryInSeconds: delay))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, 30)
                }
            }
        }
        lock.withLock { restartTask = task }
    }

    private func diagnose(_ diagnostic: WakeDiagnostic) {
        lock.withLock { diagnosticHandler }?(diagnostic)
    }

    static func speakable(_ error: Error) -> SpeakableError {
        error as? SpeakableError ?? SpeakableError("I couldn't start listening for the wake phrase.")
    }
}
