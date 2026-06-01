import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

@Suite("/status route")
struct StatusRouteTests {
    @Test("Reports name, version, and server list")
    func reportsServers() async throws {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [
                .init(name: "", executable: URL(fileURLWithPath: "/bin/cat")),
                .init(name: "alpha", executable: URL(fileURLWithPath: "/bin/cat")),
            ],
            version: "1.2.3"
        )
        let address = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let url = URL(string: "http://127.0.0.1:\(address.port!)/status")!
        let response = try await httpClient.send(HTTPRequest(method: "GET", url: url))
        #expect(response.statusCode == 200)

        let body = try JSONDecoder().decode(JSONValue.self, from: response.body)
        guard case .object(let fields) = body else { Issue.record("expected object"); return }
        #expect(fields["name"] == .string("toolsmith"))
        #expect(fields["version"] == .string("1.2.3"))
        #expect(fields["servers"] == .array([.string(""), .string("alpha")]))
        #expect(fields["lastActivityAt"] == .null)
    }

    @Test("lastActivityAt is set after a /messages POST")
    func lastActivityUpdated() async throws {
        let proxy = try ServerModeProxy(
            host: "127.0.0.1",
            port: 0,
            servers: [.init(name: "", executable: URL(fileURLWithPath: "/bin/cat"))]
        )
        let address = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let httpClient = URLSessionHTTPClient()
        let base = URL(string: "http://127.0.0.1:\(address.port!)")!

        // Touch activity by posting a JSON-RPC message.
        let body = try WireJSON.encoder().encode(
            JSONRPCMessage.request(JSONRPCRequest(id: 1, method: "ping"))
        )
        _ = try await httpClient.send(HTTPRequest(
            method: "POST",
            url: base.appendingPathComponent("messages"),
            headers: [("Content-Type", "application/json")],
            body: body
        ))

        let statusResponse = try await httpClient.send(HTTPRequest(method: "GET", url: base.appendingPathComponent("status")))
        let json = try JSONDecoder().decode(JSONValue.self, from: statusResponse.body)
        guard case .object(let fields) = json else { Issue.record("expected object"); return }
        if case .string(let timestamp) = fields["lastActivityAt"] ?? .null {
            // ISO 8601 strings include "T" and "Z".
            #expect(timestamp.contains("T"))
            #expect(timestamp.contains("Z"))
        } else {
            Issue.record("expected ISO 8601 string, got \(String(describing: fields["lastActivityAt"]))")
        }
    }
}

@Suite("ActivityTracker")
struct ActivityTrackerTests {
    @Test("Snapshot is nil before any touch")
    func nilBefore() async {
        let tracker = ActivityTracker()
        #expect(await tracker.snapshot() == nil)
    }

    @Test("Touch sets the timestamp")
    func touchSets() async {
        let tracker = ActivityTracker()
        let date = Date(timeIntervalSince1970: 1_000_000)
        await tracker.touch(now: date)
        #expect(await tracker.snapshot() == date)
    }

    @Test("Later touch overwrites the previous timestamp")
    func touchOverwrites() async {
        let tracker = ActivityTracker()
        let first = Date(timeIntervalSince1970: 1_000_000)
        let second = Date(timeIntervalSince1970: 2_000_000)
        await tracker.touch(now: first)
        await tracker.touch(now: second)
        #expect(await tracker.snapshot() == second)
    }
}
