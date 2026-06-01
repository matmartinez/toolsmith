import Foundation

/// Canonical encoder/decoder for JSON written to or read from the
/// wire. Slashes stay unescaped so method names like `tools/call`
/// don't ship as `tools\/call`.
public enum WireJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
