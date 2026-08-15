import Foundation
import Testing

@testable import Toolsmith

private actor MockClientTransport: ClientTransport {
    private let stream: AsyncThrowingStream<JSONRPCMessage, Error>
    private let continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation
    private(set) var sentMessages: [JSONRPCMessage] = []
    private(set) var startCalls: Int = 0

    init() {
        let (s, c) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        self.stream = s
        self.continuation = c
    }

    nonisolated var incoming: AsyncThrowingStream<JSONRPCMessage, Error> { stream }

    func start() async throws { startCalls += 1 }
    func send(_ message: JSONRPCMessage) async throws { sentMessages.append(message) }
    func push(_ message: JSONRPCMessage) { continuation.yield(message) }
    func finish() { continuation.finish() }
}

@Suite("ClientModeProxy")
struct ClientModeProxyTests {
    private func makeStdio() -> (transport: StdioTransport, writeIn: FileHandle, readOut: FileHandle) {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = StdioTransport(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )
        return (transport, inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading)
    }

    private func writeLine(_ message: JSONRPCMessage, to handle: FileHandle) throws {
        var data = try WireJSON.encoder().encode(message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func readLine(from handle: FileHandle) throws -> String {
        var buffer = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            buffer.append(byte)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    @Test("Calls start() on the remote transport")
    func callsStart() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, _) = makeStdio()
        try writeIn.close()
        await mock.finish()

        try await ClientModeProxy.run(local: local, remote: mock)
        #expect(await mock.startCalls == 1)
    }

    @Test("Forwards stdin lines as JSON-RPC sends to the remote")
    func stdinToRemote() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, _) = makeStdio()

        let request = JSONRPCMessage.request(JSONRPCRequest(id: 1, method: "ping"))
        try writeLine(request, to: writeIn)
        try writeIn.close()
        await mock.finish()

        try await ClientModeProxy.run(local: local, remote: mock)
        let sent = await mock.sentMessages
        #expect(sent == [request])
    }

    @Test("Forwards remote incoming messages back to stdout")
    func remoteToStdout() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        let response = JSONRPCMessage.response(
            JSONRPCResponse(id: 1, result: .object(["ok": .bool(true)]))
        )
        await mock.push(response)
        await mock.finish()
        try writeIn.close()

        try await ClientModeProxy.run(local: local, remote: mock)

        let line = try readLine(from: readOut)
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8))
        #expect(decoded == response)
    }

    @Test("Bidirectional traffic: request in, response out")
    func bidirectional() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        let request = JSONRPCMessage.request(JSONRPCRequest(id: 7, method: "tools/call"))
        let response = JSONRPCMessage.response(JSONRPCResponse(id: 7, result: .object(["text": "hi"])))

        try writeLine(request, to: writeIn)
        await mock.push(response)
        try writeIn.close()
        await mock.finish()

        try await ClientModeProxy.run(local: local, remote: mock)

        let sent = await mock.sentMessages
        #expect(sent == [request])
        let line = try readLine(from: readOut)
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8))
        #expect(decoded == response)
    }

    @Test("Progress notifications from the remote pass through to stdout")
    func progressPassthrough() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        let progress = JSONRPCMessage.notification(
            JSONRPCNotification(
                method: mcpProgressNotificationMethod,
                params: ["progressToken": "t1", "progress": 50, "total": 100]
            )
        )
        let final = JSONRPCMessage.response(JSONRPCResponse(id: 1, result: .object(["done": true])))
        await mock.push(progress)
        await mock.push(final)
        await mock.finish()
        try writeIn.close()

        try await ClientModeProxy.run(local: local, remote: mock)

        var decoded: [JSONRPCMessage] = []
        for _ in 0..<2 {
            let line = try readLine(from: readOut)
            decoded.append(try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8)))
        }
        #expect(decoded == [progress, final])
    }

    // MARK: - Schema sanitizing

    private static let offendingListResult: JSONValue = [
        "tools": [
            ["name": "cal",
             "inputSchema": ["type": "object",
                             "properties": ["email": ["type": "string", "pattern": #"^[^\s@]+$"#]]]],
        ],
    ]

    private func emailPattern(in message: JSONRPCMessage) -> JSONValue? {
        guard case .response(let r) = message,
              case .object(let result)? = r.result,
              case .array(let tools) = result["tools"],
              case .object(let tool) = tools.first,
              case .object(let schema) = tool["inputSchema"],
              case .object(let props) = schema["properties"],
              case .object(let email) = props["email"]
        else { return nil }
        return email["pattern"]
    }

    @Test("Sanitizes a tools/list response flowing back to stdout")
    func sanitizesToolsListResponse() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        // Client asks for tools/list; the proxy must record id→method before
        // the response can be correlated.
        try writeLine(.request(JSONRPCRequest(id: 1, method: mcpListToolsMethod)), to: writeIn)

        let proxyTask = Task { try await ClientModeProxy.run(local: local, remote: mock) }
        // Once the request reaches the remote, the id→method record is in place
        // (record runs before send), so pushing the reply now is race-free.
        while await mock.sentMessages.isEmpty { await Task.yield() }
        await mock.push(.response(JSONRPCResponse(id: 1, result: Self.offendingListResult)))
        await mock.finish()
        try writeIn.close()
        try await proxyTask.value

        let line = try readLine(from: readOut)
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8))
        #expect(emailPattern(in: decoded) == .string(#"^[^ \t\r\n\f\v@]+$"#))
    }

    @Test("A non-tools/list response passes through untouched")
    func nonToolsListUntouched() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        // Same structural payload, but the request method is not tools/list.
        try writeLine(.request(JSONRPCRequest(id: 2, method: "ping")), to: writeIn)

        let proxyTask = Task { try await ClientModeProxy.run(local: local, remote: mock) }
        while await mock.sentMessages.isEmpty { await Task.yield() }
        let response = JSONRPCMessage.response(JSONRPCResponse(id: 2, result: Self.offendingListResult))
        await mock.push(response)
        await mock.finish()
        try writeIn.close()
        try await proxyTask.value

        let line = try readLine(from: readOut)
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8))
        #expect(decoded == response)
    }

    @Test("--no-sanitize-schemas passes the offending pattern through verbatim")
    func sanitizeDisabled() async throws {
        let mock = MockClientTransport()
        let (local, writeIn, readOut) = makeStdio()

        let response = JSONRPCMessage.response(JSONRPCResponse(id: 1, result: Self.offendingListResult))
        await mock.push(response)
        await mock.finish()
        try writeIn.close()

        try await ClientModeProxy.run(local: local, remote: mock, sanitizeSchemas: false)

        let line = try readLine(from: readOut)
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: Data(line.utf8))
        #expect(emailPattern(in: decoded) == .string(#"^[^\s@]+$"#))
    }
}

@Suite("Toolsmith header parsing")
struct ToolsmithHeaderParsingTests {
    @Test("Parses NAME: VALUE pairs")
    func basicParse() throws {
        let parsed = try Toolsmith.parseHeaders([
            "Authorization: Bearer abc",
            "X-Trace: 123",
        ])
        #expect(parsed.count == 2)
        #expect(parsed[0] == ("Authorization", "Bearer abc"))
        #expect(parsed[1] == ("X-Trace", "123"))
    }

    @Test("Single space after colon is stripped, additional spaces preserved")
    func spaceStripping() throws {
        let parsed = try Toolsmith.parseHeaders(["X: a b c", "Y:  leading-space"])
        #expect(parsed[0].1 == "a b c")
        #expect(parsed[1].1 == " leading-space")
    }

    @Test("Missing colon throws ValidationError")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parseHeaders(["no-colon"])
        }
    }
}

@Suite("Toolsmith env parsing")
struct ToolsmithEnvParsingTests {
    @Test("Parses KEY=VALUE pairs")
    func basicParse() throws {
        let parsed = try Toolsmith.parseEnvPairs(["FOO=bar", "BAZ=qux"])
        #expect(parsed == ["FOO": "bar", "BAZ": "qux"])
    }

    @Test("Values may contain '='")
    func valueWithEquals() throws {
        let parsed = try Toolsmith.parseEnvPairs(["URL=https://x?y=1&z=2"])
        #expect(parsed["URL"] == "https://x?y=1&z=2")
    }

    @Test("Missing '=' throws ValidationError")
    func malformed() {
        #expect(throws: (any Error).self) {
            _ = try Toolsmith.parseEnvPairs(["NO_EQUALS"])
        }
    }
}
