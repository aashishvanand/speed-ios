import XCTest
@testable import CFSpeedKit

final class LatencySummaryTests: XCTestCase {
    func testEmptySamplesReturnsNil() {
        XCTAssertNil(LatencySummary(samples: []))
    }

    func testStatsComputedFromSamples() {
        let summary = LatencySummary(samples: [10, 20, 30])!
        XCTAssertEqual(summary.minMs, 10)
        XCTAssertEqual(summary.maxMs, 30)
        XCTAssertEqual(summary.avgMs, 20)
        XCTAssertEqual(summary.jitterMs, 10)
    }
}
