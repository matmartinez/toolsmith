import Foundation

/// A resource the server can read. Reused inside `ResourceLink` content
/// blocks and the standalone `resources/*` endpoints.
public struct MCPResource: Hashable, Codable, Sendable {
    public var name: String
    public var title: String?
    public var uri: String
    public var description: String?
    public var mimeType: String?
    public var annotations: MCPAnnotations?
    public var size: Int?

    public init(
        name: String,
        uri: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        annotations: MCPAnnotations? = nil,
        size: Int? = nil
    ) {
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.size = size
    }
}

public struct MCPTextResourceContents: Hashable, Codable, Sendable {
    public var uri: String
    public var mimeType: String?
    public var text: String

    public init(uri: String, text: String, mimeType: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }
}

public struct MCPBlobResourceContents: Hashable, Codable, Sendable {
    public var uri: String
    public var mimeType: String?
    /// Base64-encoded binary payload.
    public var blob: String

    public init(uri: String, blob: String, mimeType: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.blob = blob
    }
}

/// Text-or-blob resource contents, discriminated by which payload field
/// (`text` or `blob`) is present.
public enum MCPResourceContents: Hashable, Sendable {
    case text(MCPTextResourceContents)
    case blob(MCPBlobResourceContents)
}

extension MCPResourceContents: Codable {
    private enum Keys: String, CodingKey { case text, blob }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.text) {
            self = .text(try MCPTextResourceContents(from: decoder))
        } else if container.contains(.blob) {
            self = .blob(try MCPBlobResourceContents(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Resource contents must carry `text` or `blob`."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value): try value.encode(to: encoder)
        case .blob(let value): try value.encode(to: encoder)
        }
    }
}
