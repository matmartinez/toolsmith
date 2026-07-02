import Foundation
import Testing

@testable import Toolsmith

/// Line-oriented JSON-RPC responder: for every request it echoes the
/// method back in the result. Crucially it replies with the id it was
/// *given* — so if the proxy failed to remap ids, concurrent callers
/// sharing an id would be indistinguishable. `-u` keeps stdio unbuffered.
private let kEchoResponder = """
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if isinstance(msg, dict) and 'id' in msg and 'method' in msg:
        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'],
                          'result': {'echoed': msg.get('method')}}), flush=True)
"""

private func makeResponder() -> ChildSession {
    ChildSession(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        args: ["python3", "-u", "-c", kEchoResponder]
    )
}

/// Drain a request stream to its single final response.
private func finalResponse(
    _ stream: AsyncThrowingStream<JSONRPCMessage, Error>
) async throws -> JSONRPCResponse {
    for try await message in stream {
        if case .response(let response) = message { return response }
    }
    throw ChildSession.Failure.childExited
}

@Suite("ChildSession")
struct ChildSessionTests {
    @Test("Round-trips a request and restores the caller's id")
    func roundTrip() async throws {
        let session = makeResponder()
        try await session.start()
        defer { Task { await session.stop() } }

        let response = try await finalResponse(await session.request(
            JSONRPCRequest(id: 7, method: "tools/list")
        ))
        #expect(response.id == .number(7))
        #expect(response.result == .object(["echoed": .string("tools/list")]))
    }

    @Test("Concurrent requests sharing id:1 never cross-deliver")
    func concurrentIdCollisionIsolated() async throws {
        let session = makeResponder()
        try await session.start()
        defer { Task { await session.stop() } }

        // All three use the SAME client id (1) — the exact case that
        // hung the old broadcast implementation. Each must get *its own*
        // method echoed back.
        async let a = finalResponse(await session.request(JSONRPCRequest(id: 1, method: "alpha")))
        async let b = finalResponse(await session.request(JSONRPCRequest(id: 1, method: "beta")))
        async let c = finalResponse(await session.request(JSONRPCRequest(id: 1, method: "gamma")))
        let (ra, rb, rc) = try await (a, b, c)

        #expect(ra.id == .number(1) && rb.id == .number(1) && rc.id == .number(1))
        #expect(ra.result == .object(["echoed": .string("alpha")]))
        #expect(rb.result == .object(["echoed": .string("beta")]))
        #expect(rc.result == .object(["echoed": .string("gamma")]))
    }

    @Test("request before start finishes with notStarted")
    func requestBeforeStartThrows() async throws {
        let session = makeResponder()
        let stream = await session.request(JSONRPCRequest(id: 1, method: "ping"))
        await #expect(throws: ChildSession.Failure.notStarted) {
            for try await _ in stream {}
        }
    }

    @Test("notify before start throws")
    func notifyBeforeStartThrows() async throws {
        let session = makeResponder()
        await #expect(throws: ChildSession.Failure.notStarted) {
            try await session.notify(JSONRPCNotification(method: "x"))
        }
    }

    @Test("Double start throws")
    func doubleStartThrows() async throws {
        let session = makeResponder()
        try await session.start()
        defer { Task { await session.stop() } }
        await #expect(throws: ChildSession.Failure.alreadyStarted) {
            try await session.start()
        }
    }

    @Test("usingPATH convenience init runs the command")
    func usingPathConvenience() async throws {
        let session = ChildSession.usingPATH(
            command: "python3", args: ["-u", "-c", kEchoResponder]
        )
        try await session.start()
        defer { Task { await session.stop() } }

        let response = try await finalResponse(await session.request(
            JSONRPCRequest(id: 3, method: "ping")
        ))
        #expect(response.id == .number(3))
        #expect(response.result == .object(["echoed": .string("ping")]))
    }
}
