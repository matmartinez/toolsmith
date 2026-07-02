import Foundation
import Testing

@testable import Toolsmith

private func roundTrip<T: Encodable, U: Decodable>(_ value: T, as: U.Type) throws -> U {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(U.self, from: data)
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(T.self, from: data)
}

private func echoExposure() -> CLIExposureConfig {
    CLIExposureConfig(
        executable: "/bin/echo",
        tools: [
            CLIToolSpec(
                name: "say",
                inputSchema: ["type": "object",
                              "properties": ["message": ["type": "string"]],
                              "required": ["message"]],
                argv: [.argument(name: "message")],
                description: "Print the given message"
            ),
        ]
    )
}

private func failingExposure() -> CLIExposureConfig {
    // /bin/sh -c "..." with literal as the script; argument piped after.
    CLIExposureConfig(
        executable: "/bin/sh",
        tools: [
            CLIToolSpec(
                name: "boom",
                inputSchema: ["type": "object"],
                argv: [.literal("-c"), .literal("echo error-stream 1>&2; exit 3")]
            ),
        ]
    )
}

private func awaitResponse(
    from backend: CLIBackend,
    requestId id: JSONRPCID,
    method: String,
    params: JSONValue? = nil
) async throws -> JSONRPCResponse {
    let stream = await backend.request(JSONRPCRequest(id: id, method: method, params: params))
    for try await message in stream {
        if case .response(let response) = message { return response }
    }
    throw NSError(domain: "CLIBackendTests", code: 1)
}

@Suite("CLIBackend")
struct CLIBackendTests {
    @Test("initialize advertises tools capability and serverInfo")
    func initialize() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(from: backend, requestId: 1, method: mcpInitializeMethod)
        let result = try decode(MCPInitializeResult.self, from: response.result ?? .null)
        #expect(result.protocolVersion == latestMCPProtocolVersion)
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.capabilities.prompts == nil)
        #expect(result.capabilities.resources == nil)
        #expect(result.serverInfo.name == "toolsmith-cli")
    }

    @Test("tools/list returns the configured tools")
    func toolsList() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(from: backend, requestId: 1, method: mcpListToolsMethod)
        let result = try decode(MCPListToolsResult.self, from: response.result ?? .null)
        #expect(result.tools.count == 1)
        #expect(result.tools[0].name == "say")
        #expect(result.tools[0].description == "Print the given message")
    }

    @Test("tools/call invokes /bin/echo and returns its stdout as text")
    func callToolSuccess() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: mcpCallToolMethod,
            params: ["name": "say", "arguments": ["message": "hi-there"]]
        )
        let result = try decode(MCPCallToolResult.self, from: response.result ?? .null)
        #expect(result.isError == nil)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text == "hi-there\n")
    }

    @Test("Non-zero exit produces isError=true and stderr in content")
    func callToolFailure() async throws {
        let backend = CLIBackend(exposure: failingExposure())
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: mcpCallToolMethod,
            params: ["name": "boom", "arguments": .object([:])]
        )
        let result = try decode(MCPCallToolResult.self, from: response.result ?? .null)
        #expect(result.isError == true)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text == "error-stream\n")
    }

    @Test("Unknown tool name surfaces as JSON-RPC -32601")
    func unknownTool() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: mcpCallToolMethod,
            params: ["name": "nope", "arguments": .object([:])]
        )
        #expect(response.result == nil)
        #expect(response.error?.code == JSONRPCError.methodNotFound)
        #expect(response.error?.message.contains("nope") == true)
    }

    @Test("Missing required argument surfaces as JSON-RPC -32602")
    func missingRequired() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: mcpCallToolMethod,
            params: ["name": "say", "arguments": .object([:])]
        )
        #expect(response.error?.code == JSONRPCError.invalidParams)
        #expect(response.error?.message.contains("message") == true)
    }

    @Test("Unknown method surfaces as JSON-RPC -32601")
    func unknownMethod() async throws {
        let backend = CLIBackend(exposure: echoExposure())
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: "nonexistent/method"
        )
        #expect(response.error?.code == JSONRPCError.methodNotFound)
        #expect(response.error?.message.contains("nonexistent/method") == true)
    }

    @Test("Per-server env is layered on top of the parent env, not a wholesale replacement")
    func envMerging() async throws {
        // /bin/sh exists at an absolute path so we don't rely on PATH
        // resolution for the shell itself. The inline script reads two
        // env vars: TOOLSMITH_OVERRIDE (set by exposure.env) and PATH
        // (inherited from the parent unless we replaced the whole env).
        let exposure = CLIExposureConfig(
            executable: "/bin/sh",
            tools: [
                CLIToolSpec(
                    name: "probe",
                    inputSchema: ["type": "object"],
                    argv: [
                        .literal("-c"),
                        .literal(#"echo override=$TOOLSMITH_OVERRIDE path-empty=$(test -z "$PATH" && echo yes || echo no)"#),
                    ]
                ),
            ],
            env: ["TOOLSMITH_OVERRIDE": "ok"]
        )
        let backend = CLIBackend(exposure: exposure)
        let response = try await awaitResponse(
            from: backend,
            requestId: 1,
            method: mcpCallToolMethod,
            params: ["name": "probe", "arguments": .object([:])]
        )
        let result = try decode(MCPCallToolResult.self, from: response.result ?? .null)
        guard case .text(let text) = result.content[0] else {
            Issue.record("expected text content"); return
        }
        #expect(text.text.contains("override=ok"))
        // PATH must still be present from the parent env even though
        // we set exposure.env — that's the whole point of this fix.
        #expect(text.text.contains("path-empty=no"))
    }

    @Test("Custom serverInfo flows through initialize")
    func customServerInfo() async throws {
        let backend = CLIBackend(
            exposure: echoExposure(),
            serverInfo: MCPImplementation(name: "git-tools", version: "9.9.9")
        )
        let response = try await awaitResponse(from: backend, requestId: 1, method: mcpInitializeMethod)
        let result = try decode(MCPInitializeResult.self, from: response.result ?? .null)
        #expect(result.serverInfo.name == "git-tools")
        #expect(result.serverInfo.version == "9.9.9")
    }
}
