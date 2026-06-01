import Foundation

enum Mode: Equatable {
    case client
    case server

    static func detect(commandOrUrl: String?) -> Mode {
        guard let value = commandOrUrl, !value.isEmpty else { return .server }
        let lowered = value.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return .client
        }
        return .server
    }
}

enum TransportKind: String, CaseIterable {
    case sse
    case streamablehttp
}

enum LogLevel: String, CaseIterable, Sendable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var severity: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        case .critical: 4
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}
