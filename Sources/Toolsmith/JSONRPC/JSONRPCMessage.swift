import Foundation

/// Marker for the JSON-RPC protocol version. The spec mandates "2.0".
public let jsonRPCVersion = "2.0"

public struct JSONRPCRequest: Hashable, Codable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonRPCVersion
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Hashable, Codable, Sendable {
    public var jsonrpc: String
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = jsonRPCVersion
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Hashable, Codable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(id: JSONRPCID, result: JSONValue) {
        self.jsonrpc = jsonRPCVersion
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID, error: JSONRPCError) {
        self.jsonrpc = jsonRPCVersion
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Discriminated union over the three JSON-RPC envelope shapes.
public enum JSONRPCMessage: Hashable, Sendable {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)
}

extension JSONRPCMessage: Codable {
    private enum DiscriminatorKeys: String, CodingKey {
        case method, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let hasMethod = container.contains(.method)
        let hasId = container.contains(.id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)

        if hasMethod && hasId {
            self = .request(try JSONRPCRequest(from: decoder))
        } else if hasMethod {
            self = .notification(try JSONRPCNotification(from: decoder))
        } else if hasResult || hasError {
            self = .response(try JSONRPCResponse(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Object is not a JSON-RPC request, response, or notification."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let value): try value.encode(to: encoder)
        case .response(let value): try value.encode(to: encoder)
        case .notification(let value): try value.encode(to: encoder)
        }
    }
}
