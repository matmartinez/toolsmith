import Foundation
import Testing

@testable import Toolsmith

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }
}

@Suite("Logger")
struct LoggerTests {
    /// Drive a fresh Logger instance with a synchronous sink that
    /// captures lines into the given collector. Tests use a per-Suite
    /// Logger so the shared singleton's state isn't perturbed.
    private func makeLogger(minLevel: LogLevel) -> (Logger, LineCollector) {
        let collector = LineCollector()
        let logger = Logger()
        logger.setMinLevel(minLevel)
        logger.setSink { collector.append($0) }
        return (logger, collector)
    }

    @Test("LogLevel ordering: debug < info < warning < error < critical")
    func levelOrdering() {
        let ordered: [LogLevel] = [.debug, .info, .warning, .error, .critical]
        for i in 0..<ordered.count - 1 {
            #expect(ordered[i] < ordered[i + 1])
        }
        #expect(LogLevel.info >= LogLevel.info)
        #expect(LogLevel.error > LogLevel.debug)
    }

    @Test("Level filtering: messages below minLevel are dropped")
    func filtering() {
        let (logger, collector) = makeLogger(minLevel: .warning)
        logger.debug("d")
        logger.info("i")
        logger.warning("w")
        logger.error("e")
        logger.critical("c")
        let lines = collector.snapshot()
        let labels = lines.map { line -> String in
            // Format is "<timestamp> <LABEL> toolsmith: …"
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            return parts.count >= 2 ? String(parts[1]) : ""
        }
        #expect(labels == ["WARNING", "ERROR", "CRITICAL"])
    }

    @Test("Line format includes ISO timestamp, level label, and 'toolsmith:' prefix")
    func format() {
        let (logger, collector) = makeLogger(minLevel: .info)
        logger.info("hello world")
        let lines = collector.snapshot()
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.hasSuffix("\n"))
        #expect(line.contains(" INFO toolsmith: hello world"))
        // ISO 8601 prefix: starts with a 4-digit year.
        let yearDigits = line.prefix(4)
        let isAllDigits = yearDigits.allSatisfy { $0.isNumber }
        #expect(isAllDigits)
        #expect(line.contains("T"))
        #expect(line.contains("Z"))
    }

    @Test("setMinLevel can be changed at runtime")
    func dynamicMinLevel() {
        let (logger, collector) = makeLogger(minLevel: .error)
        logger.info("hidden")
        logger.setMinLevel(.info)
        logger.info("visible")
        let lines = collector.snapshot()
        #expect(lines.count == 1)
        #expect(lines[0].contains("visible"))
    }

    @Test("resetSink restores default behavior without crashing")
    func resetSink() {
        let (logger, _) = makeLogger(minLevel: .info)
        logger.info("captured")
        logger.resetSink()
        // After reset, subsequent calls go to stderr — we can't easily
        // assert that. Just verify resetSink doesn't crash.
        logger.info("post-reset")
    }
}
