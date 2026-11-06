import Foundation
import HFCore

/// Picks the language the recogniser listens in.
///
/// - No language chosen: the Mac's own language, or the nearest one the recogniser supports
///   (this Mac is `en_IN`, which is supported as it is).
/// - A language chosen (`WAKE_LANGUAGE`): exactly that language and region, or a clear error that
///   names the supported ones. It never quietly listens in a different language from the one asked
///   for, because a wrong language is exactly the kind of thing that makes the phrase go unheard.
enum LanguageChoice {
    /// - Parameters:
    ///   - requested: the chosen language, or nil for the Mac's.
    ///   - supported: what the recogniser supports on this Mac.
    ///   - nearestToMac: the recogniser's own nearest match for the Mac's language, if any.
    static func resolve(requested: Locale?, supported: [Locale], nearestToMac: Locale?) throws -> Locale {
        // The Mac's own language passed in explicitly (the app does this when WAKE_LANGUAGE is
        // empty) is still "the Mac's language": the nearest supported one is fine, so a Mac set to
        // English with, say, a German region still listens in English.
        guard let requested, code(requested) != code(.current) else {
            if let nearestToMac { return nearestToMac }
            throw SpeakableError(
                "On-device speech recognition doesn't support this Mac's language, \(code(Locale.current)), so set "
                    + "WAKE_LANGUAGE to one of \(list(supported, near: Locale.current)).")
        }
        let language = requested.language.languageCode?.identifier
        if let region = requested.region?.identifier {
            if let exact = supported.first(where: {
                $0.language.languageCode?.identifier == language && $0.region?.identifier == region
            }) {
                return exact
            }
        } else {
            // "en" on its own: any English the recogniser has, preferring the Mac's region.
            let sameLanguage = supported.filter { $0.language.languageCode?.identifier == language }
            if let match = sameLanguage.first(where: { $0.region?.identifier == Locale.current.region?.identifier })
                ?? sameLanguage.sorted(by: { code($0) < code($1) }).first
            {
                return match
            }
        }
        throw SpeakableError(
            "The wake language \(code(requested)) isn't supported by on-device speech recognition on this Mac, "
                + "so set WAKE_LANGUAGE to one of \(list(supported, near: requested)).")
    }

    /// "en_GB": the form WAKE_LANGUAGE takes.
    static func code(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? locale.identifier
        guard let region = locale.region?.identifier else { return language }
        return "\(language)_\(region)"
    }

    /// The supported codes in the same language as `near` if there are any, otherwise all of them.
    static func list(_ supported: [Locale], near: Locale) -> String {
        let language = near.language.languageCode?.identifier
        let same = supported.filter { $0.language.languageCode?.identifier == language }
        let codes = Set((same.isEmpty ? supported : same).map(code)).sorted()
        return codes.isEmpty ? "none on this Mac" : codes.joined(separator: ", ")
    }
}
