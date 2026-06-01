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
        child: ChildSession,
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
            case .notification:
                try await child.send(message)
                return ServerHTTPResponse(status: .accepted)

            case .response:
                return ServerHTTPResponse(
                    status: .badRequest,
                    headers: [("Content-Type", "text/plain; charset=utf-8")],
                    body: .data(Data("server does not accept response messages".utf8))
                )

            case .request(let request):
                let (subscriberId, subscription) = await child.subscribe()
                try await child.send(message)

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
                                if Self.isReplyTo(request: request, message: msg) {
                                    continuation.finish()
                                    return
                                }
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        Task { await child.unsubscribe(subscriberId) }
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

        router.register(.GET, path) { _ in
            await activity?.touch()
            let (subscriberId, subscription) = await child.subscribe()
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
                continuation.onTermination = { _ in
                    task.cancel()
                    Task { await child.unsubscribe(subscriberId) }
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

    /// True if `message` is the final reply to `request`: either a
    /// JSON-RPC response or error carrying the same id.
    private static func isReplyTo(request: JSONRPCRequest, message: JSONRPCMessage) -> Bool {
        if case .response(let response) = message, response.id == request.id {
            return true
        }
        return false
    }
}
