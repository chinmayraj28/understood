import Foundation

/// The rules no memory may break, checked in code for every source
/// (explicit, learned and built-in). docs/MEMORY.md, Part B section 5.
public enum HardRules {
    /// What the user hears when a secret is refused.
    public static let secretRefusal = "I never store passwords, codes, PINs, or card and bank details."
    /// What the user hears when a fact would let a risky action skip its confirmation.
    public static let permissionRefusal =
        "I can't remember that. I always check with you before sending, paying or deleting."

    // MARK: Secrets (5.1)

    private static let secretWords = Pattern(
        #"\b(pass ?words?|passcodes?|passwd|pass ?phrases?|one[- ]time (?:pass)?codes?|otps?|verification codes?|security codes?|2fa|two[- ]factor|auth(?:entication)? codes?|login codes?|cvv|cvc|card numbers?|credit cards?|debit cards?|card details|bank details|bank account|account numbers?|sort codes?|iban|routing numbers?|social security|ssn|national insurance|api keys?|secret keys?|private keys?|access tokens?|seed phrases?|recovery (?:phrases?|codes?|keys?)|mnemonic|security (?:questions?|answers?)|maiden name|login details|credentials?)\b"#,
        caseInsensitive: true)
    /// "PIN" in capitals, or "pin" in a context that means a PIN. "pin this tab" is fine.
    private static let pinWord = Pattern(
        #"\bPINs?\b|(?i:\b(?:my|the|card|bank|phone|sim)\s+pin\b|\bpin\s*(?:code|number|is\b|:))"#)
    private static let codeWithDigits = Pattern(#"\b(?:code|pin)\b\D{0,15}\d{4,8}\b"#, caseInsensitive: true)
    private static let sortCode = Pattern(#"\b\d{2}-\d{2}-\d{2}\b"#)
    private static let iban = Pattern(#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#)
    private static let digitRun = Pattern(#"(?:\d[ -]?){13,19}"#)
    private static let longToken = Pattern(#"\b[A-Za-z0-9_\-]{24,}\b"#)
    private static let digit = Pattern(#"\d"#)
    private static let letter = Pattern(#"[A-Za-z]"#)

    /// True if the text names or contains a secret: a password, code, PIN, card or bank detail, or a key.
    public static func looksSecret(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if secretWords.matches(text) || pinWord.matches(text) || codeWithDigits.matches(text) { return true }
        if sortCode.matches(text) || iban.matches(text.replacingOccurrences(of: " ", with: "")) { return true }
        for run in digitRun.allMatches(text) {
            let digits = run.filter(\.isNumber)
            if (13...19).contains(digits.count), passesLuhn(digits) { return true }
        }
        for token in longToken.allMatches(text) where digit.matches(token) && letter.matches(token) {
            return true  // looks like an API key or an access token
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sk-")
    }

    /// What replaces a clause that held a secret.
    public static let secretPlaceholder = "[private]"
    private static let clauseBoundary = Pattern(#"(?<=[,;.!?\n])"#)

    /// The text with every clause that looks like a secret replaced by "[private]":
    /// "Type my PIN 4821 into the bank app, then open Notes" → "[private], then open Notes".
    ///
    /// Used on everything that is stored or sent to a model but is not itself a fact
    /// (task goals, summaries and steps), so a secret the user dictated for a task never
    /// lands in the episode log or in a learning prompt. Whole clauses go, because the
    /// secret's value may sit on either side of the word that gives it away ("Typed 4821
    /// in the PIN field").
    public static func redactSecrets(_ text: String) -> String {
        guard looksSecret(text) else { return text }
        let clauses = clauseBoundary.split(text)
        let redacted = clauses.map { clause -> String in
            guard looksSecret(clause) else { return clause }
            let leading = clause.prefix(while: \.isWhitespace)
            let trailingPunctuation = clause.last.map { ",;.!?\n".contains($0) ? String($0) : "" } ?? ""
            return leading + secretPlaceholder + trailingPunctuation
        }.joined()
        // A secret split across clauses (a card number with commas, say) is caught here.
        return looksSecret(redacted) ? secretPlaceholder : redacted
    }

    private static let numberRun = Pattern(#"\d(?:[ -]?\d){3,}"#)

    /// Redacts several texts from one task together. A number that one text gives away as
    /// secret ("the verification code 482913") is also removed from the others, where it may
    /// appear on its own ("Typed 482913").
    public static func redactSecrets(_ texts: [String]) -> [String] {
        var secretNumbers = Set<String>()
        for text in texts where looksSecret(text) {
            for clause in clauseBoundary.split(text) where looksSecret(clause) {
                for run in numberRun.allMatches(clause) { secretNumbers.insert(run.filter(\.isNumber)) }
            }
        }
        return texts.map { text in
            var output = redactSecrets(text)
            for digits in secretNumbers {
                // Match the same digits even if spaced or dashed differently.
                let spaced = digits.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ -]?")
                output = Pattern("(?<!\\d)" + spaced + "(?!\\d)").replace(output, with: secretPlaceholder)
            }
            return output
        }
    }

    /// The Luhn checksum every payment card number passes.
    static func passesLuhn(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count else { return false }
        var total = 0
        let parity = values.count % 2
        for (index, value) in values.enumerated() {
            var digitValue = value
            if index % 2 == parity {
                digitValue *= 2
                if digitValue > 9 { digitValue -= 9 }
            }
            total += digitValue
        }
        return total % 10 == 0
    }

    // MARK: Permission to skip a confirmation (5.2)

    static let riskyVerbs = "send|pay|buy|purchase|order|delete|remove|submit|post|invite|share|publish|transfer|accept"

    private static let skipConfirmation = Pattern(
        #"\b(?:don'?t|do not|never|no need to|stop|without|skip|no more)\s+(?:ever\s+)?(?:\w+\s+)?(?:ask|asking|confirm|confirming|confirmations?|check|checking|double[- ]check)"#,
        caseInsensitive: true)
    private static let automaticRisky = Pattern(#"\bauto(?:matically)?[- ]?(?:"# + riskyVerbs + ")",
                                                caseInsensitive: true)
    private static let justDoIt = Pattern(#"\bjust (?:"# + riskyVerbs + #") it\b"#, caseInsensitive: true)
    private static let hasRiskyVerb = Pattern(#"\b(?:"# + riskyVerbs + #"|confirm\w*)\b"#, caseInsensitive: true)
    private static let offWords: Set<String> = ["off", "never", "none", "no", "skip", "disabled", "disable", "false",
                                                "0", "nothing"]
    private static let consentWords: Set<String> = [
        "yes", "yeah", "yep", "y", "sure", "ok", "okay", "go ahead", "do it", "send", "send it", "confirm",
        "confirmed", "approve", "approved", "allow", "allowed", "granted", "true",
    ]

    /// True if storing this would read as permission to skip a confirmation.
    /// "confirmations: brief" is fine; "confirmations: off" and "don't ask before sending" are not.
    public static func grantsPermission(key: String, value: String) -> Bool {
        let text = "\(key) \(value)".replacingOccurrences(of: "_", with: " ")
        if skipConfirmation.matches(text) || automaticRisky.matches(text) || justDoIt.matches(text) { return true }
        let keyText = key.replacingOccurrences(of: "_", with: " ").lowercased()
        var valueText = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = valueText.last, last == "." || last == "!" { valueText.removeLast() }
        return hasRiskyVerb.matches(keyText) && (consentWords.contains(valueText) || offWords.contains(valueText))
    }

    /// A sentence to say if this fact must never be stored, or nil if it may be.
    public static func refusalReason(key: String, value: String) -> String? {
        if looksSecret(key) || looksSecret(value) { return secretRefusal }
        if grantsPermission(key: key, value: value) { return permissionRefusal }
        return nil
    }
}

/// Finding and hiding the wording of messages the user dictates.
/// Memory keeps the preference behind a message, never the message. Part B section 5.4.
public enum MessageContent {
    private static let quoted = Pattern(#""[^"]{2,}"|\x{201C}[^\x{201D}]{2,}\x{201D}|\x{2018}[^\x{2019}]{2,}\x{2019}"#)
    private static let afterColon = Pattern(#"(?<!\d):\s+\S.*$"#)
    private static let saying = Pattern(
        #"\b(?<lead>saying|say|says|that says|reply(?:ing)? with|tell (?!me\b)\w+(?: that)?|text(?:ing)? \w+ that|message(?: \w+)? that|ask (?!me\b)\w+(?: if| whether| to)?)\s+(?<body>\S.*)$"#,
        caseInsensitive: true)
    private static let chatVerbNameText = Pattern(
        #"^(?<lead>\s*(?:whatsapp|text|message|imessage)\s+(?:my\s+)?\w+)\s+(?!(?:(?:on|in|via|using)\s+(?:whatsapp|imessage|messages|telegram|signal|slack)|about)\b)(?<body>\S.*)$"#,
        caseInsensitive: true)
    private static let word = Pattern(#"\w+"#)

    /// "WhatsApp Mum: running late" → "WhatsApp Mum: [message]".
    public static func redact(_ text: String) -> String {
        var output = quoted.replace(text, with: "[message]")
        output = afterColon.replace(output, with: ": [message]")
        output = saying.replace(output) { $0.group("lead") + " [message]" }
        return chatVerbNameText.replace(output) { $0.group("lead") + " [message]" }
    }

    /// The parts of a goal that look like dictated message wording.
    public static func parts(of goal: String) -> [String] {
        var found = quoted.allMatches(goal).map { String($0.dropFirst().dropLast()) }
        if let match = afterColon.firstMatch(goal) {
            found.append(String(match.matched.drop(while: { $0 == ":" || $0 == " " })))
        }
        if let match = saying.firstMatch(goal) { found.append(match.group("body")) }
        if let match = chatVerbNameText.firstMatch(goal) { found.append(match.group("body")) }
        let trimSet = CharacterSet(charactersIn: " \"'.")
        return found.map { $0.trimmingCharacters(in: trimSet) }.filter { $0.count >= 3 }
    }

    /// True if `value` repeats the dictated message in `goal`: three words in a row,
    /// or a short message of six characters or more.
    public static func repeatsMessage(_ value: String, goal: String) -> Bool {
        let valueWords = word.allMatches(value.lowercased()).joined(separator: " ")
        for part in parts(of: goal) {
            let partWords = word.allMatches(part.lowercased())
            if partWords.count < 3 {
                let joined = partWords.joined(separator: " ")
                if !joined.isEmpty, joined.count >= 6, valueWords.contains(joined) { return true }
                continue
            }
            for start in 0...(partWords.count - 3)
            where valueWords.contains(partWords[start..<start + 3].joined(separator: " ")) {
                return true
            }
        }
        return false
    }
}
