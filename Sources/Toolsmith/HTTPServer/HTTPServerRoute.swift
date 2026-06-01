import Foundation
import NIOHTTP1

/// One HTTP request seen by the server, plus its body as a single Data.
/// Request bodies are aggregated by the pipeline before dispatch.
public struct ServerHTTPRequest: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: String?
    public var headers: [(String, String)]
    public var body: Data

    public init(
        method: HTTPMethod,
        path: String,
        query: String? = nil,
        headers: [(String, String)] = [],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// One server-side response. Either a unary buffered body or a stream of
/// body chunks emitted over time (used for SSE and chunked-streamable
/// responses). Use `.stream` with an explicit `Content-Type` of
/// `text/event-stream` for SSE.
public struct ServerHTTPResponse: Sendable {
    public var status: HTTPResponseStatus
    public var headers: [(String, String)]
    public var body: Body

    public enum Body: Sendable {
        case empty
        case data(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    public init(status: HTTPResponseStatus, headers: [(String, String)] = [], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ data: Data, status: HTTPResponseStatus = .ok) -> ServerHTTPResponse {
        ServerHTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json")],
            body: .data(data)
        )
    }

    public static func text(_ string: String, status: HTTPResponseStatus = .ok) -> ServerHTTPResponse {
        ServerHTTPResponse(
            status: status,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: .data(Data(string.utf8))
        )
    }

    public static func notFound() -> ServerHTTPResponse {
        ServerHTTPResponse(status: .notFound, body: .data(Data("not found".utf8)))
    }

    public static func methodNotAllowed() -> ServerHTTPResponse {
        ServerHTTPResponse(status: .methodNotAllowed, body: .data(Data("method not allowed".utf8)))
    }
}

/// A handler invoked by the server's router when an incoming request
/// matches a registered route.
public typealias ServerHandler = @Sendable (ServerHTTPRequest) async throws -> ServerHTTPResponse

/// Order-preserving list of routes. The first matching entry wins.
public struct ServerRouter: Sendable {
    public struct Entry: Sendable {
        public var method: HTTPMethod
        public var path: String
        public var handler: ServerHandler

        public init(method: HTTPMethod, path: String, handler: @escaping ServerHandler) {
            self.method = method
            self.path = path
            self.handler = handler
        }
    }

    public private(set) var entries: [Entry]
    public var fallback: ServerHandler

    public init(entries: [Entry] = [], fallback: @escaping ServerHandler = { _ in .notFound() }) {
        self.entries = entries
        self.fallback = fallback
    }

    public mutating func register(_ method: HTTPMethod, _ path: String, handler: @escaping ServerHandler) {
        entries.append(Entry(method: method, path: path, handler: handler))
    }

    public func dispatch(_ request: ServerHTTPRequest) async throws -> ServerHTTPResponse {
        if let entry = entries.first(where: { $0.method == request.method && $0.path == request.path }) {
            return try await entry.handler(request)
        }
        if entries.contains(where: { $0.path == request.path }) {
            return .methodNotAllowed()
        }
        return try await fallback(request)
    }
}
