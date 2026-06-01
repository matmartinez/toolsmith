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

    @Option(name: .customLong("cli-tools-config"), help: "Path to a JSON file declaring host CLIs to expose as MCP servers.")
    var cliToolsConfig: String?

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
        let hasCLITools = cliToolsConfig != nil
        if !(hasDefaultServer || hasNamedServer || hasConfig || hasCLITools) {
            throw ValidationError("Provide a command-or-URL, --named-server, --named-server-config, or --cli-tools-config.")
        }

        if let ssePort, self.port == 0 { self.port = ssePort }
        if let sseHost, self.host == "127.0.0.1" { self.host = sseHost }
    }

    mutating func run() async throws {
        Logger.shared.setMinLevel(debug ? .debug : logLevel)
        switch Mode.detect(commandOrUrl: commandOrUrl) {
        case .client:
            Logger.shared.debug("entering client mode")
            try await runClientMode()
        case .server:
            Logger.shared.debug("entering server mode")
            try await runServerMode()
        }
    }

    private func runServerMode() async throws {
        let envDict = try Self.parseEnvPairs(env)
        let environment = Self.mergeEnvironment(envDict, passEnvironment: passEnvironment)
        let workingDirectory = cwd.map { URL(fileURLWithPath: $0) }
        let envURL = URL(fileURLWithPath: "/usr/bin/env")

        var specs: [ServerModeProxy.NamedServer] = []
        if let defaultCommand = commandOrUrl {
            specs.append(ServerModeProxy.NamedServer(
                name: "",
                executable: envURL,
                args: [defaultCommand] + args,
                env: environment,
                cwd: workingDirectory
            ))
        }
        for entry in try Self.parseNamedServerEntries(namedServer) {
            specs.append(ServerModeProxy.NamedServer(
                name: entry.name,
                executable: envURL,
                args: entry.commandWords,
                env: environment,
                cwd: workingDirectory
            ))
        }

        if let path = namedServerConfig {
            let configFile = try ServerConfigLoader.load(contentsOfFile: path)
            specs.append(contentsOf: ServerConfigLoader.specs(
                from: configFile,
                executable: envURL,
                defaultEnv: environment,
                cwd: workingDirectory
            ))
        }

        if let path = cliToolsConfig {
            let cliFile = try CLIToolsLoader.load(contentsOfFile: path)
            specs.append(contentsOf: CLIToolsLoader.specs(from: cliFile))
        }

        let cors: CORSConfig? = allowOrigin.isEmpty
            ? nil
            : CORSConfig(allowedOrigins: allowOrigin, exposedHeaders: exposeHeader)
        for spec in specs {
            let label = spec.name.isEmpty ? "(default)" : spec.name
            let summary: String
            switch spec.backend {
            case let .stdioChild(_, args, _, _):
                summary = args.joined(separator: " ")
            case .cliExposure:
                summary = "<cli-tools exposure>"
            }
            Logger.shared.info("setting up server '\(label)': \(summary)")
        }
        let proxy = try ServerModeProxy(host: host, port: port, servers: specs, cors: cors)
        let address = try await proxy.start()
        Logger.shared.info("listening on http://\(host):\(address.port ?? port)")

        await Self.waitForTerminationSignal()
        Logger.shared.info("shutdown signal received; stopping")
        await proxy.stop()
    }

    static func mergeEnvironment(
        _ explicit: [String: String],
        passEnvironment: Bool
    ) -> [String: String]? {
        if passEnvironment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in explicit { merged[key] = value }
            return merged
        }
        return explicit.isEmpty ? nil : explicit
    }

    struct NamedServerEntry: Equatable {
        var name: String
        var commandWords: [String]
    }

    static func parseNamedServerEntries(_ raw: [String]) throws -> [NamedServerEntry] {
        try raw.map { value in
            guard let equals = value.firstIndex(of: "=") else {
                throw ValidationError(#"malformed --named-server "\#(value)"; expected "NAME=COMMAND""#)
            }
            let name = String(value[..<equals])
            guard !name.isEmpty else {
                throw ValidationError("--named-server name cannot be empty")
            }
            let command = String(value[value.index(after: equals)...])
            let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard !words.isEmpty else {
                throw ValidationError("--named-server \"\(name)\" has an empty command")
            }
            return NamedServerEntry(name: name, commandWords: words)
        }
    }

    static func parseEnvPairs(_ raw: [String]) throws -> [String: String] {
        var dict: [String: String] = [:]
        for entry in raw {
            guard let equals = entry.firstIndex(of: "=") else {
                throw ValidationError(#"malformed --env "\#(entry)"; expected "KEY=VALUE""#)
            }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            dict[key] = value
        }
        return dict
    }

    /// Suspends until the process receives SIGINT or SIGTERM. We
    /// install dispatch-source-backed handlers so the existing default
    /// disposition (process exit) is suppressed and we can shut the
    /// HTTP server + child down cleanly before returning.
    private static func waitForTerminationSignal() async {
        let stream = AsyncStream<Int32> { continuation in
            let queue = DispatchQueue(label: "toolsmith.signal")
            let sources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { continuation.yield(sig) }
                source.resume()
                signal(sig, SIG_IGN)
                return source
            }
            continuation.onTermination = { _ in
                for source in sources { source.cancel() }
            }
        }
        for await _ in stream { break }
    }

    private func runClientMode() async throws {
        guard let raw = commandOrUrl, let url = URL(string: raw) else {
            throw ValidationError("client mode requires an http(s):// URL")
        }
        let parsed = try Self.parseHeaders(headers)

        var httpClient: HTTPClient = URLSessionHTTPClient(verifyTLS: !noVerifySsl)
        if let oauth = makeOAuthProvider(httpClient: httpClient) {
            Logger.shared.info("using OAuth2 client-credentials against \(oauth.tokenURL)")
            httpClient = BearerTokenHTTPClient(inner: httpClient) {
                try await oauth.accessToken()
            }
        } else if let token = ProcessInfo.processInfo.environment["API_ACCESS_TOKEN"],
                  !parsed.contains(where: { $0.0.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            Logger.shared.debug("API_ACCESS_TOKEN present; injecting Authorization header")
            httpClient = BearerTokenHTTPClient(inner: httpClient) { token }
        }

        let remote: ClientTransport
        switch transport {
        case .sse:
            Logger.shared.info("connecting via SSE to \(url)")
            remote = SSEClientTransport(url: url, headers: parsed, httpClient: httpClient)
        case .streamablehttp:
            Logger.shared.info("connecting via streamable-HTTP to \(url)")
            remote = StreamableHTTPClientTransport(url: url, headers: parsed, httpClient: httpClient)
        }

        let local = StdioTransport(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput
        )
        try await ClientModeProxy.run(local: local, remote: remote)
        Logger.shared.info("client mode finished")
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
