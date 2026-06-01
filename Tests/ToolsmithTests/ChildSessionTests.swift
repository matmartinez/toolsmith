import Foundation
import Testing

@testable import Toolsmith

@Suite("ChildSession")
struct ChildSessionTests {
    @Test("Spawns /bin/cat and round-trips a JSON-RPC message")
    func catRoundTrip() async throws {
        let session = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
        try await session.start()

        let (subscriptionId, stream) = await session.subscribe()
        let request = JSONRPCMessage.request(
            JSONRPCRequest(id: 1, method: "tools/call", params: ["name": "echo"])
        )
        try await session.send(request)

        var iterator = stream.makeAsyncIterator()
        let echoed = try await iterator.next()
        #expect(echoed == request)

        await session.unsubscribe(subscriptionId)
        await session.stop()
    }

    @Test("Broadcasts a child message to every subscriber")
    func broadcastsToAll() async throws {
        let session = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
        try await session.start()

        let (id1, stream1) = await session.subscribe()
        let (id2, stream2) = await session.subscribe()

        let message = JSONRPCMessage.notification(JSONRPCNotification(method: "n"))
        try await session.send(message)

        var it1 = stream1.makeAsyncIterator()
        var it2 = stream2.makeAsyncIterator()
        let m1 = try await it1.next()
        let m2 = try await it2.next()
        #expect(m1 == message)
        #expect(m2 == message)

        await session.unsubscribe(id1)
        await session.unsubscribe(id2)
        await session.stop()
    }

    @Test("Unsubscribed stream finishes immediately on next read")
    func unsubscribeFinishes() async throws {
        let session = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
        try await session.start()

        let (id, stream) = await session.subscribe()
        await session.unsubscribe(id)

        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 0)

        await session.stop()
    }

    @Test("send before start throws")
    func sendBeforeStartThrows() async throws {
        let session = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
        await #expect(throws: ChildSession.Failure.notStarted) {
            try await session.send(.notification(JSONRPCNotification(method: "x")))
        }
    }

    @Test("Double start throws")
    func doubleStartThrows() async throws {
        let session = ChildSession(executable: URL(fileURLWithPath: "/bin/cat"))
        try await session.start()
        await #expect(throws: ChildSession.Failure.alreadyStarted) {
            try await session.start()
        }
        await session.stop()
    }

    @Test("usingPATH convenience init runs the command")
    func usingPathConvenience() async throws {
        let session = ChildSession.usingPATH(command: "cat")
        try await session.start()
        let (subId, stream) = await session.subscribe()
        let request = JSONRPCMessage.request(JSONRPCRequest(id: 7, method: "ping"))
        try await session.send(request)
        var it = stream.makeAsyncIterator()
        let echoed = try await it.next()
        #expect(echoed == request)
        await session.unsubscribe(subId)
        await session.stop()
    }
}
