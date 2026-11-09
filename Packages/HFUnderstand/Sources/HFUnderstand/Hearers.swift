import Foundation
import HFCore
import os

// What the three recognisers (ScribeHearer, GeminiHearer, AppleHearer) share: one logger, and
// one way of sending a web request and turning a failed reply into a short sentence that can be
// spoken. The time limit is not here: the caller runs the hearers side by side and applies it.

let understandLog = Logger(subsystem: "com.handsfree", category: "understand")

/// Sends web requests for the two online hearers and explains failures in plain words.
enum HearerHTTP {
    /// Sends the request and returns the body of a successful (2xx) reply. Any other reply, or no
    /// reply at all, becomes a `SpeakableError` naming the service. Never logs the request body,
    /// which holds the person's voice.
    static func send(_ request: URLRequest, session: URLSession, service: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        // Cancelled already (the time limit ran out, or the person said stop): send nothing.
        try Task.checkCancellation()
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            understandLog.error("\(service, privacy: .public) timed out")
            throw SpeakableError("\(service) took too long to answer.")
        } catch {
            understandLog.error("\(service, privacy: .public) unreachable: \(String(describing: error), privacy: .public)")
            throw SpeakableError("I couldn't reach \(service). The internet may be down.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // The error body is service text, not the person's speech, but keep it private anyway.
            understandLog.error(
                "\(service, privacy: .public) answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .private)")
            throw failure(status: status, service: service)
        }
        return data
    }

    /// The spoken sentence for an HTTP status.
    static func failure(status: Int, service: String) -> SpeakableError {
        switch status {
        case 401, 403: return SpeakableError("\(service) didn't accept the key, so I couldn't use it to hear you.")
        case 402: return SpeakableError("The \(service) account has run out of credit.")
        case 408, 504: return SpeakableError("\(service) took too long to answer.")
        case 413: return SpeakableError("That recording was too long for \(service).")
        case 400, 422: return SpeakableError("\(service) couldn't use that recording.")
        case 429: return SpeakableError("\(service) is busy right now.")
        case 500...599: return SpeakableError("\(service) had a problem on its side.")
        default: return SpeakableError("\(service) gave an answer I didn't expect.")
        }
    }
}

/// The language part of a BCP-47 code: "en-GB" becomes "en". Empty stays empty.
func primaryLanguage(_ code: String) -> String {
    String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
}

/// Trims, drops blanks and repeats (ignoring case), keeping the first, most likely, spelling.
func uniqueTerms(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for term in terms {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
        result.append(trimmed)
    }
    return result
}
