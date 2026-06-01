import Foundation

/// Common surface every client-mode remote transport offers to the
/// proxy core. The legacy SSE transport and the streamable-HTTP
/// transport both conform.
public protocol ClientTransport: Sendable {
    /// Open whatever long-lived connections this transport needs before
    /// it is safe to call `send`. Default: no-op, for transports that
    /// don't pre-open anything (streamable-HTTP).
    func start() async throws

    /// Send one JSON-RPC message to the remote peer.
    func send(_ message: JSONRPCMessage) async throws

    /// Inbound messages from the remote peer. The stream finishes when
    /// the remote side closes the connection or throws on protocol error.
    var incoming: AsyncThrowingStream<JSONRPCMessage, Error> { get }
}

public extension ClientTransport {
    func start() async throws {}
}

extension SSEClientTransport: ClientTransport {}
extension StreamableHTTPClientTransport: ClientTransport {}
