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

    func testSingleSampleHasNoJitter() {
        let summary = LatencySummary(samples: [12])!
        XCTAssertEqual(summary.medianMs, 12)
        XCTAssertNil(summary.jitterMs)
    }

    func testQualityUnavailableWithoutJitter() {
        XCTAssertNil(NetworkQuality(download: 500, latencyMs: 5, jitterMs: nil, loadedLatencyIncreaseMs: 5))
    }

    func testOnlyRecoverableFailuresRetryAutomatically() {
        XCTAssertTrue(TestFailure.offline.allowsAutomaticRetry)
        XCTAssertTrue(TestFailure.interrupted.allowsAutomaticRetry)
        XCTAssertFalse(TestFailure.rejected(statusCode: 429).allowsAutomaticRetry)
        XCTAssertFalse(TestFailure.unreachable.allowsAutomaticRetry)
        XCTAssertFalse(TestFailure.dataNotAllowed.allowsAutomaticRetry)
    }
}
