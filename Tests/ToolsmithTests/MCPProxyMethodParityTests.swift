import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Extended MCP responder used by the proxy-method parity suite.
/// Implements one canonical response per common MCP method so the
/// proxy tests can decode the result back into typed structs and
/// assert structural correctness, mirroring the coverage shape of
/// upstream tests/test_proxy_server.py.
private let kRichResponderScript = #"""
import sys, json

def respond(msg_id, result=None, error=None):
    out = {'jsonrpc': '2.0', 'id': msg_id}
    if error is not None:
        out['error'] = error
    else:
        out['result'] = result
    return out

def handle(msg):
    if not isinstance(msg, dict) or 'method' not in msg:
        return None
    method = msg['method']
    msg_id = msg.get('id')
    if msg_id is None:
        return None
    params = msg.get('params') or {}

    if method == 'initialize':
        return respond(msg_id, result={
            'protocolVersion': '2025-06-18',
            'capabilities': {
                'tools': {'listChanged': False},
                'prompts': {'listChanged': False},
                'resources': {'subscribe': True, 'listChanged': False},
                'logging': {},
                'completions': {},
            },
            'serverInfo': {'name': 'rich-test', 'version': '1.0.0'},
        })

    if method == 'resources/list':
        return respond(msg_id, result={
            'resources': [{
                'name': 'readme',
                'uri': 'file:///README.md',
                'mimeType': 'text/markdown',
            }]
        })

    if method == 'resources/read':
        uri = params.get('uri', '')
        return respond(msg_id, result={
            'contents': [{
                'uri': uri,
                'mimeType': 'text/plain',
                'text': f'Body of {uri}',
            }]
        })

    if method == 'resources/templates/list':
        return respond(msg_id, result={
            'resourceTemplates': [{
                'name': 'logs',
                'uriTemplate': 'file:///logs/{date}.log',
                'mimeType': 'text/plain',
            }]
        })

    if method == 'resources/subscribe' or method == 'resources/unsubscribe':
        return respond(msg_id, result={})

    if method == 'prompts/get':
        return respond(msg_id, result={
            'description': 'A short greeting',
            'messages': [
                {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
                {'role': 'assistant', 'content': {'type': 'text', 'text': 'hello!'}},
            ]
        })

    if method == 'completion/complete':
        return respond(msg_id, result={
            'completion': {
                'values': ['terse', 'tersely'],
                'total': 2,
                'hasMore': False,
            }
        })

    if method == 'logging/setLevel':
        return respond(msg_id, result={})

    if method == 'tools/call':
        if params.get('name') == 'boom':
            return respond(msg_id, result={
                'content': [{'type': 'text', 'text': 'kaboom'}],
                'isError': True,
            })

    return respond(msg_id, error={'code': -32601, 'message': 'Method not found: ' + method})

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
    out = handle(msg)
    if out is not None:
        print(json.dumps(out), flush=True)
"""#

private struct ProxyMethodHarness {
    let proxy: ServerModeProxy
    let base: URL
    let httpClient: HTTPClient

    static func start() async throws -> ProxyMethodHarness {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(
                    name: "",
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    args: ["python3", "-u", "-c", kRichResponderScript]
                ),
            ]
        )
        let address = try await proxy.start()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!
        return ProxyMethodHarness(proxy: proxy, base: base, httpClient: URLSessionHTTPClient())
    }

    func stop() async { await proxy.stop() }

    /// POST a JSON-RPC request to /mcp and return the first response
    /// from the SSE stream. /mcp closes the stream on the matching
    /// id, so the first .response message is the answer.
    func roundTrip(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        let body = try WireJSON.encoder().encode(JSONRPCMessage.request(request))
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("mcp"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        while true {
            guard let line = try await iterator.next() else {
                throw Failure.streamEndedWithoutResponse
            }
            guard let event = parser.feed(line: line), event.event == "message" else { continue }
            let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
            guard case .response(let response) = message else {
                throw Failure.unexpectedMessageShape
            }
            return response
        }
    }

    enum Failure: Error { case streamEndedWithoutResponse, unexpectedMessageShape }
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(type, from: data)
}

@Suite("MCP proxy method parity (upstream: test_proxy_server.py)")
struct MCPProxyMethodParityTests {
    @Test("initialize result decodes to MCPInitializeResult (upstream: implicit)")
    func initialize() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpInitializeMethod,
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": .object([:]),
                "clientInfo": ["name": "toolsmith-test", "version": "0.0.0"],
            ]
        ))
        let result = try decode(MCPInitializeResult.self, from: response.result ?? .null)
        #expect(result.serverInfo.name == "rich-test")
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.capabilities.resources?.subscribe == true)
    }

    @Test("resources/list round-trips (upstream: test_list_resources)")
    func listResources() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(
            JSONRPCRequest(id: 1, method: mcpListResourcesMethod)
        )
        let result = try decode(MCPListResourcesResult.self, from: response.result ?? .null)
        #expect(result.resources.count == 1)
        #expect(result.resources[0].uri == "file:///README.md")
        #expect(result.resources[0].mimeType == "text/markdown")
    }

    @Test("resources/read returns matching contents (upstream: test_read_resource)")
    func readResource() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpReadResourceMethod,
            params: ["uri": "file:///hello.txt"]
        ))
        let result = try decode(MCPReadResourceResult.self, from: response.result ?? .null)
        #expect(result.contents.count == 1)
        guard case .text(let text) = result.contents[0] else {
            Issue.record("expected text resource contents")
            return
        }
        #expect(text.uri == "file:///hello.txt")
        #expect(text.text == "Body of file:///hello.txt")
    }

    @Test("resources/templates/list round-trips (upstream: test_list_resource_templates)")
    func listResourceTemplates() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(
            JSONRPCRequest(id: 1, method: mcpListResourceTemplatesMethod)
        )
        let result = try decode(MCPListResourceTemplatesResult.self, from: response.result ?? .null)
        #expect(result.resourceTemplates.count == 1)
        #expect(result.resourceTemplates[0].uriTemplate == "file:///logs/{date}.log")
    }

    @Test("resources/subscribe + unsubscribe (upstream: test_subscribe_resource / test_unsubscribe_resource)")
    func subscribeUnsubscribe() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let subscribeResponse = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpSubscribeResourceMethod,
            params: ["uri": "file:///watched.txt"]
        ))
        #expect(subscribeResponse.result != nil)
        #expect(subscribeResponse.error == nil)

        let unsubscribeResponse = try await harness.roundTrip(JSONRPCRequest(
            id: 2, method: mcpUnsubscribeResourceMethod,
            params: ["uri": "file:///watched.txt"]
        ))
        #expect(unsubscribeResponse.result != nil)
        #expect(unsubscribeResponse.error == nil)
    }

    @Test("prompts/get round-trips with PromptMessage list (upstream: test_get_prompt)")
    func getPrompt() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpGetPromptMethod,
            params: ["name": "greeting"]
        ))
        let result = try decode(MCPGetPromptResult.self, from: response.result ?? .null)
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[1].role == .assistant)
        guard case .text(let assistant) = result.messages[1].content else {
            Issue.record("expected assistant text content")
            return
        }
        #expect(assistant.text == "hello!")
    }

    @Test("completion/complete round-trips (upstream: test_complete)")
    func complete() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpCompleteMethod,
            params: [
                "ref": ["type": "ref/prompt", "name": "greeting"],
                "argument": ["name": "style", "value": "ter"],
            ]
        ))
        let result = try decode(MCPCompleteResult.self, from: response.result ?? .null)
        #expect(result.completion.values == ["terse", "tersely"])
        #expect(result.completion.total == 2)
        #expect(result.completion.hasMore == false)
    }

    @Test("logging/setLevel returns empty result (upstream: test_set_logging_error happy path)")
    func setLogLevel() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpSetLogLevelMethod,
            params: ["level": "warning"]
        ))
        #expect(response.error == nil)
        #expect(response.result != nil)
    }

    @Test("tools/call with isError=true round-trips the error flag (upstream: test_call_tool_with_error)")
    func callToolWithError() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(JSONRPCRequest(
            id: 1, method: mcpCallToolMethod,
            params: ["name": "boom", "arguments": .object([:])]
        ))
        let result = try decode(MCPCallToolResult.self, from: response.result ?? .null)
        #expect(result.isError == true)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content for error result")
            return
        }
        #expect(text.text == "kaboom")
    }

    @Test("Unknown method produces JSON-RPC -32601 (upstream: implicit method-not-found)")
    func methodNotFound() async throws {
        let harness = try await ProxyMethodHarness.start()
        defer { Task { await harness.stop() } }
        let response = try await harness.roundTrip(
            JSONRPCRequest(id: 1, method: "nonexistent/method")
        )
        #expect(response.result == nil)
        #expect(response.error?.code == JSONRPCError.methodNotFound)
        #expect(response.error?.message.contains("nonexistent/method") == true)
    }
}
