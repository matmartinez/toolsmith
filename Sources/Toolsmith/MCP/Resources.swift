import Foundation

public let mcpListResourcesMethod = "resources/list"
public let mcpReadResourceMethod = "resources/read"
public let mcpListResourceTemplatesMethod = "resources/templates/list"
public let mcpSubscribeResourceMethod = "resources/subscribe"
public let mcpUnsubscribeResourceMethod = "resources/unsubscribe"
public let mcpResourceUpdatedNotificationMethod = "notifications/resources/updated"
public let mcpResourceListChangedNotificationMethod = "notifications/resources/list_changed"

public struct MCPResourceTemplate: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var uriTemplate: String
    public var description: String?
    public var mimeType: String?
    public var annotations: MCPAnnotations?

    public init(
        name: String,
        uriTemplate: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        annotations: MCPAnnotations? = nil
    ) {
        self.name = name
        self.title = title
        self.uriTemplate = uriTemplate
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

public struct MCPListResourcesParams: Hashable, Codable, Sendable {
    public var cursor: MCPCursor?
    public init(cursor: MCPCursor? = nil) { self.cursor = cursor }
}

public struct MCPListResourcesResult: Hashable, Codable, Sendable {
    public var resources: [MCPResource]
    public var nextCursor: MCPCursor?
    public init(resources: [MCPResource], nextCursor: MCPCursor? = nil) {
        self.resources = resources
        self.nextCursor = nextCursor
    }
}

public struct MCPListResourceTemplatesParams: Hashable, Codable, Sendable {
    public var cursor: MCPCursor?
    public init(cursor: MCPCursor? = nil) { self.cursor = cursor }
}

public struct MCPListResourceTemplatesResult: Hashable, Codable, Sendable {
    public var resourceTemplates: [MCPResourceTemplate]
    public var nextCursor: MCPCursor?
    public init(resourceTemplates: [MCPResourceTemplate], nextCursor: MCPCursor? = nil) {
        self.resourceTemplates = resourceTemplates
        self.nextCursor = nextCursor
    }
}

public struct MCPReadResourceParams: Hashable, Codable, Sendable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}

public struct MCPReadResourceResult: Hashable, Codable, Sendable {
    public var contents: [MCPResourceContents]
    public init(contents: [MCPResourceContents]) { self.contents = contents }
}

public struct MCPSubscribeParams: Hashable, Codable, Sendable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}

public struct MCPUnsubscribeParams: Hashable, Codable, Sendable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}

public struct MCPResourceUpdatedParams: Hashable, Codable, Sendable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}
