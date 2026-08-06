import Foundation

// JSON-RPC 2.0, by hand.
//
// An official Swift MCP SDK exists. It is not used here, deliberately:
// the surface actually needed is initialize / initialized / tools/list
// / tools/call / ping, which is this file plus a transport, and the SDK
// pulls swift-log, swift-system and swift-collections behind it. In a
// package that pins tree-sitter grammars by exact revision because of
// ABI churn, taking three transitive dependencies to avoid ~300 lines
// is the wrong trade. Recorded here so the decision is auditable
// rather than accidental.

/// A request id, which the spec allows to be a number or a string.
/// Echoing back the wrong type is a common interop bug, so the
/// distinction is preserved rather than normalized.
public enum RequestID: Sendable, Hashable, Codable {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Any JSON value, so params and results can be arbitrary without a
/// generic parameter threading through the whole server.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Emit whole numbers as integers; a client that renders
            // `limit: 10.0` back at us is entitled to be confused.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // Convenience accessors — handlers read arguments, they don't
    // pattern-match trees.
    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .number(let v): return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v } else { return nil }
    }
}

public struct JSONRPCRequest: Sendable, Decodable {
    public let jsonrpc: String
    /// Absent for notifications, which must never be answered.
    public let id: RequestID?
    public let method: String
    public let params: JSONValue?
}

public struct JSONRPCError: Sendable, Encodable, Error {
    public let code: Int
    public let message: String

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid request")
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: "Invalid params: \(detail)")
    }
    public static func internalError(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: "Internal error: \(detail)")
    }
}

public struct JSONRPCResponse: Sendable, Encodable {
    public let jsonrpc = "2.0"
    public let id: RequestID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public static func success(id: RequestID?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: RequestID?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        // Exactly one of result/error, never both, never neither.
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .object([:]), forKey: .result)
        }
    }
}
