import XCTest
@testable import CFSpeedKit

/// Hits the real speed.cloudflare.com endpoints. Not run in CI by default —
/// used to manually sanity-check the engine end-to-end.
final class SpeedTestRunnerIntegrationTests: XCTestCase {
    @MainActor
    func testRunnerCompletesAgainstRealEndpoint() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CF_SPEEDTEST_LIVE"] == "1", "set CF_SPEEDTEST_LIVE=1 to run live network test")

        let config = SpeedTestConfig(
            baseURL: URL(string: "https://speed.cloudflare.com")!,
            concurrency: 4,
            downloadDuration: 3,
            uploadDuration: 3,
            downloadBytesPerRequest: 10_000_000,
            uploadBytesPerRequest: 2_000_000,
            idleLatencyProbeCount: 5,
            sampleInterval: 0.2
        )
        let runner = SpeedTestRunner(config: config)
        runner.start()

        let deadline = Date().addingTimeInterval(30)
        while runner.result == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let result = try XCTUnwrap(runner.result)
        XCTAssertGreaterThan(result.download.meanMbps, 0)
        XCTAssertGreaterThan(result.upload.meanMbps, 0)
        XCTAssertGreaterThan(result.idleLatency.avgMs, 0)
        print("Download: \(result.download.meanMbps) Mbps, Upload: \(result.upload.meanMbps) Mbps, Latency: \(result.idleLatency.avgMs) ms, Colo: \(result.meta.colo ?? "?")")
    }
}
