import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

private actor MessageInbox {
    private(set) var received: [JSONRPCMessage] = []
    func append(_ message: JSONRPCMessage) { received.append(message) }
    var count: Int { received.count }
}

private actor SSEStreamHub {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func attach(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func push(_ data: Data) { continuation?.yield(data) }
    func finish() { continuation?.finish() }
}

@Suite("ClientModeProxy end-to-end")
struct ClientModeProxyE2ETests {
    @Test("stdin request → real HTTP server → SSE response → stdout")
    func endToEnd() async throws {
        let inbox = MessageInbox()
        let hub = SSEStreamHub()

        var router = ServerRouter()
        router.register(.GET, "/sse") { _ in
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data("event: endpoint\ndata: /messages\n\n".utf8))
                Task { await hub.attach(continuation) }
            }
            return ServerHTTPResponse(
                status: .ok,
                headers: [("Content-Type", "text/event-stream")],
                body: .stream(stream)
            )
        }
        router.register(.POST, "/messages") { request in
            let message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: request.body)
            await inbox.append(message)
            return ServerHTTPResponse(status: .ok)
        }

        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let sseURL = URL(string: "http://127.0.0.1:\(address.port!)/sse")!
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let local = StdioTransport(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )
        let remote = SSEClientTransport(
            url: sseURL,
            httpClient: URLSessionHTTPClient()
        )

        async let proxyResult: Void = ClientModeProxy.run(local: local, remote: remote)

        // Stdin → server
        let request = JSONRPCMessage.request(JSONRPCRequest(id: 1, method: "ping"))
        var requestBytes = try WireJSON.encoder().encode(request)
        requestBytes.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: requestBytes)

        // Wait until server has the request
        let deadline = Date().addingTimeInterval(5)
        while await inbox.count == 0 {
            if Date() > deadline { Issue.record("server did not receive request within 5s"); break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let received = await inbox.received
        #expect(received == [request])

        // Server → stdout
        let response = JSONRPCMessage.response(
            JSONRPCResponse(id: 1, result: .object(["pong": .bool(true)]))
        )
        let responseJSON = String(decoding: try WireJSON.encoder().encode(response), as: UTF8.self)
        await hub.push(Data("event: message\ndata: \(responseJSON)\n\n".utf8))

        var line = Data()
        while let byte = try outputPipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            line.append(byte)
        }
        let decoded = try WireJSON.decoder().decode(JSONRPCMessage.self, from: line)
        #expect(decoded == response)

        // Tear down: closing stdin EOFs the proxy's local input; finishing
        // the SSE stream EOFs the remote.incoming side; both tasks unwind.
        try inputPipe.fileHandleForWriting.close()
        await hub.finish()
        try await proxyResult
    }
}
