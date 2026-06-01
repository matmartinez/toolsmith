import Foundation
import NIO

/// Orchestrates server mode: spawns one or more MCP servers as child
/// processes and exposes each via the HTTP server. The "default"
/// server (declared with the positional command) is mounted at root
/// paths `/sse` + `/messages`. Each `--named-server` entry is mounted
/// under `/servers/<name>/sse` + `/servers/<name>/messages`.
public actor ServerModeProxy {
    public struct NamedServer: Sendable {
        public let name: String  // empty == default, mounted at root
        public let executable: URL
        public let args: [String]
        public let env: [String: String]?
        public let cwd: URL?

        public init(
            name: String,
            executable: URL,
            args: [String] = [],
            env: [String: String]? = nil,
            cwd: URL? = nil
        ) {
            self.name = name
            self.executable = executable
            self.args = args
            self.env = env
            self.cwd = cwd
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

    private var children: [ChildSession] = []
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

    /// Spawn every server, register their routes, and bind the HTTP
    /// listener. Returns the resolved local address.
    public func start() async throws -> SocketAddress {
        var router = ServerRouter()
        for spec in servers {
            let child = ChildSession(
                executable: spec.executable,
                args: spec.args,
                env: spec.env,
                cwd: spec.cwd
            )
            try await child.start()
            let prefix = spec.name.isEmpty ? "" : "/servers/\(spec.name)"
            ServerModeRoutes.register(
                on: &router,
                child: child,
                ssePath: prefix + "/sse",
                postPath: prefix + "/messages",
                activity: activity
            )
            StreamableHTTPRoutes.register(
                on: &router,
                child: child,
                path: prefix + "/mcp",
                activity: activity
            )
            children.append(child)
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
        for child in children { await child.stop() }
        children.removeAll()
    }
}
