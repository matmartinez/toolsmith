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
/// validation via a per-session delegate. Streaming requests use a
/// data-task delegate that yields each received chunk as soon as it
/// arrives — `URLSession.bytes(for:).lines` buffers until a threshold
/// is reached, which breaks SSE flows that depend on the first event
/// being delivered promptly.
public final class URLSessionHTTPClient: HTTPClient {
    private let verifyTLS: Bool
    private let configuration: URLSessionConfiguration

    public init(verifyTLS: Bool = true, configuration: URLSessionConfiguration = .ephemeral) {
        self.verifyTLS = verifyTLS
        self.configuration = configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = makeSession(delegate: verifyTLS ? nil : InsecureTLSDelegate())
        defer { session.invalidateAndCancel() }
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
        let (lineStream, lineContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        let resumed = ResumedFlag()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPStreamResponse, Error>) in
            let delegate = StreamingDelegate(
                verifyTLS: verifyTLS,
                onResponse: { http in
                    Task {
                        guard await resumed.markIfNeeded() else { return }
                        cont.resume(returning: HTTPStreamResponse(
                            statusCode: http.statusCode,
                            headers: Self.headerDictionary(http),
                            lines: lineStream
                        ))
                    }
                },
                onLine: { lineContinuation.yield($0) },
                onComplete: { error in
                    if let error {
                        lineContinuation.finish(throwing: error)
                        Task {
                            guard await resumed.markIfNeeded() else { return }
                            cont.resume(throwing: error)
                        }
                    } else {
                        lineContinuation.finish()
                    }
                }
            )
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: urlRequest)
            lineContinuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private func makeSession(delegate: URLSessionDelegate?) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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

private actor ResumedFlag {
    private var resumed = false
    func markIfNeeded() -> Bool {
        if resumed { return false }
        resumed = true
        return true
    }
}

private final class InsecureTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
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

/// Delegate driving `openStream`. Buffers received bytes, splits on
/// LF, and emits each completed line via `onLine` immediately. Stripping
/// a trailing CR keeps CRLF-line endings producing the same lines as
/// LF-only.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let verifyTLS: Bool
    private let onResponse: @Sendable (HTTPURLResponse) -> Void
    private let onLine: @Sendable (String) -> Void
    private let onComplete: @Sendable (Error?) -> Void
    private var buffer = Data()
    private let bufferLock = NSLock()

    init(
        verifyTLS: Bool,
        onResponse: @escaping @Sendable (HTTPURLResponse) -> Void,
        onLine: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        self.verifyTLS = verifyTLS
        self.onResponse = onResponse
        self.onLine = onLine
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if !verifyTLS,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse { onResponse(http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bufferLock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineBytes = buffer.subdata(in: buffer.startIndex..<idx)
            let stripped = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes[...]
            lines.append(String(decoding: stripped, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        bufferLock.unlock()
        for line in lines { onLine(line) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        bufferLock.lock()
        var trailing: String? = nil
        if !buffer.isEmpty {
            trailing = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
        }
        bufferLock.unlock()
        if let trailing { onLine(trailing) }
        onComplete(error)
    }
}
