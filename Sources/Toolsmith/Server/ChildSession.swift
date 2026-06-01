import Foundation

/// A spawned MCP server child plus its newline-delimited JSON-RPC
/// pipes. The actor owns one `Process` and one shared `StdioTransport`;
/// any number of subscribers (e.g. concurrent SSE clients) receive
/// every message the child emits.
///
/// For an MVP we broadcast — each subscriber sees every child→host
/// message. ID-routed delivery (only deliver a response to the client
/// that issued the matching request) is a later refinement.
public actor ChildSession {
    public enum Failure: Error, Sendable, Equatable {
        case alreadyStarted
        case notStarted
    }

    private let process: Process
    private let transport: StdioTransport
    private var subscribers: [UUID: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation] = [:]
    private var pumpTask: Task<Void, Never>?
    private var started: Bool = false

    public init(executable: URL, args: [String] = [], env: [String: String]? = nil, cwd: URL? = nil) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let env { process.environment = env }
        if let cwd { process.currentDirectoryURL = cwd }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr is inherited so child diagnostics surface on ours.
        self.process = process
        self.transport = StdioTransport(
            input: stdoutPipe.fileHandleForReading,
            output: stdinPipe.fileHandleForWriting
        )
    }

    /// Spawn the child and start the pump task that fans incoming
    /// JSON-RPC messages out to every current and future subscriber.
    public func start() throws {
        guard !started else { throw Failure.alreadyStarted }
        try process.run()
        started = true
        let transport = self.transport
        pumpTask = Task { [weak self] in
            do {
                for try await message in transport.incoming() {
                    await self?.broadcast(message)
                }
                await self?.finishAll(throwing: nil)
            } catch {
                await self?.finishAll(throwing: error)
            }
        }
    }

    /// Issue a new subscription. The returned id is required to
    /// `unsubscribe`; the stream completes when the child exits or
    /// the subscription is explicitly cancelled.
    public func subscribe() -> (id: UUID, stream: AsyncThrowingStream<JSONRPCMessage, Error>) {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        subscribers[id] = continuation
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    public func send(_ message: JSONRPCMessage) async throws {
        guard started else { throw Failure.notStarted }
        try await transport.send(message)
    }

    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        started = false
    }

    private func broadcast(_ message: JSONRPCMessage) {
        for (_, continuation) in subscribers { continuation.yield(message) }
    }

    private func finishAll(throwing error: Error?) {
        for (_, continuation) in subscribers {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
        subscribers.removeAll()
        started = false
    }
}

public extension ChildSession {
    /// Convenience: spawn via `/usr/bin/env` so the first argument can
    /// be an unresolved command name from PATH (e.g. `uvx`).
    static func usingPATH(
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) -> ChildSession {
        ChildSession(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            args: [command] + args,
            env: env,
            cwd: cwd
        )
    }
}
