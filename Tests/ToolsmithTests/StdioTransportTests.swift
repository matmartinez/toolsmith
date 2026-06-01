import Foundation
import Testing

@testable import Toolsmith

@Suite("StdioTransport")
struct StdioTransportTests {
    /// Wires a fresh transport: the test holds the *other* end of each pipe.
    private func makePair() -> (transport: StdioTransport, writeIn: FileHandle, readOut: FileHandle) {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let transport = StdioTransport(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )
        return (transport, inputPipe.fileHandleForWriting, outputPipe.fileHandleForReading)
    }

    /// Reads bytes from `handle` until a newline is seen and returns the
    /// line (without the trailing newline), as UTF-8.
    private func readLine(from handle: FileHandle) throws -> String {
        var buffer = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            buffer.append(byte)
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    @Test("send writes a newline-terminated JSON line")
    func sendWritesLine() async throws {
        let (transport, _, readOut) = makePair()
        let request = JSONRPCRequest(id: 1, method: "ping")
        try await transport.send(.request(request))

        let line = try readLine(from: readOut)
        #expect(line.contains(#""method":"ping""#))
        #expect(line.contains(#""id":1"#))
        #expect(line.hasSuffix("}"))
    }

    @Test("incoming yields a message written to the input handle")
    func incomingYieldsMessage() async throws {
        let (transport, writeIn, _) = makePair()
        let json = #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#
        try writeIn.write(contentsOf: Data((json + "\n").utf8))
        try writeIn.close()

        var received: [JSONRPCMessage] = []
        for try await message in transport.incoming() {
            received.append(message)
        }
        #expect(received.count == 1)
        guard case .request(let request) = received.first else {
            Issue.record("expected request, got \(String(describing: received.first))")
            return
        }
        #expect(request.id == .number(7))
        #expect(request.method == "tools/list")
    }

    @Test("incoming skips blank lines")
    func incomingSkipsBlank() async throws {
        let (transport, writeIn, _) = makePair()
        let body = "\n\n" + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n\n"
        try writeIn.write(contentsOf: Data(body.utf8))
        try writeIn.close()

        var count = 0
        for try await _ in transport.incoming() { count += 1 }
        #expect(count == 1)
    }

    @Test("incoming carries multiple messages in order")
    func multipleMessages() async throws {
        let (transport, writeIn, _) = makePair()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"a"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"b"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"c"}"#,
        ].joined(separator: "\n") + "\n"
        try writeIn.write(contentsOf: Data(lines.utf8))
        try writeIn.close()

        var methods: [String] = []
        for try await message in transport.incoming() {
            if case .request(let r) = message { methods.append(r.method) }
        }
        #expect(methods == ["a", "b", "c"])
    }

    @Test("incoming finishes with decodingFailed on malformed JSON")
    func decodingFailure() async throws {
        let (transport, writeIn, _) = makePair()
        try writeIn.write(contentsOf: Data("{not json}\n".utf8))
        try writeIn.close()

        await #expect(throws: StdioTransport.Failure.self) {
            for try await _ in transport.incoming() {}
        }
    }

    @Test("send then receive round-trips through a cat subprocess")
    func roundTripViaCat() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        let transport = StdioTransport(
            input: stdout.fileHandleForReading,
            output: stdin.fileHandleForWriting
        )

        let original = JSONRPCMessage.request(
            JSONRPCRequest(id: "abc", method: "tools/call", params: ["name": "echo"])
        )

        async let firstEcho: JSONRPCMessage? = {
            var iterator = transport.incoming().makeAsyncIterator()
            return try await iterator.next()
        }()

        try await transport.send(original)
        try stdin.fileHandleForWriting.close()

        let echoed = try await firstEcho
        #expect(echoed == original)
        process.waitUntilExit()
    }
}
