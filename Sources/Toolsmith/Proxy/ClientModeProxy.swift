import Foundation

/// Client-mode proxy: pipe JSON-RPC messages between our own stdio
/// (where the host MCP harness is reading/writing) and a remote
/// HTTP-based MCP server. Both directions run concurrently; the call
/// returns when either side finishes or throws, cancelling the other.
public enum ClientModeProxy {
    public static func run(local: StdioTransport, remote: ClientTransport) async throws {
        try await remote.start()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in local.incoming() {
                    try await remote.send(message)
                }
            }
            group.addTask {
                for try await message in remote.incoming {
                    try await local.send(message)
                }
            }
            // Wait for both directions to finish. If either errors, cancel
            // the other and propagate the first error after the group drains.
            // In real use, when stdin EOFs the harness has typically also
            // closed stdout, so the remote→local task fails on the next
            // write with broken pipe and the group unwinds.
            var firstError: Error?
            while true {
                do {
                    guard try await group.next() != nil else { break }
                } catch {
                    if firstError == nil {
                        firstError = error
                        group.cancelAll()
                    }
                }
            }
            if let firstError { throw firstError }
        }
    }
}
