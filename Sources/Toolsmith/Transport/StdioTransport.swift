import Foundation

/// Bidirectional JSON-RPC transport over a pair of byte streams using
/// newline-delimited UTF-8 JSON. Used both for the proxy's own
/// stdin/stdout (client mode) and for the child server's stdin/stdout
/// (server mode).
///
/// The actor serializes outbound writes so concurrent senders cannot
/// interleave bytes for the same line. Inbound messages stream through
/// `incoming()` and end when the input handle reports EOF.
public actor StdioTransport {
    public enum Failure: Error, Hashable, Sendable {
        case decodingFailed(String)
    }

    private let input: FileHandle
    private let output: FileHandle
    private let encoder: JSONEncoder

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// Encode `message` as a single newline-terminated JSON object and
    /// write it to the output handle atomically.
    public func send(_ message: JSONRPCMessage) throws {
        var data = try encoder.encode(message)
        data.append(0x0A)
        try output.write(contentsOf: data)
    }

    /// Async stream of incoming messages. Blank lines are skipped.
    /// The stream finishes when the input handle reaches EOF; a decode
    /// error finishes the stream with `Failure.decodingFailed`.
    public nonisolated func incoming() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        let input = self.input
        return AsyncThrowingStream { continuation in
            let task = Task {
                let decoder = JSONDecoder()
                do {
                    for try await line in input.bytes.lines {
                        if line.isEmpty { continue }
                        let data = Data(line.utf8)
                        do {
                            let message = try decoder.decode(JSONRPCMessage.self, from: data)
                            continuation.yield(message)
                        } catch {
                            continuation.finish(throwing: Failure.decodingFailed(line))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
