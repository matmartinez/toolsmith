import Foundation
import Testing

@testable import Toolsmith

private actor RecordingHTTPClient: HTTPClient {
    private(set) var sendLog: [HTTPRequest] = []
    private var sendHandler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?

    func setHandler(_ handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse) {
        sendHandler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sendLog.append(request)
        if let sendHandler { return try await sendHandler(request) }
        return HTTPResponse(statusCode: 200)
    }

    func openStream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        sendLog.append(request)
        let (stream, _) = AsyncThrowingStream<String, Error>.makeStream()
        return HTTPStreamResponse(statusCode: 200, headers: [:], lines: stream)
    }
}

@Suite("BearerTokenHTTPClient")
struct BearerTokenHTTPClientTests {
    @Test("send injects Authorization: Bearer header")
    func sendInjectsHeader() async throws {
        let inner = RecordingHTTPClient()
        let client = BearerTokenHTTPClient(inner: inner, tokenProvider: { "tok-123" })
        _ = try await client.send(HTTPRequest(method: "POST", url: URL(string: "https://x")!))
        let log = await inner.sendLog
        #expect(log[0].headers.first?.0 == "Authorization")
        #expect(log[0].headers.first?.1 == "Bearer tok-123")
    }

    @Test("openStream injects Authorization: Bearer header")
    func openStreamInjectsHeader() async throws {
        let inner = RecordingHTTPClient()
        let client = BearerTokenHTTPClient(inner: inner, tokenProvider: { "tok-xyz" })
        _ = try await client.openStream(HTTPRequest(method: "GET", url: URL(string: "https://x")!))
        let log = await inner.sendLog
        #expect(log[0].headers.contains { $0.0 == "Authorization" && $0.1 == "Bearer tok-xyz" })
    }

    @Test("Token provider is called per request")
    func tokenPerRequest() async throws {
        let counter = Counter()
        let inner = RecordingHTTPClient()
        let client = BearerTokenHTTPClient(inner: inner, tokenProvider: {
            "tok-\(await counter.next())"
        })
        _ = try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://x")!))
        _ = try await client.send(HTTPRequest(method: "GET", url: URL(string: "https://x")!))
        let log = await inner.sendLog
        #expect(log[0].headers.first?.1 == "Bearer tok-1")
        #expect(log[1].headers.first?.1 == "Bearer tok-2")
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

@Suite("OAuth2ClientCredentialsProvider")
struct OAuth2ClientCredentialsProviderTests {
    private let tokenURL = URL(string: "https://auth.example/token")!

    private func setupOK(
        accessToken: String = "shiny-new-token",
        expiresIn: Double? = 3600
    ) async -> (RecordingHTTPClient, OAuth2ClientCredentialsProvider) {
        let http = RecordingHTTPClient()
        var fields = #""access_token":"\#(accessToken)","token_type":"Bearer""#
        if let expiresIn { fields += #","expires_in":\#(expiresIn)"# }
        let body = Data("{\(fields)}".utf8)
        await http.setHandler { _ in HTTPResponse(statusCode: 200, body: body) }
        let provider = OAuth2ClientCredentialsProvider(
            clientId: "id",
            clientSecret: "secret",
            tokenURL: tokenURL,
            httpClient: http
        )
        return (http, provider)
    }

    @Test("First call fetches a token and returns it")
    func firstCallFetches() async throws {
        let (http, provider) = await setupOK()
        let token = try await provider.accessToken()
        #expect(token == "shiny-new-token")

        let log = await http.sendLog
        #expect(log.count == 1)
        let request = log[0]
        #expect(request.method == "POST")
        #expect(request.url == tokenURL)
        #expect(request.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/x-www-form-urlencoded" })
        let basic = Data("id:secret".utf8).base64EncodedString()
        #expect(request.headers.contains { $0.0 == "Authorization" && $0.1 == "Basic \(basic)" })
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self) == "grant_type=client_credentials")
    }

    @Test("Subsequent calls reuse the cached token")
    func subsequentReuses() async throws {
        let (http, provider) = await setupOK()
        _ = try await provider.accessToken()
        _ = try await provider.accessToken()
        _ = try await provider.accessToken()
        let log = await http.sendLog
        #expect(log.count == 1)
    }

    @Test("Token is refreshed once it nears expiry")
    func refreshesNearExpiry() async throws {
        let http = RecordingHTTPClient()
        let counter = Counter()
        await http.setHandler { _ in
            let n = await counter.next()
            let body = Data(#"{"access_token":"tok-\#(n)","expires_in":60}"#.utf8)
            return HTTPResponse(statusCode: 200, body: body)
        }
        let provider = OAuth2ClientCredentialsProvider(
            clientId: "i", clientSecret: "s",
            tokenURL: tokenURL, httpClient: http, refreshSkew: 30
        )
        let now = Date()
        let first = try await provider.accessToken(now: now)
        #expect(first == "tok-1")

        // 31 seconds later: token is 60s lifetime, skew 30s → still valid
        let still = try await provider.accessToken(now: now.addingTimeInterval(29))
        #expect(still == "tok-1")

        // 31 seconds later (60 - 30 = 30, anything past that refreshes)
        let refreshed = try await provider.accessToken(now: now.addingTimeInterval(31))
        #expect(refreshed == "tok-2")
    }

    @Test("Non-2xx token endpoint surfaces as tokenEndpointStatus")
    func tokenEndpointError() async throws {
        let http = RecordingHTTPClient()
        await http.setHandler { _ in HTTPResponse(statusCode: 401) }
        let provider = OAuth2ClientCredentialsProvider(
            clientId: "i", clientSecret: "s",
            tokenURL: tokenURL, httpClient: http
        )
        await #expect(throws: OAuth2ClientCredentialsProvider.Failure.tokenEndpointStatus(401)) {
            _ = try await provider.accessToken()
        }
    }

    @Test("Malformed token response surfaces as invalidTokenResponse")
    func invalidTokenResponse() async throws {
        let http = RecordingHTTPClient()
        await http.setHandler { _ in HTTPResponse(statusCode: 200, body: Data("not json".utf8)) }
        let provider = OAuth2ClientCredentialsProvider(
            clientId: "i", clientSecret: "s",
            tokenURL: tokenURL, httpClient: http
        )
        await #expect(throws: OAuth2ClientCredentialsProvider.Failure.invalidTokenResponse) {
            _ = try await provider.accessToken()
        }
    }

    @Test("Missing expires_in defaults to a one-hour lifetime")
    func defaultExpiry() async throws {
        let (_, provider) = await setupOK(expiresIn: nil)
        let now = Date()
        _ = try await provider.accessToken(now: now)
        // After 59 minutes the token should still be valid; refresh skew
        // pushes the deadline forward only by 30 seconds.
        let stillValid = try await provider.accessToken(now: now.addingTimeInterval(60 * 59))
        #expect(stillValid == "shiny-new-token")
    }
}
