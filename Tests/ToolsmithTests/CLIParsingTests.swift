import ArgumentParser
import Testing

@testable import Toolsmith

@Suite("CLI parsing")
struct CLIParsingTests {
    private func parse(_ arguments: [String]) throws -> Toolsmith {
        try Toolsmith.parse(arguments)
    }

    @Test("URL positional routes to client mode")
    func urlRoutesToClientMode() throws {
        let cmd = try parse(["http://example.com/sse"])
        #expect(cmd.commandOrUrl == "http://example.com/sse")
        #expect(Mode.detect(commandOrUrl: cmd.commandOrUrl) == .client)
    }

    @Test("HTTPS URL also routes to client mode")
    func httpsUrlRoutesToClientMode() throws {
        let cmd = try parse(["https://example.com/sse"])
        #expect(Mode.detect(commandOrUrl: cmd.commandOrUrl) == .client)
    }

    @Test("Command positional routes to server mode")
    func commandRoutesToServerMode() throws {
        let cmd = try parse(["echo", "hello"])
        #expect(cmd.commandOrUrl == "echo")
        #expect(cmd.args == ["hello"])
        #expect(Mode.detect(commandOrUrl: cmd.commandOrUrl) == .server)
    }

    @Test("Trailing args after command are captured for passthrough")
    func variadicArgsPassthrough() throws {
        let cmd = try parse(["uvx", "mcp-server-fetch", "--some-flag", "value"])
        #expect(cmd.commandOrUrl == "uvx")
        #expect(cmd.args == ["mcp-server-fetch", "--some-flag", "value"])
    }

    @Test("Missing input fails validation")
    func missingInputFails() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parse([])
        }
    }

    @Test("--named-server alone satisfies validation")
    func namedServerSatisfiesValidation() throws {
        let cmd = try parse(["--named-server", "fetch=uvx mcp-server-fetch"])
        #expect(cmd.namedServer == ["fetch=uvx mcp-server-fetch"])
        #expect(cmd.commandOrUrl == nil)
    }

    @Test("--named-server-config alone satisfies validation")
    func namedServerConfigSatisfiesValidation() throws {
        let cmd = try parse(["--named-server-config", "/tmp/servers.json"])
        #expect(cmd.namedServerConfig == "/tmp/servers.json")
    }

    @Test("--header takes a NAME: VALUE string, repeatable")
    func headerParsing() throws {
        let cmd = try parse([
            "-H", "Authorization: Bearer token",
            "-H", "X-Trace: abc",
            "http://example.com/sse",
        ])
        #expect(cmd.headers == ["Authorization: Bearer token", "X-Trace: abc"])
    }

    @Test("--header without colon fails validation")
    func headerWithoutColonFails() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parse([
                "--header", "Authorization",
                "http://example.com/sse",
            ])
        }
    }

    @Test("--env takes KEY=VALUE, repeatable")
    func envParsing() throws {
        let cmd = try parse([
            "-e", "FOO=bar",
            "-e", "BAZ=qux",
            "echo", "hi",
        ])
        #expect(cmd.env == ["FOO=bar", "BAZ=qux"])
    }

    @Test("--env without = fails validation")
    func envWithoutEqualsFails() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parse(["--env", "FOO", "echo"])
        }
    }

    @Test("--named-server takes NAME=COMMAND, repeatable")
    func namedServerParsing() throws {
        let cmd = try parse([
            "--named-server", "a=uvx a-server",
            "--named-server", "b=uvx b-server",
        ])
        #expect(cmd.namedServer == ["a=uvx a-server", "b=uvx b-server"])
    }

    @Test("--no-verify-ssl flag is recognized")
    func noVerifySslFlag() throws {
        let cmd = try parse(["--no-verify-ssl", "http://example.com/sse"])
        #expect(cmd.noVerifySsl == true)
    }

    @Test("--debug is independent from --log-level")
    func debugAndLogLevel() throws {
        let cmd = try parse(["--debug", "echo"])
        #expect(cmd.debug == true)
        #expect(cmd.logLevel == .info)
    }

    @Test("--transport accepts streamablehttp")
    func transportChoice() throws {
        let cmd = try parse(["--transport", "streamablehttp", "http://example.com/mcp"])
        #expect(cmd.transport == .streamablehttp)
    }

    @Test("--sse-port aliases to --port when port is at default")
    func ssePortAliasing() throws {
        let cmd = try parse(["--sse-port", "9000", "echo"])
        #expect(cmd.port == 9000)
    }

    @Test("Explicit --port wins over --sse-port")
    func explicitPortWins() throws {
        let cmd = try parse(["--port", "8080", "--sse-port", "9000", "echo"])
        #expect(cmd.port == 8080)
    }

    @Test("--allow-origin is repeatable")
    func allowOriginRepeats() throws {
        let cmd = try parse([
            "--allow-origin", "https://a.example",
            "--allow-origin", "https://b.example",
            "echo",
        ])
        #expect(cmd.allowOrigin == ["https://a.example", "https://b.example"])
    }
}

@Suite("Mode detection")
struct ModeTests {
    @Test("nil returns server")
    func nilIsServer() {
        #expect(Mode.detect(commandOrUrl: nil) == .server)
    }

    @Test("empty returns server")
    func emptyIsServer() {
        #expect(Mode.detect(commandOrUrl: "") == .server)
    }

    @Test("http(s) URLs route to client")
    func httpUrlIsClient() {
        #expect(Mode.detect(commandOrUrl: "http://x") == .client)
        #expect(Mode.detect(commandOrUrl: "HTTPS://X/Y") == .client)
    }

    @Test("Other strings route to server")
    func otherIsServer() {
        #expect(Mode.detect(commandOrUrl: "echo") == .server)
        #expect(Mode.detect(commandOrUrl: "/usr/bin/uvx") == .server)
        #expect(Mode.detect(commandOrUrl: "ws://x") == .server)
    }
}
