import Foundation

/// Per-named-server CLI-exposure config. Carries the executable that
/// every tool in this server resolves through, optional cwd + env
/// applied to each invocation, and the list of tools advertised to
/// MCP clients via `tools/list`.
public struct CLIExposureConfig: Codable, Hashable, Sendable {
    public var executable: String
    public var cwd: String?
    public var env: [String: String]?
    public var tools: [CLIToolSpec]

    public init(
        executable: String,
        tools: [CLIToolSpec],
        cwd: String? = nil,
        env: [String: String]? = nil
    ) {
        self.executable = executable
        self.cwd = cwd
        self.env = env
        self.tools = tools
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

