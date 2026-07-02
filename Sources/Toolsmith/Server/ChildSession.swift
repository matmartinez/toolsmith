import Foundation

/// A spawned MCP server child plus its newline-delimited JSON-RPC
/// pipes. The actor owns one `Process` and one shared `StdioTransport`,
/// and **multiplexes** any number of concurrent client requests onto
/// that single warm upstream session.
///
/// Each inbound `request(_:)` is assigned a fresh, private upstream id;
/// the reply that comes back carrying that id is delivered only to the
/// originating request's stream (with the caller's original id
/// restored). This is the port of the Python MCP SDK's
/// `BaseSession.send_request` that toolsmith's earlier broadcast
/// implementation omitted — without it, two stateless callers both
/// using `id:1` cross-deliver and hang.
///
/// The child is initialized **once** (a lazy background handshake) and
/// kept warm for the process lifetime; downstream `initialize` requests
/// are answered locally from the cached upstream result rather than
/// re-initializing the shared child under every caller.
public actor ChildSession {
    public enum Failure: Error, Sendable, Equatable {
        case alreadyStarted
        case notStarted
        case timeout
        case childExited
    }

    private let process: Process
    private let transport: StdioTransport
    private let clientInfo: MCPImplementation
    private let requestTimeout: Duration

    private var pumpTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var started = false

    /// Next private upstream id to hand out. Monotonic for the session
    /// so concurrent requests never collide, regardless of the ids the
    /// clients chose.
    private var nextUpstreamId: Int64 = 1

    /// In-flight client requests, keyed by their upstream id. Each entry
    /// remembers the caller's original id so the final response can be
    /// rewritten back to it.
    private struct PendingRequest {
        let originalId: JSONRPCID
        let continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation
    }
    private var pendingRequests: [Int64: PendingRequest] = [:]

    /// Internal round-trips (the startup handshake), keyed by upstream id.
    private var pendingResponses: [Int64: CheckedContinuation<JSONRPCResponse, Error>] = [:]

    /// Per-upstream-id timeout guards so a lost reply cleans up instead
    /// of leaking a continuation forever.
    private var timeouts: [Int64: Task<Void, Never>] = [:]

    /// Progress-token → upstream id, so `notifications/progress` the
    /// child emits mid-request route back onto the originating stream.
    private var progressRoutes: [MCPProgressToken: Int64] = [:]

    /// Subscribers to server-initiated / unsolicited messages (GET streams).
    private var eventSubscribers: [UUID: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation] = [:]

    /// The upstream `initialize` result, cached after the handshake so
    /// downstream `initialize` requests are answered without touching
    /// the child. `nil` until the handshake completes (or if it failed).
    private var cachedInitializeResult: JSONValue?

    public init(
        executable: URL,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        clientInfo: MCPImplementation = MCPImplementation(name: "toolsmith", version: "0.0.0"),
        requestTimeout: Duration = .seconds(60)
    ) {
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
        self.clientInfo = clientInfo
        self.requestTimeout = requestTimeout
    }

    // MARK: - Lifecycle

    /// Spawn the child and start the pump that routes incoming messages
    /// to the right waiter. Kicks off the `initialize` handshake in the
    /// background so `start()` does not block on a cold child.
    public func start() throws {
        guard !started else { throw Failure.alreadyStarted }
        try process.run()
        started = true
        Logger.shared.debug(
            "spawned child pid=\(process.processIdentifier) " +
            "exec=\(process.executableURL?.path ?? "?") " +
            "args=\((process.arguments ?? []).joined(separator: " "))"
        )
        let transport = self.transport
        pumpTask = Task { [weak self] in
            do {
                for try await message in transport.incoming() {
                    await self?.handleIncoming(message)
                }
                await self?.failAll(with: Failure.childExited)
            } catch {
                Logger.shared.error("child pump errored: \(error)")
                await self?.failAll(with: error)
            }
        }
        handshakeTask = Task { [weak self] in await self?.handshake() }
    }

    public func stop() {
        let pid = process.processIdentifier
        handshakeTask?.cancel()
        handshakeTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        failAll(with: Failure.childExited)
        for (_, continuation) in eventSubscribers { continuation.finish() }
        eventSubscribers.removeAll()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        started = false
        Logger.shared.debug("stopped child pid=\(pid) status=\(process.terminationStatus)")
    }

    // MARK: - MCPServerBackend

    public func request(_ request: JSONRPCRequest) -> AsyncThrowingStream<JSONRPCMessage, Error> {
        AsyncThrowingStream { continuation in
            Task { self.beginRequest(request, continuation) }
        }
    }

    public func notify(_ notification: JSONRPCNotification) async throws {
        // We drive the child's session ourselves; swallow the client's
        // post-initialize notification so we don't double-signal the
        // shared child.
        if notification.method == mcpInitializedNotificationMethod { return }
        guard started else { throw Failure.notStarted }
        try await transport.send(.notification(notification))
    }

    public func events() -> (id: UUID, stream: AsyncThrowingStream<JSONRPCMessage, Error>) {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<JSONRPCMessage, Error>.makeStream()
        eventSubscribers[id] = continuation
        return (id, stream)
    }

    public func stopEvents(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)?.finish()
    }

    public func emitToEvents(_ message: JSONRPCMessage) {
        fanoutEvents(message)
    }

    // MARK: - Request handling

    private func beginRequest(
        _ request: JSONRPCRequest,
        _ continuation: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation
    ) {
        // Answer initialize locally from the cached upstream handshake,
        // so stateless clients re-initializing on every call don't churn
        // the shared child.
        if request.method == mcpInitializeMethod, let cached = cachedInitializeResult {
            continuation.yield(.response(JSONRPCResponse(id: request.id, result: initializeResult(cached, requestedBy: request))))
            continuation.finish()
            return
        }

        guard started else {
            continuation.finish(throwing: Failure.notStarted)
            return
        }

        let upstreamId = allocateUpstreamId()
        pendingRequests[upstreamId] = PendingRequest(originalId: request.id, continuation: continuation)
        if let token = MCPProgressTokenExtractor.token(in: request.params) {
            progressRoutes[token] = upstreamId
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropRequest(upstreamId) }
        }
        scheduleTimeout(upstreamId)

        let remapped = JSONRPCRequest(id: .number(upstreamId), method: request.method, params: request.params)
        Task { [weak self] in
            do {
                try await self?.transport.send(.request(remapped))
            } catch {
                await self?.failRequest(upstreamId, with: error)
            }
        }
    }

    /// Handle an out-of-band drop (client hung up before the reply).
    private func dropRequest(_ upstreamId: Int64) {
        guard pendingRequests.removeValue(forKey: upstreamId) != nil else { return }
        clearRoutes(for: upstreamId)
        cancelTimeout(upstreamId)
    }

    private func failRequest(_ upstreamId: Int64, with error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: upstreamId) else { return }
        clearRoutes(for: upstreamId)
        cancelTimeout(upstreamId)
        pending.continuation.finish(throwing: error)
    }

    private func handleIncoming(_ message: JSONRPCMessage) {
        switch message {
        case .response(let response):
            guard case .number(let upstreamId) = response.id else {
                fanoutEvents(message)
                return
            }
            if let cont = pendingResponses.removeValue(forKey: upstreamId) {
                cancelTimeout(upstreamId)
                cont.resume(returning: response)
                return
            }
            if let pending = pendingRequests.removeValue(forKey: upstreamId) {
                cancelTimeout(upstreamId)
                clearRoutes(for: upstreamId)
                pending.continuation.yield(.response(rewrite(response, to: pending.originalId)))
                pending.continuation.finish()
                return
            }
            // Unclaimed response — surface it on the event fan-out.
            fanoutEvents(message)

        case .notification(let notification):
            if let token = progressToken(in: notification),
               let upstreamId = progressRoutes[token],
               let pending = pendingRequests[upstreamId] {
                // Forward verbatim: the token is the client's own, and
                // params pass through untouched.
                pending.continuation.yield(.notification(notification))
                return
            }
            fanoutEvents(message)

        case .request:
            // Server-initiated request (e.g. sampling). No per-request
            // owner; hand to the event fan-out.
            fanoutEvents(message)
        }
    }

    private func failAll(with error: Error) {
        for (id, pending) in pendingRequests {
            cancelTimeout(id)
            pending.continuation.finish(throwing: error)
        }
        pendingRequests.removeAll()
        for (id, cont) in pendingResponses {
            cancelTimeout(id)
            cont.resume(throwing: error)
        }
        pendingResponses.removeAll()
        progressRoutes.removeAll()
    }

    // MARK: - Handshake

    /// Initialize the child once and cache its result so downstream
    /// `initialize` calls are answered locally. Tolerates failure — an
    /// uncooperative child just means we forward `initialize` through.
    private func handshake() async {
        let params: JSONValue = .object([
            "protocolVersion": .string(latestMCPProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientInfo.name),
                "version": .string(clientInfo.version),
            ]),
        ])
        do {
            let response = try await internalRoundTrip(method: mcpInitializeMethod, params: params)
            if let result = response.result {
                cachedInitializeResult = result
                try? await transport.send(.notification(JSONRPCNotification(method: mcpInitializedNotificationMethod)))
                Logger.shared.debug("upstream handshake complete")
            }
        } catch {
            Logger.shared.debug("upstream handshake skipped: \(error)")
        }
    }

    /// A one-shot request/response used internally (handshake). Unlike
    /// `beginRequest`, this resolves a single `JSONRPCResponse`.
    private func internalRoundTrip(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let upstreamId = allocateUpstreamId()
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[upstreamId] = continuation
            scheduleTimeout(upstreamId)
            Task { [weak self] in
                do {
                    try await self?.transport.send(
                        .request(JSONRPCRequest(id: .number(upstreamId), method: method, params: params))
                    )
                } catch {
                    await self?.failResponse(upstreamId, with: error)
                }
            }
        }
    }

    private func failResponse(_ upstreamId: Int64, with error: Error) {
        guard let cont = pendingResponses.removeValue(forKey: upstreamId) else { return }
        cancelTimeout(upstreamId)
        cont.resume(throwing: error)
    }

    // MARK: - Helpers

    private func allocateUpstreamId() -> Int64 {
        let id = nextUpstreamId
        nextUpstreamId += 1
        return id
    }

    private func scheduleTimeout(_ upstreamId: Int64) {
        let timeout = requestTimeout
        timeouts[upstreamId] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fireTimeout(upstreamId)
        }
    }

    private func fireTimeout(_ upstreamId: Int64) {
        timeouts[upstreamId] = nil
        if pendingRequests[upstreamId] != nil {
            failRequest(upstreamId, with: Failure.timeout)
        } else if pendingResponses[upstreamId] != nil {
            failResponse(upstreamId, with: Failure.timeout)
        }
    }

    private func cancelTimeout(_ upstreamId: Int64) {
        timeouts.removeValue(forKey: upstreamId)?.cancel()
    }

    private func clearRoutes(for upstreamId: Int64) {
        progressRoutes = progressRoutes.filter { $0.value != upstreamId }
    }

    private func fanoutEvents(_ message: JSONRPCMessage) {
        for (_, continuation) in eventSubscribers { continuation.yield(message) }
    }

    /// Rebuild a response under the caller's original id.
    private func rewrite(_ response: JSONRPCResponse, to id: JSONRPCID) -> JSONRPCResponse {
        if let result = response.result {
            return JSONRPCResponse(id: id, result: result)
        }
        return JSONRPCResponse(
            id: id,
            error: response.error ?? JSONRPCError(code: JSONRPCError.internalError, message: "missing result")
        )
    }

    /// The cached upstream initialize result, optionally clamping the
    /// advertised protocol version down to what the caller asked for so
    /// we never claim a newer revision than the client requested.
    private func initializeResult(_ cached: JSONValue, requestedBy request: JSONRPCRequest) -> JSONValue {
        guard case .object(var result) = cached,
              case .object(let params)? = request.params,
              case .string(let requested)? = params["protocolVersion"],
              case .string(let advertised)? = result["protocolVersion"],
              requested < advertised
        else { return cached }
        result["protocolVersion"] = .string(requested)
        return .object(result)
    }

    private func progressToken(in notification: JSONRPCNotification) -> MCPProgressToken? {
        guard notification.method == mcpProgressNotificationMethod,
              case .object(let params)? = notification.params,
              let raw = params["progressToken"]
        else { return nil }
        switch raw {
        case .integer(let value): return .number(value)
        case .string(let value): return .string(value)
        default: return nil
        }
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

extension ChildSession: MCPServerBackend {}
