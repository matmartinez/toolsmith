import Foundation
import NIOHTTP1

/// Mounts the MCP SSE-transport routes on a `ServerRouter`, backed by
/// a single shared `ChildSession`.
///
/// - GET  `<ssePath>`: opens a `text/event-stream`. The first record is
///   `event: endpoint` announcing where to POST messages. Subsequent
///   records carry one JSON-RPC message each (`event: message`) — every
///   child-emitted message is broadcast to every connected client.
/// - POST `<postPath>`: body is decoded as a JSON-RPC message and
///   forwarded to the child's stdin. The response is `202 Accepted`
///   (the actual MCP response will arrive asynchronously over the SSE
///   stream).
public enum ServerModeRoutes {
    public static func register(
        on router: inout ServerRouter,
        child: ChildSession,
        ssePath: String = "/sse",
        postPath: String = "/messages",
        activity: ActivityTracker? = nil
    ) {
        router.register(.GET, ssePath) { _ in
            await activity?.touch()
            let (subscriberId, subscription) = await child.subscribe()
            let endpointEvent = Data("event: endpoint\ndata: \(postPath)\n\n".utf8)

            let bodyStream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(endpointEvent)
                let task = Task {
                    do {
                        for try await message in subscription {
                            let json = try WireJSON.encoder().encode(message)
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
                body: .stream(bodyStream)
            )
        }

        router.register(.POST, postPath) { request in
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
            try await child.send(message)
            return ServerHTTPResponse(status: .accepted)
        }
    }
}

/// Status endpoint. Returns a small JSON snapshot of the proxy:
/// name, version, the list of mounted server names, and the
/// timestamp of the most recent /sse or /messages request (ISO 8601).
public enum StatusRoute {
    public static func register(
        on router: inout ServerRouter,
        serverNames: [String],
        activity: ActivityTracker,
        version: String
    ) {
        router.register(.GET, "/status") { _ in
            let last = await activity.snapshot()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var payload: [String: JSONValue] = [
                "name": .string("toolsmith"),
                "version": .string(version),
                "servers": .array(serverNames.map { .string($0) }),
            ]
            if let last {
                payload["lastActivityAt"] = .string(formatter.string(from: last))
            } else {
                payload["lastActivityAt"] = .null
            }
            let body = try WireJSON.encoder().encode(JSONValue.object(payload))
            return ServerHTTPResponse(
                status: .ok,
                headers: [("Content-Type", "application/json")],
                body: .data(body)
            )
        }
    }
}
