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

@Suite("MCP resources")
struct MCPResourcesTests {
    @Test("ResourceTemplate round-trips")
    func templateRoundTrip() throws {
        let template = MCPResourceTemplate(
            name: "logs",
            uriTemplate: "file:///logs/{date}.log",
            description: "Daily log files.",
            mimeType: "text/plain"
        )
        let decoded = try decode(MCPResourceTemplate.self, try encode(template))
        #expect(decoded == template)
    }

    @Test("ListResourcesResult round-trips with pagination")
    func listResources() throws {
        let result = MCPListResourcesResult(
            resources: [
                MCPResource(name: "readme", uri: "file:///README.md", mimeType: "text/markdown"),
            ],
            nextCursor: "page-2"
        )
        let decoded = try decode(MCPListResourcesResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("ListResourceTemplatesResult round-trips")
    func listTemplates() throws {
        let result = MCPListResourceTemplatesResult(
            resourceTemplates: [
                MCPResourceTemplate(name: "logs", uriTemplate: "file:///logs/{date}.log"),
            ]
        )
        let decoded = try decode(MCPListResourceTemplatesResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("ReadResourceResult with mixed text and blob round-trips")
    func readResult() throws {
        let result = MCPReadResourceResult(
            contents: [
                .text(MCPTextResourceContents(uri: "file:///a.txt", text: "hello")),
                .blob(MCPBlobResourceContents(uri: "file:///a.bin", blob: "AAAA")),
            ]
        )
        let decoded = try decode(MCPReadResourceResult.self, try encode(result))
        #expect(decoded == result)
    }

    @Test("Subscribe / Unsubscribe / ResourceUpdated params encode the uri")
    func subscribeShapes() throws {
        #expect(try string(MCPSubscribeParams(uri: "file:///a")) == #"{"uri":"file:///a"}"#)
        #expect(try string(MCPUnsubscribeParams(uri: "file:///a")) == #"{"uri":"file:///a"}"#)
        #expect(try string(MCPResourceUpdatedParams(uri: "file:///a")) == #"{"uri":"file:///a"}"#)
    }
}

@Suite("MCP prompts")
struct MCPPromptsTests {
    @Test("Prompt round-trips with arguments")
    func promptRoundTrip() throws {
        let prompt = MCPPrompt(
            name: "summarize",
            description: "Summarize a document.",
            arguments: [
                MCPPromptArgument(name: "text", description: "Document text", required: true),
                MCPPromptArgument(name: "style", required: false),
            ]
        )
        let decoded = try decode(MCPPrompt.self, try encode(prompt))
        #expect(decoded == prompt)
    }

    @Test("GetPromptParams arguments are strings")
    func getPromptArgs() throws {
        let params = MCPGetPromptParams(name: "summarize", arguments: ["text": "Hello.", "style": "terse"])
        let decoded = try decode(MCPGetPromptParams.self, try encode(params))
        #expect(decoded == params)
    }

    @Test("GetPromptResult carries messages with content blocks")
    func getPromptResult() throws {
        let result = MCPGetPromptResult(
            description: "A friendly greeting.",
            messages: [
                MCPPromptMessage(role: .user, content: .text(MCPTextContent(text: "hi"))),
                MCPPromptMessage(role: .assistant, content: .text(MCPTextContent(text: "hello!"))),
            ]
        )
        let decoded = try decode(MCPGetPromptResult.self, try encode(result))
        #expect(decoded == result)
    }
}

@Suite("MCP completion")
struct MCPCompletionTests {
    @Test("Prompt ref encodes type=ref/prompt")
    func promptRef() throws {
        let ref: MCPCompletionRef = .prompt(MCPPromptReference(name: "summarize"))
        #expect(try string(ref) == #"{"name":"summarize","type":"ref/prompt"}"#)
    }

    @Test("Resource-template ref encodes type=ref/resource")
    func resourceRef() throws {
        let ref: MCPCompletionRef = .resourceTemplate(
            MCPResourceTemplateReference(uri: "file:///logs/{date}.log")
        )
        #expect(try string(ref) == #"{"type":"ref/resource","uri":"file:///logs/{date}.log"}"#)
    }

    @Test("Completion ref decodes both variants")
    func refRoundTrip() throws {
        let prompt = try decode(MCPCompletionRef.self, #"{"type":"ref/prompt","name":"x"}"#)
        guard case .prompt(let p) = prompt else { Issue.record("expected prompt"); return }
        #expect(p.name == "x")

        let resource = try decode(MCPCompletionRef.self, #"{"type":"ref/resource","uri":"u"}"#)
        guard case .resourceTemplate(let r) = resource else { Issue.record("expected resource"); return }
        #expect(r.uri == "u")
    }

    @Test("Unknown ref type rejects")
    func unknownRefRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(MCPCompletionRef.self, #"{"type":"ref/unknown"}"#)
        }
    }

    @Test("CompleteParams + Result round-trip")
    func completeRoundTrip() throws {
        let params = MCPCompleteParams(
            ref: .prompt(MCPPromptReference(name: "p")),
            argument: MCPCompletionArgument(name: "style", value: "ter"),
            context: MCPCompletionContext(arguments: ["prev": "v"])
        )
        let decodedParams = try decode(MCPCompleteParams.self, try encode(params))
        #expect(decodedParams == params)

        let result = MCPCompleteResult(
            completion: MCPCompletion(values: ["terse", "tersely"], total: 12, hasMore: true)
        )
        let decodedResult = try decode(MCPCompleteResult.self, try encode(result))
        #expect(decodedResult == result)
    }
}

@Suite("MCP logging")
struct MCPLoggingTests {
    @Test("All log levels round-trip")
    func levelRoundTrip() throws {
        for level in MCPLoggingLevel.allCases {
            let params = MCPSetLogLevelParams(level: level)
            let decoded = try decode(MCPSetLogLevelParams.self, try encode(params))
            #expect(decoded == params)
        }
    }

    @Test("Log message params encode data as JSON")
    func logMessage() throws {
        let params = MCPLogMessageParams(
            level: .warning,
            data: ["msg": "slow query", "ms": 850],
            logger: "db"
        )
        let decoded = try decode(MCPLogMessageParams.self, try encode(params))
        #expect(decoded == params)
    }
}

@Suite("MCP cancellation")
struct MCPCancellationTests {
    @Test("CancelledParams with numeric id round-trips")
    func numericId() throws {
        let params = MCPCancelledParams(requestId: 17, reason: "user aborted")
        let decoded = try decode(MCPCancelledParams.self, try encode(params))
        #expect(decoded == params)
    }

    @Test("CancelledParams with string id and no reason omits reason")
    func stringIdNoReason() throws {
        let params = MCPCancelledParams(requestId: "abc")
        let encoded = try string(params)
        #expect(!encoded.contains("reason"))
        #expect(encoded.contains("\"requestId\":\"abc\""))
    }
}

@Suite("MCP method-name constants")
struct MCPMethodNamesTests {
    @Test("Constants match the spec strings")
    func constants() {
        #expect(mcpInitializeMethod == "initialize")
        #expect(mcpInitializedNotificationMethod == "notifications/initialized")
        #expect(mcpProgressNotificationMethod == "notifications/progress")
        #expect(mcpListToolsMethod == "tools/list")
        #expect(mcpCallToolMethod == "tools/call")
        #expect(mcpListResourcesMethod == "resources/list")
        #expect(mcpReadResourceMethod == "resources/read")
        #expect(mcpListResourceTemplatesMethod == "resources/templates/list")
        #expect(mcpSubscribeResourceMethod == "resources/subscribe")
        #expect(mcpUnsubscribeResourceMethod == "resources/unsubscribe")
        #expect(mcpResourceUpdatedNotificationMethod == "notifications/resources/updated")
        #expect(mcpResourceListChangedNotificationMethod == "notifications/resources/list_changed")
        #expect(mcpListPromptsMethod == "prompts/list")
        #expect(mcpGetPromptMethod == "prompts/get")
        #expect(mcpPromptListChangedNotificationMethod == "notifications/prompts/list_changed")
        #expect(mcpCompleteMethod == "completion/complete")
        #expect(mcpSetLogLevelMethod == "logging/setLevel")
        #expect(mcpLogMessageNotificationMethod == "notifications/message")
        #expect(mcpCancelledNotificationMethod == "notifications/cancelled")
        #expect(mcpToolListChangedNotificationMethod == "notifications/tools/list_changed")
    }
}
