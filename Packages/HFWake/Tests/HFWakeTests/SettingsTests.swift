import Foundation
import HFCore
import Speech
import Testing

@testable import HFWake

@Suite struct ConfigurationFromSettings {
    func configuration(_ environment: [String: String]) -> WakeListener.Configuration {
        WakeListener.Configuration(settings: Settings.load(environment: environment, envFileCandidates: []))
    }

    @Test func defaults() {
        let configuration = configuration([:])
        #expect(configuration.phrase == "Hey Handsfree")
        #expect(configuration.alternatives.isEmpty)
        #expect(configuration.strictness == .balanced)
        #expect(configuration.locale == nil)  // the Mac's own language
    }

    @Test func wakeAlternativesBecomeExtraPhrases() {
        let configuration = configuration(["WAKE_ALTERNATIVES": "Hello Sam's Mac, Computer listen ,"])
        #expect(configuration.alternatives == ["Hello Sam's Mac", "Computer listen"])
        let matcher = WakePhraseMatcher(
            phrase: configuration.phrase, alternatives: configuration.alternatives, strictness: configuration.strictness)
        #expect(matcher.match("computer listen, open mail")?.restOfSentence == "open mail")
    }

    @Test(arguments: [("strict", WakeStrictness.strict), ("LENIENT", .lenient), ("balanced", .balanced), ("loose", .balanced)])
    func wakeStrictness(_ value: String, _ expected: WakeStrictness) {
        #expect(configuration(["WAKE_STRICTNESS": value]).strictness == expected)
    }

    @Test(arguments: [("en_GB", "GB"), ("en-GB", "GB"), (" en_US ", "US")])
    func wakeLanguage(_ value: String, _ region: String) {
        let locale = configuration(["WAKE_LANGUAGE": value]).locale
        #expect(locale?.language.languageCode?.identifier == "en")
        #expect(locale?.region?.identifier == region)
    }
}

@Suite struct LanguageChoosing {
    let supported = ["en_AU", "en_GB", "en_IN", "en_US", "fr_FR"].map { Locale(identifier: $0) }

    @Test func noChoiceMeansTheNearestToTheMac() throws {
        let chosen = try LanguageChoice.resolve(requested: nil, supported: supported, nearestToMac: Locale(identifier: "en_IN"))
        #expect(LanguageChoice.code(chosen) == "en_IN")
    }

    @Test func aChosenSupportedLanguageIsUsedExactly() throws {
        let chosen = try LanguageChoice.resolve(
            requested: Locale(identifier: "en_GB"), supported: supported, nearestToMac: Locale(identifier: "en_IN"))
        #expect(LanguageChoice.code(chosen) == "en_GB")
    }

    @Test func anUnsupportedLanguageFailsAndNamesTheSupportedOnes() {
        // Not quietly en_US or en_IN instead: a wrong language is a reason the phrase goes unheard.
        #expect(throws: SpeakableError(
            "The wake language en_JM isn't supported by on-device speech recognition on this Mac, "
                + "so set WAKE_LANGUAGE to one of en_AU, en_GB, en_IN, en_US.")
        ) {
            try LanguageChoice.resolve(
                requested: Locale(identifier: "en_JM"), supported: supported, nearestToMac: Locale(identifier: "en_IN"))
        }
    }

    @Test func anUnsupportedLanguageWithNoRelativeListsEverything() {
        #expect(throws: SpeakableError(
            "The wake language de_DE isn't supported by on-device speech recognition on this Mac, "
                + "so set WAKE_LANGUAGE to one of en_AU, en_GB, en_IN, en_US, fr_FR.")
        ) {
            try LanguageChoice.resolve(requested: Locale(identifier: "de_DE"), supported: supported, nearestToMac: nil)
        }
    }

    @Test func aLanguageWithoutARegionPicksOneOfThatLanguage() throws {
        let chosen = try LanguageChoice.resolve(requested: Locale(identifier: "fr"), supported: supported, nearestToMac: nil)
        #expect(LanguageChoice.code(chosen) == "fr_FR")
    }

    @Test func aMacLanguageWithNoMatchFailsClearly() {
        #expect(throws: SpeakableError.self) {
            try LanguageChoice.resolve(requested: nil, supported: supported, nearestToMac: nil)
        }
    }

    @Test func theRealRecogniserRefusesAnUnsupportedLanguage() async throws {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            try Test.cancel("SpeechAnalyzer isn't available on this Mac")
        }
        let supportedHere = await SpeechTranscriber.supportedLocales.map(LanguageChoice.code)
        let unsupported = ["en_JM", "zz_ZZ"].first { !supportedHere.contains($0) }!
        let engine = AnalyzerEngine(locale: Locale(identifier: unsupported), contextualStrings: [])
        do {
            try await engine.prepare(requestPermission: false)
            Issue.record("prepare should have failed for \(unsupported)")
        } catch let error as SpeakableError {
            #expect(error.spokenMessage.hasPrefix("The wake language \(unsupported) isn't supported"))
            #expect(error.spokenMessage.contains("en_GB"))
        }
    }
}
