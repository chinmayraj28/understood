import Foundation
import HFCore

extension Phrasebook {
    /// Matches below this similarity are not reported: they would only distract the repair stage.
    public static let minimumMatchSimilarity = 0.6

    /// The stored pair closest to any of the new transcripts, or nil.
    ///
    /// Method: `SpeechText.similarity` between each transcript and each stored "heard" text
    /// (a word edit distance where sound-alike or similarly spelled words cost less). The
    /// best pair wins by similarity × a recency factor (0.6 + 0.4 × the 30-day half-life
    /// weight), so a recent pair beats an equally close old one.
    ///
    /// `timesConfirmed` in the result is the recency-weighted count, rounded down (at least 1):
    /// three confirmations a month ago count as one, so a pair nobody has used for a while is
    /// checked with the person once more before the decider trusts it on its own again.
    public func bestMatch(for transcripts: [String]) -> PhrasebookMatch? {
        let heardWords = transcripts.map(SpeechText.words).filter { !$0.isEmpty }
        guard !heardWords.isEmpty else { return nil }
        lock.lock()
        let rows = (try? database.query("SELECT meant, heard, heard_key, times_confirmed, last_confirmed_at FROM entries")) ?? []
        lock.unlock()

        return best(in: rows, heardWords: heardWords)
    }

    /// For each recogniser that heard something, its closest pair among the pairs **that same
    /// recogniser** stored. Recognisers make different mistakes: Apple's "mess a mum" for
    /// "message Mum" says nothing about what Scribe's "message Sam" meant. This is what the
    /// decider trusts; `bestMatch(for:)` (any recogniser) is only a hint for the repair stage.
    /// Same similarity, recency and decayed count as `bestMatch(for:)`.
    public func matchesByHearer(for hypotheses: [Hypothesis]) -> [HearerName: PhrasebookMatch] {
        lock.lock()
        let rows = (try? database.query("SELECT meant, heard, heard_key, hearer, times_confirmed, last_confirmed_at FROM entries")) ?? []
        lock.unlock()
        var matches: [HearerName: PhrasebookMatch] = [:]
        for hypothesis in hypotheses where !SpeechText.words(hypothesis.text).isEmpty {
            let ownRows = rows.filter { $0["hearer"]?.text == hypothesis.hearer.rawValue }
            if let match = best(in: ownRows, heardWords: [SpeechText.words(hypothesis.text)]) {
                matches[hypothesis.hearer] = match
            }
        }
        return matches
    }

    /// The best-scoring row for any of the transcripts (as word lists), or nil.
    func best(in rows: [PhrasebookRow], heardWords: [[String]]) -> PhrasebookMatch? {
        var best: (score: Double, match: PhrasebookMatch)?
        for row in rows {
            let storedWords = SpeechText.words(row["heard_key"]?.text ?? "")
            let similarity = heardWords.map { SpeechText.similarity(words: $0, storedWords) }.max() ?? 0
            guard similarity >= Self.minimumMatchSimilarity else { continue }
            let weight = recencyWeight(Date(timeIntervalSince1970: row["last_confirmed_at"]?.real ?? 0))
            let confirmed = Int(row["times_confirmed"]?.integer ?? 1)
            let match = PhrasebookMatch(
                meant: row["meant"]?.text ?? "", heard: row["heard"]?.text ?? "", similarity: similarity,
                // + 0.01: a pair confirmed a moment ago keeps its full count.
                timesConfirmed: max(1, Int((Double(confirmed) * weight + 0.01).rounded(.down))))
            let score = similarity * (0.6 + 0.4 * weight)
            if let current = best, current.score > score
                || (current.score == score && current.match.timesConfirmed >= match.timesConfirmed)
            {
                continue
            }
            best = (score, match)
        }
        return best?.match
    }

    /// This person's most useful clips, as examples for a recogniser that learns from them.
    ///
    /// Useful means recent (30-day half-life on when it was recorded) and hard: a clip whose
    /// recogniser transcript was far from what was meant teaches more than one it got right.
    /// One clip per meaning, so the few examples cover different phrases.
    public func examples(limit: Int) -> [SpeechExample] {
        guard limit > 0 else { return [] }
        lock.lock()
        let rows = (try? database.query(
            "SELECT meant, meant_key, heard, wav, created_at FROM entries WHERE wav IS NOT NULL AND length(wav) > 0")) ?? []
        lock.unlock()

        let scored = rows.map { row -> (score: Double, key: String, example: SpeechExample) in
            let wrongness = 1 - SpeechText.similarity(row["heard"]?.text ?? "", row["meant"]?.text ?? "")
            let weight = recencyWeight(Date(timeIntervalSince1970: row["created_at"]?.real ?? 0))
            return (weight * (1 + wrongness), row["meant_key"]?.text ?? "",
                    SpeechExample(wav: row["wav"]?.blob ?? Data(), text: row["meant"]?.text ?? ""))
        }
        var seen: Set<String> = [], examples: [SpeechExample] = []
        for item in scored.sorted(by: { $0.score > $1.score }) where seen.insert(item.key).inserted {
            examples.append(item.example)
            if examples.count == limit { break }
        }
        return examples
    }

    /// Words and phrases this person says, most used first, for recognisers that accept hints.
    /// Each meant phrase is followed by its own content words ("message Mum", "message", "mum"),
    /// so a recogniser that only takes single words still gets the names. Use is the
    /// recency-weighted number of confirmations.
    public func keyterms(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let rows = (try? database.query(
            "SELECT meant, meant_key, times_confirmed, last_confirmed_at FROM entries ORDER BY last_confirmed_at DESC")) ?? []
        lock.unlock()

        var usage: [String: Double] = [:], wording: [String: String] = [:]
        for row in rows {
            let key = row["meant_key"]?.text ?? ""
            let weight = recencyWeight(Date(timeIntervalSince1970: row["last_confirmed_at"]?.real ?? 0))
            usage[key, default: 0] += Double(row["times_confirmed"]?.integer ?? 1) * weight
            if wording[key] == nil { wording[key] = row["meant"]?.text }  // newest wording
        }
        var seen: Set<String> = [], terms: [String] = []
        func append(_ term: String) {
            guard terms.count < limit, seen.insert(term.lowercased()).inserted else { return }
            terms.append(term)
        }
        for key in usage.keys.sorted(by: { (usage[$0]!, $1) > (usage[$1]!, $0) }) {
            guard let phrase = wording[key] else { continue }
            append(phrase)
            for word in phrase.split(separator: " ").map({ $0.trimmingCharacters(in: .punctuationCharacters) })
            where word.count > 1 && !SpeechText.fillerWords.contains(word.lowercased()) {
                append(word)
            }
        }
        return terms
    }
}
