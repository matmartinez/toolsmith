import Foundation

/// JSON-RPC 2.0 error object.
public struct JSONRPCError: Hashable, Codable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Reserved codes from the spec.
    public static let parseError = -32_700
    public static let invalidRequest = -32_600
    public static let methodNotFound = -32_601
    public static let invalidParams = -32_602
    public static let internalError = -32_603
}
