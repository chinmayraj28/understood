import Foundation

/// A language model that fills in a structured answer.
///
/// Memory uses this to turn "Priya Shah or Priya Patel?" answered "Shah" into a
/// typed fact. The Claude client in HFScreenAgent implements it, and the app
/// passes it in, so HFMemory does not need to know how Claude is called.
public protocol StructuredLanguageModel: Sendable {
    /// Returns a JSON object matching `schema` (a JSON Schema object).
    /// Throws on any failure; callers treat a failure as "nothing learned".
    func extract(instructions: String, input: String, schema: JSONValue) async throws -> JSONValue
}
