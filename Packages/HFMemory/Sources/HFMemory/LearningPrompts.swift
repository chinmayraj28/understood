import Foundation
import HFCore

/// The learning prompts and their output schemas, read from docs/prompts/memory_learning.md
/// (bundled as a resource), so the document is the single place to edit them.
///
/// The file is parsed by its markers: for each numbered section, the text between
/// `=== system ===` and `=== end ===`, and the first ```json block under "### Output schema".
public struct LearningPrompts: Sendable, Equatable {
    /// Prompt 1: is this answer a lasting preference?
    public let exchangeInstructions: String
    public let exchangeSchema: JSONValue
    /// Prompt 2: what did this task teach about operating the Mac?
    public let reflectInstructions: String
    public let reflectSchema: JSONValue
    /// Prompt 3: the yes-or-no question for an optional quick pre-filter such as Jev.
    public let lastingQuestion: String

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The prompts bundled with this package, or nil if the file is missing or malformed
    /// (a test makes sure it is neither).
    public static let bundled: LearningPrompts? = {
        guard let url = Bundle.module.url(forResource: "memory_learning", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return try? parse(markdown: text)
    }()

    /// Reads the prompts out of the Markdown document.
    public static func parse(markdown: String) throws -> LearningPrompts {
        let sections = splitSections(markdown)
        func section(_ number: Int) throws -> [String] {
            guard let lines = sections[number] else { throw ParseError(description: "section \(number) missing") }
            return lines
        }
        let exchange = try section(1)
        let reflect = try section(2)
        let jevGate = try section(3)
        guard let lastingJSON = jsonBlocks(in: jevGate).first(where: { $0["type"]?.stringValue == "noul" }),
              let lastingQuestion = lastingJSON["instructions"]?.stringValue
        else { throw ParseError(description: "section 3 has no noul question") }
        return LearningPrompts(
            exchangeInstructions: try systemText(in: exchange),
            exchangeSchema: try outputSchema(in: exchange),
            reflectInstructions: try systemText(in: reflect),
            reflectSchema: try outputSchema(in: reflect),
            lastingQuestion: lastingQuestion)
    }

    /// Lines of each "## <number>." section.
    private static func splitSections(_ markdown: String) -> [Int: [String]] {
        var sections: [Int: [String]] = [:]
        var current: Int?
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let rest = line.dropFirst(3)
                current = Int(rest.prefix(while: \.isNumber))
                continue
            }
            if let current { sections[current, default: []].append(line) }
        }
        return sections
    }

    private static func systemText(in lines: [String]) throws -> String {
        guard let start = lines.firstIndex(of: "=== system ==="),
              let end = lines[(start + 1)...].firstIndex(of: "=== end ===")
        else { throw ParseError(description: "system markers missing") }
        let text = lines[(start + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError(description: "empty system text") }
        return text
    }

    private static func outputSchema(in lines: [String]) throws -> JSONValue {
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("### Output schema") }),
              let schema = jsonBlocks(in: Array(lines[heading...])).first,
              schema["type"]?.stringValue == "object"
        else { throw ParseError(description: "output schema missing") }
        return schema
    }

    /// Every ```json block in the lines that parses as a JSON object.
    private static func jsonBlocks(in lines: [String]) -> [JSONValue] {
        var blocks: [JSONValue] = []
        var collecting: [String]?
        for line in lines {
            if collecting == nil, line.trimmingCharacters(in: .whitespaces) == "```json" {
                collecting = []
            } else if collecting != nil, line.trimmingCharacters(in: .whitespaces) == "```" {
                let text = collecting!.joined(separator: "\n")
                if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value.objectValue != nil {
                    blocks.append(value)
                }
                collecting = nil
            } else if collecting != nil {
                collecting!.append(line)
            }
        }
        return blocks
    }
}
