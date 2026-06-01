import Foundation
import Testing

@testable import Toolsmith

private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func string<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encode(value), as: UTF8.self)
}

@Suite("ArgvSpec Codable")
struct ArgvSpecTests {
    @Test("literal round-trips")
    func literalRoundTrip() throws {
        let spec = ArgvSpec.literal("status")
        let encoded = try string(spec)
        #expect(encoded == #"{"literal":"status"}"#)
        #expect(try decode(ArgvSpec.self, encoded) == spec)
    }

    @Test("argument round-trips")
    func argumentRoundTrip() throws {
        let spec = ArgvSpec.argument(name: "path")
        let encoded = try string(spec)
        #expect(encoded == #"{"argument":"path"}"#)
        #expect(try decode(ArgvSpec.self, encoded) == spec)
    }

    @Test("optionalArgument round-trips")
    func optionalArgumentRoundTrip() throws {
        let spec = ArgvSpec.optionalArgument(name: "format")
        let encoded = try string(spec)
        #expect(encoded == #"{"optionalArgument":"format"}"#)
        #expect(try decode(ArgvSpec.self, encoded) == spec)
    }

    @Test("flag round-trips with argument pair")
    func flagRoundTrip() throws {
        let spec = ArgvSpec.flag(literal: "-n", argument: "limit")
        let encoded = try string(spec)
        #expect(encoded == #"{"argument":"limit","flag":"-n"}"#)
        #expect(try decode(ArgvSpec.self, encoded) == spec)
    }

    @Test("booleanFlag round-trips with argument pair")
    func booleanFlagRoundTrip() throws {
        let spec = ArgvSpec.booleanFlag(literal: "--verbose", argument: "verbose")
        let encoded = try string(spec)
        #expect(encoded == #"{"argument":"verbose","booleanFlag":"--verbose"}"#)
        #expect(try decode(ArgvSpec.self, encoded) == spec)
    }

    @Test("Empty object rejects")
    func emptyRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(ArgvSpec.self, "{}")
        }
    }

    @Test("Unknown tag key rejects")
    func unknownTagRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(ArgvSpec.self, #"{"hologram":"x"}"#)
        }
    }

    @Test("Conflicting tag keys (literal + argument) reject")
    func conflictingTagsReject() {
        #expect(throws: (any Error).self) {
            _ = try decode(ArgvSpec.self, #"{"literal":"a","argument":"b"}"#)
        }
    }

    @Test("Conflicting tag keys (flag + literal) reject")
    func flagAndLiteralReject() {
        #expect(throws: (any Error).self) {
            _ = try decode(ArgvSpec.self, #"{"literal":"a","flag":"-n","argument":"limit"}"#)
        }
    }

    @Test("flag without argument key rejects")
    func flagMissingArgumentRejects() {
        #expect(throws: (any Error).self) {
            _ = try decode(ArgvSpec.self, #"{"flag":"-n"}"#)
        }
    }

    @Test("Array of mixed specs round-trips through Codable")
    func arrayRoundTrip() throws {
        let specs: [ArgvSpec] = [
            .literal("log"),
            .flag(literal: "-n", argument: "limit"),
            .booleanFlag(literal: "--verbose", argument: "verbose"),
            .optionalArgument(name: "path"),
        ]
        let encoded = try encode(specs)
        let decoded = try JSONDecoder().decode([ArgvSpec].self, from: encoded)
        #expect(decoded == specs)
    }
}
