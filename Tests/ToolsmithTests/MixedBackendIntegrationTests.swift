import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Minimal python responder used as a stdio MCP server for the mixed
/// integration test. Mirrors the shape of the upstream parity tests:
/// echoes back a `result: {echoed: <method>}` for every request.
private let kStdioPythonScript = #"""
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
        print(json.dumps({
            'jsonrpc': '2.0',
            'id': msg['id'],
            'result': {'echoed': msg.get('method')},
        }), flush=True)
"""#

private func echoExposure() -> CLIExposureConfig {
    CLIExposureConfig(
        executable: "/bin/echo",
        tools: [
            CLIToolSpec(
                name: "say",
                inputSchema: ["type": "object",
                              "properties": ["message": ["type": "string"]],
                              "required": ["message"]],
                argv: [.argument(name: "message")]
            ),
        ]
    )
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(T.self, from: data)
}

private func firstResponse(
    on stream: AsyncThrowingStream<String, Error>
) async throws -> JSONRPCResponse {
    var parser = SSEParser()
    var iterator = stream.makeAsyncIterator()
    while true {
        guard let line = try await iterator.next() else {
            throw NSError(domain: "MixedBackendTests", code: 0)
        }
        guard let event = parser.feed(line: line), event.event == "message" else { continue }
        let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
        guard case .response(let response) = message else { continue }
        return response
    }
}

@Suite("Mixed backend integration (stdio + CLI exposure)")
struct MixedBackendIntegrationTests {
    @Test("Two servers, one of each kind, routed independently")
    func mixed() async throws {
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                // stdio MCP server (python responder)
                .init(
                    name: "py",
                    backend: .stdioChild(
                        executable: envURL,
                        args: ["python3", "-u", "-c", kStdioPythonScript],
                        env: nil,
                        cwd: nil
                    )
                ),
                // CLI-exposure server (echo)
                .init(name: "echo", backend: .cliExposure(echoExposure())),
            ]
        )
        let address = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!

        // /status reports both servers.
        let status = try await httpClient.send(
            HTTPRequest(method: "GET", url: base.appendingPathComponent("status"))
        )
        let statusJSON = try JSONDecoder().decode(JSONValue.self, from: status.body)
        guard case .object(let fields) = statusJSON,
              case .array(let names) = fields["servers"] ?? .null else {
            Issue.record("expected status servers array"); return
        }
        let stringNames = names.compactMap { v -> String? in
            if case .string(let s) = v { return s }
            return nil
        }
        #expect(Set(stringNames) == ["py", "echo"])

        // POST a request to the python server → expect result.echoed = "ping".
        let pyBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 1, method: "ping"))
        )
        let pyResponse = try await firstResponse(on: try await httpClient.openStream(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("servers/py/mcp"),
                headers: [("Content-Type", "application/json")],
                body: pyBody
            )
        ).lines)
        let pyResult = try decode(JSONValue.self, from: pyResponse.result ?? .null)
        #expect(pyResult == .object(["echoed": .string("ping")]))

        // POST tools/call to the CLI server → expect echoed stdout.
        let cliBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 2, method: mcpCallToolMethod,
                params: ["name": "say", "arguments": ["message": "mixed-mode"]]
            ))
        )
        let cliResponse = try await firstResponse(on: try await httpClient.openStream(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("servers/echo/mcp"),
                headers: [("Content-Type", "application/json")],
                body: cliBody
            )
        ).lines)
        let cliResult = try decode(MCPCallToolResult.self, from: cliResponse.result ?? .null)
        guard case .text(let text) = cliResult.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text == "mixed-mode\n")

        // Confirm the two backends are isolated: tools/list on /servers/py/mcp
        // should NOT yield the CLI's "say" tool (the py responder doesn't
        // implement tools/list, so it returns echoed:tools/list).
        let listBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 3, method: mcpListToolsMethod))
        )
        let pyListResponse = try await firstResponse(on: try await httpClient.openStream(
            HTTPRequest(
                method: "POST",
                url: base.appendingPathComponent("servers/py/mcp"),
                headers: [("Content-Type", "application/json")],
                body: listBody
            )
        ).lines)
        let pyListResult = try decode(JSONValue.self, from: pyListResponse.result ?? .null)
        #expect(pyListResult == .object(["echoed": .string("tools/list")]))
    }
}
