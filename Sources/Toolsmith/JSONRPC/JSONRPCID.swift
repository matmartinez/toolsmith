import Foundation

/// A JSON-RPC request identifier. The spec allows strings, numbers, or
/// null; we represent each variant explicitly so the wire form round-trips.
public enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case number(Int64)
    case null
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSON-RPC id must be a string, number, or null."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONRPCID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONRPCID: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .number(value) }
}
