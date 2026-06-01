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
        name: [.customShort("H"), .customLong("headers")],
        parsing: .upToNextOption,
        help: ArgumentHelp("Custom request headers. Repeat for multiple.", valueName: "KEY VALUE")
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
        parsing: .upToNextOption,
        help: ArgumentHelp("Environment variable for the spawned server. Repeat for multiple.", valueName: "KEY VALUE")
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
        parsing: .upToNextOption,
        help: ArgumentHelp("Define a named server, exposed at /servers/<NAME>/. Repeat for multiple.", valueName: "NAME COMMAND")
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

        if headers.count % 2 != 0 {
            throw ValidationError("--headers expects KEY VALUE pairs; got an odd number of values.")
        }
        if env.count % 2 != 0 {
            throw ValidationError("--env expects KEY VALUE pairs; got an odd number of values.")
        }
        if namedServer.count % 2 != 0 {
            throw ValidationError("--named-server expects NAME COMMAND pairs; got an odd number of values.")
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
        let mode = Mode.detect(commandOrUrl: commandOrUrl)
        let effectiveLogLevel: LogLevel = debug ? .debug : logLevel

        print("toolsmith: mode=\(mode) commandOrUrl=\(commandOrUrl ?? "<nil>") args=\(args)")
        print("toolsmith: transport=\(transport) host=\(host) port=\(port) stateless=\(stateless)")
        print("toolsmith: logLevel=\(effectiveLogLevel) passEnvironment=\(passEnvironment)")
        if !namedServer.isEmpty { print("toolsmith: namedServer=\(namedServer)") }
        if let namedServerConfig { print("toolsmith: namedServerConfig=\(namedServerConfig)") }
        print("toolsmith: not implemented")
    }
}
