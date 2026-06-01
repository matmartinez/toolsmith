import Foundation

public let mcpCompleteMethod = "completion/complete"

public struct MCPPromptReference: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public init(name: String, title: String? = nil) {
        self.name = name
        self.title = title
    }
}

public struct MCPResourceTemplateReference: Hashable, Codable, Sendable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}

/// Discriminated by the wire `type` tag (`ref/prompt` or `ref/resource`).
public enum MCPCompletionRef: Hashable, Sendable {
    case prompt(MCPPromptReference)
    case resourceTemplate(MCPResourceTemplateReference)
}

extension MCPCompletionRef: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    private enum Kind: String {
        case prompt = "ref/prompt"
        case resource = "ref/resource"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown completion ref type \"\(raw)\"."
            )
        }
        switch kind {
        case .prompt: self = .prompt(try MCPPromptReference(from: decoder))
        case .resource: self = .resourceTemplate(try MCPResourceTemplateReference(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prompt(let value):
            try container.encode(Kind.prompt.rawValue, forKey: .type)
            try value.encode(to: encoder)
        case .resourceTemplate(let value):
            try container.encode(Kind.resource.rawValue, forKey: .type)
            try value.encode(to: encoder)
        }
    }
}

public struct MCPCompletionArgument: Hashable, Codable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct MCPCompletionContext: Hashable, Codable, Sendable {
    public var arguments: [String: String]?
    public init(arguments: [String: String]? = nil) { self.arguments = arguments }
}

public struct MCPCompleteParams: Hashable, Codable, Sendable {
    public var ref: MCPCompletionRef
    public var argument: MCPCompletionArgument
    public var context: MCPCompletionContext?

    public init(
        ref: MCPCompletionRef,
        argument: MCPCompletionArgument,
        context: MCPCompletionContext? = nil
    ) {
        self.ref = ref
        self.argument = argument
        self.context = context
    }
}

public struct MCPCompletion: Hashable, Codable, Sendable {
    public var values: [String]
    public var total: Int?
    public var hasMore: Bool?

    public init(values: [String], total: Int? = nil, hasMore: Bool? = nil) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
    }
}

public struct MCPCompleteResult: Hashable, Codable, Sendable {
    public var completion: MCPCompletion
    public init(completion: MCPCompletion) { self.completion = completion }
}
