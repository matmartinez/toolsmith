import Foundation
import Testing

@testable import Toolsmith

@Suite("ServerConfigLoader")
struct ServerConfigLoaderTests {
    private func writeTempFile(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "toolsmith-\(UUID().uuidString).json"
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("Decodes mcpServers with command, args, env")
    func decodes() throws {
        let path = try writeTempFile("""
        {
          "mcpServers": {
            "fetch": {
              "command": "uvx",
              "args": ["mcp-server-fetch"],
              "env": {"LOG_LEVEL": "info"},
              "timeout": 60,
              "transportType": "stdio"
            },
            "node": {
              "command": "node",
              "args": ["/opt/server.js"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try ServerConfigLoader.load(contentsOfFile: path)
        #expect(config.mcpServers.count == 2)
        #expect(config.mcpServers["fetch"]?.command == "uvx")
        #expect(config.mcpServers["fetch"]?.args == ["mcp-server-fetch"])
        #expect(config.mcpServers["fetch"]?.env == ["LOG_LEVEL": "info"])
        #expect(config.mcpServers["node"]?.command == "node")
        #expect(config.mcpServers["node"]?.args == ["/opt/server.js"])
    }

    @Test("isEnabled defaults to true when omitted")
    func defaultEnabled() throws {
        let entry = ServerConfigEntry(command: "x")
        #expect(entry.isEnabled == true)
    }

    @Test("Disabled entries are filtered out of specs")
    func filtersDisabled() {
        let config = ServerConfigFile(mcpServers: [
            "a": ServerConfigEntry(command: "cat"),
            "b": ServerConfigEntry(command: "cat", enabled: false),
        ])
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: nil,
            cwd: nil
        )
        #expect(specs.map(\.name) == ["a"])
    }

    @Test("specs sorts entries alphabetically for deterministic mount order")
    func sortsByName() {
        let config = ServerConfigFile(mcpServers: [
            "zeta": ServerConfigEntry(command: "cat"),
            "alpha": ServerConfigEntry(command: "cat"),
            "beta": ServerConfigEntry(command: "cat"),
        ])
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: nil,
            cwd: nil
        )
        #expect(specs.map(\.name) == ["alpha", "beta", "zeta"])
    }

    @Test("Per-entry env layers on top of defaultEnv")
    func envLayering() {
        let config = ServerConfigFile(mcpServers: [
            "x": ServerConfigEntry(
                command: "cat",
                env: ["FOO": "from-config", "EXTRA": "config-only"]
            ),
        ])
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: ["FOO": "from-cli", "CLI_ONLY": "v"],
            cwd: nil
        )
        let env = specs[0].env ?? [:]
        #expect(env["FOO"] == "from-config")  // per-entry wins
        #expect(env["EXTRA"] == "config-only")
        #expect(env["CLI_ONLY"] == "v")
    }

    @Test("specs builds /usr/bin/env args = [command, args...]")
    func argsLayout() {
        let config = ServerConfigFile(mcpServers: [
            "x": ServerConfigEntry(command: "uvx", args: ["mcp-server-fetch", "--port=8080"]),
        ])
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: nil,
            cwd: nil
        )
        #expect(specs[0].args == ["uvx", "mcp-server-fetch", "--port=8080"])
    }

    @Test("Missing file throws fileNotFound")
    func missingFile() {
        #expect(throws: ServerConfigLoader.Failure.fileNotFound("/no/such/path.json")) {
            _ = try ServerConfigLoader.load(contentsOfFile: "/no/such/path.json")
        }
    }

    @Test("Malformed JSON throws malformedJSON")
    func malformed() throws {
        let path = try writeTempFile("{not json}")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }
}
