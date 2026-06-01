import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

@Suite("CORS")
struct CORSTests {
    private func buildProxy(allow: [String], expose: [String] = []) async throws -> (ServerModeProxy, URL) {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [.init(name: "", executable: URL(fileURLWithPath: "/bin/cat"))],
            cors: CORSConfig(allowedOrigins: allow, exposedHeaders: expose)
        )
        let address = try await proxy.start()
        return (proxy, URL(string: "http://127.0.0.1:\(address.port!)")!)
    }

    @Test("CORSConfig.matchOrigin honors allowlist and wildcard")
    func matchOrigin() {
        let exact = CORSConfig(allowedOrigins: ["https://a.example", "https://b.example"])
        #expect(exact.matchOrigin("https://a.example") == "https://a.example")
        #expect(exact.matchOrigin("https://nope.example") == nil)
        #expect(exact.matchOrigin(nil) == nil)

        let any = CORSConfig(allowedOrigins: ["*"])
        #expect(any.matchOrigin("https://anything") == "https://anything")
        #expect(any.matchOrigin(nil) == nil)
    }

    @Test("OPTIONS preflight returns 204 with Allow-Origin for allowed origin")
    func preflightAllowed() async throws {
        let (proxy, base) = try await buildProxy(allow: ["https://app.example"])
        defer { Task { await proxy.stop() } }

        let response = try await URLSessionHTTPClient().send(
            HTTPRequest(
                method: "OPTIONS",
                url: base.appendingPathComponent("messages"),
                headers: [
                    ("Origin", "https://app.example"),
                    ("Access-Control-Request-Method", "POST"),
                ]
            )
        )
        #expect(response.statusCode == 204)
        #expect(response.headers["Access-Control-Allow-Origin"] == "https://app.example")
        #expect(response.headers["Access-Control-Allow-Methods"]?.contains("POST") == true)
        #expect(response.headers["Access-Control-Max-Age"] != nil)
    }

    @Test("OPTIONS preflight returns 403 for disallowed origin")
    func preflightForbidden() async throws {
        let (proxy, base) = try await buildProxy(allow: ["https://app.example"])
        defer { Task { await proxy.stop() } }

        let response = try await URLSessionHTTPClient().send(
            HTTPRequest(
                method: "OPTIONS",
                url: base.appendingPathComponent("messages"),
                headers: [("Origin", "https://attacker.example")]
            )
        )
        #expect(response.statusCode == 403)
        #expect(response.headers["Access-Control-Allow-Origin"] == nil)
    }

    @Test("GET /status adds Allow-Origin + Expose-Headers when origin matches")
    func statusWithOrigin() async throws {
        let (proxy, base) = try await buildProxy(
            allow: ["https://app.example"],
            expose: ["X-Toolsmith-Trace", "X-Other"]
        )
        defer { Task { await proxy.stop() } }

        let response = try await URLSessionHTTPClient().send(
            HTTPRequest(
                method: "GET",
                url: base.appendingPathComponent("status"),
                headers: [("Origin", "https://app.example")]
            )
        )
        #expect(response.statusCode == 200)
        #expect(response.headers["Access-Control-Allow-Origin"] == "https://app.example")
        let expose = response.headers["Access-Control-Expose-Headers"] ?? ""
        #expect(expose.contains("X-Toolsmith-Trace"))
        #expect(expose.contains("X-Other"))
    }

    @Test("Wildcard origin echoes the request's Origin")
    func wildcardOrigin() async throws {
        let (proxy, base) = try await buildProxy(allow: ["*"])
        defer { Task { await proxy.stop() } }

        let response = try await URLSessionHTTPClient().send(
            HTTPRequest(
                method: "GET",
                url: base.appendingPathComponent("status"),
                headers: [("Origin", "https://anything.example")]
            )
        )
        #expect(response.headers["Access-Control-Allow-Origin"] == "https://anything.example")
    }

    @Test("Request without Origin does not get CORS headers")
    func noOrigin() async throws {
        let (proxy, base) = try await buildProxy(allow: ["https://app.example"])
        defer { Task { await proxy.stop() } }

        let response = try await URLSessionHTTPClient().send(
            HTTPRequest(method: "GET", url: base.appendingPathComponent("status"))
        )
        #expect(response.statusCode == 200)
        #expect(response.headers["Access-Control-Allow-Origin"] == nil)
    }
}
