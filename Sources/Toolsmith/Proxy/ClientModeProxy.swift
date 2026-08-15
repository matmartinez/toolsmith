import Foundation

/// Client-mode proxy: pipe JSON-RPC messages between our own stdio
/// (where the host MCP harness is reading/writing) and a remote
/// HTTP-based MCP server. Both directions run concurrently; the call
/// returns when either side finishes or throws, cancelling the other.
public enum ClientModeProxy {
    /// Correlates outbound request ids to their method so an inbound response
    /// can be recognized as answering a `tools/list` (which carries no method
    /// of its own).
    private actor MethodTracker {
        private var methods: [JSONRPCID: String] = [:]
        func record(_ id: JSONRPCID, method: String) { methods[id] = method }
        func take(_ id: JSONRPCID) -> String? { methods.removeValue(forKey: id) }
    }

    public static func run(
        local: StdioTransport,
        remote: ClientTransport,
        sanitizeSchemas: Bool = true
    ) async throws {
        try await remote.start()

        let tracker = MethodTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in local.incoming() {
                    if sanitizeSchemas, case .request(let request) = message {
                        await tracker.record(request.id, method: request.method)
                    }
                    try await remote.send(message)
                }
            }
            group.addTask {
                for try await message in remote.incoming {
                    let forwarded = sanitizeSchemas
                        ? await Self.sanitize(message, tracker: tracker)
                        : message
                    try await local.send(forwarded)
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

    /// If `message` is the response to a `tools/list`, rewrite GBNF-hostile
    /// schema patterns; otherwise return it untouched.
    private static func sanitize(_ message: JSONRPCMessage, tracker: MethodTracker) async -> JSONRPCMessage {
        guard case .response(let response) = message,
              let method = await tracker.take(response.id),
              method == mcpListToolsMethod,
              let result = response.result
        else { return message }

        let (sanitized, mods) = SchemaSanitizer.sanitizeToolsListResult(result)
        guard !mods.isEmpty else { return message }
        for mod in mods {
            Logger.shared.debug("schema-sanitize: tool=\(mod.tool) path=\(mod.path) action=\(mod.action) original=\(mod.original)")
        }
        Logger.shared.info("schema-sanitize: tools/list — \(mods.count) pattern(s) rewritten/dropped")
        return .response(JSONRPCResponse(id: response.id, result: sanitized))
    }
}
