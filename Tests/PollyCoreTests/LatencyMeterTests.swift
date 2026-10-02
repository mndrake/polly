import XCTest
@testable import PollyCore

final class LatencyMeterTests: XCTestCase {
    func testSmoothsPerSpeaker() {
        var meter = LatencyMeter()
        meter.record(speaker: .others, resultEnd: 10, now: 12)
        XCTAssertEqual(meter.smoothed[.others], 2)
        meter.record(speaker: .others, resultEnd: 20, now: 21)
        XCTAssertEqual(meter.smoothed[.others]!, 1.7, accuracy: 0.0001)
        XCTAssertEqual(meter.latest[.others], 1)
        meter.record(speaker: .me, resultEnd: 5, now: 5.5)
        XCTAssertEqual(meter.overall!, 1.7, accuracy: 0.0001, "overall reports the slower channel")
    }

    func testIgnoresImplausibleSamples() {
        var meter = LatencyMeter()
        meter.record(speaker: .me, resultEnd: 12, now: 10)   // future
        meter.record(speaker: .me, resultEnd: 0, now: 10)    // no timing info
        meter.record(speaker: .me, resultEnd: 10, now: 100)  // stale final
        XCTAssertNil(meter.overall)
    }

    func testDescribe() {
        XCTAssertEqual(LatencyMeter.describe(0.84), "0.8 s behind")
    }
}
