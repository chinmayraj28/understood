import Testing

@testable import HFWake

@Suite struct DefaultPhraseMatching {
    let matcher = WakePhraseMatcher(phrase: "Hey Handsfree")

    @Test(arguments: [
        "Hey Handsfree",
        "hey handsfree",
        "Hey hands free",
        "hey hands-free",
        "Hey, hands free.",
        "HEY HANDS FREE!",
        "hay hands free",
        "Hay, handsfree",
        "a hands free",
        "A hands free.",
        "Hi hands free",
        "Hello handsfree",
        "hey hans free",
        "hey hand free",
        "hey hand's free",
        "hey, um, hands free",
        "Okay. Hey hands free.",
        "High hands-free, open Safari.",  // how SpeechAnalyzer wrote "Hi Handsfree" on this Mac
        "Hey Hansfree, open Mail.",  // also seen on this Mac
        "Hey hands-f free",  // a partial seen on this Mac
        "Hey Hands 3, open Mail.",  // a British voice on this Mac: "free" written as a digit
        "Pay hands free, open Spotify.",  // the same voice: "Hey" written as "Pay"
        "Pay hands free.",
    ])
    func wakesOnTheWaysARecogniserWritesIt(_ transcript: String) {
        #expect(matcher.match(transcript) != nil, "should wake on \"\(transcript)\"")
    }

    @Test(arguments: [
        "I use hands free in the car",
        "Hands free calling is great",
        "she bought a hands free kit",
        "the hands-free mode is on",
        "hey there",
        "hey hands",
        "hey free",
        "hey how are you",
        "handsfree",
        "and then he hands free tickets out",  // "he" sounds like "hey", but not at the start of a sentence
        "they handed three",
        // Found by review: ordinary sentences that an earlier version woke on.
        "A hands-free kit is the law now.",
        "He hands free samples to everyone.",
        "It's okay, hands free is fine.",
        "Hi, hands free calling works.",
        "Oh hands free mode is on.",
        "I hands free stuff.",
        "Hey Hans, free on Friday?",
        "I'll pay hands free next time",  // "pay" counts only at the start of a sentence
        "Pay hands free calls a visit",  // and only with a pause after the name
        "No hands free.",  // "no" is not a mishearing of "hey" at balanced
        "",
        "   ",
    ])
    func doesNotWakeOnOrdinarySpeech(_ transcript: String) {
        #expect(matcher.match(transcript) == nil, "should not wake on \"\(transcript)\"")
    }

    @Test(arguments: [
        ("Hey Handsfree, open Spotify", "open Spotify"),
        ("hey hands free open spotify.", "open spotify"),
        ("Hey hands-free... what's the time?", "what's the time?"),
        ("Hey Handsfree", ""),
        ("Hey Handsfree.", ""),
        ("Hey hands-free?", ""),  // seen on this Mac: the question mark is not the rest
        ("so I said hey handsfree turn the volume up", "turn the volume up"),
        ("Hey Handsfree, hey Handsfree, open Mail", "open Mail"),
        ("Hey handsfree. Reply to Mark's email", "Reply to Mark's email"),
    ])
    func extractsTheRestOfTheSentence(_ transcript: String, _ expected: String) {
        #expect(matcher.match(transcript)?.restOfSentence == expected)
    }

    @Test func reportsWhatWasHeardAndWhichPhrase() {
        let match = matcher.match("Hay, hands free. Open Mail.")
        #expect(match?.phrase == "Hey Handsfree")
        #expect(match?.heardAs == "hay hands free")
        #expect(match?.restOfSentence == "Open Mail")
    }

    @Test func aWeakLeadInCountsOnlyAtTheStartOfASentence() {
        #expect(matcher.match("A hands free. Open Spotify.")?.restOfSentence == "Open Spotify")
        #expect(matcher.match("Right. A hands free.") != nil)
        #expect(matcher.match("I got a hands free headset") == nil)
    }
}

@Suite struct ConfiguredPhraseMatching {
    @Test func aDifferentPhraseWithALeadIn() {
        let matcher = WakePhraseMatcher(phrase: "Okay Computer")
        #expect(matcher.match("OK computer, open Safari")?.restOfSentence == "open Safari")
        #expect(matcher.match("o.k. computer") != nil)
        #expect(matcher.match("okay, computer.") != nil)
        #expect(matcher.match("okay kompyuter") != nil)  // one sound off
        // How SpeechAnalyzer wrote "Okay computer, what's the time" on this Mac.
        #expect(matcher.match("Oh, computer, what's the time?")?.restOfSentence == "what's the time?")
        #expect(matcher.match("my computer is slow") == nil)
        #expect(matcher.match("I bought an old computer") == nil)
        #expect(matcher.match("Hey Handsfree") == nil)
    }

    @Test func aPhraseWithoutALeadInIsAllName() {
        let matcher = WakePhraseMatcher(phrase: "Wake up Mac")
        #expect(matcher.match("wake up mac open mail")?.restOfSentence == "open mail")
        #expect(matcher.match("wakeup mac") != nil)
        #expect(matcher.match("wake up") == nil)
    }

    @Test func alternativePhrasesAlsoWake() {
        let matcher = WakePhraseMatcher(phrase: "Hey Handsfree", alternatives: ["Hello Sam's Mac", "Computer listen"])
        #expect(matcher.match("hello sam's mac, open mail")?.phrase == "Hello Sam's Mac")
        #expect(matcher.match("computer listen") != nil)
        #expect(matcher.match("hey hands free")?.phrase == "Hey Handsfree")
        #expect(matcher.match("the computer can listen") == nil)
    }

    @Test func theEarliestPhraseInTheTranscriptWins() {
        let matcher = WakePhraseMatcher(phrase: "Hey Handsfree", alternatives: ["Computer listen"])
        let match = matcher.match("computer listen hey handsfree open mail")
        #expect(match?.phrase == "Computer listen")
        #expect(match?.restOfSentence == "open mail")
    }

    @Test func shortNamesGetNoSoundTolerance() {
        let matcher = WakePhraseMatcher(phrase: "Hey Max")
        #expect(matcher.match("hey max") != nil)
        #expect(matcher.match("hey mix") == nil)
    }

    @Test func emptyPhrasesAreIgnored() {
        let matcher = WakePhraseMatcher(phrase: "  ", alternatives: ["Hey Handsfree"])
        #expect(matcher.phrases == ["Hey Handsfree"])
        #expect(matcher.match("hey handsfree") != nil)
    }
}

@Suite struct Strictness {
    @Test func strictAcceptsOnlyTheSpellingWithAnySpacing() {
        let matcher = WakePhraseMatcher(phrase: "Hey Handsfree", strictness: .strict)
        #expect(matcher.match("Hey, hands-free") != nil)
        #expect(matcher.match("hey hands free") != nil)
        #expect(matcher.match("hay hands free") == nil)
        #expect(matcher.match("a hands free") == nil)
        #expect(matcher.match("hey hans free") == nil)
    }

    @Test func lenientAcceptsMoreAndCanDropTheLeadIn() {
        let matcher = WakePhraseMatcher(phrase: "Hey Handsfree", strictness: .lenient)
        #expect(matcher.match("hey hands three") != nil)
        #expect(matcher.match("hey and free") != nil)
        #expect(matcher.match("Hands free, open Spotify")?.restOfSentence == "open Spotify")
        // Even lenient needs the name to start a sentence when the lead-in is missing.
        #expect(matcher.match("I use hands free in the car") == nil)
    }

    @Test func balancedSitsBetween() {
        let matcher = WakePhraseMatcher(phrase: "Hey Handsfree")
        #expect(matcher.match("hey hands three") != nil)  // one sound off
        #expect(matcher.match("Hands free, open Spotify") == nil)
    }
}

@Suite struct SoundKeys {
    @Test func spellingsOfTheSameSoundShareAKey() {
        #expect(WakePhraseMatcher.soundKey("hey") == WakePhraseMatcher.soundKey("hay"))
        #expect(WakePhraseMatcher.soundKey("handsfree") == "h*ndsfr*")
        #expect(WakePhraseMatcher.soundKey("phone") == WakePhraseMatcher.soundKey("fone"))
        #expect(WakePhraseMatcher.soundKey("computer") == WakePhraseMatcher.soundKey("kompyuter"))
    }

    @Test func editDistance() {
        #expect(WakePhraseMatcher.editDistance("kitten", "sitting") == 3)
        #expect(WakePhraseMatcher.editDistance("", "abc") == 3)
        #expect(WakePhraseMatcher.editDistance("same", "same") == 0)
    }
}
