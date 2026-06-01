import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

@Suite("URLSession streaming probe")
struct URLSessionStreamingProbeTests {
    @Test("bytes.lines delivers lines from our chunked SSE server")
    func bytesLinesDelivers() async throws {
        var router = ServerRouter()
        router.register(.GET, "/stream") { _ in
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data("event: message\ndata: one\n\n".utf8))
                continuation.yield(Data("event: message\ndata: two\n\n".utf8))
                continuation.yield(Data("event: message\ndata: three\n\n".utf8))
                continuation.finish()
            }
            return ServerHTTPResponse(
                status: .ok,
                headers: [("Content-Type", "text/event-stream")],
                body: .stream(stream)
            )
        }
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let url = URL(string: "http://127.0.0.1:\(address.port!)/stream")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
        }
        // We expect at least the data lines and blank separators
        let dataLines = lines.filter { $0.hasPrefix("data: ") }
        #expect(dataLines == ["data: one", "data: two", "data: three"], "got lines: \(lines)")
    }
}
