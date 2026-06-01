import Foundation

/// Role tag on content annotations.
public enum MCPRole: String, Hashable, Codable, CaseIterable, Sendable {
    case user
    case assistant
}

/// Optional hints attached to content / resources telling clients how
/// to prioritize the payload.
public struct MCPAnnotations: Hashable, Codable, Sendable {
    public var audience: [MCPRole]?
    public var priority: Double?
    public var lastModified: String?

    public init(audience: [MCPRole]? = nil, priority: Double? = nil, lastModified: String? = nil) {
        self.audience = audience
        self.priority = priority
        self.lastModified = lastModified
    }
}

/// MCP pagination cursor. Opaque to the proxy.
public typealias MCPCursor = String
