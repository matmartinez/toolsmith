import Foundation
import Testing

@testable import Toolsmith

@Suite("CLIToolsLoader")
struct CLIToolsLoaderTests {
    private func writeTempFile(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "toolsmith-cli-\(UUID().uuidString).json"
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("Decodes a full cliServers entry with every argv variant")
    func decodesAllVariants() throws {
        let path = try writeTempFile("""
        {
          "cliServers": {
            "git": {
              "executable": "/usr/bin/git",
              "cwd": "/tmp",
              "env": { "GIT_PAGER": "cat" },
              "tools": [
                {
                  "name": "log",
                  "description": "Show commit logs.",
                  "inputSchema": {
                    "type": "object",
                    "properties": {
                      "path":    { "type": "string" },
                      "limit":   { "type": "integer" },
                      "verbose": { "type": "boolean" }
                    }
                  },
                  "argv": [
                    { "literal": "log" },
                    { "flag": "-n", "argument": "limit" },
                    { "booleanFlag": "--stat", "argument": "verbose" },
                    { "optionalArgument": "path" }
                  ]
                }
              ]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let file = try CLIToolsLoader.load(contentsOfFile: path)
        let git = try #require(file.cliServers["git"])
        #expect(git.executable == "/usr/bin/git")
        #expect(git.cwd == "/tmp")
        #expect(git.env == ["GIT_PAGER": "cat"])
        #expect(git.tools.count == 1)

        let log = git.tools[0]
        #expect(log.name == "log")
        #expect(log.description == "Show commit logs.")
        #expect(log.argv == [
            .literal("log"),
            .flag(literal: "-n", argument: "limit"),
            .booleanFlag(literal: "--stat", argument: "verbose"),
            .optionalArgument(name: "path"),
        ])
    }

    @Test("Missing file throws fileNotFound")
    func missingFile() {
        #expect(throws: CLIToolsLoader.Failure.fileNotFound("/no/such/path.json")) {
            _ = try CLIToolsLoader.load(contentsOfFile: "/no/such/path.json")
        }
    }

    @Test("Malformed JSON throws malformedJSON")
    func malformedJSON() throws {
        let path = try writeTempFile("{not json}")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try CLIToolsLoader.load(contentsOfFile: path)
        }
    }

    @Test("Missing cliServers top-level key fails decode")
    func missingTopLevelKey() throws {
        let path = try writeTempFile(#"{"some_other_key":"value"}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try CLIToolsLoader.load(contentsOfFile: path)
        }
    }

    @Test("Entry missing required `executable` fails decode")
    func missingExecutable() throws {
        let path = try writeTempFile(#"{"cliServers":{"x":{"tools":[]}}}"#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: (any Error).self) {
            _ = try CLIToolsLoader.load(contentsOfFile: path)
        }
    }

    @Test("specs(from:) sorts entries alphabetically for deterministic mount order")
    func sortsByName() {
        let file = CLIToolsFile(cliServers: [
            "zeta": CLIExposureConfig(executable: "/x", tools: []),
            "alpha": CLIExposureConfig(executable: "/x", tools: []),
            "beta": CLIExposureConfig(executable: "/x", tools: []),
        ])
        let specs = CLIToolsLoader.specs(from: file)
        #expect(specs.map(\.name) == ["alpha", "beta", "zeta"])
    }

    @Test("specs(from:) carries cliExposure backend payloads")
    func specsCarryPayload() {
        let exposure = CLIExposureConfig(
            executable: "/bin/echo",
            tools: [CLIToolSpec(
                name: "say",
                inputSchema: ["type": "object"],
                argv: [.argument(name: "message")]
            )]
        )
        let file = CLIToolsFile(cliServers: ["say": exposure])
        let specs = CLIToolsLoader.specs(from: file)
        #expect(specs.count == 1)
        guard case let .cliExposure(carried) = specs[0].backend else {
            Issue.record("expected cliExposure backend")
            return
        }
        #expect(carried.executable == "/bin/echo")
        #expect(carried.tools.count == 1)
        #expect(carried.tools[0].name == "say")
    }
}
