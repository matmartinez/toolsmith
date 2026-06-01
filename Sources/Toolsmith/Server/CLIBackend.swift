import Foundation

/// In-process MCP server backed by one or more host-CLI invocations.
/// Spawns nothing at startup; each `tools/call` triggers a one-shot
/// subprocess via `runCLI`. Conforms to `MCPServerBackend` so the
/// existing `ServerModeRoutes` / `StreamableHTTPRoutes` registrars
/// can talk to it without any code change.
public actor CLIBackend: MCPServerBackend {
    private let exposure: CLIExposureConfig
    private let serverInfo: MCPImplementation
    private var subscribers: [UUID: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation] = [:]

    public init(
        exposure: CLIExposureConfig,
        serverInfo: MCPImplementation = MCPImplementation(name: "toolsmith-cli", version: "0.0.0")
    ) {
        self.exposure = exposure
        self.serverInfo = serverInfo
    }

    // MARK: - MCPServerBackend

    public func start() async throws { /* nothing to spawn */ }

    public func stop() async {
        for (_, continuation) in subscribers { continuation.finish() }
        subscribers.removeAll()
    }

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
        guard case .request(let request) = message else { return }
        let response = await dispatch(request)
        broadcast(.response(response))
    }

    // MARK: - Dispatch

    private func broadcast(_ message: JSONRPCMessage) {
        for (_, continuation) in subscribers { continuation.yield(message) }
    }

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case mcpInitializeMethod:
            return initializeResponse(id: request.id)
        case mcpListToolsMethod:
            return toolsListResponse(id: request.id)
        case mcpCallToolMethod:
            return await callToolResponse(id: request.id, params: request.params)
        default:
            return JSONRPCResponse(id: request.id, error: JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "Method not found: \(request.method)"
            ))
        }
    }

    private func initializeResponse(id: JSONRPCID) -> JSONRPCResponse {
        let result = MCPInitializeResult(
            protocolVersion: latestMCPProtocolVersion,
            capabilities: MCPServerCapabilities(
                tools: MCPToolsCapability(listChanged: false)
            ),
            serverInfo: serverInfo
        )
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(result) ?? .null)
    }

    private func toolsListResponse(id: JSONRPCID) -> JSONRPCResponse {
        let tools = exposure.tools.map { spec in
            MCPTool(
                name: spec.name,
                inputSchema: spec.inputSchema,
                title: spec.title,
                description: spec.description
            )
        }
        let result = MCPListToolsResult(tools: tools)
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(result) ?? .null)
    }

    private func callToolResponse(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        // Decode tools/call params.
        let callParams: MCPCallToolParams
        do {
            let data = try WireJSON.encoder().encode(params ?? .null)
            callParams = try WireJSON.decoder().decode(MCPCallToolParams.self, from: data)
        } catch {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Invalid tools/call params: \(error)")
        }

        // Resolve tool by name.
        guard let tool = exposure.tools.first(where: { $0.name == callParams.name }) else {
            return errorResponse(id: id, code: JSONRPCError.methodNotFound,
                                 message: "Unknown tool: \(callParams.name)")
        }

        // Project argv.
        let argv: [String]
        do {
            argv = try projectArgv(tool.argv, arguments: callParams.arguments ?? [:])
        } catch ArgvProjectionError.missingRequired(let name) {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Missing required argument '\(name)' for tool '\(tool.name)'")
        } catch ArgvProjectionError.unsupportedValueType(let name) {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Unsupported value type for argument '\(name)' on tool '\(tool.name)'")
        } catch {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Argv projection failed for '\(tool.name)': \(error)")
        }

        Logger.shared.debug("invoking \(exposure.executable) \(argv.joined(separator: " "))")

        // Merge parent env underneath the per-server overrides. Host
        // CLIs almost always need PATH/HOME/USER from the parent —
        // passing the per-server `env` block alone (the way Foundation
        // Process treats a non-nil env) would isolate the child and
        // break common cases like `things add`, which needs `open` on
        // PATH to fire its URL scheme.
        let effectiveEnv: [String: String]?
        if let overrides = exposure.env {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in overrides { merged[key] = value }
            effectiveEnv = merged
        } else {
            effectiveEnv = nil  // nil ⇒ Process inherits parent env wholesale
        }

        // Run the CLI.
        let result: CLIInvocationResult
        do {
            result = try await runCLI(
                executable: URL(fileURLWithPath: exposure.executable),
                args: argv,
                env: effectiveEnv,
                cwd: exposure.cwd.map { URL(fileURLWithPath: $0) }
            )
        } catch {
            return errorResponse(id: id, code: -32000,
                                 message: "Spawn failed for tool '\(tool.name)': \(error)")
        }

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        let stderrText = String(decoding: result.stderr, as: UTF8.self)
        let isError = result.exitCode != 0
        let text: String = isError
            ? (stderrText.isEmpty ? stdoutText : stderrText)
            : stdoutText

        let callResult = MCPCallToolResult(
            content: [.text(MCPTextContent(text: text))],
            isError: isError ? true : nil
        )
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(callResult) ?? .null)
    }

    private func errorResponse(id: JSONRPCID, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message))
    }

    /// Round-trip a typed encodable into a JSONValue payload so it can
    /// drop straight into JSONRPCResponse.result. Returns nil only on
    /// truly malformed input — for the typed MCP structs we control,
    /// it always succeeds.
    private static func encodeAsJSONValue<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? WireJSON.encoder().encode(value) else { return nil }
        return try? WireJSON.decoder().decode(JSONValue.self, from: data)
    }
}
