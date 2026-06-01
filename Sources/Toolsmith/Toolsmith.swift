import ArgumentParser
import Foundation

extension TransportKind: ExpressibleByArgument {}
extension LogLevel: ExpressibleByArgument {}

@main
struct Toolsmith: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toolsmith",
        abstract: "Bridge MCP transports (stdio ↔ SSE/StreamableHTTP).",
        version: "0.0.0"
    )

    // MARK: Positional

    @Argument(help: "MCP server command, or an http(s):// URL for client mode. Falls back to $SSE_URL.")
    var commandOrUrl: String?

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed to the spawned server command.")
    var args: [String] = []

    // MARK: Client-mode options

    @Option(
        name: [.customShort("H"), .customLong("header")],
        parsing: .singleValue,
        help: ArgumentHelp(#"Custom request header, e.g. "Authorization: Bearer x". Repeat for multiple."#, valueName: "NAME: VALUE")
    )
    var headers: [String] = []

    @Option(help: "Transport for the remote endpoint.")
    var transport: TransportKind = .sse

    @Option(help: "OAuth2 client ID.")
    var clientId: String?

    @Option(help: "OAuth2 client secret.")
    var clientSecret: String?

    @Option(help: "OAuth2 token endpoint URL.")
    var tokenUrl: String?

    @Option(name: .customLong("verify-ssl"), help: "Path to a PEM CA bundle to validate against.")
    var verifySslPath: String?

    @Flag(name: .customLong("no-verify-ssl"), help: "Disable TLS certificate verification.")
    var noVerifySsl: Bool = false

    // MARK: Stdio/spawn options

    @Option(
        name: [.short, .customLong("env")],
        parsing: .singleValue,
        help: ArgumentHelp("Environment variable for the spawned server, KEY=VALUE. Repeat for multiple.", valueName: "KEY=VALUE")
    )
    var env: [String] = []

    @Option(help: "Working directory for the spawned server.")
    var cwd: String?

    @Flag(help: "Inherit Toolsmith's environment when spawning the server.")
    var passEnvironment: Bool = false

    @Option(name: .customLong("log-level"), help: "Logging verbosity.")
    var logLevel: LogLevel = .info

    @Flag(help: "Shortcut for --log-level DEBUG.")
    var debug: Bool = false

    @Option(
        name: .customLong("named-server"),
        parsing: .singleValue,
        help: ArgumentHelp("Named server exposed at /servers/<NAME>/, in NAME=COMMAND form. Repeat for multiple.", valueName: "NAME=COMMAND")
    )
    var namedServer: [String] = []

    @Option(name: .customLong("named-server-config"), help: "Path to a JSON file declaring named servers.")
    var namedServerConfig: String?

    // MARK: HTTP server options

    @Option(help: "Port for the local HTTP server (0 = random).")
    var port: Int = 0

    @Option(help: "Listen address for the local HTTP server.")
    var host: String = "127.0.0.1"

    @Flag(help: "Enable stateless mode for the streamable-HTTP endpoint.")
    var stateless: Bool = false

    @Option(name: .customLong("sse-port"), help: "Deprecated alias for --port.")
    var ssePort: Int?

    @Option(name: .customLong("sse-host"), help: "Deprecated alias for --host.")
    var sseHost: String?

    @Option(
        name: .customLong("allow-origin"),
        parsing: .singleValue,
        help: ArgumentHelp("CORS allowed origin. Repeat for multiple.", valueName: "ORIGIN")
    )
    var allowOrigin: [String] = []

    @Option(
        name: .customLong("expose-header"),
        parsing: .singleValue,
        help: ArgumentHelp("CORS exposed response header. Repeat for multiple.", valueName: "HEADER")
    )
    var exposeHeader: [String] = []

    // MARK: Validation & run

    mutating func validate() throws {
        if commandOrUrl == nil {
            commandOrUrl = ProcessInfo.processInfo.environment["SSE_URL"]
        }

        for header in headers where !header.contains(":") {
            throw ValidationError(#"--header value "\#(header)" must be in "NAME: VALUE" form."#)
        }
        for entry in env where !entry.contains("=") {
            throw ValidationError(#"--env value "\#(entry)" must be in "KEY=VALUE" form."#)
        }
        for entry in namedServer where !entry.contains("=") {
            throw ValidationError(#"--named-server value "\#(entry)" must be in "NAME=COMMAND" form."#)
        }

        let hasDefaultServer = commandOrUrl != nil
        let hasNamedServer = !namedServer.isEmpty
        let hasConfig = namedServerConfig != nil
        if !(hasDefaultServer || hasNamedServer || hasConfig) {
            throw ValidationError("Provide a command-or-URL, --named-server, or --named-server-config.")
        }

        if let ssePort, self.port == 0 { self.port = ssePort }
        if let sseHost, self.host == "127.0.0.1" { self.host = sseHost }
    }

    mutating func run() async throws {
        switch Mode.detect(commandOrUrl: commandOrUrl) {
        case .client:
            try await runClientMode()
        case .server:
            FileHandle.standardError.write(Data("toolsmith: server mode not implemented yet\n".utf8))
            throw ExitCode.failure
        }
    }

    private func runClientMode() async throws {
        guard let raw = commandOrUrl, let url = URL(string: raw) else {
            throw ValidationError("client mode requires an http(s):// URL")
        }
        let parsed = try Self.parseHeaders(headers)

        var httpClient: HTTPClient = URLSessionHTTPClient(verifyTLS: !noVerifySsl)
        if let oauth = makeOAuthProvider(httpClient: httpClient) {
            httpClient = BearerTokenHTTPClient(inner: httpClient) {
                try await oauth.accessToken()
            }
        } else if let token = ProcessInfo.processInfo.environment["API_ACCESS_TOKEN"],
                  !parsed.contains(where: { $0.0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            httpClient = BearerTokenHTTPClient(inner: httpClient) { token }
        }

        let remote: ClientTransport
        switch transport {
        case .sse:
            remote = SSEClientTransport(url: url, headers: parsed, httpClient: httpClient)
        case .streamablehttp:
            remote = StreamableHTTPClientTransport(url: url, headers: parsed, httpClient: httpClient)
        }

        let local = StdioTransport(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput
        )
        try await ClientModeProxy.run(local: local, remote: remote)
    }

    private func makeOAuthProvider(httpClient: HTTPClient) -> OAuth2ClientCredentialsProvider? {
        guard let id = clientId,
              let secret = clientSecret,
              let urlString = tokenUrl,
              let url = URL(string: urlString)
        else { return nil }
        return OAuth2ClientCredentialsProvider(
            clientId: id,
            clientSecret: secret,
            tokenURL: url,
            httpClient: httpClient
        )
    }

    static func parseHeaders(_ raw: [String]) throws -> [(String, String)] {
        try raw.map { value in
            guard let colon = value.firstIndex(of: ":") else {
                throw ValidationError(#"malformed --header "\#(value)"; expected "NAME: VALUE""#)
            }
            let name = value[..<colon].trimmingCharacters(in: .whitespaces)
            var rest = value[value.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            return (name, String(rest))
        }
    }
}
