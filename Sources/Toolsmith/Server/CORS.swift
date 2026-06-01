import Foundation
import NIOHTTP1

/// CORS policy for the HTTP server. `allowedOrigins` may include `"*"`
/// to permit any origin; otherwise origins are matched case-sensitively
/// against the request's `Origin` header.
public struct CORSConfig: Sendable, Hashable {
    public var allowedOrigins: [String]
    public var exposedHeaders: [String]
    public var allowedMethods: [String]
    public var allowedHeaders: [String]
    public var maxAge: Int

    public init(
        allowedOrigins: [String],
        exposedHeaders: [String] = [],
        allowedMethods: [String] = ["GET", "POST", "OPTIONS"],
        allowedHeaders: [String] = ["Content-Type", "Authorization"],
        maxAge: Int = 86_400
    ) {
        self.allowedOrigins = allowedOrigins
        self.exposedHeaders = exposedHeaders
        self.allowedMethods = allowedMethods
        self.allowedHeaders = allowedHeaders
        self.maxAge = maxAge
    }

    public func matchOrigin(_ origin: String?) -> String? {
        guard let origin else { return nil }
        if allowedOrigins.contains("*") { return origin }
        return allowedOrigins.contains(origin) ? origin : nil
    }
}

/// Wraps every registered handler in `router` so its response carries
/// Access-Control-Allow-Origin (when the request's Origin is allowed)
/// plus Access-Control-Expose-Headers. Also installs an OPTIONS
/// preflight handler for every unique registered path.
public func applyCORS(to router: inout ServerRouter, config: CORSConfig) {
    let originalEntries = router.entries
    let originalFallback = router.fallback
    var wrapped = ServerRouter()

    for entry in originalEntries {
        let handler = entry.handler
        wrapped.register(entry.method, entry.path) { request in
            var response = try await handler(request)
            decorateWithCORS(response: &response, request: request, config: config)
            return response
        }
    }

    let pathsAlreadyHandlingOptions = Set(originalEntries.filter { $0.method == .OPTIONS }.map(\.path))
    let allPaths = Set(originalEntries.map(\.path))
    for path in allPaths where !pathsAlreadyHandlingOptions.contains(path) {
        wrapped.register(.OPTIONS, path) { request in
            corsPreflight(request: request, config: config)
        }
    }

    wrapped.fallback = { request in
        var response = try await originalFallback(request)
        decorateWithCORS(response: &response, request: request, config: config)
        return response
    }

    router = wrapped
}

/// Builds a response for a CORS preflight (OPTIONS) request. Returns
/// 204 with the relevant Access-Control-* headers when the origin is
/// allowed; otherwise 403.
public func corsPreflight(request: ServerHTTPRequest, config: CORSConfig) -> ServerHTTPResponse {
    let origin = headerValue("Origin", in: request.headers)
    guard let allowed = config.matchOrigin(origin) else {
        return ServerHTTPResponse(status: .forbidden, body: .data(Data("origin not allowed".utf8)))
    }
    return ServerHTTPResponse(
        status: .noContent,
        headers: [
            ("Access-Control-Allow-Origin", allowed),
            ("Access-Control-Allow-Methods", config.allowedMethods.joined(separator: ", ")),
            ("Access-Control-Allow-Headers", config.allowedHeaders.joined(separator: ", ")),
            ("Access-Control-Max-Age", String(config.maxAge)),
            ("Vary", "Origin"),
        ]
    )
}

private func decorateWithCORS(response: inout ServerHTTPResponse, request: ServerHTTPRequest, config: CORSConfig) {
    let origin = headerValue("Origin", in: request.headers)
    guard let allowed = config.matchOrigin(origin) else { return }
    response.headers.append(("Access-Control-Allow-Origin", allowed))
    response.headers.append(("Vary", "Origin"))
    if !config.exposedHeaders.isEmpty {
        response.headers.append(("Access-Control-Expose-Headers", config.exposedHeaders.joined(separator: ", ")))
    }
}

private func headerValue(_ name: String, in headers: [(String, String)]) -> String? {
    headers.first(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame })?.1
}
