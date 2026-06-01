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
        guard case let .stdioChild(_, _, env, _) = specs[0].backend else {
            Issue.record("expected stdioChild backend"); return
        }
        let dict = env ?? [:]
        #expect(dict["FOO"] == "from-config")  // per-entry wins
        #expect(dict["EXTRA"] == "config-only")
        #expect(dict["CLI_ONLY"] == "v")
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
        guard case let .stdioChild(_, args, _, _) = specs[0].backend else {
            Issue.record("expected stdioChild backend"); return
        }
        #expect(args == ["uvx", "mcp-server-fetch", "--port=8080"])
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

    // MARK: - Parity with upstream tests/test_config_loader.py

    @Test("Empty mcpServers dict loads zero specs (upstream: test_empty_mcpservers_dict)")
    func emptyMCPServers() throws {
        let path = try writeTempFile(#"{ "mcpServers": {} }"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = try ServerConfigLoader.load(contentsOfFile: path)
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: nil,
            cwd: nil
        )
        #expect(specs.isEmpty)
    }

    @Test("Missing mcpServers key fails decode (upstream: test_invalid_config_format_missing_mcpservers)")
    func missingMCPServersKey() throws {
        let path = try writeTempFile(#"{"some_other_key":"value"}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Empty JSON object {} fails decode (upstream: test_config_file_is_empty_json_object)")
    func emptyJSONObject() throws {
        let path = try writeTempFile("{}")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Empty file fails decode (upstream: test_config_file_is_empty_string)")
    func emptyFile() throws {
        let path = try writeTempFile("")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Server entry that is not an object fails decode (upstream: test_invalid_server_entry_not_dict)")
    func entryNotAnObject() throws {
        let path = try writeTempFile(#"{"mcpServers":{"server1":"not_a_dict"}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Server entry missing command fails decode (upstream: test_server_entry_missing_command)")
    func entryMissingCommand() throws {
        let path = try writeTempFile(#"{"mcpServers":{"x":{"args":["a"]}}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Server entry with args that is not an array fails decode (upstream: test_server_entry_invalid_args_type)")
    func entryArgsNotAnArray() throws {
        let path = try writeTempFile(#"{"mcpServers":{"x":{"command":"c","args":"not_a_list"}}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try ServerConfigLoader.load(contentsOfFile: path)
        }
    }

    @Test("Mixed enabled/implicit-enabled/disabled (upstream: test_load_config_with_not_enabled_server)")
    func mixedEnabledStates() throws {
        let path = try writeTempFile("""
        {
          "mcpServers": {
            "explicit": {"command": "a", "enabled": true},
            "implicit": {"command": "b"},
            "disabled": {"command": "c", "enabled": false}
          }
        }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = try ServerConfigLoader.load(contentsOfFile: path)
        let specs = ServerConfigLoader.specs(
            from: config,
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            defaultEnv: nil,
            cwd: nil
        )
        #expect(specs.map(\.name) == ["explicit", "implicit"])
    }
}
