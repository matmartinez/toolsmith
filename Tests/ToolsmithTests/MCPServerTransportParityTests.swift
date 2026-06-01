import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Inline python MCP responder. Handles initialize / tools/list /
/// tools/call(echo) / prompts/list, returning realistic JSON-RPC
/// responses. Used to exercise our server-mode pipes against
/// MCP-shaped traffic, matching the shape of upstream's
/// tests/test_mcp_server.py BackgroundServer fixture.
private let kMCPResponderScript = #"""
import sys, json

def handle(msg):
    if not isinstance(msg, dict) or 'method' not in msg:
        return None
    method = msg['method']
    msg_id = msg.get('id')
    if msg_id is None:
        return None  # notification — no response
    if method == 'initialize':
        return {
            'jsonrpc': '2.0', 'id': msg_id,
            'result': {
                'protocolVersion': '2025-06-18',
                'capabilities': {
                    'tools': {'listChanged': False},
                    'prompts': {'listChanged': False},
                },
                'serverInfo': {'name': 'test-server', 'version': '1.0.0'},
            }
        }
    if method == 'tools/list':
        return {
            'jsonrpc': '2.0', 'id': msg_id,
            'result': {
                'tools': [{
                    'name': 'echo',
                    'description': 'Echo tool',
                    'inputSchema': {
                        'type': 'object',
                        'properties': {'message': {'type': 'string'}},
                        'required': ['message'],
                    },
                }]
            }
        }
    if method == 'tools/call':
        params = msg.get('params') or {}
        if params.get('name') == 'echo':
            args = params.get('arguments') or {}
            return {
                'jsonrpc': '2.0', 'id': msg_id,
                'result': {
                    'content': [
                        {'type': 'text', 'text': 'Echo: ' + str(args.get('message', ''))}
                    ]
                }
            }
    if method == 'prompts/list':
        return {
            'jsonrpc': '2.0', 'id': msg_id,
            'result': {'prompts': [{'name': 'prompt1'}]}
        }
    return {
        'jsonrpc': '2.0', 'id': msg_id,
        'error': {'code': -32601, 'message': 'Method not found: ' + method}
    }

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    response = handle(msg)
    if response is not None:
        print(json.dumps(response), flush=True)
"""#

private func makeMCPResponder() -> ChildSession {
    ChildSession(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        args: ["python3", "-u", "-c", kMCPResponderScript]
    )
}

/// Reads one JSON-RPC message from the SSE stream by skipping any
/// non-message events (endpoint, comments, etc.). Iterates `lines`
/// in place; returns nil if the stream ends before a message arrives.
private func nextSSEMessage(
    parser: inout SSEParser,
    iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator
) async throws -> JSONRPCMessage? {
    while true {
        guard let line = try await iterator.next() else { return nil }
        guard let event = parser.feed(line: line), event.event == "message" else { continue }
        return try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
    }
}

private func nextSSEEvent(
    parser: inout SSEParser,
    iterator: inout AsyncThrowingStream<String, Error>.AsyncIterator
) async throws -> SSEEvent? {
    while true {
        guard let line = try await iterator.next() else { return nil }
        if let event = parser.feed(line: line) { return event }
    }
}

@Suite("MCP server transport parity (upstream: test_mcp_server.py)")
struct MCPServerTransportParityTests {
    private func startServer(
        cors: CORSConfig? = nil
    ) async throws -> (ServerModeProxy, URL) {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(
                    name: "",
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    args: ["python3", "-u", "-c", kMCPResponderScript]
                ),
            ],
            cors: cors
        )
        let address = try await proxy.start()
        return (proxy, URL(string: "http://127.0.0.1:\(address.port!)")!)
    }

    @Test("SSE transport: initialize + list_prompts round-trip (upstream: test_sse_transport)")
    func sseTransport() async throws {
        let (proxy, base) = try await startServer()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let stream = try await httpClient.openStream(
            HTTPRequest(method: "GET", url: base.appendingPathComponent("sse"))
        )
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()

        // First record is the endpoint announcement.
        let endpoint = try await nextSSEEvent(parser: &parser, iterator: &iterator)
        #expect(endpoint?.event == "endpoint")
        #expect(endpoint?.data == "/messages")

        // POST initialize.
        let initBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 1, method: mcpInitializeMethod,
                params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": .object([:]),
                    "clientInfo": ["name": "toolsmith-test", "version": "0.0.0"],
                ]
            ))
        )
        _ = try await httpClient.send(HTTPRequest(
            method: "POST", url: base.appendingPathComponent("messages"),
            headers: [("Content-Type", "application/json")], body: initBody
        ))
        let initMsg = try await nextSSEMessage(parser: &parser, iterator: &iterator)
        guard case .response(let initResponse) = initMsg else {
            Issue.record("expected initialize response, got \(String(describing: initMsg))")
            return
        }
        #expect(initResponse.id == .number(1))

        // POST prompts/list.
        let promptsBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 2, method: mcpListPromptsMethod))
        )
        _ = try await httpClient.send(HTTPRequest(
            method: "POST", url: base.appendingPathComponent("messages"),
            headers: [("Content-Type", "application/json")], body: promptsBody
        ))
        let promptsMsg = try await nextSSEMessage(parser: &parser, iterator: &iterator)
        guard case .response(let promptsResponse) = promptsMsg,
              let result = promptsResponse.result
        else {
            Issue.record("expected prompts/list response, got \(String(describing: promptsMsg))")
            return
        }
        // Decode the result back into a typed MCPListPromptsResult to assert structure.
        let promptsResultData = try WireJSON.encoder().encode(result)
        let prompts = try WireJSON.decoder().decode(MCPListPromptsResult.self, from: promptsResultData)
        #expect(prompts.prompts.count == 1)
        #expect(prompts.prompts[0].name == "prompt1")
    }

    @Test("Streamable HTTP transport: 3× tools/call echo round-trip (upstream: test_http_transport)")
    func httpTransport() async throws {
        let (proxy, base) = try await startServer()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()

        // 1) initialize via POST /mcp
        let initBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 1, method: mcpInitializeMethod,
                params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": .object([:]),
                    "clientInfo": ["name": "toolsmith-test", "version": "0.0.0"],
                ]
            ))
        )
        let initStream = try await httpClient.openStream(HTTPRequest(
            method: "POST", url: base.appendingPathComponent("mcp"),
            headers: [("Content-Type", "application/json")], body: initBody
        ))
        var initParser = SSEParser()
        var initIter = initStream.lines.makeAsyncIterator()
        let initMsg = try await nextSSEMessage(parser: &initParser, iterator: &initIter)
        guard case .response(let initResponse) = initMsg else {
            Issue.record("expected initialize response on /mcp")
            return
        }
        #expect(initResponse.id == .number(1))

        // 2) tools/list
        let listBody = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 2, method: mcpListToolsMethod))
        )
        let listStream = try await httpClient.openStream(HTTPRequest(
            method: "POST", url: base.appendingPathComponent("mcp"),
            headers: [("Content-Type", "application/json")], body: listBody
        ))
        var listParser = SSEParser()
        var listIter = listStream.lines.makeAsyncIterator()
        let listMsg = try await nextSSEMessage(parser: &listParser, iterator: &listIter)
        guard case .response(let listResponse) = listMsg,
              let listResult = listResponse.result
        else {
            Issue.record("expected tools/list response")
            return
        }
        let listResultData = try WireJSON.encoder().encode(listResult)
        let tools = try WireJSON.decoder().decode(MCPListToolsResult.self, from: listResultData)
        #expect(tools.tools.count == 1)
        #expect(tools.tools[0].name == "echo")

        // 3) tools/call 3× with different messages
        for i in 0..<3 {
            let callBody = try WireJSON.encoder().encode(
                JSONRPCMessage.request(JSONRPCRequest(
                    id: JSONRPCID.number(100 + Int64(i)),
                    method: mcpCallToolMethod,
                    params: [
                        "name": "echo",
                        "arguments": ["message": .string("test_\(i)")],
                    ]
                ))
            )
            let callStream = try await httpClient.openStream(HTTPRequest(
                method: "POST", url: base.appendingPathComponent("mcp"),
                headers: [("Content-Type", "application/json")], body: callBody
            ))
            var callParser = SSEParser()
            var callIter = callStream.lines.makeAsyncIterator()
            let callMsg = try await nextSSEMessage(parser: &callParser, iterator: &callIter)
            guard case .response(let callResponse) = callMsg,
                  let callResult = callResponse.result
            else {
                Issue.record("expected tools/call response \(i)")
                return
            }
            let callData = try WireJSON.encoder().encode(callResult)
            let toolResult = try WireJSON.decoder().decode(MCPCallToolResult.self, from: callData)
            #expect(toolResult.content.count == 1)
            guard case .text(let text) = toolResult.content[0] else {
                Issue.record("expected text content for call \(i)")
                return
            }
            #expect(text.text == "Echo: test_\(i)")
        }
    }
}
