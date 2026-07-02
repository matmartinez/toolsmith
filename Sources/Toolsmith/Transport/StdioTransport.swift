import Foundation

/// Ignore SIGPIPE the first time any stdio transport is created. Writing
/// to a child whose read end has closed — it exited, or we're mid-teardown
/// and a lingering request/handshake task still holds a message — otherwise
/// delivers SIGPIPE and kills the whole process. With it ignored the write
/// fails with EPIPE instead, which `send` surfaces as an ordinary throw.
private let ignoreSIGPIPE: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

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
        case readFailed(Int32)
    }

    private let input: FileHandle
    private let output: FileHandle
    private let encoder: JSONEncoder

    public init(input: FileHandle, output: FileHandle) {
        _ = ignoreSIGPIPE
        self.input = input
        self.output = output
        self.encoder = WireJSON.encoder()
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
    ///
    /// Reads run on a **dedicated thread** doing blocking `read(2)` on the
    /// raw descriptor, not `FileHandle.bytes.lines`. Foundation's
    /// `AsyncBytes` serializes its blocking reads on a process-wide queue,
    /// so a single slow/quiet child (e.g. one mid-request against a slow
    /// upstream) head-of-line-blocks every *other* child's stdout — which
    /// stalls unrelated servers for as long as the slow read is parked.
    /// One thread per transport keeps each child's reads independent.
    public nonisolated func incoming() -> AsyncThrowingStream<JSONRPCMessage, Error> {
        let fd = input.fileDescriptor
        return AsyncThrowingStream { continuation in
            let thread = Thread {
                let decoder = WireJSON.decoder()
                var pending = Data()
                let capacity = 65_536
                var chunk = [UInt8](repeating: 0, count: capacity)

                func flushLines() -> Bool {
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let lineData = pending.subdata(in: pending.startIndex..<newline)
                        pending.removeSubrange(pending.startIndex...newline)
                        if lineData.isEmpty { continue }
                        do {
                            continuation.yield(try decoder.decode(JSONRPCMessage.self, from: lineData))
                        } catch {
                            continuation.finish(
                                throwing: Failure.decodingFailed(String(decoding: lineData, as: UTF8.self))
                            )
                            return false
                        }
                    }
                    return true
                }

                while true {
                    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
                    if n < 0 {
                        if errno == EINTR { continue }
                        continuation.finish(throwing: Failure.readFailed(errno))
                        return
                    }
                    if n == 0 { continuation.finish(); return }  // EOF
                    pending.append(contentsOf: chunk[0..<n])
                    guard flushLines() else { return }
                }
            }
            thread.name = "toolsmith.stdio-read"
            thread.stackSize = 1 << 20
            // The blocking read unblocks (returns EOF) when the child exits
            // and its write end closes, which is how the thread terminates.
            thread.start()
        }
    }
}
