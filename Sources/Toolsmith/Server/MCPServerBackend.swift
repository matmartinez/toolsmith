import Foundation

/// The minimum surface a server-mode backend must offer so that the
/// route registrars (`ServerModeRoutes.register`, `StreamableHTTPRoutes
/// .register`) can dispatch traffic to it without knowing whether it
/// pipes JSON-RPC to a spawned child or handles it in-process.
///
/// The model is **id-routed request/response**, not broadcast: each
/// client request is answered on its own dedicated stream, so
/// concurrent requests that happen to reuse the same JSON-RPC id (the
/// norm for stateless clients, which restart ids at 1) never
/// cross-deliver. This mirrors the Python MCP SDK's `BaseSession`,
/// which allocates its own request id per outbound call and correlates
/// replies through a per-id map — the layer toolsmith's original
/// broadcast `ChildSession` was missing.
///
/// Both implementations — `ChildSession` (spawn) and `CLIBackend`
/// (in-process, CLI-shelling) — conform.
public protocol MCPServerBackend: Sendable {
    func start() async throws
    func stop() async

    /// Handle one client request. Returns a stream that yields any
    /// correlated out-of-band messages (e.g. `notifications/progress`
    /// tied to this request's `progressToken`) followed by exactly one
    /// final response, then finishes. The final response carries the
    /// **caller's original id** — the backend owns id remapping to the
    /// upstream internally.
    func request(_ request: JSONRPCRequest) async -> AsyncThrowingStream<JSONRPCMessage, Error>

    /// Forward a client notification upstream (fire-and-forget).
    func notify(_ notification: JSONRPCNotification) async throws

    /// Subscribe to server-initiated messages — unsolicited
    /// notifications / requests the upstream emits that aren't tied to
    /// a specific in-flight request. Used by GET event streams.
    func events() async -> (id: UUID, stream: AsyncThrowingStream<JSONRPCMessage, Error>)
    func stopEvents(_ id: UUID) async

    /// Push a message onto the events fan-out. Used by the legacy
    /// `/messages` POST handler to deliver a request's asynchronous
    /// response (and any correlated notifications) over the shared
    /// `/sse` stream.
    func emitToEvents(_ message: JSONRPCMessage) async
}
