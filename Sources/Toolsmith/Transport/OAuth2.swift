import Foundation

/// Decorator that injects `Authorization: Bearer <token>` on every
/// request before delegating to an inner HTTPClient. The token is
/// pulled lazily per request from `tokenProvider`, which lets the
/// caller plug in either a static API token or an OAuth2 provider
/// that caches + refreshes a server-issued access token.
public final class BearerTokenHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private let tokenProvider: @Sendable () async throws -> String

    public init(
        inner: HTTPClient,
        tokenProvider: @Sendable @escaping () async throws -> String
    ) {
        self.inner = inner
        self.tokenProvider = tokenProvider
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await inner.send(decorated(request))
    }

    public func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        try await inner.openStream(decorated(request))
    }

    private func decorated(_ request: HTTPRequest) async throws -> HTTPRequest {
        var copy = request
        let token = try await tokenProvider()
        copy.headers.insert(("Authorization", "Bearer \(token)"), at: 0)
        return copy
    }
}

/// OAuth2 client-credentials grant (RFC 6749 §4.4). Caches the issued
/// access token in memory and refetches a fresh one shortly before the
/// previous one expires. Token endpoint is contacted via the same
/// HTTPClient seam the transports use, so tests can drive it through
/// a mock.
public actor OAuth2ClientCredentialsProvider {
    public enum Failure: Error, Sendable, Equatable {
        case tokenEndpointStatus(Int)
        case invalidTokenResponse
    }

    private let clientId: String
    private let clientSecret: String
    public let tokenURL: URL
    private let httpClient: HTTPClient
    private let refreshSkew: TimeInterval

    private var currentToken: String?
    private var expiresAt: Date?

    /// `refreshSkew` controls how early we refetch the token relative
    /// to its server-declared expiry. Default 30s.
    public init(
        clientId: String,
        clientSecret: String,
        tokenURL: URL,
        httpClient: HTTPClient,
        refreshSkew: TimeInterval = 30
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.tokenURL = tokenURL
        self.httpClient = httpClient
        self.refreshSkew = refreshSkew
    }

    /// Returns a cached token if it's still valid (with skew), otherwise
    /// fetches a fresh one from the token endpoint.
    public func accessToken(now: Date = Date()) async throws -> String {
        if let currentToken, let expiresAt, expiresAt > now.addingTimeInterval(refreshSkew) {
            return currentToken
        }
        return try await fetch(now: now)
    }

    private func fetch(now: Date) async throws -> String {
        let credentials = "\(clientId):\(clientSecret)"
        let basic = Data(credentials.utf8).base64EncodedString()
        let body = Data("grant_type=client_credentials".utf8)
        let request = HTTPRequest(
            method: "POST",
            url: tokenURL,
            headers: [
                ("Authorization", "Basic \(basic)"),
                ("Content-Type", "application/x-www-form-urlencoded"),
                ("Accept", "application/json"),
            ],
            body: body
        )
        let response = try await httpClient.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw Failure.tokenEndpointStatus(response.statusCode)
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let token_type: String?
            let expires_in: Double?
        }
        let parsed: TokenResponse
        do {
            parsed = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw Failure.invalidTokenResponse
        }
        currentToken = parsed.access_token
        expiresAt = now.addingTimeInterval(parsed.expires_in ?? 3600)
        return parsed.access_token
    }
}
