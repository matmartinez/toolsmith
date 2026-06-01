import Foundation
import Testing

@testable import Toolsmith

@Suite("ArgvProjection")
struct ArgvProjectionTests {
    @Test("Literal tokens pass through unchanged")
    func literals() throws {
        let argv = try projectArgv(
            [.literal("git"), .literal("status"), .literal("--porcelain")],
            arguments: [:]
        )
        #expect(argv == ["git", "status", "--porcelain"])
    }

    @Test("Required argument emits its stringified value")
    func requiredArgumentString() throws {
        let argv = try projectArgv(
            [.argument(name: "path")],
            arguments: ["path": "/etc/hosts"]
        )
        #expect(argv == ["/etc/hosts"])
    }

    @Test("Required argument: int, double, bool stringify correctly")
    func requiredArgumentScalars() throws {
        #expect(try projectArgv([.argument(name: "n")], arguments: ["n": 42]) == ["42"])
        #expect(try projectArgv([.argument(name: "n")], arguments: ["n": .double(1.5)]) == ["1.5"])
        #expect(try projectArgv([.argument(name: "n")], arguments: ["n": true]) == ["true"])
        #expect(try projectArgv([.argument(name: "n")], arguments: ["n": false]) == ["false"])
    }

    @Test("Missing required argument throws missingRequired")
    func missingRequired() {
        #expect(throws: ArgvProjectionError.missingRequired(name: "path")) {
            _ = try projectArgv([.argument(name: "path")], arguments: [:])
        }
    }

    @Test("Null / array / object value for an argument throws unsupportedValueType")
    func unsupportedValueTypes() {
        for value in [JSONValue.null, .array([.string("x")]), .object(["k": .string("v")])] {
            #expect(throws: ArgvProjectionError.unsupportedValueType(name: "x")) {
                _ = try projectArgv([.argument(name: "x")], arguments: ["x": value])
            }
        }
    }

    @Test("Optional argument is included when present, skipped when absent")
    func optionalArgument() throws {
        let specs: [ArgvSpec] = [.literal("show"), .optionalArgument(name: "format")]
        #expect(try projectArgv(specs, arguments: ["format": "json"]) == ["show", "json"])
        #expect(try projectArgv(specs, arguments: [:]) == ["show"])
    }

    @Test("flag emits literal + value when argument is present, nothing when absent")
    func flag() throws {
        let specs: [ArgvSpec] = [.flag(literal: "-n", argument: "limit")]
        #expect(try projectArgv(specs, arguments: ["limit": 10]) == ["-n", "10"])
        #expect(try projectArgv(specs, arguments: [:]) == [])
    }

    @Test("booleanFlag emits the literal only when value is bool true")
    func booleanFlag() throws {
        let specs: [ArgvSpec] = [.booleanFlag(literal: "--verbose", argument: "verbose")]
        #expect(try projectArgv(specs, arguments: ["verbose": true]) == ["--verbose"])
        #expect(try projectArgv(specs, arguments: ["verbose": false]) == [])
        #expect(try projectArgv(specs, arguments: [:]) == [])
        // Non-bool value: treated as absent (not a hard error).
        #expect(try projectArgv(specs, arguments: ["verbose": "true"]) == [])
    }

    @Test("Combined spec yields the full argv in declaration order")
    func combined() throws {
        let specs: [ArgvSpec] = [
            .literal("log"),
            .flag(literal: "-n", argument: "limit"),
            .booleanFlag(literal: "--stat", argument: "verbose"),
            .optionalArgument(name: "path"),
        ]
        let argv = try projectArgv(specs, arguments: [
            "limit": 5,
            "verbose": true,
            "path": "src/",
        ])
        #expect(argv == ["log", "-n", "5", "--stat", "src/"])
    }
}
