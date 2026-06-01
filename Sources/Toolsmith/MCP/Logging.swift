import Foundation

public let mcpSetLogLevelMethod = "logging/setLevel"
public let mcpLogMessageNotificationMethod = "notifications/message"

/// Syslog-aligned log severity levels.
public enum MCPLoggingLevel: String, Hashable, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case alert
    case emergency
}

public struct MCPSetLogLevelParams: Hashable, Codable, Sendable {
    public var level: MCPLoggingLevel
    public init(level: MCPLoggingLevel) { self.level = level }
}

public struct MCPLogMessageParams: Hashable, Codable, Sendable {
    public var level: MCPLoggingLevel
    public var logger: String?
    public var data: JSONValue

    public init(level: MCPLoggingLevel, data: JSONValue, logger: String? = nil) {
        self.level = level
        self.logger = logger
        self.data = data
    }
}
