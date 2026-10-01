import Foundation

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental Server-Sent Events parser.
///
/// Feed it lines (without trailing newlines). It dispatches on blank lines per
/// the SSE spec, but also tolerates line sources that drop blank lines (Apple's
/// `URL.AsyncBytes.lines` does): Anthropic sends exactly one `data:` line per
/// event, so a new `event:` line, or a `data:` line following a complete data
/// payload, also terminates the previous event.
public struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func consume(line rawLine: String) -> [SSEEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        var out: [SSEEvent] = []

        if line.isEmpty {
            if let event = dispatch() { out.append(event) }
            return out
        }
        if line.hasPrefix(":") { return out } // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            if !dataLines.isEmpty, let event = dispatch() { out.append(event) }
            eventName = String(value)
        case "data":
            if !dataLines.isEmpty, Self.looksComplete(dataLines.joined(separator: "\n")), let event = dispatch() {
                out.append(event)
            }
            dataLines.append(String(value))
        default:
            break // id:, retry: — unused
        }
        return out
    }

    /// Flushes a trailing event at end of stream.
    public mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    private static func looksComplete(_ data: String) -> Bool {
        guard let bytes = data.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: bytes)) != nil
    }
}
