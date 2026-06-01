import Foundation

public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [(String, String)]
    public var body: Data?

    public init(method: String, url: URL, headers: [(String, String)] = [], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method
            && lhs.url == rhs.url
            && lhs.body == rhs.body
            && lhs.headers.elementsEqual(rhs.headers, by: { $0 == $1 })
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(method)
        hasher.combine(url)
        hasher.combine(body)
        for (k, v) in headers { hasher.combine(k); hasher.combine(v) }
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct HTTPStreamResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>

    public init(
        statusCode: Int,
        headers: [String: String],
        lines: AsyncThrowingStream<String, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.lines = lines
    }
}

/// Minimal HTTP client surface the transports depend on. Two methods:
/// `send` for unary requests and `openStream` for long-lived
/// line-delimited streaming responses (SSE).
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

/// URLSession-backed HTTPClient. The `verifyTLS` knob controls TLS chain
/// validation via a per-session delegate.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(verifyTLS: Bool = true, configuration: URLSessionConfiguration = .ephemeral) {
        if verifyTLS {
            self.session = URLSession(configuration: configuration)
        } else {
            self.session = URLSession(
                configuration: configuration,
                delegate: InsecureTLSDelegate(),
                delegateQueue: nil
            )
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = makeURLRequest(request)
        let (data, response) = try await session.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        return HTTPResponse(
            statusCode: http?.statusCode ?? 0,
            headers: Self.headerDictionary(http),
            body: data
        )
    }

    public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let urlRequest = makeURLRequest(request)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let http = response as? HTTPURLResponse
        let lineStream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(
            statusCode: http?.statusCode ?? 0,
            headers: Self.headerDictionary(http),
            lines: lineStream
        )
    }

    private func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    private static func headerDictionary(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        return headers
    }
}

private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
