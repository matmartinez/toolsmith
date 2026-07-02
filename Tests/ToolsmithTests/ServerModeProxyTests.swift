import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Echoes each request's method back in the result, replying with the
/// id it was given. `-u` keeps stdio unbuffered.
private let kProxyResponder = """
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if isinstance(msg, dict) and 'id' in msg and 'method' in msg:
        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'],
                          'result': {'echoed': msg.get('method')}}), flush=True)
"""

@Suite("ServerModeProxy")
struct ServerModeProxyTests {
    @Test("No servers throws noServers")
    func empty() throws {
        #expect(throws: ServerModeProxy.Failure.noServers) {
            _ = try ServerModeProxy(host: "127.0.0.1", port: 0, servers: [])
        }
    }

    @Test("Duplicate names throw")
    func duplicates() throws {
        let cat = URL(fileURLWithPath: "/bin/cat")
        #expect(throws: ServerModeProxy.Failure.duplicateName("a")) {
            _ = try ServerModeProxy(
                host: "127.0.0.1",
                port: 0,
                servers: [
                    .init(name: "a", executable: cat),
                    .init(name: "a", executable: cat),
                ]
            )
        }
    }

    @Test("Mounts default + named servers and routes traffic to each")
    func mountsBoth() async throws {
        let cat = URL(fileURLWithPath: "/bin/cat")
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(name: "", executable: cat),
                .init(name: "alpha", executable: cat),
                .init(name: "beta", executable: cat),
            ]
        )
        let address = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!

        // Probe each prefix: GET /sse returns 200 with the SSE content type;
        // the endpoint event points to the matching POST path.
        let paths: [(sse: String, post: String)] = [
            ("/sse", "/messages"),
            ("/servers/alpha/sse", "/servers/alpha/messages"),
            ("/servers/beta/sse", "/servers/beta/messages"),
        ]
        for path in paths {
            let stream = try await httpClient.openStream(
                HTTPRequest(method: "GET", url: base.appendingPathComponent(path.sse), headers: [("Accept", "text/event-stream")])
            )
            #expect(stream.statusCode == 200)

            var parser = SSEParser()
            var iterator = stream.lines.makeAsyncIterator()
            var endpoint: SSEEvent?
            while endpoint == nil {
                guard let line = try await iterator.next() else { break }
                if let event = parser.feed(line: line) { endpoint = event }
            }
            #expect(endpoint?.event == "endpoint")
            #expect(endpoint?.data == path.post)
        }
    }

    @Test("Traffic to one named server doesn't leak into another's stream")
    func isolation() async throws {
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let responderArgs = ["python3", "-u", "-c", kProxyResponder]
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(name: "alpha", executable: env, args: responderArgs),
                .init(name: "beta", executable: env, args: responderArgs),
            ]
        )
        let address = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!

        // Subscribe to beta first so we can read it after.
        let betaStream = try await httpClient.openStream(
            HTTPRequest(method: "GET", url: base.appendingPathComponent("servers/beta/sse"))
        )
        var betaParser = SSEParser()
        var betaIterator = betaStream.lines.makeAsyncIterator()
        // Drain endpoint event so the next message is the echoed payload.
        while true {
            guard let line = try await betaIterator.next() else { break }
            if let event = betaParser.feed(line: line), event.event == "endpoint" { break }
        }

        // POST a request to alpha; its reply belongs on alpha's stream, so
        // beta must NOT see it.
        let alphaRequest = JSONRPCMessage.request(JSONRPCRequest(id: 99, method: "ping-alpha"))
        _ = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("servers/alpha/messages"),
                headers: [("Content-Type", "application/json")],
                body: try WireJSON.encoder().encode(alphaRequest)
            )
        )

        // POST a different request to beta; beta's reply should surface here.
        let betaRequest = JSONRPCMessage.request(JSONRPCRequest(id: 100, method: "ping-beta"))
        _ = try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("servers/beta/messages"),
                headers: [("Content-Type", "application/json")],
                body: try WireJSON.encoder().encode(betaRequest)
            )
        )

        var betaMessages: [JSONRPCMessage] = []
        while betaMessages.isEmpty {
            guard let line = try await betaIterator.next() else { break }
            if let event = betaParser.feed(line: line), event.event == "message" {
                let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
                betaMessages.append(decoded)
            }
        }
        // The only message on beta's stream is beta's own response — alpha's
        // never leaks across.
        guard case .response(let response) = betaMessages.first else {
            Issue.record("expected a response on beta's stream, got \(String(describing: betaMessages.first))")
            return
        }
        #expect(response.id == .number(100))
        #expect(response.result == .object(["echoed": .string("ping-beta")]))
    }
}

@Suite("--named-server parsing")
struct NamedServerParseTests {
    @Test("Parses NAME=COMMAND into name + word list")
    func basic() throws {
        let parsed = try Toolsmith.parseNamedServerEntries([
            "fetch=uvx mcp-server-fetch",
            "node=node /opt/server.js --debug",
        ])
        #expect(parsed.count == 2)
        #expect(parsed[0].name == "fetch")
        #expect(parsed[0].commandWords == ["uvx", "mcp-server-fetch"])
        #expect(parsed[1].name == "node")
        #expect(parsed[1].commandWords == ["node", "/opt/server.js", "--debug"])
    }

    @Test("Missing '=' throws")
    func missingEquals() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parseNamedServerEntries(["no-equals"])
        }
    }

    @Test("Empty name throws")
    func emptyName() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parseNamedServerEntries(["=cat"])
        }
    }

    @Test("Empty command throws")
    func emptyCommand() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parseNamedServerEntries(["name="])
        }
    }
}

@Suite("Toolsmith env merge")
struct ToolsmithEnvMergeTests {
    @Test("passEnvironment=false returns nil for empty input")
    func emptyNoPass() {
        #expect(Toolsmith.mergeEnvironment([:], passEnvironment: false) == nil)
    }

    @Test("passEnvironment=false returns explicit entries only")
    func explicitOnly() {
        let merged = Toolsmith.mergeEnvironment(["A": "1"], passEnvironment: false)
        #expect(merged == ["A": "1"])
    }

    @Test("passEnvironment=true unions parent env with explicit overrides")
    func union() {
        let merged = Toolsmith.mergeEnvironment(["TOOLSMITH_TEST_KEY": "override"], passEnvironment: true)
        #expect(merged?["TOOLSMITH_TEST_KEY"] == "override")
        // PATH is set in the process environment on macOS test runs.
        #expect(merged?["PATH"] != nil)
    }
}
