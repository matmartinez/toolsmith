import Foundation

/// Latest MCP protocol revision Toolsmith targets when initiating a session.
public let latestMCPProtocolVersion = "2025-06-18"

/// Method name for the initialize request.
public let mcpInitializeMethod = "initialize"

/// Method name for the post-initialize client notification.
public let mcpInitializedNotificationMethod = "notifications/initialized"

/// Identifies an MCP implementation. Used by both client and server during
/// the initialize handshake.
public struct MCPImplementation: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var version: String

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
    }
}

public struct MCPRootsCapability: Hashable, Codable, Sendable {
    public var listChanged: Bool?
    public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
}

public struct MCPSamplingCapability: Hashable, Codable, Sendable {
    public init() {}
}

public struct MCPElicitationCapability: Hashable, Codable, Sendable {
    public init() {}
}

public struct MCPClientCapabilities: Hashable, Codable, Sendable {
    public var experimental: [String: JSONValue]?
    public var roots: MCPRootsCapability?
    public var sampling: MCPSamplingCapability?
    public var elicitation: MCPElicitationCapability?

    public init(
        experimental: [String: JSONValue]? = nil,
        roots: MCPRootsCapability? = nil,
        sampling: MCPSamplingCapability? = nil,
        elicitation: MCPElicitationCapability? = nil
    ) {
        self.experimental = experimental
        self.roots = roots
        self.sampling = sampling
        self.elicitation = elicitation
    }
}

public struct MCPPromptsCapability: Hashable, Codable, Sendable {
    public var listChanged: Bool?
    public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
}

public struct MCPResourcesCapability: Hashable, Codable, Sendable {
    public var subscribe: Bool?
    public var listChanged: Bool?
    public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

public struct MCPToolsCapability: Hashable, Codable, Sendable {
    public var listChanged: Bool?
    public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
}

public struct MCPLoggingCapability: Hashable, Codable, Sendable {
    public init() {}
}

public struct MCPCompletionsCapability: Hashable, Codable, Sendable {
    public init() {}
}

public struct MCPServerCapabilities: Hashable, Codable, Sendable {
    public var experimental: [String: JSONValue]?
    public var logging: MCPLoggingCapability?
    public var completions: MCPCompletionsCapability?
    public var prompts: MCPPromptsCapability?
    public var resources: MCPResourcesCapability?
    public var tools: MCPToolsCapability?

    public init(
        experimental: [String: JSONValue]? = nil,
        logging: MCPLoggingCapability? = nil,
        completions: MCPCompletionsCapability? = nil,
        prompts: MCPPromptsCapability? = nil,
        resources: MCPResourcesCapability? = nil,
        tools: MCPToolsCapability? = nil
    ) {
        self.experimental = experimental
        self.logging = logging
        self.completions = completions
        self.prompts = prompts
        self.resources = resources
        self.tools = tools
    }
}

/// Params for the `initialize` request.
public struct MCPInitializeParams: Hashable, Codable, Sendable {
    public var protocolVersion: String
    public var capabilities: MCPClientCapabilities
    public var clientInfo: MCPImplementation

    public init(
        protocolVersion: String = latestMCPProtocolVersion,
        capabilities: MCPClientCapabilities = .init(),
        clientInfo: MCPImplementation
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

/// Result of the `initialize` request.
public struct MCPInitializeResult: Hashable, Codable, Sendable {
    public var protocolVersion: String
    public var capabilities: MCPServerCapabilities
    public var serverInfo: MCPImplementation
    public var instructions: String?

    public init(
        protocolVersion: String,
        capabilities: MCPServerCapabilities,
        serverInfo: MCPImplementation,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}
