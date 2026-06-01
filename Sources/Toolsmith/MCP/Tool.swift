import Foundation

public let mcpListToolsMethod = "tools/list"
public let mcpCallToolMethod = "tools/call"

/// Behavioral hints a server may attach to a tool. Hints only — never
/// authoritative.
public struct MCPToolAnnotations: Hashable, Codable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// A tool advertised by the server. `inputSchema` / `outputSchema` are
/// kept as opaque JSON to preserve fidelity — the proxy never inspects
/// them.
public struct MCPTool: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: MCPToolAnnotations?

    public init(
        name: String,
        inputSchema: JSONValue,
        title: String? = nil,
        description: String? = nil,
        outputSchema: JSONValue? = nil,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }
}

/// Params for `tools/list`. Pagination uses an opaque cursor.
public struct MCPListToolsParams: Hashable, Codable, Sendable {
    public var cursor: MCPCursor?
    public init(cursor: MCPCursor? = nil) { self.cursor = cursor }
}

public struct MCPListToolsResult: Hashable, Codable, Sendable {
    public var tools: [MCPTool]
    public var nextCursor: MCPCursor?

    public init(tools: [MCPTool], nextCursor: MCPCursor? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

/// Params for `tools/call`. `arguments` is opaque so any client-supplied
/// shape forwards untouched.
public struct MCPCallToolParams: Hashable, Codable, Sendable {
    public var name: String
    public var arguments: [String: JSONValue]?

    public init(name: String, arguments: [String: JSONValue]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPCallToolResult: Hashable, Codable, Sendable {
    public var content: [MCPContent]
    public var structuredContent: [String: JSONValue]?
    public var isError: Bool?

    public init(
        content: [MCPContent],
        structuredContent: [String: JSONValue]? = nil,
        isError: Bool? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}
