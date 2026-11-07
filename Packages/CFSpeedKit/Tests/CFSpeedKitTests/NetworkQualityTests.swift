import Foundation
import Testing
@testable import CFSpeedKit

@Suite("Network quality scoring")
struct NetworkQualityTests {
    /// Regression: the scoring tables are all ascending "lower is better",
    /// so an unmeasured loaded-latency increase passed as 0 scored as the
    /// *best* bucket. A run whose loaded-latency probes all failed therefore
    /// graded out as Great. Unmeasured must mean no score at all.
    @Test("No grade when loaded latency was never measured")
    func missingLoadedLatencyYieldsNoScore() {
        #expect(NetworkQuality(
            download: 45,
            latencyMs: 25,
            jitterMs: 1,
            loadedLatencyIncreaseMs: nil
        ) == nil)
    }

    @Test("A run that lost its connection mid-transfer carries no grade")
    func interruptedRunHasNoQuality() {
        let result = TestResult(
            meta: NetworkMeta(),
            idleLatency: LatencySummary(samples: [24, 26, 25])!,
            download: ThroughputSummary(
                bytes: 40_000_000, durationSeconds: 8, meanMbps: 22,
                medianMbps: 20, p25Mbps: 8, p75Mbps: 40, p90Mbps: 45
            ),
            downloadLoadedLatency: nil,
            upload: .zero,
            uploadLoadedLatency: nil
        )
        #expect(result.quality == nil)
    }

    /// Guards the port of Cloudflare's tables: making the score optional must
    /// not change what a complete measurement grades as.
    @Test("A fully measured fast connection still grades great")
    func healthyRunStillGrades() throws {
        let quality = try #require(NetworkQuality(
            download: 420,
            latencyMs: 12,
            jitterMs: 1,
            loadedLatencyIncreaseMs: 9
        ))
        #expect(quality.videoStreaming == .great)
        #expect(quality.onlineGaming == .great)
        #expect(quality.videoChatting == .great)
    }

    @Test("A slow, high-latency connection grades badly")
    func poorRunGradesBadly() throws {
        let quality = try #require(NetworkQuality(
            download: 0.5,
            latencyMs: 600,
            jitterMs: 550,
            loadedLatencyIncreaseMs: 600
        ))
        #expect(quality.videoStreaming == .bad)
        #expect(quality.onlineGaming == .bad)
        #expect(quality.videoChatting == .bad)
    }
}

@Suite("Failure classification")
struct TestFailureTests {
    @Test("URLError codes map to the right failure", arguments: [
        (URLError.Code.notConnectedToInternet, TestFailure.offline),
        (.dataNotAllowed, .dataNotAllowed),
        (.internationalRoamingOff, .dataNotAllowed),
        (.networkConnectionLost, .interrupted),
        (.timedOut, .unreachable),
        (.cannotFindHost, .unreachable),
        (.dnsLookupFailed, .unreachable),
        (.secureConnectionFailed, .unreachable),
    ])
    func mapping(code: URLError.Code, expected: TestFailure) {
        #expect(TestFailure(URLError(code)) == expected)
    }

    /// Only states that can't change within a run should short-circuit the
    /// probe loop; a timeout or a dropped connection deserves its retries.
    @Test("Only unrecoverable states stop the probe loop early")
    func terminalStates() {
        #expect(TestFailure.offline.isTerminal)
        #expect(TestFailure.dataNotAllowed.isTerminal)
        #expect(!TestFailure.unreachable.isTerminal)
        #expect(!TestFailure.interrupted.isTerminal)
        #expect(!TestFailure.unknown("boom").isTerminal)
    }

    @Test("Unknown failures surface the underlying description")
    func unknownCarriesDescription() {
        let error = URLError(.cannotDecodeRawData)
        guard case .unknown(let description) = TestFailure(error) else {
            Issue.record("expected .unknown")
            return
        }
        #expect(description == error.localizedDescription)
    }
}
