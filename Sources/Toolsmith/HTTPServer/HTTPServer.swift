import Foundation
import NIO
import NIOHTTP1

/// NIO-backed HTTP/1.1 server. Buffers each request body, dispatches
/// to a `ServerRouter`, and writes the matched handler's response.
/// Supports streaming response bodies via `ServerHTTPResponse.Body.stream`.
public final class HTTPServer: @unchecked Sendable {
    public let router: ServerRouter
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(router: ServerRouter) {
        self.router = router
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Bind to host:port and start serving. Returns the actual local
    /// address (with the resolved port — useful when port=0).
    public func start(host: String, port: Int) async throws -> SocketAddress {
        let router = self.router
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPServerRequestAggregator(router: router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        return channel.localAddress!
    }

    public func stop() async throws {
        try? await channel?.close()
        try await group.shutdownGracefully()
    }
}

/// Per-connection handler that buffers the request head + body, then
/// hands the assembled `ServerHTTPRequest` to the router and pipes the
/// response back through the pipeline.
private final class HTTPServerRequestAggregator: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: ServerRouter
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var keepAlive: Bool = false

    init(router: ServerRouter) { self.router = router }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head
            self.body = nil
            self.keepAlive = head.isKeepAlive
        case .body(var buffer):
            if self.body == nil {
                self.body = buffer
            } else {
                self.body?.writeBuffer(&buffer)
            }
        case .end:
            guard let head else { return }
            let bodyData = body.flatMap { Data($0.readableBytesView) } ?? Data()
            let request = Self.makeRequest(head: head, body: bodyData)
            self.head = nil
            self.body = nil
            let router = self.router
            let keepAlive = self.keepAlive
            let channel = context.channel
            let loop = context.eventLoop
            let promise = loop.makePromise(of: Void.self)
            promise.completeWithTask {
                try await Self.handle(request: request, router: router, channel: channel, keepAlive: keepAlive)
            }
            promise.futureResult.whenFailure { error in
                Self.writeServerError(channel: channel, error: error, keepAlive: false)
            }
        }
    }

    private static func makeRequest(head: HTTPRequestHead, body: Data) -> ServerHTTPRequest {
        let method = head.method
        let pathAndQuery = head.uri
        let (path, query): (String, String?) = {
            if let q = pathAndQuery.firstIndex(of: "?") {
                return (String(pathAndQuery[..<q]), String(pathAndQuery[pathAndQuery.index(after: q)...]))
            }
            return (pathAndQuery, nil)
        }()
        var headers: [(String, String)] = []
        for header in head.headers { headers.append((header.name, header.value)) }
        return ServerHTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func handle(
        request: ServerHTTPRequest,
        router: ServerRouter,
        channel: Channel,
        keepAlive: Bool
    ) async throws {
        let response: ServerHTTPResponse
        do {
            response = try await router.dispatch(request)
        } catch {
            response = ServerHTTPResponse(
                status: .internalServerError,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: .data(Data("internal error".utf8))
            )
        }
        try await Self.write(response: response, on: channel, keepAlive: keepAlive)
    }

    private static func write(
        response: ServerHTTPResponse,
        on channel: Channel,
        keepAlive: Bool
    ) async throws {
        var headers = HTTPHeaders()
        for (name, value) in response.headers { headers.add(name: name, value: value) }
        let head: HTTPResponseHead
        switch response.body {
        case .empty:
            if !headers.contains(name: "Content-Length") { headers.add(name: "Content-Length", value: "0") }
            head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        case .data(let data):
            if !headers.contains(name: "Content-Length") {
                headers.add(name: "Content-Length", value: String(data.count))
            }
            head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
        case .stream(let stream):
            if !headers.contains(name: "Transfer-Encoding") {
                headers.add(name: "Transfer-Encoding", value: "chunked")
            }
            head = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
            for try await chunk in stream {
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).get()
            }
        }
        let endPromise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: endPromise)
        if !keepAlive {
            endPromise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        }
        try await endPromise.futureResult.get()
    }

    private static func writeServerError(channel: Channel, error: Error, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .internalServerError, headers: headers)
        _ = channel.writeAndFlush(HTTPServerResponsePart.head(head))
        let endPromise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: endPromise)
        if !keepAlive {
            endPromise.futureResult.whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
