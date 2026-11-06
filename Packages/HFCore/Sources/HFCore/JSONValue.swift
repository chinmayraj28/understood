import Foundation

/// A JSON value with a known shape, so tool parameters and results can cross
/// module boundaries without `Any`.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var doubleValue: Double? { if case .number(let value) = self { return value } else { return nil } }
    public var intValue: Int? { doubleValue.flatMap { Int(exactly: $0.rounded()) } }
    public var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Builds a JSONValue from what `JSONSerialization` or an SDK hands back (`Any`).
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let value as JSONValue: self = value
        case let value as String: self = .string(value)
        case let value as NSNumber:
            // NSNumber hides booleans; CFBoolean is how to tell them apart from 0 and 1.
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) } else { self = .number(value.doubleValue) }
        case let value as [Any?]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any?]: self = .object(value.mapValues { JSONValue(any: $0) })
        default: self = .string(String(describing: value!))
        }
    }

    /// The reverse of `init(any:)`, for handing to `JSONSerialization` or an SDK.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }
}

public typealias JSONObject = [String: JSONValue]

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
