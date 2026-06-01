import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

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

private func startProxy(exposureName: String = "echo") async throws -> (ServerModeProxy, URL) {
    let proxy = try ServerModeProxy(
        host: "127.0.0.1",
        port: 0,
        servers: [
            .init(name: exposureName, backend: .cliExposure(echoExposure())),
        ]
    )
    let address = try await proxy.start()
    return (proxy, URL(string: "http://127.0.0.1:\(address.port!)")!)
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(T.self, from: data)
}

@Suite("CLIBackend routes integration")
struct CLIBackendRoutesTests {
    @Test("Streamable HTTP: tools/list returns the declared tool")
    func toolsListOverMCP() async throws {
        let (proxy, base) = try await startProxy()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 1, method: mcpListToolsMethod))
        )
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("servers/echo/mcp"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        var decoded: JSONRPCMessage?
        while decoded == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "message" {
                decoded = try WireJSON.decoder().decode(
                    JSONRPCMessage.self, from: Data(event.data.utf8)
                )
            }
        }
        guard case .response(let response) = decoded else {
            Issue.record("expected tools/list response"); return
        }
        let result = try decode(MCPListToolsResult.self, from: response.result ?? .null)
        #expect(result.tools.map(\.name) == ["say"])
    }

    @Test("Streamable HTTP: tools/call(echo) returns the captured stdout")
    func callToolOverMCP() async throws {
        let (proxy, base) = try await startProxy()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 2, method: mcpCallToolMethod,
                params: ["name": "say", "arguments": ["message": "hi-from-cli"]]
            ))
        )
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("servers/echo/mcp"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        var decoded: JSONRPCMessage?
        while decoded == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "message" {
                decoded = try WireJSON.decoder().decode(
                    JSONRPCMessage.self, from: Data(event.data.utf8)
                )
            }
        }
        guard case .response(let response) = decoded else {
            Issue.record("expected tools/call response"); return
        }
        let result = try decode(MCPCallToolResult.self, from: response.result ?? .null)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text == "hi-from-cli\n")
    }

    @Test("Legacy SSE: tools/call response flows through /sse after POST /messages")
    func callToolOverSSE() async throws {
        let (proxy, base) = try await startProxy()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()

        // Open the long-lived SSE stream and drain the endpoint event.
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "GET", url: base.appendingPathComponent("servers/echo/sse")
        ))
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        while true {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "endpoint" { break }
        }

        // POST tools/call to the announced messages path.
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 7, method: mcpCallToolMethod,
                params: ["name": "say", "arguments": ["message": "via-sse"]]
            ))
        )
        _ = try await httpClient.send(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("servers/echo/messages"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        // Drain the SSE stream until the response event arrives.
        var responseMessage: JSONRPCMessage?
        while responseMessage == nil {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "message" {
                responseMessage = try WireJSON.decoder().decode(
                    JSONRPCMessage.self, from: Data(event.data.utf8)
                )
            }
        }
        guard case .response(let response) = responseMessage,
              let resultJSON = response.result else {
            Issue.record("expected response over /sse"); return
        }
        let result = try decode(MCPCallToolResult.self, from: resultJSON)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text == "via-sse\n")
    }
}
