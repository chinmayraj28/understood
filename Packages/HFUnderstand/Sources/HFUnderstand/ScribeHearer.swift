import Foundation
import HFCore

// ElevenLabs Scribe, the batch speech-to-text API. Checked against ElevenLabs' docs and by a real
// call on 7 Nov 2026 (docs/spikes/hearers.md):
//   POST https://api.elevenlabs.io/v1/speech-to-text, header xi-api-key, multipart form with
//   `file`, `model_id` ("scribe_v2"), `language_code`, and `keyterms` once per term.
//   Keyterms: at most 1,000; each under 50 characters and at most 5 words; none of < > { } [ ] \.
//   Keyterms add 20% to the price, and more than 100 makes every request bill at least 20 seconds.

/// ElevenLabs Scribe (batch), told the words likely in this turn: names, apps, usual commands.
public struct ScribeHearer: Hearing {
    /// The documented maximum number of keyterms for batch Scribe.
    public static let keytermLimit = 1_000
    /// Each keyterm must be shorter than this many characters.
    public static let keytermMaxCharacters = 50
    /// Each keyterm may have at most this many words.
    public static let keytermMaxWords = 5

    public var name: HearerName { .scribe }

    let apiKey: String
    let model: String
    let session: URLSession
    let maxKeyterms: Int
    let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// - Parameters:
    ///   - apiKey: the ElevenLabs key, from `Settings.load().elevenLabsAPIKey`.
    ///   - model: the batch Scribe model. "scribe_v2" is the current one and the only one with keyterms.
    ///   - maxKeyterms: how many of the hints' keyterms to send, most likely first. 100 by default,
    ///     because above 100 ElevenLabs bills every request as at least 20 seconds, which is about
    ///     seven times the cost of a 3-second command. Never more than 1,000.
    public init(apiKey: String, model: String = "scribe_v2", maxKeyterms: Int = 100, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.maxKeyterms = max(0, min(maxKeyterms, Self.keytermLimit))
        self.session = session
    }

    /// Sends the turn's audio to Scribe and returns the transcript. Throws a `SpeakableError`
    /// when the key is missing or wrong, the service fails, or no words were heard.
    public func hear(_ turn: RecordedTurn, hints: HearingHints) async throws -> String {
        guard !apiKey.isEmpty else { throw SpeakableError("There's no ElevenLabs key, so I can't use its recogniser.") }
        let request = makeRequest(turn, hints: hints)
        let data = try await HearerHTTP.send(request, session: session, service: "ElevenLabs")
        struct Reply: Decodable { let text: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw SpeakableError("ElevenLabs gave an answer I didn't expect.")
        }
        let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeakableError("ElevenLabs heard no words.") }
        return text
    }

    /// The multipart request. Separate so tests can check its shape without a network.
    func makeRequest(_ turn: RecordedTurn, hints: HearingHints) -> URLRequest {
        var form = MultipartForm()
        form.addField("model_id", model)
        let language = primaryLanguage(hints.languageCode)
        if !language.isEmpty { form.addField("language_code", language) }
        // Sounds such as "(laughs)" are not words the person said; leave them out of the text.
        form.addField("tag_audio_events", "false")
        // Word timings are not used, so don't ask for them.
        form.addField("timestamps_granularity", "none")
        for term in Self.acceptedKeyterms(hints.keyterms, limit: maxKeyterms) {
            form.addField("keyterms", term)
        }
        form.addFile("file", fileName: "turn.wav", contentType: "audio/wav", data: turn.wav)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()
        return request
    }

    /// The keyterms Scribe will take, most likely first: within ElevenLabs' length, word and
    /// character rules, without repeats, and at most `limit`. A term that breaks a rule is dropped
    /// rather than shortened, because a cut-off name would steer the recogniser wrongly.
    static func acceptedKeyterms(_ terms: [String], limit: Int) -> [String] {
        let accepted = uniqueTerms(terms).filter { fitsKeytermRules($0, forbidden: CharacterSet(charactersIn: "<>{}[]\\")) }
        return Array(accepted.prefix(max(0, min(limit, keytermLimit))))
    }

    /// True when a trimmed term is short enough (counted in Unicode scalars, as the server counts,
    /// so "é" written as two scalars counts as two), has at most five words, and has none of the
    /// forbidden characters.
    static func fitsKeytermRules(_ term: String, forbidden: CharacterSet) -> Bool {
        term.unicodeScalars.count < keytermMaxCharacters
            && term.split(separator: " ").count <= keytermMaxWords
            && term.rangeOfCharacter(from: forbidden) == nil
    }
}

/// A multipart/form-data body, built by hand because URLSession has no builder for one.
struct MultipartForm {
    let boundary = "handsfree-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, contentType: String, data: Data) {
        body.append(Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        var finished = body
        finished.append(Data("--\(boundary)--\r\n".utf8))
        return finished
    }
}
