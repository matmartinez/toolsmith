import Foundation

/// Method name for progress notifications.
public let mcpProgressNotificationMethod = "notifications/progress"

/// Opaque token attaching out-of-band progress updates to a request.
/// MCP allows strings or numbers.
public enum MCPProgressToken: Hashable, Sendable {
    case string(String)
    case number(Int64)
}

extension MCPProgressToken: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
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
            debugDescription: "Progress token must be a string or number."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

extension MCPProgressToken: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension MCPProgressToken: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .number(value) }
}

/// Params for `notifications/progress`.
public struct MCPProgressNotificationParams: Hashable, Codable, Sendable {
    public var progressToken: MCPProgressToken
    public var progress: Double
    public var total: Double?
    public var message: String?

    public init(
        progressToken: MCPProgressToken,
        progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) {
        self.progressToken = progressToken
        self.progress = progress
        self.total = total
        self.message = message
    }
}

/// Reads the progress token a caller may have attached to a request via
/// `params._meta.progressToken`. Returns nil when the request has no
/// `_meta`/`progressToken` field. The proxy uses this to bridge the
/// child-server's progress notifications back to the originating client.
public enum MCPProgressTokenExtractor {
    public static func token(in params: JSONValue?) -> MCPProgressToken? {
        guard case .object(let outer) = params,
              case .object(let meta) = outer["_meta"],
              let raw = meta["progressToken"]
        else { return nil }
        switch raw {
        case .integer(let value): return .number(value)
        case .string(let value): return .string(value)
        default: return nil
        }
    }
}
