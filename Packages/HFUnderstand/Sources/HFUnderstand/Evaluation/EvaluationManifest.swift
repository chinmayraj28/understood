import Foundation

/// The list of recordings an evaluation runs over: who spoke, what they were asked to say, where
/// the audio is, and whether the clip is for enrolment (teaching the system this speaker) or for
/// testing. Stored as JSON next to the audio, in `eval/data/` (never in git).
///
/// The enrolment/test split is fixed in the manifest, before anything is run, so a result can never
/// come from a recording the system already saw. See `TorgoManifestBuilder` for the rule.
public struct EvaluationManifest: Codable, Sendable, Equatable {
    public var name: String
    /// The rule used to split enrolment from test clips, in plain words. Copied into every result.
    public var splitRule: String
    public var speakers: [Speaker]
    public var clips: [Clip]

    public struct Speaker: Codable, Sendable, Equatable {
        /// Such as "F01" (TORGO: F/M for women/men, C for control).
        public var id: String
        /// "dysarthric" or "control".
        public var group: String
        /// Such as "cerebral palsy", when known.
        public var condition: String?
        /// Such as "severe", "moderate", "mild", when known, with where it came from in `severitySource`.
        public var severity: String?
        public var severitySource: String?

        public init(id: String, group: String, condition: String? = nil, severity: String? = nil, severitySource: String? = nil) {
            self.id = id
            self.group = group
            self.condition = condition
            self.severity = severity
            self.severitySource = severitySource
        }
    }

    public enum Split: String, Codable, Sendable {
        /// Used only to teach the system this speaker: keyterms, Gemini examples, phrasebook.
        case enrolment
        /// Used only to measure.
        case test
    }

    public struct Clip: Codable, Sendable, Equatable {
        /// Unique, such as "F01-S1-0043".
        public var id: String
        public var speaker: String
        public var session: String
        /// What the speaker was asked to say: the reference text.
        public var prompt: String
        /// Path to the WAV file, relative to the manifest's folder.
        public var audio: String
        public var split: Split
        /// "word" (one word, such as "yes") or "sentence".
        public var kind: String
        public var seconds: Double?
        /// Enrolment clips only: true when the speaker says this prompt again later (in a test clip).
        /// Used to choose which enrolment clips to keep under a cost cap; see the split rule.
        public var repeatedLater: Bool?

        public init(id: String, speaker: String, session: String, prompt: String, audio: String, split: Split, kind: String, seconds: Double? = nil, repeatedLater: Bool? = nil) {
            self.repeatedLater = repeatedLater
            self.id = id
            self.speaker = speaker
            self.session = session
            self.prompt = prompt
            self.audio = audio
            self.split = split
            self.kind = kind
            self.seconds = seconds
        }
    }

    public init(name: String, splitRule: String, speakers: [Speaker], clips: [Clip]) {
        self.name = name
        self.splitRule = splitRule
        self.speakers = speakers
        self.clips = clips
    }

    public static func load(from url: URL) throws -> EvaluationManifest {
        try JSONDecoder().decode(EvaluationManifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    public func clips(of speaker: String, split: Split) -> [Clip] {
        clips.filter { $0.speaker == speaker && $0.split == split }
    }
}

/// Builds a manifest from an extracted TORGO folder (`F01/Session1/wav_arrayMic/0001.wav` with
/// `F01/Session1/prompts/0001.txt`).
///
/// Which clips are kept:
/// - Only prompts that are real words or sentences. Non-word tasks ("[say Ah-P-eee repeatedly]"),
///   picture descriptions (a path to an image) and "xxx" are dropped.
/// - One microphone per utterance: the array microphone, or the head microphone when a session has
///   no array recording. Both microphones record the same utterance, so using both would put the
///   same speech in enrolment and test.
/// - WAV files cut short (the end of a partial download) are dropped.
///
/// The split, per speaker, with clips in recording order (session, then utterance number):
/// - A prompt the speaker said two or more times: the first recording is enrolment, every later
///   recording is test. This is the "seen" case: a person's everyday command said again later.
/// - A prompt said once: with two or more sessions, enrolment if in the earliest session, else test;
///   with one session, enrolment if in the first half, else test. This gives the "unseen" case.
/// A recording is never in both; nothing later in time teaches anything earlier.
public enum TorgoManifestBuilder {
    public static let splitRule = """
        Per speaker, clips in recording order. A prompt said two or more times: its first recording is \
        enrolment, every later recording is test. A prompt said once: enrolment if in the earliest \
        session (one-session speakers: the first half), else test. One microphone per utterance \
        (array, else head), so no recording is in both splits. Non-word and picture-description \
        prompts are dropped. When enrolment is capped, enrolment clips of prompts the speaker says \
        again are used first (like the app's setup, where a person records their own everyday \
        phrases), then the rest in recording order. Test clips are "seen" when the same prompt text \
        (normalised) is among the enrolment clips used, else "unseen".
        """

    /// Severities as reported in the TORGO literature for these speakers (intelligibility from the
    /// Frenchay Dysarthria Assessment). Recorded here because the archives carry no severity field.
    static let reported: [String: (condition: String, severity: String)] = [
        "F01": ("cerebral palsy", "severe"),
        "F03": ("cerebral palsy", "moderate"),
        "F04": ("cerebral palsy", "mild"),
        "M01": ("cerebral palsy", "severe"),
        "M02": ("cerebral palsy", "severe"),
        "M03": ("cerebral palsy", "mild"),
        "M04": ("cerebral palsy", "severe"),
        "M05": ("cerebral palsy", "moderate to severe"),
    ]
    static let severitySource =
        "As reported in the TORGO literature (Rudzicz et al. 2012; per-speaker table in e.g. Joy & Umesh 2018); not re-assessed here."

    /// Scans `root` and writes audio paths relative to `manifestFolder`.
    public static func build(root: URL, manifestFolder: URL, name: String = "TORGO subset") throws -> EvaluationManifest {
        let fm = FileManager.default
        let speakerIDs = try fm.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") && isDirectory(root.appendingPathComponent($0)) }
            .sorted()

        var speakers: [EvaluationManifest.Speaker] = []
        var clips: [EvaluationManifest.Clip] = []

        for speakerID in speakerIDs {
            let speakerFolder = root.appendingPathComponent(speakerID)
            let sessions = try fm.contentsOfDirectory(atPath: speakerFolder.path)
                .filter { $0.hasPrefix("Session") && isDirectory(speakerFolder.appendingPathComponent($0)) }
                .sorted { sessionNumber($0) < sessionNumber($1) }

            var bySession: [(session: String, clips: [EvaluationManifest.Clip])] = []
            for session in sessions {
                let sessionClips = scanSession(
                    speaker: speakerID, session: session,
                    folder: speakerFolder.appendingPathComponent(session),
                    manifestFolder: manifestFolder)
                if !sessionClips.isEmpty { bySession.append((session, sessionClips)) }
            }
            if bySession.isEmpty { continue }
            clips += split(bySession.map(\.clips))

            let isControl = speakerID.dropFirst().hasPrefix("C")
            let known = reported[speakerID]
            speakers.append(.init(
                id: speakerID,
                group: isControl ? "control" : "dysarthric",
                condition: isControl ? nil : known?.condition,
                severity: isControl ? "none" : known?.severity,
                severitySource: known == nil ? nil : severitySource))
        }
        return EvaluationManifest(name: name, splitRule: splitRule, speakers: speakers, clips: clips)
    }

    /// Splits one speaker's clips (sessions in order, each in utterance order) by the rule above.
    public static func split(_ sessions: [[EvaluationManifest.Clip]]) -> [EvaluationManifest.Clip] {
        let ordered = sessions.flatMap { $0 }
        var counts: [String: Int] = [:]
        for clip in ordered { counts[WordErrorRate.normalise(clip.prompt), default: 0] += 1 }

        // Where the "said once" prompts switch from enrolment to test.
        let onceIsEnrolment: (Int, Int) -> Bool  // (session index, position within that session)
        if sessions.count >= 2 {
            onceIsEnrolment = { session, _ in session == 0 }
        } else {
            let half = sessions[0].count / 2
            onceIsEnrolment = { _, position in position < half }
        }

        var firstSeen = Set<String>()
        var result: [EvaluationManifest.Clip] = []
        for (sessionIndex, session) in sessions.enumerated() {
            for (position, clip) in session.enumerated() {
                var copy = clip
                let key = WordErrorRate.normalise(clip.prompt)
                if (counts[key] ?? 0) >= 2 {
                    let isFirst = firstSeen.insert(key).inserted
                    copy.split = isFirst ? .enrolment : .test
                    copy.repeatedLater = isFirst ? true : nil
                } else {
                    copy.split = onceIsEnrolment(sessionIndex, position) ? .enrolment : .test
                    copy.repeatedLater = copy.split == .enrolment ? false : nil
                }
                result.append(copy)
            }
        }
        return result
    }

    /// The usable clips of one session, in utterance-number order.
    static func scanSession(speaker: String, session: String, folder: URL, manifestFolder: URL) -> [EvaluationManifest.Clip] {
        let fm = FileManager.default
        let array = folder.appendingPathComponent("wav_arrayMic")
        let head = folder.appendingPathComponent("wav_headMic")
        let audioFolder = isDirectory(array) && !((try? fm.contentsOfDirectory(atPath: array.path)) ?? []).isEmpty ? array : head
        guard let names = try? fm.contentsOfDirectory(atPath: audioFolder.path) else { return [] }

        var result: [EvaluationManifest.Clip] = []
        for name in names.sorted() where name.lowercased().hasSuffix(".wav") {
            let utterance = String(name.dropLast(4))
            let promptURL = folder.appendingPathComponent("prompts/\(utterance).txt")
            guard let raw = try? String(contentsOf: promptURL, encoding: .utf8) ?? String(contentsOf: promptURL, encoding: .isoLatin1) else { continue }
            let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isUsablePrompt(prompt) else { continue }
            let wavURL = audioFolder.appendingPathComponent(name)
            guard let seconds = completeWAVSeconds(wavURL) else { continue }
            result.append(.init(
                id: "\(speaker)-S\(sessionNumber(session))-\(utterance)",
                speaker: speaker,
                session: session,
                prompt: prompt,
                audio: relativePath(of: wavURL, from: manifestFolder),
                split: .test,
                kind: WordErrorRate.words(prompt).count == 1 ? "word" : "sentence",
                seconds: seconds))
        }
        return result
    }

    /// Real words or sentences only.
    public static func isUsablePrompt(_ prompt: String) -> Bool {
        if prompt.isEmpty { return false }
        if prompt.contains("[") || prompt.contains("]") || prompt.contains("/") || prompt.contains("\\") { return false }
        let lower = prompt.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".png") { return false }
        let words = WordErrorRate.words(prompt)
        if words.isEmpty || words.allSatisfy({ $0 == "xxx" }) { return false }
        return true
    }

    /// The duration of a WAV file, or nil when the file is shorter than its header says (a
    /// download cut off part-way) or is not a WAV file.
    static func completeWAVSeconds(_ url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url), data.count >= 44 else { return nil }
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        guard data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return nil }
        if Int(u32(4)) + 8 > data.count { return nil }
        // Walk the chunks to find "fmt " and "data".
        var offset = 12
        var byteRate: UInt32 = 0
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            if id == "fmt " { byteRate = u32(offset + 16); _ = u16(offset + 8) }
            if id == "data" {
                guard byteRate > 0, offset + 8 + size <= data.count else { return nil }
                return Double(size) / Double(byteRate)
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    static func sessionNumber(_ session: String) -> Int {
        Int(session.filter(\.isNumber)) ?? 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func relativePath(of file: URL, from folder: URL) -> String {
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(filePath.count, folderPath.count), filePath[common] == folderPath[common] { common += 1 }
        let ups = Array(repeating: "..", count: folderPath.count - common)
        return (ups + filePath[common...]).joined(separator: "/")
    }
}
