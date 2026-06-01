import Foundation

/// One Server-Sent Event, assembled from one or more `field: value` lines
/// terminated by a blank line per WHATWG EventSource.
public struct SSEEvent: Hashable, Sendable {
    /// The `event:` field, or `"message"` when absent.
    public var event: String
    /// `data:` lines joined by `\n`. A trailing `\n` from the last data
    /// line is stripped per spec.
    public var data: String
    /// Sticky `id:` field; once set, persists across subsequent events
    /// until explicitly replaced.
    public var id: String?
    /// `retry:` field, in milliseconds.
    public var retry: Int?

    public init(event: String = "message", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental, line-oriented Server-Sent Events parser. Feed each line
/// (without trailing newline) from the wire via `feed(line:)`; an event
/// is returned whenever a blank line terminates the current record.
///
/// Per WHATWG, `id` is sticky across events. `event` / `data` / `retry`
/// reset after each dispatch.
public struct SSEParser: Sendable {
    private var pendingData: String = ""
    private var pendingEvent: String? = nil
    private var pendingRetry: Int? = nil
    private var stickyId: String? = nil

    public init() {}

    /// Feed one line. Returns a completed event when the line terminates
    /// the current record (i.e. is empty), nil otherwise.
    public mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil  // comment
        }
        let (name, value) = Self.splitField(line)
        switch name {
        case "event":
            pendingEvent = value
        case "data":
            pendingData += value + "\n"
        case "id":
            if !value.contains("\u{0000}") { stickyId = value.isEmpty ? nil : value }
        case "retry":
            if let n = Int(value), n >= 0 { pendingRetry = n }
        default:
            break  // unknown fields are ignored per spec
        }
        return nil
    }

    /// Convenience for tests: parse a whole SSE blob in one pass.
    public mutating func feed(text: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = feed(line: String(line)) {
                events.append(event)
            }
        }
        return events
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            pendingData = ""
            pendingEvent = nil
            pendingRetry = nil
        }
        guard !pendingData.isEmpty else { return nil }
        var data = pendingData
        if data.hasSuffix("\n") { data.removeLast() }
        return SSEEvent(
            event: pendingEvent ?? "message",
            data: data,
            id: stickyId,
            retry: pendingRetry
        )
    }

    private static func splitField(_ line: String) -> (name: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let name = String(line[..<colon])
        var rest = line[line.index(after: colon)...]
        if rest.first == " " { rest = rest.dropFirst() }
        return (name, String(rest))
    }
}
