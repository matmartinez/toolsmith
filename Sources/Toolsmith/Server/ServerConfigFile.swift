import Foundation

/// On-disk shape of a `--named-server-config` file. Matches the
/// upstream mcp-proxy schema: a top-level `mcpServers` object keyed
/// by server name.
///
/// Per upstream, `timeout` and `transportType` are accepted but
/// ignored. `enabled` defaults to true; entries with `"enabled":
/// false` are filtered out at load time.
public struct ServerConfigFile: Codable, Hashable, Sendable {
    public var mcpServers: [String: ServerConfigEntry]

    public init(mcpServers: [String: ServerConfigEntry]) {
        self.mcpServers = mcpServers
    }
}

public struct ServerConfigEntry: Codable, Hashable, Sendable {
    public var command: String
    public var args: [String]?
    public var env: [String: String]?
    public var enabled: Bool?
    // The following fields are parsed for compatibility but ignored.
    public var timeout: Double?
    public var transportType: String?

    public init(
        command: String,
        args: [String]? = nil,
        env: [String: String]? = nil,
        enabled: Bool? = nil,
        timeout: Double? = nil,
        transportType: String? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
        self.timeout = timeout
        self.transportType = transportType
    }

    public var isEnabled: Bool { enabled ?? true }
}

public enum ServerConfigLoader {
    public enum Failure: Error, Sendable, Equatable {
        case fileNotFound(String)
        case malformedJSON(String)
    }

    public static func load(contentsOfFile path: String) throws -> ServerConfigFile {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.fileNotFound(path)
        }
        do {
            return try JSONDecoder().decode(ServerConfigFile.self, from: data)
        } catch {
            throw Failure.malformedJSON(error.localizedDescription)
        }
    }

    /// Convert a parsed config file into the spec list ServerModeProxy
    /// expects. `defaultEnv` is the env merged in underneath each
    /// per-server `env` block (CLI --env values, optionally plus the
    /// parent process env when --pass-environment is set).
    public static func specs(
        from config: ServerConfigFile,
        executable: URL,
        defaultEnv: [String: String]?,
        cwd: URL?
    ) -> [ServerModeProxy.NamedServer] {
        config.mcpServers.compactMap { name, entry -> ServerModeProxy.NamedServer? in
            guard entry.isEnabled else { return nil }
            var merged: [String: String] = defaultEnv ?? [:]
            for (key, value) in entry.env ?? [:] { merged[key] = value }
            return ServerModeProxy.NamedServer(
                name: name,
                executable: executable,
                args: [entry.command] + (entry.args ?? []),
                env: merged.isEmpty ? nil : merged,
                cwd: cwd
            )
        }
        .sorted { $0.name < $1.name }  // deterministic mount order
    }
}
