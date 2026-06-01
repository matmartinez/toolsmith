import Foundation

public struct MCPTextContent: Hashable, Codable, Sendable {
    public var text: String
    public var annotations: MCPAnnotations?
    public init(text: String, annotations: MCPAnnotations? = nil) {
        self.text = text
        self.annotations = annotations
    }
}

public struct MCPImageContent: Hashable, Codable, Sendable {
    public var data: String
    public var mimeType: String
    public var annotations: MCPAnnotations?
    public init(data: String, mimeType: String, annotations: MCPAnnotations? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

public struct MCPAudioContent: Hashable, Codable, Sendable {
    public var data: String
    public var mimeType: String
    public var annotations: MCPAnnotations?
    public init(data: String, mimeType: String, annotations: MCPAnnotations? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

public struct MCPResourceLink: Hashable, Codable, Sendable {
    public var resource: MCPResource
    public init(resource: MCPResource) { self.resource = resource }
}

public struct MCPEmbeddedResource: Hashable, Codable, Sendable {
    public var resource: MCPResourceContents
    public var annotations: MCPAnnotations?
    public init(resource: MCPResourceContents, annotations: MCPAnnotations? = nil) {
        self.resource = resource
        self.annotations = annotations
    }
}

/// A content block returned by tools or embedded in prompts.
/// Wire form is discriminated by `type`.
public enum MCPContent: Hashable, Sendable {
    case text(MCPTextContent)
    case image(MCPImageContent)
    case audio(MCPAudioContent)
    case resourceLink(MCPResource)
    case resource(MCPEmbeddedResource)
}

extension MCPContent: Codable {
    private enum CodingKeys: String, CodingKey { case type }

    private enum Kind: String {
        case text
        case image
        case audio
        case resourceLink = "resource_link"
        case resource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type \"\(raw)\"."
            )
        }
        switch kind {
        case .text: self = .text(try MCPTextContent(from: decoder))
        case .image: self = .image(try MCPImageContent(from: decoder))
        case .audio: self = .audio(try MCPAudioContent(from: decoder))
        case .resourceLink: self = .resourceLink(try MCPResource(from: decoder))
        case .resource: self = .resource(try MCPEmbeddedResource(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text.rawValue, forKey: .type)
            try value.encode(to: encoder)
        case .image(let value):
            try container.encode(Kind.image.rawValue, forKey: .type)
            try value.encode(to: encoder)
        case .audio(let value):
            try container.encode(Kind.audio.rawValue, forKey: .type)
            try value.encode(to: encoder)
        case .resourceLink(let value):
            try container.encode(Kind.resourceLink.rawValue, forKey: .type)
            try value.encode(to: encoder)
        case .resource(let value):
            try container.encode(Kind.resource.rawValue, forKey: .type)
            try value.encode(to: encoder)
        }
    }
}
