import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

/// Inline responder that, for a tools/call request carrying a
/// progressToken in `params._meta.progressToken`, emits three
/// progress notifications correlated to that token before sending
/// the final response. Used to exercise progress forwarding through
/// server mode — the proxy is transparent, so notifications must
/// stream through ChildSession's broadcast → SSE event: message
/// records before the matching .response closes the stream.
private let kProgressResponderScript = #"""
import sys, json

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
    if not isinstance(msg, dict):
        continue
    method = msg.get('method')
    msg_id = msg.get('id')

    if method == 'initialize' and msg_id is not None:
        print(json.dumps({
            'jsonrpc': '2.0', 'id': msg_id,
            'result': {
                'protocolVersion': '2025-06-18',
                'capabilities': {'tools': {'listChanged': False}},
                'serverInfo': {'name': 'progress-test', 'version': '1.0.0'},
            }
        }), flush=True)
        continue

    if method == 'tools/call' and msg_id is not None:
        params = msg.get('params') or {}
        meta = params.get('_meta') or {}
        token = meta.get('progressToken')
        # Emit three progress notifications if a token was passed.
        if token is not None:
            for i, (p, total) in enumerate([(1, 3), (2, 3), (3, 3)]):
                print(json.dumps({
                    'jsonrpc': '2.0',
                    'method': 'notifications/progress',
                    'params': {
                        'progressToken': token,
                        'progress': p,
                        'total': total,
                        'message': 'step ' + str(i + 1),
                    }
                }), flush=True)
        # Final response.
        print(json.dumps({
            'jsonrpc': '2.0', 'id': msg_id,
            'result': {
                'content': [{'type': 'text', 'text': 'done'}],
            }
        }), flush=True)
        continue
"""#

private func startProgressHarness() async throws -> (ServerModeProxy, URL) {
    let proxy = try ServerModeProxy(
        host: "127.0.0.1",
        port: 0,
        servers: [
            .init(
                name: "",
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                args: ["python3", "-u", "-c", kProgressResponderScript]
            ),
        ]
    )
    let address = try await proxy.start()
    return (proxy, URL(string: "http://127.0.0.1:\(address.port!)")!)
}

@Suite("Progress forwarding parity (upstream: test_progress_forwarding.py)")
struct ProgressForwardingParityTests {
    @Test("notifications/progress are forwarded over /mcp before the final response")
    func progressOverMCP() async throws {
        let (proxy, base) = try await startProgressHarness()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 42, method: mcpCallToolMethod,
                params: [
                    "name": "anything",
                    "arguments": .object([:]),
                    "_meta": ["progressToken": "tok-1"],
                ]
            ))
        )
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("mcp"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        var progressEvents: [MCPProgressNotificationParams] = []
        var finalResponse: JSONRPCResponse?
        while finalResponse == nil {
            guard let line = try await iterator.next() else { break }
            guard let event = parser.feed(line: line), event.event == "message" else { continue }
            let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
            switch message {
            case .notification(let n) where n.method == mcpProgressNotificationMethod:
                let paramsData = try WireJSON.encoder().encode(n.params ?? .null)
                progressEvents.append(
                    try WireJSON.decoder().decode(MCPProgressNotificationParams.self, from: paramsData)
                )
            case .response(let r):
                finalResponse = r
            default:
                break
            }
        }

        #expect(progressEvents.count == 3)
        #expect(progressEvents.map(\.progress) == [1.0, 2.0, 3.0])
        for event in progressEvents {
            #expect(event.progressToken == .string("tok-1"))
            #expect(event.total == 3.0)
        }
        #expect(finalResponse?.id == .number(42))
    }

    @Test("notifications/progress are forwarded over /sse + /messages before the final response")
    func progressOverSSE() async throws {
        let (proxy, base) = try await startProgressHarness()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()

        // Open the long-lived SSE stream.
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "GET",
            url: base.appendingPathComponent("sse")
        ))
        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()

        // Drain the endpoint event.
        while true {
            guard let line = try await iterator.next() else { break }
            if let event = parser.feed(line: line), event.event == "endpoint" { break }
        }

        // POST tools/call with a progressToken.
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 99, method: mcpCallToolMethod,
                params: [
                    "name": "anything",
                    "arguments": .object([:]),
                    "_meta": ["progressToken": 7],
                ]
            ))
        )
        _ = try await httpClient.send(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("messages"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        // Read events until we see the final response.
        var progressCount = 0
        var finalResponse: JSONRPCResponse?
        while finalResponse == nil {
            guard let line = try await iterator.next() else { break }
            guard let event = parser.feed(line: line), event.event == "message" else { continue }
            let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
            switch message {
            case .notification(let n) where n.method == mcpProgressNotificationMethod:
                progressCount += 1
            case .response(let r):
                finalResponse = r
            default:
                break
            }
        }

        #expect(progressCount == 3)
        #expect(finalResponse?.id == .number(99))
    }

    @Test("Without a progressToken, no progress notifications are emitted (upstream: test_progress_callback_not_created_without_token)")
    func noTokenNoProgress() async throws {
        let (proxy, base) = try await startProgressHarness()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(
                id: 1, method: mcpCallToolMethod,
                params: ["name": "anything", "arguments": .object([:])]
            ))
        )
        let stream = try await httpClient.openStream(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("mcp"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        var parser = SSEParser()
        var iterator = stream.lines.makeAsyncIterator()
        var progressCount = 0
        var finalResponse: JSONRPCResponse?
        while finalResponse == nil {
            guard let line = try await iterator.next() else { break }
            guard let event = parser.feed(line: line), event.event == "message" else { continue }
            let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(event.data.utf8))
            switch message {
            case .notification(let n) where n.method == mcpProgressNotificationMethod:
                progressCount += 1
            case .response(let r):
                finalResponse = r
            default:
                break
            }
        }

        #expect(progressCount == 0)
        #expect(finalResponse?.id == .number(1))
    }

    @Test("MCPProgressTokenExtractor reads token from arbitrary params (upstream: test_meta_parameter_extraction)")
    func extractorParity() {
        // Numeric token
        #expect(
            MCPProgressTokenExtractor.token(in: ["_meta": ["progressToken": 42]])
                == .number(42)
        )
        // Zero is still a valid token
        #expect(
            MCPProgressTokenExtractor.token(in: ["_meta": ["progressToken": 0]])
                == .number(0)
        )
        // String token
        #expect(
            MCPProgressTokenExtractor.token(in: ["_meta": ["progressToken": "string-token"]])
                == .string("string-token")
        )
        // Missing _meta entirely
        #expect(MCPProgressTokenExtractor.token(in: ["name": "echo"]) == nil)
        // _meta without progressToken
        #expect(MCPProgressTokenExtractor.token(in: ["_meta": ["other": "value"]]) == nil)
        // Nil params
        #expect(MCPProgressTokenExtractor.token(in: nil) == nil)
    }
}
