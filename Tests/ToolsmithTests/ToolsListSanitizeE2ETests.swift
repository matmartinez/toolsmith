import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// A minimal stdio MCP responder whose `tools/list` advertises a calendar-style
/// tool with an attendee-email `pattern` using the GBNF-hostile `\s` shorthand
/// nested under `properties.attendees.items.properties.email` (depth 3). Mirrors
/// `@cocal/google-calendar-mcp`'s `^[^\s@]+@[^\s@]+\.[^\s@]+$`.
private let kCalendarResponderScript = #"""
import sys, json

def handle(msg):
    method = msg.get('method')
    msg_id = msg.get('id')
    if msg_id is None:
        return None
    if method == 'initialize':
        return {'jsonrpc': '2.0', 'id': msg_id, 'result': {
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {'listChanged': False}},
            'serverInfo': {'name': 'calendar', 'version': '1.0.0'},
        }}
    if method == 'tools/list':
        return {'jsonrpc': '2.0', 'id': msg_id, 'result': {'tools': [{
            'name': 'calendar_create-event',
            'inputSchema': {
                'type': 'object',
                'properties': {
                    'attendees': {
                        'type': 'array',
                        'items': {
                            'type': 'object',
                            'properties': {
                                'email': {'type': 'string',
                                          'pattern': '^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$'},
                            },
                            'required': ['email'],
                        },
                    },
                },
            },
        }]}}
    return {'jsonrpc': '2.0', 'id': msg_id,
            'error': {'code': -32601, 'message': 'Method not found: ' + str(method)}}

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

private struct SanitizeHarness {
    let proxy: ServerModeProxy
    let base: URL
    let httpClient: HTTPClient

    static func start(sanitizeSchemas: Bool) async throws -> SanitizeHarness {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(
                    name: "",
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    args: ["python3", "-u", "-c", kCalendarResponderScript]
                ),
            ],
            sanitizeSchemas: sanitizeSchemas
        )
        let address = try await proxy.start()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!
        return SanitizeHarness(proxy: proxy, base: base, httpClient: URLSessionHTTPClient())
    }

    func stop() async { await proxy.stop() }

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

/// Pull `tools[0].inputSchema.properties.attendees.items.properties.email.pattern`
/// out of a `tools/list` result, if present.
private func attendeeEmailPattern(in result: JSONValue?) -> JSONValue? {
    guard case .object(let root)? = result,
          case .array(let tools) = root["tools"],
          case .object(let tool) = tools.first,
          case .object(let schema) = tool["inputSchema"],
          case .object(let props) = schema["properties"],
          case .object(let attendees) = props["attendees"],
          case .object(let items) = attendees["items"],
          case .object(let iprops) = items["properties"],
          case .object(let email) = iprops["email"]
    else { return nil }
    return email["pattern"]
}

@Suite("tools/list schema sanitizing (server mode, end-to-end)")
struct ToolsListSanitizeE2ETests {
    @Test("Nested \\s email pattern is rewritten through the proxy; tool still present")
    func rewritesNestedPattern() async throws {
        let harness = try await SanitizeHarness.start(sanitizeSchemas: true)
        defer { Task { await harness.stop() } }

        let response = try await harness.roundTrip(
            JSONRPCRequest(id: 1, method: mcpListToolsMethod)
        )
        let result = try #require(response.result)
        // Tool survives.
        let listed = try decodeToolsList(result)
        #expect(listed.tools.first?.name == "calendar_create-event")
        // Pattern was rewritten — the \s shorthand is gone, the expansion is in.
        let pattern = attendeeEmailPattern(in: result)
        guard case .string(let text)? = pattern else {
            Issue.record("email pattern missing or not a string: \(String(describing: pattern))")
            return
        }
        #expect(!text.contains(#"\s"#))
        #expect(text.contains(#" \t\r\n\f\v"#))
    }

    @Test("With sanitizing disabled the pattern passes through verbatim")
    func disabledPassesThrough() async throws {
        let harness = try await SanitizeHarness.start(sanitizeSchemas: false)
        defer { Task { await harness.stop() } }

        let response = try await harness.roundTrip(
            JSONRPCRequest(id: 1, method: mcpListToolsMethod)
        )
        let pattern = attendeeEmailPattern(in: response.result)
        #expect(pattern == .string(#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#))
    }

    private func decodeToolsList(_ value: JSONValue) throws -> MCPListToolsResult {
        let data = try WireJSON.encoder().encode(value)
        return try WireJSON.decoder().decode(MCPListToolsResult.self, from: data)
    }
}
