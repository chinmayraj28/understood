import Foundation
import HFCore
import Testing

@testable import HFUnderstand

/// A clock the test can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(days: Double) { lock.lock(); current += days * 86_400; lock.unlock() }
}

@Suite("Phrasebook")
struct PhrasebookTests {
    @Test func addingTheSamePairCountsConfirmations() throws {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, source: .confirmation)
        try book.add(heard: "Call some.", meant: "call sam", hearer: .scribe, source: .confirmation)
        try book.add(heard: "call some", meant: "call Sam", hearer: .apple, source: .confirmation)
        #expect(book.count == 2)
        let scribe = try #require(try book.entries().first { $0.hearer == .scribe })
        #expect(scribe.timesConfirmed == 2)
    }

    @Test func emptyTextIsNotStored() throws {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "  ", meant: "call Sam", hearer: .scribe, source: .confirmation)
        try book.add(heard: "call some", meant: "...", hearer: .scribe, source: .confirmation)
        #expect(book.count == 0)
    }

    @Test func exactAndSoundAlikeTranscriptsMatch() throws {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, source: .correction)
        let exact = try #require(book.bestMatch(for: ["Call some!"]))
        #expect(exact.meant == "call Sam" && exact.similarity == 1)
        let soundAlike = try #require(book.bestMatch(for: ["open spotify", "call sum"]))
        #expect(soundAlike.meant == "call Sam")
        #expect(soundAlike.similarity < Decider.strongMatchSimilarity)  // a hint, never strong on its own
        #expect(book.bestMatch(for: ["open spotify"]) == nil)
        #expect(book.bestMatch(for: ["", " "]) == nil)
    }

    @Test func recentPairsBeatOldOnes() throws {
        let clock = TestClock()
        let book = try Phrasebook.inMemory(now: { clock.now })
        try book.add(heard: "message mom", meant: "message Mum", hearer: .scribe, source: .confirmation)
        clock.advance(days: 90)
        try book.add(heard: "message mom", meant: "message Tom", hearer: .gemini, source: .confirmation)
        #expect(book.bestMatch(for: ["message mom"])?.meant == "message Tom")
    }

    @Test func oldConfirmationsCountForLess() throws {
        let clock = TestClock()
        let book = try Phrasebook.inMemory(now: { clock.now })
        for _ in 0..<4 { try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, source: .confirmation) }
        #expect(book.bestMatch(for: ["call some"])?.timesConfirmed == 4)
        clock.advance(days: 60)  // two half-lives
        #expect(book.bestMatch(for: ["call some"])?.timesConfirmed == 1)
    }

    @Test func examplesPreferHardRecentClipsOnePerMeaning() throws {
        let clock = TestClock()
        let book = try Phrasebook.inMemory(now: { clock.now })
        try book.add(heard: "open whatsapp", meant: "open WhatsApp", hearer: .scribe, wav: Data([1]), source: .enrolment)
        try book.add(heard: "oh pen what's up", meant: "open WhatsApp", hearer: .apple, wav: Data([2]), source: .enrolment)
        try book.add(heard: "scroll down", meant: "scroll down", hearer: .scribe, wav: Data([3]), source: .enrolment)
        try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, source: .confirmation)  // no clip
        let examples = book.examples(limit: 5)
        #expect(examples.map(\.text) == ["open WhatsApp", "scroll down"])
        #expect(examples.first?.wav == Data([2]))  // the clip the recogniser got most wrong
        #expect(book.examples(limit: 1).count == 1 && book.examples(limit: 0).isEmpty)
    }

    @Test func keytermsAreMostUsedFirstWithTheirWords() throws {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "scroll town", meant: "scroll down", hearer: .scribe, source: .confirmation)
        for hearer in [HearerName.scribe, .apple, .gemini] {
            try book.add(heard: "message mom", meant: "message Mum", hearer: hearer, source: .confirmation)
        }
        #expect(book.keyterms(limit: 10) == ["message Mum", "message", "Mum", "scroll down", "scroll", "down"])
        #expect(book.keyterms(limit: 2) == ["message Mum", "message"])
    }

    @Test func forgetRemovesEveryPairForAMeaning() throws {
        let book = try Phrasebook.inMemory()
        try book.add(heard: "call some", meant: "call Sam", hearer: .scribe, wav: Data([1]), source: .confirmation)
        try book.add(heard: "cool sum", meant: "Call Sam.", hearer: .gemini, source: .confirmation)
        try book.add(heard: "scroll town", meant: "scroll down", hearer: .scribe, source: .confirmation)
        #expect(try book.forget(meant: "call sam") == 2)
        #expect(book.count == 1 && book.bestMatch(for: ["call some"]) == nil)
    }

    @Test func fileIsPrivateAndSurvivesReopening() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("phrasebook.sqlite")
        try Phrasebook(path: path).add(heard: "call some", meant: "call Sam", hearer: .scribe, wav: Data([9, 9]), source: .correction)
        let reopened = try Phrasebook(path: path)
        #expect(reopened.count == 1)
        #expect(try reopened.entries(includingAudio: true).first?.wav == Data([9, 9]))
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func manyThreadsAtOnceAreSafe() async throws {
        let book = try Phrasebook.inMemory()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try? book.add(heard: "phrase \(index % 5)", meant: "meant \(index % 5)", hearer: .scribe, source: .confirmation)
                    _ = book.bestMatch(for: ["phrase \(index % 5)"])
                    _ = book.keyterms(limit: 5)
                }
            }
        }
        #expect(book.count == 5)
        #expect(try book.entries().map(\.timesConfirmed).reduce(0, +) == 40)
    }
}
