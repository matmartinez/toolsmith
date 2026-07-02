import Foundation
import NIOHTTP1

/// Server side of the MCP "Streamable HTTP" transport. Both POST and
/// GET share one path (default `/mcp`).
///
/// POST: client sends one JSON-RPC message in the body.
///   - notification → forward to child, return `202 Accepted` (no body)
///   - request → subscribe to the child, forward the request, stream
///     subsequent child messages back as `text/event-stream` until a
///     reply with the matching id arrives, then close the stream
///   - response → 400, the server does not accept response messages
///
/// GET: opens a server-initiated `text/event-stream` carrying every
/// message the child emits. Used for out-of-band notifications.
public enum StreamableHTTPRoutes {
    public static func register(
        on router: inout ServerRouter,
        backend: any MCPServerBackend,
        path: String = "/mcp",
        activity: ActivityTracker? = nil
    ) {
        router.register(.POST, path) { request in
            await activity?.touch()
            let message: JSONRPCMessage
            do {
                message = try WireJSON.decoder().decode(JSONRPCMessage.self, from: request.body)
            } catch {
                return ServerHTTPResponse(
                    status: .badRequest,
                    headers: [("Content-Type", "text/plain; charset=utf-8")],
                    body: .data(Data("malformed JSON-RPC body".utf8))
                )
            }

            switch message {
            case .notification(let notification):
                try await backend.notify(notification)
                return ServerHTTPResponse(status: .accepted)

            case .response:
                return ServerHTTPResponse(
                    status: .badRequest,
                    headers: [("Content-Type", "text/plain; charset=utf-8")],
                    body: .data(Data("server does not accept response messages".utf8))
                )

            case .request(let request):
                // The backend returns a dedicated stream for this
                // request: any correlated notifications (progress) then
                // exactly one final response, then it finishes. Because
                // the backend owns id-routing, this stream carries only
                // *this* request's traffic — no cross-delivery.
                let subscription = await backend.request(request)

                let body = AsyncThrowingStream<Data, Error> { continuation in
                    // SSE comment chunk to flush headers to the client
                    // immediately. URLSession will not invoke its
                    // didReceive-response delegate hook until at least
                    // one body chunk arrives.
                    continuation.yield(Data(": stream-open\n\n".utf8))
                    let task = Task {
                        do {
                            for try await msg in subscription {
                                let json = try WireJSON.encoder().encode(msg)
                                let payload = "event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
                                continuation.yield(Data(payload.utf8))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }

                return ServerHTTPResponse(
                    status: .ok,
                    headers: [
                        ("Content-Type", "text/event-stream"),
                        ("Cache-Control", "no-cache"),
                    ],
                    body: .stream(body)
                )
            }
        }

        router.register(.GET, path) { _ in
            await activity?.touch()
            // GET carries only server-initiated / unsolicited messages
            // (per-request responses flow back on their own POST stream).
            let (subscriberId, subscription) = await backend.events()
            let body = AsyncThrowingStream<Data, Error> { continuation in
                // SSE comment chunk to flush headers (see POST handler).
                continuation.yield(Data(": stream-open\n\n".utf8))
                let task = Task {
                    do {
                        for try await msg in subscription {
                            let json = try WireJSON.encoder().encode(msg)
                            let payload = "event: message\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
                            continuation.yield(Data(payload.utf8))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                // Periodic keepalive so an abandoned stream is detected: once
                // the peer is gone the write fails, the body stream ends, and
                // this subscription is released instead of parking forever
                // (which would leak the connection into CLOSE_WAIT).
                let heartbeat = Self.heartbeat(continuation)
                continuation.onTermination = { _ in
                    task.cancel()
                    heartbeat.cancel()
                    Task { await backend.stopEvents(subscriberId) }
                }
            }
            return ServerHTTPResponse(
                status: .ok,
                headers: [
                    ("Content-Type", "text/event-stream"),
                    ("Cache-Control", "no-cache"),
                ],
                body: .stream(body)
            )
        }
    }

    /// Emit an SSE keepalive comment on `continuation` every 15s. Shared by
    /// the long-lived GET event streams in both transports so an abandoned
    /// connection is noticed (the write fails once the peer is gone) rather
    /// than leaking a parked subscription and its file descriptor.
    static func heartbeat(
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                continuation.yield(Data(": keepalive\n\n".utf8))
            }
        }
    }
}
