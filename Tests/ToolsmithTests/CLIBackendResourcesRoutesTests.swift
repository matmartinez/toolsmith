import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

private func resourceExposure() -> CLIExposureConfig {
    CLIExposureConfig(
        executable: "/bin/echo",
        tools: [],
        resources: [
            CLIResourceSpec(
                name: "greeting",
                uri: "echo://hello",
                argv: [.literal("hello")],
                mimeType: "text/plain",
                output: .text
            ),
        ],
        resourceTemplates: [
            CLIResourceTemplateSpec(
                name: "echo-text",
                uriTemplate: "echo://text/{value}",
                argv: [.argument(name: "value")],
                mimeType: "text/plain",
                output: .text
            ),
            CLIResourceTemplateSpec(
                name: "echo-bytes",
                uriTemplate: "echo://bytes/{value}",
                argv: [.argument(name: "value")],
                mimeType: "application/octet-stream",
                output: .blob
            ),
        ]
    )
}

private func toolsOnlyExposure() -> CLIExposureConfig {
    CLIExposureConfig(
        executable: "/bin/echo",
        tools: [
            CLIToolSpec(
                name: "say",
                inputSchema: ["type": "object"],
                argv: [.literal("hi")]
            ),
        ]
    )
}

private func startProxy(exposure: CLIExposureConfig, name: String = "echo") async throws
    -> (ServerModeProxy, URL)
{
    let proxy = try ServerModeProxy(
        host: "127.0.0.1",
        port: 0,
        servers: [.init(name: name, backend: .cliExposure(exposure))]
    )
    let address = try await proxy.start()
    return (proxy, URL(string: "http://127.0.0.1:\(address.port!)")!)
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
    let data = try WireJSON.encoder().encode(value)
    return try WireJSON.decoder().decode(T.self, from: data)
}

private func roundTrip(
    base: URL,
    server: String,
    request: JSONRPCRequest
) async throws -> JSONRPCResponse {
    let httpClient = URLSessionHTTPClient()
    let body = try WireJSON.encoder().encode(JSONRPCMessage.request(request))
    let stream = try await httpClient.openStream(HTTPRequest(
        method: "POST",
        url: base.appendingPathComponent("servers/\(server)/mcp"),
        headers: [("Content-Type", "application/json")],
        body: body
    ))
    var parser = SSEParser()
    var iterator = stream.lines.makeAsyncIterator()
    while true {
        guard let line = try await iterator.next() else {
            throw CLIBackendResourcesRoutesError.streamEnded
        }
        if let event = parser.feed(line: line), event.event == "message" {
            let decoded = try WireJSON.decoder().decode(
                JSONRPCMessage.self, from: Data(event.data.utf8)
            )
            guard case .response(let response) = decoded else {
                throw CLIBackendResourcesRoutesError.unexpectedMessage
            }
            return response
        }
    }
}

private enum CLIBackendResourcesRoutesError: Error {
    case streamEnded
    case unexpectedMessage
}

@Suite("CLIBackend resource routes")
struct CLIBackendResourcesRoutesTests {
    @Test("resources/list returns declared static resources")
    func resourcesList() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(id: 1, method: mcpListResourcesMethod)
        )
        let result = try decode(MCPListResourcesResult.self, from: response.result ?? .null)
        #expect(result.resources.map(\.uri) == ["echo://hello"])
        #expect(result.resources[0].mimeType == "text/plain")
    }

    @Test("resources/templates/list returns declared templates")
    func templatesList() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(id: 2, method: mcpListResourceTemplatesMethod)
        )
        let result = try decode(MCPListResourceTemplatesResult.self, from: response.result ?? .null)
        #expect(result.resourceTemplates.map(\.uriTemplate)
                == ["echo://text/{value}", "echo://bytes/{value}"])
    }

    @Test("resources/read on a templated text URI captures and projects the placeholder")
    func readTextTemplate() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 3, method: mcpReadResourceMethod,
                params: ["uri": "echo://text/hi-from-template"]
            )
        )
        let result = try decode(MCPReadResourceResult.self, from: response.result ?? .null)
        guard case .text(let text) = result.contents[0] else {
            Issue.record("expected text contents"); return
        }
        #expect(text.uri == "echo://text/hi-from-template")
        #expect(text.text == "hi-from-template\n")
        #expect(text.mimeType == "text/plain")
    }

    @Test("resources/read with output=blob round-trips through base64")
    func readBlobTemplate() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 4, method: mcpReadResourceMethod,
                params: ["uri": "echo://bytes/payload"]
            )
        )
        let result = try decode(MCPReadResourceResult.self, from: response.result ?? .null)
        guard case .blob(let blob) = result.contents[0] else {
            Issue.record("expected blob contents"); return
        }
        let bytes = Data(base64Encoded: blob.blob)
        #expect(bytes.map { String(decoding: $0, as: UTF8.self) } == "payload\n")
        #expect(blob.mimeType == "application/octet-stream")
    }

    @Test("resources/read on a static URI uses the static spec")
    func readStaticResource() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 5, method: mcpReadResourceMethod,
                params: ["uri": "echo://hello"]
            )
        )
        let result = try decode(MCPReadResourceResult.self, from: response.result ?? .null)
        guard case .text(let text) = result.contents[0] else {
            Issue.record("expected text contents"); return
        }
        #expect(text.text == "hello\n")
    }

    @Test("Unknown URI surfaces as JSON-RPC -32002")
    func readUnknownURI() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 6, method: mcpReadResourceMethod,
                params: ["uri": "mail://nowhere"]
            )
        )
        #expect(response.error?.code == -32002)
    }

    @Test("Exposure with no resources omits the resources capability on initialize")
    func capabilityOmittedWithoutResources() async throws {
        let (proxy, base) = try await startProxy(exposure: toolsOnlyExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 7, method: mcpInitializeMethod,
                params: ["protocolVersion": .string(latestMCPProtocolVersion),
                         "capabilities": [:],
                         "clientInfo": ["name": "t", "version": "0"]]
            )
        )
        let result = try decode(MCPInitializeResult.self, from: response.result ?? .null)
        #expect(result.capabilities.resources == nil)
        #expect(result.capabilities.tools != nil)
    }

    @Test("Exposure with resources advertises the resources capability on initialize")
    func capabilityAdvertisedWithResources() async throws {
        let (proxy, base) = try await startProxy(exposure: resourceExposure())
        defer { Task { await proxy.stop() } }

        let response = try await roundTrip(
            base: base, server: "echo",
            request: JSONRPCRequest(
                id: 8, method: mcpInitializeMethod,
                params: ["protocolVersion": .string(latestMCPProtocolVersion),
                         "capabilities": [:],
                         "clientInfo": ["name": "t", "version": "0"]]
            )
        )
        let result = try decode(MCPInitializeResult.self, from: response.result ?? .null)
        #expect(result.capabilities.resources?.subscribe == false)
        #expect(result.capabilities.resources?.listChanged == false)
    }
}
