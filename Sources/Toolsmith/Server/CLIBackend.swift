import Foundation

/// In-process MCP server backed by one or more host-CLI invocations.
/// Spawns nothing at startup; each `tools/call` triggers a one-shot
/// subprocess via `runCLI`. Conforms to `MCPServerBackend` so the
/// existing `ServerModeRoutes` / `StreamableHTTPRoutes` registrars
/// can talk to it without any code change.
public actor CLIBackend: MCPServerBackend {
    private let exposure: CLIExposureConfig
    private let serverInfo: MCPImplementation
    private let sanitizeSchemas: Bool
    private var eventSubscribers: [UUID: AsyncThrowingStream<JSONRPCMessage, Error>.Continuation] = [:]
    private var cachedTemplateMatchers: [(URITemplateMatcher, CLIResourceTemplateSpec)]?

    public init(
        exposure: CLIExposureConfig,
        serverInfo: MCPImplementation = MCPImplementation(name: "toolsmith-cli", version: "0.0.0"),
        sanitizeSchemas: Bool = true
    ) {
        self.exposure = exposure
        self.serverInfo = serverInfo
        self.sanitizeSchemas = sanitizeSchemas
    }

    // MARK: - MCPServerBackend

    public func start() async throws { /* nothing to spawn */ }

    public func stop() async {
        for (_, continuation) in eventSubscribers { continuation.finish() }
        eventSubscribers.removeAll()
    }

    /// Dispatch the request in-process and yield exactly one response.
    /// No id remapping needed — each call is handled synchronously and
    /// independently, so there is no cross-request state to collide.
    public func request(_ request: JSONRPCRequest) -> AsyncThrowingStream<JSONRPCMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let response = await self.dispatch(request)
                continuation.yield(.response(response))
                continuation.finish()
            }
        }
    }

    /// CLI exposures have no upstream to notify; notifications are dropped.
    public func notify(_ notification: JSONRPCNotification) async throws {}

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
        for (_, continuation) in eventSubscribers { continuation.yield(message) }
    }

    // MARK: - Dispatch

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case mcpInitializeMethod:
            return initializeResponse(id: request.id)
        case mcpListToolsMethod:
            return toolsListResponse(id: request.id)
        case mcpCallToolMethod:
            return await callToolResponse(id: request.id, params: request.params)
        case mcpListResourcesMethod:
            return listResourcesResponse(id: request.id)
        case mcpListResourceTemplatesMethod:
            return listResourceTemplatesResponse(id: request.id)
        case mcpReadResourceMethod:
            return await readResourceResponse(id: request.id, params: request.params)
        default:
            return JSONRPCResponse(id: request.id, error: JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "Method not found: \(request.method)"
            ))
        }
    }

    private func initializeResponse(id: JSONRPCID) -> JSONRPCResponse {
        let hasResources = !(exposure.resources ?? []).isEmpty
            || !(exposure.resourceTemplates ?? []).isEmpty
        let result = MCPInitializeResult(
            protocolVersion: latestMCPProtocolVersion,
            capabilities: MCPServerCapabilities(
                resources: hasResources
                    ? MCPResourcesCapability(subscribe: false, listChanged: false)
                    : nil,
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
        let encoded = Self.encodeAsJSONValue(result) ?? .null
        guard sanitizeSchemas else {
            return JSONRPCResponse(id: id, result: encoded)
        }
        let (sanitized, mods) = SchemaSanitizer.sanitizeToolsListResult(encoded)
        if !mods.isEmpty {
            for mod in mods {
                Logger.shared.debug("schema-sanitize: tool=\(mod.tool) path=\(mod.path) action=\(mod.action) original=\(mod.original)")
            }
            Logger.shared.info("schema-sanitize: tools/list — \(mods.count) pattern(s) rewritten/dropped")
        }
        return JSONRPCResponse(id: id, result: sanitized)
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

        // Run the CLI.
        let result: CLIInvocationResult
        do {
            result = try await runCLI(
                executable: URL(fileURLWithPath: exposure.executable),
                args: argv,
                env: effectiveEnv(),
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

    private func listResourcesResponse(id: JSONRPCID) -> JSONRPCResponse {
        let resources = (exposure.resources ?? []).map { spec in
            MCPResource(
                name: spec.name,
                uri: spec.uri,
                title: spec.title,
                description: spec.description,
                mimeType: spec.mimeType
            )
        }
        let result = MCPListResourcesResult(resources: resources)
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(result) ?? .null)
    }

    private func listResourceTemplatesResponse(id: JSONRPCID) -> JSONRPCResponse {
        let templates = (exposure.resourceTemplates ?? []).map { spec in
            MCPResourceTemplate(
                name: spec.name,
                uriTemplate: spec.uriTemplate,
                title: spec.title,
                description: spec.description,
                mimeType: spec.mimeType
            )
        }
        let result = MCPListResourceTemplatesResult(resourceTemplates: templates)
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(result) ?? .null)
    }

    private func readResourceResponse(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        // Decode resources/read params.
        let readParams: MCPReadResourceParams
        do {
            let data = try WireJSON.encoder().encode(params ?? .null)
            readParams = try WireJSON.decoder().decode(MCPReadResourceParams.self, from: data)
        } catch {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Invalid resources/read params: \(error)")
        }
        let uri = readParams.uri

        // Static lookup first.
        var arguments: [String: JSONValue] = ["uri": .string(uri)]
        var argvSpec: [ArgvSpec]?
        var output: CLIResourceOutput = .text
        var mimeType: String?
        var sourceName = uri

        if let staticSpec = (exposure.resources ?? []).first(where: { $0.uri == uri }) {
            argvSpec = staticSpec.argv
            output = staticSpec.output ?? .text
            mimeType = staticSpec.mimeType
            sourceName = staticSpec.name
        } else {
            for (matcher, spec) in templateMatchers() {
                if let captures = matcher.match(uri) {
                    for (k, v) in captures { arguments[k] = .string(v) }
                    argvSpec = spec.argv
                    output = spec.output ?? .text
                    mimeType = spec.mimeType
                    sourceName = spec.name
                    break
                }
            }
        }

        guard let argv0 = argvSpec else {
            return errorResponse(id: id, code: -32002,
                                 message: "Resource not found: \(uri)")
        }

        // Project argv.
        let argv: [String]
        do {
            argv = try projectArgv(argv0, arguments: arguments)
        } catch ArgvProjectionError.missingRequired(let name) {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Missing required argument '\(name)' for resource '\(sourceName)'")
        } catch ArgvProjectionError.unsupportedValueType(let name) {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Unsupported value type for argument '\(name)' on resource '\(sourceName)'")
        } catch {
            return errorResponse(id: id, code: JSONRPCError.invalidParams,
                                 message: "Argv projection failed for '\(sourceName)': \(error)")
        }

        Logger.shared.debug("invoking \(exposure.executable) \(argv.joined(separator: " "))")

        let result: CLIInvocationResult
        do {
            result = try await runCLI(
                executable: URL(fileURLWithPath: exposure.executable),
                args: argv,
                env: effectiveEnv(),
                cwd: exposure.cwd.map { URL(fileURLWithPath: $0) }
            )
        } catch {
            return errorResponse(id: id, code: -32000,
                                 message: "Spawn failed for resource '\(sourceName)': \(error)")
        }

        if result.exitCode != 0 {
            let stderrText = String(decoding: result.stderr, as: UTF8.self)
            let stdoutText = String(decoding: result.stdout, as: UTF8.self)
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            return errorResponse(id: id, code: -32002,
                                 message: "Resource read failed for '\(sourceName)': \(detail)")
        }

        let contents: MCPResourceContents
        switch output {
        case .text:
            let text = String(decoding: result.stdout, as: UTF8.self)
            contents = .text(MCPTextResourceContents(uri: uri, text: text, mimeType: mimeType))
        case .blob:
            let blob = result.stdout.base64EncodedString()
            contents = .blob(MCPBlobResourceContents(uri: uri, blob: blob, mimeType: mimeType))
        }
        let readResult = MCPReadResourceResult(contents: [contents])
        return JSONRPCResponse(id: id, result: Self.encodeAsJSONValue(readResult) ?? .null)
    }

    private func errorResponse(id: JSONRPCID, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message))
    }

    /// Merge parent env underneath the per-server overrides. Host
    /// CLIs almost always need PATH/HOME/USER from the parent —
    /// passing the per-server `env` block alone (the way Foundation
    /// Process treats a non-nil env) would isolate the child and
    /// break common cases like `things add`, which needs `open` on
    /// PATH to fire its URL scheme.
    private func effectiveEnv() -> [String: String]? {
        guard let overrides = exposure.env else { return nil }
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in overrides { merged[key] = value }
        return merged
    }

    /// Lazy-compile the configured templates. `CLIResourceTemplateSpec`
    /// already validated each template at decode time, so re-compiling
    /// here cannot fail in practice; any failure is silently dropped
    /// (the corresponding URI will simply never match).
    private func templateMatchers() -> [(URITemplateMatcher, CLIResourceTemplateSpec)] {
        if let cached = cachedTemplateMatchers { return cached }
        let pairs = (exposure.resourceTemplates ?? []).compactMap { spec -> (URITemplateMatcher, CLIResourceTemplateSpec)? in
            guard let matcher = try? URITemplateMatcher.compile(spec.uriTemplate) else { return nil }
            return (matcher, spec)
        }
        cachedTemplateMatchers = pairs
        return pairs
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
