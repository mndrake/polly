import XCTest
@testable import PollyCore

final class SSEParserTests: XCTestCase {
    private func parse(_ lines: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events = lines.flatMap { parser.consume(line: $0) }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    func testStandardFraming() {
        let events = parse(["event: a", "data: {\"x\":1}", "", "event: b", "data: {\"y\":2}", ""])
        XCTAssertEqual(events, [SSEEvent(event: "a", data: "{\"x\":1}"), SSEEvent(event: "b", data: "{\"y\":2}")])
    }

    func testWithoutBlankLines() {
        let events = parse(["event: a", "data: {\"x\":1}", "event: b", "data: {\"y\":2}"])
        XCTAssertEqual(events.map(\.event), ["a", "b"])
    }

    func testConsecutiveDataLinesWithoutEventNames() {
        let events = parse(["data: {\"x\":1}", "data: {\"y\":2}"])
        XCTAssertEqual(events.map(\.data), ["{\"x\":1}", "{\"y\":2}"])
    }

    func testMultiLineDataIsJoined() {
        let events = parse(["data: {\"x\":", "data: 1}", ""])
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "{\"x\":\n1}")])
    }

    func testCommentsAndCarriageReturnsIgnored() {
        let events = parse([": keep-alive", "event: a\r", "data: {}\r", "\r"])
        XCTAssertEqual(events, [SSEEvent(event: "a", data: "{}")])
    }
}
