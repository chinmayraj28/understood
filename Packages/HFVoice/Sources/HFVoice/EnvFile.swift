import Foundation

/// Writes one `KEY=value` line into a `.env` file, leaving every other line as it was.
///
/// Used only by `hf-voice setup` to store ELEVENLABS_AGENT_ID. It never reads
/// out or prints the other values, and keeps the file readable by the user only.
public enum EnvFile {
    /// Replaces the line for `key`, or appends one. Creates the file if needed.
    public static func set(_ key: String, to value: String, in file: URL) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let newLine = "\(key)=\(value)"
        var replaced = false
        lines = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let bare = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard bare.hasPrefix("\(key)=") else { return line }
            if replaced { return nil }  // drop duplicates of the same key
            replaced = true
            return newLine
        }
        if !replaced { lines.append(newLine) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The repo's `.env`: the first one found walking up from `directory`.
    public static func find(from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        var folder = directory
        for _ in 0..<8 {
            let candidate = folder.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            folder.deleteLastPathComponent()
        }
        return nil
    }
}
