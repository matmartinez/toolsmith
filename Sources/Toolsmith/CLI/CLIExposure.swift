import Foundation

/// Per-named-server CLI-exposure config. Carries the executable that
/// every tool in this server resolves through, optional cwd + env
/// applied to each invocation, and the list of tools advertised to
/// MCP clients via `tools/list`. Optionally also declares MCP
/// resources and resource templates served via `resources/*`.
public struct CLIExposureConfig: Codable, Hashable, Sendable {
    public var executable: String
    public var cwd: String?
    public var env: [String: String]?
    public var tools: [CLIToolSpec]
    public var resources: [CLIResourceSpec]?
    public var resourceTemplates: [CLIResourceTemplateSpec]?

    public init(
        executable: String,
        tools: [CLIToolSpec],
        cwd: String? = nil,
        env: [String: String]? = nil,
        resources: [CLIResourceSpec]? = nil,
        resourceTemplates: [CLIResourceTemplateSpec]? = nil
    ) {
        self.executable = executable
        self.cwd = cwd
        self.env = env
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
    }
}

/// How to wrap the subprocess's stdout into MCPResourceContents.
public enum CLIResourceOutput: String, Codable, Hashable, Sendable {
    /// UTF-8 decode stdout → MCPTextResourceContents.
    case text
    /// Base64-encode raw stdout bytes → MCPBlobResourceContents.
    case blob
}

/// One static MCP resource exposed by a CLI server. The `uri` is an
/// exact-match key; on `resources/read uri=<uri>`, the projection runs
/// the configured `argv` and wraps stdout per `output`. A synthetic
/// `uri` argument is available to `argv` so the spec can pass the URI
/// verbatim into the subprocess.
public struct CLIResourceSpec: Codable, Hashable, Sendable {
    public var name: String
    public var title: String?
    public var uri: String
    public var description: String?
    public var mimeType: String?
    public var output: CLIResourceOutput?
    public var argv: [ArgvSpec]

    public init(
        name: String,
        uri: String,
        argv: [ArgvSpec],
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        output: CLIResourceOutput? = nil
    ) {
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.output = output
        self.argv = argv
    }
}

/// One MCP resource template exposed by a CLI server. The
/// `uriTemplate` uses `{name}` placeholders (RFC 6570 operators are
/// intentionally unsupported). Placeholder values become arguments
/// available to `argv`, alongside a synthetic `uri` carrying the
/// inbound URI verbatim.
public struct CLIResourceTemplateSpec: Codable, Hashable, Sendable {
    public var name: String
    public var title: String?
    public var uriTemplate: String
    public var description: String?
    public var mimeType: String?
    public var output: CLIResourceOutput?
    public var argv: [ArgvSpec]

    public init(
        name: String,
        uriTemplate: String,
        argv: [ArgvSpec],
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        output: CLIResourceOutput? = nil
    ) {
        self.name = name
        self.title = title
        self.uriTemplate = uriTemplate
        self.description = description
        self.mimeType = mimeType
        self.output = output
        self.argv = argv
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, uriTemplate, description, mimeType, output, argv
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.uriTemplate = try container.decode(String.self, forKey: .uriTemplate)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        self.output = try container.decodeIfPresent(CLIResourceOutput.self, forKey: .output)
        self.argv = try container.decode([ArgvSpec].self, forKey: .argv)

        // Fail config-load on malformed templates rather than at request time.
        do {
            _ = try URITemplateMatcher.compile(self.uriTemplate)
        } catch let error as URITemplateMatcher.CompileError {
            throw DecodingError.dataCorruptedError(
                forKey: .uriTemplate,
                in: container,
                debugDescription: "Invalid uriTemplate \"\(self.uriTemplate)\": \(error)"
            )
        }
    }
}

/// One MCP tool exposed by a CLI server. The tool's `name`,
/// `description`, and `inputSchema` flow into the `tools/list`
/// response verbatim; the `argv` projection turns the inbound
/// `tools/call` arguments into a concrete subprocess invocation.
public struct CLIToolSpec: Codable, Hashable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue
    public var argv: [ArgvSpec]

    public init(
        name: String,
        inputSchema: JSONValue,
        argv: [ArgvSpec],
        title: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.argv = argv
    }
}

/// One token in a CLI tool's argv spec. Each variant maps a slot in
/// the projected argv to either a literal string or a value drawn from
/// the inbound MCP `tools/call` arguments.
///
/// Wire form (single-key tagged objects):
///
///   { "literal": "log" }
///   { "argument": "path" }
///   { "optionalArgument": "format" }
///   { "flag": "-n", "argument": "limit" }
///   { "booleanFlag": "--verbose", "argument": "verbose" }
public enum ArgvSpec: Hashable, Sendable {
    /// Always emit this literal token.
    case literal(String)

    /// Emit the value of the named MCP argument. Projection fails if
    /// the argument is missing.
    case argument(name: String)

    /// Emit the value of the named MCP argument if it is present.
    /// Skip the token entirely when absent.
    case optionalArgument(name: String)

    /// If the named MCP argument is present, emit the literal token
    /// followed by the argument's value. Skip both when absent.
    case flag(literal: String, argument: String)

    /// If the named MCP argument is present AND its value is the bool
    /// `true`, emit the literal token. Skip otherwise.
    case booleanFlag(literal: String, argument: String)
}

extension ArgvSpec: Codable {
    private enum CodingKeys: String, CodingKey {
        case literal
        case argument
        case optionalArgument
        case flag
        case booleanFlag
    }

    private static let allTagKeys: [CodingKeys] = [
        .literal, .argument, .optionalArgument, .flag, .booleanFlag,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let present = Self.allTagKeys.filter { container.contains($0) }

        // `flag` and `booleanFlag` legitimately require `argument` to
        // appear alongside. Strip `argument` from the conflict check
        // when one of those tag keys is present.
        let primaryTags: Set<CodingKeys> = {
            var keys = Set(present)
            if keys.contains(.flag) || keys.contains(.booleanFlag) {
                keys.remove(.argument)
            }
            return keys
        }()

        guard primaryTags.count == 1, let tag = primaryTags.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "ArgvSpec must declare exactly one of \(Self.allTagKeys.map { $0.rawValue }) — got \(present.map { $0.rawValue })."
            ))
        }

        switch tag {
        case .literal:
            self = .literal(try container.decode(String.self, forKey: .literal))
        case .argument:
            self = .argument(name: try container.decode(String.self, forKey: .argument))
        case .optionalArgument:
            self = .optionalArgument(name: try container.decode(String.self, forKey: .optionalArgument))
        case .flag:
            let lit = try container.decode(String.self, forKey: .flag)
            let arg = try container.decode(String.self, forKey: .argument)
            self = .flag(literal: lit, argument: arg)
        case .booleanFlag:
            let lit = try container.decode(String.self, forKey: .booleanFlag)
            let arg = try container.decode(String.self, forKey: .argument)
            self = .booleanFlag(literal: lit, argument: arg)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .literal(let value):
            try container.encode(value, forKey: .literal)
        case .argument(let name):
            try container.encode(name, forKey: .argument)
        case .optionalArgument(let name):
            try container.encode(name, forKey: .optionalArgument)
        case .flag(let lit, let arg):
            try container.encode(lit, forKey: .flag)
            try container.encode(arg, forKey: .argument)
        case .booleanFlag(let lit, let arg):
            try container.encode(lit, forKey: .booleanFlag)
            try container.encode(arg, forKey: .argument)
        }
    }
}

