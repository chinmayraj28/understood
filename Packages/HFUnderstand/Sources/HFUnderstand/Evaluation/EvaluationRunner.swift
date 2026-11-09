import Foundation
import HFCore

/// One configuration of the understanding layer to measure, such as "Scribe alone" or
/// "+ phrasebook". The runner builds a fresh one for every speaker, so nothing learned from one
/// speaker can help another.
public struct EvaluationSetup: Sendable {
    public var name: String
    /// One line on what this setup adds, for the report.
    public var summary: String
    /// Builds the layer for one speaker. `enrolment` holds only that speaker's enrolment clips
    /// (never test clips); the setup decides what to do with them (keyterms, examples, learning).
    public var make: @Sendable (_ speaker: String, _ enrolment: [EnrolmentClip]) async -> any Understanding

    public init(name: String, summary: String, make: @escaping @Sendable (String, [EnrolmentClip]) async -> any Understanding) {
        self.name = name
        self.summary = summary
        self.make = make
    }
}

/// An enrolment recording with what the speaker was asked to say.
public struct EnrolmentClip: Sendable {
    public var turn: RecordedTurn
    public var prompt: String

    public init(turn: RecordedTurn, prompt: String) {
        self.turn = turn
        self.prompt = prompt
    }
}

/// Everything recorded about one test clip under one setup.
public struct ClipRecord: Codable, Sendable, Equatable {
    public var setup: String
    public var clip: String
    public var speaker: String
    public var kind: String
    /// True when the same prompt (normalised) was among this speaker's enrolment clips.
    public var promptSeen: Bool
    public var prompt: String
    public var hypotheses: [Hypothesis]
    public var phrasebookMatch: PhrasebookMatch?
    public var reading: Reading?
    /// "act", "confirm", "choose", "askAgain" or "cannotHear".
    public var decision: String
    /// The text that would go to the agent (act), or be offered (confirm, choose), or the reading.
    public var finalText: String
    public var seconds: Double
    /// True when the whole clip ran past the runner's time cap (a stalled network call). It is
    /// then scored as "cannot hear": never as right, never as an action.
    public var timedOut: Bool?
}

/// Runs setups over a manifest's test clips and records what happened to each one.
public struct EvaluationRunner: Sendable {
    public var manifest: EvaluationManifest
    /// The manifest's folder; clip audio paths are relative to it.
    public var manifestFolder: URL
    /// Turns a WAV file into a recorded turn (the real one is `WAV.load(contentsOf:)`).
    public var loadTurn: @Sendable (URL) throws -> RecordedTurn
    /// Most enrolment clips used per speaker (cost limit). Nil uses them all.
    public var enrolmentLimit: Int?
    /// Most seconds one clip may take, all stages together. Past it the clip is scored as
    /// "cannot hear" and the run moves on, so a stalled call cannot hang the evaluation.
    public var clipTimeLimitSeconds: Double
    /// Called with one line per clip, for progress on the command line.
    public var log: @Sendable (String) -> Void

    public init(
        manifest: EvaluationManifest,
        manifestFolder: URL,
        enrolmentLimit: Int? = nil,
        clipTimeLimitSeconds: Double = 30,
        loadTurn: @escaping @Sendable (URL) throws -> RecordedTurn,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.manifest = manifest
        self.manifestFolder = manifestFolder
        self.enrolmentLimit = enrolmentLimit
        self.clipTimeLimitSeconds = clipTimeLimitSeconds
        self.loadTurn = loadTurn
        self.log = log
    }

    /// The enrolment clips used for a speaker, up to `enrolmentLimit`: clips of prompts the speaker
    /// says again first (the person's everyday phrases), then the rest, each in recording order.
    public func enrolmentClips(of speaker: String) -> [EvaluationManifest.Clip] {
        let all = manifest.clips(of: speaker, split: .enrolment)
        guard let limit = enrolmentLimit else { return all }
        let repeated = all.filter { $0.repeatedLater == true }
        let rest = all.filter { $0.repeatedLater != true }
        return Array((repeated + rest).prefix(limit))
    }

    /// Picks up to `limit` test clips spread evenly across speakers (taking turns), and within a
    /// speaker alternating "seen" and "unseen" prompts, so a small run still covers both cases.
    /// Deterministic: the same manifest and limit always give the same clips.
    public func selectTestClips(limit: Int?, speakers: [String]? = nil) -> [EvaluationManifest.Clip] {
        let ids = speakers ?? manifest.speakers.map(\.id)
        var queues: [[EvaluationManifest.Clip]] = ids.map { speaker in
            let seen = seenPrompts(of: speaker)
            let tests = manifest.clips(of: speaker, split: .test)
            let a = tests.filter { seen.contains(WordErrorRate.normalise($0.prompt)) }
            let b = tests.filter { !seen.contains(WordErrorRate.normalise($0.prompt)) }
            var mixed: [EvaluationManifest.Clip] = []
            for index in 0..<max(a.count, b.count) {
                if index < a.count { mixed.append(a[index]) }
                if index < b.count { mixed.append(b[index]) }
            }
            return mixed
        }
        var picked: [EvaluationManifest.Clip] = []
        let cap = limit ?? Int.max
        while picked.count < cap, queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices where !queues[index].isEmpty && picked.count < cap {
                picked.append(queues[index].removeFirst())
            }
        }
        return picked
    }

    /// The normalised prompts in the enrolment clips actually used for a speaker.
    public func seenPrompts(of speaker: String) -> Set<String> {
        Set(enrolmentClips(of: speaker).map { WordErrorRate.normalise($0.prompt) })
    }

    /// Runs every setup over the given test clips. Clips run one at a time so the seconds are
    /// honest. A clip whose audio cannot be read is skipped and logged.
    public func run(setups: [EvaluationSetup], testClips: [EvaluationManifest.Clip]) async -> [ClipRecord] {
        let speakers = orderedUnique(testClips.map(\.speaker))
        var records: [ClipRecord] = []
        for setup in setups {
            for speaker in speakers {
                let enrolment = enrolmentClips(of: speaker).compactMap { clip -> EnrolmentClip? in
                    guard let turn = load(clip) else { return nil }
                    return EnrolmentClip(turn: turn, prompt: clip.prompt)
                }
                let understanding = await setup.make(speaker, enrolment)
                let seen = seenPrompts(of: speaker)
                for clip in testClips where clip.speaker == speaker {
                    guard let turn = load(clip) else { continue }
                    let result = await Self.understand(turn, with: understanding, limit: clipTimeLimitSeconds)
                    var record = Self.record(setup: setup.name, clip: clip, seen: seen, result: result ?? Self.timedOutResult(clipTimeLimitSeconds))
                    if result == nil { record.timedOut = true }
                    log("[\(setup.name)] \(clip.id) \"\(clip.prompt)\" -> \(record.decision): \"\(record.finalText)\" (\(String(format: "%.1f", record.seconds)) s)")
                    records.append(record)
                }
            }
        }
        return records
    }

    /// Feeds enrolment clips through a layer the way the app would: hear each one, then record
    /// that the person confirmed what they were asked to say. Setups that learn call this.
    public static func enrol(_ understanding: any Understanding, with clips: [EnrolmentClip], limit: Double = 30) async {
        for clip in clips {
            guard let result = await understand(clip.turn, with: understanding, limit: limit) else { continue }
            await understanding.learn(from: clip.turn, result: result, outcome: .confirmed(meant: clip.prompt))
        }
    }

    /// Distinct enrolment prompts, most frequent first: the keyterms a setup may pass on.
    public static func keyterms(from clips: [EnrolmentClip], limit: Int = 200) -> [String] {
        var counts: [String: (count: Int, first: Int, text: String)] = [:]
        for (index, clip) in clips.enumerated() {
            let key = WordErrorRate.normalise(clip.prompt)
            guard !key.isEmpty else { continue }
            let existing = counts[key]
            counts[key] = ((existing?.count ?? 0) + 1, existing?.first ?? index, existing?.text ?? clip.prompt)
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.first < $1.first }
            .prefix(limit)
            .map(\.text)
    }

    /// Runs one turn, or gives up after `limit` seconds and returns nil. The work is cancelled but
    /// not waited for: a call stuck in the network must not hold up the run.
    public static func understand(_ turn: RecordedTurn, with understanding: any Understanding, limit: Double) async -> UnderstandingResult? {
        let once = FirstAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UnderstandingResult?, Never>) in
            let work = Task {
                let result = await understanding.understand(turn, context: UnderstandingContext())
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func timedOutResult(_ limit: Double) -> UnderstandingResult {
        UnderstandingResult(
            hypotheses: [], phrasebookMatch: nil, reading: nil,
            decision: .cannotHear(message: "Timed out after \(Int(limit)) s"), seconds: limit)
    }

    static func record(setup: String, clip: EvaluationManifest.Clip, seen: Set<String>, result: UnderstandingResult) -> ClipRecord {
        let decision: String
        let finalText: String
        switch result.decision {
        case .act(let text): decision = "act"; finalText = text
        case .confirm(_, let reading): decision = "confirm"; finalText = reading
        case .choose(_, let options): decision = "choose"; finalText = result.reading?.text ?? options.first ?? ""
        case .askAgain: decision = "askAgain"; finalText = result.reading?.text ?? ""
        case .cannotHear: decision = "cannotHear"; finalText = result.reading?.text ?? ""
        }
        return ClipRecord(
            setup: setup, clip: clip.id, speaker: clip.speaker, kind: clip.kind,
            promptSeen: seen.contains(WordErrorRate.normalise(clip.prompt)),
            prompt: clip.prompt, hypotheses: result.hypotheses, phrasebookMatch: result.phrasebookMatch,
            reading: result.reading, decision: decision, finalText: finalText, seconds: result.seconds, timedOut: nil)
    }

    private func load(_ clip: EvaluationManifest.Clip) -> RecordedTurn? {
        let url = manifestFolder.appendingPathComponent(clip.audio)
        do { return try loadTurn(url) } catch {
            log("skipped \(clip.id): cannot read \(clip.audio) (\(error))")
            return nil
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Lets exactly one of two racing tasks give the answer.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.withLock {
            if taken { return false }
            taken = true
            return true
        }
    }
}
