import Foundation
import Testing

@testable import Toolsmith

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try decode(type, Data(json.utf8))
}

private func string<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encode(value), as: UTF8.self)
}

@Suite("MCP Implementation")
struct MCPImplementationTests {
    @Test("Omits title when nil")
    func omitsNilTitle() throws {
        let impl = MCPImplementation(name: "toolsmith", version: "0.0.0")
        #expect(try string(impl) == #"{"name":"toolsmith","version":"0.0.0"}"#)
    }

    @Test("Encodes title when present")
    func encodesTitle() throws {
        let impl = MCPImplementation(name: "toolsmith", version: "0.0.0", title: "Toolsmith")
        #expect(try string(impl) == #"{"name":"toolsmith","title":"Toolsmith","version":"0.0.0"}"#)
    }

    @Test("Decodes upstream-shaped JSON")
    func decodesUpstreamShape() throws {
        let impl = try decode(
            MCPImplementation.self,
            #"{"name":"mcp-server-fetch","version":"1.2.3"}"#
        )
        #expect(impl.name == "mcp-server-fetch")
        #expect(impl.version == "1.2.3")
        #expect(impl.title == nil)
    }
}

@Suite("MCP capabilities")
struct MCPCapabilitiesTests {
    @Test("Empty server capabilities encode as empty object")
    func emptyServerCaps() throws {
        let caps = MCPServerCapabilities()
        #expect(try string(caps) == "{}")
    }

    @Test("Server capabilities preserve nested empty markers")
    func serverCapsMarkers() throws {
        let caps = MCPServerCapabilities(
            logging: MCPLoggingCapability(),
            tools: MCPToolsCapability(listChanged: true)
        )
        let encoded = try string(caps)
        #expect(encoded == #"{"logging":{},"tools":{"listChanged":true}}"#)
        let roundTripped = try decode(MCPServerCapabilities.self, encoded)
        #expect(roundTripped == caps)
    }

    @Test("Resources capability carries subscribe + listChanged")
    func resourcesCap() throws {
        let caps = MCPServerCapabilities(
            resources: MCPResourcesCapability(subscribe: true, listChanged: false)
        )
        let encoded = try string(caps)
        #expect(encoded == #"{"resources":{"listChanged":false,"subscribe":true}}"#)
    }

    @Test("Client capabilities round-trip with sampling + roots")
    func clientCaps() throws {
        let caps = MCPClientCapabilities(
            roots: MCPRootsCapability(listChanged: true),
            sampling: MCPSamplingCapability()
        )
        let encoded = try string(caps)
        let decoded = try decode(MCPClientCapabilities.self, encoded)
        #expect(decoded == caps)
    }

    @Test("Experimental dictionary survives round-trip")
    func experimental() throws {
        let caps = MCPClientCapabilities(
            experimental: ["my-feature": .object(["enabled": .bool(true)])]
        )
        let decoded = try decode(MCPClientCapabilities.self, try encode(caps))
        #expect(decoded == caps)
    }
}

@Suite("MCP initialize")
struct MCPInitializeTests {
    @Test("Initialize params round-trip")
    func paramsRoundTrip() throws {
        let params = MCPInitializeParams(
            clientInfo: MCPImplementation(name: "toolsmith", version: "0.0.0")
        )
        let decoded = try decode(MCPInitializeParams.self, try encode(params))
        #expect(decoded == params)
        #expect(decoded.protocolVersion == latestMCPProtocolVersion)
    }

    @Test("Initialize result decodes server-shaped JSON")
    func resultDecodesServerShape() throws {
        let json = """
        {
          "protocolVersion": "2025-06-18",
          "capabilities": {
            "tools": {"listChanged": false},
            "logging": {}
          },
          "serverInfo": {"name": "fetch", "version": "0.1.0"},
          "instructions": "Use the fetch tool to retrieve URLs."
        }
        """
        let result = try decode(MCPInitializeResult.self, json)
        #expect(result.protocolVersion == "2025-06-18")
        #expect(result.capabilities.tools?.listChanged == false)
        #expect(result.capabilities.logging != nil)
        #expect(result.serverInfo.name == "fetch")
        #expect(result.instructions == "Use the fetch tool to retrieve URLs.")
    }

    @Test("Initialize wraps cleanly in a JSONRPCRequest")
    func wrapsInJSONRPCRequest() throws {
        let params = MCPInitializeParams(
            clientInfo: MCPImplementation(name: "toolsmith", version: "0.0.0")
        )
        let paramsJSON = try JSONDecoder().decode(JSONValue.self, from: try encode(params))
        let request = JSONRPCRequest(id: 1, method: mcpInitializeMethod, params: paramsJSON)
        let encoded = try string(request)
        #expect(encoded.contains(#""method":"initialize""#))
        #expect(encoded.contains(#""protocolVersion":"2025-06-18""#))
    }
}

@Suite("MCP progress")
struct MCPProgressTests {
    @Test("Progress token string round-trips")
    func tokenString() throws {
        let token: MCPProgressToken = "t-1"
        #expect(try string(token) == "\"t-1\"")
        #expect(try decode(MCPProgressToken.self, "\"t-1\"") == .string("t-1"))
    }

    @Test("Progress token number round-trips")
    func tokenNumber() throws {
        let token: MCPProgressToken = 42
        #expect(try string(token) == "42")
        #expect(try decode(MCPProgressToken.self, "42") == .number(42))
    }

    @Test("Progress notification params round-trip")
    func paramsRoundTrip() throws {
        let params = MCPProgressNotificationParams(
            progressToken: "t",
            progress: 50,
            total: 100,
            message: "halfway"
        )
        let decoded = try decode(MCPProgressNotificationParams.self, try encode(params))
        #expect(decoded == params)
    }

    @Test("Total + message are omitted when nil")
    func omitsNilFields() throws {
        let params = MCPProgressNotificationParams(progressToken: 1, progress: 10)
        let encoded = try string(params)
        #expect(!encoded.contains("total"))
        #expect(!encoded.contains("message"))
    }

    @Test("Extractor reads _meta.progressToken when present")
    func extractorReadsToken() {
        let params: JSONValue = ["_meta": ["progressToken": "abc"], "name": "echo"]
        #expect(MCPProgressTokenExtractor.token(in: params) == .string("abc"))

        let numericParams: JSONValue = ["_meta": ["progressToken": 7]]
        #expect(MCPProgressTokenExtractor.token(in: numericParams) == .number(7))
    }

    @Test("Extractor returns nil when no _meta or no token")
    func extractorReturnsNil() {
        #expect(MCPProgressTokenExtractor.token(in: nil) == nil)
        #expect(MCPProgressTokenExtractor.token(in: ["name": "echo"]) == nil)
        #expect(MCPProgressTokenExtractor.token(in: ["_meta": ["foo": "bar"]]) == nil)
        #expect(MCPProgressTokenExtractor.token(in: .string("not-an-object")) == nil)
    }
}
