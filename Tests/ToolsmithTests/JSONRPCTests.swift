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

@Suite("JSONValue round-trip")
struct JSONValueTests {
    @Test("Null round-trips")
    func nullRoundTrip() throws {
        let value: JSONValue = .null
        #expect(try string(value) == "null")
        #expect(try decode(JSONValue.self, "null") == .null)
    }

    @Test("Bool round-trips")
    func boolRoundTrip() throws {
        #expect(try string(JSONValue.bool(true)) == "true")
        #expect(try decode(JSONValue.self, "false") == .bool(false))
    }

    @Test("Integer round-trips and beats double when whole")
    func integerRoundTrip() throws {
        #expect(try string(JSONValue.integer(42)) == "42")
        #expect(try decode(JSONValue.self, "42") == .integer(42))
        #expect(try decode(JSONValue.self, "-7") == .integer(-7))
    }

    @Test("Double round-trips when fractional")
    func doubleRoundTrip() throws {
        #expect(try decode(JSONValue.self, "1.5") == .double(1.5))
    }

    @Test("String round-trips")
    func stringRoundTrip() throws {
        #expect(try string(JSONValue.string("hi")) == "\"hi\"")
        #expect(try decode(JSONValue.self, "\"hi\"") == .string("hi"))
    }

    @Test("Array round-trips")
    func arrayRoundTrip() throws {
        let value: JSONValue = [1, "two", true, .null]
        let encoded = try string(value)
        #expect(try decode(JSONValue.self, encoded) == value)
    }

    @Test("Object round-trips")
    func objectRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [1, 2, 3], "c": ["nested": true]]
        let encoded = try encode(value)
        #expect(try decode(JSONValue.self, encoded) == value)
    }

    @Test("Sorted-keys encoder gives stable bytes")
    func sortedKeysStable() throws {
        let value: JSONValue = ["b": 2, "a": 1, "c": 3]
        #expect(try string(value) == #"{"a":1,"b":2,"c":3}"#)
    }

    @Test("Garbage rejects")
    func garbageRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(JSONValue.self, "{invalid}")
        }
    }
}

@Suite("JSONRPCID round-trip")
struct JSONRPCIDTests {
    @Test("Number id round-trips")
    func numberId() throws {
        let id: JSONRPCID = 7
        #expect(try string(id) == "7")
        #expect(try decode(JSONRPCID.self, "7") == .number(7))
    }

    @Test("String id round-trips")
    func stringId() throws {
        let id: JSONRPCID = "abc"
        #expect(try string(id) == "\"abc\"")
        #expect(try decode(JSONRPCID.self, "\"abc\"") == .string("abc"))
    }

    @Test("Null id round-trips")
    func nullId() throws {
        #expect(try string(JSONRPCID.null) == "null")
        #expect(try decode(JSONRPCID.self, "null") == .null)
    }

    @Test("String '1' and number 1 are distinct")
    func stringNumberDistinct() {
        #expect(JSONRPCID.string("1") != .number(1))
    }

    @Test("Boolean id rejects")
    func boolRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(JSONRPCID.self, "true")
        }
    }
}

@Suite("JSON-RPC envelopes")
struct JSONRPCEnvelopeTests {
    @Test("Request encodes with jsonrpc, id, method, params")
    func requestEncoding() throws {
        let request = JSONRPCRequest(
            id: 1,
            method: "tools/call",
            params: ["name": "echo", "arguments": ["text": "hi"]]
        )
        let encoded = try string(request)
        let expected = #"{"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"text":"hi"},"name":"echo"}}"#
        #expect(encoded == expected)
    }

    @Test("Request without params omits the key")
    func requestOmitsNilParams() throws {
        let request = JSONRPCRequest(id: 1, method: "ping")
        let encoded = try string(request)
        #expect(!encoded.contains("params"))
    }

    @Test("Request round-trips")
    func requestRoundTrip() throws {
        let request = JSONRPCRequest(
            id: "uuid-1",
            method: "initialize",
            params: ["protocolVersion": "2024-11-05"]
        )
        let decoded = try decode(JSONRPCRequest.self, try encode(request))
        #expect(decoded == request)
    }

    @Test("Notification has no id and round-trips")
    func notificationRoundTrip() throws {
        let notification = JSONRPCNotification(
            method: "notifications/progress",
            params: ["progressToken": "t", "progress": 50, "total": 100]
        )
        let encoded = try string(notification)
        #expect(!encoded.contains("\"id\""))
        let decoded = try decode(JSONRPCNotification.self, Data(encoded.utf8))
        #expect(decoded == notification)
    }

    @Test("Response (success) round-trips and omits error")
    func responseSuccessRoundTrip() throws {
        let response = JSONRPCResponse(
            id: 1,
            result: ["content": [["type": "text", "text": "ok"]]]
        )
        let encoded = try string(response)
        #expect(!encoded.contains("\"error\""))
        let decoded = try decode(JSONRPCResponse.self, Data(encoded.utf8))
        #expect(decoded == response)
    }

    @Test("Response (error) round-trips and omits result")
    func responseErrorRoundTrip() throws {
        let response = JSONRPCResponse(
            id: 1,
            error: JSONRPCError(
                code: JSONRPCError.methodNotFound,
                message: "unknown",
                data: ["method": "foo"]
            )
        )
        let encoded = try string(response)
        #expect(!encoded.contains("\"result\""))
        let decoded = try decode(JSONRPCResponse.self, Data(encoded.utf8))
        #expect(decoded == response)
    }

    @Test("Error without data omits the key")
    func errorOmitsNilData() throws {
        let error = JSONRPCError(code: -1, message: "boom")
        let encoded = try string(error)
        #expect(encoded == #"{"code":-1,"message":"boom"}"#)
    }
}

@Suite("JSONRPCMessage discriminator")
struct JSONRPCMessageTests {
    @Test("Decodes request when method + id present")
    func decodesRequest() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let message = try decode(JSONRPCMessage.self, json)
        guard case .request(let request) = message else {
            Issue.record("expected .request, got \(message)")
            return
        }
        #expect(request.method == "tools/list")
        #expect(request.id == .number(1))
    }

    @Test("Decodes notification when method present without id")
    func decodesNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let message = try decode(JSONRPCMessage.self, json)
        guard case .notification(let notification) = message else {
            Issue.record("expected .notification, got \(message)")
            return
        }
        #expect(notification.method == "notifications/initialized")
    }

    @Test("Decodes response when result present")
    func decodesResponseSuccess() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#
        let message = try decode(JSONRPCMessage.self, json)
        guard case .response(let response) = message else {
            Issue.record("expected .response, got \(message)")
            return
        }
        #expect(response.id == .number(2))
        #expect(response.result == .object(["ok": .bool(true)]))
        #expect(response.error == nil)
    }

    @Test("Decodes response when error present")
    func decodesResponseError() throws {
        let json = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"missing"}}"#
        let message = try decode(JSONRPCMessage.self, json)
        guard case .response(let response) = message else {
            Issue.record("expected .response, got \(message)")
            return
        }
        #expect(response.error?.code == JSONRPCError.methodNotFound)
    }

    @Test("Round-trips each variant through the envelope")
    func envelopeRoundTrip() throws {
        let cases: [JSONRPCMessage] = [
            .request(JSONRPCRequest(id: 1, method: "m", params: ["k": "v"])),
            .notification(JSONRPCNotification(method: "n")),
            .response(JSONRPCResponse(id: 1, result: .integer(7))),
            .response(JSONRPCResponse(id: 1, error: .init(code: -1, message: "e"))),
        ]
        for original in cases {
            let encoded = try encode(original)
            let decoded = try decode(JSONRPCMessage.self, encoded)
            #expect(decoded == original)
        }
    }

    @Test("Object without discriminator fields rejects")
    func rejectsEmptyObject() {
        #expect(throws: (any Error).self) {
            _ = try decode(JSONRPCMessage.self, #"{"jsonrpc":"2.0"}"#)
        }
    }
}
