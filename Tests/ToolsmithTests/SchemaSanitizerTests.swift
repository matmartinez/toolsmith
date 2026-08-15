import Foundation
import Testing

@testable import Toolsmith

@Suite("SchemaSanitizer pattern transform")
struct SchemaSanitizerPatternTests {
    // MARK: Trigger truth table (SCHEMA_SANITIZER_REQUEST.md) — OK rows survive.

    @Test("Non-shorthand patterns are unchanged")
    func okRowsUnchanged() {
        #expect(SchemaSanitizer.sanitizePattern("^[^@]+$") == .unchanged)
        #expect(SchemaSanitizer.sanitizePattern(#"^[^@]+@[^@]+\.[^@]+$"#) == .unchanged)
        #expect(SchemaSanitizer.sanitizePattern(#"^a\.b$"#) == .unchanged)
        #expect(SchemaSanitizer.sanitizePattern("^[a-z]{1,64}$") == .unchanged)
    }

    // Acceptance criterion #3: the working calendar patterns must survive.
    @Test("Acceptance #3 survivors are untouched")
    func survivors() {
        #expect(SchemaSanitizer.sanitizePattern("^[^=]+=[^=]+$") == .unchanged)
        #expect(SchemaSanitizer.sanitizePattern("^[a-z0-9_-]{1,64}$") == .unchanged)
    }

    // FAIL rows containing only \s are rewritten (expandable, not dropped).
    @Test(#"\s inside a class is spliced"#)
    func sInClass() {
        #expect(SchemaSanitizer.sanitizePattern(#"^[^\s]+$"#) == .rewritten(#"^[^ \t\r\n\f\v]+$"#))
        #expect(SchemaSanitizer.sanitizePattern(#"^[^\s@]+$"#) == .rewritten(#"^[^ \t\r\n\f\v@]+$"#))
    }

    @Test("Real-world calendar email pattern is rewritten")
    func calendarEmail() {
        let input = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        let expected = #"^[^ \t\r\n\f\v@]+@[^ \t\r\n\f\v@]+\.[^ \t\r\n\f\v@]+$"#
        #expect(SchemaSanitizer.sanitizePattern(input) == .rewritten(expected))
    }

    // FAIL rows containing \S — no safe positive expansion → drop.
    @Test(#"\S / \D / \W / \b drop the whole pattern"#)
    func unexpandableDrop() {
        #expect(SchemaSanitizer.sanitizePattern(#"^\S+@\S+\.\S+$"#) == .drop)
        #expect(SchemaSanitizer.sanitizePattern(#"^\D+$"#) == .drop)
        #expect(SchemaSanitizer.sanitizePattern(#"\W"#) == .drop)
        #expect(SchemaSanitizer.sanitizePattern(#"\bword\b"#) == .drop)
    }

    @Test(#"Bare \d and \w are wrapped in a class"#)
    func bareWrap() {
        #expect(SchemaSanitizer.sanitizePattern(#"\d"#) == .rewritten("[0-9]"))
        #expect(SchemaSanitizer.sanitizePattern(#"^\d{3}$"#) == .rewritten("^[0-9]{3}$"))
        #expect(SchemaSanitizer.sanitizePattern(#"\w+"#) == .rewritten("[A-Za-z0-9_]+"))
        #expect(SchemaSanitizer.sanitizePattern(#"[\d]"#) == .rewritten("[0-9]"))
        #expect(SchemaSanitizer.sanitizePattern(#"[a\w]"#) == .rewritten("[aA-Za-z0-9_]"))
    }

    @Test("A drop-class shorthand wins over a rewritable one")
    func dropWins() {
        #expect(SchemaSanitizer.sanitizePattern(#"\d\S"#) == .drop)
    }

    @Test("Literal escapes are preserved (not misread as shorthands)")
    func literalEscapes() {
        #expect(SchemaSanitizer.sanitizePattern(#"^\d+\.\d+$"#) == .rewritten(#"^[0-9]+\.[0-9]+$"#))
        // \t is a literal escape, not a shorthand — leave untouched.
        #expect(SchemaSanitizer.sanitizePattern(#"a\tb"#) == .unchanged)
    }

    @Test("Rewrite is idempotent (R5)")
    func idempotent() {
        let patterns = [#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, #"\d{3}"#, #"\w+"#, #"[^\s@]"#]
        for p in patterns {
            guard case .rewritten(let once) = SchemaSanitizer.sanitizePattern(p) else {
                Issue.record("expected rewrite for \(p)")
                continue
            }
            #expect(SchemaSanitizer.sanitizePattern(once) == .unchanged)
        }
    }
}

@Suite("SchemaSanitizer schema walk")
struct SchemaSanitizerWalkTests {
    @Test("Drops a pattern nested under array items + properties (R3, depth ≥ 2)")
    func deepDrop() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "attendees": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "email": ["type": "string", "pattern": #"^\S+@\S+$"#],
                        ],
                    ],
                ],
            ],
        ]
        let (out, mods) = SchemaSanitizer.sanitizeSchema(schema, tool: "t", path: "inputSchema")
        #expect(mods.count == 1)
        #expect(mods.first?.action == .dropped)
        guard case .object(let o) = out,
              case .object(let props) = o["properties"],
              case .object(let att) = props["attendees"],
              case .object(let items) = att["items"],
              case .object(let iprops) = items["properties"],
              case .object(let email) = iprops["email"]
        else { Issue.record("unexpected shape"); return }
        #expect(email["pattern"] == nil)
        #expect(email["type"] == .string("string"))
    }

    @Test("Rewrites through anyOf and $defs")
    func anyOfAndDefs() {
        let schema: JSONValue = [
            "$defs": ["id": ["type": "string", "pattern": #"\w+"#]],
            "anyOf": [
                ["type": "string", "pattern": #"^[^\s]+$"#],
                ["type": "integer"],
            ],
        ]
        let (out, mods) = SchemaSanitizer.sanitizeSchema(schema, tool: "t", path: "inputSchema")
        #expect(mods.count == 2)
        guard case .object(let o) = out,
              case .object(let defs) = o["$defs"],
              case .object(let id) = defs["id"],
              case .array(let any) = o["anyOf"],
              case .object(let first) = any.first
        else { Issue.record("unexpected shape"); return }
        #expect(id["pattern"] == .string("[A-Za-z0-9_]+"))
        #expect(first["pattern"] == .string(#"^[^ \t\r\n\f\v]+$"#))
    }

    @Test("A property literally named 'pattern' is not treated as a keyword")
    func propertyNamedPattern() {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["pattern": ["type": "string"]],
        ]
        let (out, mods) = SchemaSanitizer.sanitizeSchema(schema, tool: "t", path: "s")
        #expect(mods.isEmpty)
        #expect(out == schema)
    }

    @Test("Non-schema values and missing pattern are no-ops")
    func noOps() {
        #expect(SchemaSanitizer.sanitizeSchema(.string("x"), tool: "t", path: "s").1.isEmpty)
        let plain: JSONValue = ["type": "object", "additionalProperties": true]
        let (out, mods) = SchemaSanitizer.sanitizeSchema(plain, tool: "t", path: "s")
        #expect(mods.isEmpty)
        #expect(out == plain)
    }
}

@Suite("SchemaSanitizer tools/list result")
struct SchemaSanitizerToolsListTests {
    @Test("Sanitizes only offending tools, preserves nextCursor and siblings")
    func toolsListResult() {
        let result: JSONValue = [
            "tools": [
                ["name": "good",
                 "inputSchema": ["type": "object",
                                 "properties": ["a": ["type": "string", "pattern": "^[a-z]+$"]]]],
                ["name": "bad",
                 "inputSchema": ["type": "object",
                                 "properties": ["email": ["type": "string", "pattern": #"^[^\s@]+$"#]]]],
            ],
            "nextCursor": "page2",
        ]
        let (out, mods) = SchemaSanitizer.sanitizeToolsListResult(result)
        #expect(mods.count == 1)
        #expect(mods.first?.tool == "bad")
        guard case .object(let o) = out,
              case .array(let tools) = o["tools"],
              case .object(let good) = tools.first,
              case .object(let goodSchema) = good["inputSchema"],
              case .object(let goodProps) = goodSchema["properties"],
              case .object(let goodA) = goodProps["a"],
              case .object(let bad) = tools.last,
              case .object(let badSchema) = bad["inputSchema"],
              case .object(let badProps) = badSchema["properties"],
              case .object(let email) = badProps["email"]
        else { Issue.record("unexpected shape"); return }
        #expect(o["nextCursor"] == .string("page2"))
        #expect(goodA["pattern"] == .string("^[a-z]+$"))
        #expect(email["pattern"] == .string(#"^[^ \t\r\n\f\v@]+$"#))
    }

    @Test("A result with no tools array is returned untouched")
    func nonToolsResult() {
        let result: JSONValue = ["resources": [["uri": "file:///x"]]]
        let (out, mods) = SchemaSanitizer.sanitizeToolsListResult(result)
        #expect(mods.isEmpty)
        #expect(out == result)
    }
}
