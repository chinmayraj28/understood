import Foundation

/// Settings and secrets, read once at startup.
///
/// Values come from, in order: the process environment, then the first `.env`
/// file found among the candidate paths. Secrets are only ever read here, and
/// nothing in this type prints or logs them.
public struct Settings: Sendable {
    // Keys. An empty string means "not set".
    public var elevenLabsAPIKey: String
    public var elevenLabsAgentID: String
    public var anthropicAPIKey: String
    public var openRouterAPIKey: String

    // Jev, the fast classifier, reached through OpenRouter's System One endpoint.
    public var jevURL: URL
    public var jevModel: String
    /// Past this we stop waiting for Jev and use the keyword fallback.
    public var jevTimeoutSeconds: Double

    // Claude.
    public var taskModel: String  // looks at the screen and picks the next action
    public var smallModel: String  // short background jobs, such as learning from a finished task

    // Task limits.
    public var maxTaskSteps: Int
    public var maxTaskSeconds: Double

    // Waking and sleeping.
    /// What the user says to start a conversation, e.g. "Hey Handsfree". It is listened for on
    /// the Mac itself, so no audio leaves the laptop and no ElevenLabs minutes are used while asleep.
    public var wakePhrase: String
    /// "phrase": sleep until the wake phrase is heard (the default).
    /// "always": keep a conversation open the whole time, for demos and testing.
    public var wakeMode: WakeMode
    /// How long a conversation stays open with nobody speaking and no task running before
    /// the app goes back to sleep.
    public var sleepAfterIdleSeconds: Double

    /// Memory database and logs. Never inside the repo.
    public var dataDirectory: URL

    // Safe targets for real end-to-end tests. Tests never send to anyone else.
    public var testWhatsAppContact: String
    public var testInviteEmail: String

    /// Names of required keys that are not set, for a clear first-run message.
    public var missingKeys: [String] {
        var missing: [String] = []
        if elevenLabsAPIKey.isEmpty { missing.append("ELEVENLABS_API_KEY") }
        if anthropicAPIKey.isEmpty { missing.append("ANTHROPIC_API_KEY") }
        return missing
    }

    /// Without an OpenRouter key we skip Jev and use the keyword fallbacks.
    public var isJevEnabled: Bool { !openRouterAPIKey.isEmpty }

    public static let applicationSupportFolderName = "Handsfree"

    /// Where a `.env` file is looked for, most specific first.
    public static func defaultEnvFileCandidates() -> [URL] {
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["HANDSFREE_ENV_FILE"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        // During development: walk up from the working directory to find the repo's .env.
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent(".env"))
            directory.deleteLastPathComponent()
        }
        // For the installed app.
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Library/Application Support/\(applicationSupportFolderName)/.env"))
        return candidates
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFileCandidates: [URL] = defaultEnvFileCandidates()
    ) -> Settings {
        var values: [String: String] = [:]
        if let file = envFileCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let text = try? String(contentsOf: file, encoding: .utf8)
        {
            values = parseEnvFile(text)
        }
        // The process environment wins over the file.
        values.merge(environment) { _, fromEnvironment in fromEnvironment }

        func string(_ key: String, _ fallback: String = "") -> String {
            let value = values[key]?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? fallback : value
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDirectory = values["HANDSFREE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/\(applicationSupportFolderName)")

        return Settings(
            elevenLabsAPIKey: string("ELEVENLABS_API_KEY"),
            elevenLabsAgentID: string("ELEVENLABS_AGENT_ID"),
            anthropicAPIKey: string("ANTHROPIC_API_KEY"),
            openRouterAPIKey: string("OPENROUTER_API_KEY"),
            jevURL: URL(string: string("JEV_URL", "https://openrouter.ai/api/v1/systemone"))!,
            jevModel: string("JEV_MODEL", "jev-latest"),
            jevTimeoutSeconds: Double(string("JEV_TIMEOUT_S", "0.8")) ?? 0.8,
            taskModel: string("TASK_MODEL", "claude-sonnet-5-5"),
            smallModel: string("SMALL_MODEL", "claude-haiku-5-5"),
            maxTaskSteps: Int(string("MAX_TASK_STEPS", "25")) ?? 25,
            maxTaskSeconds: Double(string("MAX_TASK_SECONDS", "180")) ?? 180,
            wakePhrase: string("WAKE_PHRASE", "Hey Handsfree"),
            wakeMode: WakeMode(rawValue: string("WAKE_MODE", "phrase").lowercased()) ?? .phrase,
            sleepAfterIdleSeconds: max(5, Double(string("SLEEP_AFTER_IDLE_S", "25")) ?? 25),
            dataDirectory: dataDirectory,
            testWhatsAppContact: string("TEST_WHATSAPP_CONTACT"),
            testInviteEmail: string("TEST_INVITE_EMAIL")
        )
    }

    /// Parses `KEY=value` lines. Ignores blank lines and `#` comments, and strips matching quotes.
    public static func parseEnvFile(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst("export ".count)) }
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }
}
