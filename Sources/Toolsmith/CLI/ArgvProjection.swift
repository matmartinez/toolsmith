import Foundation

/// Failure modes encountered while projecting ArgvSpec[] into actual argv.
public enum ArgvProjectionError: Error, Sendable, Equatable {
    case missingRequired(name: String)
    case unsupportedValueType(name: String)
}

/// Projects a list of argv specs + an MCP tools/call `arguments`
/// dictionary into a concrete argv array.
///
/// Stringify rule for `JSONValue` → argv token:
///   - `.string(s)` → s verbatim
///   - `.integer(n)` → decimal representation
///   - `.double(d)` → Swift's default `String(d)`
///   - `.bool(b)` → `"true"` or `"false"`
///   - `.null` / `.array` / `.object` → throws `.unsupportedValueType`
public func projectArgv(
    _ specs: [ArgvSpec],
    arguments: [String: JSONValue]
) throws -> [String] {
    var argv: [String] = []
    for spec in specs {
        switch spec {
        case .literal(let token):
            argv.append(token)

        case .argument(let name):
            guard let value = arguments[name] else {
                throw ArgvProjectionError.missingRequired(name: name)
            }
            argv.append(try stringify(value, name: name))

        case .optionalArgument(let name):
            guard let value = arguments[name] else { continue }
            argv.append(try stringify(value, name: name))

        case .flag(let literal, let name):
            guard let value = arguments[name] else { continue }
            argv.append(literal)
            argv.append(try stringify(value, name: name))

        case .booleanFlag(let literal, let name):
            guard case .bool(let flag) = arguments[name] else { continue }
            if flag { argv.append(literal) }
        }
    }
    return argv
}

private func stringify(_ value: JSONValue, name: String) throws -> String {
    switch value {
    case .string(let s): return s
    case .integer(let n): return String(n)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    case .null, .array, .object:
        throw ArgvProjectionError.unsupportedValueType(name: name)
    }
}
