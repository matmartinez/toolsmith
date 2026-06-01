import Foundation

public let mcpListPromptsMethod = "prompts/list"
public let mcpGetPromptMethod = "prompts/get"
public let mcpPromptListChangedNotificationMethod = "notifications/prompts/list_changed"

public struct MCPPromptArgument: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var required: Bool?

    public init(name: String, title: String? = nil, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.required = required
    }
}

public struct MCPPrompt: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [MCPPromptArgument]?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [MCPPromptArgument]? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptMessage: Hashable, Codable, Sendable {
    public var role: MCPRole
    public var content: MCPContent
    public init(role: MCPRole, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

public struct MCPListPromptsParams: Hashable, Codable, Sendable {
    public var cursor: MCPCursor?
    public init(cursor: MCPCursor? = nil) { self.cursor = cursor }
}

public struct MCPListPromptsResult: Hashable, Codable, Sendable {
    public var prompts: [MCPPrompt]
    public var nextCursor: MCPCursor?
    public init(prompts: [MCPPrompt], nextCursor: MCPCursor? = nil) {
        self.prompts = prompts
        self.nextCursor = nextCursor
    }
}

public struct MCPGetPromptParams: Hashable, Codable, Sendable {
    public var name: String
    /// Per the spec, prompt-template arguments are strings, not arbitrary
    /// JSON. Distinct from `tools/call` arguments.
    public var arguments: [String: String]?
    public init(name: String, arguments: [String: String]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPGetPromptResult: Hashable, Codable, Sendable {
    public var description: String?
    public var messages: [MCPPromptMessage]
    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}
