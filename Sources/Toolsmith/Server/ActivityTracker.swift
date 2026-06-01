import Foundation

/// Records the timestamp of the most recent inbound request the
/// proxy has seen, for surfacing via `/status`.
public actor ActivityTracker {
    private var lastActivity: Date?
    public init() {}

    public func touch(now: Date = Date()) { lastActivity = now }
    public func snapshot() -> Date? { lastActivity }
}
