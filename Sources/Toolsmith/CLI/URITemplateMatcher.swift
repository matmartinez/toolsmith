import Foundation

/// Compiled `{name}`-style URI template. Self-contained, deliberately
/// narrower than RFC 6570: no operators, no list expansion, just
/// alternating literal segments and named placeholders. Captured
/// values are percent-decoded before being returned.
public struct URITemplateMatcher: Hashable, Sendable {
    public enum Segment: Hashable, Sendable {
        case literal(String)
        case placeholder(String)
    }

    public enum CompileError: Error, Equatable, Sendable {
        case emptyPlaceholder
        case unterminatedPlaceholder
        case nestedBrace
        case duplicatePlaceholder(String)
        case invalidPlaceholderName(String)
        case reservedPlaceholderName(String)
    }

    public let template: String
    public let segments: [Segment]
    public let placeholderNames: [String]

    /// Synthetic argument name injected into `resources/read` argument
    /// dicts. Disallowed as a placeholder name so captures cannot
    /// shadow it.
    public static let reservedNames: Set<String> = ["uri"]

    public static func compile(_ template: String) throws -> URITemplateMatcher {
        var segments: [Segment] = []
        var names: [String] = []
        var seen: Set<String> = []
        var currentLiteral = ""
        var index = template.startIndex

        while index < template.endIndex {
            let ch = template[index]
            if ch == "}" {
                throw CompileError.unterminatedPlaceholder
            }
            if ch == "{" {
                if !currentLiteral.isEmpty {
                    segments.append(.literal(currentLiteral))
                    currentLiteral = ""
                }
                let nameStart = template.index(after: index)
                guard let nameEnd = template[nameStart...].firstIndex(of: "}") else {
                    throw CompileError.unterminatedPlaceholder
                }
                let nameSlice = template[nameStart..<nameEnd]
                if nameSlice.contains("{") {
                    throw CompileError.nestedBrace
                }
                let name = String(nameSlice)
                if name.isEmpty {
                    throw CompileError.emptyPlaceholder
                }
                if !isValidIdentifier(name) {
                    throw CompileError.invalidPlaceholderName(name)
                }
                if Self.reservedNames.contains(name) {
                    throw CompileError.reservedPlaceholderName(name)
                }
                if !seen.insert(name).inserted {
                    throw CompileError.duplicatePlaceholder(name)
                }
                segments.append(.placeholder(name))
                names.append(name)
                index = template.index(after: nameEnd)
            } else {
                currentLiteral.append(ch)
                index = template.index(after: index)
            }
        }
        if !currentLiteral.isEmpty {
            segments.append(.literal(currentLiteral))
        }

        return URITemplateMatcher(
            template: template,
            segments: segments,
            placeholderNames: names
        )
    }

    /// Match `uri` against this template. Returns a dictionary keyed by
    /// placeholder name, with values percent-decoded. `nil` on no match.
    public func match(_ uri: String) -> [String: String]? {
        var captures: [String: String] = [:]
        var cursor = uri.startIndex

        var i = 0
        while i < segments.count {
            switch segments[i] {
            case .literal(let lit):
                guard uri[cursor...].hasPrefix(lit) else { return nil }
                cursor = uri.index(cursor, offsetBy: lit.count)

            case .placeholder(let name):
                // Find the next literal segment to bound the capture.
                let nextLiteral: String? = {
                    if i + 1 < segments.count, case .literal(let next) = segments[i + 1] {
                        return next
                    }
                    return nil
                }()

                let raw: String
                if let bound = nextLiteral {
                    guard let endRange = uri.range(of: bound, range: cursor..<uri.endIndex) else {
                        return nil
                    }
                    raw = String(uri[cursor..<endRange.lowerBound])
                    cursor = endRange.lowerBound
                } else {
                    raw = String(uri[cursor..<uri.endIndex])
                    cursor = uri.endIndex
                }

                if raw.isEmpty { return nil }
                captures[name] = raw.removingPercentEncoding ?? raw
            }
            i += 1
        }

        guard cursor == uri.endIndex else { return nil }
        return captures
    }
}

private func isValidIdentifier(_ s: String) -> Bool {
    guard let first = s.first else { return false }
    if !(first.isLetter || first == "_") { return false }
    for ch in s.dropFirst() {
        if !(ch.isLetter || ch.isNumber || ch == "_") { return false }
    }
    return true
}
