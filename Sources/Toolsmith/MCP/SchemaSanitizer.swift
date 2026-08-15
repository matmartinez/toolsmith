import Foundation

/// Rewrites GBNF-hostile JSON-Schema `pattern` constructs in `tools/list`
/// results before they reach the client.
///
/// llama.cpp compiles every advertised tool `inputSchema` into a single
/// combined GBNF grammar. A `pattern` carrying a PCRE shorthand class escape
/// (`\s`, `\S`, `\d`, `\w`, `\D`, `\W`, `\b`) at nesting depth ≥ 2 fails
/// grammar compilation, and one bad schema fails the whole chat request with
/// a bare `400: Failed to initialize samplers`.
///
/// The advertised schema is advisory — it only shapes the client's sampling
/// grammar; the MCP server still validates arguments itself at `tools/call`.
/// So rewriting or dropping an offending `pattern` here costs no real
/// validation. Expandable shorthands (`\s`, `\d`, `\w`) become explicit
/// positive classes; the rest (`\S`, `\D`, `\W`, `\b`), which have no safe
/// positive expansion, cause the `pattern` key to be dropped entirely.
///
/// The transform is idempotent (R5): the expansions introduce only literal
/// escapes and plain class members, none of which are themselves in the
/// shorthand set.
public enum SchemaSanitizer {
    /// A single change the sanitizer made, for observability (R7).
    public struct Modification: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            case rewritten(String)
            case dropped
        }
        /// The advertised tool the schema belongs to.
        public let tool: String
        /// Dotted JSON path to the offending `pattern`, e.g.
        /// `inputSchema.properties.attendees.items.properties.email.pattern`.
        public let path: String
        /// The original pattern string, before the transform.
        public let original: String
        public let action: Action
    }

    /// Sanitize a `tools/list` result object in place: walk each tool's
    /// `inputSchema`, rewrite offending patterns, and preserve everything
    /// else (including `nextCursor`, R6). A result with no `tools` array is
    /// returned untouched.
    public static func sanitizeToolsListResult(
        _ result: JSONValue
    ) -> (JSONValue, [Modification]) {
        guard case .object(var obj) = result,
              case .array(let tools)? = obj["tools"]
        else { return (result, []) }

        var mods: [Modification] = []
        var newTools: [JSONValue] = []
        newTools.reserveCapacity(tools.count)
        for tool in tools {
            guard case .object(var entry) = tool else {
                newTools.append(tool)
                continue
            }
            let name: String
            if case .string(let n)? = entry["name"] { name = n } else { name = "?" }
            if let schema = entry["inputSchema"] {
                let (sanitized, schemaMods) = sanitizeSchema(schema, tool: name, path: "inputSchema")
                entry["inputSchema"] = sanitized
                mods.append(contentsOf: schemaMods)
            }
            newTools.append(.object(entry))
        }
        obj["tools"] = .array(newTools)
        return (.object(obj), mods)
    }

    // MARK: - Schema walk (R3)

    /// Keys whose value is itself a single schema (or, for `items`, possibly
    /// an array of schemas in the older tuple form).
    private static let singleSchemaKeys = ["items", "additionalProperties", "propertyNames", "not"]
    /// Keys whose value is a `{ name: schema }` map.
    private static let schemaMapKeys = ["properties", "$defs", "definitions"]
    /// Keys whose value is an array of schemas.
    private static let schemaArrayKeys = ["prefixItems", "anyOf", "oneOf", "allOf"]

    /// Recursively sanitize a schema value. Objects have their `pattern`
    /// rewritten and every nested schema position walked; arrays are walked
    /// element-wise (tuple `items`); scalars/booleans pass through.
    static func sanitizeSchema(
        _ schema: JSONValue,
        tool: String,
        path: String
    ) -> (JSONValue, [Modification]) {
        switch schema {
        case .array(let elements):
            var mods: [Modification] = []
            var out: [JSONValue] = []
            out.reserveCapacity(elements.count)
            for (index, element) in elements.enumerated() {
                let (sanitized, m) = sanitizeSchema(element, tool: tool, path: "\(path)[\(index)]")
                out.append(sanitized)
                mods.append(contentsOf: m)
            }
            return (.array(out), mods)

        case .object(var obj):
            var mods: [Modification] = []

            // Rewrite this level's own `pattern` (R1/R2).
            if case .string(let pattern)? = obj["pattern"] {
                switch sanitizePattern(pattern) {
                case .unchanged:
                    break
                case .rewritten(let replacement):
                    obj["pattern"] = .string(replacement)
                    mods.append(.init(tool: tool, path: "\(path).pattern",
                                      original: pattern, action: .rewritten(replacement)))
                case .drop:
                    obj.removeValue(forKey: "pattern")
                    mods.append(.init(tool: tool, path: "\(path).pattern",
                                      original: pattern, action: .dropped))
                }
            }

            // Single-schema children (items may be object or tuple array;
            // additionalProperties may be a boolean — sanitizeSchema returns
            // non-object/array values untouched).
            for key in singleSchemaKeys {
                guard let child = obj[key] else { continue }
                let (sanitized, m) = sanitizeSchema(child, tool: tool, path: "\(path).\(key)")
                obj[key] = sanitized
                mods.append(contentsOf: m)
            }

            // Maps of schemas: recurse each VALUE, never treating a property
            // name as a schema keyword.
            for key in schemaMapKeys {
                guard case .object(let map)? = obj[key] else { continue }
                var newMap: [String: JSONValue] = [:]
                for (name, value) in map {
                    let (sanitized, m) = sanitizeSchema(value, tool: tool, path: "\(path).\(key).\(name)")
                    newMap[name] = sanitized
                    mods.append(contentsOf: m)
                }
                obj[key] = .object(newMap)
            }

            // Arrays of schemas.
            for key in schemaArrayKeys {
                guard case .array(let arr)? = obj[key] else { continue }
                var out: [JSONValue] = []
                out.reserveCapacity(arr.count)
                for (index, element) in arr.enumerated() {
                    let (sanitized, m) = sanitizeSchema(element, tool: tool, path: "\(path).\(key)[\(index)]")
                    out.append(sanitized)
                    mods.append(contentsOf: m)
                }
                obj[key] = .array(out)
            }

            return (.object(obj), mods)

        default:
            return (schema, [])
        }
    }

    // MARK: - Pattern transform (R1/R2)

    enum PatternResult: Equatable {
        case unchanged
        case rewritten(String)
        case drop
    }

    /// In-class (spliced) expansions for the shorthands that have a safe
    /// positive form. The strings contain literal `\t`/`\r`/… escapes (two
    /// characters each), so the rewrite stays a valid regex and is idempotent.
    private static func expansion(for shorthand: Character) -> String? {
        switch shorthand {
        case "s": return #" \t\r\n\f\v"#
        case "d": return "0-9"
        case "w": return "A-Za-z0-9_"
        default: return nil
        }
    }

    /// Scan a `pattern`, rewriting `\s`/`\d`/`\w` (bare → wrapped class,
    /// in-class → spliced) and flagging `\S`/`\D`/`\W`/`\b` for a full drop.
    /// Every other escaped character (`\.`, `\t`, `\\`, …) is a literal and is
    /// preserved verbatim, so non-offending patterns come back `.unchanged`.
    static func sanitizePattern(_ pattern: String) -> PatternResult {
        let chars = Array(pattern)
        var out = ""
        out.reserveCapacity(chars.count + 8)
        var index = 0
        var inClass = false
        var classJustOpened = false
        var changed = false
        var drop = false

        while index < chars.count {
            let ch = chars[index]

            // Escape sequence.
            if ch == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if let members = expansion(for: next) {
                    out += inClass ? members : "[\(members)]"
                    changed = true
                } else if next == "S" || next == "D" || next == "W" || next == "b" {
                    drop = true
                    out.append(ch); out.append(next)
                } else {
                    // Literal escape — keep as-is.
                    out.append(ch); out.append(next)
                }
                classJustOpened = false
                index += 2
                continue
            }

            if inClass {
                if classJustOpened {
                    // A leading `^` still leaves the next char as the class's
                    // first member; a leading `]` there is a literal.
                    if ch != "^" { classJustOpened = false }
                    out.append(ch)
                } else if ch == "]" {
                    inClass = false
                    out.append(ch)
                } else {
                    out.append(ch)
                }
            } else if ch == "[" {
                inClass = true
                classJustOpened = true
                out.append(ch)
            } else {
                out.append(ch)
            }
            index += 1
        }

        if drop { return .drop }
        return changed ? .rewritten(out) : .unchanged
    }
}
