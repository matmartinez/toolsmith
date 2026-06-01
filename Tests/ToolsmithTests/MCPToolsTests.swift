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

@Suite("MCP Tool")
struct MCPToolTests {
    @Test("Minimal tool round-trips")
    func minimalRoundTrip() throws {
        let tool = MCPTool(name: "echo", inputSchema: ["type": "object"])
        let decoded = try decode(MCPTool.self, try encode(tool))
        #expect(decoded == tool)
    }

    @Test("Tool with full annotations round-trips")
    func fullRoundTrip() throws {
        let tool = MCPTool(
            name: "fetch",
            inputSchema: [
                "type": "object",
                "properties": ["url": ["type": "string"]],
                "required": ["url"],
            ],
            title: "HTTP Fetch",
            description: "Fetches a URL.",
            outputSchema: ["type": "object"],
            annotations: MCPToolAnnotations(
                title: "Fetch",
                readOnlyHint: true,
                openWorldHint: true
            )
        )
        let decoded = try decode(MCPTool.self, try encode(tool))
        #expect(decoded == tool)
    }

    @Test("Tool preserves opaque inputSchema fields")
    func opaqueSchema() throws {
        let json = """
        {
          "name": "weird",
          "inputSchema": {
            "type": "object",
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "x-custom": [1, 2, 3]
          }
        }
        """
        let tool = try decode(MCPTool.self, json)
        guard case .object(let schema) = tool.inputSchema else {
            Issue.record("inputSchema is not an object")
            return
        }
        #expect(schema["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"))
        #expect(schema["x-custom"] == .array([.integer(1), .integer(2), .integer(3)]))
    }
}

@Suite("MCP tools/list")
struct MCPListToolsTests {
    @Test("Result with multiple tools round-trips")
    func resultRoundTrip() throws {
        let result = MCPListToolsResult(
            tools: [
                MCPTool(name: "a", inputSchema: ["type": "object"]),
                MCPTool(name: "b", inputSchema: ["type": "object"], description: "second"),
            ],
            nextCursor: "page-2"
        )
        let decoded = try decode(MCPListToolsResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("Result without nextCursor omits the key")
    func resultOmitsCursor() throws {
        let result = MCPListToolsResult(tools: [])
        let encoded = try string(result)
        #expect(!encoded.contains("nextCursor"))
        #expect(encoded == #"{"tools":[]}"#)
    }

    @Test("Params without cursor encode as empty object")
    func paramsEmpty() throws {
        let params = MCPListToolsParams()
        #expect(try string(params) == "{}")
    }
}

@Suite("MCP tools/call")
struct MCPCallToolTests {
    @Test("Params round-trip with arguments")
    func paramsWithArgs() throws {
        let params = MCPCallToolParams(
            name: "echo",
            arguments: ["text": "hello"]
        )
        let decoded = try decode(MCPCallToolParams.self, try encode(params))
        #expect(decoded == params)
    }

    @Test("Params omit arguments when nil")
    func paramsOmitsNilArgs() throws {
        let params = MCPCallToolParams(name: "ping")
        let encoded = try string(params)
        #expect(encoded == #"{"name":"ping"}"#)
    }

    @Test("Result with text content round-trips")
    func textResult() throws {
        let result = MCPCallToolResult(
            content: [.text(MCPTextContent(text: "hello world"))]
        )
        let decoded = try decode(MCPCallToolResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("Result with isError + structuredContent")
    func errorResult() throws {
        let result = MCPCallToolResult(
            content: [.text(MCPTextContent(text: "boom"))],
            structuredContent: ["code": "E_TIMEOUT"],
            isError: true
        )
        let decoded = try decode(MCPCallToolResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("Result with mixed content types round-trips")
    func mixedContent() throws {
        let result = MCPCallToolResult(
            content: [
                .text(MCPTextContent(text: "hello")),
                .image(MCPImageContent(data: "base64data", mimeType: "image/png")),
                .audio(MCPAudioContent(data: "audiodata", mimeType: "audio/wav")),
            ]
        )
        let decoded = try decode(MCPCallToolResult.self, try encode(result))
        #expect(decoded == result)
    }
}

@Suite("MCP content discriminator")
struct MCPContentTests {
    @Test("Text content encodes with type tag")
    func textEncoding() throws {
        let content: MCPContent = .text(MCPTextContent(text: "hi"))
        #expect(try string(content) == #"{"text":"hi","type":"text"}"#)
    }

    @Test("Image content round-trips")
    func imageRoundTrip() throws {
        let content: MCPContent = .image(
            MCPImageContent(data: "abc", mimeType: "image/png")
        )
        let decoded = try decode(MCPContent.self, try encode(content))
        #expect(decoded == content)
    }

    @Test("Resource link round-trips with type='resource_link'")
    func resourceLink() throws {
        let resource = MCPResource(
            name: "readme",
            uri: "file:///README.md",
            mimeType: "text/markdown"
        )
        let content: MCPContent = .resourceLink(resource)
        let encoded = try string(content)
        #expect(encoded.contains(#""type":"resource_link""#))
        let decoded = try decode(MCPContent.self, Data(encoded.utf8))
        #expect(decoded == content)
    }

    @Test("Embedded text resource round-trips")
    func embeddedText() throws {
        let content: MCPContent = .resource(
            MCPEmbeddedResource(
                resource: .text(MCPTextResourceContents(uri: "file:///a.txt", text: "body"))
            )
        )
        let decoded = try decode(MCPContent.self, try encode(content))
        #expect(decoded == content)
    }

    @Test("Embedded blob resource round-trips")
    func embeddedBlob() throws {
        let content: MCPContent = .resource(
            MCPEmbeddedResource(
                resource: .blob(MCPBlobResourceContents(uri: "file:///a.bin", blob: "AAAA"))
            )
        )
        let decoded = try decode(MCPContent.self, try encode(content))
        #expect(decoded == content)
    }

    @Test("Unknown content type rejects")
    func unknownTypeRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(MCPContent.self, #"{"type":"hologram","data":"x"}"#)
        }
    }
}

@Suite("MCP resource contents discriminator")
struct MCPResourceContentsTests {
    @Test("Text variant decodes when `text` field is present")
    func textVariant() throws {
        let contents = try decode(
            MCPResourceContents.self,
            #"{"uri":"file:///a.txt","text":"body"}"#
        )
        guard case .text(let t) = contents else {
            Issue.record("expected text variant")
            return
        }
        #expect(t.text == "body")
    }

    @Test("Blob variant decodes when `blob` field is present")
    func blobVariant() throws {
        let contents = try decode(
            MCPResourceContents.self,
            #"{"uri":"file:///a.bin","blob":"AAAA"}"#
        )
        guard case .blob(let b) = contents else {
            Issue.record("expected blob variant")
            return
        }
        #expect(b.blob == "AAAA")
    }

    @Test("Neither field rejects")
    func neitherFieldRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(MCPResourceContents.self, #"{"uri":"file:///a"}"#)
        }
    }
}
