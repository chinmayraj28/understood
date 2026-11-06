import Foundation

/// Finds an installed app from what the user said.
///
/// People say app names loosely: "chrome", "vs code", "whats app", "settings".
/// Matching goes from strict to loose, and only the strict steps pick an app:
/// 1. a known nickname ("vs code" is Visual Studio Code), if that app is installed
/// 2. the same name ignoring case, spaces and punctuation
/// 3. every spoken word appears in exactly one app's name ("teams")
/// 4. a near-identical spelling (similarity 0.9 or more), the kind speech-to-text produces
/// Anything looser is offered as a suggestion, so the wrong app is never opened.
public enum AppMatching {
    public enum Result: Equatable, Sendable {
        case found(InstalledApp)
        /// Several apps match equally: ask which.
        case ambiguous([String])
        /// Nothing is close enough to open; these are the nearest names.
        case notFound(suggestions: [String])
    }

    static let nicknames: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "visual studio": "Visual Studio Code",
        "zoom": "zoom.us", "settings": "System Settings", "system preferences": "System Settings",
        "preferences": "System Settings", "control panel": "System Settings",
        "teams": "Microsoft Teams", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "power point": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook", "onenote": "Microsoft OneNote", "one note": "Microsoft OneNote",
        "imessage": "Messages", "i message": "Messages", "text messages": "Messages",
        "itunes": "Music", "apple music": "Music", "files": "Finder", "file explorer": "Finder",
        "explorer": "Finder", "voice memos": "VoiceMemos", "facetime": "FaceTime", "face time": "FaceTime",
        "task manager": "Activity Monitor", "command line": "Terminal",
    ]

    static let openThreshold = 0.9
    static let suggestThreshold = 0.6

    /// "The Spotify app." -> "spotify".
    static func normalise(_ text: String, dropAppWord: Bool = true) -> String {
        var text = text.lowercased().replacingOccurrences(of: "&", with: " and ")
        text = text.replacingOccurrences(of: #"\.app\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^(the|my)\s+"#, with: "", options: .regularExpression)
        if dropAppWord { text = text.replacingOccurrences(of: #"\s+(app|application)$"#, with: "", options: .regularExpression) }
        return text
    }

    static func squash(_ text: String) -> String { normalise(text).replacingOccurrences(of: " ", with: "") }

    public static func find(_ spoken: String, in apps: [InstalledApp]) -> Result {
        let query = normalise(spoken)
        guard !query.isEmpty else { return .notFound(suggestions: []) }
        var bySquash: [String: InstalledApp] = [:]
        for app in apps where bySquash[squash(app.name)] == nil { bySquash[squash(app.name)] = app }

        if let nickname = nicknames[query], let app = bySquash[squash(nickname)] { return .found(app) }
        // "whats app" must not lose its "app": try the name with it kept, too.
        for form in [normalise(spoken, dropAppWord: false), query] {
            if let app = bySquash[form.replacingOccurrences(of: " ", with: "")] { return .found(app) }
        }

        let words = query.split(separator: " ").map(String.init)
        let containing = apps.filter { app in
            let nameWords = Set(normalise(app.name).split(separator: " ").map(String.init))
            return words.allSatisfy(nameWords.contains)
        }
        if containing.count == 1 { return .found(containing[0]) }
        if containing.count > 1 { return .ambiguous(containing.prefix(5).map(\.name)) }

        let scored = apps.map { (score(query, $0), $0) }.sorted { $0.0 > $1.0 }
        if let best = scored.first, best.0 >= openThreshold, scored.count == 1 || scored[1].0 < best.0 - 0.05 {
            return .found(best.1)
        }
        return .notFound(suggestions: scored.prefix(3).filter { $0.0 >= suggestThreshold }.map(\.1.name))
    }

    static func score(_ query: String, _ app: InstalledApp) -> Double {
        let whole = similarity(squash(query), squash(app.name))
        let bestWord = normalise(app.name).split(separator: " ").map { similarity(query, String($0)) }.max() ?? 0
        return max(whole, bestWord * 0.95)
    }

    /// Ratcliff/Obershelp similarity, the measure Python's difflib uses: twice the
    /// matched characters over the total length.
    static func similarity(_ first: String, _ second: String) -> Double {
        let left = Array(first), right = Array(second)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        return 2 * Double(matchingCharacters(left[...], right[...])) / Double(left.count + right.count)
    }

    private static func matchingCharacters(_ left: ArraySlice<Character>, _ right: ArraySlice<Character>) -> Int {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        var bestLength = 0, bestLeft = left.startIndex, bestRight = right.startIndex
        for leftIndex in left.indices {
            for rightIndex in right.indices {
                var length = 0
                while leftIndex + length < left.endIndex, rightIndex + length < right.endIndex,
                    left[leftIndex + length] == right[rightIndex + length]
                {
                    length += 1
                }
                if length > bestLength { (bestLength, bestLeft, bestRight) = (length, leftIndex, rightIndex) }
            }
        }
        guard bestLength > 0 else { return 0 }
        return bestLength
            + matchingCharacters(left[left.startIndex..<bestLeft], right[right.startIndex..<bestRight])
            + matchingCharacters(left[(bestLeft + bestLength)...], right[(bestRight + bestLength)...])
    }
}

/// The apps installed in the usual folders.
enum AppIndex {
    static let folders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            guard let app = app(at: url), found[app.name.lowercased()] == nil else { return }
            found[app.name.lowercased()] = app
        }
        let fileManager = FileManager.default
        for folder in folders {
            for entry in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if !entry.lastPathComponent.hasPrefix(".") {
                    // One level of grouping folders, such as /Applications/Microsoft Office.
                    for inner in (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                    where inner.pathExtension == "app" {
                        add(inner)
                    }
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return found.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func app(at url: URL) -> InstalledApp? {
        guard url.pathExtension == "app" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: url)?.bundleIdentifier ?? ""
        return InstalledApp(name: name, path: url.path, bundleID: bundleID)
    }
}
