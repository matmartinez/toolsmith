import Foundation

public let mcpCancelledNotificationMethod = "notifications/cancelled"

/// Params for `notifications/cancelled`. `requestId` mirrors a JSON-RPC id.
public struct MCPCancelledParams: Hashable, Codable, Sendable {
    public var requestId: JSONRPCID
    public var reason: String?

    public init(requestId: JSONRPCID, reason: String? = nil) {
        self.requestId = requestId
        self.reason = reason
    }
}
