import Foundation

/// The minimum surface a server-mode backend must offer so that the
/// route registrars (`ServerModeRoutes.register`, `StreamableHTTPRoutes
/// .register`) can dispatch traffic to it without knowing whether it
/// pipes JSON-RPC to a spawned child or handles it in-process.
///
/// Both implementations — `ChildSession` (spawn) and `CLIBackend`
/// (in-process, CLI-shelling) — conform.
public protocol MCPServerBackend: Sendable {
    func start() async throws
    func stop() async
    func subscribe() async -> (id: UUID, stream: AsyncThrowingStream<JSONRPCMessage, Error>)
    func unsubscribe(_ id: UUID) async
    func send(_ message: JSONRPCMessage) async throws
}

extension ChildSession: MCPServerBackend {}
