import Foundation
import Testing
@testable import HFUnderstand

@Suite struct TorgoManifestTests {
    /// A minimal valid WAV: 16 kHz mono 16-bit, `samples` samples of silence.
    static func wav(samples: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        data.append(Data(count: Int(bytes)))
        return data
    }

    /// Writes a fake TORGO folder and returns its root.
    static func makeTree(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torgo-\(UUID().uuidString)/raw")
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    @Test func twoSessionsSplitByEarliestSession() throws {
        let w = Self.wav(samples: 16_000)
        let root = try Self.makeTree([
            "F01/Session1/wav_arrayMic/0001.wav": w, "F01/Session1/prompts/0001.txt": Data("yes\n".utf8),
            "F01/Session1/wav_headMic/0001.wav": w,  // same utterance, other mic: must not appear twice
            "F01/Session1/wav_arrayMic/0002.wav": w, "F01/Session1/prompts/0002.txt": Data("[say Ah-P-eee repeatedly]".utf8),
            "F01/Session2_3/wav_arrayMic/0005.wav": w, "F01/Session2_3/prompts/0005.txt": Data("The quick brown fox".utf8),
            "F01/Session2_3/wav_arrayMic/0006.wav": w, "F01/Session2_3/prompts/0006.txt": Data("input/images/a.jpg".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let folder = root.deletingLastPathComponent()
        let manifest = try TorgoManifestBuilder.build(root: root, manifestFolder: folder)
        #expect(manifest.clips.map(\.id) == ["F01-S1-0001", "F01-S23-0005"])
        #expect(manifest.clips.map(\.split) == [.enrolment, .test])
        #expect(manifest.clips[0].audio == "raw/F01/Session1/wav_arrayMic/0001.wav")
        #expect(manifest.clips[0].kind == "word")
        #expect(manifest.clips[1].kind == "sentence")
        #expect(manifest.clips[0].seconds == 1.0)
        #expect(manifest.speakers == [.init(id: "F01", group: "dysarthric", condition: "cerebral palsy", severity: "severe",
                                            severitySource: TorgoManifestBuilder.severitySource)])
    }

    @Test func oneSessionSplitsInHalfAndHeadMicIsTheFallback() throws {
        let w = Self.wav(samples: 800)
        var files: [String: Data] = [:]
        for n in 1...4 {
            files["FC01/Session1/wav_headMic/000\(n).wav"] = w
            files["FC01/Session1/prompts/000\(n).txt"] = Data("word\(n)".utf8)
        }
        let root = try Self.makeTree(files)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let manifest = try TorgoManifestBuilder.build(root: root, manifestFolder: root.deletingLastPathComponent())
        #expect(manifest.clips.map(\.split) == [.enrolment, .enrolment, .test, .test])
        #expect(manifest.clips.allSatisfy { $0.audio.contains("wav_headMic") })
        #expect(manifest.speakers.first?.group == "control")
        #expect(manifest.speakers.first?.severity == "none")
    }

    @Test func truncatedWAVIsDropped() throws {
        let full = Self.wav(samples: 16_000)
        let root = try Self.makeTree([
            "M01/Session1/wav_arrayMic/0001.wav": full.prefix(full.count / 2),
            "M01/Session1/prompts/0001.txt": Data("yes".utf8),
        ])
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let manifest = try TorgoManifestBuilder.build(root: root, manifestFolder: root.deletingLastPathComponent())
        #expect(manifest.clips.isEmpty)
        #expect(manifest.speakers.isEmpty)
    }

    @Test func repeatedPromptFirstRecordingIsEnrolmentLaterOnesTest() {
        func clip(_ id: String, _ prompt: String) -> EvaluationManifest.Clip {
            .init(id: id, speaker: "M01", session: "S", prompt: prompt, audio: "\(id).wav", split: .test, kind: "word")
        }
        // Session 1: up, yes, menu. Session 2: Up., no, up.
        let result = TorgoManifestBuilder.split([
            [clip("a", "up"), clip("b", "yes"), clip("c", "menu")],
            [clip("d", "Up."), clip("e", "no"), clip("f", "up")],
        ])
        let splits = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.split) })
        #expect(splits == ["a": .enrolment, "b": .enrolment, "c": .enrolment, "d": .test, "e": .test, "f": .test])
        let repeated = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.repeatedLater) })
        #expect(repeated["a"] == true)
        #expect(repeated["b"] == false)
        #expect(result.first { $0.id == "d" }?.repeatedLater == nil)
    }

    @Test func repeatWithinOneSessionStillSplitsByTime() {
        func clip(_ id: String, _ prompt: String) -> EvaluationManifest.Clip {
            .init(id: id, speaker: "M01", session: "S", prompt: prompt, audio: "\(id).wav", split: .test, kind: "word")
        }
        // A later repeat in the first half still goes to test; once-only prompts split by half.
        let result = TorgoManifestBuilder.split([[clip("a", "yes"), clip("b", "yes"), clip("c", "one"), clip("d", "two"), clip("e", "three"), clip("f", "four")]])
        // Half is 3: "one" (position 2) is enrolment; "two" onwards are test.
        #expect(result.map(\.split) == [.enrolment, .test, .enrolment, .test, .test, .test])
    }

    @Test func cappedEnrolmentPrefersPromptsSaidAgain() {
        let clips: [EvaluationManifest.Clip] = [
            .init(id: "e1", speaker: "F01", session: "S1", prompt: "pat", audio: "e1.wav", split: .enrolment, kind: "word", repeatedLater: false),
            .init(id: "e2", speaker: "F01", session: "S1", prompt: "up", audio: "e2.wav", split: .enrolment, kind: "word", repeatedLater: true),
            .init(id: "t1", speaker: "F01", session: "S2", prompt: "up", audio: "t1.wav", split: .test, kind: "word"),
        ]
        let manifest = EvaluationManifest(name: "m", splitRule: "", speakers: [.init(id: "F01", group: "dysarthric")], clips: clips)
        let runner = EvaluationRunner(manifest: manifest, manifestFolder: URL(fileURLWithPath: "/tmp"), enrolmentLimit: 1,
                                      loadTurn: { _ in throw CancellationError() })
        #expect(runner.enrolmentClips(of: "F01").map(\.id) == ["e2"])
        #expect(runner.seenPrompts(of: "F01") == ["up"])
    }

    @Test func promptFilter() {
        #expect(TorgoManifestBuilder.isUsablePrompt("Yes"))
        #expect(TorgoManifestBuilder.isUsablePrompt("She had your dark suit in greasy wash water all year."))
        #expect(!TorgoManifestBuilder.isUsablePrompt("xxx"))
        #expect(!TorgoManifestBuilder.isUsablePrompt("[relax your mouth in its normal position]"))
        #expect(!TorgoManifestBuilder.isUsablePrompt("input/images/door.jpg"))
        #expect(!TorgoManifestBuilder.isUsablePrompt(""))
    }

    @Test func manifestRoundTrips() throws {
        let manifest = EvaluationRunnerTests.manifest()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try manifest.write(to: url)
        #expect(try EvaluationManifest.load(from: url) == manifest)
    }
}
