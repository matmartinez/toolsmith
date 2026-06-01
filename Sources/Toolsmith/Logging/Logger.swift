import Foundation

/// Process-wide logger. Synchronous + lock-guarded so it can be called
/// from any context, including NIO event-loop callbacks. Writes to
/// stderr by default — never stdout, since in client mode stdout is
/// the JSON-RPC wire channel and any stray byte would corrupt the
/// frame. Tests can redirect by calling `setSink`.
final class Logger: @unchecked Sendable {
    /// The shared singleton. Configure once in Toolsmith.run() via
    /// `setMinLevel`; everything else logs through this.
    static let shared = Logger()

    private let lock = NSLock()
    private var _minLevel: LogLevel = .info
    private var _sink: @Sendable (String) -> Void = Logger.stderrSink

    init() {}

    var minLevel: LogLevel {
        lock.lock(); defer { lock.unlock() }
        return _minLevel
    }

    func setMinLevel(_ level: LogLevel) {
        lock.lock(); defer { lock.unlock() }
        _minLevel = level
    }

    /// Replace the destination. Each emitted line is passed verbatim
    /// (including the trailing `\n`). Useful for tests.
    func setSink(_ sink: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        _sink = sink
    }

    /// Restore the default stderr sink.
    func resetSink() {
        lock.lock(); defer { lock.unlock() }
        _sink = Logger.stderrSink
    }

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        let snapshot: (LogLevel, @Sendable (String) -> Void) = {
            lock.lock(); defer { lock.unlock() }
            return (_minLevel, _sink)
        }()
        guard level >= snapshot.0 else { return }
        let line = "\(Self.timestamp()) \(level.rawValue) toolsmith: \(message())\n"
        snapshot.1(line)
    }

    func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    func critical(_ message: @autoclosure () -> String) { log(.critical, message()) }

    private static let stderrSink: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func timestamp() -> String {
        // ISO8601DateFormatter is not Sendable, so build per-call.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
