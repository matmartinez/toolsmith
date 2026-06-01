import Foundation
import NIO

/// Orchestrates server mode: spawns one or more MCP servers as child
/// processes and exposes each via the HTTP server. The "default"
/// server (declared with the positional command) is mounted at root
/// paths `/sse` + `/messages`. Each `--named-server` entry is mounted
/// under `/servers/<name>/sse` + `/servers/<name>/messages`.
public actor ServerModeProxy {
    /// How a named server's traffic is satisfied. Existing entries
    /// (positional command, --named-server, --named-server-config)
    /// resolve to `.stdioChild`, which spawns a child MCP server via
    /// `ChildSession`. The new `--cli-tools-config` resolves to
    /// `.cliExposure`, served by an in-process `CLIBackend` that shells
    /// out per `tools/call`.
    public enum BackendKind: Sendable {
        case stdioChild(executable: URL, args: [String], env: [String: String]?, cwd: URL?)
        case cliExposure(CLIExposureConfig)
    }

    public struct NamedServer: Sendable {
        public let name: String  // empty == default, mounted at root
        public let backend: BackendKind

        public init(name: String, backend: BackendKind) {
            self.name = name
            self.backend = backend
        }

        /// Convenience for stdio entries — keeps the older call sites
        /// (tests, CLI plumbing) ergonomic.
        public init(
            name: String,
            executable: URL,
            args: [String] = [],
            env: [String: String]? = nil,
            cwd: URL? = nil
        ) {
            self.init(name: name, backend: .stdioChild(executable: executable, args: args, env: env, cwd: cwd))
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case noServers
        case duplicateName(String)
    }

    public let host: String
    public let port: Int
    public let servers: [NamedServer]
    public let version: String
    public let cors: CORSConfig?

    private var backends: [any MCPServerBackend] = []
    private var httpServer: HTTPServer?
    public let activity = ActivityTracker()

    public init(
        host: String,
        port: Int,
        servers: [NamedServer],
        version: String = "0.0.0",
        cors: CORSConfig? = nil
    ) throws {
        guard !servers.isEmpty else { throw Failure.noServers }
        var seen = Set<String>()
        for spec in servers {
            if !seen.insert(spec.name).inserted {
                throw Failure.duplicateName(spec.name)
            }
        }
        self.host = host
        self.port = port
        self.servers = servers
        self.version = version
        self.cors = cors
    }

    /// Construct every backend, register its routes, and bind the HTTP
    /// listener. Returns the resolved local address.
    public func start() async throws -> SocketAddress {
        var router = ServerRouter()
        for spec in servers {
            let backend: any MCPServerBackend
            switch spec.backend {
            case let .stdioChild(executable, args, env, cwd):
                backend = ChildSession(executable: executable, args: args, env: env, cwd: cwd)
            case let .cliExposure(config):
                backend = CLIBackend(
                    exposure: config,
                    serverInfo: MCPImplementation(
                        name: spec.name.isEmpty ? "toolsmith-cli" : spec.name,
                        version: version
                    )
                )
            }
            try await backend.start()
            let prefix = spec.name.isEmpty ? "" : "/servers/\(spec.name)"
            ServerModeRoutes.register(
                on: &router,
                backend: backend,
                ssePath: prefix + "/sse",
                postPath: prefix + "/messages",
                activity: activity
            )
            StreamableHTTPRoutes.register(
                on: &router,
                backend: backend,
                path: prefix + "/mcp",
                activity: activity
            )
            backends.append(backend)
        }
        StatusRoute.register(
            on: &router,
            serverNames: servers.map(\.name),
            activity: activity,
            version: version
        )
        if let cors { applyCORS(to: &router, config: cors) }
        let httpServer = HTTPServer(router: router)
        let address = try await httpServer.start(host: host, port: port)
        self.httpServer = httpServer
        return address
    }

    public func stop() async {
        try? await httpServer?.stop()
        httpServer = nil
        for backend in backends { await backend.stop() }
        backends.removeAll()
    }
}
